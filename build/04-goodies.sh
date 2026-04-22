#!/bin/bash
# =============================================================================
#  build/04-goodies.sh — Phase 3: BORE + Baseband Guard + KernelSU / SUSFS
# =============================================================================

add_goodies() {
    # ── BORE Scheduler ────────────────────────────────────────────────────────
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
                info "Applying SUSFS patch (JackA1ltman/$KERNEL_VERSION)..."
                wget -qO- "$SUSFS_PATCH" | patch -s -p1 --fuzz=5
                _append_susfs_configs
                KSU_HOOK="$HOOK_SUSFS"
                success "SUSFS enabled"
            else
                info "ReSukiSU without SUSFS"
            fi

            info "Applying backport + hook patches..."
            curl -LSs "$BACKPORT" | bash &>/dev/null
            curl -LSs "$KSU_HOOK" | bash &>/dev/null
            success "ReSukiSU ready"
            ;;

        ksunext|ksunext_susfs)
            # ── KernelSU-Next ─────────────────────────────────────────────────
            info "Setting up KernelSU-Next..."
            local KSU_URI="https://github.com/KernelSU-Next/KernelSU-Next/raw/refs/heads/dev/kernel/setup.sh"
            local KSU_BRANCH="legacy"
            [[ "$KERNELSU_SELECTOR" == "ksunext_susfs" ]] && KSU_BRANCH="legacy_susfs"

            curl -LSs --fail --retry 3 "$KSU_URI" \
                | bash -s $KSU_BRANCH &>/dev/null \
                || die "KernelSU-Next setup script failed to download/run"

            {
                echo "CONFIG_KSU=y"
                echo "CONFIG_KSU_MANUAL_HOOK=y"
                echo "CONFIG_HAVE_SYSCALL_TRACEPOINTS=y"
                echo "CONFIG_THREAD_INFO_IN_TASK=y"
            } >> "$MAIN_DEFCONFIG"

            local KSU_HOOK="$HOOK_SYSCALL"
            if [[ "$KERNELSU_SELECTOR" == "ksunext_susfs" ]]; then
                info "Applying SUSFS patch (JackA1ltman/$KERNEL_VERSION)..."
                wget -qO- "$SUSFS_PATCH" | patch -s -p1 --fuzz=5
                _append_susfs_configs
                KSU_HOOK="$HOOK_SUSFS"
                # Fix: KernelSU-Next supercall.c calls susfs_add_try_umount()
                # (and other SUSFS functions) but does not #include <linux/susfs.h>.
                # The JackA1ltman SUSFS patch adds the header to the kernel tree but
                # does not update KernelSU-Next's out-of-tree source includes.
                # Injecting the include here resolves the implicit-function-declaration
                # -Werror that otherwise aborts the build.
                local _SUPERCALL="drivers/kernelsu/supercall/supercall.c"
                if [ -f "$_SUPERCALL" ] && \
                   grep -q "susfs_" "$_SUPERCALL" && \
                   ! grep -q "linux/susfs.h" "$_SUPERCALL"; then
                    python3 -c "
import re
path = '$_SUPERCALL'
with open(path) as f:
    src = f.read()
# Insert after the last #include block at the top of the file
src = re.sub(
    r'((?:[ \t]*#include\s+[<\"][^\n]+\n)+)',
    lambda m: m.group(0) + '#include <linux/susfs.h>\n',
    src, count=1)
with open(path, 'w') as f:
    f.write(src)
" && info "KernelSU-Next: injected <linux/susfs.h> into supercall.c" \
                       || warn "KernelSU-Next: susfs.h injection skipped"
                fi
                success "SUSFS enabled"
            else
                info "KernelSU-Next without SUSFS"
            fi

            info "Applying backport + hook patches..."
            curl -LSs "$BACKPORT" | bash &>/dev/null
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
