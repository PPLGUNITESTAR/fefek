#!/bin/bash
# =============================================================================
#  build/06-compile.sh — Phase 5: Kernel compilation
# =============================================================================

compile_it() {
    info "Launching make with $THREAD_COUNT jobs..."
    make -j"$THREAD_COUNT" O=out "${MAKE_ARGS[@]}" 2>&1 | tee build.log
    local rc=${PIPESTATUS[0]}

    grep -Eiw "warning:|error:" build.log > warnings.txt || true

    export WARN_COUNT=$(grep -ciw "warning:" build.log || true)
    export ERR_COUNT=$(grep -ciw  "error:"   build.log || true)

    rm -f build.log

    [ $rc -ne 0 ] && die "Compilation exited with code $rc (Errors: $ERR_COUNT)"
    success "Compilation finished (Warnings: $WARN_COUNT, Errors: $ERR_COUNT)"
}
