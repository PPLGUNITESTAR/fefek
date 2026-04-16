// SPDX-License-Identifier: GPL-2.0-only
/*
 * cpufreq_schedlancer.c — Schedlancer CPUFreq Governor v4
 *
 * Thermal-aware, idle-aware cpufreq governor for SM6150.
 *
 *  -------------------------
 *  - CRITICAL: __cpufreq_driver_target() is no longer called while holding
 *    any spinlock.  sl_apply_thermal() returns the target freq; callers
 *    apply it after releasing cl->lock.  Same for sl_check_idle().
 *    This eliminates "scheduling while atomic" on drivers that sleep.
 *  - gov_enabled accessed via READ_ONCE/WRITE_ONCE — no compiler-induced
 *    data race on lockless reads from sl_set_freq().
 *  - Temperature comparisons use signed long arithmetic, never (u32) casts.
 *    Negative sensor readings no longer wrap to 4 billion and produce
 *    nonsense throttle decisions.
 *  - sl_apply_thermal() always updates throttled_idx, even for idle
 *    clusters.  When a cluster exits idle, it picks up the latest thermal
 *    target instead of a stale one.
 *  - Division by zero guard on temp_diff (sysfs clamps to >=1).
 *  - Sensor readings outside [-40 000, 150 000] m°C are rejected as
 *    spurious.
 *  - lockdep_assert_held() on functions that require cl->lock.
 *  - OPP table ascending-order validated at module init with WARN_ON.
 *  - Cache-line aligned struct layout to eliminate false sharing between
 *    read-mostly identity, hot mutable state, and cold sysfs tunables.
 *  - unlikely()/likely() on fast-path branches for better branch prediction.
 *  - Thermal sensor accessed via thermal_zone_get_temp() (kernel standard
 *    API).  Returns millidegrees Celsius; all comparisons are in m°C.
 *  - Governor registered with new-style cpufreq_governor .init/.exit/
 *    .start/.stop/.limits callbacks.
 *
 * Author: 0xArCHDeViL
 */

#define pr_fmt(fmt) "SL: " fmt

#include <linux/atomic.h>
#include <linux/bug.h>
#include <linux/compiler.h>
#include <linux/cpufreq.h>
#include <linux/delay.h>
#include <linux/kernel.h>
#include <linux/kthread.h>
#include <linux/lockdep.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/rcupdate.h>
#include <linux/sched.h>
#include <linux/sched/task.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/thermal.h>
#include <linux/wait.h>

#include "cpufreq_schedlancer.h"

/* ------------------------------------------------------------------ */
/*  Global state                                                        */
/* ------------------------------------------------------------------ */

static struct sl_governor gov;

/*
 * Per-CPU load tracking — only read and written from the single monitor
 * kthread (serially per CPU), so no locking is needed.
 */
static DEFINE_PER_CPU(struct sl_cpu_load, sl_load);

/* ------------------------------------------------------------------ */
/*  Helpers: OPP lookup                                                 */
/* ------------------------------------------------------------------ */

/**
 * sl_nearest_idx() - find the highest OPP index not exceeding @freq_khz
 * @cl:       cluster
 * @freq_khz: target frequency in kHz
 *
 * Returns index in [0, nr_freqs-1].  If @freq_khz is below the lowest
 * OPP, returns 0.
 */
static u32 sl_nearest_idx(const struct sl_cluster *cl, u32 freq_khz)
{
	u32 i;

	for (i = cl->nr_freqs - 1; i > 0; i--) {
		if (cl->freqs[i] <= freq_khz)
			return i;
	}
	return 0;
}

/* ------------------------------------------------------------------ */
/*  OPP table validation (called once at init)                         */
/* ------------------------------------------------------------------ */

/**
 * sl_validate_opp_table() - check that an OPP table is sorted ascending
 *
 * Returns true if valid, false (with WARN) if not.
 */
static bool __init sl_validate_opp_table(const char *name,
					  const u32 *freqs, u32 nr)
{
	u32 i;
	bool valid = true;

	if (WARN_ON_ONCE(nr == 0)) {
		pr_err("%s: empty OPP table\n", name);
		return false;
	}

	for (i = 1; i < nr; i++) {
		if (WARN_ON_ONCE(freqs[i] <= freqs[i - 1])) {
			pr_err("%s: not ascending at [%u]=%u -> [%u]=%u\n",
			       name, i - 1, freqs[i - 1], i, freqs[i]);
			valid = false;
		}
	}

	return valid;
}

/* ------------------------------------------------------------------ */
/*  Thermal sensor                                                      */
/* ------------------------------------------------------------------ */

/**
 * sl_update_sensor() - read the cached thermal zone device
 *
 * Updates gov.cur_temp/prev_temp under gov.temp_lock.
 * Rejects readings outside [SL_TEMP_SANE_MIN, SL_TEMP_SANE_MAX] (m°C).
 * Returns 0 on success, -errno on failure (temps left unchanged).
 *
 * thermal_zone_get_temp() returns millidegrees Celsius in this kernel.
 */
int sl_update_sensor(void)
{
	int raw = 0;
	long temp;
	int ret;
	unsigned long flags;

	if (unlikely(!gov.tz)) {
		pr_warn_ratelimited("thermal zone not available\n");
		return -ENODEV;
	}

	ret = thermal_zone_get_temp(gov.tz, &raw);
	if (unlikely(ret)) {
		pr_warn_ratelimited("thermal_zone_get_temp failed: %d\n", ret);
		return ret;
	}

	temp = (long)raw;	/* raw is already millidegrees */

	/* Reject clearly spurious readings */
	if (unlikely(temp < SL_TEMP_SANE_MIN || temp > SL_TEMP_SANE_MAX)) {
		pr_warn_ratelimited("insane reading %ld m°C\n", temp);
		return -ERANGE;
	}

	spin_lock_irqsave(&gov.temp_lock, flags);
	gov.prev_temp = gov.cur_temp;
	gov.cur_temp  = temp;
	spin_unlock_irqrestore(&gov.temp_lock, flags);

	return 0;
}

/* ------------------------------------------------------------------ */
/*  Frequency application                                               */
/* ------------------------------------------------------------------ */

/**
 * sl_set_freq() - apply a new max frequency to the cluster policy
 * @cl:       cluster
 * @freq_khz: desired frequency (kHz)
 *
 * MUST NOT be called with cl->lock held — __cpufreq_driver_target()
 * may sleep on some platforms (regulator I2C, etc.).
 * Uses RCU internally for safe policy lifetime management.
 */
void sl_set_freq(struct sl_cluster *cl, u32 freq_khz)
{
	struct cpufreq_policy *policy;

	rcu_read_lock();
	policy = rcu_dereference(cl->policy);
	if (unlikely(!policy) || unlikely(!READ_ONCE(cl->gov_enabled))) {
		rcu_read_unlock();
		return;
	}

	/* Skip if freq is already where we want it */
	if (likely(policy->cur == freq_khz && policy->max == freq_khz)) {
		rcu_read_unlock();
		return;
	}

	policy->max = freq_khz;
	__cpufreq_driver_target(policy, freq_khz, CPUFREQ_RELATION_H);
	rcu_read_unlock();

	sl_dbg("cluster[%d] -> %u kHz", cl->id, freq_khz);
}

/* ------------------------------------------------------------------ */
/*  Thermal mitigation                                                  */
/* ------------------------------------------------------------------ */

/**
 * sl_apply_thermal() - compute thermally-limited OPP index
 * @cl:   cluster (must hold cl->lock)
 * @temp: current temperature in m°C (signed long)
 *
 * Always updates cl->throttled_idx — even for idle clusters — so that
 * when a cluster exits idle it picks up the latest thermal target.
 *
 * Returns: target frequency in kHz if cur_idx changed and the cluster
 *          is not idle, 0 otherwise.  Caller must apply the returned
 *          frequency AFTER releasing cl->lock via sl_set_freq().
 */
u32 sl_apply_thermal(struct sl_cluster *cl, long temp)
{
	u32 throttle_temp, temp_diff, hysteresis, max_thr_idx;
	u32 new_idx, max_idx;

	lockdep_assert_held(&cl->lock);

	max_idx = cl->nr_freqs - 1;

	/*
	 * Snapshot tunables with READ_ONCE — they can be written
	 * concurrently from sysfs under tunables_lock (a different
	 * lock).  Individual u32 reads are naturally atomic on ARM,
	 * READ_ONCE prevents compiler-level tearing/caching.
	 */
	throttle_temp = READ_ONCE(cl->tunables.throttle_temp);
	temp_diff     = READ_ONCE(cl->tunables.temp_diff);
	hysteresis    = READ_ONCE(cl->tunables.hysteresis);
	max_thr_idx   = READ_ONCE(cl->tunables.max_throttle_idx);

	/* Clamp max_throttle_idx to valid range */
	max_thr_idx = min_t(u32, max_thr_idx, max_idx);

	/* Defense against division by zero */
	if (unlikely(temp_diff == 0))
		temp_diff = 1;

	/*
	 * All temperature comparisons are signed — no (u32) casts.
	 * throttle_temp is u32 but always in valid range, so (long) cast
	 * is safe and preserves correct comparison for negative temps.
	 */
	if (temp < (long)throttle_temp) {
		/*
		 * Below trip point.  Only unthrottle if we have
		 * hysteresis clearance — prevents bounce.
		 */
		if (cl->throttled &&
		    temp > (long)(throttle_temp - hysteresis)) {
			/* Still in hysteresis band — keep current target,
			 * update throttled_idx for idle-exit accuracy.
			 */
			new_idx = cl->throttled_idx;
			goto out;
		}

		cl->throttled   = false;
		new_idx = max_idx;
	} else {
		/*
		 * At or above trip point: compute target index.
		 *
		 *   steps = (temp - throttle_temp) / temp_diff + 1
		 *   idx   = max_idx - steps
		 *
		 * Floored at max_thr_idx so we never go below a
		 * minimum guaranteed OPP.
		 */
		long excess = temp - (long)throttle_temp;
		u32  steps  = (u32)(excess / (long)temp_diff) + 1;

		new_idx = (steps <= max_idx)
			? (max_idx - steps)
			: 0;
		new_idx = max_t(u32, new_idx, max_thr_idx);

		cl->throttled = true;
	}

out:
	new_idx = clamp_t(u32, new_idx, 0, max_idx);
	cl->throttled_idx = new_idx;

	/* Cluster is idle — idle path owns the frequency.
	 * We still updated throttled_idx above so idle-exit
	 * picks up the latest thermal target.
	 */
	if (atomic_read(&cl->idle))
		return 0;

	/* No change needed */
	if (new_idx == cl->cur_idx)
		return 0;

	cl->cur_idx = new_idx;
	return cl->freqs[new_idx];
}

/* ------------------------------------------------------------------ */
/*  Idle detection                                                      */
/* ------------------------------------------------------------------ */

/**
 * sl_get_cpu_load() - compute instantaneous CPU load (%)
 * @cpu:  CPU number
 * @pcpu: per-CPU tracking struct (single-writer: monitor kthread)
 *
 * Returns load in range [0, 100].
 */
int sl_get_cpu_load(int cpu, struct sl_cpu_load *pcpu)
{
	u64 wall = 0, idle;
	u64 wall_delta, idle_delta;
	u32 load;

	idle = get_cpu_idle_time(cpu, &wall, 0);

	wall_delta = wall - pcpu->prev_wall;
	idle_delta = idle - pcpu->prev_idle;

	pcpu->prev_wall = wall;
	pcpu->prev_idle = idle;

	if (unlikely(!wall_delta))
		return 0;

	/* idle > wall can happen at boot/init — treat as 0% load */
	if (unlikely(idle_delta >= wall_delta))
		return 0;

	load = (u32)(100ULL * (wall_delta - idle_delta) / wall_delta);
	return (int)clamp_t(u32, load, 0, 100);
}

/**
 * sl_check_idle() - assess whether a cluster should enter/exit idle mode
 * @cl: cluster
 *
 * Four-phase design to avoid sleeping-in-atomic:
 *   Phase 1: compute per-CPU loads (no lock, only per-CPU data + RCU)
 *   Phase 2: decide idle state transition under cl->lock, record target freq
 *   Phase 3: apply frequency AFTER releasing cl->lock
 *   Phase 4: update global poll interval (lockless atomics)
 */
void sl_check_idle(struct sl_cluster *cl)
{
	struct cpufreq_policy *policy;
	u32 sum_load = 0, nr_cpus = 0, avg_load;
	u32 idle_threshold, idle_freq;
	u32 target_freq = 0;
	bool any_busy = false;
	int cpu;
	unsigned long flags;

	/* ---- Phase 1: compute loads (no lock) ---- */
	rcu_read_lock();
	policy = rcu_dereference(cl->policy);
	if (unlikely(!policy)) {
		rcu_read_unlock();
		return;
	}

	for_each_cpu(cpu, policy->related_cpus) {
		struct sl_cpu_load *pcpu = &per_cpu(sl_load, cpu);
		int load = sl_get_cpu_load(cpu, pcpu);

		if ((u32)load >= SL_SINGLE_CORE_BUSY_PCT)
			any_busy = true;

		sum_load += (u32)load;
		nr_cpus++;
	}
	rcu_read_unlock();

	if (unlikely(!nr_cpus))
		return;

	avg_load = sum_load / nr_cpus;

	/* Snapshot tunables — lockless, individual u32 reads are atomic */
	idle_threshold = READ_ONCE(cl->tunables.idle_threshold);
	idle_freq      = READ_ONCE(cl->tunables.idle_freq_khz);

	/* ---- Phase 2: decide under lock ---- */
	spin_lock_irqsave(&cl->lock, flags);

	if (!any_busy && avg_load < idle_threshold) {
		/* Entering or sustaining idle */
		if (!atomic_read(&cl->idle)) {
			atomic_set(&cl->idle, 1);
			sl_dbg("cluster[%d] IDLE avg=%u%%", cl->id, avg_load);
		}
		target_freq = idle_freq;
	} else {
		/* Active — check if we're exiting idle */
		if (atomic_read(&cl->idle)) {
			atomic_set(&cl->idle, 0);
			sl_dbg("cluster[%d] UNIDLE avg=%u%%", cl->id,
			       avg_load);
			/* Restore latest thermal-limited index */
			cl->cur_idx = cl->throttled_idx;
			target_freq = cl->freqs[cl->cur_idx];
		}
		/* else: already active, no freq change from idle path */
	}

	spin_unlock_irqrestore(&cl->lock, flags);

	/* ---- Phase 3: apply frequency (no lock held) ---- */
	if (target_freq)
		sl_set_freq(cl, target_freq);

	/* ---- Phase 4: update poll interval ---- */
	if (atomic_read(&cl->idle)) {
		atomic_set(&gov.poll_ms, SL_POLL_IDLE_MS);
	} else {
		bool all_active = true;
		int i;

		for (i = 0; i < SL_NR_CLUSTERS; i++) {
			if (atomic_read(&gov.clusters[i].idle)) {
				all_active = false;
				break;
			}
		}
		if (all_active)
			atomic_set(&gov.poll_ms, SL_POLL_ACTIVE_MS);
	}
}

/* ------------------------------------------------------------------ */
/*  Monitor kthread                                                     */
/* ------------------------------------------------------------------ */

/**
 * sl_monitor_task() - main governor loop
 *
 * Sleeps via wait_event_interruptible_timeout() — the kernel's
 * freezer and OOM killer can interact with it properly.
 * Woken early (via gov.wq) when a policy comes online/offline.
 */
static int sl_monitor_task(void *data)
{
	while (!kthread_should_stop()) {
		int poll_ms;
		long ret;
		long cur_temp, prev_temp;
		unsigned long flags;
		int i;

		/* Sleep until timeout or early wake */
		poll_ms = atomic_read(&gov.poll_ms);
		ret = wait_event_interruptible_timeout(
			gov.wq,
			kthread_should_stop() ||
			    atomic_read(&gov.should_wake),
			msecs_to_jiffies(poll_ms));

		atomic_set(&gov.should_wake, 0);

		if (unlikely(kthread_should_stop()))
			break;

		/* No active policies — nothing to do */
		if (unlikely(!atomic_read(&gov.enabled_count)))
			continue;

		/* ---- Thermal read ---- */
		if (sl_update_sensor())
			goto check_idle; /* sensor failed, still do idle */

		spin_lock_irqsave(&gov.temp_lock, flags);
		cur_temp  = gov.cur_temp;
		prev_temp = gov.prev_temp;
		spin_unlock_irqrestore(&gov.temp_lock, flags);

		/* Only run thermal mitigation if temp actually changed */
		if (cur_temp != prev_temp) {
			for (i = 0; i < SL_NR_CLUSTERS; i++) {
				struct sl_cluster *cl = &gov.clusters[i];
				u32 freq;

				/*
				 * sl_apply_thermal always updates
				 * throttled_idx (even for idle clusters)
				 * and returns 0 if idle or unchanged.
				 */
				spin_lock_irqsave(&cl->lock, flags);
				freq = sl_apply_thermal(cl, cur_temp);
				spin_unlock_irqrestore(&cl->lock, flags);

				/* Apply AFTER releasing cl->lock */
				if (freq)
					sl_set_freq(cl, freq);
			}
		}

check_idle:
		/* ---- Idle detection (always runs) ---- */
		for (i = 0; i < SL_NR_CLUSTERS; i++) {
			struct sl_cluster *cl = &gov.clusters[i];

			if (likely(READ_ONCE(cl->gov_enabled)))
				sl_check_idle(cl);
		}
	}

	return 0;
}

/* ------------------------------------------------------------------ */
/*  sysfs interface                                                     */
/* ------------------------------------------------------------------ */

/*
 * Per-cluster tunables exposed at:
 *   /sys/devices/system/cpu/cpufreq/<policy>/schedlancer/
 *
 * Reads/writes are serialized by cl->tunables_lock (mutex).
 * The kthread reads tunables locklessly via READ_ONCE — acceptable
 * because individual u32 reads are naturally atomic on ARM and the
 * worst case is one poll with a slightly stale value.
 */

#define SL_SYSFS_SHOW(field)						\
static ssize_t show_##field(struct cpufreq_policy *policy, char *buf)	\
{									\
	struct sl_cluster *cl = policy->governor_data;			\
	u32 val;							\
	if (unlikely(!cl))						\
		return -ENODEV;						\
	mutex_lock(&cl->tunables_lock);					\
	val = cl->tunables.field;					\
	mutex_unlock(&cl->tunables_lock);				\
	return scnprintf(buf, PAGE_SIZE, "%u\n", val);			\
}

#define SL_SYSFS_STORE(field, lo, hi)					\
static ssize_t store_##field(struct cpufreq_policy *policy,		\
			     const char *buf, size_t count)		\
{									\
	struct sl_cluster *cl = policy->governor_data;			\
	u32 val;							\
	if (unlikely(!cl))						\
		return -ENODEV;						\
	if (kstrtou32(buf, 10, &val))					\
		return -EINVAL;						\
	val = clamp_t(u32, val, lo, hi);				\
	mutex_lock(&cl->tunables_lock);					\
	WRITE_ONCE(cl->tunables.field, val);				\
	mutex_unlock(&cl->tunables_lock);				\
	return count;							\
}

#define SL_SYSFS_RW(field, lo, hi)					\
	SL_SYSFS_SHOW(field)						\
	SL_SYSFS_STORE(field, lo, hi)					\
	static struct freq_attr field##_attr =				\
		__ATTR(field, 0664, show_##field, store_##field)

/*
 * tunables in m°C — ranges match the header defaults.
 * throttle_temp: 20 000 – 90 000 m°C (20–90°C)
 * temp_diff:          1 –  20 000 m°C
 * hysteresis:         0 –  10 000 m°C
 * max_throttle_idx:   0 –  SL_BIG_MAX_IDX (table-floor index)
 * idle_threshold:     0 –  100  (percent)
 * idle_freq_khz:      0 –  UINT_MAX (kHz)
 */
SL_SYSFS_RW(throttle_temp,    20000,  90000);
SL_SYSFS_RW(temp_diff,            1,  20000);
SL_SYSFS_RW(hysteresis,           0,  10000);
SL_SYSFS_RW(max_throttle_idx,     0,  SL_BIG_MAX_IDX);
SL_SYSFS_RW(idle_threshold,       0,    100);
SL_SYSFS_RW(idle_freq_khz,        0, UINT_MAX);

static struct attribute *sl_attrs[] = {
	&throttle_temp_attr.attr,
	&temp_diff_attr.attr,
	&hysteresis_attr.attr,
	&max_throttle_idx_attr.attr,
	&idle_threshold_attr.attr,
	&idle_freq_khz_attr.attr,
	NULL,
};

static struct attribute_group sl_attr_group = {
	.attrs = sl_attrs,
	.name  = "schedlancer",
};

int sl_sysfs_register(struct cpufreq_policy *policy, struct sl_cluster *cl)
{
	int rc;

	policy->governor_data = cl;
	rc = sysfs_create_group(get_governor_parent_kobj(policy),
				&sl_attr_group);
	if (unlikely(rc)) {
		pr_err("sysfs_create_group failed: %d\n", rc);
		policy->governor_data = NULL;
	}
	return rc;
}

void sl_sysfs_unregister(struct cpufreq_policy *policy)
{
	sysfs_remove_group(get_governor_parent_kobj(policy), &sl_attr_group);
	policy->governor_data = NULL;
}

/* ------------------------------------------------------------------ */
/*  Internal helper: find cluster for policy                           */
/* ------------------------------------------------------------------ */

/**
 * sl_cluster_for_policy() - find the cluster matching this policy
 * @policy: cpufreq policy
 *
 * Safe to call without gov_lock — only reads immutable fields
 * (policy_cpu) set once at init.
 */
static struct sl_cluster *sl_cluster_for_policy(struct cpufreq_policy *policy)
{
	int i;

	for (i = 0; i < SL_NR_CLUSTERS; i++) {
		struct sl_cluster *cl = &gov.clusters[i];

		if (cl->policy_cpu == policy->cpu ||
		    cpumask_test_cpu(policy->cpu, policy->related_cpus))
			return cl;
	}
	return NULL;
}

/* ------------------------------------------------------------------ */
/*  Governor lifecycle — new-style cpufreq_governor callbacks          */
/* ------------------------------------------------------------------ */

/**
 * sl_gov_init() - called once per policy when governor is first selected
 *
 * Registers sysfs tunables directory.  Does not start the kthread or
 * enable frequency control — that happens in sl_gov_start().
 */
int sl_gov_init(struct cpufreq_policy *policy)
{
	struct sl_cluster *cl;
	int ret;

	mutex_lock(&gov.gov_lock);

	cl = sl_cluster_for_policy(policy);
	if (unlikely(!cl)) {
		pr_err("no cluster for cpu%d\n", policy->cpu);
		ret = -ENODEV;
		goto out;
	}

	ret = sl_sysfs_register(policy, cl);

out:
	mutex_unlock(&gov.gov_lock);
	return ret;
}

/**
 * sl_gov_exit() - called when governor is deselected for this policy
 *
 * Tears down sysfs.  Must mirror sl_gov_init() exactly.
 */
void sl_gov_exit(struct cpufreq_policy *policy)
{
	mutex_lock(&gov.gov_lock);
	sl_sysfs_unregister(policy);
	mutex_unlock(&gov.gov_lock);
}

/**
 * sl_gov_start() - called when the cpufreq core begins using this governor
 *
 * Enables frequency control for this cluster and wakes the monitor kthread
 * on the first active policy.
 */
int sl_gov_start(struct cpufreq_policy *policy)
{
	struct sl_cluster *cl;
	unsigned long flags;
	int ret = 0;

	mutex_lock(&gov.gov_lock);

	cl = sl_cluster_for_policy(policy);
	if (unlikely(!cl)) {
		pr_err("no cluster for cpu%d\n", policy->cpu);
		ret = -ENODEV;
		goto out;
	}

	/* Store policy under RCU, init throttle state */
	spin_lock_irqsave(&cl->lock, flags);
	rcu_assign_pointer(cl->policy, policy);
	WRITE_ONCE(cl->gov_enabled, true);
	cl->cur_idx      = cl->nr_freqs - 1;
	cl->throttled_idx = cl->nr_freqs - 1;
	cl->throttled    = false;
	atomic_set(&cl->idle, 0);
	spin_unlock_irqrestore(&cl->lock, flags);

	/* Wake kthread on first policy */
	if (atomic_inc_return(&gov.enabled_count) == 1) {
		atomic_set(&gov.should_wake, 1);
		wake_up_interruptible(&gov.wq);
	}

	sl_dbg("started for cpu%d (cluster %d)", policy->cpu, cl->id);

out:
	mutex_unlock(&gov.gov_lock);
	return ret;
}

/**
 * sl_gov_stop() - called when the cpufreq core stops using this governor
 *
 * Disables frequency control for this cluster.  Waits for any concurrent
 * RCU readers to finish before returning.
 */
void sl_gov_stop(struct cpufreq_policy *policy)
{
	struct sl_cluster *cl;
	unsigned long flags;

	mutex_lock(&gov.gov_lock);

	cl = sl_cluster_for_policy(policy);
	if (unlikely(!cl))
		goto out;

	spin_lock_irqsave(&cl->lock, flags);
	WRITE_ONCE(cl->gov_enabled, false);
	rcu_assign_pointer(cl->policy, NULL);
	atomic_set(&cl->idle, 0);
	spin_unlock_irqrestore(&cl->lock, flags);

	/*
	 * Wait for all concurrent RCU readers (sl_set_freq, sl_check_idle)
	 * to finish before the framework reclaims the policy.
	 */
	synchronize_rcu();

	if (atomic_dec_and_test(&gov.enabled_count)) {
		atomic_set(&gov.poll_ms, SL_POLL_ACTIVE_MS);
		sl_dbg("all clusters stopped");
	}

	sl_dbg("stopped for cpu%d (cluster %d)", policy->cpu, cl->id);

out:
	mutex_unlock(&gov.gov_lock);
}

/**
 * sl_gov_limits() - handle external policy->max/min changes
 *
 * Called from cpufreq core when policy limits change.
 * Recomputes our internal ceiling and re-applies thermal.
 * Frequency is applied AFTER releasing cl->lock to avoid sleeping
 * in atomic context.
 */
void sl_gov_limits(struct cpufreq_policy *policy)
{
	struct sl_cluster *cl;
	unsigned long flags;
	long cur_temp;
	u32 freq;

	cl = sl_cluster_for_policy(policy);
	if (unlikely(!cl))
		return;

	/* Re-clamp our internal max index to the new policy->max */
	spin_lock_irqsave(&cl->lock, flags);

	cl->nr_freqs = (cl->id == SL_CLUSTER_BIG)
		? SL_BIG_NR_FREQS
		: SL_LITTLE_NR_FREQS;

	if (policy->max < cl->freqs[cl->nr_freqs - 1]) {
		u32 new_max = sl_nearest_idx(cl, policy->max);

		cl->cur_idx = min_t(u32, cl->cur_idx, new_max);
	}

	spin_unlock_irqrestore(&cl->lock, flags);

	/* Read temperature snapshot */
	spin_lock_irqsave(&gov.temp_lock, flags);
	cur_temp = gov.cur_temp;
	spin_unlock_irqrestore(&gov.temp_lock, flags);

	/* Re-apply thermal — decision under lock, application outside */
	spin_lock_irqsave(&cl->lock, flags);
	freq = sl_apply_thermal(cl, cur_temp);
	spin_unlock_irqrestore(&cl->lock, flags);

	if (freq)
		sl_set_freq(cl, freq);
}

/* ------------------------------------------------------------------ */
/*  cpufreq governor descriptor                                        */
/* ------------------------------------------------------------------ */

static struct cpufreq_governor cpufreq_gov_schedlancer = {
	.name             = "schedlancer",
	.init             = sl_gov_init,
	.exit             = sl_gov_exit,
	.start            = sl_gov_start,
	.stop             = sl_gov_stop,
	.limits           = sl_gov_limits,
	.owner            = THIS_MODULE,
};

/* ------------------------------------------------------------------ */
/*  Cluster initialisation                                              */
/* ------------------------------------------------------------------ */

static void sl_init_cluster(struct sl_cluster *cl,
			    enum sl_cluster_id id,
			    int policy_cpu,
			    const u32 *freqs,
			    u32 nr_freqs)
{
	cl->id         = id;
	cl->policy_cpu = policy_cpu;
	cl->freqs      = freqs;
	cl->nr_freqs   = nr_freqs;

	spin_lock_init(&cl->lock);
	mutex_init(&cl->tunables_lock);
	atomic_set(&cl->idle, 0);
	RCU_INIT_POINTER(cl->policy, NULL);
	WRITE_ONCE(cl->gov_enabled, false);
	cl->throttled     = false;
	cl->cur_idx       = nr_freqs - 1;
	cl->throttled_idx = nr_freqs - 1;

	if (id == SL_CLUSTER_LITTLE) {
		cl->tunables = (struct sl_tunables){
			.throttle_temp    = SL_THROTTLE_TEMP_LITTLE,
			.temp_diff        = SL_TEMP_DIFF_LITTLE,
			.hysteresis       = SL_HYSTERESIS_LITTLE,
			.max_throttle_idx = SL_MAX_THROTTLE_IDX_LITTLE,
			.idle_threshold   = SL_IDLE_THRESHOLD_LITTLE,
			.idle_freq_khz    = SL_IDLE_FREQ_LITTLE,
		};
	} else {
		cl->tunables = (struct sl_tunables){
			.throttle_temp    = SL_THROTTLE_TEMP_BIG,
			.temp_diff        = SL_TEMP_DIFF_BIG,
			.hysteresis       = SL_HYSTERESIS_BIG,
			.max_throttle_idx = SL_MAX_THROTTLE_IDX_BIG,
			.idle_threshold   = SL_IDLE_THRESHOLD_BIG,
			.idle_freq_khz    = SL_IDLE_FREQ_BIG,
		};
	}
}

/* ------------------------------------------------------------------ */
/*  Module init / exit                                                  */
/* ------------------------------------------------------------------ */

static int __init cpufreq_gov_schedlancer_init(void)
{
	struct sched_param param = { .sched_priority = MAX_RT_PRIO - 2 };
	int ret;

	/* Validate OPP tables at load time */
	if (!sl_validate_opp_table("little", sl_little_freqs,
				   SL_LITTLE_NR_FREQS) ||
	    !sl_validate_opp_table("big", sl_big_freqs,
				   SL_BIG_NR_FREQS)) {
		pr_err("OPP table validation failed - refusing to load\n");
		return -EINVAL;
	}

	/* Resolve thermal zone once — read-only after this point */
	gov.tz = thermal_zone_get_zone_by_name(SL_SENSOR_NAME);
	if (IS_ERR_OR_NULL(gov.tz)) {
		pr_warn("thermal zone '%s' not found, thermal throttling disabled\n",
			SL_SENSOR_NAME);
		gov.tz = NULL;
		/* Non-fatal: governor works without thermal, just no throttle */
	}

	/* Init global state */
	mutex_init(&gov.gov_lock);
	spin_lock_init(&gov.temp_lock);
	init_waitqueue_head(&gov.wq);
	atomic_set(&gov.should_wake,   0);
	atomic_set(&gov.enabled_count, 0);
	atomic_set(&gov.poll_ms, SL_POLL_ACTIVE_MS);
	gov.cur_temp  = 0;
	gov.prev_temp = 0;

	/* Init clusters */
	sl_init_cluster(&gov.clusters[SL_CLUSTER_LITTLE],
			SL_CLUSTER_LITTLE,
			SL_LITTLE_POLICY_CPU,
			sl_little_freqs,
			SL_LITTLE_NR_FREQS);

	sl_init_cluster(&gov.clusters[SL_CLUSTER_BIG],
			SL_CLUSTER_BIG,
			SL_BIG_POLICY_CPU,
			sl_big_freqs,
			SL_BIG_NR_FREQS);

	/* Spawn monitor kthread */
	gov.monitor_task = kthread_create(sl_monitor_task, NULL,
					  "schedlancer");
	if (IS_ERR(gov.monitor_task)) {
		ret = PTR_ERR(gov.monitor_task);
		pr_err("kthread_create failed: %d\n", ret);
		return ret;
	}

	sched_setscheduler_nocheck(gov.monitor_task, SCHED_FIFO, &param);
	get_task_struct(gov.monitor_task);
	wake_up_process(gov.monitor_task);

	ret = cpufreq_register_governor(&cpufreq_gov_schedlancer);
	if (ret) {
		pr_err("cpufreq_register_governor failed: %d\n", ret);
		kthread_stop(gov.monitor_task);
		put_task_struct(gov.monitor_task);
		return ret;
	}

	pr_info("v4 loaded - %u little OPPs, %u big OPPs, thermal zone: %s\n",
		(u32)SL_LITTLE_NR_FREQS, (u32)SL_BIG_NR_FREQS,
		gov.tz ? SL_SENSOR_NAME : "none");
	return 0;
}

static void __exit cpufreq_gov_schedlancer_exit(void)
{
	cpufreq_unregister_governor(&cpufreq_gov_schedlancer);

	/* Wake kthread so it sees kthread_should_stop() */
	atomic_set(&gov.should_wake, 1);
	wake_up_interruptible(&gov.wq);

	kthread_stop(gov.monitor_task);
	put_task_struct(gov.monitor_task);

	/* Final RCU grace period — all readers guaranteed done */
	synchronize_rcu();

	pr_info("unloaded\n");
}

MODULE_AUTHOR("0xArCHDeViL");
MODULE_DESCRIPTION("Schedlancer CPUFreq Governor v4");
MODULE_LICENSE("GPL v2");

module_init(cpufreq_gov_schedlancer_init);
module_exit(cpufreq_gov_schedlancer_exit);
