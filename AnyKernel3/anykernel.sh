#!/system/bin/sh
# AnyKernel3 — Houdini Kernel for sweet (sm6150)
# osm0sis @ xda-developers

properties() { '
do.devicecheck=1
do.modules=0
do.cleanup=1
do.cleanuponabort=0
device.name1=sweet
device.name2=sweetin
supported.versions=11-16
supported.patchlevels=
supported.vendorpatchlevels=
'; }

# boot partition — sweet is non-AB, no vendor_boot
BLOCK=/dev/block/bootdevice/by-name/boot;
IS_SLOT_DEVICE=0;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import ak3 core functions
. tools/ak3-core.sh;

# Display build info if available
if [ -f buildinfo.sh ]; then
  . ./buildinfo.sh;
  ui_print " ";
  ui_print "  Build Date : $BUILD_DATE";

  # Resolve root solution name from BUILD_TYPE
  case "$BUILD_TYPE" in
    zako)
      ui_print "  Root       : ReSukiSU";
      ui_print "  SUSFS      : Disabled";;
    zako_susfs|zako-susfs)
      ui_print "  Root       : ReSukiSU";
      ui_print "  SUSFS      : Enabled";;
    ksunext)
      ui_print "  Root       : KernelSU-Next";
      ui_print "  SUSFS      : Disabled";;
    ksunext_susfs|ksunext-susfs)
      ui_print "  Root       : KernelSU-Next";
      ui_print "  SUSFS      : Enabled";;
    *)
      ui_print "  Root       : Unrooted";
      ui_print "  SUSFS      : N/A";;
  esac;

  if [ "$BORE_MODE" = "bore" ]; then
    ui_print "  BORE Sched : Active";
  else
    ui_print "  BORE Sched : Inactive";
  fi;
  if [ "$F2FS_MODE" = "f2fs" ]; then
    ui_print "  F2FS       : Enabled";
  else
    ui_print "  F2FS       : Disabled";
  fi;
  if [ "$TOOLCHAIN" = "kaleidoscope" ]; then
    ui_print "  Compiler   : Kaleidoscope Clang";
  elif [ "$TOOLCHAIN" = "lilium" ]; then
    ui_print "  Compiler   : Lilium Clang";
  elif [ "$TOOLCHAIN" = "greenforce" ]; then
    ui_print "  Compiler   : Greenforce Clang";
  else
    ui_print "  Compiler   : Neutron Clang";
  fi;
  ui_print " ";
fi;

# kernel 4.14 — non-GKI, straight dump_boot + write_boot
dump_boot;

# flash dtbo.img if present
if [ -f dtbo.img ]; then
  flash_generic dtbo;
fi;

write_boot;
