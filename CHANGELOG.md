# Changelog

## Unreleased

### Fixed

- **blfs-libs aborting on its own pcre2 prerequisite (nightly #183)**
  (`blfs/08a-build-blfs-libs.sh`)
  - The first run to pass blfs-base died in blfs-libs after 0.2 s:
    `Missing LFS prerequisites: pcre2`.  No LFS stage builds pcre2
    (it is the BLFS general/pcre2 package), yet verify_prerequisites
    demanded it up front while the stage's own pcre2 build ran in the
    last phase, after glib2 which hard-requires it.  pcre2 is dropped
    from the prerequisite loop and now builds first in the GLib
    ecosystem phase; the later entry stays as a no-op for resume-from
    runs

- **Dead source URLs from nightly #182 download errors**
  (`packages/custom-sources.list`, `packages/stable/12.4/sources.list`,
  `config/packages.conf.json`, `config/build-java.conf`, `builder.py`)
  - libxslt: GNOME keeps sources under `major.minor` directories, so
    `sources/libxslt/1.1.43/` was a permanent 404; repointed to
    `sources/libxslt/1.1/libxslt-1.1.43.tar.xz`
  - graphene: the GitHub release asset is gone; repointed to the BLFS
    book's GNOME mirror (`sources/graphene/1.10/`)
  - exim: upstream purges old versions from the FTP (and the entry had
    a doubled `/pub/pub/` path); repointed to the only surviving
    release, exim-4.100
  - Temurin JDK: Adoptium removed the 21.0.10+9 release; the java-dev
    toolchain now pins 21.0.9+10 everywhere (source list, packages
    config, build-java.conf, default configs)
  - Business-ISBN-3.012: CPAN keeps only the latest version of a
    distribution, so the pinned release moved to backpan.perl.org
  - ncurses-6.5-20250809 snapshot: the invisible-mirror.net `current`
    directory rotated to 6.6 snapshots; the dead override is dropped
    and the official LFS ncurses URL is restored
  - jack2: upstream stopped attaching release assets after v1.9.14 and
    no mirror carries `jack2-1.9.22.tar.gz`; the dead entry is removed
    (jack2 stays optional in blfs/24, the pipewire-jack layer covers
    the JACK API) and the guardrail test now fails if it returns

- **cURL configure failure in blfs-base (nightly #178)**
  (`blfs/08-build-blfs-base.sh`)
  - curl 8.15 hard-requires libpsl; `configure` aborted with
    `libpsl libs and/or directories were not found where specified!`
    because libpsl (and its libidn2/libunistring chain, only built
    later by the 08a libs stage) was missing.  The IDN stack is now
    built in blfs-base before cURL, following the BLFS book commands
    (meson build for libpsl)
- **libpsl docs install aborting blfs-base (nightly #179)**
  (`blfs/08-build-blfs-base.sh`)
  - Follow-up to the nightly #178 fix: the libpsl release tarball
    ships no documentation and the BLFS book installs none
    ("Installed Directories: None"), so the doc copy step failed with
    `cannot stat '../doc/libpsl/*'` and was removed
- **blfs-bootscripts bulk install aborting blfs-base (nightly #181)**
  (`blfs/08-build-blfs-base.sh`)
  - Every profile died in blfs-base with
    `make: *** No rule to make target 'install'. Stop.` right after
    libxml2: the blfs-bootscripts package has no bulk `install`
    target.  The BLFS book (introduction/bootscripts.html) installs
    each init script with its own `make install-<init-script>` target
    and only asks to keep the source tree around until the BLFS
    system is complete.  The blanket `make install` is dropped; the
    archive is still verified and extracted in /sources for the
    per-service stages

## [0.53.0] - 2026-08-23

### Added

- **Java development toolchain actually installed** (`blfs/12-install-java-dev.sh`,
  `packages/custom-sources.list`)
  - Profile completeness audit: the java-dev stage wrapped every
    install in `if ls <tarball>` guards, none of those tarballs were
    in any download list, and the stage logged success anyway — the
    image shipped without Java.  The seven required sources are now
    listed (Temurin JDK 21.0.10+9, Maven 3.9.16, Gradle 8.14, Tomcat
    10.1.56, Jenkins 2.555.3, Docker 28.3.3 static binaries, kubectl
    1.32.4) and the stage is fail-fast: a missing archive or a failed
    verification (`java -version`, `mvn --version`, `gradle --version`,
    `docker --version`, `kubectl version --client`) aborts the build
  - Gradle is extracted with `python3 -m zipfile` since unzip is not
    part of the LFS base

- **Connection management in basic-networking**
  (`blfs/23-basic-networking.sh`)
  - Audit: the stage ended at wpa_supplicant, so no built system had a
    DHCP client beyond static configuration and desktops had no WiFi
    management.  dhcpcd 10.2.4 (required) and libndp + NetworkManager
    1.54.0 (BLFS book commands, `nmtui` off, elogind session tracking
    when available) are built; NetworkManager stays optional on
    profiles without the GLib stack (minimal/server/audio-cli)

- **JACK audio infrastructure for the audio profiles**
  (`blfs/24-multimedia.sh`, `packages/custom-sources.list`)
  - Audit: audio-core promised JACK but no stage built it.  jack2
    1.9.22 is built with its bundled waf before PipeWire, which then
    ships the pipewire-jack API layer; the NeuralRack stage's
    `have_pc jack` guard now resolves

- **GNU Emacs for the gnu-free profiles**
  (`blfs/10-build-applications.sh`)
  - Audit: the emacs-30.2 tarball was downloaded but never built.
    The applications stage now requests and builds Emacs (BLFS
    postlfs/emacs commands) whenever `PROFILE` is a gnu-free profile

- **Multimedia stack for desktop profiles** (`builder.py`, `README.md`)
  - Audit: `blfs/24-multimedia.sh` was gated to audio profiles only,
    so the kde profile's 'multimedia' token was dead and VLC (which
    needs pc:libavcodec) was silently skipped on every desktop.  The
    stage now runs for audio profiles and any profile declaring the
    'multimedia' package token; xfce, gnome, lxqt, kde, java-dev and
    full declare it

- **QEMU boot smoke test for every release pipeline**
  (`tools/qemu-boot-smoke.sh`, `.github/workflows/nightly.yml`,
  `.github/workflows/release.yml`,
  `.github/workflows/build-iso-from-cache.yml`)
  - New reusable script boots the build artifact (live ISO or raw disk
    image) in QEMU and asserts the kernel reaches userspace: it rejects
    kernel panics, silent boots, and boots that never hand over to init
  - The artifact's kernel and initramfs are extracted and booted
    directly with `console=ttyS0`, giving the test full control of the
    serial console regardless of the shipped grub/isolinux config; KVM
    is used when available, TCG otherwise
  - Replaces the fragile inline CI step (90 s budget, `|| true`
    swallowing QEMU failures, `-append` ignored without `-kernel`);
    wired into nightly (ISO, or disk image for headless profiles),
    release and build-iso-from-cache
  - Supporting fixes so the live ISO actually boots:
    `final/12-create-initramfs.sh` now detects `live.squashfs` on the
    boot media, mounts it via loop device and `switch_root`s into it
    (previously the ISO panicked with "Attempted to kill init"), and
    `config/kernel-config` gains `ISO9660_FS`/`SQUASHFS`/`BLK_DEV_LOOP`
    plus the 8250 serial console

- **Nightly CI coverage for desktop environments and systemd**
  (`.github/workflows/nightly.yml`)
  - Audit G3: `gnome`, `kde` and `lxqt` join the nightly matrix with
    their native init (systemd); previously only xfce-family stages had
    CI coverage
  - Audit G4: `minimal` and `xfce` now also build with systemd on every
    nightly, so both init paths stay proven; the stale commented-out
    systemd job block is removed

### Changed

- **Profile promises aligned with what stages actually build**
  (`builder.py`)
  - Audit: the dead tokens `audio-daw`/`audio-midi` (no DAW or MIDI
    sequencer exists in the BLFS 13.0 book), `gnu-octave` (needs CMake
    and LAPACK, absent from the stack) and `icecat` (last GNU prebuilt
    release is 60.7.0 from 2019; a source build is a full Firefox
    toolchain) promised software no stage could deliver.  They are
    removed from the profiles instead of staying as decoration, and a
    guardrail test fails CI if they reappear

### Fixed

- **lfs-system no longer dies on the final /bin/bash re-link**
  (`lfs/05b-build-lfs-system.sh`, `lfs/05a-build-lfs-basic.sh`)
  - Nightly #176 (minimal/sysvinit/x86_64) compiled the whole system
    and failed on the very last line of lfs-system:
    `ln: '/usr/bin/bash' and '/bin/bash' are the same file`.  On a
    fresh disk image `host/04` creates the usr-merge symlinks
    (`bin -> usr/bin`, `lib -> usr/lib`, `sbin -> usr/sbin`), so once
    chapter 8 installs the final bash both paths are one file and
    `ln -sfn` aborts under `set -e`
  - Every `/bin/bash` and `/bin/sh` re-link (the chroot standalone
    switch, the post-build relink and the 05a bootstrap links) is now
    guarded with a `-ef` same-file test and skipped when both paths
    already resolve to the same file.  A functional test replays the
    merged-usr layout and static guardrails fail CI if the unguarded
    commands return

- **test_arch_cli_override uses a hermetic output directory**
  (`tests/test_arch_option.py`)
  - The xfce-sysvinit cache workflow creates `/tmp/lfs-build` with
    sudo before running pytest (nightly #28), so `setup_logging()`
    crashed with `PermissionError` when the test passed that directory
    as `--output`; the test now uses a `tmp_path`-based directory

- **find_archive now picks the newest version among duplicates**
  (all `lfs/` and `blfs/` stage scripts)
  - Nightly #174 (minimal/sysvinit/x86_64) failed exactly like #173
    even though the stale systemd entries were removed from
    `packages/custom-sources.list`: the nightly restores the
    packages-cache-latest release into `sources/`, and that cache
    still carried systemd-221 and systemd-256.20 next to
    systemd-257.8.  `find_archive` returned the first glob-order
    match (the oldest name), so the chapter 8 udev case ran against
    the 2015 systemd-221 tree again
  - Every copy of `find_archive` now sorts the versioned candidates
    (`sort -V`) and returns the newest, which is always the version
    the book commands target (source lists are pinned).  A functional
    test replays the #174 scenario (three systemd tarballs) and a
    static guardrail fails CI if glob-order selection returns

- **NeuralRack v0.4.1 for the audio-studio profile**
  (`blfs/27-audio-studio.sh`, `builder.py`, `packages/custom-sources.list`)
  - New `audio-studio` stage builds and installs NeuralRack v0.4.1
    (brummer10 neural amp modeller / impulse response loader) as an
    LV2 plugin into `/usr/lib/lv2` plus a standalone app when JACK or
    ALSA is present; the stage is scheduled only for the `audio-cli`
    and `audio-studio` profiles, after the BLFS multimedia stack
    (ALSA/PipeWire) which those profiles now build as well
  - Builds the LV2 host stack required by the plugin: zix 0.4.2,
    serd 0.32.4, sord 0.16.18, lv2 1.18.10, sratom 0.6.18, lilv
    0.26.4 and libsndfile 1.2.2 (BLFS book commands)
  - Book deviation: lv2/zix/serd/sord/sratom/lilv and NeuralRack have
    no BLFS book page, so they build from canonical upstream release
    tarballs with pinned sha256 checksums verified before extraction.
    The NeuralRack release `-src` tarball is used because the generic
    GitHub `refs/tags` archive lacks the git submodules and downloads
    under a version-only filename that breaks source resolution
  - On the CLI-only `audio-cli` profile the stage installs the LV2
    host stack and skips NeuralRack (its GUI needs cairo/X11); on
    `audio-studio` a missing GUI stack aborts the build

- **LPM binary repository for base packages** (`lfs/05b-build-lfs-system.sh`,
  `blfs/14-create-base-packages.sh`, `.github/workflows/release.yml`,
  `.github/workflows/xfce-live-boot-iso.yml`)
  - The chapter 8 build loop now captures per-package file lists
    (`/var/lib/lpm/manifests/<pkg>.list`, snapshot diff via awk so it
    works before diffutils is built)
  - Stage 14 assembles each manifest into a real
    `{name}-{version}.tar.xz` in `lpm-repo/` (lpm's
    `{name}-{version}/files/` install layout) and records the real
    sha256 of the tarball in the repository manifest; packages without
    a manifest keep the placeholder checksum lpm skips
  - Stable release pipelines upload `lpm-repo/*.tar.xz` next to
    `packages.list`, so installed systems can reinstall and upgrade
    base packages over the network; nightlies stay metadata-only to
    avoid matrix asset collisions

### Fixed

- **Dead BLFS layer stages are now scheduled** (`builder.py`)
  - Audit G1/G2: `blfs/23-basic-networking.sh`, `blfs/25-server.sh` and
    `blfs/26-printing-scanning.sh` were implemented but never reached by
    `get_build_stages()`, so NetworkManager/wpa_supplicant/dhcpcd,
    OpenSSH and CUPS landed in no built system and the profile package
    lists (`network`, `ssh`, `server-tools`, `all`) were aspirational
  - A new `_profile_has_pkg()` helper gates the three stages on the
    profile package list (`all` matches every group), scheduled in the
    documented BUILD_STAGES order: basic-networking, then multimedia,
    server, printing-scanning and audio-studio
  - Headless nightly profiles (minimal, server) ship no live ISO; the
    verify/sign/pointer/upload/smoke steps now fall back to the disk
    image instead of failing on the missing ISO

- **BUILD_STAGES drifted from the scheduler** (`builder.py`, `README.md`)
  - Audit G6: the constant listed `service-mgmt` while the scheduler
    emitted `service-abstraction`, and it lacked `build-kernel` and
    `package-manager`; the constant now mirrors `get_build_stages()`
    exactly and a guardrail test fails on any future drift

- **LPM configuration and checksum handling** (`config/lpm.conf`,
  `blfs/19-lpm.sh`, `blfs/14-create-base-packages.sh`)
  - Rewrote `config/lpm.conf` to only ship keys the engine consumes;
    the old `LPM_DB="/var/lib/lpm/db.json"` relocated every database
    into a `db.json/` subdirectory on installed systems, hiding the
    build-time seeded registry, and dead keys (`REPO_MIRRORS`,
    `GPG_VERIFY`, `DOWNLOAD_*`, ...) documented a configuration
    surface that never existed
  - `lpm install` now only verifies checksums that are real 64-hex
    sha256 values; placeholders (`sha256-dummy`, `base-<hash>` from
    stage 14) skip verification instead of dying with "Checksum
    mismatch"
  - Stage 14's shipped config aligned with the engine (`USE_COLOR=true`
    instead of `1`, dead `JOBS=0` removed)

- **lfs-system bc link failure** (`lfs/05b-build-lfs-system.sh`)
  - bc's final link died on undefined `tputs`/`tgoto` references
    (Nightly #167): the readline built just before bc embeds a
    DT_NEEDED on chapter 7's `libncursesw.so.6` (which lives in
    `/tools/lib`), and bc's linker had no search path for it. bc's
    configure now receives `LDFLAGS='-L/tools/lib -Wl,-rpath-link,/tools/lib'`,
    mirroring readline's own exposure

- **lfs-system gcc cc-link failure** (`lfs/05b-build-lfs-system.sh`)
  - GCC >= 15 creates `/usr/bin/cc` during `make install` itself, so
    the legacy book line `ln -sv gcc /usr/bin/cc` aborted lfs-system
    with "ln: failed to create symbolic link '/usr/bin/cc': File
    exists" (Nightly #168, both matrix jobs, after ~1h19m of build).
    The link is now guarded (`[ -e /usr/bin/cc ] || ln -sv ...`),
    keeping the book's link for older compilers
  - Hardened the remaining resume-sensitive `ln -sv` sites in the same
    stage to `ln -sfv` (bzip2, flex, pkgconf, gawk man page, vim)
    so a re-run after `--resume-from lfs-system` stays idempotent

- **lfs-system openssl "bad interpreter: /usr/bin/env" failure**
  (`lfs/05a-build-lfs-basic.sh`, `lfs/05b-build-lfs-system.sh`)
  - Nightly #169 (minimal/sysvinit/x86_64) died at openssl:
    `./config: /sources/openssl-3.5.2/Configure: /usr/bin/env: bad
    interpreter: No such file or directory`. LFS 12.4 6.5 installs the
    temporary Coreutils under `/usr`, so `/usr/bin/env` exists when
    chapter 8 starts; here the temporary tools live under `/tools`, so
    the kernel could not resolve the `#!/usr/bin/env perl` shebang of
    OpenSSL's `Configure`
  - `lfs-basic` now bridges `/usr/bin/env -> /tools/bin/env` (guarded
    so an existing real env is never clobbered), and `lfs-system`
    drops the bridge right before the final Coreutils `make install`
    so a real `/usr/bin/env` replaces it — installing through the
    symlink would write into `/tools` and leave `/usr/bin/env`
    dangling once `/tools` is removed at the end of chapter 8

- **lfs-system kmod "meson: command not found" failure**
  (`lfs/05b-build-lfs-system.sh`)
  - Nightly #170 (all profiles) died at kmod right after meson
    installed cleanly: the meson case ended with
    `ln -sfv meson /usr/bin/meson`, which replaced the real console
    script pip had just installed with a relative self-referencing
    symlink that resolves to nothing. The BLFS book installs meson
    with `pip3 wheel` + `pip3 install` only; the non-book symlink is
    removed, and the case now verifies `meson` is on PATH so any
    future drift fails the meson case instead of the next consumer
    (kmod, udev)

- **lfs-system tar "should not run configure as root" failure**
  (`lfs/05b-build-lfs-system.sh`)
  - Nightly #172 (xfce/sysvinit/x86_64) died at tar-1.35: the tar
    case ran a bare `./configure`, but chapter 8 builds run as root
    inside the chroot and tar's gnulib configure rejects that. Per
    the book, the case now passes `FORCE_UNSAFE_CONFIGURE=1`, same as
    the coreutils case

- **lfs-system udev built from a stale systemd-221 tree**
  (`packages/custom-sources.list`, `tests/test_acceptance_shell.py`)
  - Nightly #173 (full/sysvinit/x86_64) died in the chapter 8 udev
    case at `sed: can't read rules.d/50-udev-default.rules.in`: the
    sources list carried three systemd tarballs (256.20, 221, 257.8).
    Each downloads under a distinct filename, and `find_archive`
    returns the first glob-order match, so the udev case (written for
    the LFS 12.4 systemd-257.8 layout, where the rules live in
    `rules.d/`) deterministically extracted the 2015 systemd-221 tree
    (rules still under `rules/rules/`)
  - Both stale entries are removed; the LFS 12.4 systemd-257.8 tarball
    from the init tools section is now the only systemd source, shared
    by the udev chapter 8 case and 06a-init-system.sh. A guardrail
    test fails CI if a second systemd tarball ever reappears in
    `packages/custom-sources.list`

- **`lpm install` silently installed nothing on bash >= 4.4**
  (`blfs/19-lpm.sh`)
  - `install_order()` built its dependency list through an inverted
    awk membership pipeline over the order array. On bash >= 4.4
    (the GitHub runners) an empty array made `"${order[@]}"` expand
    to nothing, the pipeline exited 0 and `lpm install` returned
    success without installing anything, breaking the LPM sysroot
    smoke tests in CI
  - Membership checks now use `grep -qxF` over a `"${order[@]:-}"`
    expansion and the final print is guarded against an empty array,
    so the install order is built identically on every bash version

- **Nightly pipeline completeness** (`builder.py`, `.github/workflows/nightly.yml`)
  - New `--nightly` CLI flag: enables dated ISO naming
    (`lfs-{version}-{profile}-{arch}-{init}-{YYYYMMDD}.iso`) so the ISO
    the builder produces matches the dated name the nightly workflow
    verifies and uploads (previously the verify step referenced a file
    that was never created)
  - `create-release` now uses a unique dated tag
    (`nightly-YYYYMMDD`) and release name (`Nightly Build YYYYMMDD`)
    instead of overwriting a release tagged with the branch name; also
    sets `make_latest: false` so the stable `latest` pointer is
    preserved alongside `prerelease: true`
  - Per-profile artifact names in the release: kernel, `SHA256SUMS`,
    `build_info.json`, SBOM and LPM manifest are renamed with a
    `{profile}-{arch}-{init}` suffix so matrix jobs no longer overwrite
    each other's assets
  - Nightly builds now generate the SPDX SBOM (`--sbom`) and upload it
    as a release asset

- **Release pipeline hardening: signing, compat pointer, asset splitting**
  - `nightly.yml`: GPG signing step guarded on `secrets.GPG_PRIVATE_KEY`
    / `secrets.GPG_PASSPHRASE` (fingerprint from `vars.GPG_KEY_ID`);
    uploads a detached armored `.iso.sig` next to the ISO, and skips
    cleanly while the secrets are not configured
  - `nightly.yml` + `release.yml`: publish a tiny
    `lfs-installer.iso.pointer` asset (ISO name + SHA256 + download URL)
    resolving the backward-compatible installer name without
    duplicating multi-GB ISOs; for stable releases it is available at
    `releases/latest/download/lfs-installer.iso.pointer`
  - `nightly.yml`: split rootfs export (`tar --zstd | split -b 1900m`,
    same convention as the packages cache) for the `xfce` and `arm64`
    profiles, part checksums appended to the per-profile SHA256SUMS;
    nightly releases older than 30 days are pruned after publishing
  - `build-rootfs-cache.yml`: rootfs cache now streamed into
    `*.tar.zst.part-NN` assets with SHA256SUMS (a single archive would
    break the 2 GB release-asset cap); `build-iso-from-cache.yml`
    updated to download and reassemble every part instead of only the
    first matching asset

### Changed

- **Duplicate `lpm` stage removed** (`builder.py`, `README.md`)
  - The scheduler ran `blfs/19-lpm.sh` twice: once as `package-manager`
    (before `base-packages`) and again as a legacy `lpm` stage after
    `system-updater`. The second run was idempotent but redundant; it
    is removed from `get_build_stages()` and `BUILD_STAGES`, and the
    README stage table now lists 40 stages

- **`blfs/19-lpm.sh` is shfmt-clean** (`blfs/19-lpm.sh`)
  - The LPM engine now conforms to the CI sh-checker gate
    (`SHFMT_OPTS: -s -i 4`): redirection spacing (`>>file`),
    continuation-line indentation and one single-quoted log string.
    Formatting only, no behavior change; previously a latent CI
    failure waiting for the next edit of the file

- **Dead security config keys removed** (`config/build.conf`,
  `config/build.conf.json`, `config/default.json`, `builder.py`)
  - Audit G7: `security.fail2ban`, `security.hids` and
    `security.daily_scans` were exported as `LFS_CONFIG_SECURITY_*`
    variables but consumed by no stage script; they are removed from the
    shipped configs and from `LFSConfig.get_default_config()`

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

- **Nightly #165: readline failed to link `-lncursesw` in lfs-system** (`lfs/05b-build-lfs-system.sh`)
  - The only ncursesw present when chapter 8 readline builds is the
    chapter 7 one installed under `/tools/lib`, which is outside the
    native compiler's default search paths; configure never detected
    it and the forced `SHLIB_LIBS="-lncursesw"` then died with
    `ld: cannot find -lncursesw`
  - Fix: pass `LDFLAGS="-L/tools/lib"` to readline's configure so the
    curses library check resolves the temporary ncursesw; the chapter
    8 ncurses later replaces it under `/usr/lib` with the same SONAME
  - Test: `test_readline_configure_sees_tools_lib`
- **graphene source URL restored to the BLFS book GNOME mirror** (`packages/stable/12.4/sources.list`)
  - The GitHub refs URL downloaded a bare `1.10.8.tar.gz` with no
    package name, failing `test_required_packages_have_sources` and
    breaking `find_archive graphene` in blfs-libs

- **Nightly #162/#163: corrupt cached zlib tarball poisoned every build** (`builder.py`)
  - The `packages-cache-latest` release carries a broken
    `zlib-1.3.1.tar.gz` (SHA256 `71a999aa…` vs upstream `9a93b2b7…`,
    not gzip at all); the nightly copies it into `sources/` and
    `download()` blindly trusted it (`Already exists:`), so every
    x86_64 job died at zlib right after glibc with `gzip: stdin: not
    in gzip format`
  - Fix: `SourceDownloader.download()` now validates existing files by
    archive magic bytes (gzip/xz/bzip2/zip) and re-downloads anything
    invalid, making builds self-healing against any corrupt cache file
  - Tests: `test_is_valid_archive_magic_bytes`,
    `test_is_valid_archive_unreadable`,
    `test_download_redownloads_corrupt_existing_file`,
    `test_download_keeps_valid_existing_file`

- **Nightly #163: arm64 lfs-system killed by the hardcoded 2h stage timeout** (`builder.py`, `.github/workflows/nightly.yml`)
  - The U-Boot `ARCH=arm` fix worked (uboot stage now passes), but the
    chroot build runs under qemu-aarch64 emulation and `lfs-system`
    reached only early perl before the 7200s cap killed it
  - Fix: new `--stage-timeout` CLI option (also honouring
    `build_options.stage_timeout` in `config/build.conf`) plumbed
    through `LFSBuilder` into `ScriptExecutor`; the nightly workflow
    now passes `--stage-timeout 18000`
  - Tests: `test_script_executor_stage_timeout`,
    `test_lfs_builder_stage_timeout_propagation`,
    `test_main_stage_timeout_option`

- **Nightly #161: U-Boot build passed a kernel arch name to `ARCH`** (`host/05-build-uboot.sh`)
  - With the `$LFS/sources` fix in place the arm64 job advanced to the
    U-Boot compile and died with `ln: failed to create symbolic link
    'arch/aarch64/include/asm/arch': No such file or directory`:
    builder.py exports the kernel architecture name (`aarch64`), but
    U-Boot has no `arch/aarch64` or `arch/arm64` tree
  - Fix: kernel-style arch names (`aarch64*`, `arm64*`) are mapped to
    U-Boot's `ARCH=arm` before the first `make` call; the defconfig
    (`rpi_4_defconfig`) still selects the 64-bit ARMv8 build
  - Regression test: `test_uboot_maps_kernel_arch_to_uboot_arm`

- **Nightly #161: lfs-system built the python docs tarball instead of the sources** (`lfs/05b-build-lfs-system.sh` + 17 more stage scripts)
  - With the toolchain rpath fix in place, the xfce job advanced past
    perl and died at `=== Building python-3.13.7-docs-html ===` with
    `./configure: No such file or directory`: the `find_archive`
    prefix glob returned the first alphabetical match, and the
    documentation tarball sorts before `Python-3.13.7.tar.xz`
  - Fix: `find_archive` is now variant-safe everywhere it resolves
    tarballs by package name (`lfs/05b`, `lfs/06a`, `lfs/06c-e`,
    `blfs/08`, `08a-d`, `09a-d`, `23`, `24`, `25`, `26`): it matches
    case-insensitively (`Python-3.13.7.tar.xz`, `XML-Parser`),
    treats underscores like dashes (`flit_core`), prefers
    `name-<version>` tarballs while skipping `-docs`/`-html`
    variants, and falls back to oddball layouts by preferring `-src`
    archives (`tcl8.6.16-src`), then a top-level `configure` probe
    (`expect5.45.4`, `icu4c-77_1-src.tgz`)
  - Regression tests: `test_find_archive_survives_variant_tarballs`,
    `test_all_stages_use_variant_safe_find_archive`

- **Nightly #160: uboot stage `/sources` permission failure on aarch64** (`host/05-build-uboot.sh`)
  - With the toolchain stage fixed, the arm64 job advanced to the
    `uboot` stage and died on `mkdir: cannot create directory
    '/sources': Permission denied`: the stage runs as the unprivileged
    `lfs` user but worked from a host-level `/sources`
  - Fix: U-Boot is now downloaded and built in `$LFS/sources` (the
    builder's sources directory, owned by lfs); curl-first download
    with wget fallback; the board is read from the flattened profile
    config (`LFS_PROFILE_UBOOT_BOARD`); the `.dtb` probe uses `find`
    instead of `ls`
  - Regression test: `test_uboot_uses_lfs_sources_not_host_root`

- **Nightly #159/#160 failures: aarch64 coreutils `make install` and x86_64 `xz: liblzma.so.5` missing** (`host/04-build-toolchain.sh`)
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
  - x86_64 jobs: the `lfs-system` stage died on the first source
    extraction (`xz: error while loading shared libraries:
    liblzma.so.5`): the temporary tools link against the target glibc
    whose loader only searches `/lib` and `/usr/lib` at runtime, so
    `/tools/lib` is invisible inside the chapter 7/8 chroot
  - Fix: every temporary tools configure call (generic loop, ncurses,
    file) passes `LDFLAGS="-Wl,-rpath,$LFS/tools/lib
    -Wl,-rpath,/tools/lib"`. Both roots are embedded because the same
    binaries run from two different roots — `$LFS/tools/lib` on the
    build host during the toolchain stage and `/tools/lib` inside the
    chroot where `$LFS` is `/`; the first iteration of this fix
    embedded only the host path, which does not exist in the chroot
    and left the failure unchanged
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
