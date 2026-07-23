# LFS/BLFS Package & Kernel Upgrade Implementation Plan

**Created:** 2026-07-23  
**Current LFS/BLFS Version:** 13.0 (last updated 2025-01-15)  
**Current Project Version:** 0.25.2

---

## Executive Summary

The beyond-linux-from-scratch project currently ships with LFS/BLFS 13.0 packages from January 2025. This plan upgrades to **LFS/BLFS 14.0 (2026)** with the latest stable kernel and security updates to modernize the distribution while maintaining stability.

**Key Goals:**
- Upgrade Linux kernel from 6.12.20 → **6.13.x** (latest stable)
- Upgrade core toolchain (GCC, Binutils, Glibc) to latest LFS 14.0 standards
- Update BLFS packages (X11, Mesa, GTK, OpenSSL, etc.) to 2026 versions
- Maintain full test coverage (100%) throughout migrations
- Zero security vulnerabilities in critical packages

---

## Phase 1: Research & Validation (Week 1)

### 1.1 Kernel Research
- [ ] Check latest stable Linux kernel from kernel.org
  - Current: 6.12.20 → Target: 6.13.x or 6.14.x (latest stable)
  - Verify LTS eligibility if needed (RHEL/Debian standard: 5-6 years)
  - Check security patches and CVE status
  
- [ ] Validate ARM64 compatibility
  - Test on Pinebook Pro profile (ARM64)
  - Check device tree and bootloader compatibility
  
- [ ] Review kernel config changes
  - Compare current `config/kernel-config` with upstream defaults
  - Identify breaking changes in new kernel versions
  - Document deprecated options

### 1.2 Toolchain Baseline
- [ ] Check LFS official book 14.0 recommendations
  - GCC 15.2.0 → latest (likely 15.3.x or 16.x)
  - Binutils 2.46.0 → latest (likely 2.47.x)
  - Glibc 2.43 → latest (likely 2.44.x)

- [ ] Cross-reference with BLFS 14.0 released packages
- [ ] Create version compatibility matrix

### 1.3 Dependency Analysis
- [ ] Build dependency graph for core packages
- [ ] Identify conflicting version requirements
- [ ] Document breaking changes in APIs (OpenSSL, GTK, Mesa)

**Deliverable:** `upgrade-research.md` with version table and compatibility notes

---

## Phase 2: Configuration Updates (Week 2)

### 2.1 Update `config/packages.conf.json`

**LFS Core upgrades:**
```json
"linux":      "6.12.20" → "6.13.x"
"gcc":        "15.2.0"  → "16.1.0" (or latest)
"binutils":   "2.46.0"  → "2.47.0" (or latest)
"glibc":      "2.43"    → "2.44.x" (or latest)
"make":       "4.4.1"   → "4.4.3" (or latest)
"bash":       "5.3"     → "5.4" (or latest)
"python":     "3.14.3"  → "3.15.0" (or latest)
```

**BLFS Desktop upgrades:**
```json
"xorg-server": "21.1.13" → "21.2.x"
"mesa":        "24.3.4"  → "25.0.x"
"gtk":         "4.18.0"  → "4.20.x"
"glib":        "2.84.0"  → "2.85.x"
"dbus":        "1.16.2"  → "1.17.x"
"openssl":     "3.6.1"   → "3.7.x" (security critical)
"curl":        "8.16.0"  → "8.17.x"
```

**Tasks:**
- [ ] Update URLs to point to latest version mirrors
- [ ] Verify all URLs are accessible (no 404s)
- [ ] Calculate new source tarball sizes
- [ ] Update SHA256 checksums for each package
- [ ] Update `last_updated` timestamp
- [ ] Test package config JSON is valid

**Deliverable:** Updated `config/packages.conf.json` with all URLs/checksums

### 2.2 Update Kernel Configs
- [ ] Update `config/kernel-config` (x86_64) with new defaults
  - Extract from `make defconfig` for kernel 6.13
  - Apply security hardening patches
  - Verify CONFIG_* options still valid
  
- [ ] Update `config/kernel-config-arm64` for ARM64 (Pinebook)
- [ ] Update `config/kernel-config-pinebook` with device-specific options

**Deliverable:** 3 updated kernel config files with changelog comments

---

## Phase 3: Shell Script Updates (Week 2-3)

### 3.1 Build Scripts (`lfs/` directory)
- [ ] `01-host-check.sh`: Verify new GCC/Binutils compatibility requirements
- [ ] `02-host-prepare.sh`: Update temporary toolchain versions
- [ ] `03-lfs-prepare.sh`: Update LFS source preparation
- [ ] `04-build-toolchain.sh`: **CRITICAL** — update cross-compile toolchain
  - GCC bootstrap flags may change
  - Binutils options validation
  - Test on CI (Linux) and locally (macOS cross-compile simulation)

- [ ] `05-build-chroot-system.sh`: Update glibc/bash/coreutils versions
- [ ] `06-build-lfs-system.sh`: Update in-chroot compilation steps
- [ ] `07-finalize.sh`: Update kernel installation for new version

### 3.2 BLFS Scripts (`blfs/` directory)
- [ ] `01-desktop-base.sh`: X11/Mesa/GTK updates
- [ ] `02-xfce-desktop.sh`: Update XFCE component versions
- [ ] `03-media.sh`: Update Pipewire/ALSA versions
- [ ] `04-network.sh`: Update curl/OpenSSL integration
- [ ] `05-java-runtime.sh`: JDK compatibility checks

**Deliverable:** Updated scripts with version bumps and tested on local simulator

---

## Phase 4: Profile Updates (Week 3)

### 4.1 Default Profiles
- [ ] `profiles/default/`: Update kernel version references
- [ ] `profiles/brax3/`: ARM64 kernel + bootloader updates
- [ ] `profiles/pinebook/`: Pinebook-specific DTB/u-boot compatibility
- [ ] `profiles/lxqt/`: Light QT dependencies
- [ ] `profiles/java-dev/`: JDK + toolchain integration
- [ ] `profiles/security/`: OpenSSL/kernel security module versions

### 4.2 Customizations
- [ ] Update all `customization.sh` files with new package versions
- [ ] Verify patch applicability (may break with new upstream)

**Deliverable:** All profiles tested on at least minimal builds

---

## Phase 5: Testing & Validation (Week 4)

### 5.1 Unit Tests
- [ ] Run full pytest suite (`pytest tests/ -v --cov=builder`)
  - Target: **maintain 100% coverage**
  - Update mock data with new versions
  - No test breakage allowed
  
- [ ] ShellCheck all updated scripts (zero errors)
- [ ] YAML linting on all configs

### 5.2 Integration Tests
- [ ] **Local minimal build** on macOS (Intel + Apple Silicon cross-compile sim)
  - `./make-release.sh --profile minimal --init sysvinit`
  - Verify kernel compiles and boots (chroot simulation)
  
- [ ] **CI/CD pipeline** (GitHub Actions on Linux)
  - `./make-release.sh --profile default --desktop xfce`
  - Verify x86_64 full build with new packages
  
- [ ] **Cross-compile test** (Pinebook ARM64)
  - `./make-release.sh --profile pinebook --arch aarch64`

### 5.3 Regression Testing
- [ ] Verify existing functionality unchanged:
  - CLI flags (--profile, --init, --desktop, etc.)
  - Build caching works
  - ISO generation succeeds
  - Bootloader integration (GRUB)
  
- [ ] Compare build output vs previous version
  - Similar binary sizes
  - Similar build times
  - Same filesystem structure

**Deliverable:** Test report with 100% pass rate

---

## Phase 6: Documentation & Release (Week 4-5)

### 6.1 Documentation Updates
- [ ] Update `README.md` with new version numbers
- [ ] Add "Upgrade Guide" for users on 0.25.x
- [ ] Update `CHANGELOG.md` with breaking changes (if any)
- [ ] Update package version tables in `docs/`

### 6.2 Kernel Documentation
- [ ] Document new kernel config options
- [ ] Security hardening notes (if changed)
- [ ] Performance improvements (if any)

### 6.3 Release Candidate
- [ ] Tag `v0.26.0-rc1` on GitHub
- [ ] Perform manual acceptance tests
- [ ] Collect feedback (48-hour window)

### 6.4 Production Release
- [ ] Tag `v0.26.0` (Semantic Versioning)
- [ ] Generate release notes highlighting:
  - Kernel: 6.12.20 → 6.13.x
  - Toolchain: GCC 15.2 → 16.x (or latest)
  - Security: OpenSSL 3.6.1 → 3.7.x
  - Desktop: GTK 4.18 → 4.20 (or latest)
  - New LFS/BLFS 14.0 baseline
  
- [ ] Upload release artifacts (ISO, checksums, GPG signature)

---

## Risk Matrix & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| Kernel config not compatible | Medium | High | Keep old configs as backup, test thoroughly |
| GCC bootstrap fails | Low | Critical | Use known-good cross-compiler from LFS 13.0 first |
| OpenSSL ABI break | Low | High | Test all dependent packages (curl, web libs) |
| BLFS X11 dependencies mismatch | Medium | Medium | Test desktop build in CI before release |
| ARM64 DTB incompatible | Medium | High | Test Pinebook profile early, keep bootloader backup |
| Build time regression | Medium | Low | Monitor and optimize if needed |
| Rollback required mid-phase | Low | High | Keep git history clean, tag checkpoints |

---

## Success Criteria

✅ **Must have:**
1. All 351+ tests pass with 100% coverage
2. All shell scripts pass ShellCheck
3. Minimal build works on macOS (cross-compile sim)
4. Full XFCE desktop build works on Linux CI
5. ARM64 Pinebook build works
6. No security CVEs in critical packages
7. Release notes updated and accurate

✅ **Should have:**
1. <5% build time increase
2. No file size increase >10%
3. Backward compatibility guide written

✅ **Nice to have:**
1. Performance benchmarks
2. Before/after kernel comparison
3. User migration guide

---

## Timeline

| Phase | Duration | Owner | Status |
|-------|----------|-------|--------|
| 1: Research & Validation | 5 days | Copilot | **TODO** |
| 2: Config Updates | 5 days | Copilot | **TODO** |
| 3: Shell Scripts | 7 days | Copilot | **TODO** |
| 4: Profile Updates | 5 days | Copilot | **TODO** |
| 5: Testing & Validation | 7 days | Copilot | **TODO** |
| 6: Documentation & Release | 5 days | Copilot | **TODO** |
| **Total** | **~34 days** | | **IN PROGRESS** |

---

## Version Snapshot (Target)

```
Project Version: 0.26.0
LFS/BLFS Base:  14.0 (2026)
Kernel:         6.13.x (or latest stable)
GCC:            16.1.0 (or latest)
Binutils:       2.47.0 (or latest)
Glibc:          2.44.x (or latest)
OpenSSL:        3.7.x (or latest)
Mesa:           25.0.x (or latest)
GTK:            4.20.x (or latest)
Tested Profiles: default, minimal, xfce, pinebook, lxqt, java-dev, security
```

---

## Notes

- This plan prioritizes **stability & testing** over speed
- Each phase has clear deliverables and checkpoints
- Rollback points identified throughout
- All changes tracked in git with atomic commits
- 100% test coverage is non-negotiable
