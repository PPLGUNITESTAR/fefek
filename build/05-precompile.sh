#!/bin/bash
# =============================================================================
#  build/05-precompile.sh — Phase 4: Config assembly and pre-compile setup
# =============================================================================

before_compile() {
    mkdir -p out

    local MAKE_CMD=(make O=out "${MAKE_ARGS[@]}")

    # ── Step 1: Generate base .config ─────────────────────────────────────────
    info "Generating base .config from defconfig..."
    "${MAKE_CMD[@]}" ARCH=arm64 "$ACTUAL_MAIN_DEFCONFIG" &>/dev/null

    # ── Step 2: Append config fragments ──────────────────────────────────────
    info "Appending config fragments..."
    [ -f "arch/arm64/configs/$COMMON_DEFCONFIG" ] \
        && cat "arch/arm64/configs/$COMMON_DEFCONFIG" >> out/.config
    [ -f "arch/arm64/configs/$DEVICE_DEFCONFIG" ] \
        && cat "arch/arm64/configs/$DEVICE_DEFCONFIG" >> out/.config
    # Watt: performance/battery/UX optimization fragment
    [ -f "arch/arm64/configs/vendor/watt.config" ] \
        && cat "arch/arm64/configs/vendor/watt.config" >> out/.config
    echo "CONFIG_LOCALVERSION=\"$KERNEL_NAME\"" >> out/.config

    # ── Step 3: Kernel config overrides ──────────────────────────────────────
    info "Applying performance + size config overrides..."

    # Debug info — strip everything for size
    ./scripts/config --file out/.config \
        --disable DEBUG_INFO            \
        --disable DEBUG_INFO_REDUCED    \
        --disable DEBUG_INFO_SPLIT      \
        --disable DEBUG_INFO_DWARF4     \
        --enable  DEBUG_INFO_NONE

    # LTO
    ./scripts/config --file out/.config \
        --enable  LTO_CLANG             \
        --enable  LTO_CLANG_FULL        \
        --disable LTO_CLANG_THIN        \
        --disable MODVERSIONS           \
        --disable MODULE_SIG            \
        --disable MODULE_SIG_FORCE

    ./scripts/config --file out/.config \
        --set-val FRAME_WARN 0

    ./scripts/config --file out/.config \
        --enable KERNEL_GZ

    # Tick rate
    ./scripts/config --file out/.config \
        --disable HZ_100                \
        --disable HZ_250                \
        --enable  HZ_300                \
        --set-val HZ 300

    # Tracing / debug — strip all
    ./scripts/config --file out/.config \
        --disable FTRACE                \
        --disable FUNCTION_TRACER       \
        --disable IRQSOFF_TRACER        \
        --disable PREEMPT_TRACER        \
        --disable SCHED_TRACER          \
        --disable KPROBES               \
        --disable KPROBE_EVENTS         \
        --disable UPROBE_EVENTS         \
        --disable DEBUG_FS              \
        --disable SLUB_DEBUG            \
        --disable DEBUG_MEMORY_INIT     \
        --disable DETECT_HUNG_TASK      \
        --disable LOCKUP_DETECTOR       \
        --disable PROFILING

    ./scripts/config --file out/.config \
        --disable SCHED_DEBUG           \
        --disable DYNAMIC_DEBUG         \
        --disable IPC_LOGGING           \
        --disable QCOM_RTB              \
        --disable DEBUG_BUGVERBOSE      \
        --disable DEBUG_SPINLOCK        \
        --disable DEBUG_MUTEXES         \
        --disable DEBUG_ATOMIC_SLEEP    \
        --disable PROVE_LOCKING         \
        --disable MSM_DEBUG_LAR_UNLOCK  \
        --set-val CONSOLE_LOGLEVEL_DEFAULT 3 \
        --set-val MESSAGE_LOGLEVEL_DEFAULT 3

    ./scripts/config --file out/.config \
        --disable PM_WAKELOCKS_LIMIT    \
        --disable PM_DEBUG

    # ── Watt: Performance | UI Smoothness | Battery ───────────────────────────
    # UCLAMP: required for Android's top-app cgroup uclamp_min hints to
    # propagate through fork. Without this, CPU ramp hints are silently dropped
    # → p99 frame latency spikes on app launch and heavy scroll.
    ./scripts/config --file out/.config \
        --enable UCLAMP_TASK            \
        --enable UCLAMP_TASK_GROUP

    # CPU_FREQ_STAT: zero runtime cost, enables time_in_state profiling.
    ./scripts/config --file out/.config \
        --enable CPU_FREQ_STAT

    # TCP: BBR congestion control + FQ_CODEL qdisc reduces modem active time
    # by eliminating buffer bloat retransmissions during idle network periods.
    ./scripts/config --file out/.config \
        --enable TCP_CONG_ADVANCED      \
        --enable TCP_CONG_BBR           \
        --enable NET_SCH_FQ_CODEL       \
        --enable NET_SCH_DEFAULT        \
        --enable DEFAULT_FQ_CODEL

    # Memory: COMPACTION prevents kswapd over-waking under sustained workloads.
    ./scripts/config --file out/.config \
        --enable COMPACTION             \
        --enable CMA                    \
        --disable CMA_DEBUGFS

    # ── Step 4: Resolve config dependencies ──────────────────────────────────
    info "Resolving config dependencies..."
    "${MAKE_CMD[@]}" olddefconfig &>/dev/null
    "${MAKE_CMD[@]}" syncconfig   &>/dev/null

    # ── Step 5: Git snapshot pre-compile ─────────────────────────────────────
    git config user.email "$GIT_EMAIL" &>/dev/null
    git config user.name  "$GIT_NAME"  &>/dev/null
    git add . &>/dev/null
    git commit -m "build: pre-compile setup [v3.1 · Houdini]" &>/dev/null

    success "Pre-compile configuration done"
}
