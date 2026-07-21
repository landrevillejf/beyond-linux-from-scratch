# Changelog

All notable changes to the LFS/BLFS Builder project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.0] - 2026-07-20

### Added

#### Professional Branding System (Complete Implementation)
- **Installer Branding (New Feature)**
  - GRUB boot menu with branded background gradient (800x600)
  - Custom GRUB color scheme (Forest Green primary, Light Green highlight)
  - Branded ISO volume label: `BLFS-0.5.0-LIVE`
  - Publisher metadata: `Beyond Linux From Scratch`
  - Installer splash screen (1024x768 professional gradient)
  - Automatic image generation at ISO build time
  - Zero external dependencies (PPM format, GRUB-native)
  - Automatic PNG conversion if ImageMagick/Pillow available

- **Live System Branding (Complete Implementation)**
  - Professional desktop themes (LFS-Dark, LFS-Light)
  - Icon packs (Papirus Dark/Light variants)
  - Professional wallpapers (custom or auto-generated)
  - System branding configuration files with manifest
  - Desktop-specific customization (XFCE, GNOME, KDE, LXQt)

- **Branding Configuration & Management System**
  - Central TOML configuration (`branding/branding.toml`)
  - Branding manager Python module for configuration export
  - Support for multiple branding presets (default, custom)
  - Desktop-specific theme overrides and customization
  - Environment variable controls for runtime configuration

- **Wallpaper Generation System**
  - Python generator for dynamic wallpaper creation
  - Integrated into build process with optional execution
  - Controlled via `LFS_CONFIG_BRANDING_GENERATE_WALLPAPERS` flag
  - Fallback to default wallpapers if generation fails
  - Graceful error handling (non-fatal on generation failure)

- **Updated Installer Script (final/14-create-installer.sh)**
  - Load branding configuration during ISO creation
  - Generate branded images at build time
  - Embed GRUB background in boot configuration
  - Apply branded colors to boot menu
  - Set custom ISO volume label and publisher metadata
  - Create branding manifest in ISO filesystem

- **Comprehensive Branding Documentation**
  - `docs/BRANDING.md` - Complete system branding guidelines and usage
  - `docs/INSTALLER_BRANDING.md` - Installer branding implementation details
  - `docs/branding-visual-mockup.html` - Interactive desktop environment mockup
  - `branding/installer/README.md` - Installer-specific configuration guide
  - Updated `README.md` with branding system overview
  - Updated `CHANGELOG.md` with semantic versioning

### Changed

#### Shell Script Hardening and Robustness
- **Shell script validation and fixing (Issue #35)**
  - Fixed 350+ shell scripting issues across 22 scripts for production-ready quality
  - **SC2086 (unquoted variables)**: Added proper quoting for 150+ variable instances
    - Variables like `$LFS`, `$SOURCES_HOST`, `$LFS_HOME` now safely quoted
    - Prevents word splitting and path corruption with spaces
  - **SC2010/SC2012 (unsafe ls patterns)**: Replaced unreliable `ls | grep` patterns with robust `find` commands
    - Affected: `host/04-build-toolchain.sh`, `lfs/09-build-kernel.sh`, `final/*.sh`
    - Handles filenames with special characters correctly
  - **SC2162 (read without -r)**: Added `-r` flag to `read` commands to preserve backslashes
  - **SC2046 (unquoted command substitution)**: Quoted command substitutions to prevent word splitting
  - **SC2028 (echo vs printf)**: Replaced `echo` with `printf` for binary data handling
  - **Sudo hardening**: Added `-n` (non-interactive) flag to prevent CI/CD password prompts
  - All 29+ scripts now pass ShellCheck with zero critical issues
  - All scripts validated with `bash -n` syntax check

#### Profile Parameter Architecture
- **Removed hardcoded init and desktop parameters from profiles**
  - Removed hardcoded `--init systemd` from `profiles/brax3/build.sh`
  - Removed hardcoded `--init sysvinit` from `profiles/pinebook/build.sh`
  - Removed hardcoded `--desktop pcmanfm-qt` from `profiles/lxqt/customization.sh`
  - Profiles now receive init_system and desktop via CLI arguments from builder
  - Enables flexible profile reuse with different configurations
  - Builder collects parameters dynamically (not hardcoded)

#### Path Resolution and Build System
- **LFS Path Resolution (macOS Compatibility)**
  - Changed `Path.resolve()` to `Path.absolute()` in `builder.py` line 1010
  - Handles macOS symlink behavior consistently
  - Prevents `/private/` prefix injection from resolve()
  - Maintains absolute path requirement for autotools compatibility

- **Release Pipeline Dependencies**
  - Added missing build dependencies to `.github/workflows/release.yml`
  - `libgmp-dev`, `libmpfr-dev`, `libmpc-dev` required for GCC compilation
  - Fixes "Building GCC requires GMP/MPFR/MPC" errors in CI

### Fixed

#### Critical Build System Issues
- **LFS absolute path requirement (Critical)**
  - Configure scripts require absolute paths for `--prefix` argument
  - LFS environment variable now properly uses absolute paths
  - Fixes: "configure: error: expected an absolute directory name for --prefix"
  - Autotools now finds all prerequisites during compilation

- **LFS directory structure alignment (Critical)**
  - Fixed "Source for binutils not found" error at build stage 4
  - LFS now correctly points to output_dir (not output_dir/image)
  - Ensures `$LFS/sources` resolves to the actual sources directory
  - Scripts now find all downloaded packages as expected
  - CI builds can now complete the toolchain stage successfully

#### Build Pipeline and Dependencies
- **Download failure behavior on dead URLs**
  - Permanent HTTP errors (e.g., 404) now fail fast instead of consuming all retries
  - Prevents long apparent "freeze" periods during source acquisition in release jobs

- **Release pipeline chroot bootstrap reliability**
  - Hardened `lfs/06-build-lfs-system.sh` tool bootstrap for chroot execution
  - Avoids copying shell builtins as host binaries
  - Ensures `/bin/sh` and `/usr/bin/env` exist in chroot
  - Prevents `./configure` execution failures in chroot environment

#### Test Coverage and Validation
- **Coverage completeness**
  - Added targeted tests for source list key fallback and downloader fast-fail behavior
  - Maintained `builder.py` coverage at 100% after recent pipeline hardening changes
  - All 343 tests passing with 100% code coverage

### Files Modified
- `builder.py`: Corrected SourceDownloader initialization, absolute path handling, path resolution
- `.github/workflows/release.yml`: Updated directory creation, cache paths, build dependencies
- `final/14-create-installer.sh`: Added branding integration, GRUB configuration, ISO customization
- `profiles/brax3/build.sh`: Removed hardcoded init parameter
- `profiles/pinebook/build.sh`: Removed hardcoded init parameter
- `profiles/lxqt/customization.sh`: Removed hardcoded desktop parameter
- `blfs/21-branding.sh`: Integration of wallpaper generation and branding application
- `.gitignore`: Added PPM files (auto-generated large images)
- `README.md`: Added branding system section with documentation links
- Multiple shell scripts in `host/`, `lfs/`, and `blfs/` directories: Shell script hardening

### Files Created
- `branding/installer/installer-branding.conf` - Installer branding configuration
- `branding/installer/generate-installer-branding.py` - Image generation script (PPM format, zero deps)
- `branding/installer/backgrounds/grub-background.ppm` - GRUB boot menu background
- `branding/installer/backgrounds/installer-splash.ppm` - Installer splash screen
- `branding/installer/README.md` - Installer branding configuration guide
- `docs/BRANDING.md` - Comprehensive system branding documentation
- `docs/INSTALLER_BRANDING.md` - Installer branding implementation details and guide
- `docs/branding-visual-mockup.html` - Interactive desktop environment mockup

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
