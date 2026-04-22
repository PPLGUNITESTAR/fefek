#!/bin/bash
# =============================================================================
#  build/04-goodies.sh — Phase 3: BORE + Baseband Guard + KernelSU / SUSFS
# =============================================================================

add_goodies() {
    # ── BORE Scheduler ────────────────────────────────────────────────────────
    if [[ "$BORE_SELECTOR" == "bore" ]]; then
        apply_patch_list --fuzz=5 "BORE" \
            "https://github.com/ximi-mojito-test/android_kernel_xiaomi_mojito/commit/eff756aaf5d666a15d8ac19743b582c2ce0fe3aa.patch" \
            "https://github.com/ximi-mojito-test/android_kernel_xiaomi_mojito/commit/2220322065591df5ff7ae27cc1fff386d3631bd0.patch"
        echo "CONFIG_SCHED_BORE=y" >> "$MAIN_DEFCONFIG"
    else
        info "BORE scheduler skipped (mode=none)"
    fi

    # ── Baseband Guard ────────────────────────────────────────────────────────
    info "Setting up Baseband Guard..."
    curl -LSs "https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh" | bash &>/dev/null
    echo "CONFIG_BBG=y" >> "$MAIN_DEFCONFIG"
    success "Baseband Guard enabled"

    # ── KernelSU + optional SUSFS ─────────────────────────────────────────────
    local BACKPORT="https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd/raw/refs/heads/mainline/Patches/backport_patches.sh"
    local SUSFS_PATCH="https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd/raw/refs/heads/mainline/Patches/Patch/susfs_patch_to_${KERNEL_VERSION}.patch"
    local HOOK_SUSFS="https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd/raw/refs/heads/mainline/Patches/susfs_inline_hook_patches.sh"
    local HOOK_SYSCALL="https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd/raw/refs/heads/mainline/Patches/syscall_hook_patches.sh"

    # ── Helper: append SUSFS configs ─────────────────────────────────────────
    _append_susfs_configs() {
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
    }

    case "$KERNELSU_SELECTOR" in
        zako|zako_susfs|zako-susfs)
            # ── ReSukiSU ─────────────────────────────────────────────────────
            info "Setting up ReSukiSU..."
            local KSU_URI="https://github.com/ReSukiSU/ReSukiSU/raw/refs/heads/main/kernel/setup.sh"
            curl -LSs --fail --retry 3 "$KSU_URI" \
                | bash -s main &>/dev/null \
                || die "ReSukiSU setup script failed to download/run"

            {
                echo "CONFIG_KSU=y"
                echo "CONFIG_KSU_MULTI_MANAGER_SUPPORT=y"
                echo "CONFIG_KPM=n"
                echo "CONFIG_KSU_MANUAL_HOOK=y"
                echo "CONFIG_HAVE_SYSCALL_TRACEPOINTS=y"
                echo "CONFIG_THREAD_INFO_IN_TASK=y"
            } >> "$MAIN_DEFCONFIG"

            local KSU_HOOK="$HOOK_SYSCALL"
            if [[ "$KERNELSU_SELECTOR" == "zako_susfs" || "$KERNELSU_SELECTOR" == "zako-susfs" ]]; then
                apply_patch_list --fuzz=5 "SUSFS ($KERNEL_VERSION)" "$SUSFS_PATCH"
                _append_susfs_configs
                KSU_HOOK="$HOOK_SUSFS"
            else
                info "ReSukiSU without SUSFS"
            fi

            info "Applying backport + hook patches..."
            curl -LSs "$BACKPORT" | bash &>/dev/null
            curl -LSs "$KSU_HOOK" | bash &>/dev/null
            success "ReSukiSU ready"
            ;;



        none)
            info "KSU skipped (mode=none)"
            ;;
    esac
}
