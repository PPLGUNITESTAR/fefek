# Redmi Note 10 Pro (sweet) - Houdini Kernel

This repository contains the source code, patching system, and build pipeline for the Houdini Kernel, explicitly tuned for the Xiaomi Redmi Note 10 Pro (sm6150 / SDM732G).

We don't just host a static codebase; we actively pull, patch, and reconfigure the kernel locally at compile time. This README breaks down the actual device hardware maps, the build script logic, and the aggressive compiler choices we use to squeeze out performance.

## 📱 Core Metadata

- **Codename**: sweet
- **SoC**: Qualcomm Snapdragon 732G (SM6150)
- **Architecture**: `arm64`
- **Base Defconfig**: `arch/arm64/configs/vendor/sdmsteppe-perf_defconfig`
- **Device Overrides**: `arch/arm64/configs/vendor/sweet.config`

---

## 🛠️ The Build Pipeline (`sweet.sh`)

Our CI/CD pipeline runs entirely through a modular bash script (`sweet.sh`). Instead of maintaining a dozen different github branches for every feature combination, the script takes arguments straight from GitHub Actions to construct the exact kernel variant you want on the fly.

### Toolchain Choices

You can choose your poison when it comes to the compiler:

1. **Neutron Clang + GCC**: The stable default. The script fetches the latest Neutron release via Antman and uses Greenforce GCC for cross-compilation linking.
2. **Lilium Clang (Exclusive)**: An experimental setup leveraging LTO, PGO, and BOLT optimizations. It uses integrated LLVM binutils, completely bypassing standalone GCC. We've actively suppressed some strict Clang 18+ warnings here just to get Qualcomm's legacy code to compile without screaming.

### Aggressive Stripping & Tuning

We use `scripts/config` to rewrite the generated `.config` before the build starts:

- Forced `-O3` overrides `-O2` globally.
- `LTO_CLANG_FULL` is enabled for maximum binary size reduction at link time.
- Polly vectorization flags (`-mllvm -polly`) are passed directly into `KCFLAGS`.
- Heavy debugging systems (Ftrace, Slub Debug, Kprobes, Scheduler Debug, Spinlock checking) are ripped out to kill overhead.
- Timer frequency is hardcoded to `HZ=300`.

---

## 🧬 Dynamic Injection

Before a single object file is compiled, we patch the source tree with external code.

### Root & Security

- **KernelSU (ReSukiSU)**: We inject the KernelSU setup script directly. Depending on the build variant, it uses standard syscall hooks or manual hooks.
- **SUSFS**: For the `zako_susfs` variant, JackA1ltman's patches are pulled down to actively spoof `uname` and hide the KSU footprint from banking apps.
- **Baseband Guard (BBG)**: Pulled and enforced automatically to protect modem integrity.

### Schedulers & File Systems

- **BORE (Burst-Oriented Response Enhancer)**: We pull remote commits to replace standard CFS logic, prioritizing UI responsiveness and burst workloads.
- **F2FS Compression**: Toggles LZ4 compression for F2FS. The script handles reverting conflicting commits and applying the clean patch path automatically.

### Device-level Code Fixes

- **LN8000 Charger**: 10 separate remote commits are applied to address power management flaws in the LN8000 IC.
- **SDE Screen Tearing**: Manual display serial interface (DSI) and DTBO patches to stop horizontal tearing during sleep/wake cycles.

---

## 🗺️ Project Structure & Hardware Map

For anyone reading the actual repository code, here is how the hardware functionally maps to our custom configuration rules:

### Directory Layout

- `arch/arm64/`: Where the main target definitions live.
- `techpack/audio/`: Qualcomm's out-of-tree audio DSP and codec drivers.
- `techpack/data/`: IPA and RMNET networking components.
- `drivers/`: The bulk of the functional hardware drivers.

### Deep Dive: `sweet.config` Hardware

While `sdmsteppe` handles the base chipset, the `sweet.config` file explicitly defines the Redmi Note 10 Pro components:

- **Cameras**: Upgrades Spectra camera capabilities (`CONFIG_SPECTRA_CAMERA_UPGRADE=y`) and hooks the WL2866D LDO regulator.
- **Sensors**:
  - Hooks the AKM09970 compass.
  - Enables the hardware IR blaster (`CONFIG_LIRC=y`).
  - Activates the ultrasound proximity setup (`CONFIG_US_PROXIMITY=y`).
- **Haptics**: Uses the Awinic AW8624 linear motor for specific system vibrations.
- **Biometrics**: FPC and Goodix fingerprint modules wrapped in Trusted Execution Environment (TEE) boundaries.
- **Touch & Display**: Incorporates Goodix GTX9896 and FocalTech FTS K6 touch ICs, explicitly exposing Xiaomi's proprietary touch feature interface (`CONFIG_TOUCHSCREEN_XIAOMI_TOUCHFEATURE=y`).
- **Power**: Dictated by the BQ2597X charge pump and verified by the DS28E16 battery authorization chain.
- **Crash Logging**: Preserves a strict 4MB memory boundary (`ramoops_memreserve=4M`) to retain kernel panics across forced reboots.

---

## 📦 Final Packaging

After the build completes, the script checks exactly what features were injected and generates a `buildinfo.sh` file. The resulting `Image.gz`, custom `dtb`, and `dtbo` are tossed into an AnyKernel3 folder and compressed using `advzip` (at compression level 4, 100 iterations) to produce the smallest possible flashable `.zip`.

Ready to flash via recovery on Android 11 through 16.
