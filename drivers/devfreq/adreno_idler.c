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
 */

#include <linux/module.h>
#include <linux/devfreq.h>
#include <linux/atomic.h>
#include <linux/msm_adreno_devfreq.h>

#define ADRENO_IDLER_MAJOR_VERSION 1
#define ADRENO_IDLER_MINOR_VERSION 1

/*
 * stats.busy_time threshold for determining if the given workload is idle.
 * Any workload higher than this will be treated as a non-idle workload.
 * Adreno idler will more actively try to ramp down the frequency
 * if this is set to a higher value.
 */
static unsigned long idleworkload = 4500;
module_param_named(adreno_idler_idleworkload, idleworkload, ulong, 0664);

/*
 * Number of consecutive idle events required before ramping down frequency.
 * The last idlewait events must all be idle before Adreno idler ramps down.
 * This prevents micro-lags during scrolling or gaming.
 * Adreno idler will more actively try to ramp down the frequency
 * if this is set to a lower value.
 */
static unsigned int idlewait = 15;
module_param_named(adreno_idler_idlewait, idlewait, uint, 0664);

/* Taken from ondemand */
static unsigned int downdifferential = 20;
module_param_named(adreno_idler_downdifferential, downdifferential, uint, 0664);

/* Master switch to activate the whole routine */
static bool adreno_idler_active;
module_param_named(adreno_idler_active, adreno_idler_active, bool, 0664);

/*
 * Consecutive idle event counter.
 * Using atomic_t for safe access from concurrent sysfs writes to params
 * and governor callback path.
 */
static atomic_t idlecount = ATOMIC_INIT(0);

int adreno_idler(struct devfreq_dev_status stats, struct devfreq *devfreq,
		 unsigned long *freq)
{
	unsigned int cur_idlewait, cur_downdifferential;
	unsigned long cur_idleworkload;
	unsigned long lowest_freq;
	int count;

	/* Snapshot module_params via READ_ONCE to guard against compiler
	 * reordering and torn reads from concurrent sysfs writes. */
	if (!READ_ONCE(adreno_idler_active))
		return 0;

	/* Defensive: validate devfreq profile and freq_table before access */
	if (unlikely(!devfreq || !devfreq->profile ||
		     !devfreq->profile->freq_table ||
		     devfreq->profile->max_state == 0))
		return 0;

	cur_idleworkload   = READ_ONCE(idleworkload);
	cur_idlewait       = READ_ONCE(idlewait);
	cur_downdifferential = READ_ONCE(downdifferential);

	lowest_freq =
		devfreq->profile->freq_table[devfreq->profile->max_state - 1];

	if (stats.busy_time < cur_idleworkload) {
		/*
		 * Idle workload detected. Increment counter but cap it at
		 * cur_idlewait to prevent unbounded growth during prolonged
		 * idle periods.
		 */
		count = atomic_inc_return(&idlecount);
		if (count > (int)cur_idlewait)
			atomic_set(&idlecount, (int)cur_idlewait);

		if (*freq == lowest_freq) {
			/* Already at lowest frequency, nothing to do. */
			return 1;
		}

		/*
		 * Ramp down if we've been idle for cur_idlewait consecutive
		 * events AND the busy ratio is below the down differential.
		 *
		 * Use u64 multiplication to prevent overflow of busy_time * 100
		 * on 32-bit where unsigned long is 32 bits.
		 *
		 * Guard against total_time == 0 to avoid a meaningless
		 * comparison (can occur on the very first sample).
		 */
		if (count >= (int)cur_idlewait && stats.total_time > 0 &&
		    (u64)stats.busy_time * 100 <
		    (u64)stats.total_time * cur_downdifferential) {
			*freq = lowest_freq;
			/*
			 * Reset to (cur_idlewait - 1) rather than decrementing
			 * by 1. This preserves hysteresis: the next idle event
			 * will not immediately trigger another ramp-down, but
			 * one more idle sample suffices — regardless of how far
			 * above cur_idlewait the counter had grown.
			 */
			atomic_set(&idlecount,
				   (int)cur_idlewait > 0 ?
				   (int)cur_idlewait - 1 : 0);
			return 1;
		}
	} else {
		/*
		 * Non-idle workload. Reset counter and let the TZ governor
		 * determine the appropriate frequency for the current load.
		 * Do not return 1 here — allow the rest of the algorithm to
		 * run, as it may even select the lowest frequency.
		 */
		atomic_set(&idlecount, 0);
	}

	return 0;
}
EXPORT_SYMBOL(adreno_idler);

static int __init adreno_idler_init(void)
{
	pr_info("adreno_idler: version %d.%d by arter97\n",
		ADRENO_IDLER_MAJOR_VERSION,
		ADRENO_IDLER_MINOR_VERSION);

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
