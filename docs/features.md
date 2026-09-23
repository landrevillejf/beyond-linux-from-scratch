The LFS/BLFS builder is a single Python orchestrator (`builder.py`) that provides **over 60 distinct features**, organized into the following categories:

---

### 🧩 **Build Profiles** (18)
- 17 predefined profiles + 1 custom template (`minimal`, `gnu-free`, `gnu-free-full`, `xfce`, `gnome`, `java-dev`, `secure`, `full`, `arm64`, `audio-cli`, `pinebook`, `audio-studio`, `kde`, `lxqt`, `server`, `brax3`, `lg3d`, `custom`).
- Each profile defines packages, desktop, init system, live-system flag, security hardening, privacy tools, package manager, system updater and (for ARM/mobile) cross-compilation and bootloader.
- Inspect them with `--list-profiles` and `--profile-info <profile>`.
- `lg3d` provisions a bare X11/Xorg host (no Wayland, no display manager), installs Project Looking Glass to `/opt/lg3d`, and wires it as the X11 session -- a systemd unit hands off to `xinit` -> `run-lg3d.sh`, in compositor mode by default (`2d`/`swing`/`dev` selectable via the profile's `lg3d_mode`) -- so lg3d runs as the window manager + compositor; the binding host contract lives in `lfs-x11-contract.md`.

### ⚙️ **Init Systems** (5)
- Choice of `sysvinit`, `systemd`, `openrc`, `runit`, or `s6` (via `--init`).
- Service abstraction layer plus a first-boot service.

### 🖥️ **Desktop Environments**
- XFCE, GNOME, KDE Plasma, LXQt and Phosh (mobile), or no GUI.
- Display manager (LightDM and friends), Xorg and Wayland stacks.
- Desktop extras such as Firefox, LibreOffice, GIMP and VLC.

### 📚 **Book Compliance**
- Stages follow LFS 13.0 / BLFS 13.0: packages are built with the exact commands from the books, with the books' error policy enforced.

### 📦 **Package Management (LPM)**
- Integrated `lpm` package manager with dependency resolution, checksum verification, auto-clean and daily upgrade checks.
- Base package creation and `lfs-update` integration.

### 🔄 **System Updater**
- Backup/rollback support, automatic update checks and package updater, shipped on every profile.

### 💿 **Live System & Installer**
- Live ISO with squashfs compression (xz) and persistence support.
- Hybrid BIOS/UEFI bootable installer ISO generation.
- Initramfs creation for the live system.
- Opt-in Calamares build chain: the `calamares-build` stage compiles popt, the filesystem tools (dosfstools, gptfdisk, parted), a trimmed Qt6, extra-cmake-modules, the KF6 CoreAddons/I18n/WidgetsAddons trio, polkit-qt-1, yaml-cpp, kpmcore and Calamares 3.3, and refuses to pass unless `libcalamares_viewmodule_partition.so` exists; `calamares` then writes the configuration. Disabled on every profile for now - turn it on with `--installer calamares` or a profile's `graphical_installer` flag. Nothing boots into it yet: the ISO's `install` GRUB entry still chains to the same live session, and `blfs/22-calamares-installer.sh` only writes configuration.

### 🔐 **Encryption**
- Full-disk LUKS encryption via the `luks-encryption` stage, with encrypted swap support.

### ☕ **Java Development**
- Install OpenJDK (Temurin), Maven, Gradle, Tomcat, Jenkins, Docker and kubectl via the `java-dev` stage.

### 🎚️ **Audio Production**
- `audio-studio` profile: Ardour DAW, LV2 plugin packs (LSP Plugins, Dragonfly Reverb), NeuralRack and realtime tuning (`audio` group, `limits.d`, low-latency sysctl).
- PREEMPT_RT realtime kernel config auto-selected per profile.
- `audio-cli` keeps a console-only PipeWire/JACK promise.

### 🌐 **Networking, Server & Multimedia**
- Basic networking: DHCP, DNS, IPv6, Wi-Fi, Bluetooth configuration.
- Server packages: Apache, MariaDB, PostgreSQL, Samba, OpenSSH, BIND, OpenLDAP and more.
- Multimedia: PipeWire/PulseAudio, GStreamer, ffmpeg, mpv, VLC.
- Printing and scanning: CUPS, SANE, Gutenprint.

### 🔒 **Security & Privacy**
- Kernel hardening, nftables firewall, fail2ban, audit and HIDS (AIDE) with daily scans.
- User hardening (password policy, root login lockout, login attempt limits).
- Privacy tools: telemetry blocking, DNSCrypt, WireGuard, Tor.

### 🎨 **Professional Branding**
- Central TOML configuration (`branding/branding.toml`) with profile-specific presets.
- Branded GRUB boot menu, custom backgrounds, splash screens, ISO volume label and publisher metadata.
- Desktop themes, icon packs, custom wallpapers and a branding manifest with checksums.
- Desktop-specific customization (XFCE, GNOME, KDE, LXQt, Phosh).

### 🔧 **Cross-Compilation & Bootloaders**
- ARM64 (aarch64) cross-compilation with QEMU user emulation; target arch overridable with `--arch`.
- Bootloaders: GRUB, U-Boot and ABoot (overridable with `--bootloader`).

### 🛠️ **Build & Customisation**
- Parallel source downloads with configurable timeouts, retries and layered mirror fallbacks (GNU mirrors, BLFS conglomeration, Void Linux).
- Archive magic-byte validation and SHA/MD5 checksum verification.
- Parallel compilation (`-j$(nproc)`).
- Build cache: restore a pre-built rootfs (`--use-cache`, `--cache-only`, `--cache-url`).
- Resume from a failed stage (`--resume-from`) and stop early (`--stop-after`).
- Verbose logging (`--verbose`), interactive clean (`--clean`).
- Generate sources list (`--generate-sources-list`).
- Custom JSON config, custom source lists (`packages/custom-sources.list`), post-install scripts.

### 📦 **Supply-Chain Artifacts**
- GPG-sign the generated ISO (`--sign-iso [GPG_KEY]`).
- Generate an SPDX software bill of materials (`--sbom`).
- Milestone (`--milestone alpha1`) and nightly (`--nightly`) ISO naming.

### 🖥️ **Multi-Platform & Host Prep**
- Runs on Linux (native), macOS (Docker via `mac-lfs-builder.sh`) and Windows (WSL2).
- Host environment checks, distro detection/override (`--host-distro`) and Docker detection.
- Creates and configures the `lfs` user, bootstraps the chroot with binaries and libraries.
- Disk image creation and disk space validation.

### 🖱️ **Additional Utilities**
- USB writer (`--write-usb`) with automatic partition unmounting and `rdisk` on macOS.
- Final `validate` stage that checks the produced image before publication.
- Wallpaper generator and system audit scripts.

### ⏱️ **CI/CD Automation**
- Cache generation pipelines, a shared base prefix cache (`build-base-cache.yml`), full ISO release pipelines and ISO-from-cache reconstruction.
- Nightly profile matrix builds with concurrency control and per-job budgets.
- Build, benchmark, cross-compile verification, CodeQL and Codacy security scans.

---

In total, the builder offers **over 60 configurable features**, making it a highly flexible tool for building custom LFS/BLFS distributions.
