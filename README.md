# Redmi Note 10 Pro (sweet)

## Metadata Perangkat
- **Perangkat**: Redmi Note 10 Pro (Kodenama: sweet)
- **SoC**: Qualcomm Snapdragon 732G (SM6150 / SDMsteppe)
- **Arsitektur**: `arm64`
- **Defconfig Utama**: `arch/arm64/configs/vendor/sdmsteppe-perf_defconfig`
- **Config Perangkat (Append)**: `arch/arm64/configs/vendor/sweet.config`

## 1. Indexing & Project Structure

Struktur direktori kernel ini menggunakan standar Linux kernel base dengan penambahan komponen spesifik Qualcomm dan Android.

### Direktori Inti (Linux Standard Base)
- `arch/`: Kode spesifik arsitektur. Untuk perangkat ini, fokus berada di `arch/arm64/`.
- `block/`: Implementasi layer block device.
- `drivers/`: Device drivers, memuat sebagian besar implementasi fungsional hardware SoC dan periferal.
- `fs/`: Sistem file (Filesystem).
- `include/`: Kernel headers.
- `kernel/`: Subsistem inti kernel (scheduler, dts, dll).
- `mm/`: Memory management.
- `net/`: Subsistem jaringan.

### Komponen Android & Build System
- `build.config.*`: Konfigurasi sistem build Android (contoh: `build.config.common`, `build.config.aarch64`).
- `Android.mk` / `AndroidKernel.mk` / `Androidbp`: File konfigurasi AOSP Make/Blueprint untuk kompilasi kernel di dalam environment source tree Android.
- `gen_headers_arm.bp` / `gen_headers_arm64.bp`: Blueprint file untuk melakukan generasi kernel headers yang akan digunakan oleh Android userspace.

### Spesifik Qualcomm & Vendor
- `techpack/`: Out-of-tree drivers spesifik dari Qualcomm yang dipisah dari tree utama.
  - `techpack/audio/`: Driver untuk Audio DSP dan Codec.
  - `techpack/data/`: Komponen data networking Qualcomm (IPA, RMNET).
  - `techpack/stub/`: Driver stub untuk kompatibilitas API.

## 2. Arsitektur & Hierarchy Defconfig

Proses konfigurasi target "sweet" menggunakan mekanisme hierarki, menggabungkan base SoC dengan spesifikasi device.

1. **Base Configuration (SoC Level)**: Baseline konfigurasi berpusat pada Snapdragon 6150 / Steppe.
   - ↳ `sdmsteppe_defconfig` (Standar/Debug)
   - ↳ `sdmsteppe-perf_defconfig` (Performance tuned, untuk build production/user) **<- ACTUAL_MAIN_DEFCONFIG**
2. **Device-Specific Overrides (Device Level)**: File pelengkap yang di-append ke defconfig utama saat proses build untuk mengaktifkan hardware spesifik Redmi Note 10 Pro.
   - ↳ `sweet.config`

## 3. Mapping Hardware Spesifik (`sweet.config`)

Berdasarkan hasil pembacaan `sweet.config`, berikut mapping fungsionalitas hardware spesifik yang membedakan "sweet" dari baseline `sdmsteppe`:

- **Identitas Device**: `CONFIG_MACH_XIAOMI_SWEET=y`
- **Kamera**: Peningkatan fitur Spectra Camera (`CONFIG_SPECTRA_CAMERA_UPGRADE=y`) dan LDO regulator WL2866D.
- **Sensor**:
  - Kompas: AKM09970 (`CONFIG_AKM09970=y`).
  - IR Blaster (Inframerah): Mengaktifkan modul IR (`CONFIG_RC_CORE=y`, `CONFIG_LIRC=y`).
  - Proximity: Menggunakan sensor ultrasound (`CONFIG_US_PROXIMITY=y`).
- **Haptics / Getaran**: Menggunakan linear motor dari Awinic AW8624 (`CONFIG_INPUT_AW8624_HAPTIC=y`).
- **Input & Keamanan (Fingerprint)**:
  - Menggunakan modul dari FPC dan FS dengan dukungan TEE (Trusted Execution Environment).
- **Touchscreen & Layar**:
  - Mendukung banyak IC (Goodix GTX9896, FocalTech FTS K6).
  - Mengaktifkan fitur sentuh spesifik Xiaomi (`CONFIG_TOUCHSCREEN_XIAOMI_TOUCHFEATURE=y`).
- **Power & Charging**: Pengaturan charge pump via BQ2597X, K6 Charge, serta verifikasi baterai melalui DS28E16.
- **Ramoops**: Mengamankan memori sebesar 4MB (`ramoops_memreserve=4M`) untuk log panic kernel.
