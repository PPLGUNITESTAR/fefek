#!/bin/bash
# =============================================================================
#  build/07-finalize.sh — Phase 6: AnyKernel3 packaging & build summary
# =============================================================================

finalize_build() {
    local IMAGE="out/arch/arm64/boot/Image.gz"
    local DTB="out/arch/arm64/boot/dtb.img"
    local DTBO="out/arch/arm64/boot/dtbo.img"

    if [ ! -f "$IMAGE" ]; then
        die "Image.gz not found — build failed"
    fi

    # ── Timing ────────────────────────────────────────────────────────────────
    local BUILD_END
    BUILD_END=$(date +%s)
    local ELAPSED=$(( BUILD_END - BUILD_START ))
    local MINS=$(( ELAPSED / 60 ))
    local SECS=$(( ELAPSED % 60 ))
    local SIZE
    SIZE=$(du -sh "$IMAGE" | cut -f1)
    local FULL_DATE
    FULL_DATE=$(TZ='Asia/Jakarta' date +"%A, %d %b %Y %H:%M:%S WIB")

    # ── Sanitize counters ─────────────────────────────────────────────────────
    WARN_COUNT=${WARN_COUNT:-0}
    ERR_COUNT=${ERR_COUNT:-0}
    PATCH_FAILED_TOTAL=${PATCH_FAILED_TOTAL:-0}

    # ── AnyKernel3 packaging ──────────────────────────────────────────────────
    info "Preparing AnyKernel3 artifacts..."
    local AK3_DIR="AnyKernel3"
    local BINFO="$AK3_DIR/buildinfo.sh"

    # Detect which optional images exist
    local DTB_STATUS="missing"
    local DTBO_STATUS="missing"

    cp "$IMAGE" "$AK3_DIR/"

    if [ -f "$DTB" ]; then
        cp "$DTB" "$AK3_DIR/"
        DTB_STATUS="$(du -sh "$DTB" | cut -f1)"
        info "DTB   copied → $DTB_STATUS"
    else
        warn "DTB   not found — skipped"
    fi

    if [ -f "$DTBO" ]; then
        cp "$DTBO" "$AK3_DIR/"
        DTBO_STATUS="$(du -sh "$DTBO" | cut -f1)"
        info "DTBO  copied → $DTBO_STATUS"
    else
        warn "DTBO  not found — skipped"
    fi

    # ── buildinfo.sh metadata ─────────────────────────────────────────────────
    {
        echo "# Houdini Build Metadata"
        echo "BUILD_DATE=\"$FULL_DATE\""
        echo "BUILD_TYPE=\"$KERNELSU_SELECTOR\""
        echo "BORE_MODE=\"$BORE_SELECTOR\""
        echo "F2FS_MODE=\"$F2FS_SELECTOR\""
        echo "TOOLCHAIN=\"$TOOLCHAIN_SELECTOR\""
        echo "CLANG_VER=\"$(clang --version 2>/dev/null | head -1 || echo unknown)\""
        echo "KERNEL_VERSION=\"$KERNEL_VERSION\""
        echo "PATCH_FAILED=\"$PATCH_FAILED_TOTAL\""
        echo "COMPILE_WARNINGS=\"$WARN_COUNT\""
        echo "COMPILE_ERRORS=\"$ERR_COUNT\""
        echo "BUILD_TIME=\"${MINS}m ${SECS}s\""
    } > "$BINFO"

    success "AnyKernel3 ready for packaging"

    # ── Status strings ────────────────────────────────────────────────────────
    local BORE_STR="INACTIVE"
    [[ "$BORE_SELECTOR" == "bore" ]] && BORE_STR="ACTIVE"

    local F2FS_STR="INACTIVE"
    [[ "$F2FS_SELECTOR" == "f2fs" ]] && F2FS_STR="ACTIVE"

    # PATCH health: green if zero failures, red otherwise
    local PATCH_STR
    if [[ "$PATCH_FAILED_TOTAL" -eq 0 ]]; then
        PATCH_STR="OK (0 failures)"
    else
        PATCH_STR="DEGRADED ($PATCH_FAILED_TOTAL failed)"
    fi

    # Toolchain display name
    local TC_DISP="Neutron Clang"
    [[ "$TOOLCHAIN_SELECTOR" == "lilium"       ]] && TC_DISP="Lilium Clang"
    [[ "$TOOLCHAIN_SELECTOR" == "kaleidoscope" ]] && TC_DISP="Kaleidoscope Clang"
    [[ "$TOOLCHAIN_SELECTOR" == "greenforce"   ]] && TC_DISP="Greenforce Clang"

    local TIME_STR="${MINS}m ${SECS}s"

    # ── Color refs (from 00-common.sh) ────────────────────────────────────────
    local CY="\E[1;36m" W="\E[1;37m" G="\E[1;32m" Y="\E[1;33m"
    local M="\E[1;35m"  R="\E[1;31m" B="\E[1;34m" NC="\E[0m"

    # Patch status color
    local PATCH_COLOR="$G"
    [[ "$PATCH_FAILED_TOTAL" -gt 0 ]] && PATCH_COLOR="$R"

    # Compile error color
    local ERR_COLOR="$G"
    [[ "$ERR_COUNT" -gt 0 ]] && ERR_COLOR="$R"
    local WARN_COLOR="$G"
    [[ "$WARN_COUNT" -gt 0 ]] && WARN_COLOR="$Y"

    # ── Summary box ───────────────────────────────────────────────────────────
    echo ""
    echo -e "${CY}╭━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╮${NC}"
    echo -e "${CY}│${NC}${G}                 BUILD SUCCESSFUL                    ${NC}${CY}│${NC}"
    echo -e "${CY}├━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┤${NC}"
    printf  "${CY}│${NC}  ${W}Kernel  :${NC} ${G}%-41s${NC}${CY}│${NC}\n" "$KERNEL_NAME"
    printf  "${CY}│${NC}  ${W}Device  :${NC} ${Y}%-41s${NC}${CY}│${NC}\n" "$DEVICE_IMPORT"
    printf  "${CY}│${NC}  ${W}KSU     :${NC} ${M}%-41s${NC}${CY}│${NC}\n" "$KERNELSU_SELECTOR"
    printf  "${CY}│${NC}  ${W}BORE    :${NC} ${G}%-41s${NC}${CY}│${NC}\n" "$BORE_STR"
    printf  "${CY}│${NC}  ${W}F2FS    :${NC} ${Y}%-41s${NC}${CY}│${NC}\n" "$F2FS_STR"
    printf  "${CY}│${NC}  ${W}BBG     :${NC} ${R}%-41s${NC}${CY}│${NC}\n" "ACTIVE (Enforced)"
    printf  "${CY}│${NC}  ${W}Compiler:${NC} ${M}%-41s${NC}${CY}│${NC}\n" "$TC_DISP"
    printf  "${CY}│${NC}  ${W}Size    :${NC} ${B}%-41s${NC}${CY}│${NC}\n" "$SIZE"
    printf  "${CY}│${NC}  ${W}Time    :${NC} ${G}%-41s${NC}${CY}│${NC}\n" "$TIME_STR"
    echo -e "${CY}├─────────────────────────────────────────────────────┤${NC}"
    printf  "${CY}│${NC}  ${W}Patches :${NC} ${PATCH_COLOR}%-41s${NC}${CY}│${NC}\n" "$PATCH_STR"
    printf  "${CY}│${NC}  ${W}Errors  :${NC} ${ERR_COLOR}%-41s${NC}${CY}│${NC}\n" "$ERR_COUNT"
    printf  "${CY}│${NC}  ${W}Warnings:${NC} ${WARN_COLOR}%-41s${NC}${CY}│${NC}\n" "$WARN_COUNT"
    printf  "${CY}│${NC}  ${W}Built   :${NC} ${B}%-41s${NC}${CY}│${NC}\n" "$FULL_DATE"
    echo -e "${CY}╰━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╯${NC}"
    echo ""
    ls -alh "$IMAGE"
}
