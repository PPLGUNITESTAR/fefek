#!/bin/bash
# =============================================================================
#  build/07-finalize.sh — Phase 6: AnyKernel3 packaging & build summary
# =============================================================================

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

    {
        echo "# Houdini Build Metadata"
        echo "BUILD_DATE=\"$FULL_DATE\""
        echo "BUILD_TYPE=\"$KERNELSU_SELECTOR\""
        echo "BORE_MODE=\"$BORE_SELECTOR\""
        echo "F2FS_MODE=\"$F2FS_SELECTOR\""
        echo "TOOLCHAIN=\"$TOOLCHAIN_SELECTOR\""
    } > "$BINFO"

    cp "$IMAGE" "$AK3_DIR/"
    [ -f "$DTB"  ] && cp "$DTB"  "$AK3_DIR/"
    [ -f "$DTBO" ] && cp "$DTBO" "$AK3_DIR/"

    success "AnyKernel3 ready for packaging"

    # ── Build summary box ─────────────────────────────────────────────────────
    local BORE_STATUS="ACTIVE";  [[ "$BORE_SELECTOR" != "bore" ]] && BORE_STATUS="INACTIVE"
    local F2FS_STATUS="ACTIVE";  [[ "$F2FS_SELECTOR" != "f2fs" ]] && F2FS_STATUS="INACTIVE"
    local TIME_STR="${MINS}m ${SECS}s"

    echo ""
    echo -e "\E[1;36m╭━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╮\E[0m"
    echo -e "\E[1;36m│\E[0m\E[1;32m                 BUILD SUCCESSFUL                    \E[0m\E[1;36m│\E[0m"
    echo -e "\E[1;36m├━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┤\E[0m"
    printf  "\E[1;36m│\E[0m  \E[1;37mKernel  :\E[0m \E[1;32m%-41s\E[0m\E[1;36m│\E[0m\n" "$KERNEL_NAME"
    printf  "\E[1;36m│\E[0m  \E[1;37mDevice  :\E[0m \E[1;33m%-41s\E[0m\E[1;36m│\E[0m\n" "$DEVICE_IMPORT"
    printf  "\E[1;36m│\E[0m  \E[1;37mKSU     :\E[0m \E[1;35m%-41s\E[0m\E[1;36m│\E[0m\n" "$KERNELSU_SELECTOR"
    printf  "\E[1;36m│\E[0m  \E[1;37mBORE    :\E[0m \E[1;32m%-41s\E[0m\E[1;36m│\E[0m\n" "$BORE_STATUS"
    printf  "\E[1;36m│\E[0m  \E[1;37mF2FS    :\E[0m \E[1;33m%-41s\E[0m\E[1;36m│\E[0m\n" "$F2FS_STATUS"
    printf  "\E[1;36m│\E[0m  \E[1;37mCompiler:\E[0m \E[1;35m%-41s\E[0m\E[1;36m│\E[0m\n" "$TOOLCHAIN_SELECTOR"
    printf  "\E[1;36m│\E[0m  \E[1;37mBBG     :\E[0m \E[1;31m%-41s\E[0m\E[1;36m│\E[0m\n" "ACTIVE (Enforced)"
    printf  "\E[1;36m│\E[0m  \E[1;37mSize    :\E[0m \E[1;34m%-41s\E[0m\E[1;36m│\E[0m\n" "$SIZE"
    printf  "\E[1;36m│\E[0m  \E[1;37mTime    :\E[0m \E[1;32m%-41s\E[0m\E[1;36m│\E[0m\n" "$TIME_STR"
    echo -e "\E[1;36m├─────────────────────────────────────────────────────┤\E[0m"
    printf  "\E[1;36m│\E[0m  \E[1;37mErrors  :\E[0m \E[1;31m%-41s\E[0m\E[1;36m│\E[0m\n" "$ERR_COUNT"
    printf  "\E[1;36m│\E[0m  \E[1;37mWarnings:\E[0m \E[1;33m%-41s\E[0m\E[1;36m│\E[0m\n" "$WARN_COUNT"
    printf  "\E[1;36m│\E[0m  \E[1;37mBuilt   :\E[0m \E[1;34m%-41s\E[0m\E[1;36m│\E[0m\n" "$FULL_DATE"
    echo -e "\E[1;36m╰━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╯\E[0m"
    echo ""
    ls -alh "$IMAGE"
}
