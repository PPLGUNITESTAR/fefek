// SPDX-License-Identifier: GPL-2.0
/*
 * Copyright (C) 2023-2024 Sultan Alsawaf <sultan@kerneltoast.com>.
 */

/**
 * DOC: SBalance description
 *
 * This is a simple IRQ balancer that polls every X number of milliseconds and
 * moves IRQs from the most interrupt-heavy CPU to the least interrupt-heavy
 * CPUs until the heaviest CPU is no longer the heaviest. IRQs are only moved
 * from one source CPU to any number of destination CPUs per balance run.
 * Balancing is skipped if the gap between the most interrupt-heavy CPU and the
 * least interrupt-heavy CPU is below the configured threshold of interrupts.
 *
 * The heaviest IRQs are targeted for migration in order to reduce the number of
 * IRQs to migrate. If moving an IRQ would reduce overall balance, then it won't
 * be migrated.
 *
 * The most interrupt-heavy CPU is calculated by scaling the number of new
 * interrupts on that CPU to the CPU's current capacity. This way, interrupt
 * heaviness takes into account factors such as thermal pressure and time spent
 * processing interrupts rather than just the sheer number of them. This also
 * makes SBalance aware of CPU asymmetry, where different CPUs can have
 * different performance capacities and be proportionally balanced.
 *
 * Changes from the original (v2):
 *  - bal_irq_move_node_cmp: replaced unsigned subtraction (wraps on overflow)
 *    with an explicit three-way compare so list_sort always receives a correct
 *    signed ordering.
 *  - update_irq_data: zero delta_nr when resetting old_nr so stale deltas
 *    never leak into the move-node list on the next run.
 *  - scale_intrs: guard against cpu_cap == 0 (CPU just onlined, capacity not
 *    yet populated) to prevent a division-by-zero trap.
 *  - sbalance_wait: made process_timer per-invocation (stack-allocated) so
 *    there is no shared static state that could be clobbered if the kthread
 *    is ever woken spuriously while the timer is live.
 *  - balance_irqs: cpumask moved off static storage onto the stack so it is
 *    logically scoped to a single invocation, removing the latent risk from
 *    a future second caller.
 *  - sbalance_init: replaced BUG_ON(IS_ERR(...)) with a pr_err + return so a
 *    kthread allocation failure does not panic the kernel unnecessarily.
 *  - CPU-exclude mask: initialised explicitly to CPU_MASK_NONE instead of
 *    relying on cpulist_parse("") succeeding with an empty string.
 */

#define pr_fmt(fmt) "sbalance: " fmt

#include <linux/freezer.h>
#include <linux/irq.h>
#include <linux/list_sort.h>
#include "../sched/sched.h"
#include "internals.h"

/* Perform IRQ balancing every POLL_MS milliseconds */
#define POLL_MS 10

/*
 * There needs to be a difference of at least this many new interrupts between
 * the heaviest and least-heavy CPUs during the last polling window in order for
 * balancing to occur. This is to avoid balancing when the system is quiet.
 *
 * This threshold is compared to the _scaled_ interrupt counts per CPU; i.e.,
 * the number of interrupts scaled to the CPU's capacity.
 */
#define IRQ_SCALED_THRESH 10

struct bal_irq {
	struct list_head node;
	struct list_head move_node;
	struct rcu_head rcu;
	struct irq_desc *desc;
	unsigned int delta_nr;
	unsigned int old_nr;
	int prev_cpu;
};

struct bal_domain {
	struct list_head movable_irqs;
	unsigned long old_total;
	unsigned int intrs;
	int cpu;
};

static LIST_HEAD(bal_irq_list);
static DEFINE_SPINLOCK(bal_irq_lock);
static DEFINE_PER_CPU(struct bal_domain, balance_data);
static DEFINE_PER_CPU(unsigned long, cpu_cap);
static cpumask_t cpu_exclude_mask __read_mostly;

void sbalance_desc_add(struct irq_desc *desc)
{
	struct bal_irq *bi;

	bi = kmalloc(sizeof(*bi), GFP_KERNEL);
	if (WARN_ON(!bi))
		return;

	*bi = (typeof(*bi)){ .desc = desc };
	spin_lock(&bal_irq_lock);
	list_add_tail_rcu(&bi->node, &bal_irq_list);
	spin_unlock(&bal_irq_lock);
}

void sbalance_desc_del(struct irq_desc *desc)
{
	struct bal_irq *bi;

	spin_lock(&bal_irq_lock);
	list_for_each_entry(bi, &bal_irq_list, node) {
		if (bi->desc == desc) {
			list_del_rcu(&bi->node);
			kfree_rcu(bi, rcu);
			break;
		}
	}
	spin_unlock(&bal_irq_lock);
}

/*
 * Three-way compare for list_sort: returns negative if lhs should sort
 * before rhs (i.e. lhs has MORE interrupts — descending order).
 *
 * The original used unsigned subtraction (rhs->delta_nr - lhs->delta_nr)
 * which wraps when rhs < lhs and produces a large positive value instead
 * of the expected negative one, corrupting the sort order for those pairs.
 */
static int bal_irq_move_node_cmp(void *priv, struct list_head *lhs_p,
				 struct list_head *rhs_p)
{
	const struct bal_irq *lhs = list_entry(lhs_p, typeof(*lhs), move_node);
	const struct bal_irq *rhs = list_entry(rhs_p, typeof(*rhs), move_node);

	if (lhs->delta_nr > rhs->delta_nr)
		return -1;
	if (lhs->delta_nr < rhs->delta_nr)
		return 1;
	return 0;
}

/* Returns false if this IRQ should be totally ignored for this balancing run */
static bool update_irq_data(struct bal_irq *bi, int *cpu)
{
	struct irq_desc *desc = bi->desc;
	unsigned int nr;

	/*
	 * Get the CPU which currently has this IRQ affined. Due to hardware and
	 * irqchip driver quirks, a previously set affinity may not match the
	 * actual affinity of the IRQ. Therefore, we check the last CPU that the
	 * IRQ fired upon in order to determine its actual affinity.
	 */
	*cpu = READ_ONCE(desc->last_cpu);
	if (*cpu >= nr_cpu_ids)
		return false;

	/*
	 * Calculate the number of new interrupts from this IRQ. It is assumed
	 * that the IRQ has been running on the same CPU since the last
	 * balancing run. This might not hold true if the IRQ was moved by
	 * someone else since the last balancing run, or if the CPU this IRQ was
	 * previously running on has since gone offline.
	 */
	nr = *per_cpu_ptr(desc->kstat_irqs, *cpu);
	if (nr <= bi->old_nr) {
		bi->old_nr = nr;
		/*
		 * Zero delta_nr explicitly so a stale count from a previous
		 * run cannot leak into the move-node list if this entry is
		 * skipped this time but selected next time without an update.
		 */
		bi->delta_nr = 0;
		return false;
	}

	/* Calculate the number of new interrupts on this CPU from this IRQ */
	bi->delta_nr = nr - bi->old_nr;
	bi->old_nr = nr;
	return true;
}

static int move_irq_to_cpu(struct bal_irq *bi, int cpu)
{
	struct irq_desc *desc = bi->desc;
	int prev_cpu, ret;

	/* Set the affinity if it wasn't changed since we looked at it */
	raw_spin_lock_irq(&desc->lock);
	prev_cpu = cpumask_first(desc->irq_common_data.affinity);
	if (prev_cpu == bi->prev_cpu) {
		ret = irq_set_affinity_locked(&desc->irq_data, cpumask_of(cpu),
					      false);
	} else {
		bi->prev_cpu = prev_cpu;
		ret = -EINVAL;
	}
	raw_spin_unlock_irq(&desc->lock);

	if (!ret) {
		/*
		 * Anchor old_nr to the new CPU's current kstat so that the
		 * next poll counts only interrupts that fired AFTER migration.
		 * Any prior count on the destination CPU is intentionally
		 * excluded — we want delta_nr to reflect post-move activity.
		 * Counter wrap (u32) is handled by the nr <= old_nr guard in
		 * update_irq_data(), which resets tracking cleanly.
		 */
		bi->old_nr = *per_cpu_ptr(desc->kstat_irqs, cpu);
		pr_debug("Moved IRQ%d (CPU%d -> CPU%d)\n",
			 irq_desc_get_irq(desc), prev_cpu, cpu);
	}
	return ret;
}

/*
 * Scale the number of interrupts to the CPU's current capacity.
 * Returns u64 to prevent overflow: intrs (u32) * SCHED_CAPACITY_SCALE (1024)
 * can exceed UINT_MAX when intrs is large, corrupting comparisons if truncated
 * to 32 bits.
 *
 * Guard against cpu_cap == 0: a CPU that just came online may not have had
 * its capacity populated yet.  Treat it as fully capable so it is neither
 * spuriously excluded from nor targeted by balancing.
 */
static u64 scale_intrs(unsigned int intrs, int cpu)
{
	unsigned long cap = per_cpu(cpu_cap, cpu);

	if (unlikely(!cap))
		return (u64)intrs;

	return (u64)intrs * SCHED_CAPACITY_SCALE / cap;
}

/* Returns true if IRQ balancing should stop */
static bool find_min_bd(const cpumask_t *mask, u64 max_intrs,
			struct bal_domain **min_bd)
{
	u64 intrs, min_intrs = (u64)~0ULL;
	struct bal_domain *bd;
	int cpu;

	for_each_cpu(cpu, mask) {
		bd = per_cpu_ptr(&balance_data, cpu);
		intrs = scale_intrs(bd->intrs, bd->cpu);

		/* Terminate when the formerly-max CPU isn't the max anymore */
		if (intrs > max_intrs)
			return true;

		/* Don't consider moving IRQs to this CPU if it's excluded */
		if (cpumask_test_cpu(cpu, &cpu_exclude_mask))
			continue;

		/* Find the CPU with the lowest relative number of interrupts */
		if (intrs < min_intrs) {
			min_intrs = intrs;
			*min_bd = bd;
		}
	}

	/* No CPUs available to move IRQs onto */
	if (min_intrs == (u64)~0ULL)
		return true;

	/* Don't balance if IRQs are already balanced evenly enough */
	return max_intrs - min_intrs < IRQ_SCALED_THRESH;
}

static void balance_irqs(void)
{
	/*
	 * Stack-allocate cpus rather than using static storage so this
	 * function is re-entrant-safe and the mask lifetime is explicit.
	 * On this target NR_CPUS <= 8, so cpumask_t is 8 bytes on the
	 * stack — well within budget.  On configs with larger NR_CPUS the
	 * kthread stack (8–16 KB) still comfortably accommodates it.
	 */
	cpumask_t cpus;
	/*
	 * Initialise max_bd and min_bd to NULL.  Both are assigned only
	 * inside loops; NULL catches any path where the loop body is
	 * skipped, turning a silent UB dereference into a visible crash.
	 */
	struct bal_domain *bd, *max_bd = NULL, *min_bd = NULL;
	u64 intrs, max_intrs;
	bool moved_irq = false;
	struct bal_irq *bi;
	int cpu;

	cpus_read_lock();
	rcu_read_lock();

	/* Find the available CPUs for balancing, if there are any */
	cpumask_copy(&cpus, cpu_active_mask);
	if (unlikely(cpumask_weight(&cpus) <= 1))
		goto unlock;

	for_each_cpu(cpu, &cpus) {
		/*
		 * Get the current capacity for each CPU. This is adjusted for
		 * time spent processing IRQs, RT-task time, and thermal
		 * pressure. We don't exclude time spent processing IRQs when
		 * balancing because balancing is only done using interrupt
		 * counts rather than time spent in interrupts. That way, time
		 * spent processing each interrupt is considered when balancing.
		 */
		per_cpu(cpu_cap, cpu) = cpu_rq(cpu)->cpu_capacity;

		/* Get the number of new interrupts on this CPU */
		bd = per_cpu_ptr(&balance_data, cpu);
		bd->intrs = kstat_cpu_irqs_sum(cpu) - bd->old_total;
		bd->old_total += bd->intrs;
	}

	list_for_each_entry_rcu(bi, &bal_irq_list, node) {
		/* Consider this IRQ for balancing if it's movable */
		if (!__irq_can_set_affinity(bi->desc))
			continue;

		if (!update_irq_data(bi, &cpu))
			continue;

		/* Ignore for this run if the IRQ isn't on the expected CPU */
		if (cpu != bi->prev_cpu) {
			bi->prev_cpu = cpu;
			continue;
		}

		/* Add this IRQ to its CPU's list of movable IRQs */
		bd = per_cpu_ptr(&balance_data, cpu);
		list_add_tail(&bi->move_node, &bd->movable_irqs);
	}

	/* Find the most interrupt-heavy CPU with movable IRQs */
	while (1) {
		max_intrs = 0;
		for_each_cpu(cpu, &cpus) {
			bd = per_cpu_ptr(&balance_data, cpu);
			intrs = scale_intrs(bd->intrs, bd->cpu);
			if (intrs > max_intrs) {
				max_intrs = intrs;
				max_bd = bd;
			}
		}

		/*
		 * No balancing to do if all CPUs are quiet.
		 * max_bd is assigned only when intrs > 0, so this check also
		 * guarantees max_bd is non-NULL before it is dereferenced below.
		 */
		if (unlikely(!max_intrs))
			goto unlock;

		/* Ensure the heaviest CPU has IRQs which can be moved away */
		if (!list_empty(&max_bd->movable_irqs))
			break;

try_next_heaviest:
		/*
		 * If the heaviest CPU has no movable IRQs then it can neither
		 * receive IRQs nor give IRQs. Exclude it from balancing so the
		 * remaining CPUs can be balanced, if there are any.
		 */
		if (cpumask_weight(&cpus) == 2)
			goto unlock;

		__cpumask_clear_cpu(max_bd->cpu, &cpus);
	}

	/* Find the CPU with the lowest relative interrupt count */
	if (find_min_bd(&cpus, max_intrs, &min_bd))
		goto unlock;

	/* Sort movable IRQs in descending order of number of new interrupts */
	list_sort(NULL, &max_bd->movable_irqs, bal_irq_move_node_cmp);

	/* Push IRQs away from the heaviest CPU to the least-heavy CPUs */
	list_for_each_entry(bi, &max_bd->movable_irqs, move_node) {
		/* Skip this IRQ if it would just overload the target CPU */
		intrs = scale_intrs(min_bd->intrs + bi->delta_nr, min_bd->cpu);
		if (intrs >= max_intrs)
			continue;

		/* Try to migrate this IRQ, or skip it if migration fails */
		if (move_irq_to_cpu(bi, min_bd->cpu))
			continue;

		/* Keep track of whether or not any IRQs are moved */
		moved_irq = true;

		/*
		 * Update the counts and recalculate the max scaled count. The
		 * balance domain's delta interrupt count could be lower than
		 * the sum of new interrupts counted for each IRQ, since they're
		 * measured using different counters.
		 */
		min_bd->intrs += bi->delta_nr;
		max_bd->intrs -= min(bi->delta_nr, max_bd->intrs);
		max_intrs = scale_intrs(max_bd->intrs, max_bd->cpu);

		/* Recheck for the least-heavy CPU since it may have changed */
		if (find_min_bd(&cpus, max_intrs, &min_bd))
			break;
	}

	/*
	 * If the heaviest CPU has movable IRQs which can't actually be moved,
	 * then ignore it and try balancing the next heaviest CPU.
	 *
	 * Note: moved_irq is intentionally NOT reset between iterations of
	 * try_next_heaviest.  It tracks whether THIS iteration of the migration
	 * loop moved anything; resetting it would cause an already-balanced
	 * second-pass CPU to incorrectly trigger another try_next_heaviest.
	 */
	if (!moved_irq)
		goto try_next_heaviest;
unlock:
	rcu_read_unlock();
	cpus_read_unlock();

	/* Reset each balance domain for the next run */
	for_each_possible_cpu(cpu) {
		bd = per_cpu_ptr(&balance_data, cpu);
		INIT_LIST_HEAD(&bd->movable_irqs);
		bd->intrs = 0;
	}
}

struct process_timer {
	struct timer_list timer;
	struct task_struct *task;
};

static void process_timeout(struct timer_list *t)
{
	struct process_timer *timeout = from_timer(timeout, t, timer);

	wake_up_process(timeout->task);
}

static void sbalance_wait(long poll_jiffies)
{
	/*
	 * Stack-allocate the timer so each call to sbalance_wait() owns its
	 * own timer instance.  The original static local was safe in practice
	 * (only one caller), but a stack allocation makes the ownership and
	 * lifetime explicit and removes the latent hazard entirely.
	 *
	 * Open code freezable_schedule_timeout_interruptible() in order to
	 * make the timer deferrable, so that it doesn't kick CPUs out of idle.
	 */
	struct process_timer timeout;

	freezer_do_not_count();
	__set_current_state(TASK_IDLE);
	timeout.task = current;
	timer_setup(&timeout.timer, process_timeout, TIMER_DEFERRABLE);
	timeout.timer.expires = jiffies + poll_jiffies;
	add_timer(&timeout.timer);
	schedule();
	del_singleshot_timer_sync(&timeout.timer);
	freezer_count();
}

static int __noreturn sbalance_thread(void *data)
{
	long poll_jiffies = msecs_to_jiffies(POLL_MS);
	struct bal_domain *bd;
	int cpu;

	/*
	 * No CPUs are excluded by default.  Initialise explicitly rather than
	 * relying on cpulist_parse("") succeeding with an empty string, which
	 * is implementation-defined behaviour across kernel versions.
	 */
	cpu_exclude_mask = CPU_MASK_NONE;

	/* Initialize the data used for balancing */
	for_each_possible_cpu(cpu) {
		bd = per_cpu_ptr(&balance_data, cpu);
		INIT_LIST_HEAD(&bd->movable_irqs);
		bd->cpu = cpu;
	}

	set_freezable();
	while (1) {
		sbalance_wait(poll_jiffies);
		balance_irqs();
	}
}

static int __init sbalance_init(void)
{
	struct task_struct *t;

	/*
	 * Use a named variable so we can log a proper error instead of
	 * unconditionally panicking the kernel with BUG_ON().  If kthread
	 * creation fails (e.g. OOM at init time), IRQ balancing simply won't
	 * happen — the system remains functional.
	 */
	t = kthread_run(sbalance_thread, NULL, "sbalanced");
	if (IS_ERR(t)) {
		pr_err("failed to start sbalanced kthread: %ld\n", PTR_ERR(t));
		return PTR_ERR(t);
	}
	return 0;
}
late_initcall(sbalance_init);
