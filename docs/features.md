The LFS/BLFS builder is a Python script that provides **over 50 distinct features**, organized into the following categories:

---

### 🧩 **Build Profiles** (17)
- 16 predefined profiles + 1 custom (`minimal`, `gnu-free`, `gnu-free-full`, `xfce`, `gnome`, `java-dev`, `secure`, `full`, `arm64`, `audio-cli`, `pinebook`, `audio-studio`, `kde`, `lxqt`, `server`, `brax3`, `custom`).

### ⚙️ **Init Systems** (5)
- Choice of `sysvinit`, `systemd`, `openrc`, `runit`, or `s6` (via `--init`).

### 📦 **Package Management**
- Integrated `lpm` package manager with dependency resolution, auto‑clean, and upgrade checks.
- Base package creation and advanced `lpm` features.

### 🔄 **System Updater**
- Backup/rollback support, automatic update checks, and package updater.

### 💿 **Live System & Installer**
- Live ISO with squashfs compression and persistence support.
- Bootable installer ISO generation.
- Initramfs creation.

### 🖥️ **Desktop Environments**
- XFCE, GNOME, KDE, LXQT (plus custom extras like Firefox, LibreOffice, GIMP, VLC).

### ☕ **Java Development**
- Install OpenJDK, Maven, Gradle, Tomcat, Jenkins, Docker, kubectl.

### 🔒 **Security & Privacy**
- Kernel hardening, firewall (nftables), fail2ban, audit, HIDS (AIDE), daily scans.
- Privacy tools: telemetry blocking, DNSCrypt, WireGuard, Tor.

### 🔧 **Cross‑Compilation & Bootloaders**
- ARM64 cross‑compilation with QEMU support.
- Bootloaders: GRUB, U‑Boot, ABoot (overridable).

### 🌐 **Networking & Users**
- DHCP, DNS, IPv6, Wi‑Fi, Bluetooth configuration.
- User creation with groups, sudo, autologin.

### 🛠️ **Build & Customisation**
- Parallel source downloads with retries and MD5 checksum verification.
- Parallel compilation (`-j$(nproc)`).
- Build cache (use pre‑built tarballs via `--use-cache`, `--cache-only`).
- Resume from failed stages (`--resume-from`).
- Verbose logging (`--verbose`), clean build directory (`--clean`).
- Generate sources list (`--generate-sources-list`).
- Custom JSON config, custom source lists, post‑install scripts.

### 🖥️ **Multi‑Platform & Host Prep**
- Runs on Linux, macOS, Windows (WSL2).
- Host environment checks, Docker detection.
- Creates and configures the `lfs` user.
- Bootstraps chroot with necessary binaries and libraries.

### 🖱️ **Additional Utilities**
- USB writer (`--write-usb`).
- System audit script (separate).
- Branding (themes, wallpapers, icons).
- First‑boot service and service abstraction.

### 📝 **Miscellaneous**
- Disk space validation.
- Display profile information (`--profile-info`).
- List available profiles (`--list-profiles`).
- Override kernel type (`--kernel-type`), version (`--kernel-version`).
- Override bootloader (`--bootloader`).
- Support for custom kernel types (linux-libre, gnu‑hurd, freebsd).
- Audio profiles (CLI, studio).
- Specific device profiles (Pinebook, Brax3).

---

In total, the builder offers **over 50 configurable features**, making it a highly flexible tool for building custom LFS/BLFS distributions.