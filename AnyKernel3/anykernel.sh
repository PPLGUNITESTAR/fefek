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

# kernel 4.14 — non-GKI, straight dump_boot + write_boot
dump_boot;

# flash dtbo.img if present
if [ -f dtbo.img ]; then
  flash_generic dtbo;
fi;

write_boot;
