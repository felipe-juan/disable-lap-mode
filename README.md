# Disable ThinkPad Lap Detection (disable-lapmode.sh)

A script that permanently disables the lap detection sensor on ThinkPad laptops by patching the `thinkpad_acpi` kernel module. Uses DKMS to automatically reapply the patch after every kernel update.

> ⚠️ **AI Transparency Disclosure**  
> This entire repository — including the `disable-lapmode.sh` script, this README, and all related documentation — was created with the assistance of generative AI (large language models). 
> **Please review the script thoroughly before executing it**, understand the modifications it performs (kernel module patching, source downloads, DKMS registration), and accept all associated risks.
> The author assume no liability for any damage, data loss, or unexpected behaviour resulting from the use of this software.

## Table of Contents
- [What This Does](#what-this-does)
- [Background](#background)
- [Compatibility](#compatibility)
- [Quick Start](#quick-start)
- [Uninstall / Revert](#uninstall--revert)
- [How It Works](#how-it-works)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## What This Does
On many modern ThinkPads, a hardware "lap detection" sensor (`dytc_lapmode`) limits CPU performance when the laptop is on a soft surface (your lap). This is meant to prevent overheating, but it often triggers falsely on stable surfaces like desks or laptop stands, causing erratic throttling.

This script:
- Downloads the current kernel's `thinkpad_acpi.c` source
- Patches one line to make the lap sensor **always report `false`** (i.e., "not on lap")
- Builds and installs the modified module via **DKMS**, so it survives kernel upgrades

After a reboot, `/sys/devices/platform/thinkpad_acpi/dytc_lapmode` will always read `0`, and performance is no longer affected by the sensor.

---

## Compatibility
- **Laptops** – ThinkPads that expose `/sys/devices/platform/thinkpad_acpi/dytc_lapmode` (most recent T, X, P, X1 series)
- **Operating Systems** – Fedora 34+, Ubuntu 20.04+, Arch/Manjaro, and other systemd-based distributions
- **Kernels** – Tested on kernel 7.x (Fedora 44), but works on all kernels ≥ 4.x
- **Package managers** – `dnf`, `apt`, or `pacman` (others are warned but may work if dependencies are met manually)

---

## Quick Start

### 1. Download the script
```bash
curl -O https://raw.githubusercontent.com/felipe-juan/disable-lap-mode/main/disable-lapmode.sh
chmod +x disable-lapmode.sh
```

### 2. Run as root
```bash
sudo ./disable-lapmode.sh
```

The script will:
- Check that you're on a ThinkPad with the lap sensor
- Install build dependencies (`gcc`, `dkms`, `wget`, etc.)
- Download the kernel source, patch it, and register the module with DKMS
- Install the patched module

### 3. Reboot
```bash
sudo reboot
```

After reboot, verify:
```bash
cat /sys/devices/platform/thinkpad_acpi/dytc_lapmode   # Should output 0
sudo modinfo thinkpad_acpi | grep version              # Should show 420.26
```

---

## Uninstall / Revert
To completely remove the patched module and restore stock behaviour:

```bash
sudo ./disable-lapmode.sh --uninstall
```

Then reboot. DKMS will automatically load the original `thinkpad_acpi` module.

---

## How It Works

1. **DKMS (Dynamic Kernel Module Support)**  
   A system that automatically rebuilds out-of-tree kernel modules when the kernel is updated. We register a fake "package" called `thinkpad_acpi/1.0` that contains a build script.

2. **Source download & patch**  
   The `PRE_BUILD` script (`scripts/download.sh`) runs before each build:
   - Detects your kernel version
   - Downloads the matching `thinkpad_acpi.c` from [git.kernel.org](https://git.kernel.org)
   - Downloads `dual_accel_detect.h` if required (kernel ≥ 5.14)
   - Patches the lap detection logic:
     ```c
     // Original:
     *state = output & BIT(DYTC_GET_LAPMODE_BIT) ? true : false;
     // Patched:
     *state = output & BIT(DYTC_GET_LAPMODE_BIT) ? false : false;
     ```
   - Tags the module version as `420.26` for easy identification

3. **Build & install**  
   The `Makefile` builds the module, compresses it (`.xz`), and DKMS places it in the correct directory (`/kernel/drivers/platform/x86/` or the `lenovo/` subdirectory for kernels ≥ 5.17).

4. **Auto-rebuild on kernel updates**  
   With `AUTOINSTALL="yes"` in `dkms.conf`, any future kernel upgrade will automatically trigger a rebuild of the patched module.

---

## Troubleshooting

### "This system does not appear to have a ThinkPad lap mode sensor."
- The script checks for `/sys/devices/platform/thinkpad_acpi/dytc_lapmode`. If missing, your laptop either doesn't have the sensor or uses a different driver.  
- You can try loading `thinkpad_acpi` manually: `sudo modprobe thinkpad_acpi` and re-run.

### DKMS build fails
- **"wget: unable to resolve host address"** → No internet connection. The script downloads kernel source on the fly.
- **"kernel-devel not found"** → Install `kernel-devel` (or `linux-headers` on Arch) matching your kernel:  
  `sudo dnf install kernel-devel-$(uname -r)` / `sudo apt install linux-headers-$(uname -r)`
- **"Module not found in lenovo/ subdir"** → The script auto-detects the correct path for kernels ≥ 5.17. If it fails, you can manually set `DEST_MODULE_LOCATION` in `dkms.conf`.

### After reboot, still throttling?
- Ensure the module is actually loaded: `lsmod | grep thinkpad_acpi`
- Check `dmesg | grep thinkpad_acpi` for version `420.26`
- Some ThinkPads may require additional BIOS settings; this patch only disables the `dytc_lapmode` sensor.

### How to fully clean up
```bash
sudo ./disable-lapmode.sh --uninstall
sudo rm -rf /usr/src/thinkpad_acpi-1.0
sudo dkms status   # Should show no thinkpad_acpi entries
sudo reboot
```
