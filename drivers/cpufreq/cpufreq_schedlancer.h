/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * cpufreq_schedlancer.h — Schedlancer CPUFreq Governor v4
 *
 * Thermal-aware, idle-aware cpufreq governor for SM6150.
 *
 *   - Hardcoded OPP tables (no runtime cpufreq_frequency_get_table dependency)
 *   - Deferred frequency application: decisions under spinlock, driver calls
 *     outside — zero sleeping-in-atomic-context risk
 *   - Temperature hysteresis to prevent freq oscillation
 *   - Per-cluster idle detection with single-threaded-task bias
 *   - Cache-line aligned hot/cold struct separation
 *   - READ_ONCE/WRITE_ONCE on all locklessly-accessed shared state
 *   - Signed temperature arithmetic throughout (no u32 cast bugs)
 *   - Runtime OPP table validation at init
 *
 * Author: 0xArCHDeViL
 */

#ifndef _CPUFREQ_SCHEDLANCER_H_
#define _CPUFREQ_SCHEDLANCER_H_

#include <linux/atomic.h>
#include <linux/cache.h>
#include <linux/compiler.h>
#include <linux/cpufreq.h>
#include <linux/mutex.h>
#include <linux/spinlock.h>
#include <linux/thermal.h>
#include <linux/wait.h>
#include <linux/types.h>

/* ------------------------------------------------------------------ */
/*  Debug                                                               */
/* ------------------------------------------------------------------ */

#ifdef CONFIG_CPU_FREQ_GOV_SCHEDLANCER_DEBUG
# define SL_DEBUG 1
#else
# define SL_DEBUG 0
#endif

#define sl_dbg(fmt, ...)					\
	do {							\
		if (SL_DEBUG)					\
			pr_info("SL: " fmt "\n", ##__VA_ARGS__);	\
	} while (0)

/* ------------------------------------------------------------------ */
/*  SM6150 topology                                                     */
/* ------------------------------------------------------------------ */

/*
 * SM6150 topology:
 *   Little cluster: CPU 0-5  (Cortex-A55)
 *   Big   cluster: CPU 6-7  (Cortex-A76)
 *
 * Policy CPUs (first CPU of each cluster's policy):
 *   Little: CPU 0
 *   Big:    CPU 6
 */
#define SL_LITTLE_POLICY_CPU	0
#define SL_BIG_POLICY_CPU	6
#define SL_NR_CLUSTERS		2

/* ------------------------------------------------------------------ */
/*  OPP tables — hardcoded for SM6150                                  */
/* ------------------------------------------------------------------ */

/* Little cluster (Cortex-A55), units: kHz, ascending order */
static const u32 sl_little_freqs[] = {
	 300000,  576000,  768000, 1017600,
	1248000, 1324800, 1497600, 1612800,
	1708800, 1804800,
};
#define SL_LITTLE_NR_FREQS	ARRAY_SIZE(sl_little_freqs)
#define SL_LITTLE_MAX_IDX	(SL_LITTLE_NR_FREQS - 1)

/* Big cluster (Cortex-A76), units: kHz, ascending order */
static const u32 sl_big_freqs[] = {
	 300000,  652800,  806400,  979200,
	1094400, 1209600, 1324800, 1555200,
	1708800, 1843200, 1939200, 2169600,
	2208000, 2304000,
};
#define SL_BIG_NR_FREQS		ARRAY_SIZE(sl_big_freqs)
#define SL_BIG_MAX_IDX		(SL_BIG_NR_FREQS - 1)

/* ------------------------------------------------------------------ */
/*  Thermal sensor                                                      */
/* ------------------------------------------------------------------ */

/*
 * SM6150 TSENS zone name used for CPU temperature.
 * thermal_zone_get_temp() returns millidegrees Celsius in this kernel.
 * All internal comparisons are therefore in millidegrees.
 */
#define SL_SENSOR_NAME		"cpu-0-0-usr"

/*
 * Temperature sanity bounds (m°C) — reject readings outside this range.
 * -40 000 m°C to 150 000 m°C.
 */
#define SL_TEMP_SANE_MIN	(-40000L)
#define SL_TEMP_SANE_MAX	(150000L)

/* ------------------------------------------------------------------ */
/*  Default tunables (millidegrees)                                    */
/* ------------------------------------------------------------------ */

/*
 * Thermal — stored as u32 in tunables (m°C), cast to long for comparison.
 *
 * A55 little cores are efficient (~0.3W at max) — high trip gives them
 * headroom.  A76 big cores are power-hungry (~2W at max) — lower trip
 * throttles them first, saving the most energy per degree.
 */
#define SL_THROTTLE_TEMP_LITTLE		48000	/* m°C trip point, little */
#define SL_THROTTLE_TEMP_BIG		43000	/* m°C trip point, big    */
#define SL_TEMP_DIFF_LITTLE		4000	/* m°C per throttle step  */
#define SL_TEMP_DIFF_BIG		2000	/* m°C per throttle step  */
#define SL_HYSTERESIS_LITTLE		3000	/* m°C deadband           */
#define SL_HYSTERESIS_BIG		3000

/*
 * Max throttle depth (OPP index floor).
 * A55 at 768 MHz still handles UI/background smoothly.
 * A76 at 1.2 GHz is fast enough for sustained workloads.
 */
#define SL_MAX_THROTTLE_IDX_LITTLE	2	/* floor = sl_little_freqs[2] =  768000 */
#define SL_MAX_THROTTLE_IDX_BIG		5	/* floor = sl_big_freqs[5]    = 1209600 */

/*
 * Idle.
 * Little idle_freq at 576 MHz instead of 300 MHz: the power difference
 * is ~15 mW on A55, but wake-from-idle responsiveness (touch, input)
 * improves significantly.  Big cores get minimum — no reason to keep
 * an idle A76 spinning fast.
 */
#define SL_IDLE_THRESHOLD_LITTLE	40	/* % avg cluster load      */
#define SL_IDLE_THRESHOLD_BIG		25
#define SL_IDLE_FREQ_LITTLE		sl_little_freqs[1]	/* 576 MHz */
#define SL_IDLE_FREQ_BIG		sl_big_freqs[0]		/* 300 MHz */

/* Single-core busy bias: if any core >= this %, don't idle the cluster */
#define SL_SINGLE_CORE_BUSY_PCT		60U

/* Polling intervals (ms) */
#define SL_POLL_ACTIVE_MS		1500
#define SL_POLL_IDLE_MS			500

/* ------------------------------------------------------------------ */
/*  Cluster index enum                                                  */
/* ------------------------------------------------------------------ */

enum sl_cluster_id {
	SL_CLUSTER_LITTLE = 0,
	SL_CLUSTER_BIG    = 1,
};

/* ------------------------------------------------------------------ */
/*  Per-cluster tunables (userspace-writable via sysfs)                */
/* ------------------------------------------------------------------ */

struct sl_tunables {
	/*
	 * Thermal knobs — u32 storage in m°C, cast to long for signed
	 * comparison against thermal_zone_get_temp() output.
	 */
	u32 throttle_temp;	/* m°C: trip point          */
	u32 temp_diff;		/* m°C: step size (min 1)   */
	u32 hysteresis;		/* m°C: unthrottle guard    */
	u32 max_throttle_idx;	/* freq table floor index   */

	/* Idle knobs */
	u32 idle_threshold;	/* % avg load for idle      */
	u32 idle_freq_khz;	/* kHz during idle          */
};

/* ------------------------------------------------------------------ */
/*  Per-CPU load tracking                                               */
/* ------------------------------------------------------------------ */

struct sl_cpu_load {
	u64 prev_wall;
	u64 prev_idle;
};

/* ------------------------------------------------------------------ */
/*  Per-cluster state                                                   */
/*                                                                      */
/*  Layout is split across cache lines to reduce false sharing:         */
/*    Line 1: read-mostly identity + OPP pointer                        */
/*    Line 2: read-write hot state (spinlock, indices, flags)           */
/*    Line 3: slow-path tunables (mutex + struct)                       */
/* ------------------------------------------------------------------ */

struct sl_cluster {
	/* --- Read-mostly identity (set once at init, never mutated) --- */
	enum sl_cluster_id	id;
	int			policy_cpu;
	const u32		*freqs;
	u32			nr_freqs;

	/* --- Hot-path mutable state (kthread + governor callbacks) --- */
	spinlock_t		lock ____cacheline_aligned_in_smp;
	u32			cur_idx;	/* current OPP index         */
	u32			throttled_idx;	/* thermal target index      */
	bool			throttled;	/* true if above trip point  */
	bool			gov_enabled;	/* READ_ONCE/WRITE_ONCE only */

	/* Idle — atomic for lockless read in kthread fast path */
	atomic_t		idle;

	/* --- Slow-path tunables (sysfs reads/writes) --- */
	struct mutex		tunables_lock ____cacheline_aligned_in_smp;
	struct sl_tunables	tunables;

	/* cpufreq policy — RCU-protected, set on start, cleared on stop.
	 * rcu_assign_pointer() for writes, rcu_dereference() for reads.
	 */
	struct cpufreq_policy __rcu *policy;
};

/* ------------------------------------------------------------------ */
/*  Global governor state                                               */
/* ------------------------------------------------------------------ */

struct sl_governor {
	struct sl_cluster	clusters[SL_NR_CLUSTERS];

	/*
	 * Temperature — protected by temp_lock (only written by kthread,
	 * read by kthread + limits callback).
	 * Values are in millidegrees Celsius (as returned by
	 * thermal_zone_get_temp()).
	 */
	spinlock_t		temp_lock ____cacheline_aligned_in_smp;
	long			cur_temp;
	long			prev_temp;

	/*
	 * Thermal zone device — resolved once at module_init by name,
	 * then used read-only.  No locking needed after init.
	 */
	struct thermal_zone_device *tz;

	/* kthread control */
	struct task_struct	*monitor_task;
	wait_queue_head_t	wq;
	atomic_t		should_wake;
	atomic_t		enabled_count;

	/* Adaptive poll interval (ms) */
	atomic_t		poll_ms;

	/* Serializes start/stop to prevent concurrent races per cluster */
	struct mutex		gov_lock;
};

/* ------------------------------------------------------------------ */
/*  Function prototypes                                                 */
/* ------------------------------------------------------------------ */

/* Governor lifecycle — wired to cpufreq_governor .init/.exit/.start/.stop/.limits */
int  sl_gov_init(struct cpufreq_policy *policy);
void sl_gov_exit(struct cpufreq_policy *policy);
int  sl_gov_start(struct cpufreq_policy *policy);
void sl_gov_stop(struct cpufreq_policy *policy);
void sl_gov_limits(struct cpufreq_policy *policy);

/* Thermal */
int  sl_update_sensor(void);

/*
 * sl_apply_thermal() - compute thermally-limited OPP index
 *
 * Must be called with cl->lock held.
 * Returns: target frequency in kHz if a change is needed, 0 otherwise.
 * Caller must apply the returned frequency AFTER releasing cl->lock
 * via sl_set_freq().
 */
u32  sl_apply_thermal(struct sl_cluster *cl, long temp);

/* Idle */
int  sl_get_cpu_load(int cpu, struct sl_cpu_load *pcpu);
void sl_check_idle(struct sl_cluster *cl);

/* Frequency application — must NOT be called with cl->lock held.
 * Uses RCU internally for safe policy access.
 */
void sl_set_freq(struct sl_cluster *cl, u32 freq_khz);

/* Sysfs */
int  sl_sysfs_register(struct cpufreq_policy *policy, struct sl_cluster *cl);
void sl_sysfs_unregister(struct cpufreq_policy *policy);

#endif /* _CPUFREQ_SCHEDLANCER_H_ */
