# Changelog

All notable changes to the LFS/BLFS Builder project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **Source download path alignment (Critical)**
  - Fixed "Source for binutils not found" error in CI builds (Issues #35, #36, #37)
  - SourceDownloader now saves sources to `{output_dir}/image/sources` (not `{output_dir}/sources`)
  - Ensures sources directory matches LFS=$LFS/sources expectation
  - Updated GitHub Actions workflow to create correct directory structure
  - Fixed cache restore path to align with actual source location
  - CI builds can now progress past stage 4 (toolchain)

- **Shell script robustness and portability (Issue #35)**
  - Fixed 350+ shell scripting issues across 22 scripts for production-ready quality
  - **SC2086**: Added proper quoting for all variables (150+ occurrences)
    - Variables like `$LFS`, `$SOURCES_HOST`, `$LFS_HOME` now safely quoted
    - Prevents word splitting and path corruption with spaces
  - **SC2010/SC2012**: Replaced unreliable `ls | grep` patterns with robust `find` commands
    - Affected: `host/04-build-toolchain.sh`, `lfs/09-build-kernel.sh`, `final/*.sh`
    - Handles filenames with special characters correctly
  - **SC2162**: Added `-r` flag to `read` commands to preserve backslashes
  - **SC2046**: Quoted command substitutions to prevent word splitting
  - **SC2028**: Replaced `echo` with `printf` for binary data in `host/00-setup-qemu.sh`
  - **Sudo hardening**: Added `-n` (non-interactive) flag to prevent CI/CD password prompts
  
- **Shell script validation**
  - All 29+ scripts pass ShellCheck with zero critical issues
  - All scripts validated with `bash -n` syntax check
  - Enhanced CI/CD compatibility for Docker and automated environments

### Files Modified
- `builder.py`: Corrected SourceDownloader initialization path
- `.github/workflows/release.yml`: Updated directory creation and cache paths
- `host/00-setup-qemu.sh`, `host/04-build-toolchain.sh`
- `lfs/05-build-lfs-basic.sh`, `lfs/06-build-lfs-system.sh`, `lfs/06a-init-system.sh`
- `lfs/06b-service-management.sh`, `lfs/07-configure-lfs.sh`, `lfs/09-build-kernel.sh`
- `blfs/08-build-blfs-base.sh` through `blfs/17-first-boot-service.sh`
- `final/13-create-bootloader.sh`, `final/14-create-installer.sh`, `final/15-create-live-system.sh`

## [0.4.5] - 2026-07-17

### Added
- **LPM interface mode selection**
  - Added `--mode` to `lpm.py` with `cli` (default) and `text` modes.
  - Added interactive text menu flow for package operations.
  - Added dedicated tests in `tests/test_lpm_mode.py`.

- **PR labeler configuration**
  - Added `.github/labeler.yml` label rules for docs, CI, tests, builder, shell scripts, and LPM scopes.

### Changed
- **Coverage and CI reporting alignment**
  - Updated `python-app.yml` to keep a single coverage-producing pytest run before Codecov upload.
  - Updated README coverage badge URL to remove the stale `unittests` flag view.

- **MkDocs strict documentation navigation**
  - Replaced invalid `mkdocs.yml` nav references with existing docs pages.
  - Simplified `docs/troubleshoot.md` and removed broken internal links.
  - Fixed `docs/content.md` license link target for strict build compatibility.

- **Source download behavior hardening**
  - `SourceDownloader` now uses config-driven timeout/retry values at runtime.
  - Default download tuning changed from `300s/3 retries` to `30s/2 retries` in:
    - `config/default.json`
    - `config/build.conf`
    - `config/build.conf.json`

### Fixed
- **Release pipeline chroot bootstrap reliability**
  - Hardened `lfs/06-build-lfs-system.sh` tool bootstrap for chroot execution.
  - Avoids copying shell builtins as host binaries.
  - Ensures `/bin/sh` and `/usr/bin/env` exist in chroot, preventing `./configure` execution failures.

- **Download failure behavior on dead URLs**
  - Permanent HTTP errors (e.g. 404) now fail fast instead of consuming all retries.
  - Prevents long apparent “freeze” periods during source acquisition in release jobs.

- **Coverage completeness**
  - Added targeted tests for source list key fallback and downloader fast-fail behavior.
  - Restored `builder.py` coverage to 100% after recent pipeline hardening changes.

### Added
- **Builder parameter persistence for shell stages**
  - Added `/etc/lfs-builder-params.env` generation during branding stage.
  - Captures exported builder parameters (`LFS_*`, `LFS_CONFIG_*`, `LFS_PROFILE_*`) for traceability and post-build inspection.

- **Complete BDD test coverage for build scenarios**
  - Added `tests/features/test_build.py` to implement and execute `tests/features/build.feature`.
  - Added `pytest-bdd` to `tests/requirements-test.txt` so BDD suites run consistently in CI and local environments.

- **README full professional rewrite**
  - Replaced previous README with a complete English guide.
  - Added architecture, build flow, and workflow topology diagrams (Mermaid).
  - Added comprehensive CLI reference, profile matrix, outputs contract, and workflow behavior model.

### Changed
- **Builder runtime synchronization**
  - Introduced executor refresh flow so shell environment is rebuilt after runtime overrides (`--init`, `--no-live`, `--kernel-type`, `--bootloader`).
  - Added host distro override handling via config (`host.distro_override`) in host detection logic.
  - Updated live stage inclusion logic to reflect both profile defaults and runtime config state.

- **GitHub Actions workflow architecture**
  - Refactored cache workflows to be strictly cache-only (no release publishing).
  - Standardized release-capable workflows to verify and publish ISO + kernel + SHA256 checksums.
  - Updated nightly and cross-compile workflows to align with current builder behavior and output paths.
  - Removed failure-masking behavior in CI test workflows and fixed docs deployment permissions.

### Fixed
- **End-to-end test reliability**
  - Restored full test suite execution including BDD collection.
  - Added missing prerequisite test coverage for host distro override path.
  - Achieved `builder.py` line coverage at 100% with passing test suite.

#### Added
- **`--bootloader` option** in builder.py to allow users to specify the bootloader type (GRUB, Syslinux, U-Boot) for cross-compilation builds.
- **`--host-distro` option** in builder.py to allow users to specify the host distribution (Ubuntu, Fedora, Arch, openSUSE) for dependency installation.
- **`--kernel-type` option** in builder.py to allow users to specify the kernel type (linux, linux-libre, linux-rt) for the build.
- **Enhanced logging** in builder.py to include host distribution, kernel type, and bootloader information in the build summary.
- **New configuration file** `config/build-cross.conf` for cross-compilation builds, including bootloader and kernel type settings.

### Fixed
- **Cross-compilation detection** in builder.py to correctly identify the target architecture and set the appropriate environment variables.
- **Bootloader selection** in cross-compilation builds to ensure the correct bootloader is installed based on the `--bootloader` option.
- **Kernel type selection** in cross-compilation builds to ensure the correct kernel sources are downloaded and built based on the `--kernel-type` option.
- **Host distribution detection** in builder.py to correctly identify the host OS and install the necessary dependencies for building LFS/BLFS.
- **Tests** for the new options to ensure they work as expected.
- **Github workflows updated** to include cross-compilation tests for ARM64 and RISC-V architectures, ensuring that the new options work as expected across different host distributions.

## [0.4.4] – 2026-07-06

### Added
- **New wallpaper variants** with enhanced visual effects and color schemes.
- **Improved documentation** for the wallpaper generator, including usage examples and configuration options.

### Fixed
- **Minor bug fixes** in the wallpaper generator script to ensure compatibility with different Python versions and operating systems.
- **Font path** in the wallpaper generator – fallback to macOS system font (Helvetica) if DejaVu is unavailable.
- **Image quality** improvements in the wallpaper generator – enhanced rendering and compression settings.
- **Ls error in lfs and blfs scripts** – fixed incorrect path handling in certain environments. Realmit
- **Fix github workflows** 

## [0.4.3] – 2026-06-27

### Added
- **Wallpaper generator** (`generate_wallpapers.py`)
  - Generates multiple wallpaper variants using the LFS GTK theme colors.
  - Preserves the original, well‑liked design (`lfs-wallpaper.png`).
  - Offers different gradients, glowing circles, triangles, and decorative patterns.
  - Integrates the SVG logo directly into the image (via `cairosvg`).
- **Vector logo** (`logo.svg`)
  - Official LFS logo (green square with "LFS" text and subtitle) added to the project root.
  - Used in the README header and wallpapers.
- **README updates**
  - Added the logo as a header.
  - Critical clarification: **building under Docker/macOS does NOT produce a real ISO** – it creates a minimal skeleton for validation only.
  - Added instructions for obtaining a real ISO on a Linux host (or Lima/WSL2).
  - Added a section for the wallpaper generator.
- **New scripts**:
  - `generate_wallpapers.py` – multiple wallpaper generation.
  - `logo.svg` – vector logo for the project.

### Changed
- **Environment detection** in all shell and Python scripts.
  - Automatic detection of Docker, Lima, and WSL2.
  - In Docker mode, scripts create minimal skeletons (placeholders) and **do not** run actual compilations (to avoid `chroot`, `mount`, etc. errors).
- **Line endings**: all `.sh` scripts now use LF (Unix) instead of CRLF, resolving `Exec format error` issues.
- **Directory structure**:
  - Added optional `wallpaper/` folder for generated images.
  - `logo.svg` is placed at the project root.
- **Help messages**: `builder.py --help` now clearly states that Docker mode is for testing only.

### Fixed
- **`chroot: Operation not permitted`** under Docker – the build now continues by creating a minimal system without `chroot`.
- **Permission errors** when writing to `/usr/local/bin` – all scripts now use `$LFS` in Docker mode.
- **Font path** in the wallpaper generator – fallback to macOS system font (Helvetica) if DejaVu is unavailable.
- **Dead links** in `packages/sources.list` – updated via `analyze_urls.py` validation.

## [4.2.0] - 2026-05-14

### Added
- **Audio Production Support**
  - Complete audio production profiles:
    - `audio-cli` - Terminal-only audio production (headless, low-latency)
    - `audio-studio` - Full audio production studio with XFCE desktop
  - Real-time kernel (PREEMPT_RT) support for low-latency audio
  - JACK2, PipeWire, ALSA audio servers
  - Professional DAWs: Ardour 8.12.0, LMMS 1.2.2, Audacity 3.8.2
  - MIDI tools: FluidSynth 2.5.0, TiMidity++ 2.15.0, LinuxSampler 2.3.0
  - LV2/LADSPA plugins: Calf Studio Gear, LSP Plugins, Dragonfly Reverb
  - SoundFonts: FluidR3 GM/GS, Timidity Freepats
  - Jack GUI tools: QjackCtl 1.0.1, Patchage 1.0.12, Qpwgraph 1.8.0
  - Network audio: JackTrip, Sonobus, Zita-NJbridge
  - Real-time system tuning (rtirq-init, rt-tests, cyclictest)

- **Init System Flexibility**
  - Full support for **sysvinit** (LFS classic) alongside systemd
  - Boot script styles: LFS Classic (`/etc/rc.d/rc0.d...rc6.d`) and BSD-style (`/etc/rc.d/rcS.d`)
  - Unified `svc` command abstraction layer for both init systems
  - Service management aliases (`sv-start`, `sv-stop`, `sv-restart`, `sv-status`)
  - Automatic detection of active init system at runtime
  - Complete service management for sysvinit (start/stop/restart/status/enable/disable)
  - Systemd service files for all daemons
  - Default runlevel configuration (3 for CLI, 5 for GUI)

- **Network Stack Enhancement**
  - Web browsers: Firefox 128.8.0esr, Brave 1.76.82, Chromium 133.0.6943.98
  - Email clients: Thunderbird 140.8.0esr, Claws Mail 0.4.3, Mutt 2.2.15, NeoMutt 20241212
  - Terminal browsers: Lynx 2.9.2, Links 2.30, w3m 0.5.3
  - Download managers: Wget2 2.2.0, Aria2 1.37.0
  - Network libraries: libevent 2.1.12, nss 3.107, nspr 4.37, libvpx 1.15.0, dav1d 1.5.1
  - Network configuration system (`config/network.conf`)
  - DHCP and static IP configuration
  - DNS resolver selection (systemd-resolved, dnsmasq, resolvconf)
  - Wi-Fi support with WPA_Supplicant
  - Proxy settings for corporate networks
  - TCP BBR congestion control optimization

- **Enhanced Configuration System**
  - `config/audio-profile.conf` - Complete audio production configuration
    - Sample rate (44.1k/48k/96k/192k)
    - Buffer size (64/128/256/512/1024 frames)
    - Real-time priority (0-99)
    - CPU governor selection (performance/ondemand/conservative)
    - DAW and plugin selection
    - SoundFont library level (none/minimal/medium/full)
  - `config/network.conf` - Network configuration
    - Interface configuration (DHCP/static)
    - DNS servers and search domains
    - Wi-Fi SSID/PSK settings
    - Firewall rules
    - Proxy settings
  - `config/init.conf` - Init system configuration
    - sysvinit vs systemd choice
    - Boot script style (lfs-classic/bsd-style)
    - Default runlevel/target
    - Service management style
  - `packages.conf.json` - Updated to LFS 13.0 versions
    - Linux 6.12.20, GCC 15.2.0, Glibc 2.43
    - Python 3.14.3, Bash 5.3, Binutils 2.46.0
    - Systemd 259.1, Sysvinit 3.14

- **New Scripts**
  - `lfs/06a-init-system.sh` - Init system installer (sysvinit/systemd/openrc/runit/s6)
  - `lfs/06b-service-management.sh` - Unified service abstraction (`svc` command)
  - `lfs/06c-boot-scripts.sh` - SysVinit boot scripts (both styles)
  - `lfs/06d-systemd-config.sh` - Systemd configuration
  - `lfs/06e-init-selector.sh` - Interactive init system selection wizard
  - `profiles/select-audio-profile.sh` - Audio profile selector (CLI/Desktop/Studio)
  - `profiles/audio/build.sh` - Unified audio profile builder
  - `profiles/audio/cli-minimal/packages.list` - CLI audio packages
  - `profiles/audio/desktop-xfce/packages.list` - XFCE audio workstation
  - `profiles/audio/desktop-gnome/packages.list` - GNOME audio workstation
  - `profiles/audio/studio-full/packages.list` - Complete professional studio

- **Configuration Files**
  - `config/audio-profile.conf` - Audio-specific settings
  - `config/network.conf` - Network configuration
  - `config/init.conf` - Init system selection
  - `config/build-cross.conf` - Cross-compilation for ARM64
  - `config/build-java.conf` - Java development environment
  - `config/desktop.conf` - Desktop environment settings
  - `config/security.conf` - Security hardening
  - `config/lpm.conf` - Package manager configuration

- **Command Line Options**
  - `--init` - Override init system (sysvinit/systemd/openrc/runit/s6)
  - `--profile` now includes `audio-cli`, `audio-studio`, `arm64`
  - Profile info now shows init system and audio features

### Changed
- **builder.py** upgraded to v4.2.0
  - Added audio profile support with real-time kernel configuration
  - Init system selection with `sysvinit` as default (LFS classic)
  - Network configuration integration
  - Extended environment variables: `INIT_SYSTEM`, `SYSVINIT_STYLE`, `AUDIO_PROFILE`
  - Better cross-compilation detection for ARM64
  - Added QEMU user emulation for foreign architectures

- **Profile Manager** Enhanced
  - Added `audio-cli` and `audio-studio` profiles
  - All profiles now include `init_system` property
  - Profile info displays init system choice
  - Audio profiles include real-time kernel configuration

- **Updated Versions** (LFS 13.0 / BLFS 13.0)
  - Linux Kernel: 6.6.14 → **6.12.20**
  - GCC: 13.2.0 → **15.2.0**
  - Glibc: 2.38 → **2.43**
  - Binutils: 2.41 → **2.46.0**
  - Python: 3.12.1 → **3.14.3**
  - Bash: 5.2.21 → **5.3**
  - Systemd: 255 → **259.1**
  - Sysvinit: 3.08 → **3.14**
  - GRUB: 2.12 → **2.14**
  - OpenSSL: 3.1.4 → **3.6.1**
  - Firefox: 128.4.0esr → **128.8.0esr**
  - Thunderbird: 128.4.0esr → **140.8.0esr**
  - LibreOffice: 24.8.4 → **25.8.1**
  - JDK: 21.0.8 → **21.0.10**
  - Maven: 3.9.9 → **3.9.9** (current)
  - Gradle: 8.13 → **8.15**
  - Docker: 27.4.1 → **28.3.3**

- **Package Sources** (`packages/sources.list`)
  - Added sysvinit 3.14
  - Added LFS bootscripts 20240825
  - Added ALSA, JACK2, PipeWire packages
  - Added audio DAWs: Ardour, LMMS, Audacity
  - Added MIDI tools: FluidSynth, TiMidity++, WildMIDI
  - Added audio plugins: Calf, LSP, Dragonfly Reverb
  - Added browsers: Firefox, Brave, Chromium
  - Added email clients: Thunderbird, Claws Mail, Mutt
  - Added network libraries: nss, nspr, libevent, libvpx, dav1d

### Fixed
- Init system detection across all scripts
- Cross-compilation QEMU user emulation registration
- Sysroot directory creation for ARM64 builds
- U-Boot build for Raspberry Pi boards
- Audio real-time priority limits in `/etc/security/limits.conf`
- JACK2 D-Bus integration
- PipeWire ALSA compatibility
- Firefox build with Python 3.14 and glibc 2.43 (patches added)
- Thunderbird build dependencies

### Security
- Real-time audio processes have rtprio 95 and memlock unlimited
- Daily security scans include audio system components
- Firewall rules for network audio (ports 9988, 9999, 4444, 4445)
- SSH hardening for remote audio collaboration

## [4.1.0] - 2026-04-30

### Added
- **Cross-Compilation Support**
  - Full cross-compilation for ARM64 (aarch64), ARM (armv7l), RISC-V (riscv64)
  - Automatic QEMU user emulation setup (`00-setup-qemu.sh`)
  - Sysroot management for target filesystems
  - Cross-toolchain detection and configuration
  - Environment variables: `CROSS_COMPILE`, `CROSS_PREFIX`, `QEMU_USER`, `SYSROOT`, `ARCH`

- **U-Boot Bootloader Support**
  - U-Boot build stage (`05-build-uboot.sh`)
  - Support for multiple ARM boards (Raspberry Pi, Orange Pi, Banana Pi)
  - Board configuration via `uboot_board` parameter
  - Device tree blob (DTB) compilation
  - U-Boot environment configuration

- **New Build Profile: `arm64`**
  - Optimized for Raspberry Pi and ARM64 SBCs
  - U-Boot bootloader by default
  - Minimal server configuration (2GB image)
  - Cross-compilation enabled by default
  - Specific kernel configuration for ARM64

- **New Configuration Files**
  - `config/kernel-config-arm64` - ARM64 kernel configuration
  - `config/u-boot.config` - U-Boot build configuration
  - `config/build-cross.conf` - Cross-compilation example configuration

- **Builder Enhancements**
  - `--config` flag now supports cross-compilation configs
  - Automatic detection of cross-compilation from profile
  - Cross-compilation status in build info and summary
  - SD card image generation for ARM devices

### Changed
- **builder.py** upgraded to v4.1.0
  - Added `is_cross_compile()`, `get_target_architecture()`, `get_cross_prefix()`, `get_qemu_user()`, `get_sysroot()` methods
  - Extended `_get_env()` with cross-compilation variables
  - Modified `get_build_stages()` to conditionally add QEMU setup and U-Boot stages
  - Updated profile manager with architecture and bootloader properties
  - Enhanced build summary with cross-compilation information

- **Profile Manager**
  - Added `arm64` profile with cross-compilation defaults
  - Profiles now include `architecture`, `cross_compile`, `bootloader` properties
  - Profile info display includes architecture and bootloader type

- **Documentation**
  - Updated `ADVANCED.md` with cross-compilation guide
  - Added ARM64 build instructions
  - U-Boot configuration documentation

### Fixed
- Cross-compilation toolchain detection
- QEMU user emulation registration for foreign architectures
- Sysroot directory creation and permissions
- U-Boot build dependencies checking

### Security
- Cross-compiled binaries maintain security hardening
- QEMU user emulation runs in restricted mode

## [4.0.0] - 2026-04-30

### Added
- **Live System Support** (Integrated in `14-create-installer.sh`)
  - Complete "Try before install" live mode
  - SquashFS compressed root filesystem
  - RAM-based operation (no disk writes)
  - Persistence support for saving changes on USB
  - Live initramfs with overlay filesystem
  - Boot menu options: Live, Live with Persistence, Install, Rescue
  - `create-persistence.sh` tool for adding persistence to USB
  - Automatic hardware detection in live mode

- **System Update/Upgrade Manager** (`18-system-updater.sh`)
  - `lfs-update check` - Check for available system updates
  - `lfs-update upgrade` - Full system upgrade with backup
  - `lfs-update rollback` - Rollback to previous system state
  - `lfs-update status` - Show system version and package status
  - Automatic backup before any upgrade
  - Daily automatic update checks (cron/systemd timer)
  - Email notifications for available updates
  - Configurable backup retention (keeps last 5 backups)

- **Package Upgrade Commands** (`19-package-updater.sh`)
  - `lpm upgrade <package>` - Upgrade single package
  - `lpm upgrade` - Upgrade all outdated packages
  - `lpm list-outdated` - List packages with available updates
  - Version comparison against repositories
  - Repository database synchronization

- **New Configuration Options**
  - `system_updater` section in build.conf
    - `enabled`, `auto_check`, `backup_before_upgrade`, `keep_backups`, `rollback_support`
  - `live_system` section in build.conf
    - `enabled`, `squashfs_compression`, `persistence_support`, `default_boot`

- **New Command Line Options**
  - `--version` - Display builder version
  - `--no-live` - Disable live system creation (server builds)
  - Enhanced `--profile-info` with live and updater status

- **New Profile Features**
  - All desktop profiles now include live system support
  - System updater enabled by default for desktop profiles
  - Profile info shows live system and updater status

### Changed
- **builder.py** upgraded to v4.0.0
  - Added `LIVE_SYSTEM` and `SYSTEM_UPDATER` environment variables
  - New build stages: `system-updater`, `package-updater`
  - Improved USB device listing with size and model
  - Better error recovery with staged backups
  - Version display in build info and command line

- **14-create-installer.sh** Enhanced with live system
  - Squashfs creation of root filesystem
  - Separate live initramfs with overlay support
  - Persistence partition detection and mounting
  - Dual boot menu (Live/Install)
  - Copy custom scripts to live environment

- **Profile Manager** Updated
  - Added `live_system` and `system_updater` flags to all profiles
  - Size estimates adjusted for live system overhead
  - Default profile now uses live boot by default

- **Configuration Defaults**
  - LFS version: 12.2 → **13.0** (partial, completed in 4.2.0)
  - BLFS version: 12.2 → **13.0** (partial)
  - Kernel version: 6.12.10 → **6.12.20** (partial)
  - Java version: 21.0.8 → **21.0.10** (partial)

### Fixed
- Squashfs compression now properly excludes temporary directories
- Live initramfs detection of USB media
- Persistence partition label detection
- Boot menu timeout and default selection
- ISO size calculation in build summary
- Checksum generation for final ISO

### Security
- Live system runs with restricted kernel parameters
- Persistence partition uses encryption-ready filesystem
- Automatic audit of live session activities

## [3.0.0] - 2026-04-15

### Added
- **Security Hardening Module** (`15-security-hardening.sh`)
  - Kernel hardening with sysctl optimizations
  - Firewall setup (nftables/iptables with fallback)
  - Fail2ban integration for brute force protection
  - Audit system (auditd) with file integrity monitoring
  - AppArmor mandatory access control (optional)
  - Daily security scans with cron
  - Rootkit Hunter (rkhunter) integration
  - Lynis security auditing tool
  - AIDE (Advanced Intrusion Detection Environment)
  - Password quality enforcement (pwquality)
  - User account hardening (login delays, lockouts)
  - Encrypted swap support
  - Daily security reports via email

- **Privacy Tools Module** (`16-privacy-tools.sh`)
  - WireGuard VPN support
  - Tor anonymization network
  - DNSCrypt for encrypted DNS
  - Firefox privacy preset configuration
  - Telemetry blocking across applications
  - Core dump disabling
  - History sanitization for root user
  - /tmp clearing on boot

- **Init System Support** (`06a-init-system.sh`) - Enhanced in 4.2.0
  - **systemd** - Modern init with full service management
  - **SysV init** - Traditional UNIX init scripts (LFS classic)
  - **OpenRC** - Dependency-based init (Gentoo style)
  - **runit** - Simple service supervision
  - **s6** - Small supervision suite
  - Parallel service startup support
  - Auto-restart on failure capability
  - Configurable runlevels/targets

- **Service Management Abstraction** (`06b-service-management.sh`) - Enhanced in 4.2.0
  - Unified `svc` command for all init systems
  - Service aliases for consistent UX
  - Cross-platform service detection
  - Status, start, stop, restart, enable, disable commands

- **Custom Scripts System**
  - `theme-setup.sh` - Automatic font, icon, and GTK theme installation
  - `first-boot.sh` - First boot hardware detection and system configuration
  - Automatic first-boot service for systemd and SysV init
  - Theme persistence across user accounts

- **New Build Profiles**
  - `secure` - Security-hardened system with privacy tools
  - `full` - Complete system with all features enabled
  - Enhanced profile descriptions with security indicators

- **Extended Configuration Files**
  - `build-cross.conf` - Cross-compilation configuration for ARM, ARM64, RISC-V
  - `build-java.conf` - Java-optimized build configuration
  - `build.conf.minimal` - Lightweight server configuration
  - `init.conf` - Init system selection and tuning (enhanced in 4.2.0)
  - `lpm.conf` - Package manager configuration
  - `packages.conf` - Package definitions with categories
  - `packages.conf.json` - JSON format package definitions (updated to LFS 13.0 in 4.2.0)
  - `security.conf` - Comprehensive security settings

- **Profile Variants**
  - `gnome` - Full GNOME desktop environment
  - `kde` - KDE Plasma desktop (optional)
  - `lxqt` - Lightweight LXQt desktop
  - `server` - Optimized for server workloads
  - `custom` - User-defined profile template

- **Command Line Options**
  - `--init` - Override init system choice at build time (enhanced in 4.2.0)
  - `--list-profiles` - Show all available build profiles
  - `--profile-info` - Display detailed profile information
  - `--clean` - Remove build directory
  - `--verbose` - Enable detailed logging

- **Helper Tools**
  - `build-matrix.sh` - Multi-architecture build automation
  - `config-selector.sh` - Interactive configuration selection
  - Docker build support for macOS (`mac-lfs-builder.sh`, `Dockerfile.mac`)
  - WSL2 setup script for Windows

- **Documentation**
  - `README.md` - Complete project documentation
  - `CHANGELOG.md` - Version history (this file)
  - `CONTRIBUTING.md` - Contribution guidelines
  - `ADVANCED.md` - Advanced usage and optimization guide

### Changed
- **builder.py** upgraded to v3.0.0
  - Profile manager now includes security flags
  - Added resume capability from failed stages
  - Parallel source downloads (4 threads)
  - Checksum verification for all sources
  - USB device auto-detection
  - Build info JSON generation

- **14-create-installer.sh** Enhanced
  - Custom scripts integration (`theme-setup.sh`, `first-boot.sh`)
  - First-boot service for systemd and SysV init
  - EFI boot support
  - Automatic SHA256 checksum generation

- **Configuration System**
  - `build.conf` now includes comprehensive security section
  - Split configuration into specialized files

- **Package Sources** (`packages/sources.list`)
  - Updated to LFS 12.2 (Linux 6.12.10, GCC 14.2.0, Glibc 2.40)
  - XFCE 4.20, LightDM 1.32.1
  - Firefox 128.4.0esr, LibreOffice 24.8.4
  - JDK 21.0.8, Maven 3.9.9, Gradle 8.13

### Fixed
- Service detection across different init systems
- Java download URL issues (Eclipse Temurin)
- ISO creation with proper UEFI/BIOS dual boot support

### Security
- Hardened kernel parameters applied by default
- SSH root login disabled
- Daily vulnerability scanning

## [2.0.0] - 2026-04-15

### Added
- **Java Development Environment** (`12-install-java-dev.sh`)
  - OpenJDK 21.0.8 (Eclipse Temurin)
  - Maven 3.9.9, Gradle 8.13
  - Apache Tomcat 10.1.39, Jenkins 2.492.2
  - Node.js 22.14.0, Docker 27.4.1, kubectl 1.32.3
  - JMeter 5.6.3, Allure 2.32.0
  - JVM optimizations and demo projects

- **LPM Package Manager** (`13-create-package-manager.sh`)
  - `lpm` command with install, remove, list, search, info, create
  - Binary package format (.lpm)
  - Package database tracking
  - Repository system with multiple sources

- **Base Packages Creation** (`14-create-base-packages.sh`)
  - Pre-built packages for Java, Maven, Gradle, Tomcat, Node.js, Docker, Jenkins
  - Local repository generation

- **Desktop Configuration Enhancements**
  - XFCE panel customization
  - Theme and icon presets (Papirus, Arc-Dark)
  - Keyboard shortcuts
  - Auto-login configuration

- **New Build Profile**
  - `java-dev` - Java development environment with XFCE

### Changed
- **builder.py** upgraded to v2.0.0
  - Added profile manager class
  - Parallel downloads
  - Build resume capability

### Fixed
- Java download URL issues
- Tomcat and Jenkins service configurations

## [1.0.0] - 2025-12-20

### Added
- Initial release of LFS/BLFS Builder

- **Core Build System**
  - `builder.py` - Main orchestrator
  - LFSConfig configuration management
  - ScriptExecutor for build stages
  - USBWriter for ISO deployment

- **Host Preparation Scripts** (`scripts/host/`)
  - `01-check-host.sh` - System verification
  - `02-prepare-host.sh` - Environment setup
  - `03-create-disk-image.sh` - Disk image creation
  - `04-build-toolchain.sh` - Cross-compilation toolchain

- **LFS Core Scripts** (`scripts/lfs/`)
  - `05-build-lfs-basic.sh` - Base system
  - `06-build-lfs-system.sh` - Complete LFS
  - `07-configure-lfs.sh` - System configuration

- **BLFS Scripts** (`scripts/blfs/`)
  - `08-build-blfs-base.sh` - BLFS core
  - `09-build-desktop.sh` - Desktop environment
  - `10-build-applications.sh` - Applications
  - `11-configure-desktop.sh` - Desktop tuning

- **Finalization Scripts** (`scripts/final/`)
  - `12-create-initramfs.sh` - Initramfs
  - `13-create-bootloader.sh` - GRUB
  - `14-create-installer.sh` - ISO creation

- **Build Profiles**
  - `minimal` - CLI only, 1GB
  - `xfce` - XFCE desktop, 4GB
  - `gnome` - GNOME desktop, 8GB

- **Application Support**
  - Firefox, LibreOffice, GIMP, VLC, Thunar

- **Cross-Platform Support**
  - Linux native, macOS Docker, Windows WSL2

### Notes
- LFS version: 12.1
- Kernel version: 6.6.14
- Minimum RAM: 8GB
- Required disk: 50GB

---

## Version History

| Version | Date | Status | Key Features |
|---------|------|--------|--------------|
| 4.2.0 | 2026-05-14 | ✅ Current | Audio Production, SysVinit/systemd Choice, Network Stack |
| 4.1.0 | 2026-04-30 | ✅ Stable | Cross-Compilation, U-Boot, ARM64 Support |
| 4.0.0 | 2026-04-30 | ✅ Stable | Live USB, System Updater, Package Updater |
| 3.0.0 | 2026-04-15 | ✅ Stable | Security Hardening, Privacy Tools, Init Systems |
| 2.0.0 | 2026-04-15 | ✅ Stable | Java Dev Environment, LPM Package Manager |
| 1.0.0 | 2025-12-20 | ✅ Stable | Base LFS/BLFS with XFCE |

---

## Upgrade Notes

### From 4.1.0 to 4.2.0
1. Update `builder.py` to v4.2.0
2. Add audio profile sections to `packages.conf.json`
3. Create `config/audio-profile.conf` and `config/network.conf`
4. For audio production: `python3 builder.py --profile audio-studio`
5. For CLI audio (headless): `python3 builder.py --profile audio-cli`
6. To choose init system: `python3 builder.py --init sysvinit` or `--init systemd`

### From 4.0.0 to 4.1.0
1. Update `builder.py` to v4.1.0
2. Add cross-compilation sections to `build.conf` if needed
3. Install cross-compilation toolchain: `apt install gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu`
4. For ARM64 builds: `python3 builder.py --profile arm64 --config config/build-cross.conf`

### From 3.0.0 to 4.0.0
1. Update `builder.py` to v4.0.0
2. Add `system_updater` and `live_system` sections to `build.conf`
3. Run new scripts: `18-system-updater.sh`, `19-package-updater.sh`
4. Rebuild ISO for live system support

### From 2.0.0 to 3.0.0
1. Add `security` section to `build.conf`
2. Run security hardening scripts
3. Configure init system in `config/init.conf`

### Fresh Installation

```bash
# Clone repository
git clone https://github.com/lfs-builder/lfs-builder.git
cd lfs-builder

# For x86_64 desktop with live USB (systemd)
python3 builder.py --profile full

# For x86_64 desktop with sysvinit (LFS classic)
python3 builder.py --profile full --init sysvinit

# For audio production studio (XFCE + systemd)
python3 builder.py --profile audio-studio

# For headless audio production (CLI + sysvinit)
python3 builder.py --profile audio-cli --init sysvinit

# For ARM64 (Raspberry Pi)
python3 builder.py --profile arm64 --config config/build-cross.conf

# Write to USB/SD card
python3 builder.py --write-usb /dev/sdX