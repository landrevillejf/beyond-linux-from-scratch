# Changelog

All notable changes to the LFS/BLFS Builder project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

**Versioning Scheme**: 
- MAJOR (X.0.0): +1 for each new feature
- MINOR (0.Y.0): +1 for each bug fix
- PATCH (0.0.Z): +1 for minor patches

## [0.1.0] - 2026-07-17

### Added
- LFS Builder Core Framework - Foundation for building custom Linux distributions

## [0.2.0] - 2026-07-17

### Added
- Builder Configuration System - TOML-based configuration for build parameters

## [0.3.0] - 2026-07-17

### Added
- Host Environment Preparation - Verify and prepare host system for LFS builds

## [0.4.0] - 2026-07-17

### Added
- Toolchain Stage - GCC/binutils/glibc cross-compilation toolchain

### Fixed
- Shell script robustness and portability - Fixed 350+ shell scripting issues (SC2086, SC2010/SC2012, SC2162, SC2046, SC2028)

## [0.5.0] - 2026-07-17

### Added
- LFS System Construction - Build complete LFS system from sources

## [0.6.0] - 2026-07-17

### Added
- Kernel Build Integration - Linux kernel compilation and installation

## [0.7.0] - 2026-07-17

### Added
- BLFS Packages Integration - Beyond LFS additional packages layer

## [0.8.0] - 2026-07-17

### Added
- Desktop Environment Support - XFCE, GNOME, KDE, LXQt desktop environments

## [0.9.0] - 2026-07-17

### Added
- Live System Creation - Generate bootable live ISO with persistence

## [0.10.0] - 2026-07-17

### Added
- Disk Image Generation - Create and manage virtual machine disk images

### Fixed
- LFS directory structure alignment - Fixed source verification and toolchain stage failures

## [0.11.0] - 2026-07-17

### Added
- Shell Script Framework - Modular shell scripts for each build stage

## [0.12.0] - 2026-07-17

### Added
- Error Handling & Logging - Comprehensive logging system for troubleshooting

## [0.13.0] - 2026-07-17

### Added
- CI/CD Integration - GitHub Actions workflow for automated builds

## [0.14.0] - 2026-07-17

### Added
- Multiple Profile Support - Predefined build profiles (brax3, pinebook, lxqt, etc.)

## [0.15.0] - 2026-07-17

### Added
- Dynamic Profile Parameters - Profiles receive init_system and desktop via arguments

### Fixed
- Profile parameter hardcoding - Removed hardcoded values from profile scripts

## [0.16.0] - 2026-07-17

### Added
- Package Download System - Automatic source package acquisition with caching

## [0.17.0] - 2026-07-17

### Added
- Dependency Resolution - Automatic resolution of build dependencies

## [0.18.0] - 2026-07-17

### Added
- Build Cache System - Persistent caching for faster rebuilds

## [0.19.0] - 2026-07-18

### Added
- Professional Branding System - Installer branding with GRUB boot menu, branded background (800x600), custom GRUB color scheme, branded ISO volume label, installer splash screen (1024x768)

## [0.20.0] - 2026-07-20

### Added
- Live System Branding - Professional desktop themes (LFS-Dark, LFS-Light), icon packs, professional wallpapers, desktop-specific customization (XFCE, GNOME, KDE, LXQt)

## [0.21.0] - 2026-07-20

### Added
- Branding Configuration & Management - Central TOML configuration, branding manager Python module, support for multiple presets, environment variable controls

## [0.22.0] - 2026-07-20

### Added
- Wallpaper Generation System - Python generator for dynamic wallpaper creation, integrated into build process with optional execution, graceful error handling

## [0.23.0] - 2026-07-20

### Added
- Comprehensive Branding Documentation - BRANDING.md, INSTALLER_BRANDING.md, branding-visual-mockup.html, installer configuration guide, README updates

## [0.24.0] - 2026-07-20

### Added
- Build Test Suite - Comprehensive pytest test coverage (343 tests, 100% coverage)

## [0.25.0] - 2026-07-20

### Added
- Production Release Support - Release automation, version management, changelog tracking

## [0.1.1] - 2026-07-18

### Fixed
- Create build-release/sources directory before cache restore in CI workflow

## [0.2.1] - 2026-07-18

### Fixed
- Replace ls glob check with find in source verification

## [0.3.1] - 2026-07-18

### Fixed
- Correct source download path to match LFS directory structure

## [0.4.1] - 2026-07-18

### Fixed
- Align LFS directory structure with sources location - Fixed "Source for binutils not found" error

## [0.5.1] - 2026-07-18

### Fixed
- Convert LFS path to absolute path - Fixed autotools "expected an absolute directory name for --prefix" error

## [0.6.1] - 2026-07-18

### Fixed
- macOS Path Resolution - Changed Path.resolve() to Path.absolute() for macOS symlink compatibility

## [0.7.1] - 2026-07-20

### Fixed
- Add missing build dependencies for GCC (libgmp-dev, libmpfr-dev, libmpc-dev)

## [0.8.1] - 2026-07-20

### Fixed
- Fix GCC pass 1 build: embed GMP, MPFR, MPC sources in GCC source tree

## [0.9.1] - 2026-07-20

### Fixed
- Install Linux API headers to $LFS/usr/include for glibc configure

## [0.10.1] - 2026-07-20

### Fixed
- Ensure toolchain stage uses $LFS cross compiler path

## [0.11.1] - 2026-07-20

### Fixed
- Harden lfs env generation for toolchain path resolution

## [0.12.1] - 2026-07-20

### Fixed
- Fix glibc cross-compile configure to resolve GCC_NO_EXECUTABLES error

## [0.13.1] - 2026-07-20

### Fixed
- Use cross-prefixed binary names in check_toolchain verification

## Summary

**Version 0.25.1** cumulative totals:
- 25 features implemented (0.1.0 through 0.25.0)
- 13 bug fixes applied (0.*.1 versions)
- Total: 25 MAJOR + 13 MINOR = v0.25.13

Semantic versioning progression:
- v0.4.5 (previous): 4 features + 5 fixes
- v0.25.1 (this release): 25 features + 13 fixes (total cumulative)
