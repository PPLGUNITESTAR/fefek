#!/bin/bash
# =============================================================================
#  Houdini Build Script v3.2 — sweet (sm6150/SDM732G)
#  Maintainer : 0xArCHDeViL @ EviLZonE
#
#  Orchestrator — all logic lives in build/
#    00-common.sh     Helpers, colors, banner
#    01-validate.sh   Argument validation
#    02-environment.sh Toolchain setup
#    03-patches.sh    Device patches
#    04-goodies.sh    BORE + BBG + KernelSU/SUSFS
#    05-precompile.sh Config assembly
#    06-compile.sh    make
#    07-finalize.sh   AnyKernel3 + summary
# =============================================================================

# Resolve the directory this script lives in so sourcing works from any CWD
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"

# ── Source all modules ────────────────────────────────────────────────────────
chmod +x "$BUILD_DIR"/*.sh
for _mod in \
    "$BUILD_DIR/00-common.sh" \
    "$BUILD_DIR/01-validate.sh" \
    "$BUILD_DIR/02-environment.sh" \
    "$BUILD_DIR/03-patches.sh" \
    "$BUILD_DIR/04-goodies.sh" \
    "$BUILD_DIR/05-precompile.sh" \
    "$BUILD_DIR/06-compile.sh" \
    "$BUILD_DIR/07-finalize.sh"
do
    # shellcheck source=/dev/null
    source "$_mod" || { echo "[✗] Failed to source $_mod"; exit 1; }
done
unset _mod

# ── Timing ────────────────────────────────────────────────────────────────────
BUILD_START=$(date +%s)

# =============================================================================
#  Phase 0 — Input Validation
# =============================================================================
phase "Phase 0 · Input Validation"
validate_args "$@"
_banner

# =============================================================================
#  Phase 1 — Environment Setup
# =============================================================================
phase "Phase 1 · Environment Setup"
setup_environment

# =============================================================================
#  Phase 2 — Device Patches
# =============================================================================
phase "Phase 2 · Device Patches"
apply_device_patches

# =============================================================================
#  Phase 3 — Goodies (BORE + BBG + KSU/SUSFS)
# =============================================================================
phase "Phase 3 · Goodies Injection"
add_goodies

# =============================================================================
#  Phase 4 — Pre-compile
# =============================================================================
phase "Phase 4 · Pre-compile Configuration"
before_compile

# =============================================================================
#  Phase 5 — Compile
# =============================================================================
phase "Phase 5 · Compilation  ($THREAD_COUNT threads)"
compile_it

# =============================================================================
#  Phase 6 — Finalize
# =============================================================================
phase "Phase 6 · Finalize"
finalize_build
