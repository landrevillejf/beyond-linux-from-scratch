# Way Beyond Linux From Scratch

Way Beyond Linux From Scratch is an automated LFS/BLFS distribution builder. It orchestrates host preparation, toolchain construction, LFS core build, BLFS layers, kernel generation, installer creation, and optional live ISO output through a single Python entry point (`builder.py`). Works on Linux, macOS, and Windows (WSL2).

**Version:** 0.52.30  
**Author:** Jean-Francois Landreville

This repository is designed for reproducible, profile‑driven builds and CI/CD publication workflows that separate:

- Cache generation pipelines
- Full ISO release pipelines
- ISO‑from‑cache reconstruction pipelines

---

## Table of Contents

- [Features](#features)
- [Documentation pages](#documentation-pages)
- [Project goals and philosophy](#project-goals-and-philosophy)
- [Architecture](#architecture)
- [Build pipeline flow](#build-pipeline-flow)
- [Repository structure](#repository-structure)
- [System requirements](#system-requirements)
- [Quick start](#quick-start)
- [Command line reference](#command-line-reference)
- [Build profiles](#build-profiles)
- [Configuration model](#configuration-model)
- [Artifacts and outputs](#artifacts-and-outputs)
- [USB writing](#usb-writing)
- [Custom sources](#custom-sources)
- [GitHub Actions workflow model](#github-actions-workflow-model)
- [Testing and quality gates](#testing-and-quality-gates)
- [Troubleshooting](#troubleshooting)
- [Security and support](#security-and-support)
- [Contributing](#contributing)
- [License](#license)

---

## Features

- **Profile‑based builds** – choose from 17 predefined profiles (minimal, full desktop, security‑hardened, ARM64, etc.).
- **Flexible init systems** – sysvinit, systemd, OpenRC, runit, s6.
- **Desktop environments** – XFCE, GNOME, KDE Plasma, LXQt, or no GUI.
- **Cross‑compilation** – build for ARM64 (aarch64) on an x86_64 host using QEMU and cross‑toolchains.
- **Cache support** – download a pre‑built root filesystem from a remote cache to skip compilation (useful for CI/CD).
- **Live ISO generation** – produce a hybrid BIOS/UEFI ISO with a squashfs live system.
- **USB writing** – write the ISO directly to a USB drive with partition unmounting.
- **Parallel downloads** – fetch source tarballs concurrently.
- **Resume capability** – restart from a failed stage without redoing previous work.
- **Comprehensive logging** – detailed logs per stage, with last 50 lines displayed on failure.
- **Professional branding** – custom themes, wallpapers, and GRUB backgrounds for the installer and live system (see [Branding](BRANDING.md)).

---

## Documentation pages

- [Overview](content.md)
- [Stage Timings](stage-timings.md)
- [Professional Branding System](BRANDING.md)
- [Installer Branding](INSTALLER_BRANDING.md)
- [Branding Visual Reference](branding-visual-mockup.html)
- [LPM Package Manager](lpm.md)
- [Troubleshooting](troubleshoot.md)
- [Docker How-To](docker-howto.md)
- [Release How-To](make-release-how-to.md)
- [Testing How-To](testing-howto.md)
- [Wallpaper Generator How-To](wallpaper-generator-howto.md)

---

## Project goals and philosophy

This project follows three core principles:

1. **LFS first**: builds are aligned with Linux From Scratch and Beyond Linux From Scratch stage sequencing.
2. **Single orchestrator**: `builder.py` is the source of truth for profile selection, parameter propagation, and stage execution.
3. **Reproducible automation**: CI workflows produce deterministic outputs (cache archives, kernels, ISO installers) with explicit verification steps.

---

## Architecture

### High-level component architecture

```mermaid
graph LR
    CLI["CLI (builder.py)"] --> CFG["LFSConfig (config/build.conf)"]
    CLI --> PM["ProfileManager"]
    CLI --> DL["SourceDownloader"]
    CLI --> EX["ScriptExecutor"]

    CFG --> ENV["Flattened environment (LFS_CONFIG_*, LFS_PROFILE_*)"]
    PM --> ENV
    ENV --> SH["Stage shell scripts"]

    SH --> HOST["host/*"]
    SH --> LFS["lfs/*"]
    SH --> BLFS["blfs/*"]
    SH --> FINAL["final/*"]

    FINAL --> OUT["Output directory"]
    OUT --> ISO["lfs-installer.iso"]
    OUT --> IMG["image/boot/vmlinuz*"]
    OUT --> LOGS["logs/*.log"]
    OUT --> META["build_info.json"]
```

### Runtime responsibility split

| Layer | Responsibility |
|---|---|
| `builder.py` | CLI parsing, profile application, environment propagation, stage orchestration |
| `host/*.sh` | Host checks, host preparation, disk image and toolchain setup |
| `lfs/*.sh` | Core LFS base and system construction |
| `blfs/*.sh` | Desktop, applications, package management, hardening, updater layers |
| `final/*.sh` | Initramfs, bootloader, installer, live ISO generation |
| `.github/workflows/*.yml` | CI/CD automation: cache pipelines, nightly builds, release publication |

---

## Build pipeline flow

```mermaid
flowchart TD
    A["Start builder.py"] --> B["Parse CLI arguments"]
    B --> C["Load config + profile"]
    C --> D["Apply overrides (--init, --no-live, --kernel-type, --bootloader, --host-distro)"]
    D --> E["Refresh script execution environment"]
    E --> F["Check prerequisites"]
    F --> G["Prepare output layout"]
    G --> H["Update and download sources"]
    H --> I["Execute ordered stage scripts"]
    I --> J{"Build success?"}
    J -- No --> K["Stop and inspect logs"]
    J -- Yes --> L["Generate artifacts (kernel, installer, ISO or cache rootfs)"]
    L --> M["Optional USB write"]
```

### Default stage order (xfce profile, live enabled)

1. `host-check`
2. `host-prepare`
3. `disk-image`
4. `toolchain`
5. `lfs-basic`
6. `lfs-system`
7. `init-system`
8. `service-abstraction`
9. `configure-lfs`
10. `blfs-base`
11. `build-kernel`
12. `desktop`
13. `applications`
14. `configure-desktop`
15. `package-manager`
16. `base-packages`
17. `security`
18. `branding`
19. `first-boot`
20. `system-updater`
21. `package-updater`
22. `lpm-advanced`
23. `initramfs`
24. `bootloader`
25. `installer`
26. `live-system` (when enabled)

---

## Repository structure

```text
.
|-- builder.py
|-- config/
|   |-- build.conf
|   |-- build-cross.conf
|   `-- ...
|-- host/
|-- lfs/
|-- blfs/
|-- final/
|-- packages/
|-- profiles/
|-- tests/
|   |-- features/
|   `-- ...
`-- .github/workflows/
```

---

## System requirements

### Native Linux build host

| Resource | Minimum | Recommended |
|---|---:|---:|
| CPU cores | 4 | 8+ |
| RAM | 8 GB | 16+ GB |
| Disk | 50 GB free | 100+ GB free |
| Architecture | x86_64 | x86_64 |

### Supported host distributions

- Debian/Ubuntu
- Fedora/RHEL-like
- Arch

Use `--host-distro` if auto detection must be overridden:

```bash
python3 builder.py --host-distro fedora
```

### macOS and Windows

- macOS is supported through `mac-lfs-builder.sh` (Docker-based workflow).
- Windows is supported through WSL2 and Linux tooling.

---

## Quick start

```bash
git clone https://github.com/landrevillejf/beyond-linux-from-scratch.git
cd beyond-linux-from-scratch

# Install Python test/build dependencies
python3 -m pip install -r tests/requirements.txt

# List available profiles
python3 builder.py --list-profiles

# Build default profile (xfce)
python3 builder.py
```

Common variants:

```bash
# Minimal CLI system
python3 builder.py --profile minimal

# SysV init build
python3 builder.py --profile xfce --init sysvinit

# Server rootfs (no live ISO)
python3 builder.py --profile server --no-live

# ARM64 cross profile
python3 builder.py --profile arm64 --config config/build-cross.conf

# Use cache to skip compilation
python3 builder.py --profile xfce --use-cache

# Resume a failed build from the "desktop" stage
python3 builder.py --resume-from desktop

# Write the ISO to a USB drive
python3 builder.py --write-usb /dev/sdb

# Generate sources.list and exit
python3 builder.py --generate-sources-list
```

---

## Command line reference

| Option | Description |
|--------|-------------|
| `--profile` | Build profile (`xfce` by default) |
| `--output` | Output directory (`./lfs-build` by default) |
| `--config` | Configuration file path (`config/build.conf`) |
| `--download-timeout` | Timeout in seconds for each download (default: from config or 300) |
| `--download-retries` | Number of retries for failed downloads (default: from config or 3) |
| `--resume-from` | Resume from a specific stage |
| `--write-usb <device>` | Write generated ISO to a USB device |
| `--list-profiles` | Print available profiles |
| `--profile-info <profile>` | Print profile details |
| `--clean` | Interactive cleanup of output directory |
| `--verbose`, `-v` | Enable debug logs |
| `--init` | Init override (`systemd`, `sysvinit`, `openrc`, `runit`, `s6`) |
| `--no-live` | Disable live-system stage |
| `--version` | Print builder version |
| `--use-cache` | Use cache metadata to restore prebuilt image |
| `--cache-only` | Require cache hit; fail otherwise |
| `--cache-url` | Override cache metadata URL |
| `--kernel-type` | Kernel type (`linux`, `linux-libre`, `gnu-hurd`, `freebsd`) |
| `--kernel-version` | Version du noyau (ex: `6.16.1`, `6.12.20`) |
| `--host-distro` | Host distro override (`debian`, `fedora`, `arch`, `auto`) |
| `--bootloader` | Bootloader override (`grub`, `uboot`, `aboot`) |
| `--generate-sources-list` | Generate `packages/sources.list` and exit |

---

## Build profiles

Profiles are defined in `ProfileManager` and drive stage inclusion and defaults.

| Profile | Description | Desktop | Default init | Arch | Live | Size (GB) | Build time (h) |
|---|---|---|---|---|---:|---:|---:|
| `minimal` | Minimal command-line only system | none | sysvinit | x86_64 | No | 1 | 2 |
| `gnu-free` | 100% free software system | none | sysvinit | x86_64 | No | 3 | 4 |
| `gnu-free-full` | Full GNU stack | xfce | sysvinit | x86_64 | Yes | 10 | 8 |
| `xfce` | XFCE desktop environment | xfce | systemd | x86_64 | Yes | 4 | 4 |
| `gnome` | GNOME desktop environment | gnome | systemd | x86_64 | Yes | 8 | 8 |
| `kde` | KDE Plasma desktop environment | kde | systemd | x86_64 | Yes | 10 | 12 |
| `lxqt` | Lightweight LXQt desktop | lxqt | systemd | x86_64 | Yes | 2 | 3 |
| `java-dev` | Java development stack on XFCE | xfce | systemd | x86_64 | Yes | 10 | 6 |
| `server` | Server-oriented profile | none | sysvinit | x86_64 | No | 2 | 3 |
| `secure` | Hardened profile with privacy tools | xfce | sysvinit | x86_64 | Yes | 6 | 5 |
| `full` | Full feature profile | gnome | systemd | x86_64 | Yes | 20 | 12 |
| `audio-cli` | Headless audio production | none | sysvinit | x86_64 | No | 2 | 3 |
| `audio-studio` | Desktop audio production | xfce | systemd | x86_64 | Yes | 8 | 6 |
| `arm64` | ARM64 server profile | none | sysvinit | aarch64 | No | 2 | 3 |
| `pinebook` | Pinebook profile | xfce | sysvinit | aarch64 | No | 4 | 4 |
| `brax3` | Brax3 smartphone profile | phosh | systemd | aarch64 | No | 4 | 5 |
| `custom` | User-defined profile template | none | sysvinit | x86_64 | No | 5 | 5 |

---

## Configuration model

Primary configuration file: `config/build.conf` (JSON).

Key sections:

- `init_system`: selected init, service style, restart policy
- `kernel`: kernel version/type/config and module list
- `live_system`: live ISO behavior (compression, persistence, default boot)
- `package_manager`: LPM behavior
- `system_updater`: update policy
- `security`: hardening, firewall, auditing, privacy flags
- `bootloader`: grub/uboot metadata
- `repositories`: source list endpoints

At runtime, builder exports all configuration and profile values to shell stages:

- Fixed env vars: `LFS`, `PROFILE`, `INIT_SYSTEM`, `KERNEL_TYPE`, etc.
- Flattened vars: `LFS_CONFIG_*` and `LFS_PROFILE_*`

These values are preserved inside built systems in:

```text
/etc/lfs-builder-params.env
```

### Branding configuration

Branding is fully configurable from `config/build.conf`:

```json
"branding": {
  "preset": "default",
  "dir": "",
  "theme_variant": "dark",
  "gtk_theme": "",
  "icon_theme": "",
  "wallpaper": "lfs-wallpaper.png",
  "apply_desktops": "auto",
  "strict": false
}
```

Behavior:

1. `preset` selects `branding/<preset>/`.
2. `dir` can override with an absolute or repository-relative path.
3. `theme_variant`, `gtk_theme`, and `icon_theme` control theme identity.
4. `apply_desktops` accepts `auto`, `all`, or a comma list (`xfce,gnome,kde,lxqt,phosh`).
5. `strict` turns missing assets into hard errors.

Branding stage outputs:

- `/etc/lfs-builder-params.env`
- `/etc/lfs-branding-manifest.txt` (installed assets + checksums)

---

## Artifacts and outputs

Default output tree (`--output`):

```text
<output>/
|-- build_info.json
|-- logs/
|-- sources/
|-- image/
|   `-- boot/vmlinuz*
`-- lfs-installer.iso   (if live enabled)
```

Typical outputs:

- Live builds: ISO + kernel + logs + metadata
- Non-live builds (`--no-live`): root filesystem image tree + kernel + logs
- Cache workflows: compressed rootfs cache archive (`.tar.zst`)

---

## USB writing

The `--write-usb` option writes the generated ISO to a USB drive.

- On Linux, it automatically unmounts any mounted partitions on the device (by reading `/proc/mounts`) before running `dd`.
- On macOS, it uses `rdisk` for faster raw writing.
- The script asks for confirmation (`Type 'YES' to continue`) before overwriting.
- After writing, it ejects the device (on Linux) and syncs.

---

## Custom sources

You can add custom source URLs (e.g., for private mirrors or additional packages) by creating a file `packages/custom-sources.list`. Each line should contain a URL to a tarball. The builder will append these to the main `sources.list` during the download stage.

---

## GitHub Actions workflow model

### Workflow architecture

```mermaid
graph TD
    A["Cache workflows"] --> A1["xfce-sysvinit-x86_64-build-cache.yml"]
    A --> A2["xfce-systemd-x86_64-build-cache.yml"]

    B["ISO release workflows"] --> B1["xfce-live-boot-iso.yml"]
    B --> B2["release.yml"]
    B --> B3["nightly.yml"]

    C["ISO from cache workflow"] --> C1["build-iso-from-cache.yml"]

    D["CI and governance workflows"] --> D1["python-app.yml"]
    D --> D2["codeql.yml"]
    D --> D3["codacy-security-scan.yml"]
    D --> D4["docs.yml"]
    D --> D5["benchmark.yml"]
    D --> D6["pr-labeler.yml"]
    D --> D7["squash-pr.yml"]
    D --> D8["cross-compile.yml"]
    D --> D9["build.yml"]
```

### Build and release workflow behavior

| Workflow | Purpose | Produces release | Produces ISO | Produces kernel artifact | Cache-only |
|---|---|---:|---:|---:|---:|
| `xfce-sysvinit-x86_64-build-cache.yml` | Build reusable cache rootfs | No | No | Verified in cache | Yes |
| `xfce-systemd-x86_64-build-cache.yml` | Build reusable cache rootfs | No | No | Verified in cache | Yes |
| `build-iso-from-cache.yml` | Reconstruct ISO from cache archive | Optional | Yes | Yes | No |
| `xfce-live-boot-iso.yml` | Full live ISO release pipeline | Yes | Yes | Yes | No |
| `release.yml` | Tagged release build pipeline | Yes | Yes | Yes | No |
| `nightly.yml` | Scheduled profile matrix builds | Artifact upload | Yes | Yes | No |

All release-capable workflows explicitly verify:

1. ISO presence and non-empty file
2. Kernel artifact presence (`image/boot/vmlinuz*`)
3. SHA256 checksum generation for published assets

---

## Testing and quality gates

Test suite location:

```text
tests/
```

Includes:

- Unit tests
- Integration tests
- BDD feature tests (`tests/features/*.feature`)
- Coverage measurement

Current baseline in this repository:

- `builder.py` coverage target: 100%
- BDD scenarios are executable through pytest + `pytest-bdd`

Run locally:

```bash
python3 -m pip install -r tests/requirements.txt
python3 -m pytest tests/ --cov=builder --cov-report=term-missing
```

---

## Troubleshooting

### Build stops at prerequisites

- Confirm host dependencies are installed.
- Use `--host-distro` when distro detection is ambiguous.

### Live ISO missing

- Check whether `--no-live` was used.
- Verify final stages logs in `<output>/logs/`.

### Kernel missing in output

- Inspect `lfs/09-build-kernel.sh` stage log.
- Confirm `kernel.type` in config and source availability.

### Download errors

- Some source URLs may be outdated. Update `packages/sources.list` manually or via `python3 builder.py --generate-sources-list`.
- Add a `packages/custom-sources.list` with mirror URLs.

### Cache not found

- Ensure `--cache-url` points to a valid metadata JSON.
- With `--cache-only`, the build will fail if cache is unavailable.

### USB write permission denied

- Use `sudo` or run as root.

### Resume after failure

```bash
python3 builder.py --resume-from <stage-name> --profile <profile> --output <output-dir>
```

### Regenerate source list

```bash
python3 builder.py --generate-sources-list
```

---

## Security and support

- Security policy: [SECURITY.md](https://github.com/landrevillejf/beyond-linux-from-scratch/blob/main/SECURITY.md)
- Changelog: [CHANGELOG.md](https://github.com/landrevillejf/beyond-linux-from-scratch/blob/main/CHANGELOG.md)
- Advanced notes: [ADVANCED.md](https://github.com/landrevillejf/beyond-linux-from-scratch/blob/main/ADVANCED.md)

---

## Contributing

Please read [CONTRIBUTING.md](https://github.com/landrevillejf/beyond-linux-from-scratch/blob/main/CONTRIBUTING.md) before submitting pull requests.

---

## License

This project is licensed under GPLv3. See [LICENSE](https://github.com/landrevillejf/beyond-linux-from-scratch/blob/main/LICENSE).