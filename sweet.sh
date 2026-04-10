#!/bin/bash
# =============================================================================
#  PerfNeon Build Script v3.1 — sweet (sm6150/SDM732G)
#  Maintainer : ArCHDeViL @ EviLZonE
# =============================================================================

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║   ____            __   _   _                          ║"
echo "║  |  _ \ ___ _ __ / _| | \ | | ___  ___  _ __          ║"
echo "║  | |_) / _ \ '__| |_  |  \| |/ _ \/ _ \| '_ \         ║"
echo "║  |  __/  __/ |  |  _| | |\  |  __/ (_) | | | |        ║"
echo "║  |_|   \___|_|  |_|   |_| \_|\___|\___/|_| |_|        ║"
echo "║                                                       ║"
echo "║            PerfNeon Build Script v3.1                 ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""

# ── Timing ────────────────────────────────────────────────────────────────────
BUILD_START=$(date +%s)

# ── Logging helpers ───────────────────────────────────────────────────────────
info()    { echo "  [*] $*"; }
success() { echo "  [✓] $*"; }
warn()    { echo "  [!] $*"; }
die()     { echo "  [✗] $*"; exit 1; }
phase()   { echo ""; echo "━━━ $* ━━━"; }

# =============================================================================
#  Phase 0 — Input Validation
# =============================================================================
phase "Phase 0 · Input Validation"

[ $# -ne 2 ] && die "Usage: $0 [device] [ksu_mode]
  ksu_mode : none | ksu | ksu_susfs | zako | zako_susfs"

export DEVICE_IMPORT="$1"
export KERNELSU_SELECTOR="$2"

case "$KERNELSU_SELECTOR" in
    none|ksu|ksu_susfs|zako|zako_susfs|zako-susfs) ;;
    *) die "Invalid ksu_mode: '$KERNELSU_SELECTOR'. Valid: none | ksu | ksu_susfs | zako | zako_susfs" ;;
esac

success "Args OK — device=$DEVICE_IMPORT ksu=$KERNELSU_SELECTOR"

# =============================================================================
#  Phase 1 — Environment Setup
# =============================================================================
phase "Phase 1 · Environment Setup"

setup_environment() {
    # ── Maintainer ────────────────────────────────────────────────────────────
    export KBUILD_BUILD_USER=ArCHDeViL
    export KBUILD_BUILD_HOST=EviLZonE
    export GIT_NAME="$KBUILD_BUILD_USER"
    export GIT_EMAIL="${KBUILD_BUILD_USER}@${KBUILD_BUILD_HOST}"

    # ── Toolchain roots ───────────────────────────────────────────────────────
    export CLANG_ROOT="$PWD/clang"
    export GCC64_ROOT="$PWD/gcc64"
    export GCC32_ROOT="$PWD/gcc32"
    export PATH="$CLANG_ROOT/bin:$GCC64_ROOT/bin:$GCC32_ROOT/bin:/usr/bin:$PATH"

    # ── Fetch toolchains (cached) ─────────────────────────────────────────────
    if [ ! -d "$CLANG_ROOT" ]; then
        info "Fetching Neutron Clang via Antman..."
        mkdir -p "$CLANG_ROOT" && cd "$CLANG_ROOT"
        curl -LO "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman"
        chmod a+x antman
        ./antman -S && ./antman --patch=glibc
        cd ..
    else
        info "Clang cache hit — skipping fetch"
    fi

    if [ ! -d "$GCC64_ROOT" ]; then
        info "Fetching Greenforce GCC64..."
        git clone https://github.com/greenforce-project/gcc-arm64 -b main --depth=1 "$GCC64_ROOT" &>/dev/null
    else
        info "GCC64 cache hit — skipping fetch"
    fi

    if [ ! -d "$GCC32_ROOT" ]; then
        info "Fetching Greenforce GCC32..."
        git clone https://github.com/greenforce-project/gcc-arm -b main --depth=1 "$GCC32_ROOT" &>/dev/null
    else
        info "GCC32 cache hit — skipping fetch"
    fi

    # ── Clang version probe ───────────────────────────────────────────────────
    CLANG_VER=$(clang --version 2>/dev/null | head -1 || echo "unknown")
    info "Toolchain: $CLANG_VER"

    # ── Device metadata ───────────────────────────────────────────────────────
    export KERNEL_VERSION="4.14"
    export MAIN_DEFCONFIG="arch/arm64/configs/vendor/sdmsteppe-perf_defconfig"
    export ACTUAL_MAIN_DEFCONFIG="vendor/sdmsteppe-perf_defconfig"
    export COMMON_DEFCONFIG="vendor/debugfs.config"
    export DEVICE_DEFCONFIG="vendor/sweet.config"
    export KERNEL_NAME="-Houdini"
    export THREAD_COUNT=$(nproc --all)

    # ── Global make args ──────────────────────────────────────────────────────
    export MAKE_ARGS=(
        ARCH=arm64
        LLVM=1 LLVM_IAS=1
        CC="clang" LD=ld.lld
        AR=llvm-ar AS=llvm-as NM=llvm-nm
        OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
        CROSS_COMPILE=aarch64-linux-android-
        CROSS_COMPILE_ARM32=arm-linux-gnueabi-
        CLANG_TRIPLE=aarch64-linux-gnu-
        KCFLAGS="-O3 -mllvm -polly -mllvm -polly-ast-use-context -mllvm -polly-vectorizer=stripmine -Wno-declaration-after-statement -Wno-unused-variable -Wno-void-pointer-to-int-cast"
    )

    success "Environment ready — $THREAD_COUNT threads available"
}

setup_environment

# =============================================================================
#  Phase 2 — Device Patches
# =============================================================================
phase "Phase 2 · Device Patches"

apply_device_patches() {
    # ── Helper: apply a list of remote patches, bail on hard failure ──────────
    apply_patch_list() {
        local label="$1"; shift
        info "Applying $label patches..."
        for url in "$@"; do
            if ! wget -qO- "$url" | patch -s -p1; then
                warn "Patch may have partially applied: $url"
            fi
        done
    }

    # ── LN8000 charger patches ────────────────────────────────────────────────
    LN8K_PATCHES=(
        "https://github.com/crdroidandroid/android_kernel_xiaomi_sm6150/commit/7b73f853977d2c016e30319dffb1f49957d30b40.patch"
        "https://github.com/crdroidandroid/android_kernel_xiaomi_sm6150/commit/63dddc108d57dc43e1cd0da0f1445875f760cf97.patch"
        "https://github.com/crdroidandroid/android_kernel_xiaomi_sm6150/commit/95816dff2ecc7ddd907a56537946b5cf1e864953.patch"
        "https://github.com/crdroidandroid/android_kernel_xiaomi_sm6150/commit/330c60abc13530bd05287f9e5395d283ebfd6d0b.patch"
        "https://github.com/crdroidandroid/android_kernel_xiaomi_sm6150/commit/0477c7006b41a1763b3314af9eb300491b91fc25.patch"
        "https://github.com/tbyool/android_kernel_xiaomi_sm6150/commit/aa5ddad5be03aa7436e7ce6e84d46b280849acae.patch"
        "https://github.com/tbyool/android_kernel_xiaomi_sm6150/commit/857638b0da6f80830122b8d1b45c7842970e76c3.patch"
        "https://github.com/tbyool/android_kernel_xiaomi_sm6150/commit/3a68adff14cbedd09ce2a735d575c3bf92dd696f.patch"
        "https://github.com/tbyool/android_kernel_xiaomi_sm6150/commit/30fcc15d5dcf2cfc3b83a5a7d4a77e2880639fa5.patch"
        "https://github.com/tbyool/android_kernel_xiaomi_sm6150/commit/1a17a6fbbf59d901c4b3aec66c06a1c96cd89c7e.patch"
    )

    # ── DTBO fix patches ──────────────────────────────────────────────────────
    DTBO_PATCHES=(
        "https://github.com/xiaomi-sm6150/android_kernel_xiaomi_sm6150/commit/e517bc363a19951ead919025a560f843c2c03ad3.patch"
        "https://github.com/xiaomi-sm6150/android_kernel_xiaomi_sm6150/commit/a62a3b05d0f29aab9c4bf8d15fe786a8c8a32c98.patch"
        "https://github.com/xiaomi-sm6150/android_kernel_xiaomi_sm6150/commit/4b89948ec7d610f997dd1dab813897f11f403a06.patch"
        "https://github.com/xiaomi-sm6150/android_kernel_xiaomi_sm6150/commit/fade7df36b01f2b170c78c63eb8fe0d11c613c4a.patch"
        "https://github.com/xiaomi-sm6150/android_kernel_xiaomi_sm6150/commit/2628183db0d96be8dae38a21f2b09cb10978f423.patch"
        "https://github.com/xiaomi-sm6150/android_kernel_xiaomi_sm6150/commit/31f4577af3f8255ae503a5b30d8f68906edde85f.patch"
    )

    apply_patch_list "LN8K" "${LN8K_PATCHES[@]}"
    apply_patch_list "DTBO" "${DTBO_PATCHES[@]}"

    info "Applying LTO fix patch..."
    wget -qO- "https://github.com/TheSillyOk/kernel_ls_patches/raw/refs/heads/master/fix_lto.patch" | patch -s -p1

    info "Applying kpatch fix patch..."
    wget -qO- "https://github.com/TheSillyOk/kernel_ls_patches/raw/refs/heads/master/kpatch_fix.patch" | patch -s -p1

    # Append LN8000 config
    echo "CONFIG_CHARGER_LN8000=y" >> "$MAIN_DEFCONFIG"

    # ── Missing Headers ───────────────────────────────────
    info "Patching missing uaccess header for perf_trace_user..."
    [ -f arch/arm64/kernel/perf_trace_user.c ] && sed -i '1i #include <linux/uaccess.h>' arch/arm64/kernel/perf_trace_user.c

    success "Device patches applied"
}

apply_device_patches

# =============================================================================
#  Phase 3 — Goodies (BORE + BBG + KSU/SUSFS)
# =============================================================================
phase "Phase 3 · Goodies Injection"

add_goodies() {
    # ── BORE Scheduler ────────────────────────────────────────────────────────
    info "Injecting BORE scheduler..."
    wget -qO- "https://github.com/ximi-mojito-test/android_kernel_xiaomi_mojito/commit/eff756aaf5d666a15d8ac19743b582c2ce0fe3aa.patch" \
        | patch -s -p1 --fuzz=5
    wget -qO- "https://github.com/ximi-mojito-test/android_kernel_xiaomi_mojito/commit/2220322065591df5ff7ae27cc1fff386d3631bd0.patch" \
        | patch -s -p1 --fuzz=5
    echo "CONFIG_SCHED_BORE=y" >> "$MAIN_DEFCONFIG"
    success "BORE scheduler injected"

    # ── Baseband Guard ──────────────────────────────────────
    info "Setting up Baseband Guard..."
    curl -LSs "https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh" | bash &>/dev/null
    echo "CONFIG_BBG=y" >> "$MAIN_DEFCONFIG"
    success "Baseband Guard enabled"

    # ── KernelSU + optional SUSFS ─────────────────────────────────────────────
    if [[ "$KERNELSU_SELECTOR" != "none" ]]; then
        info "Setting up ReSukiSU..."
        curl -LSs "https://github.com/ReSukiSU/ReSukiSU/raw/refs/heads/main/kernel/setup.sh" \
            | bash -s main &>/dev/null
        {
            echo "CONFIG_KSU=y"
            echo "CONFIG_KSU_MULTI_MANAGER_SUPPORT=y"
            echo "CONFIG_KPM=n"
            echo "CONFIG_KSU_MANUAL_HOOK=y"
            echo "CONFIG_HAVE_SYSCALL_TRACEPOINTS=y"
        } >> "$MAIN_DEFCONFIG"

        # SUSFS branch
        if [[ "$KERNELSU_SELECTOR" == "zako_susfs" || "$KERNELSU_SELECTOR" == "zako-susfs" ]]; then
            info "Applying SUSFS patch (JackA1ltman/4.14)..."
            wget -qO- "https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd/raw/refs/heads/mainline/Patches/Patch/susfs_patch_to_4.14.patch" \
                | patch -s -p1 --fuzz=5
            {
                echo "CONFIG_KSU_SUSFS=y"
                echo "CONFIG_KSU_SUSFS_SUS_PATH=y"
                echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
                echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
                echo "CONFIG_KSU_SUSFS_SUS_OVERLAYFS=y"
                echo "CONFIG_KSU_SUSFS_TRY_UMOUNT=y"
                echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
                echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y"
                echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y"
            } >> "$MAIN_DEFCONFIG"

            KSU_HOOK="https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd/raw/refs/heads/mainline/Patches/susfs_inline_hook_patches.sh"
            success "SUSFS enabled"
        else
            KSU_HOOK="https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd/raw/refs/heads/mainline/Patches/syscall_hook_patches.sh"
            info "KSU without SUSFS"
        fi

        info "Applying backport + hook patches..."
        curl -LSs "https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd/raw/refs/heads/mainline/Patches/backport_patches.sh" \
            | bash &>/dev/null
        curl -LSs "$KSU_HOOK" | bash &>/dev/null

        success "KernelSU ready"
    else
        info "KSU skipped (mode=none)"
    fi
}

add_goodies

# =============================================================================
#  Phase 4 — Pre-compile
# =============================================================================
phase "Phase 4 · Pre-compile Configuration"

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
    echo "CONFIG_LOCALVERSION=\"$KERNEL_NAME\"" >> out/.config

    # ── Step 3: Kernel Config API — intentional overrides ────────────────────
    info "Applying performance + size config overrides..."

    # [SIZE] Nuke all debug info — biggest single size win
    ./scripts/config --file out/.config \
        --disable DEBUG_INFO            \
        --disable DEBUG_INFO_REDUCED    \
        --disable DEBUG_INFO_SPLIT      \
        --disable DEBUG_INFO_DWARF4     \
        --enable  DEBUG_INFO_NONE

    # [SIZE] LTO & Linker GC
    ./scripts/config --file out/.config \
        --enable  LTO_CLANG             \
        --enable  LTO_CLANG_FULL        \
        --disable LTO_CLANG_THIN        \
        --disable MODVERSIONS           \
        --disable MODULE_SIG            \
        --disable MODULE_SIG_FORCE

    # [SIZE] Silence stack frame warnings from crypto modules
    ./scripts/config --file out/.config \
        --set-val FRAME_WARN 0

    # [SIZE] Compress kernel image
    ./scripts/config --file out/.config \
        --enable KERNEL_GZ

    # [PERF] Scheduler & CPU policy
    ./scripts/config --file out/.config \
        --disable HZ_100                \
        --disable HZ_250                \
        --enable  HZ_300                \
        --set-val HZ 300

    # [PERF] Disable unnecessary debug/tracing overhead
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

    # [SILENT] Nuke bloated Qualcomm logs & verbose debugs 
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

    # [PERF/BATTERY] CPU idle & power
    ./scripts/config --file out/.config \
        --enable  CPU_FREQ_GOV_SCHEDUTIL \
        --enable  CPU_FREQ_GOV_PERFORMANCE

    # [BATTERY] Reduce wakelock debug
    ./scripts/config --file out/.config \
        --disable PM_WAKELOCKS_LIMIT    \
        --disable PM_DEBUG

    # ── Step 4: Resolve config deps, no interactive prompts ──────────────────
    info "Resolving config dependencies..."
    "${MAKE_CMD[@]}" olddefconfig &>/dev/null
    "${MAKE_CMD[@]}" syncconfig   &>/dev/null

    # ── Step 5: Git snapshot pre-compile ─────────────────────────────────────
    git config user.email "$GIT_EMAIL" &>/dev/null
    git config user.name  "$GIT_NAME"  &>/dev/null
    git add . &>/dev/null
    git commit -m "build: pre-compile setup [v3.1 · PerfNeon]" &>/dev/null

    success "Pre-compile configuration done"
}

before_compile

# =============================================================================
#  Phase 5 — Compile
# =============================================================================
phase "Phase 5 · Compilation  ($THREAD_COUNT threads)"

compile_it() {
    info "Launching make with $THREAD_COUNT jobs..."
    make -j"$THREAD_COUNT" O=out "${MAKE_ARGS[@]}" 2>&1 | tee build.log
    local rc=${PIPESTATUS[0]}
    
    grep -Eiw "warning:|error:" build.log > warnings.txt || true
    
    export WARN_COUNT=$(grep -ciw "warning:" build.log || true)
    export ERR_COUNT=$(grep -ciw "error:" build.log || true)
    
    rm -f build.log

    [ $rc -ne 0 ] && die "Compilation exited with code $rc (Errors: $ERR_COUNT)"
    success "Compilation finished (Warnings: $WARN_COUNT, Errors: $ERR_COUNT)"
}

compile_it

# =============================================================================
#  Phase 6 — Finalize
# =============================================================================
phase "Phase 6 · Finalize"

finalize_build() {
    local IMAGE="out/arch/arm64/boot/Image.gz"

    if [ ! -f "$IMAGE" ]; then
        die "Image.gz not found — build failed"
    fi

    local BUILD_END=$(date +%s)
    local ELAPSED=$(( BUILD_END - BUILD_START ))
    local MINS=$(( ELAPSED / 60 ))
    local SECS=$(( ELAPSED % 60 ))
    local SIZE=$(du -sh "$IMAGE" | cut -f1)

    WARN_COUNT=${WARN_COUNT:-0}
    ERR_COUNT=${ERR_COUNT:-0}

    echo ""
    echo -e "\E[1;36m╭━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╮\E[0m"
    echo -e "\E[1;36m│\E[0m\E[1;32m                 BUILD SUCCESSFUL                    \E[0m\E[1;36m│\E[0m"
    echo -e "\E[1;36m├━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┤\E[0m"
    printf  "\E[1;36m│\E[0m  \E[1;37mKernel  :\E[0m \E[1;32m%-41s\E[0m\E[1;36m│\E[0m\n" "$KERNEL_NAME"
    printf  "\E[1;36m│\E[0m  \E[1;37mDevice  :\E[0m \E[1;33m%-41s\E[0m\E[1;36m│\E[0m\n" "$DEVICE_IMPORT"
    printf  "\E[1;36m│\E[0m  \E[1;37mKSU     :\E[0m \E[1;35m%-41s\E[0m\E[1;36m│\E[0m\n" "$KERNELSU_SELECTOR"
    printf  "\E[1;36m│\E[0m  \E[1;37mBBG     :\E[0m \E[1;31m%-41s\E[0m\E[1;36m│\E[0m\n" "ACTIVE (Enforced)"
    printf  "\E[1;36m│\E[0m  \E[1;37mSize    :\E[0m \E[1;34m%-41s\E[0m\E[1;36m│\E[0m\n" "$SIZE"
    local TIME_STR="${MINS}m ${SECS}s"
    printf  "\E[1;36m│\E[0m  \E[1;37mTime    :\E[0m \E[1;32m%-41s\E[0m\E[1;36m│\E[0m\n" "$TIME_STR"
    echo -e "\E[1;36m├─────────────────────────────────────────────────────┤\E[0m"
    printf  "\E[1;36m│\E[0m  \E[1;37mErrors  :\E[0m \E[1;31m%-41s\E[0m\E[1;36m│\E[0m\n" "$ERR_COUNT"
    printf  "\E[1;36m│\E[0m  \E[1;37mWarnings:\E[0m \E[1;33m%-41s\E[0m\E[1;36m│\E[0m\n" "$WARN_COUNT"
    echo -e "\E[1;36m╰━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╯\E[0m"
    echo ""
    ls -alh "$IMAGE"
}

finalize_build
