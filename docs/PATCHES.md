# Custom Patches and Modifications

This document lists every patch and inline modification applied by the
build scripts, with book references and justifications.  Per AGENTS.md
rule 15, all deviations from the standard LFS/BLFS book instructions
are documented here.

Patches are grouped by origin: LFS book patches, BLFS book patches,
and inline modifications (sed commands that alter source behaviour).

---

## LFS book patches

These patches are published by the LFS project at
`https://www.linuxfromscratch.org/patches/lfs/12.4/` and are applied
in `lfs/05b-build-lfs-system.sh`.

| Patch | Book section | Purpose |
|---|---|---|
| `glibc-2.42-fhs-1.patch` | LFS 12.4 Section 8.14 | FHS compliance: adjusts glibc install paths to match the Filesystem Hierarchy Standard. |
| `bzip2-1.0.8-install_docs-1.patch` | LFS 12.4 Section 8.7 | Documentation install path fix: installs bzip2 docs to the correct location. |
| `expect-5.45.4-gcc15-1.patch` | LFS 12.4 Section 8.17 | GCC 15 compatibility: fixes build failures with the GCC 15 toolchain. |
| `coreutils-9.7-upstream_fix-1.patch` | LFS 12.4 Section 8.21 | Upstream bug fixes pulled from the coreutils git tree. |
| `coreutils-9.7-i18n-1.patch` | LFS 12.4 Section 8.21 | Internationalization fixes for proper locale handling. |
| `kbd-2.8.0-backspace-1.patch` | LFS 12.4 Section 8.26 | Optional backspace key mapping fix for backward compatibility with terminals that send DEL instead of Backspace. |
| `sysvinit-3.14-consolidated-1.patch` | LFS 12.4 Section 8.45 | Consolidated sysvinit improvements and BLFS compatibility fixes. |

All seven are applied unconditionally when the matching package is built.

---

## BLFS book patches

These patches are published by the BLFS project at
`https://www.linuxfromscratch.org/patches/blfs/12.4/` and are applied
in the various `blfs/*.sh` stage scripts.

| Patch | Applied in | Purpose |
|---|---|---|
| `libtirpc-1.3.6-gcc15_fixes-1.patch` | `blfs/08b-build-xorg.sh`, `blfs/23-basic-networking.sh` | GCC 15 compatibility for libtirpc. |
| `xorg-server-21.1.18-tearfree_backport-1.patch` | `blfs/08b-build-xorg.sh` | Backports the TearFree option to the modesetting driver. Optional in the book; applied only when present in `/sources`. |
| `glib-skip_warnings-1.patch` | `blfs/08a-build-blfs-libs.sh` | Suppresses non-critical glib deprecation warnings during the build. |
| `nss-standalone-1.patch` | `blfs/08a-build-blfs-libs.sh` | Allows NSS to build as a standalone package outside the Mozilla tree. |

---

## BLFS upstream-fix patches (applied via glob)

The BLFS stage scripts apply book-recommended upstream fix patches
via glob patterns (`for p in ../$pkg-*-<name>-*.patch`).  Each glob
matches zero or more patches in `/sources`; if none are present the
loop body is skipped.  These patches come from the BLFS wget-list and
are authored by the BLFS project or upstream.

| Glob pattern | Applied in | Purpose |
|---|---|---|
| `libpng-*-apng.patch.gz` | `blfs/08a-build-blfs-libs.sh` | APNG (Animated PNG) support for libpng. |
| `giflib-*-upstream_fixes-*.patch` | `blfs/08a-build-blfs-libs.sh` | Upstream bug fixes for giflib. |
| `giflib-*-security_fixes-*.patch` | `blfs/08a-build-blfs-libs.sh` | Security fixes for giflib. |
| `mesa-add_xdemos-*.patch` | `blfs/08b-build-xorg.sh` | Adds X demo programs to the Mesa build. |
| `extra-cmake-modules-*-upstream_fix-*.patch` | `blfs/09c-build-kde.sh`, `blfs/29-build-calamares.sh` | Upstream fixes for KDE extra-cmake-modules. |
| `konsole-adjust_scrollbar-*.patch` | `blfs/09c-build-kde.sh` | Scrollbar appearance adjustment for Konsole. |
| `openbox-*-py3-*.patch` | `blfs/09d-build-lxqt.sh` | Python 3 compatibility for Openbox scripts. |
| `wireless_tools-*-fix_iwlist_scanning-*.patch` | `blfs/23-basic-networking.sh` | Fixes iwlist scanning output for wireless tools. |
| `ffmpeg-*-chromium_method-*.patch` | `blfs/24-multimedia.sh` | Chromium-compatible build method for FFmpeg. |
| `vlc-*-taglib-*.patch` | `blfs/24-multimedia.sh` | TagLib metadata support fix for VLC. |
| `vlc-*-fedora_ffmpeg7-*.patch` | `blfs/24-multimedia.sh` | FFmpeg 7 compatibility for VLC (Fedora patch). |
| `httpd-blfs_layout-*.patch` | `blfs/25-server.sh` | BLFS-specific directory layout for Apache httpd. |
| `httpd-*-blfs_layout-*.patch` | `blfs/25-server.sh` | BLFS-specific directory layout for Apache httpd (versioned variant). |
| `cyrus-sasl-*-gcc15_fixes-*.patch` | `blfs/25-server.sh` | GCC 15 compatibility for Cyrus SASL. |
| `openldap-*-consolidated-*.patch` | `blfs/25-server.sh` | Consolidated fixes for OpenLDAP. |
| `ghostscript-*-gcc15_fixes-*.patch` | `blfs/26-printing-scanning.sh` | GCC 15 compatibility for Ghostscript. |
| `gptfdisk-*-convenience-*.patch` | `blfs/29-build-calamares.sh` | Convenience build fixes for gptfdisk. |
| `gptfdisk-convenience-*.patch` | `blfs/29-build-calamares.sh` | Convenience build fixes for gptfdisk (unversioned variant). |

---

## Inline modifications (sed commands)

These are source-tree modifications applied via `sed` rather than
patch files.  Each is documented with its justification.

### glibc -- Valgrind BLFS compatibility

**File:** `lfs/05b-build-lfs-system.sh` (glibc build)

```bash
sed -e '/unistd.h/i #include <string.h>' \
    -e '/libc_rwlock_init/c\
  __libc_rwlock_define_initialized (, reset_lock);\
  memcpy (&lock, &reset_lock, sizeof (lock));' \
    -i stdlib/abort.c
```

**Justification:** Not in the LFS book.  Required for BLFS Valgrind
compatibility -- without the `<string.h>` include and the lock
initialisation fix, Valgrind aborts when instrumenting glibc.

### Shadow -- YESCRYPT encryption method

**File:** `lfs/05b-build-lfs-system.sh` (shadow build)

```bash
sed -e 's:#ENCRYPT_METHOD DES:ENCRYPT_METHOD YESCRYPT:' \
    -i etc/login.defs
```

**Justification:** Upgrades the default password hashing from DES
(insecure, legacy) to YESCRYPT (modern, recommended by the book).

### Coreutils -- XOPEN source guard

**File:** `lfs/05b-build-lfs-system.sh` (coreutils build)

```bash
sed -e 's/^#if.*XOPEN.*$/#if 1/' \
    -i lib/strtod.c
```

**Justification:** Forces the strtod implementation to use the
full-featured code path regardless of the `_XOPEN_SOURCE` define,
ensuring correct locale-aware parsing.

### Udev -- group and rule adjustments

**File:** `lfs/05b-build-lfs-system.sh` (udev build)

```bash
sed -e 's/GROUP="render"/GROUP="video"/' \
    -e 's/GROUP="sgx", //' \
    -i rules.d/50-udev-default.rules.in
sed -i '/systemd-sysctl/s/^/#/' rules.d/99-systemd.rules.in
```

**Justification:** Adjusts device group ownership for the LFS
environment (render -> video, removes sgx) and disables the
systemd-sysctl rule that conflicts with the standalone udev build.

### Readline -- shared library fixes

**File:** `lfs/05b-build-lfs-system.sh` (readline build)

```bash
sed -i '/MV.*old/d' Makefile.in
sed -i '/{OLDSUFF}/c:' support/shlib-install
sed -i 's/-Wl,-rpath,[^ ]*//' support/shobj-conf
```

**Justification:** Prevents old shared library versions from being
renamed with a `.old` suffix (which would leave stale files) and
removes rpath hardcoding that would point at the build-time path.

### Texinfo -- Perl compatibility fix

**File:** `lfs/05b-build-lfs-system.sh` (texinfo build)

```bash
sed 's/! $output_file eq/$output_file ne/' -i tp/Texinfo/Convert/*.pm
```

**Justification:** Fixes a Perl syntax issue in the Texinfo converter
modules (`! ... eq` -> `ne`) that causes warnings with modern Perl.

### Iproute2 -- remove arpd

**File:** `lfs/05b-build-lfs-system.sh` (iproute2 build)

```bash
sed -i /ARPD/d Makefile
rm -fv man/man8/arpd.8
```

**Justification:** Removes the arpd daemon from the build; it depends
on Berkeley DB which is not installed in the base LFS system.

### Gawk -- skip extras

**File:** `lfs/05b-build-lfs-system.sh` (gawk build)

```bash
sed -i 's/extras//' Makefile.in
```

**Justification:** Skips building the `extras` directory which
contains non-essential extensions that may fail without optional
dependencies.

---

## Patch source URLs

All LFS and BLFS patches are downloaded from the official project
servers and listed in `packages/custom-sources.list`:

```
https://www.linuxfromscratch.org/patches/lfs/12.4/bzip2-1.0.8-install_docs-1.patch
https://www.linuxfromscratch.org/patches/lfs/12.4/coreutils-9.7-upstream_fix-1.patch
https://www.linuxfromscratch.org/patches/lfs/12.4/coreutils-9.7-i18n-1.patch
https://www.linuxfromscratch.org/patches/lfs/12.4/expect-5.45.4-gcc15-1.patch
https://www.linuxfromscratch.org/patches/lfs/12.4/glibc-2.42-fhs-1.patch
https://www.linuxfromscratch.org/patches/lfs/12.4/kbd-2.8.0-backspace-1.patch
https://www.linuxfromscratch.org/patches/lfs/12.4/sysvinit-3.14-consolidated-1.patch
https://www.linuxfromscratch.org/patches/blfs/12.4/libtirpc-1.3.6-gcc15_fixes-1.patch
https://www.linuxfromscratch.org/patches/blfs/12.4/xorg-server-21.1.18-tearfree_backport-1.patch
```

---

## Maintenance notes

- When the LFS or BLFS book releases a new patch level, update the
  version numbers in this document and in `packages/custom-sources.list`.
- New patches should be added to the appropriate section above with
  their book reference and justification.
- Patches that are accepted upstream should be noted as such and
  removed from the build scripts at the next version bump.
- The glob-based patches in BLFS stages are self-maintaining: they
  apply only when the matching file is present in `/sources`, so a
  book update that drops a patch simply results in the glob matching
  nothing.

---

**Last updated:** November 7, 2026, EST  
**Book versions:** LFS 12.4, BLFS 13.0
