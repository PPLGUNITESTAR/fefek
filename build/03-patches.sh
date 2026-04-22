#!/bin/bash
# =============================================================================
#  build/03-patches.sh — Phase 2: Device-specific source patches
# =============================================================================

apply_device_patches() {
    # ── Helper: apply a list of remote patches ────────────────────────────────
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
    local LN8K_PATCHES=(
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
    local DTBO_PATCHES=(
        "https://github.com/xiaomi-sm6150/android_kernel_xiaomi_sm6150/commit/e517bc363a19951ead919025a560f843c2c03ad3.patch"
        "https://github.com/xiaomi-sm6150/android_kernel_xiaomi_sm6150/commit/a62a3b05d0f29aab9c4bf8d15fe786a8c8a32c98.patch"
        "https://github.com/xiaomi-sm6150/android_kernel_xiaomi_sm6150/commit/4b89948ec7d610f997dd1dab813897f11f403a06.patch"
        "https://github.com/xiaomi-sm6150/android_kernel_xiaomi_sm6150/commit/fade7df36b01f2b170c78c63eb8fe0d11c613c4a.patch"
        "https://github.com/xiaomi-sm6150/android_kernel_xiaomi_sm6150/commit/2628183db0d96be8dae38a21f2b09cb10978f423.patch"
        "https://github.com/xiaomi-sm6150/android_kernel_xiaomi_sm6150/commit/31f4577af3f8255ae503a5b30d8f68906edde85f.patch"
    )

    apply_patch_list "LN8K" "${LN8K_PATCHES[@]}"
    apply_patch_list "DTBO" "${DTBO_PATCHES[@]}"

    # ── F2FS Compression (optional) ───────────────────────────────────────────
    if [[ "$F2FS_SELECTOR" == "f2fs" ]]; then
        info "Applying F2FS Compression patches..."
        local REVERT_F2FS=(
            "https://github.com/xiaomi-sm6150/android_kernel_xiaomi_sm6150/commit/212f6697ff90336cc993d163411775ec969deeb6.patch"
            "https://github.com/xiaomi-sm6150/android_kernel_xiaomi_sm6150/commit/694585a55caa3e1873c889ab3aa1c47d93144fad.patch"
        )
        revert_patch_list "F2FS Reverts" "${REVERT_F2FS[@]}"
        apply_patch_list "F2FS Compression" \
            "https://github.com/tbyool/android_kernel_xiaomi_sm6150/commit/02baeab5aaf5319e5d68f2319516efed262533ea.patch"
        echo "CONFIG_F2FS_FS_COMPRESSION=y" >> "$MAIN_DEFCONFIG"
        echo "CONFIG_F2FS_FS_LZ4=y"         >> "$MAIN_DEFCONFIG"
        success "F2FS patches applied"
    else
        info "F2FS Compression skipped (mode=none)"
    fi

    # ── Build-system fixes ────────────────────────────────────────────────────
    info "Applying LTO fix patch..."
    wget -qO- "https://github.com/TheSillyOk/kernel_ls_patches/raw/refs/heads/master/fix_lto.patch" | patch -s -p1

    info "Applying kpatch fix patch..."
    wget -qO- "https://github.com/TheSillyOk/kernel_ls_patches/raw/refs/heads/master/kpatch_fix.patch" | patch -s -p1

    # ── Config additions ──────────────────────────────────────────────────────
    echo "CONFIG_CHARGER_LN8000=y"         >> "$MAIN_DEFCONFIG"
    echo "CONFIG_EROFS_FS=y"               >> "$MAIN_DEFCONFIG"
    echo "CONFIG_SECURITY_SELINUX_DEVELOP=y" >> "$MAIN_DEFCONFIG"

    # ── Missing Headers ───────────────────────────────────────────────────────
    info "Patching missing uaccess header for perf_trace_user..."
    [ -f arch/arm64/kernel/perf_trace_user.c ] \
        && sed -i '1i #include <linux/uaccess.h>' arch/arm64/kernel/perf_trace_user.c

    success "Device patches applied"
}
