#!/bin/bash
# =============================================================================
#  build/01-validate.sh — Phase 0: Input argument validation
#  Expects: $1=device $2=ksu_mode $3=bore_mode $4=f2fs_mode $5=toolchain
# =============================================================================

validate_args() {
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

    success "Args OK — device=$DEVICE_IMPORT ksu=$KERNELSU_SELECTOR bore=$BORE_SELECTOR f2fs=$F2FS_SELECTOR toolchain=$TOOLCHAIN_SELECTOR"
}
