# Changelog

All notable changes to the LFS/BLFS Builder project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

**Versioning Scheme**: 
- MAJOR (X.0.0): +1 for each new feature
- MINOR (0.Y.0): +1 for each bug fix
- PATCH (0.0.Z): +1 for minor patches

## [0.25.1] - 2026-07-20

### Added (25 features)

1. **LFS Builder Core Framework** - Foundation for building custom Linux distributions
2. **Builder Configuration System** - TOML-based configuration for build parameters
3. **Host Environment Preparation** - Verify and prepare host system for LFS builds
4. **Toolchain Stage** - GCC/binutils/glibc cross-compilation toolchain
5. **LFS System Construction** - Build complete LFS system from sources
6. **Kernel Build Integration** - Linux kernel compilation and installation
7. **BLFS Packages Integration** - Beyond LFS additional packages layer
8. **Desktop Environment Support** - XFCE, GNOME, KDE, LXQt desktop environments
9. **Live System Creation** - Generate bootable live ISO with persistence
10. **Disk Image Generation** - Create and manage virtual machine disk images
11. **Shell Script Framework** - Modular shell scripts for each build stage
12. **Error Handling & Logging** - Comprehensive logging system for troubleshooting
13. **CI/CD Integration** - GitHub Actions workflow for automated builds
14. **Multiple Profile Support** - Predefined build profiles (brax3, pinebook, lxqt, etc.)
15. **Dynamic Profile Parameters** - Profiles receive init_system and desktop via arguments
16. **Package Download System** - Automatic source package acquisition with caching
17. **Dependency Resolution** - Automatic resolution of build dependencies
18. **Build Cache System** - Persistent caching for faster rebuilds
19. **Professional Branding System - Installer** - GRUB boot menu with branded background (800x600), custom GRUB color scheme, branded ISO volume label, installer splash screen (1024x768), automatic image generation at ISO build time, zero external dependencies (PPM format)
20. **Live System Branding** - Professional desktop themes (LFS-Dark, LFS-Light), icon packs, professional wallpapers, desktop-specific customization
21. **Branding Configuration & Management** - Central TOML configuration, branding manager Python module, support for multiple presets, environment variable controls
22. **Wallpaper Generation System** - Python generator for dynamic wallpaper creation, integrated into build process with optional execution, graceful error handling
23. **Comprehensive Branding Documentation** - BRANDING.md, INSTALLER_BRANDING.md, branding-visual-mockup.html, installer-specific configuration guide
24. **Build Test Suite** - Comprehensive pytest test coverage (343 tests, 100% coverage)
25. **Production Release Support** - Release automation, version management, changelog tracking

### Fixed (1 fix)

1. **Comprehensive Shell Script Hardening and macOS Path Resolution** - Addressed 350+ shell scripting issues (SC2086 unquoted variables, SC2010/SC2012 ls patterns, SC2162/SC2046/SC2028), fixed macOS symlink path resolution (Path.absolute() instead of Path.resolve()), removed hardcoded profile parameters, added missing CI dependencies, improved download failure handling, hardened chroot bootstrap for toolchain compilation. All 29+ scripts now pass ShellCheck with zero critical issues. Enables reproducible builds across macOS and Linux environments.

### Files Created (Supporting Branding System)
- `branding/installer/installer-branding.conf` - Installer branding configuration
- `branding/installer/generate-installer-branding.py` - Image generation (PPM, zero deps)
- `branding/installer/backgrounds/grub-background.ppm` - GRUB boot menu background
- `branding/installer/backgrounds/installer-splash.ppm` - Installer splash screen
- `branding/installer/README.md` - Installer branding configuration guide
- `docs/BRANDING.md` - System branding documentation
- `docs/INSTALLER_BRANDING.md` - Installer branding details
- `docs/branding-visual-mockup.html` - Interactive desktop mockup

### Files Modified
- `builder.py`: Path resolution, absolute path handling
- `final/14-create-installer.sh`: Branding integration, GRUB configuration
- `profiles/brax3/build.sh`, `profiles/pinebook/build.sh`, `profiles/lxqt/customization.sh`
- `blfs/21-branding.sh`: Wallpaper generation integration
- `README.md`: Added branding section
- `.gitignore`: Added PPM files
- Multiple shell scripts: Hardening (350+ fixes)

---

## [0.10.1] - 2026-07-17

### Added (MAJOR: 10 new features)

#### 1. LPM Interface Mode Selection (Feature)
- Added `--mode` to `lpm.py` with `cli` (default) and `text` modes
- Added interactive text menu flow for package operations
- Added dedicated tests in `tests/test_lpm_mode.py`

#### 2. PR Labeler Configuration (Feature)
- Added `.github/labeler.yml` label rules for docs, CI, tests, builder, shell scripts, LPM

#### 3. Builder Parameter Persistence (Feature)
- Added `/etc/lfs-builder-params.env` generation during branding stage
- Captures exported builder parameters for traceability
- Post-build inspection and parameter verification

#### 4. Complete BDD Test Coverage (Feature)
- Added `tests/features/test_build.py` for `tests/features/build.feature`
- Added `pytest-bdd` to `tests/requirements-test.txt`

#### 5. Coverage and CI Reporting Alignment (Feature)
- Updated `python-app.yml` for single coverage-producing pytest run
- Updated README coverage badge URL

#### 6. MkDocs Strict Navigation (Feature)
- Replaced invalid `mkdocs.yml` nav references
- Simplified `docs/troubleshoot.md`
- Fixed `docs/content.md` license link

#### 7. Source Download Behavior Hardening (Feature)
- `SourceDownloader` now uses config-driven timeout/retry values
- Default changed from `300s/3 retries` to `30s/2 retries`

#### 8. Release Pipeline Improvements (Feature)
- Hardened chroot bootstrap for reliability
- Improved shell binary handling

#### 9. Download Error Handling (Feature)
- Permanent HTTP errors now fail fast

#### 10. Test Coverage Completeness (Feature)
- Added targeted tests for source list and downloader
- Maintained 100% builder.py coverage

### Fixed (MINOR: 1 bug fix)

#### 1. Release Pipeline Chroot Bootstrap Reliability (Fix)
- Hardened `lfs/06-build-lfs-system.sh` tool bootstrap
- Avoids copying shell builtins
- Ensures `/bin/sh` and `/usr/bin/env` exist in chroot
