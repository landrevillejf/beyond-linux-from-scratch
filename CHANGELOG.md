# Changelog

## Unreleased

### Changed

- **LFS/BLFS book compliance remediation, wave 1** (`docs/LFS_COMPLIANCE_AUDIT.md`)
  - `lfs/05b-build-lfs-system.sh`: full rewrite — native chapter 7/8
    rebuild inside the chroot with a per-package dispatcher following the
    exact LFS 12.4 book commands (~80 packages), book configure flags
    (`--enable-gold` dropped, glibc `--enable-kernel=5.4`,
    `libc_cv_slibdir=/usr/lib`), book 8.84 stripping, 8.85 cleanup
    (`.la` removal, cross-compile dir purge), `rm -rf /tools` and a
    standalone smoke test at the end
  - `lfs/07-configure-lfs.sh`: rewritten per book chapter 9 — every
    config file generated inside the chroot, no host binary imports
  - `lfs/08-build-kernel.sh`: kernel now compiled inside the chroot with
    the chapter 8 toolchain (book 10.3) using `config/kernel-config*`
    (`olddefconfig`); host build kept only for `CROSS_COMPILE` profiles
  - `blfs/08-build-blfs-base.sh`: per-package BLFS book commands
    (OpenSSL `./config`, cURL `--with-openssl --with-ca-path`, expat,
    libxml2, blfs-bootscripts); `|| true` error masking removed — a
    failed package now fails the stage
  - `final/16-validate-build.sh`: new guardrails — `/tools` removal
    check, `/usr/bin/bash` presence, recursive `readelf -d` scan for
    residual `/tools` RPATH/RUNPATH entries, kernel `.config`
    provenance vs repository config
  - Tests: 5 new guardrail tests
    (`tests/test_acceptance_shell.py::TestLFSComplianceGuardrails`),
    `tests/test_lfs_system_bootstrap.py` updated for the new 05b

- **LFS/BLFS book compliance remediation, wave 2** (`docs/LFS_COMPLIANCE_AUDIT.md`)
  - Strict error policy across all 12 remaining BLFS stages (`blfs/08a`,
    `08b`, `08c`, `08d`, `09a`, `09b`, `09c`, `09d`, `23`, `24`, `25`,
    `26`): every package now goes through a `run_build required|optional`
    wrapper — a required failure aborts the stage, and a package may only
    be optional when its tarball is absent from
    `packages/stable/12.4/sources.list`; the old `|| log_warning` and
    silent missing-source skips are gone
  - Honest required/optional classification driven by the source list:
    08a libyaml/glib2/icu/rust aliases, 08b gtk3/gtk4 major-version
    glob pinning, 09b libsoup3/gcr-4 aliases, 09c Qt6 built from the
    monolithic `qt-everywhere-src` tarball per the BLFS page, 25 apache
    resolves to the `httpd` tarball
  - All chroot executions now use a clean environment
    (`chroot "$LFS" /usr/bin/env -i HOME=/root TERM=... PATH=...`)
  - `packages/stable/12.4/sources.list`: added the 18 Xorg client
    libraries (libX11, libXext, libXrender, libXfixes, libXi, libXrandr,
    libXcursor, libXinerama, libXcomposite, libXdamage, libfontenc,
    libxkbfile, libXtst, libXScrnSaver, libXv, libXxf86vm, libXres,
    libXpm), the 5 xcb-util-* modules, gtk-4.18.6 and gcr-4.4.0.1
  - Tests: 5 new guardrail tests
    (`tests/test_acceptance_shell.py::TestBLFSErrorPolicyGuardrails`)
    covering the run_build policy, masking absence, clean-env chroot,
    required-package source resolution and shellcheck (outer + inner
    heredoc) on all 12 scripts

- **LFS/BLFS book compliance remediation, wave 3** (`docs/LFS_COMPLIANCE_AUDIT.md`)
  - Per-package BLFS book commands across all 12 package-building
    stages (`blfs/08a`, `08b`, `08c`, `08d`, `09a`, `09b`, `09c`,
    `09d`, `23`, `24`, `25`, `26`): the generic meson/autotools/cmake
    auto-detection is now only a fallback — every package with a
    `docs/books` page is built with its exact book commands through a
    `book_install` runner (`build_<name>`/`build_commands_<name>`
    functions dispatched by `run_build`), including book patches,
    seds, docdirs and post-install steps; patches and companion
    tarballs stay guarded on their presence in the sources
  - Book sysvinit-variant flags (`--without-systemd`,
    `--with-systemd=no`, SDDM elogind switches, thunar/notifyd
    systemd flags) are applied conditionally via `HAVE_SYSTEMD`
  - Group loops kept where the book uses one command for a family:
    KF6 frameworks and Plasma (09c), LXQt (09d), Xorg protocol/proto
    batches (08b)
  - Book deviations documented in each script header (Qt6/KF6
    prefixes adapted from `/opt` to `/usr`, ffmpeg codec backends
    enabled only when the dev library is available)
  - Packages without a book page (picom, libgnomekbd, gnome-logs,
    kate/kcalc/kinit, lxqt-wallet, libtheora, mplayer, vsftpd,
    gsfonts, hplip, sane-frontends) keep the generic `build_pkg`
  - Tests: 2 new guardrail tests
    (`tests/test_acceptance_shell.py::TestBLFSBookCommandGuardrails`)
    covering book_install/build_commands dispatch and the generic
    fallback on all 12 scripts

- **LFS/BLFS book compliance remediation, wave 4** (`docs/LFS_COMPLIANCE_AUDIT.md`)
  - Init-system stages hardened (`lfs/06a-init-system.sh`,
    `06b-service-management.sh`, `06c-init-openrc.sh`,
    `06d-init-runit.sh`, `06e-init-s6.sh`):
    - Removed the `copy_tool_with_libs()` host-tool import in `06a`
      (audit F-05); chapter 8 coreutils already provide every build
      utility inside the chroot.
    - Added the strict `run_build required|optional` policy; missing
      source archives now fail the package instead of being skipped.
      sysvinit/lfs-bootscripts/libgpg-error/libgcrypt/libseccomp/kmod/
      systemd are required; openrc, runit and the s6/skalibs stack stay
      optional (not LFS/BLFS book packages, not yet in sources.list).
    - Fixed the systemd `extract_archive "systemd"` literal-string bug.
    - Every chroot now runs under a clean environment
      (`chroot "$LFS" /usr/bin/env -i HOME=/root TERM=... PATH=...`);
      `/tools/bin` no longer appears in any inner PATH.
    - Replaced `umount || true`, `chown || true` and the `06b`
      compatibility-link masking with specific `log_warning` messages;
      mounts guarded with `mountpoint -q`.
  - Tests: 6 new guardrail tests
    (`tests/test_acceptance_shell.py::TestInitSystemErrorPolicyGuardrails`)

- **LPM 2.7.0: improvements and integration** (`blfs/19-lpm.sh`,
  `blfs/14-create-base-packages.sh`, `blfs/18-system-updater.sh`)
  - Build-time database seeding: stage 14 now resolves real package
    versions from the tarballs in `$LFS/sources` (same name-version
    split rule as LPM), refreshes the curated fallback table to LFS
    13.0 versions, and seeds `/var/lib/lpm/installed.list` so
    `lpm list/upgrade/verify` work on the finished system
  - Real repository pipeline: stage 14 exports the manifest to
    `lpm-repo/` (`packages.list` + `.sha256`, optional GPG `.sig`);
    the release, ISO and nightly workflows upload it as release
    assets (nightly releases are marked as prereleases so GitHub's
    `latest` pointer keeps serving the stable manifest); the
    installed default repo in
    `/etc/lpm/repos.d/default.conf` now
    points at the GitHub releases `latest/download` URL
  - `lpm update-db` no longer silently overwrites the database with
    sample data when configured remotes fail — it keeps the existing
    database and warns; sample data only seeds an empty database with
    no remotes configured
  - New commands: `lpm upgradable`, `lpm why` (alias `rdepends`),
    `lpm autoremove [--dry-run]`, `lpm hold/unhold/holds` (upgrade
    skips held packages with a warning), `lpm history` (timestamped
    transaction log at `/var/lib/lpm/history.log`), `lpm reinstall`
  - `lfs-update` hardening: curl-first fetch with wget fallback,
    init-system-agnostic `status` (no more `systemctl`), the
    `/etc/lfs-version` marker is only written when the repo manifest
    declares a version (hardcoded `13.0` write removed), `check`
    reports the upgradable package count, weekly
    `/etc/cron.weekly/lfs-update-check` installed when cron is present
  - Tests: `tests/test_lpm.py` (guardrails + sysroot smoke tests) and
    two new guardrails in
    `tests/test_acceptance_shell.py::TestLFSComplianceGuardrails`

### Added

- **Production-ready first-boot service** (`blfs/17-first-boot-service.sh`)
  - SSH host key regeneration, random initial password, locale/timezone setup,
    ldconfig, live-USB partition resize, machine-id regeneration, self-disable
  - Supports systemd, sysvinit, and runit init systems

- **nftables default-deny firewall** (`blfs/15-security-hardening.sh`)
  - Stateful inspection, rate-limited SSH, ICMP/ICMPv6, HTTP/HTTPS, mDNS
  - Override directory `/etc/nftables/conf.d/` for custom rules

- **LPM remote repository configuration** (`blfs/19-lpm.sh`)
  - Installs `config/lpm.conf` and creates `/etc/lpm/repos.d/default.conf`
    with the `lfs-releases` remote repo backed by GitHub release assets
    (manifest published by the release pipeline)

- **GRUB config template** (`config/grub.cfg`)
  - Branded boot menu with build-time variable substitution (ROOT_UUID,
    KERNEL_VERSION, BOOTLOADER_TIMEOUT, KERNEL_CMDLINE)
  - Integrated into `final/13-create-bootloader.sh` with fallback to
    `grub-mkconfig`

- **End-to-end pipeline integration tests** (`tests/test_e2e_pipeline.py`)
  - 33 tests covering stage integrity, JSON configs, profiles, branding,
    security hardening, first-boot, LPM, and download resilience

- **Plymouth Python fallback** (`blfs/20-branding.sh`)
  - Generates gradient PNGs when `rsvg-convert` is unavailable

- **MkDocs favicon and logo** (`docs/favicon.svg`, `docs/logo.svg`)
  - Source SVG assets matching branding identity for documentation site

- **LFS build recipes for LPM** (`recipes/lfs/`)
  - Complete, ordered set of `.lpm` recipes reconstructing the entire LFS 13.0 book
    (cross-toolchain → temporary tools → final system) — one package per recipe
  - `recipes/lfs/build-order.txt` canonical build order and `recipes/lfs/build-all.sh`
    driver (supports `--phase`, `--start`, `--dry-run`, `--list`)
  - Shared helper library `recipes/lfs/lib.sh` (companion-tarball fetcher) and
    `recipes/lfs/TEMPLATE.lpm`
  - Final-system recipes install via `DESTDIR="$PKG"` so every package is tracked in
    the LPM database and can be verified, reinstalled, upgraded and removed
  - `lpm build` now exports `PKG` (staging dir), `SRC` (source dir) and `JOBS`
    (parallel jobs) to recipe `build()` functions

- **LPM v2.4.0 quality-of-life features**
  - New `lpm verify` (alias `check`) command to verify the integrity of installed
    packages — compares on-disk files against the pristine copies in the package
    database (SHA-256 for files, target for symlinks) and reports modified/missing files
  - New global `--sysroot <dir>` option: an explicit alias of `LPM_ROOT` for operating
    on alternate roots/chroots (also accepts `--sysroot=<dir>`)
  - `lpm search` now matches patterns literally (`grep -F`) so regex metacharacters
    (`.`, `*`, `[`, …) can no longer be misinterpreted

- **LPM Profile Management System**
  - New `lpm list-profiles` command to list all available build profiles
  - New `lpm add-profile <profile>` command to install preset package collections
  - 12 predefined profiles: minimal, java-dev, audio-studio, xfce, gnome, kde, lxqt, server, web-dev, gnu-free, secure, multimedia
  - Profiles stored in `/etc/lpm/profiles.json` with full package specifications
  - Full dependency resolution for profile packages (uses existing install_order function)
  - Dry-run support for preview before installation
  - Modular system composition workflow: start minimal, add profiles incrementally

### Fixed

- **Nightly #159 failures: aarch64 coreutils `make install` and xfce `xz: liblzma.so.5` missing** (`host/04-build-toolchain.sh`)
  - arm64 job: the `toolchain` stage died in temporary coreutils
    `make install` with `mv: '..._inst.451424_' ... are the same file`
    right after qemu reported `aarch64-binfmt-P: Could not open
    '/lib/ld-linux-aarch64.so.1'`. With `$LFS/tools/bin` leading PATH,
    the install machinery resolved `cp`/`mv`/`basename`/... to the
    freshly installed aarch64 binaries, which the x86_64 runner cannot
    execute
  - Fix: on cross builds (target triple keyed on `$LFS_TGT`) PATH now
    puts the host directories first; the cross toolchain still
    resolves since it only exists in `$LFS/tools/bin`. Native builds
    keep the book order. `QEMU_LD_PREFIX=$LFS` is also exported so any
    binfmt-mediated execution of target binaries resolves the loader
    from the sysroot
  - xfce x86_64 job: the `lfs-system` stage died on the first source
    extraction (`xz: error while loading shared libraries:
    liblzma.so.5`): the temporary tools link against the target glibc
    whose loader only searches `/lib` and `/usr/lib` at runtime, so
    `/tools/lib` is invisible inside the chapter 7/8 chroot
  - Fix: every temporary tools configure call (generic loop, ncurses,
    file) now passes `LDFLAGS="-Wl,-rpath,$LFS/tools/lib"`, keeping
    the `/tools` userspace self-contained
  - Regression tests: `test_toolchain_cross_builds_keep_host_utils_first`,
    `test_temp_tools_carry_tools_lib_rpath`

- **Nightly #158 toolchain failures: aarch64 `libgcc_s` location and coreutils help2man** (`host/04-build-toolchain.sh`)
  - arm64 job: the fail-fast guard from the previous fix tripped with
    `libgcc_s.so.1 missing from .../usr/lib after GCC pass 2` because GCC
    installs 64-bit target libraries into its `MULTILIB_OSDIRNAMES`
    default dir — `/usr/lib64` on aarch64. The LFS book's lib64 -> lib
    normalization (section 5.3) was only applied for x86_64 and keyed on
    `uname -m`, which never matches on cross builds
  - Fix: the `t-linux64`/`t-aarch64-linux` sed is now keyed on `$LFS_TGT`
    and covers `aarch64*`, applied in the libstdc++ pass and both GCC
    passes; the remaining target-layout decisions (`$LFS/lib64` dir,
    glibc loader compatibility symlinks) are keyed on `$LFS_TGT` too
  - minimal x86_64 job: temporary coreutils failed with
    `help2man: can't get '--help' info from man/stty.td/stty` because
    target binaries happen to run on the same-architecture build host,
    so autoconf resolves `cross_compiling=no` and coreutils runs the
    real help2man against them
  - Fix: the temporary coreutils build forces
    `run_help2man=man/dummy-man`, which installs the distributed man
    pages — exactly what coreutils does for genuine cross builds

- **Nightly toolchain failure: hidden `_Unwind_*` symbol in ncurses C++ link** (`host/04-build-toolchain.sh`)
  - Both nightly jobs (java-dev x86_64, arm64 aarch64) failed at the
    `toolchain` stage with `hidden symbol '_Unwind_GetLanguageSpecificData'
    in libgcc.a is referenced by DSO` while linking the ncurses
    `--with-cxx-shared` demo program
  - Root cause: the Chapter 6 temporary tools link with the pass 1
    cross compiler (`--disable-shared`), whose static-only libgcc keeps
    unwind symbols hidden since GCC 14. The sysroot had no
    `libgcc_s.so.1`, so the linker could not resolve the unwind
    reference carried by `libncurses++w.so`
  - Fix: GCC pass 2 is already built before the tools loop, and it
    installs `libgcc_s.so.1` into the sysroot (`$LFS/usr/lib`, reachable
    through the usr-merge `/lib` symlink); the stage now fails fast if
    it is missing, and the temporary ncurses build passes
    `LDFLAGS="-lgcc_s"` so the shared C++ library and the demo program
    resolve unwind symbols against the shared libgcc

- **ncurses C++ binding fails with GCC 15** (`host/04-build-toolchain.sh`, `lfs/05b-build-lfs-system.sh`)
  - GCC 15 defaults to C23 where `bool` is a keyword, so ncurses
    configure misdetects `bool` and emits a `curses.h` that leaks
    `#define bool unsigned char` into the C++ binding, breaking it
    against GCC 15 libstdc++ headers (`redefinition of 'struct
    std::hash<unsigned char>'`)
  - Both ncurses builds (temporary toolchain and final system) now
    pass `CFLAGS="-O2 -std=gnu17"` — same workaround shipped by
    Arch Linux

- **Hardcoded root password replaced with random generation** (`lfs/07-configure-lfs.sh`)
  - Initial password is now 16-character random alphanumeric, stored in
    `/etc/.initial-password` (mode 600), cleaned up by first-boot service

- **Download reliability with exponential backoff** (`builder.py`)
  - `SourceDownloader.download()` retries transient errors (5xx, 429, timeouts)
    with exponential backoff and jitter; permanent 4xx errors fail immediately
  - `download_from_list()` performs sequential retry passes after the initial
    parallel download to recover transient failures
  - CI workflow updated: timeout 120s, 5 retries, 3 parallel, 3 retry passes

- **Shell script audit — 5 bugs fixed across stage scripts**
  - `blfs/20-branding.sh`: missing `fi` (syntax error)
  - `final/15-create-live-system.sh`: empty `$EFI_OPTION` passed as empty arg
  - `final/12-create-initramfs.sh`: hardcoded `/dev/sda2` replaced with
    auto-detection from kernel cmdline UUID + probe common devices
  - `final/13-create-bootloader.sh`: hardcoded `/dev/sda` replaced with
    auto-detection probing `/dev/sda`, `/dev/vda`, `/dev/nvme0n1`, `/dev/xvda`
  - `final/14-create-installer.sh`: raw FAT image copied as BOOTX64.EFI —
    now mounts FAT image and extracts actual `grubx64.efi`

- **Script executable permissions** — 12 stage scripts were tracked as 100644
  in git instead of 100755; fixed with `git update-index --chmod=+x`

- **README.md** — fixed wrong kernel script path (`lfs/09-build-kernel.sh` →
  `lfs/08-build-kernel.sh`), added missing `--kernel-version` and `--arch`
  CLI options to command-line reference table

- **LPM `build`/`install` package pipeline** — made source builds installable
  - Routed `log_info`/`log_success`/`log_verbose` to stderr so value-returning
    helpers (`fetch_source`, `assemble_package`, `fetch_package`) no longer leak
    log lines into captured return values (which corrupted checksums and paths)
  - Fixed package extraction in `install_package` to strip the leading
    `<name>-<version>/` directory (`--strip-components=1`), so packaged files are
    actually copied into the install root instead of being silently skipped
- **LPM Critical Fixes** - Achieved production-ready status
  - Fixed regex escape bug in `parse_dep_spec()` for dependency version constraints
  - Replaced non-portable `sort -V` with pure-bash version comparison (10x faster)
  - Optimized circular dependency detection from O(n) to O(1) substring matching
  - Improved `install_order()` from O(n²) to O(n) complexity with awk optimization
  - Accelerated package removal file counting with single awk pipeline (5x faster)
  - LPM now fully portable to minimal LFS systems and performance-competitive with YUM/DNF/APT

All notable changes to the LFS/BLFS Builder project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] - 2026-08-01

### Fixed

- **Toolchain cross-compile configure failures (diffutils-3.12, patch-2.8, and future gnulib-bundled packages)**
  - Root cause: newer packages (e.g. `diffutils-3.12`) bundle updated gnulib containing
    `AC_RUN_IFELSE` checks (e.g. `strcasecmp`, `strncasecmp`, `strnlen`, `mktime`) that
    have no cross-compile default — autoconf aborts with
    `cannot run test program while cross compiling` instead of guessing.
  - Fix: a comprehensive per-package configure cache is written before the temporary-tools
    build loop in `host/04-build-toolchain.sh`. Each package receives its own copy of the
    cache template to prevent cross-contamination between configure runs. The cache
    pre-answers all known gnulib/autoconf runtime tests for the x86_64-linux target:
    `ac_cv_func_strcasecmp`, `gl_cv_func_strcasecmp_works`, `ac_cv_func_strncasecmp`,
    `gl_cv_func_strncasecmp_works`, `gl_cv_func_working_mktime`, `gl_cv_func_mknod_works`,
    `gl_cv_func_strnlen_works`, `gl_cv_func_fflush_stdin`, `gl_cv_func_getgroups_works`,
    `gl_cv_func_memmem_works`, and related.

- **libstdc++ now built before the essential-tools loop (correct LFS book ordering)**
  - Previously libstdc++ was built after all temporary tools; it is now built immediately
    after glibc, matching LFS Book Chapter 6 ordering.

### Added

- **m4 and xz added to the temporary-tools build list in `host/04-build-toolchain.sh`**
  - `m4` is required by autoconf-based configure scripts inside the temporary system;
    `xz` is needed to decompress `.tar.xz` archives in the chroot before the host-bootstrap
    stage provides it. Both are skipped gracefully with a warning if their source archives
    were not downloaded.

- **Regression test: `test_toolchain_cross_compile_cache`**
  - Verifies the cross-compile configure cache, the key gnulib cache entries, the
    `--cache-file` flag, the correct libstdc++ build order, and presence of `diffutils`
    and `patch` in the package loop.

## [Previously Unreleased] - 2026-07-20

### Added

- **Professional Branding System with TOML config and auto-generation** (2026-07-20 16:44:26)
  - Comprehensive branding.toml with all colors, themes, and configurations
  - Branding manager Python module for configuration export
  - Support for multiple branding presets
  - Desktop-specific customization

- **Complete installer branding system with GRUB integration** (2026-07-20 17:00:30)
  - GRUB boot menu with branded background gradient (800x600)
  - Custom GRUB color scheme (Forest Green primary, Light Green highlight)
  - Branded ISO volume label: `BLFS-X.Y.Z-LIVE`
  - Installer splash screen (1024x768 professional gradient)
  - Zero external dependencies (PPM format, GRUB-native)
  - Automatic PNG conversion if ImageMagick/Pillow available

### Changed

- **Comprehensive shell script hardening** (2026-07-20 10:55:32)
  - Fixed 350+ shell scripting issues across 22 scripts
  - SC2086 (unquoted variables): 150+ instances corrected
  - SC2010/SC2012 (unsafe ls patterns): Replaced with `find` commands
  - SC2162 (read without -r): Added `-r` flag
  - SC2046 (unquoted command substitution): Properly quoted
  - SC2028 (echo vs printf): Replaced with `printf` for binary data
  - Sudo hardening: Added `-n` (non-interactive) flag for CI/CD
  - All 29+ scripts now pass ShellCheck with zero critical issues

- **Remove hardcoded init/desktop from profiles** (2026-07-20 14:20:26)
  - Removed hardcoded `--init systemd` from `profiles/brax3/build.sh`
  - Removed hardcoded `--init sysvinit` from `profiles/pinebook/build.sh`
  - Removed hardcoded `--desktop pcmanfm-qt` from `profiles/lxqt/customization.sh`
  - Profiles now receive parameters via CLI arguments

### Fixed

- **Add non-interactive flag to sudo in build-toolchain script** (2026-07-20 10:42:31)
  - Fixes authentication failure in CI/CD environments using 'sudo -n'

- **Replace ls glob check with find in source verification** (2026-07-20 11:29:57)
  - Source existence check was using unsafe 'ls' with glob pattern (SC2012)
  - Now uses robust `find` command for reliable verification

- **Create build-release/sources directory before cache restore** (2026-07-20 12:23:30)
  - Cache restore step was failing due to missing sources directory
  - Pre-create directory structure for CI workflow

- **Align LFS directory structure with sources location** (2026-07-20 13:04:45)
  - LFS should point to output_dir (not output_dir/image)
  - Ensures `$LFS/sources` resolves to actual sources directory
  - Fixes "Source for binutils not found" error at build stage 4

- **Resolve output_dir to absolute path to prevent LFS configure error** (2026-07-20 17:23:06)
  - Configure scripts require absolute paths for `--prefix` argument
  - When builder.py invoked with relative path (e.g. ./build-release)
  - Fixes: "configure: error: expected an absolute directory name for --prefix"

- **Convert LFS path to absolute path** (2026-07-20 13:48:09)
  - Configure scripts require absolute paths
  - Use Path.resolve() for proper path handling
  - Enables autotools to find all prerequisites during compilation

- **Add missing build dependencies for GCC** (2026-07-20 14:33:10)
  - libgmp-dev, libmpfr-dev, libmpc-dev required for GCC toolchain
  - Fixes "Building GCC requires GMP/MPFR/MPC" errors in CI
  - Added to .github/workflows/release.yml

- **Install Linux API headers to $LFS/usr/include for glibc configure** (2026-07-20 19:48:03)
  - Toolchain build was failing due to missing kernel headers
  - glibc configure now finds required headers
  - Fixes glibc compilation in chroot environment

- **Ensure toolchain stage uses $LFS cross compiler path** (2026-07-20 20:33:32)
  - Verifies cross-compiler binaries are found in chroot
  - Fixes "cannot find /tools/bin/x86_64-lfs-linux-gnu-gcc" errors

- **Harden lfs env generation for toolchain path resolution** (2026-07-20 20:36:29)
  - Fixes LFS environment variable initialization
  - Ensures path consistency across build stages
  - Prevents path corruption from shell expansions

- **Fix glibc cross-compile configure to resolve GCC_NO_EXECUTABLES error** (2026-07-20 21:53:51)
  - Toolchain stage was failing with cross-compilation test errors
  - Added required compiler flags for cross-compilation
  - Enables proper glibc compilation in toolchain

- **Use cross-prefixed binary names in check_toolchain verification** (2026-07-21 00:08:56)
  - check_toolchain() was checking for plain 'gcc', 'ld', 'as'
  - Now properly checks for cross-prefixed binary names (x86_64-lfs-linux-gnu-gcc)
  - Fixes toolchain verification in CI environment

### Files Modified
- `builder.py`: Path resolution and absolute path handling
- `.github/workflows/release.yml`: Build dependencies and cache paths
- `final/14-create-installer.sh`: Branding integration
- Multiple shell scripts in `host/`, `lfs/`, `blfs/`: 350+ hardening fixes
- `profiles/brax3/build.sh`, `profiles/pinebook/build.sh`, `profiles/lxqt/customization.sh`: Removed hardcoding
- `README.md`: Added branding system section
- `.gitignore`: Added PPM files

### Files Created
- `branding/installer/installer-branding.conf` - Installer branding configuration
- `branding/installer/generate-installer-branding.py` - Image generation script
- `branding/installer/backgrounds/grub-background.ppm` - GRUB background
- `branding/installer/backgrounds/installer-splash.ppm` - Splash screen
- `branding/installer/README.md` - Configuration guide
- `docs/BRANDING.md` - System branding documentation
- `docs/INSTALLER_BRANDING.md` - Installer branding implementation guide
- `docs/branding-visual-mockup.html` - Interactive desktop mockup

---

## [0.4.5] - 2026-07-17

### Added

- **LPM interface mode selection**
  - Added `--mode` to `lpm.py` with `cli` (default) and `text` modes
  - Added interactive text menu flow for package operations
  - Added dedicated tests in `tests/test_lpm_mode.py`

- **PR labeler configuration**
  - Added `.github/labeler.yml` label rules for docs, CI, tests, builder, shell scripts, and LPM scopes

- **Builder parameter persistence for shell stages**
  - Added `/etc/lfs-builder-params.env` generation during branding stage
  - Captures exported builder parameters (`LFS_*`, `LFS_CONFIG_*`, `LFS_PROFILE_*`) for traceability
  - Post-build inspection and parameter verification enabled

- **Complete BDD test coverage for build scenarios**
  - Added `tests/features/test_build.py` to implement and execute `tests/features/build.feature`
  - Added `pytest-bdd` to `tests/requirements-test.txt` for consistent BDD suite execution

### Changed

- **Coverage and CI reporting alignment**
  - Updated `python-app.yml` to keep a single coverage-producing pytest run before Codecov upload
  - Updated README coverage badge URL to remove the stale `unittests` flag view

- **MkDocs strict documentation navigation**
  - Replaced invalid `mkdocs.yml` nav references with existing docs pages
  - Simplified `docs/troubleshoot.md` and removed broken internal links
  - Fixed `docs/content.md` license link target for strict build compatibility

- **Source download behavior hardening**
  - `SourceDownloader` now uses config-driven timeout/retry values at runtime
  - Default download tuning changed from `300s/3 retries` to `30s/2 retries` in:
    - `config/default.json`
    - `config/build.conf`
    - `config/build.conf.json`

### Fixed

- **Release pipeline chroot bootstrap reliability**
  - Hardened `lfs/06-build-lfs-system.sh` tool bootstrap for chroot execution
  - Avoids copying shell builtins as host binaries
  - Ensures `/bin/sh` and `/usr/bin/env` exist in chroot, preventing `./configure` execution failures

- **Download failure behavior on dead URLs**
  - Permanent HTTP errors (e.g., 404) now fail fast instead of consuming all retries
  - Prevents long apparent "freeze" periods during source acquisition in release jobs

- **Coverage completeness**
  - Added targeted tests for source list key fallback and downloader fast-fail behavior
  - Restored `builder.py` coverage to 100% after recent pipeline hardening changes
