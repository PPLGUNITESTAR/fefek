#!/bin/bash
# =============================================================================
#  build/00-common.sh — Shared helpers, color aliases, logging, banner
#  Sourced by sweet.sh before any other module.
# =============================================================================

# ── Color aliases ─────────────────────────────────────────────────────────────
_C="\033[0m"  _R="\033[1;31m"  _G="\033[1;32m"  _Y="\033[1;33m"
_M="\033[1;35m" _CY="\033[1;36m" _W="\033[1;37m"  _D="\033[0;90m"

# ── Logging helpers ───────────────────────────────────────────────────────────
info()    { echo "  [*] $*"; }
success() { echo "  [✓] $*"; }
warn()    { echo "  [!] $*"; }
die()     { echo "  [✗] $*"; exit 1; }
phase()   { echo ""; echo "━━━ $* ━━━"; }

# ── Banner ────────────────────────────────────────────────────────────────────
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
  [[ "$TOOLCHAIN_SELECTOR" == "lilium"       ]] && TC_DISP="Lilium Clang + LLD"
  [[ "$TOOLCHAIN_SELECTOR" == "kaleidoscope" ]] && TC_DISP="Kaleidoscope Clang + LLD"
  [[ "$TOOLCHAIN_SELECTOR" == "greenforce"   ]] && TC_DISP="Greenforce Clang + LLD"
  echo -e "    ${_D}Toolchain  : ${_CY}${TC_DISP}${E}"
  echo -e "${B}   -----------------------------------------------${E}"
  echo ""
}

# =============================================================================
#  Global patch helpers — available to all build modules
# =============================================================================

# apply_patch_list [--fuzz=N] <label> <url> [<url>...]
#   Downloads each patch to a temp file, detects already-applied patches via
#   dry-run, and prints per-patch numbered status: OK / SKIP / WARN / FAIL.
#   Optional --fuzz=N is forwarded to patch(1) for fuzzy context matching.
#   Prints a group summary on completion.
apply_patch_list() {
    # Optional --fuzz=N flag
    local fuzz_arg=""
    if [[ "$1" == --fuzz=* ]]; then
        fuzz_arg="$1"; shift
    fi

    local label="$1"; shift
    local urls=("$@")
    local total=${#urls[@]}
    local passed=0 failed=0 skipped=0 idx=1

    info "Applying $label patches ($total total)${fuzz_arg:+ [$fuzz_arg]}..."

    for url in "${urls[@]}"; do
        local short_hash
        short_hash="$(basename "$url" .patch | cut -c1-12)"

        printf "  [%2d/%2d] %s ... " "$idx" "$total" "$short_hash"

        local tmpfile
        tmpfile="$(mktemp /tmp/patch_XXXXXX.patch)"

        if ! wget -q --timeout=30 -O "$tmpfile" "$url"; then
            echo "FAIL (download error)"
            warn "         URL: $url"
            rm -f "$tmpfile"
            failed=$((failed + 1)); idx=$((idx + 1))
            continue
        fi

        # Already applied? dry-run the reverse
        if patch --dry-run -R -s -p1 < "$tmpfile" &>/dev/null; then
            echo "SKIP (already applied)"
            rm -f "$tmpfile"
            skipped=$((skipped + 1)); idx=$((idx + 1))
            continue
        fi

        local patch_out
        # shellcheck disable=SC2086  # fuzz_arg is intentionally unquoted
        if patch_out="$(patch -p1 --no-backup-if-mismatch $fuzz_arg < "$tmpfile" 2>&1)"; then
            if echo "$patch_out" | grep -qE "offset|fuzz|Hunk"; then
                echo "WARN (applied with fuzz/offset)"
                echo "$patch_out" | grep -E "offset|fuzz|Hunk" \
                    | sed 's/^/             /'
            else
                echo "OK"
            fi
            passed=$((passed + 1))
        else
            echo "FAIL (rejected)"
            echo "$patch_out" | tail -5 | sed 's/^/             /'
            warn "         URL: $url"
            failed=$((failed + 1))
        fi

        rm -f "$tmpfile"
        idx=$((idx + 1))
    done

    if [[ $failed -eq 0 ]]; then
        success "$label: $passed applied, $skipped skipped — all OK"
    else
        warn "$label: $passed OK, $skipped skipped, $failed FAILED"
    fi
}

# revert_patch_list <label> <url> [<url>...]
#   Same as apply_patch_list but applies patches in reverse (-R).
#   Skips patches that are already reverted.
revert_patch_list() {
    local label="$1"; shift
    local urls=("$@")
    local total=${#urls[@]}
    local passed=0 failed=0 skipped=0 idx=1

    info "Reverting $label patches ($total total)..."

    for url in "${urls[@]}"; do
        local short_hash
        short_hash="$(basename "$url" .patch | cut -c1-12)"

        printf "  [%2d/%2d] %s ... " "$idx" "$total" "$short_hash"

        local tmpfile
        tmpfile="$(mktemp /tmp/patch_XXXXXX.patch)"

        if ! wget -q --timeout=30 -O "$tmpfile" "$url"; then
            echo "FAIL (download error)"
            warn "         URL: $url"
            rm -f "$tmpfile"
            failed=$((failed + 1)); idx=$((idx + 1))
            continue
        fi

        # Already reverted? forward dry-run would succeed → not yet reverted
        if patch --dry-run -s -p1 < "$tmpfile" &>/dev/null; then
            : # still applied forward, we can revert
        else
            echo "SKIP (already reverted)"
            rm -f "$tmpfile"
            skipped=$((skipped + 1)); idx=$((idx + 1))
            continue
        fi

        local patch_out
        if patch_out="$(patch -R -p1 --no-backup-if-mismatch < "$tmpfile" 2>&1)"; then
            if echo "$patch_out" | grep -qE "offset|fuzz|Hunk"; then
                echo "WARN (reverted with fuzz/offset)"
                echo "$patch_out" | grep -E "offset|fuzz|Hunk" \
                    | sed 's/^/             /'
            else
                echo "OK"
            fi
            passed=$((passed + 1))
        else
            echo "FAIL (revert rejected)"
            echo "$patch_out" | tail -5 | sed 's/^/             /'
            warn "         URL: $url"
            failed=$((failed + 1))
        fi

        rm -f "$tmpfile"
        idx=$((idx + 1))
    done

    if [[ $failed -eq 0 ]]; then
        success "$label reverts: $passed applied, $skipped skipped — all OK"
    else
        warn "$label reverts: $passed OK, $skipped skipped, $failed FAILED"
    fi
}

