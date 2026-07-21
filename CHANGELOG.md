# Changelog

All notable changes to the LFS/BLFS Builder project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] - 2026-07-20

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
