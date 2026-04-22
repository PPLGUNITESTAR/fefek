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
