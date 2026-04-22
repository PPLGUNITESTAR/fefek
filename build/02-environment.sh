#!/bin/bash
# =============================================================================
#  build/02-environment.sh — Phase 1: Toolchain setup & build environment
# =============================================================================

setup_environment() {
    # ── Maintainer ────────────────────────────────────────────────────────────
    export KBUILD_BUILD_USER=ArCHDeViL
    export KBUILD_BUILD_HOST=EviLZonE
    export GIT_NAME="$KBUILD_BUILD_USER"
    export GIT_EMAIL="${KBUILD_BUILD_USER}@${KBUILD_BUILD_HOST}"

    # ── Toolchain roots ───────────────────────────────────────────────────────
    export GCC64_ROOT="$PWD/gcc64"
    export GCC32_ROOT="$PWD/gcc32"

    # ── PATH setup ────────────────────────────────────────────────────────────
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

    # ── Fetch toolchains in parallel ─────────────────────────────────────────
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
    local _COMMON_FLAGS=(
        ARCH=arm64
        LLVM=1 LLVM_IAS=1
        CC="clang" LD=ld.lld
        AR=llvm-ar AS=llvm-as NM=llvm-nm
        OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
        CROSS_COMPILE=aarch64-linux-android-
        CROSS_COMPILE_ARM32=arm-linux-gnueabi-
        CLANG_TRIPLE=aarch64-linux-gnu-
    )

    if [[ "$TOOLCHAIN_SELECTOR" == "neutron" ]]; then
        export MAKE_ARGS=(
            "${_COMMON_FLAGS[@]}"
            KCFLAGS="-O3 -Wno-declaration-after-statement -Wno-unused-variable -Wno-void-pointer-to-int-cast"
        )
    elif [[ "$TOOLCHAIN_SELECTOR" == "lilium" || "$TOOLCHAIN_SELECTOR" == "kaleidoscope" ]]; then
        export MAKE_ARGS=(
            "${_COMMON_FLAGS[@]}"
            KCFLAGS="-O3 -mllvm -inline-threshold=200 -Wno-declaration-after-statement -Wno-unused-variable -Wno-void-pointer-to-int-cast -Wno-default-const-init-var-unsafe -Wno-default-const-init-field-unsafe -Wno-implicit-enum-enum-cast"
        )
    elif [[ "$TOOLCHAIN_SELECTOR" == "greenforce" ]]; then
        export MAKE_ARGS=(
            "${_COMMON_FLAGS[@]}"
            KCFLAGS="-O2 -Wno-declaration-after-statement -Wno-unused-variable -Wno-void-pointer-to-int-cast -Wno-default-const-init-var-unsafe -Wno-default-const-init-field-unsafe -Wno-implicit-enum-enum-cast"
        )
    fi

    success "Environment ready — $THREAD_COUNT threads available"
}
