/*
 * Author: Park Ju Hyung aka arter97 <qkrwngud825@gmail.com>
 *
 * Copyright 2015 Park Ju Hyung
 *
 * This software is licensed under the terms of the GNU General Public
 * License version 2, as published by the Free Software Foundation, and
 * may be copied, distributed, and modified under those terms.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 */

/*
 * Adreno idler - Idling algorithm,
 * an efficient workaround for msm-adreno-tz's overheads.
 *
 * Main goal is to lower power consumption while maintaining high performance.
 *
 * Since msm-adreno-tz tends to *not* use the lowest frequency even on idle,
 * Adreno idler replaces msm-adreno-tz's algorithm when it comes to
 * calculating idle frequency (mostly by ondemand's method).
 * The higher frequencies are not touched with this algorithm, so high-demanding
 * games will (most likely) not suffer from worsened performance.
 *
 * Design principles (v2.1):
 *   - Tunables and the hot counter live on SEPARATE cache lines to prevent
 *     false sharing: tunables are written only from sysfs (cold path),
 *     idlecount is written on every governor callback (hot path).
 *   - atomic_long_t is used for idleworkload so the type width matches
 *     'unsigned long' on both 32- and 64-bit kernels.
 *   - Capped increment uses atomic_inc_return + conditional atomic_set —
 *     cheaper than a cmpxchg retry loop when contention is low.
 *   - All sysfs param_ops validate input ranges before writing; zero or
 *     out-of-range values are rejected with -EINVAL.
 *   - No locks are taken in the governor hot path.
 */

#include <linux/module.h>
#include <linux/devfreq.h>
#include <linux/atomic.h>
#include <linux/cache.h>
#include <linux/msm_adreno_devfreq.h>

#define ADRENO_IDLER_MAJOR_VERSION 2
#define ADRENO_IDLER_MINOR_VERSION 1

/* ------------------------------------------------------------------ */
/*  Two separate cache-line-aligned structs:                           */
/*    ai_tunables — read-mostly, written only from sysfs (cold).      */
/*    ai_counter  — written on every governor callback (hot).         */
/*                                                                     */
/*  Keeping them on separate cache lines ensures that a CPU writing   */
/*  idlecount does not invalidate the cache line that other CPUs are  */
/*  reading tunables from.                                            */
/* ------------------------------------------------------------------ */

struct adreno_idler_tunables {
	/*
	 * stats.busy_time threshold for determining if the given workload
	 * is idle.  Any workload >= this is treated as non-idle.
	 * Higher value → more aggressive ramp-down.
	 * Type: atomic_long_t so the width matches 'unsigned long' on
	 * both 32- and 64-bit builds.
	 */
	atomic_long_t	idleworkload;

	/*
	 * Number of consecutive idle events required before ramping down.
	 * Must be >= 1.  Lower value → more aggressive ramp-down.
	 */
	atomic_t	idlewait;

	/*
	 * Down-differential threshold (1–100 percent).
	 * Ramp-down only occurs when:
	 *   busy_time * 100 < total_time * downdifferential
	 * Must be in [1, 100].
	 */
	atomic_t	downdifferential;

	/*
	 * Master switch.  1 = active, 0 = bypass.
	 * Using atomic_t for atomic_read/atomic_set symmetry.
	 */
	atomic_t	active;
} ____cacheline_aligned;

struct adreno_idler_counter {
	/*
	 * Consecutive idle-event counter.
	 * Capped at idlewait to prevent unbounded growth.
	 * Isolated on its own cache line — written on every hot-path call.
	 */
	atomic_t	idlecount;
} ____cacheline_aligned;

static struct adreno_idler_tunables ai_tunables = {
	.idleworkload	  = ATOMIC_LONG_INIT(CONFIG_ADRENO_IDLER_IDLEWORKLOAD),
	.idlewait	  = ATOMIC_INIT(CONFIG_ADRENO_IDLER_IDLEWAIT),
	.downdifferential = ATOMIC_INIT(CONFIG_ADRENO_IDLER_DOWNDIFFERENTIAL),
#ifdef CONFIG_ADRENO_IDLER_ACTIVE
	.active		  = ATOMIC_INIT(1),
#else
	.active		  = ATOMIC_INIT(0),
#endif
};

static struct adreno_idler_counter ai_counter = {
	.idlecount = ATOMIC_INIT(0),
};

/* ------------------------------------------------------------------ */
/*  module_param wrappers — validate then atomic-set.                 */
/* ------------------------------------------------------------------ */

static int param_set_idleworkload(const char *val,
				  const struct kernel_param *kp)
{
	unsigned long v;
	int ret = kstrtoul(val, 0, &v);

	if (ret)
		return ret;
	/* Any non-zero workload threshold is valid. */
	if (v == 0)
		return -EINVAL;
	atomic_long_set(&ai_tunables.idleworkload, (long)v);
	return 0;
}

static int param_get_idleworkload(char *buf, const struct kernel_param *kp)
{
	return scnprintf(buf, PAGE_SIZE, "%lu\n",
			 (unsigned long)atomic_long_read(&ai_tunables.idleworkload));
}

static const struct kernel_param_ops idleworkload_ops = {
	.set = param_set_idleworkload,
	.get = param_get_idleworkload,
};
module_param_cb(adreno_idler_idleworkload, &idleworkload_ops, NULL, 0664);

/* --- idlewait --- */
static int param_set_idlewait(const char *val, const struct kernel_param *kp)
{
	unsigned int v;
	int ret = kstrtouint(val, 0, &v);

	if (ret)
		return ret;
	/*
	 * idlewait == 0 would make the ramp-down condition (cur >= 0)
	 * permanently true, causing a ramp-down on every idle sample
	 * and severe stuttering.  Reject it.
	 */
	if (v == 0)
		return -EINVAL;
	atomic_set(&ai_tunables.idlewait, (int)v);
	return 0;
}

static int param_get_idlewait(char *buf, const struct kernel_param *kp)
{
	return scnprintf(buf, PAGE_SIZE, "%u\n",
			 (unsigned int)atomic_read(&ai_tunables.idlewait));
}

static const struct kernel_param_ops idlewait_ops = {
	.set = param_set_idlewait,
	.get = param_get_idlewait,
};
module_param_cb(adreno_idler_idlewait, &idlewait_ops, NULL, 0664);

/* --- downdifferential --- */
static int param_set_downdiff(const char *val, const struct kernel_param *kp)
{
	unsigned int v;
	int ret = kstrtouint(val, 0, &v);

	if (ret)
		return ret;
	/*
	 * downdifferential == 0 makes the ramp-down condition
	 *   busy_time * 100 < total_time * 0
	 * always false — the governor silently stops working.
	 * Values > 100 are semantically nonsensical (>100% busy).
	 * Reject both.
	 */
	if (v == 0 || v > 100)
		return -EINVAL;
	atomic_set(&ai_tunables.downdifferential, (int)v);
	return 0;
}

static int param_get_downdiff(char *buf, const struct kernel_param *kp)
{
	return scnprintf(buf, PAGE_SIZE, "%u\n",
			 (unsigned int)atomic_read(&ai_tunables.downdifferential));
}

static const struct kernel_param_ops downdiff_ops = {
	.set = param_set_downdiff,
	.get = param_get_downdiff,
};
module_param_cb(adreno_idler_downdifferential, &downdiff_ops, NULL, 0664);

/* --- active --- */
static int param_set_active(const char *val, const struct kernel_param *kp)
{
	bool v;
	int ret = kstrtobool(val, &v);

	if (ret)
		return ret;
	atomic_set(&ai_tunables.active, v ? 1 : 0);
	return 0;
}

static int param_get_active(char *buf, const struct kernel_param *kp)
{
	/*
	 * Output "Y"/"N" to match the kernel convention for bool
	 * module_params (e.g. /sys/module/<name>/parameters/).
	 */
	return scnprintf(buf, PAGE_SIZE, "%c\n",
			 atomic_read(&ai_tunables.active) ? 'Y' : 'N');
}

static const struct kernel_param_ops active_ops = {
	.set = param_set_active,
	.get = param_get_active,
};
module_param_cb(adreno_idler_active, &active_ops, NULL, 0664);

/* ------------------------------------------------------------------ */
/*  Governor hot path                                                  */
/* ------------------------------------------------------------------ */

/**
 * adreno_idler - Idle-frequency override for msm-adreno-tz.
 *
 * Called from tz_get_target_freq() on every devfreq sample.
 * Returns 1 to signal that @freq has been set and TZ should bail out,
 * or 0 to let TZ continue its own algorithm.
 *
 * Thread-safety: tunables are read via atomic_read (no lock, no torn
 * read).  idlecount is mutated via atomic_inc_return / atomic_set,
 * which are individually atomic.  The combination is intentionally
 * not a single transaction — a race between two CPUs incrementing
 * idlecount simultaneously can produce a count one higher than the
 * cap for one sample, which is harmless given the subsequent clamp.
 */
int adreno_idler(struct devfreq_dev_status stats, struct devfreq *devfreq,
		 unsigned long *freq)
{
	unsigned long cur_idleworkload;
	unsigned int  cur_idlewait;
	unsigned int  cur_downdiff;
	unsigned long lowest_freq;
	int count;

	/* Fast-path exit when the feature is disabled. */
	if (!atomic_read(&ai_tunables.active))
		return 0;

	/* Defensive: profile and freq_table must be valid. */
	if (unlikely(!devfreq || !devfreq->profile ||
		     !devfreq->profile->freq_table ||
		     devfreq->profile->max_state == 0))
		return 0;

	/* Snapshot all tunables — one atomic load each, no lock. */
	cur_idleworkload = (unsigned long)atomic_long_read(&ai_tunables.idleworkload);
	cur_idlewait     = (unsigned int)atomic_read(&ai_tunables.idlewait);
	cur_downdiff     = (unsigned int)atomic_read(&ai_tunables.downdifferential);

	lowest_freq =
		devfreq->profile->freq_table[devfreq->profile->max_state - 1];

	if (stats.busy_time < cur_idleworkload) {
		/*
		 * Idle workload.  Increment idlecount and cap it at
		 * cur_idlewait to prevent unbounded growth.
		 *
		 * atomic_inc_return is cheaper than a cmpxchg retry loop
		 * under typical low-contention conditions.  A transient
		 * overshoot past the cap by one on concurrent access is
		 * harmless: the clamp below corrects it for the local copy
		 * used in the ramp-down decision, and the next sample will
		 * write the correct capped value back.
		 */
		count = atomic_inc_return(&ai_counter.idlecount);
		if (count > (int)cur_idlewait) {
			atomic_set(&ai_counter.idlecount, (int)cur_idlewait);
			count = (int)cur_idlewait;
		}

		if (*freq == lowest_freq) {
			/* Already at the floor — nothing to do. */
			return 1;
		}

		/*
		 * Ramp down if we have accumulated cur_idlewait consecutive
		 * idle events AND the busy ratio is below the
		 * down-differential threshold.
		 *
		 * u64 multiply prevents overflow of busy_time * 100 on
		 * 32-bit kernels where unsigned long is only 32 bits wide.
		 *
		 * total_time == 0 guard covers the first sample after resume.
		 *
		 * cur_idlewait is guaranteed >= 1 by param validation, so
		 * the count >= cur_idlewait check is always well-defined.
		 */
		if (count >= (int)cur_idlewait && stats.total_time > 0 &&
		    (u64)stats.busy_time * 100 <
		    (u64)stats.total_time * cur_downdiff) {
			*freq = lowest_freq;
			/*
			 * Reset to (cur_idlewait - 1) to preserve hysteresis:
			 * one more idle sample suffices for the next ramp-down
			 * without requiring a full re-accumulation from zero.
			 * cur_idlewait >= 1, so this is always >= 0.
			 */
			atomic_set(&ai_counter.idlecount,
				   (int)cur_idlewait - 1);
			return 1;
		}
	} else {
		/*
		 * Non-idle workload.  Reset counter and yield to TZ so it
		 * can select the appropriate frequency for the current load.
		 * Do NOT return 1 — TZ may still pick the lowest frequency.
		 */
		atomic_set(&ai_counter.idlecount, 0);
	}

	return 0;
}
EXPORT_SYMBOL(adreno_idler);

static int __init adreno_idler_init(void)
{
	pr_info("adreno_idler: version %d.%d by arter97\n",
		ADRENO_IDLER_MAJOR_VERSION,
		ADRENO_IDLER_MINOR_VERSION);
	pr_info("adreno_idler: active=%c idleworkload=%lu idlewait=%u downdiff=%u\n",
		atomic_read(&ai_tunables.active) ? 'Y' : 'N',
		(unsigned long)atomic_long_read(&ai_tunables.idleworkload),
		(unsigned int)atomic_read(&ai_tunables.idlewait),
		(unsigned int)atomic_read(&ai_tunables.downdifferential));
	return 0;
}
subsys_initcall(adreno_idler_init);

static void __exit adreno_idler_exit(void)
{
}
module_exit(adreno_idler_exit);

MODULE_AUTHOR("Park Ju Hyung <qkrwngud825@gmail.com>");
MODULE_DESCRIPTION("adreno_idler - A powersaver for Adreno TZ "
		   "Control idle algorithm for Adreno GPU series");
MODULE_LICENSE("GPL");
