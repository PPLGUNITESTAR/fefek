#!/bin/bash
# =============================================================================
#  Houdini Build Script v3.1 — sweet (sm6150/SDM732G)
#  Maintainer : 0xArCHDeViL @ EviLZonE
# =============================================================================

# Color aliases — used only in banner, harmless to global scope
_C="\033[0m" _R="\033[1;31m" _G="\033[1;32m" _Y="\033[1;33m" _M="\033[1;35m" _CY="\033[1;36m" _W="\033[1;37m" _D="\033[0;90m"
_banner() {
  local B="${_M}" E="${_C}"
  echo ""
  echo -e "${B}   -----------------------------------------------${E}"
  echo -e "${_W}      _  _  _____  _   _  ____  ___  _   _  ___ ${E}"
  echo -e "${_W}     | || ||  _  || | | ||  _ \|_ _|| \ | ||_ _|${E}"
  echo -e "${_W}     | __ || |_| || |_| || | | || | |  \| | | | ${E}"
  echo -e "${_W}     |_||_||_____| \___/ |____/|___||_|\__| |_| ${E}"
  echo -e "             ${_W}K    E    R    N    E    L${E}"
  echo -e "${B}   -----------------------------------------------${E}"
  echo -e "    ${_Y}[   GOD'S IN HIS HEAVEN. ALL'S RIGHT WITH   ]${E}"
  echo -e "    ${_Y}[              THE WORLD.                   ]${E}"
  echo -e "${B}   -----------------------------------------------${E}"
  echo -e "    ${_D}Maintainer : ${_M}0xArCHDeViL${E}"
  echo -e "    ${_D}Device     : ${_G}sweet (sm6150 / SDM732G)${E}"
  local TC_DISP="Neutron Clang + GCC"
  [[ "$TOOLCHAIN_SELECTOR" == "lilium" ]] && TC_DISP="Lilium Clang + LLD"
  [[ "$TOOLCHAIN_SELECTOR" == "kaleidoscope" ]] && TC_DISP="Kaleidoscope Clang + LLD"
  [[ "$TOOLCHAIN_SELECTOR" == "greenforce" ]] && TC_DISP="Greenforce Clang + LLD"
  echo -e "    ${_D}Toolchain  : ${_CY}${TC_DISP}${E}"
  echo -e "${B}   -----------------------------------------------${E}"
  echo ""
}

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

[ $# -ne 5 ] && die "Usage: $0 [device] [ksu_mode] [bore_mode] [f2fs_mode] [toolchain]
  ksu_mode  : none | zako | zako_susfs | ksunext | ksunext_susfs
  bore_mode : bore | none
  f2fs_mode : f2fs | none
  toolchain : neutron | lilium | kaleidoscope | greenforce"

export DEVICE_IMPORT="$1"
export KERNELSU_SELECTOR="$2"
export BORE_SELECTOR="$3"
export F2FS_SELECTOR="$4"
export TOOLCHAIN_SELECTOR="$5"

case "$KERNELSU_SELECTOR" in
    none|zako|zako_susfs|zako-susfs|ksunext|ksunext_susfs) ;;
    *) die "Invalid ksu_mode: '$KERNELSU_SELECTOR'. Valid: none | zako | zako_susfs | ksunext | ksunext_susfs" ;;
esac

case "$BORE_SELECTOR" in
    bore|none) ;;
    *) die "Invalid bore_mode: '$BORE_SELECTOR'. Valid: bore | none" ;;
esac

case "$F2FS_SELECTOR" in
    f2fs|none) ;;
    *) die "Invalid f2fs_mode: '$F2FS_SELECTOR'. Valid: f2fs | none" ;;
esac

case "$TOOLCHAIN_SELECTOR" in
    neutron|lilium|kaleidoscope|greenforce) ;;
    *) die "Invalid toolchain: '$TOOLCHAIN_SELECTOR'. Valid: neutron | lilium | kaleidoscope | greenforce" ;;
esac

_banner

success "Args OK — device=$DEVICE_IMPORT ksu=$KERNELSU_SELECTOR bore=$BORE_SELECTOR f2fs=$F2FS_SELECTOR toolchain=$TOOLCHAIN_SELECTOR"

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

    # ── Setup and Fetch toolchains ───────────────────────────────────────────
    export GCC64_ROOT="$PWD/gcc64"
    export GCC32_ROOT="$PWD/gcc32"

    # ── Path & Variables Setup ───────────────────────────────────────────────
    if [[ "$TOOLCHAIN_SELECTOR" == "neutron" ]]; then
        export CLANG_ROOT="$PWD/clang"
        export PATH="$CLANG_ROOT/bin:$GCC64_ROOT/bin:$GCC32_ROOT/bin:/usr/bin:$PATH"
    elif [[ "$TOOLCHAIN_SELECTOR" == "lilium" ]]; then
        export LILIUM_ROOT="$PWD/lilium"
        export PATH="$LILIUM_ROOT/bin:$GCC64_ROOT/bin:$GCC32_ROOT/bin:/usr/bin:$PATH"
    elif [[ "$TOOLCHAIN_SELECTOR" == "kaleidoscope" ]]; then
        export KALEIDOSCOPE_ROOT="$PWD/kaleidoscope"
        export PATH="$KALEIDOSCOPE_ROOT/bin:$GCC64_ROOT/bin:$GCC32_ROOT/bin:/usr/bin:$PATH"
    elif [[ "$TOOLCHAIN_SELECTOR" == "greenforce" ]]; then
        export GREENFORCE_ROOT="$PWD/greenforce-clang"
        export PATH="$GREENFORCE_ROOT/bin:$GCC64_ROOT/bin:$GCC32_ROOT/bin:/usr/bin:$PATH"
    fi

    # ── Fetch toolchains in parallel (Multi-threading) ───────────────────────
    (
        if [ ! -d "$GCC64_ROOT" ]; then
            info "Fetching Greenforce GCC64..."
            git clone https://github.com/greenforce-project/gcc-arm64 -b main --depth=1 "$GCC64_ROOT" &>/dev/null
        else
            info "GCC64 cache hit — skipping fetch"
        fi
    ) &

    (
        if [ ! -d "$GCC32_ROOT" ]; then
            info "Fetching Greenforce GCC32..."
            git clone https://github.com/greenforce-project/gcc-arm -b main --depth=1 "$GCC32_ROOT" &>/dev/null
        else
            info "GCC32 cache hit — skipping fetch"
        fi
    ) &

    (
        if [[ "$TOOLCHAIN_SELECTOR" == "neutron" ]]; then
            if [ ! -d "$CLANG_ROOT" ]; then
                info "Fetching Neutron Clang..."
                mkdir -p "$CLANG_ROOT" && cd "$CLANG_ROOT"
                curl -sLO "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman"
                chmod a+x antman
                ./antman -S && ./antman --patch=glibc
            else
                info "Neutron Clang cache hit — skipping fetch"
            fi
        elif [[ "$TOOLCHAIN_SELECTOR" == "lilium" ]]; then
            if [ ! -d "$LILIUM_ROOT/bin" ]; then
                info "Fetching Lilium Clang..."
                mkdir -p "$LILIUM_ROOT" && cd "$LILIUM_ROOT"
                wget -q https://github.com/liliumproject/clang/releases/download/20250912/lilium_clang-20250912.tar.gz
                info "Extracting Lilium Clang..."
                tar -xf lilium_clang-20250912.tar.gz -C .
                rm lilium_clang-20250912.tar.gz
            else
                info "Lilium Clang cache hit — skipping fetch"
            fi
        elif [[ "$TOOLCHAIN_SELECTOR" == "kaleidoscope" ]]; then
            if [ ! -d "$KALEIDOSCOPE_ROOT/bin" ]; then
                info "Fetching Kaleidoscope Clang..."
                mkdir -p "$KALEIDOSCOPE_ROOT" && cd "$KALEIDOSCOPE_ROOT"
                wget -qO clang.tar.zst https://github.com/PurrrsLitterbox/LLVM-stable/releases/download/llvmorg-22.1.2/clang.tar.zst
                info "Extracting Kaleidoscope Clang..."
                tar -xf clang.tar.zst
                rm clang.tar.zst
            else
                info "Kaleidoscope Clang cache hit — skipping fetch"
            fi
        elif [[ "$TOOLCHAIN_SELECTOR" == "greenforce" ]]; then
            if [ ! -d "$GREENFORCE_ROOT/bin" ]; then
                info "Fetching Greenforce Clang..."
                bash <(wget -qO- https://raw.githubusercontent.com/greenforce-project/greenforce_clang/refs/heads/main/get_clang.sh) >/dev/null
            else
                info "Greenforce Clang cache hit — skipping fetch"
            fi
        fi
    ) &

    info "Waiting for all toolchain downloads to complete..."
    wait

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
    if [[ "$TOOLCHAIN_SELECTOR" == "neutron" ]]; then
        export MAKE_ARGS=(
            ARCH=arm64
            LLVM=1 LLVM_IAS=1
            CC="clang" LD=ld.lld
            AR=llvm-ar AS=llvm-as NM=llvm-nm
            OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
            CROSS_COMPILE=aarch64-linux-android-
            CROSS_COMPILE_ARM32=arm-linux-gnueabi-
            CLANG_TRIPLE=aarch64-linux-gnu-
            KCFLAGS="-O3 -Wno-declaration-after-statement -Wno-unused-variable -Wno-void-pointer-to-int-cast"
        )
    elif [[ "$TOOLCHAIN_SELECTOR" == "lilium" ]]; then
        export MAKE_ARGS=(
            ARCH=arm64
            LLVM=1 LLVM_IAS=1
            CC="clang" LD=ld.lld
            AR=llvm-ar AS=llvm-as NM=llvm-nm
            OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
            CROSS_COMPILE=aarch64-linux-android-
            CROSS_COMPILE_ARM32=arm-linux-gnueabi-
            CLANG_TRIPLE=aarch64-linux-gnu-
            KCFLAGS="-O3 -mllvm -inline-threshold=200 -Wno-declaration-after-statement -Wno-unused-variable -Wno-void-pointer-to-int-cast -Wno-default-const-init-var-unsafe -Wno-default-const-init-field-unsafe -Wno-implicit-enum-enum-cast"
        )
    elif [[ "$TOOLCHAIN_SELECTOR" == "kaleidoscope" ]]; then
        export MAKE_ARGS=(
            ARCH=arm64
            LLVM=1 LLVM_IAS=1
            CC="clang" LD=ld.lld
            AR=llvm-ar AS=llvm-as NM=llvm-nm
            OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
            CROSS_COMPILE=aarch64-linux-android-
            CROSS_COMPILE_ARM32=arm-linux-gnueabi-
            CLANG_TRIPLE=aarch64-linux-gnu-
            KCFLAGS="-O3 -mllvm -inline-threshold=200 -Wno-declaration-after-statement -Wno-unused-variable -Wno-void-pointer-to-int-cast -Wno-default-const-init-var-unsafe -Wno-default-const-init-field-unsafe -Wno-implicit-enum-enum-cast"
        )
    elif [[ "$TOOLCHAIN_SELECTOR" == "greenforce" ]]; then
        export MAKE_ARGS=(
            ARCH=arm64
            LLVM=1 LLVM_IAS=1
            CC="clang" LD=ld.lld
            AR=llvm-ar AS=llvm-as NM=llvm-nm
            OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
            CROSS_COMPILE=aarch64-linux-android-
            CROSS_COMPILE_ARM32=arm-linux-gnueabi-
            CLANG_TRIPLE=aarch64-linux-gnu-
            KCFLAGS="-O2 -Wno-declaration-after-statement -Wno-unused-variable -Wno-void-pointer-to-int-cast -Wno-default-const-init-var-unsafe -Wno-default-const-init-field-unsafe -Wno-implicit-enum-enum-cast"
        )
    fi

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

    # ── Helper: revert a list of remote patches ───────────────────────────────
    revert_patch_list() {
        local label="$1"; shift
        info "Reverting $label commits..."
        for url in "$@"; do
            if ! wget -qO- "$url" | patch -R -s -p1; then
                warn "Revert may have failed or already reverted: $url"
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

    if [[ "$F2FS_SELECTOR" == "f2fs" ]]; then
        info "Applying F2FS Compression patches..."
        REVERT_F2FS=(
            "https://github.com/xiaomi-sm6150/android_kernel_xiaomi_sm6150/commit/212f6697ff90336cc993d163411775ec969deeb6.patch"
            "https://github.com/xiaomi-sm6150/android_kernel_xiaomi_sm6150/commit/694585a55caa3e1873c889ab3aa1c47d93144fad.patch"
        )
        revert_patch_list "F2FS Reverts" "${REVERT_F2FS[@]}"
        apply_patch_list "F2FS Compression" "https://github.com/tbyool/android_kernel_xiaomi_sm6150/commit/02baeab5aaf5319e5d68f2319516efed262533ea.patch"
        
        echo "CONFIG_F2FS_FS_COMPRESSION=y" >> "$MAIN_DEFCONFIG"
        echo "CONFIG_F2FS_FS_LZ4=y" >> "$MAIN_DEFCONFIG"
        success "F2FS patches applied"
    else
        info "F2FS Compression skipped (mode=none)"
    fi

    info "Applying LTO fix patch..."
    wget -qO- "https://github.com/TheSillyOk/kernel_ls_patches/raw/refs/heads/master/fix_lto.patch" | patch -s -p1

    info "Applying kpatch fix patch..."
    wget -qO- "https://github.com/TheSillyOk/kernel_ls_patches/raw/refs/heads/master/kpatch_fix.patch" | patch -s -p1

    # Append LN8000 config
    echo "CONFIG_CHARGER_LN8000=y" >> "$MAIN_DEFCONFIG"

    echo "CONFIG_EROFS_FS=y" >> "$MAIN_DEFCONFIG"
    echo "CONFIG_SECURITY_SELINUX_DEVELOP=y" >> "$MAIN_DEFCONFIG"

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
    if [[ "$BORE_SELECTOR" == "bore" ]]; then
        info "Injecting BORE scheduler..."
        wget -qO- "https://github.com/ximi-mojito-test/android_kernel_xiaomi_mojito/commit/eff756aaf5d666a15d8ac19743b582c2ce0fe3aa.patch" \
            | patch -s -p1 --fuzz=5
        wget -qO- "https://github.com/ximi-mojito-test/android_kernel_xiaomi_mojito/commit/2220322065591df5ff7ae27cc1fff386d3631bd0.patch" \
            | patch -s -p1 --fuzz=5
        echo "CONFIG_SCHED_BORE=y" >> "$MAIN_DEFCONFIG"
        success "BORE scheduler injected"
    else
        info "BORE scheduler skipped (mode=none)"
    fi

    # ── Baseband Guard ──────────────────────────────────────
    info "Setting up Baseband Guard..."
    curl -LSs "https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh" | bash &>/dev/null
    echo "CONFIG_BBG=y" >> "$MAIN_DEFCONFIG"
    success "Baseband Guard enabled"

    # ── KernelSU + optional SUSFS ─────────────────────────────────────────────
    case "$KERNELSU_SELECTOR" in
        zako|zako_susfs|zako-susfs)
            # ── ReSukiSU ─────────────────────────────────────────────────────
            info "Setting up ReSukiSU..."
            local KSU_URI="https://github.com/ReSukiSU/ReSukiSU/raw/refs/heads/main/kernel/setup.sh"
            local KSU_BRANCH="main"

            if [[ "$KERNELSU_SELECTOR" == "zako_susfs" || "$KERNELSU_SELECTOR" == "zako-susfs" ]]; then
                KSU_BRANCH="main"
            fi

            curl -LSs --fail --retry 3 "$KSU_URI" \
                | bash -s $KSU_BRANCH &>/dev/null \
                || die "ReSukiSU setup script failed to download/run"

            {
                echo "CONFIG_KSU=y"
                echo "CONFIG_KSU_MULTI_MANAGER_SUPPORT=y"
                echo "CONFIG_KPM=n"
                echo "CONFIG_KSU_MANUAL_HOOK=y"
                echo "CONFIG_HAVE_SYSCALL_TRACEPOINTS=y"
                echo "CONFIG_THREAD_INFO_IN_TASK=y"
            } >> "$MAIN_DEFCONFIG"

            if [[ "$KERNELSU_SELECTOR" == "zako_susfs" || "$KERNELSU_SELECTOR" == "zako-susfs" ]]; then
                info "Applying SUSFS patch (JackA1ltman/$KERNEL_VERSION)..."
                wget -qO- "https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd/raw/refs/heads/mainline/Patches/Patch/susfs_patch_to_${KERNEL_VERSION}.patch" \
                    | patch -s -p1 --fuzz=5
                {
                    echo "CONFIG_KSU_SUSFS=y"
                    echo "CONFIG_KSU_SUSFS_SUS_PATH=y"
                    echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
                    echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
                    echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
                    echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y"
                    echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y"
                    echo "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y"
                    echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y"
                    echo "CONFIG_KSU_SUSFS_SUS_MAP=y"
                    echo "CONFIG_KSU_SUSFS_TRY_UMOUNT=y"
                } >> "$MAIN_DEFCONFIG"
                KSU_HOOK="https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd/raw/refs/heads/mainline/Patches/susfs_inline_hook_patches.sh"
                success "SUSFS enabled"
            else
                KSU_HOOK="https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd/raw/refs/heads/mainline/Patches/syscall_hook_patches.sh"
                info "ReSukiSU without SUSFS"
            fi

            info "Applying backport + hook patches..."
            curl -LSs "https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd/raw/refs/heads/mainline/Patches/backport_patches.sh" \
                | bash &>/dev/null
            curl -LSs "$KSU_HOOK" | bash &>/dev/null
            success "ReSukiSU ready"
            ;;

        ksunext|ksunext_susfs)
            # ── KernelSU-Next ────────────────────────────────────────────────
            info "Setting up KernelSU-Next..."
            local KSU_URI="https://github.com/KernelSU-Next/KernelSU-Next/raw/refs/heads/dev/kernel/setup.sh"
            local KSU_BRANCH="legacy"

            if [[ "$KERNELSU_SELECTOR" == "ksunext_susfs" ]]; then
                KSU_BRANCH="legacy_susfs"
            fi

            curl -LSs --fail --retry 3 "$KSU_URI" \
                | bash -s $KSU_BRANCH &>/dev/null \
                || die "KernelSU-Next setup script failed to download/run"

            {
                echo "CONFIG_KSU=y"
                echo "CONFIG_KSU_MANUAL_HOOK=y"
                echo "CONFIG_HAVE_SYSCALL_TRACEPOINTS=y"
                echo "CONFIG_THREAD_INFO_IN_TASK=y"
            } >> "$MAIN_DEFCONFIG"

            if [[ "$KERNELSU_SELECTOR" == "ksunext_susfs" ]]; then
                info "Applying SUSFS patch (JackA1ltman/$KERNEL_VERSION)..."
                wget -qO- "https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd/raw/refs/heads/mainline/Patches/Patch/susfs_patch_to_${KERNEL_VERSION}.patch" \
                    | patch -s -p1 --fuzz=5
                {
                    echo "CONFIG_KSU_SUSFS=y"
                    echo "CONFIG_KSU_SUSFS_SUS_PATH=y"
                    echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
                    echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
                    echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
                    echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y"
                    echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y"
                    echo "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y"
                    echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y"
                    echo "CONFIG_KSU_SUSFS_SUS_MAP=y"
                    echo "CONFIG_KSU_SUSFS_TRY_UMOUNT=y"
                } >> "$MAIN_DEFCONFIG"
                KSU_HOOK="https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd/raw/refs/heads/mainline/Patches/susfs_inline_hook_patches.sh"
                success "SUSFS enabled"
            else
                KSU_HOOK="https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd/raw/refs/heads/mainline/Patches/syscall_hook_patches.sh"
                info "KernelSU-Next without SUSFS"
            fi

            info "Applying backport + hook patches..."
            curl -LSs "https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd/raw/refs/heads/mainline/Patches/backport_patches.sh" \
                | bash &>/dev/null
            curl -LSs "$KSU_HOOK" | bash &>/dev/null
            # Fix: BBG tracing.c defines selinux_cred() which this CAF 4.14 tree
            # already declares in security/selinux/include/objsec.h — causing a
            # "redefinition" build error. Strip the duplicate from BBG's copy;
            # both are identical (cred->security accessor), so removal is safe.
            if [ -f "security/baseband-guard/tracing/tracing.c" ]; then
                python3 -c "
import re
path = 'security/baseband-guard/tracing/tracing.c'
with open(path) as f:
    src = f.read()
src = re.sub(
    r'[ \t]*static inline struct task_security_struct \*selinux_cred'
    r'\(const struct cred \*cred\)\s*\{[^}]*\}\n?',
    '', src)
with open(path, 'w') as f:
    f.write(src)
" && info "BBG: selinux_cred redefinition conflict resolved" \
               || warn "BBG: selinux_cred patch skipped (pattern not found)"
            fi
            success "KernelSU-Next ready"
            ;;

        none)
            info "KSU skipped (mode=none)"
            ;;
    esac
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
    # Watt: performance/battery/UX optimization fragment
    [ -f "arch/arm64/configs/vendor/watt.config" ] \
        && cat "arch/arm64/configs/vendor/watt.config" >> out/.config
    echo "CONFIG_LOCALVERSION=\"$KERNEL_NAME\"" >> out/.config

    # ── Step 3: Kernel Config ────────────────────
    info "Applying performance + size config overrides..."

    ./scripts/config --file out/.config \
        --disable DEBUG_INFO            \
        --disable DEBUG_INFO_REDUCED    \
        --disable DEBUG_INFO_SPLIT      \
        --disable DEBUG_INFO_DWARF4     \
        --enable  DEBUG_INFO_NONE

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

    ./scripts/config --file out/.config \
        --disable HZ_100                \
        --disable HZ_250                \
        --enable  HZ_300                \
        --set-val HZ 300

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

    # ── Watt: Performance | UI Smoothness | Battery ──────────────────────────
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

    # ── Step 4: Resolve config deps ──────────────────
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

    # ── AnyKernel3 Metadata & Packaging ──────────────────────────────────────
    info "Preparing AnyKernel3 artifacts..."
    local AK3_DIR="AnyKernel3"
    local DTB="out/arch/arm64/boot/dtb.img"
    local DTBO="out/arch/arm64/boot/dtbo.img"
    local BINFO="$AK3_DIR/buildinfo.sh"

    local FULL_DATE=$(TZ='Asia/Jakarta' date +"%A, %d %b %Y %H:%M:%S WIB")

    echo "# Houdini Build Metadata" > "$BINFO"
    echo "BUILD_DATE=\"$FULL_DATE\"" >> "$BINFO"
    echo "BUILD_TYPE=\"$KERNELSU_SELECTOR\"" >> "$BINFO"
    echo "BORE_MODE=\"$BORE_SELECTOR\"" >> "$BINFO"
    echo "F2FS_MODE=\"$F2FS_SELECTOR\"" >> "$BINFO"
    echo "TOOLCHAIN=\"$TOOLCHAIN_SELECTOR\"" >> "$BINFO"

    cp "$IMAGE" "$AK3_DIR/"
    [ -f "$DTB" ]  && cp "$DTB"  "$AK3_DIR/"
    [ -f "$DTBO" ] && cp "$DTBO" "$AK3_DIR/"

    success "AnyKernel3 ready for packaging"

    echo ""
    echo -e "\E[1;36m╭━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╮\E[0m"
    echo -e "\E[1;36m│\E[0m\E[1;32m                 BUILD SUCCESSFUL                    \E[0m\E[1;36m│\E[0m"
    echo -e "\E[1;36m├━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┤\E[0m"
    printf  "\E[1;36m│\E[0m  \E[1;37mKernel  :\E[0m \E[1;32m%-41s\E[0m\E[1;36m│\E[0m\n" "$KERNEL_NAME"
    printf  "\E[1;36m│\E[0m  \E[1;37mDevice  :\E[0m \E[1;33m%-41s\E[0m\E[1;36m│\E[0m\n" "$DEVICE_IMPORT"
    printf  "\E[1;36m│\E[0m  \E[1;37mKSU     :\E[0m \E[1;35m%-41s\E[0m\E[1;36m│\E[0m\n" "$KERNELSU_SELECTOR"
    local BORE_STATUS="ACTIVE"
    [[ "$BORE_SELECTOR" != "bore" ]] && BORE_STATUS="INACTIVE"
    printf  "\E[1;36m│\E[0m  \E[1;37mBORE    :\E[0m \E[1;32m%-41s\E[0m\E[1;36m│\E[0m\n" "$BORE_STATUS"
    local F2FS_STATUS="ACTIVE"
    [[ "$F2FS_SELECTOR" != "f2fs" ]] && F2FS_STATUS="INACTIVE"
    printf  "\E[1;36m│\E[0m  \E[1;37mF2FS    :\E[0m \E[1;33m%-41s\E[0m\E[1;36m│\E[0m\n" "$F2FS_STATUS"
    printf  "\E[1;36m│\E[0m  \E[1;37mCompiler:\E[0m \E[1;35m%-41s\E[0m\E[1;36m│\E[0m\n" "$TOOLCHAIN_SELECTOR"
    printf  "\E[1;36m│\E[0m  \E[1;37mBBG     :\E[0m \E[1;31m%-41s\E[0m\E[1;36m│\E[0m\n" "ACTIVE (Enforced)"
    printf  "\E[1;36m│\E[0m  \E[1;37mSize    :\E[0m \E[1;34m%-41s\E[0m\E[1;36m│\E[0m\n" "$SIZE"
    local TIME_STR="${MINS}m ${SECS}s"
    printf  "\E[1;36m│\E[0m  \E[1;37mTime    :\E[0m \E[1;32m%-41s\E[0m\E[1;36m│\E[0m\n" "$TIME_STR"
    echo -e "\E[1;36m├─────────────────────────────────────────────────────┤\E[0m"
    printf  "\E[1;36m│\E[0m  \E[1;37mErrors  :\E[0m \E[1;31m%-41s\E[0m\E[1;36m│\E[0m\n" "$ERR_COUNT"
    printf  "\E[1;36m│\E[0m  \E[1;37mWarnings:\E[0m \E[1;33m%-41s\E[0m\E[1;36m│\E[0m\n" "$WARN_COUNT"
    printf  "\E[1;36m│\E[0m  \E[1;37mBuilt   :\E[0m \E[1;34m%-41s\E[0m\E[1;36m│\E[0m\n" "$FULL_DATE"
    echo -e "\E[1;36m╰━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╯\E[0m"
    echo ""
    ls -alh "$IMAGE"
}

finalize_build
