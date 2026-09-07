# LFS/BLFS Builder – Documentation

**Version 0.55.1** – *Works on Linux, macOS, and Windows (WSL2)*  
**Author:** Jean-Francois Landreville

---

## Overview

The **LFS/BLFS Builder** is a Python‑based orchestrator that automates the creation of a custom Linux system from scratch, following the Linux From Scratch (LFS) and Beyond Linux From Scratch (BLFS) books. It downloads source tarballs, runs a series of shell scripts to compile the toolchain, the base system, desktop environments, and additional packages, and finally produces a bootable ISO image.

The builder supports multiple profiles, init systems (sysvinit, systemd, OpenRC, runit, s6), desktop environments (XFCE, GNOME, KDE, LXQt, Phosh), cross‑compilation for ARM64, a cache mechanism to speed up repeated builds, LUKS full‑disk encryption, the Calamares graphical installer, professional branding, and supply‑chain artifacts (GPG signing and SPDX SBOM).

---

## Features

- **Profile‑based builds** – choose from 17 profiles (minimal, full desktop, security‑hardened, audio production, ARM64, etc.).
- **Flexible init systems** – sysvinit, systemd, OpenRC, runit, s6.
- **Desktop environments** – XFCE, GNOME, KDE Plasma, LXQt, Phosh (mobile), or no GUI.
- **Book compliance** – stages follow LFS 13.0 / BLFS 13.0: packages are built with the exact commands from the books, with the books' error policy enforced.
- **Cross‑compilation** – build for ARM64 (aarch64) on an x86_64 host using QEMU and cross‑toolchains; target arch can be overridden with `--arch`.
- **Cache support** – download a pre‑built root filesystem from a remote cache to skip compilation (`--use-cache`, `--cache-only`; useful for CI/CD).
- **Live ISO generation** – produce a hybrid BIOS/UEFI ISO with a squashfs live system and persistence support.
- **LUKS encryption** – full‑disk encryption support via the `luks-encryption` stage.
- **Calamares installer** – graphical system installer integration.
- **Complete software stacks** – basic networking, multimedia (PipeWire/PulseAudio, GStreamer, ffmpeg, mpv, VLC), server packages (Apache, MariaDB, PostgreSQL, Samba, OpenSSH, ...), printing and scanning (CUPS, SANE, Gutenprint).
- **Audio production** – Ardour DAW, LV2 plugin packs (LSP, Dragonfly), NeuralRack and a PREEMPT_RT realtime kernel for the `audio-studio` profile.
- **Security and privacy** – kernel hardening, nftables firewall, fail2ban, auditing (AIDE), and privacy tools.
- **Java development stack** – JDK, Maven, Gradle, Tomcat and container tooling via the `java-dev` stage.
- **USB writing** – write the ISO directly to a USB drive with partition unmounting.
- **Parallel downloads** – fetch source tarballs concurrently, with configurable timeouts and retries.
- **Resume capability** – restart from a failed stage without redoing previous work (`--resume-from`); stop early with `--stop-after`.
- **Build validation** – final `validate` stage checks the produced image before publication.
- **Supply-chain artifacts** – GPG-sign the ISO (`--sign-iso`) and generate an SPDX SBOM (`--sbom`).
- **Milestone / nightly naming** – tag ISO filenames with a milestone label (`--milestone alpha1`) or today's date (`--nightly`).
- **Professional branding** – custom themes, wallpapers, and GRUB backgrounds for the installer and live system.
- **Comprehensive logging** – detailed logs per stage, with last 150 lines displayed on failure.

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
| `--download-timeout` | Timeout in seconds for each download (default: from config or 300). |
| `--download-retries` | Number of retries for failed downloads (default: from config or 3). |
| `--stage-timeout` | Timeout in seconds for each build stage (default: 7200; raise for qemu-emulated cross builds). |
| `--resume-from` | Resume from a specific stage. Sources are still validated and downloaded first, and an unknown stage name is a hard error rather than a silent restart. |
| `--stop-after` | Stop once this stage has completed (used to publish the base prefix cache). |
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
| `--kernel-version` | Kernel version override (e.g. `6.16.1`, `6.12.20`). |
| `--host-distro` | Host distro override (`debian`, `fedora`, `arch`, `auto`). |
| `--bootloader` | Bootloader override (`grub`, `uboot`, `aboot`). |
| `--arch` | Target architecture (`x86_64`, `aarch64`). |
| `--generate-sources-list` | Generate `packages/sources.list` and exit. |
| `--sign-iso [GPG_KEY]` | Sign the generated ISO with GPG (optional key ID or email). |
| `--sbom` | Generate an SPDX software bill of materials after the build. |
| `--milestone` | Milestone tag for ISO naming (e.g. `alpha1`, `beta1`, `rc1`). |
| `--nightly` | Nightly build mode: append today's date to the ISO filename. |
| `--skip-man-pages` | Export `SKIP_MAN_PAGES=true` so stage scripts skip man page generation. |

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
| `audio-studio` | Pro audio studio: XFCE, Ardour DAW, LV2/NeuralRack, LSP/Dragonfly plugins, PREEMPT_RT |
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

The build process is divided into ordered stages. Profiles include or skip stages as needed (GUI stages are skipped for headless profiles, and `qemu-setup`/`uboot` only run for cross-compiled architectures). The master ordered list (`BUILD_STAGES` in `builder.py`) is:

1. **host-check** – verify host system prerequisites.
2. **host-prepare** – prepare the host environment (create user, directories).
3. **qemu-setup** – set up QEMU user emulation for cross-compilation.
4. **disk-image** – create a disk image file.
5. **toolchain** – build the cross-toolchain (binutils, gcc).
6. **uboot** – build U-Boot for ARM boards.
7. **lfs-basic** – build the basic LFS system (bash, coreutils, etc.).
8. **lfs-system** – build the full LFS system (glibc, binutils, gcc).
9. **init-system** – install the chosen init system.
10. **service-abstraction** – set up service management.
11. **configure-lfs** – configure the LFS system.
12. **blfs-base** – build BLFS base packages (curl, openssl, etc.).
13. **blfs-libs** – build core BLFS libraries (glib, mesa, GTK, ...).
14. **xorg** – build the X Window System stack.
15. **wayland** – build the Wayland stack.
16. **display-manager** – build the display manager (LightDM, etc.).
17. **build-kernel** – compile the Linux kernel.
18. **desktop** – build the desktop environment (if enabled).
19. **applications** – install desktop applications.
20. **configure-desktop** – configure the desktop.
21. **java-dev** – install the Java development stack (if enabled).
22. **basic-networking** – configure networking (profiles declaring `network`).
23. **multimedia** – install the multimedia stack (audio/multimedia profiles).
24. **server** – install server packages (profiles declaring `ssh`/`server-tools`).
25. **printing-scanning** – install CUPS/SANE (profiles declaring `printing` or `all`).
26. **audio-studio** – install pro audio tooling (audio profiles only).
27. **package-manager** – install the LPM package manager.
28. **base-packages** – install base packages via LPM.
29. **security** – apply security hardening.
30. **privacy** – install privacy tools.
31. **branding** – apply custom branding (themes, wallpapers).
32. **calamares** – install the Calamares graphical installer.
33. **first-boot** – set up first-boot services.
34. **system-updater** – install the system updater.
35. **luks-encryption** – set up LUKS full-disk encryption support.
36. **initramfs** – create the initramfs.
37. **bootloader** – install the bootloader (GRUB).
38. **installer** – create the bootable ISO.
39. **live-system** – generate the live squashfs and final ISO (when enabled).
40. **validate** – validate the produced build before publication.

If a stage fails, you can resume from that stage using `--resume-from`, or stop early with `--stop-after`.

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

- **Build fails at a stage** – check the log file at `./lfs-build/logs/<stage>.log`. The builder prints the last 150 lines on failure.
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