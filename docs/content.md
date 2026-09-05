# LFS/BLFS Builder – Documentation

**Version 0.4.3** – *Works on Linux, macOS, and Windows (WSL2)*  
**Author:** Jean-Francois Landreville

---

## Overview

The **LFS/BLFS Builder** is a Python‑based orchestrator that automates the creation of a custom Linux system from scratch, following the Linux From Scratch (LFS) and Beyond Linux From Scratch (BLFS) books. It downloads source tarballs, runs a series of shell scripts to compile the toolchain, the base system, desktop environments, and additional packages, and finally produces a bootable ISO image.

The builder supports multiple profiles, init systems (sysvinit, systemd, OpenRC, etc.), desktop environments (XFCE, GNOME, KDE, LXQt), cross‑compilation for ARM64, and a cache mechanism to speed up repeated builds.

---

## Features

- **Profile‑based builds** – choose from 15 predefined profiles (minimal, full desktop, security‑hardened, etc.).
- **Flexible init systems** – sysvinit, systemd, OpenRC, runit, s6.
- **Desktop environments** – XFCE, GNOME, KDE Plasma, LXQt, or no GUI.
- **Cross‑compilation** – build for ARM64 (aarch64) on an x86_64 host using QEMU and cross‑toolchains.
- **Cache support** – download a pre‑built root filesystem from a remote cache to skip compilation (useful for CI/CD).
- **Live ISO generation** – produce a hybrid BIOS/UEFI ISO with a squashfs live system.
- **USB writing** – write the ISO directly to a USB drive with partition unmounting.
- **Parallel downloads** – fetch source tarballs concurrently.
- **Resume capability** – restart from a failed stage without redoing previous work.
- **Comprehensive logging** – detailed logs per stage, with last 50 lines displayed on failure.

---

## System Requirements

- **OS:** Linux (native), macOS (with Docker), Windows 10/11 (WSL2)
- **Python:** 3.10 or higher (3.13 recommended)
- **Disk space:** at least 50 GB for a full desktop build (more if using cache)
- **Host tools (Linux):** `bash`, `gcc`, `make`, `bison`, `gawk`, `m4`, `wget`, `tar`, `gzip`, `xorriso`, `parted`
- **For macOS:** Docker Desktop is required (the builder runs inside a container)
- **For cross‑compilation (ARM64):** `gcc-aarch64-linux-gnu`, `binutils-aarch64-linux-gnu`, `qemu-user-static`

---

## Installation

```bash
git clone https://github.com/landrevillejf/beyond-linux-from-scratch.git
cd beyond-linux-from-scratch
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt   # if exists, otherwise only pytest etc. are used
```

No separate installation is needed – the builder is a single Python script `builder.py`. All dependencies are pulled via `pip install` as needed.

---

## Usage

Basic command:

```bash
python3 builder.py [OPTIONS]
```

### Common examples

```bash
# Build default XFCE + sysvinit with live ISO
python3 builder.py

# Build a minimal CLI system (no GUI)
python3 builder.py --profile minimal

# Build for ARM64 (Raspberry Pi)
python3 builder.py --profile arm64 --config config/build-cross.conf

# Build KDE Plasma with systemd
python3 builder.py --profile kde --init systemd

# Use a pre‑built cache and skip compilation
python3 builder.py --profile xfce --use-cache

# Resume a failed build from the "desktop" stage
python3 builder.py --resume-from desktop

# List all available profiles
python3 builder.py --list-profiles

# Show detailed info about a profile
python3 builder.py --profile-info full

# Clean the build directory
python3 builder.py --clean --output ./lfs-build

# Write the ISO to a USB drive
python3 builder.py --write-usb /dev/sdb
```

---

## Command‑line Options

| Option | Description |
|--------|-------------|
| `--profile` | Build profile (default: `xfce`). Choices: `minimal`, `gnu-free`, `gnu-free-full`, `xfce`, `gnome`, `java-dev`, `secure`, `full`, `arm64`, `audio-cli`, `pinebook`, `audio-studio`, `kde`, `lxqt`, `server`, `brax3`, `custom`. |
| `--output` | Output directory (default: `./lfs-build`). |
| `--config` | Configuration file path (default: `config/build.conf`). |
| `--resume-from` | Resume from a specific stage. Sources are still validated and downloaded first, and an unknown stage name is a hard error rather than a silent restart. |
| `--stop-after` | Stop after a specific stage completes (used for cache builds). |
| `--write-usb` | Write the generated ISO to a USB device (e.g., `/dev/sdb`). |
| `--list-profiles` | List all available profiles. |
| `--profile-info` | Show detailed information about a specific profile. |
| `--clean` | Delete the build directory (interactive confirmation). |
| `--verbose` / `-v` | Enable DEBUG logging. |
| `--init` | Override the init system (`systemd`, `sysvinit`, `openrc`, `runit`, `s6`). |
| `--no-live` | Disable live system creation (only produce the root filesystem). |
| `--version` | Show version information. |
| `--use-cache` | Use a pre‑built cache (skip compilation) if available. |
| `--cache-only` | Only use the cache; fail if not found. |
| `--cache-url` | Custom URL for cache metadata (default: a predefined JSON). |
| `--kernel-type` | Kernel type: `linux`, `linux-libre`, `gnu-hurd`, `freebsd`. |

---

## Build Profiles

The builder comes with a set of predefined profiles that configure the target system. Each profile defines:

- Description
- Approximate size on disk (GB)
- Estimated build time (hours)
- List of packages (or categories)
- Desktop environment (or `None`)
- Init system
- Whether to include Java development tools
- Package manager (LPM)
- Security hardening
- Privacy tools
- Live system support
- System updater
- Cross‑compilation settings (for ARM profiles)

### Available Profiles

| Profile | Description |
|---------|-------------|
| `minimal` | CLI‑only, no GUI, small footprint |
| `gnu-free` | 100% FSF‑compliant free software system |
| `gnu-free-full` | Full GNU system with all GNU packages |
| `xfce` | XFCE desktop environment (default) |
| `gnome` | GNOME desktop environment |
| `java-dev` | Java development environment with XFCE |
| `secure` | Security‑hardened system with privacy tools |
| `full` | Complete system with everything |
| `arm64` | ARM64 server (Raspberry Pi, Orange Pi) |
| `audio-cli` | CLI‑only audio production system |
| `pinebook` | Pinebook / Pinebook Pro ARM64 laptop |
| `audio-studio` | Full audio production studio with XFCE |
| `kde` | KDE Plasma full‑featured desktop |
| `lxqt` | LXQt extremely lightweight Qt desktop |
| `server` | Production‑optimised server configuration |
| `brax3` | Brax3 Linux smartphone (Qualcomm Snapdragon) |
| `custom` | User‑defined custom profile template |

---

## Configuration File

The builder uses a JSON configuration file (default: `config/build.conf`). It contains all settings for the build:

- LFS/BLFS versions
- Build threads
- Cross‑compilation flags
- Init system options
- Package manager settings
- Live system parameters
- Desktop settings
- Security options
- Kernel version and modules
- Network, locale, timezone, users
- Repository URLs
- Build options (parallel, stripping, checksum verification)

You can override any setting by editing the file. The builder will create a default configuration if the file does not exist.

---

## Build Stages

The build process is divided into several stages, executed in order:

1. **host-check** – verify host system prerequisites.
2. **host-prepare** – prepare the host environment (create user, directories).
3. **disk-image** – create a disk image file.
4. **toolchain** – build the cross‑toolchain (binutils, gcc).
5. **qemu-setup** – set up QEMU user emulation for cross‑compilation.
6. **uboot** – build U‑Boot for ARM boards.
7. **lfs-basic** – build the basic LFS system (bash, coreutils, etc.).
8. **lfs-system** – build the full LFS system (glibc, binutils, gcc).
9. **init-system** – install the chosen init system.
10. **service-abstraction** – set up service management.
11. **configure-lfs** – configure the LFS system.
12. **blfs-base** – build BLFS base packages (curl, openssl, etc.).
13. **build-kernel** – compile the Linux kernel.
14. **desktop** – build the desktop environment (if enabled).
15. **applications** – install desktop applications.
16. **configure-desktop** – configure the desktop.
17. **package-manager** – install the LPM package manager.
18. **base-packages** – install base packages via LPM.
19. **security** – apply security hardening.
20. **privacy** – install privacy tools.
21. **branding** – apply custom branding (themes, wallpapers).
22. **first-boot** – set up first‑boot services.
23. **system-updater** – install the system updater.
24. **package-updater** – install the package updater.
25. **lpm-advanced** – advanced LPM features.
26. **initramfs** – create the initramfs.
27. **bootloader** – install the bootloader (GRUB).
28. **installer** – create the bootable ISO.
29. **live-system** – generate the live squashfs and final ISO.

If a stage fails, you can resume from that stage using `--resume-from`.

---

## Cache Mechanism

The builder can use a pre‑built root filesystem cache to avoid lengthy compilation steps. This is useful for CI/CD pipelines or for quickly testing final stages.

- Enable with `--use-cache`.
- The cache is downloaded from a URL specified in `--cache-url` (default points to a metadata JSON).
- The metadata contains entries for each profile, init system, and architecture.
- If the cache is found and successfully extracted, all build stages are skipped.
- With `--cache-only`, the builder will fail if the cache is not available.

---

## USB Writing

The `--write-usb` option writes the generated ISO to a USB drive.

- On Linux, it automatically unmounts any mounted partitions on the device (by reading `/proc/mounts`) before running `dd`.
- On macOS, it uses `rdisk` for faster raw writing.
- The script asks for confirmation (`Type 'YES' to continue`) before overwriting.
- After writing, it ejects the device (on Linux) and syncs.

---

## Cross‑Compilation (ARM64)

To build for ARM64 (e.g., Raspberry Pi), use the `arm64` or `pinebook` profile. The builder:

- Sets `cross_compile = True` in the configuration.
- Uses the cross‑toolchain (`gcc-aarch64-linux-gnu` etc.).
- Sets up QEMU user emulation for running ARM binaries on the host.
- Builds U‑Boot as the bootloader.
- Produces a raw disk image (`.img`) instead of an ISO.

Cross‑compilation requires that the cross‑toolchain be installed on the host (provided by the Docker image on macOS/Windows).

---

## Custom Sources

You can add custom source URLs (e.g., for private mirrors or additional packages) by creating a file `packages/custom-sources.list`. Each line should contain a URL to a tarball. The builder will append these to the main `sources.list` during the download stage.

---

## Troubleshooting

- **Build fails at a stage** – check the log file at `./lfs-build/logs/<stage>.log`. The builder prints the last 50 lines on failure.
- **Missing host tools** – install required packages (see System Requirements).
- **Disk space** – a full desktop build may require 20–30 GB. Use `--clean` to free space.
- **Download errors** – some source URLs may be outdated. Update `packages/sources.list` manually or via `_update_sources_list()`.
- **Cache not found** – ensure `--cache-url` points to a valid metadata JSON.
- **USB write permission denied** – use `sudo` or run as root.

---

## Contributing

Contributions are welcome! Please follow these guidelines:

- Fork the repository and create a feature branch.
- Write tests for new functionality (pytest).
- Ensure 100% code coverage.
- Update documentation accordingly.
- Submit a pull request.

---

## License

This project is licensed under the GNU General Public License v3.0 – see the [LICENSE file](https://github.com/landrevillejf/beyond-linux-from-scratch/blob/main/LICENSE) for details.

---

## Support

For issues, questions, or suggestions, please open an issue on GitHub.

---

*Happy building!*