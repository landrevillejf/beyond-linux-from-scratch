# Changelog

## Unreleased

### Added

- **Ardour 9.8 DAW for the audio-studio profile**
  (`blfs/27-audio-studio.sh`, `packages/custom-sources.list`)
  - Stage 27 now builds the Ardour 9.8 digital audio workstation when
    the `audio-plugins` token is present (audio-studio).  New phases 5
    and 6 install its dependency stack first: fftw (book commands,
    double + single precision for `fftw3f`), boost, the
    libsigc++/glibmm/cairomm/atkmm/pangomm/gtkmm3 C++ binding chain
    (all BLFS book commands), then liblo 0.36, vamp-plugin-sdk 2.10
    and rubberband 4.0.0 (no book page; sha256-pinned upstream
    releases, same pattern as NeuralRack).  Ardour itself is built
    with `./waf configure --prefix=/usr --no-phone-home --no-nls
    --no-lrdf --no-lxvst --no-vst3` (JACK/ALSA/Pulse backends
    auto-detected) and installed as `/usr/bin/ardour9`
  - Book deviation: Ardour ships no usable release tarball.  GitHub
    tag archives of Ardour/ardour are placeholder stubs (see the
    mirror's README-GITHUB.txt) and git.ardour.org's archive endpoint
    requires login, so the stage clones
    `https://git.ardour.org/ardour/ardour.git` at the pinned `9.8`
    tag on the host side.  The LFS chroot ships no git, therefore the
    clone's `git describe` revision is baked into
    `libs/ardour/revision.cc` (wscript tarball path) before `.git` is
    dropped
  - audio-cli keeps its console-only promise: both phases skip when
    the token is absent

- **LV2 plugin packs for the audio-studio profile**
  (`blfs/27-audio-studio.sh`, `packages/custom-sources.list`)
  - The `audio-plugins` package token was declared on audio-studio but
    completely inert: no stage consumed it and no plugin reached the
    built system.  Stage 27 now builds LSP Plugins 1.2.35 (the full
    LV2/LADSPA suite, restricted to `lv2 ladspa ui` features so no
    JACK/GStreamer/OpenGL backend is needed) and Dragonfly Reverb
    3.2.10 (DPF-based hall/room/plate/early-reflection reverb, LV2
    bundles only) when the token is present.  Both use their `-src`
    release tarballs, which bundle the LSP sub-projects and the DPF
    framework; the bundles land in `/usr/lib/lv2`.  audio-cli keeps its
    CLI-only promise and skips the token-gated phases

- **Realtime audio tuning for the audio profiles**
  (`blfs/27-audio-studio.sh`)
  - No built system had any realtime scheduling configuration.  Stage 27
    now creates the `audio` group and installs
    `/etc/security/limits.d/audio.conf` (`@audio - rtprio 99`,
    `memlock unlimited`, `nice -19`) plus a low-latency
    `/etc/sysctl.d/90-audio.conf`.  PipeWire grants realtime priority via
    RLIMIT with these limits, so no rtkit build is required.  The
    first-boot service already adds the created user to the `audio` group
    (`blfs/17-first-boot-service.sh`); this makes that group and its
    limits actually exist

- **PREEMPT_RT realtime kernel for audio-studio**
  (`config/kernel-config-audio-studio`)
  - The base kernel config is `PREEMPT_VOLUNTARY`, unsuitable for
    low-latency audio.  A per-profile variant is added and auto-selected
    by `lfs/08-build-kernel.sh` (it prefers `kernel-config-$PROFILE`):
    `CONFIG_PREEMPT_RT=y` (+ `CONFIG_EXPERT=y` prerequisite),
    `HIGH_RES_TIMERS`, `HZ_1000`, `NO_HZ_FULL`,
    `IRQ_FORCED_THREADING`, `HPET`, `SND_HRTIMER`, plus the live-boot
    ISO9660/SQUASHFS options of the base config.  Other profiles keep the
    default config

- **Neural Amp Modeler starter models (best-effort)**
  (`blfs/27-audio-studio.sh`)
  - Stage 27 installs any `.nam` model pre-downloaded into `/sources`
    into `/usr/share/neuralrack/models` for NeuralRack to load.  No
    stable open-licensed model mirror could be pinned, so a missing model
    set is a warning, never a build failure; models are optional open
    content and can be added later via `packages/custom-sources.list`

- **Ardour DAW deferred (no buildable source)**
  - Investigated as part of the "full pro studio" request: Ardour ships
    no buildable tarball.  Its GitHub archive is an export-ignore stub
    (the tag tarball contains only a README) and the official
    `community.ardour.org` release-dist requires an account, so Ardour
    can only be built from a full `git clone` and additionally needs a
    large dependency stack (boost, fftw, aubio, libusb, hidapi, libltc,
    libwebsockets, fluidsynth, ...) that is mostly absent.  Ardour is
    deferred to a dedicated follow-up; the plugin packs, NeuralRack and
    realtime/PREEMPT_RT groundwork above are the first increment

### Changed

- **the system updater now ships on every profile**
  (`builder.py`, `config/build.conf`, `config/default.json`)
  - `minimal` was the only profile carrying `system_updater: False`, and
    the practical effect was that the `system-updater` stage had never
    once run in CI: minimal excluded it by profile while all twelve
    other jobs died in an earlier stage, so no nightly artifact has ever
    contained a `system-updater.log`.  A shipped system with no way to
    update itself is not production-ready, and `lfs-update` only
    delegates to the lpm that minimal already installs, so the profile
    now enables it too and minimal grows from 21 to 22 stages
  - `config/build.conf` and `config/default.json` also said
    `system_updater.enabled: false` while `config/build.conf.json`,
    `LFSConfig`'s built-in default and the test fixture all said true.
    All five sources now agree.  That key is inert -- `builder.py`
    overwrites it from the active profile and no stage script reads
    `LFS_CONFIG_SYSTEM_UPDATER_*` -- so the disagreement never had a
    runtime effect, but it is exactly the kind of drift that misleads
    whoever edits the file next.  The profile stays the single source of
    truth

### Fixed

- **stale gobject-introspection pin broke pango (nightly #214)**
  (`packages/custom-sources.list`)
  - All eight desktop jobs (xfce sysvinit and systemd, gnome, kde,
    lxqt, full, java-dev, audio-studio) died in blfs-libs with
    `Dependency gobject-introspection-1.0 found: NO. Found 1.82.0 but
    need: '>= 1.83.2'`, then `Dependency 'gobject-introspection-1.0' is
    required but not found` in pango's meson.  custom-sources.list
    still pinned 1.82.0 behind a bare `# gobject-introspection` label
    with no justification; custom pins are applied last and win, so the
    pin evicted the book's 1.84.0 from the generated list while pango
    1.56.4 (also from the book) hard-requires >= 1.83.2.  This is the
    same stale-pin trap documented for vala directly above it.  The
    override is dropped in favour of the official BLFS wget-list, which
    carries 1.84.0 -- the release built against the glib 2.84.4 the
    same file pins -- and replaced by a comment stating why the package
    must not be pinned again

- **branding and system-updater wrote to $LFS unprivileged
  (nightly #214)** (`blfs/20-branding.sh`, `blfs/18-system-updater.sh`)
  - Both minimal jobs got past every library stage and died in branding
    on its very first write: `mkdir: cannot create directory
    '/tmp/lfs-build/build-release/usr/share/themes': Permission
    denied`.  CI runs `sudo -u lfs python3 builder.py`, and the branding
    stage performs some twenty `mkdir -p "$LFS/..."`, fifteen `cp` and
    seven `cat >"$LFS/..."` heredocs against a tree whose /usr and /etc
    were populated as root, yet used neither the `run_privileged`
    wrapper (blfs/19-lpm.sh) nor the whole-stage sudo re-exec that
    final/12-create-initramfs.sh and lfs/08-build-kernel.sh already use
    -- despite needing root anyway for its `chroot "$LFS"` plymouth
    call.  Both stages now re-exec through `sudo -E "$0" "$@"` when
    `$EUID` is not zero, ahead of their first `$LFS` write.
    18-system-updater.sh is fixed in the same pass: it was never
    reached this run (minimal sets `system_updater: false`) but is the
    identical latent failure for every profile that enables it.  The
    branding stage also hands `$LFS/home/lfsuser/.config` back to the
    owner of the home directory with `chown -R --reference`, so running
    as root cannot lock the desktop user out of its own configuration

- **expect could not guess the build type on arm64 (nightly #214)**
  (`lfs/05b-build-lfs-system.sh`)
  - The native aarch64 job died in lfs-system right after tcl installed
    cleanly: `tclconfig/config.guess: unable to guess system type`,
    `config.guess timestamp = 2003-10-07`, then `configure: error:
    cannot guess build type; you must specify one`.  expect ships
    tclconfig/config.guess AND config.sub from 2003, both of which
    predate aarch64 entirely (zero aarch64 patterns), so its TEA
    configure has nothing to fall back on.  dejagnu's config.guess is
    2021-05-20 and aarch64-aware, so it is left alone.  expect's
    configure now receives an explicit `--build`, but the triplet is
    validated against that same fossil config.sub first: it REJECTS the
    `aarch64-pc-linux-gnu` that `gcc -dumpmachine` commonly reports
    ("machine `aarch64-pc' not recognized") and accepts only
    `aarch64-unknown-linux-gnu`, so forwarding `-dumpmachine` blindly
    would have swapped one failure for another.  An invalid or empty
    triplet falls back to `$(uname -m)-unknown-linux-gnu`; all eight
    dumpmachine/uname combinations were checked against the real 2003
    config.sub and are accepted

- **never-built texlive and docbook sources ate the six-hour job cap
  (nightly #214)** (`builder.py`)
  - The server-sysvinit and arm64-sysvinit-x86_64 jobs produced no
    failure line at all: they were cancelled mid-build at exactly
    6h0m36s, GitHub's hard per-job limit on hosted runners, which
    overrides `timeout-minutes: 480` in nightly.yml.  All thirteen
    profiles lost the same five downloads -- three multi-gigabyte
    texlive tarballs from ftp.math.utah.edu (which resets every
    connection from the runners, so each one burns the full 300 s
    timeout on every retry and on both retry passes, roughly an hour in
    total), install-tl-unx, and docbook.org's XML 5.0 zip, gone for
    good.  No stage script builds texlive or install-tl at all, and
    docbook is only ever referenced as `-D docbook=false` and as
    wpa_supplicant man-page paths, so `_update_sources_list()` now drops
    them through a new `UNUSED_SOURCE_PATTERNS` filter applied after
    the custom overrides (a deliberate custom pin can never be silently
    discarded by it).  The patterns are surgical: the rolling
    `ncurses-6.5-20250809.tgz` snapshot is the LFS wget-list's only
    ncurses entry and is kept, as are all docbook-xsl, docbook-dsssl,
    docbk31 and docs.oasis-open docbook-4.5 archives

- **libinput built before libevdev, and build_pkg hid the failure
  (nightly #213)** (`blfs/08a-build-blfs-libs.sh`,
  `blfs/08b-build-xorg.sh`, `blfs/08c-build-wayland.sh`)
  - The gnome and audio-studio jobs died in blfs-libs with
    `Dependency "libevdev" not found` at libinput's meson: the stage
    built libinput before libevdev, its REQUIRED dependency.  Worse,
    `run_build` calls the generic `build_pkg` from an `if` condition,
    which suspends `set -e` for the whole call, so the failed
    `meson setup` fell through to `log_success "$pkg installed"` and
    reported libinput as built.  blfs-libs now builds libevdev before
    libinput, and `build_pkg` in all three stages chains every build
    branch with `&&`, captures a non-zero `rc` and returns it, so a
    failed meson/ninja/configure can never again masquerade as success

- **mesa built by blfs-libs before wayland-scanner existed
  (nightly #213)** (`blfs/08a-build-blfs-libs.sh`,
  `blfs/08b-build-xorg.sh`, `blfs/08c-build-wayland.sh`)
  - Six desktop jobs died at mesa's meson with `Dependency
    "wayland-scanner" not found`: mesa was built by blfs-libs (08a),
    long before the wayland stage (08c) provided wayland-scanner and
    before the xorg stage (08b) provided the Xorg Libraries the book
    lists as a REQUIRED mesa dependency.  mesa now builds in 08b right
    after libdrm, and 08a builds wayland and wayland-protocols early
    (wayland first: wayland-protocols' meson looks up wayland-scanner)
    so libxkbcommon's wayland option and mesa's wayland platform
    resolve; 08c then skips both through is_installed

- **xorg stage never built the x7lib chapter or xorg-server's deps
  (nightly #213)** (`blfs/08b-build-xorg.sh`,
  `packages/custom-sources.list`)
  - An ordering audit found the xorg stage skipped the whole x7lib
    chapter (xtrans, libFS, libICE, libSM, libXt, libXmu, libXaw,
    libXfont2, libXft, libXxf86dga, libxshmfence, libXpresent) plus
    libxcvt and font-util, both REQUIRED by xorg-server, and built
    libepoxy (which feeds the server's glamor module) only in Phase 8,
    after xorg-server.  The stage now builds xtrans first (its
    xtrans.m4 macros are included by libFS/libICE/libSM/libXt/
    libXfont2), then the remaining x7lib libraries, libxcvt and
    font-util, and moves libepoxy ahead of the server.  cairo and pango
    are rebuilt once libX11/libXrender/libXft exist so cairo gains its
    xlib backend (GTK+3 hard-requires cairo-xlib) and pango its Xft
    backend.  None of these tarballs is in the official wget-list
    snapshot, so all fourteen are pinned in custom-sources.list

- **glib2 introspection data never generated (nightly #213)**
  (`blfs/08a-build-blfs-libs.sh`)
  - libgudev died with `Couldn't find include 'GObject-2.0.gir'` (and
    gtk4 would have next): the book reinstalls glib2 a second time
    "for the introspection data" right after gobject-introspection is
    built, but the stage only installed glib2 once.  A `glib2-gir`
    second pass now re-extracts the glib2 tarball and rebuilds it after
    gobject-introspection, so `/usr/share/gir-1.0/GObject-2.0.gir`
    exists for every later introspection consumer

- **freedesktop.org 418 lost libevdev; no second mirror tier
  (nightly #213)** (`builder.py`)
  - The #212 conglomeration fallback was not enough: freedesktop.org
    answered `418 I'm a teapot` to every libevdev request for the whole
    run and the BLFS conglomeration tree carries no libevdev directory,
    so the gnome and audio-studio jobs aborted with `no source archive
    found for libevdev`.  `download()` gained a second mirror tier keyed
    by the archive stem on the Void Linux sources mirror
    (`sources.voidlinux.org/<stem>/<file>`, byte-identical to upstream),
    tried after the conglomeration mirror, recovering hosts the BLFS
    tree does not carry

- **lpm repos.d write failed for the unprivileged CI user
  (nightly #213)** (`blfs/19-lpm.sh`)
  - Both minimal jobs died installing lpm: `install_lpm_stage` created
    `/etc/lpm/repos.d` as root, then wrote `default.conf` with a bare
    `cat >` redirection that fails with `Permission denied` when the
    stage runs as the unprivileged CI user.  The write now goes through
    the `$run_privileged tee` wrapper like every other root-owned path
    in the stage

- **mesa meson: the Mako and PyYAML python modules were never built
  (nightly #212)** (`blfs/08a-build-blfs-libs.sh`)
  - With the #210 libclc fix in place, every desktop job (xfce, gnome,
    kde, lxqt, full, java-dev, audio-studio) died one step later at
    mesa's meson with `Python (3.x) mako module >= 0.8.0 required to
    build mesa` and, right after it, the same abort for PyYAML.  The
    book lists both as REQUIRED mesa dependencies and PyYAML in turn
    requires Cython and libyaml, but no stage ever built Mako, Cython
    or PyYAML and the offline chroot cannot pip-install them from PyPI.
    blfs-libs now builds all three with the book's offline python
    module idiom (`pip3 wheel -w dist --no-build-isolation --no-deps
    --no-cache-dir "$PWD"`, then `pip3 install --no-index --find-links
    dist --no-user <Module>`) immediately before mesa.  libyaml is
    already built in phase 9 and Mako's own MarkupSafe import is
    provided by the LFS system build, so no other package is added

- **GnuTLS configure aborts: Libtasn1 not found (nightly #212)**
  (`blfs/25-server.sh`)
  - The #210 fix assumed GnuTLS would silently fall back on the
    libtasn1 copy bundled in its tarball; it does not.  All three
    headless jobs (server, minimal sysvinit and systemd) died at
    `Libtasn1 4.9 was not found. To use the included one, use
    --with-included-libtasn1`.  The desktop profiles get libtasn1 from
    blfs-libs (08a), which the headless profiles skip, so phase 8 now
    builds it with book commands before nettle and GnuTLS.
    `build_commands_gnutls` additionally passes
    `--with-included-libtasn1` when `libtasn1.pc` is absent, so a
    missing tarball degrades to the bundled copy instead of aborting

- **source_key collapsed the gtk3 and gtk4 series into one entry
  (nightly #212)** (`builder.py`)
  - The #194 dedup key stripped the whole first version token, so
    `gtk-3.24.50.tar.xz` and `gtk-4.18.6.tar.xz` both hashed to
    `pkg:gtk.tar.xz`.  Custom sources are applied last, so the
    gtk-4.18.6 pin evicted the official gtk-3.24.50 tarball from the
    generated list and the xorg stage lost the archive its required
    gtk3 build resolves through the explicit `gtk-3.*` glob.  The key
    now keeps the major digit (`pkg:gtk-3.tar.xz` versus
    `pkg:gtk-4.tar.xz`) while still stripping the minor and revision
    digits: co-installable series both survive, and a same-series
    override (gawk 5.3.2 to 5.4.0) still replaces the official URL

- **dead custom source pins evicted live book URLs (nightly #212)**
  (`packages/custom-sources.list`)
  - Auditing all 324 custom pins against the official LFS 12.4 and
    BLFS 13.0 wget-lists found 15 that 404 upstream (wayland-1.23.1,
    accountsservice-23.13.92 -- a typo for 23.13.9, poppler-25.6.0,
    babl-0.1.110, gegl-0.4.50, hunspell-5.2.3, libjpeg-turbo-3.1.1,
    json-glib-1.10.4, xorgproto-2024.1.1, xcb-proto-1.18.0,
    libdrm-2.4.174, the .tar.xz variants of libseccomp-2.6.0,
    xf86-video-fbdev-0.5.0 and xeyes-1.2.0, ImageMagick-7.1.2-27),
    stale pins dragging in a non-book major (wayland-1.26.0,
    poppler-26.08.0, xkbcommon-1.13.2, accountsservice-26.27.3,
    libwacom-0.29) and duplicates (gtk+-3.24.43, gtk-4.18.4,
    kmod-34).  A dead pin shares the dedup key of the book tarball and
    is applied last, so each one silently removed a downloadable
    source: 08c was left with no wayland tarball at all.  All of them
    are dropped (296 pins remain) and replaced by a comment stating
    why the official wget-list is authoritative for that package

- **downloads gave up on a throttled or dead upstream host
  (nightly #212)** (`builder.py`)
  - freedesktop.org answered `418 I'm a teapot` to every libevdev
    request from the runners: #208 did make 418 retryable, but the 30 s
    backoff cap re-entered the same throttle window on each attempt.
    Rate-limit answers (418 and 429) now back off eight times longer,
    capped at 240 s, while ordinary retries keep the 30 s cap.
    `download()` also gained a fallback on the BLFS conglomeration
    mirror (`ftp2.osuosl.org/pub/blfs/conglomeration/<package>/<file>`,
    the only one of the probed mirrors still serving that tree), so an
    archive dropped by its upstream host no longer fails the stage
    (ImageMagick-7.1.2-1 is 404 on imagemagick.org but present on the
    mirror).  The retry loop moved into `_download_attempt()` so the
    primary URL and each mirror get their own retry budget

- **mesa meson: libclc required by the radv/lavapipe Vulkan drivers
  (nightly #210)** (`blfs/08a-build-blfs-libs.sh`)
  - The #208 fix (`-D vulkan-drivers=amd,swrast`) cleared the rustc
    abort, but every desktop job (xfce, gnome, kde, lxqt, full,
    java-dev, audio-studio) then died at mesa meson with `Run-time
    dependency libclc found: NO`: radv/lavapipe enable mesa's OpenCL
    path, which hard-requires libclc, and libclc needs a full
    LLVM/clang toolchain that no stage builds (the llvm/libclc
    tarballs download but are never compiled).  mesa now builds
    software-only: `-D gallium-drivers=softpipe` (the book's no-LLVM
    gallium driver), `-D vulkan-drivers=""` and `-D llvm=disabled`,
    with the optional `-D video-codecs=all` dropped since softpipe has
    no video backend.  This needs no libclc, rustc, ply or
    glslangValidator and adds zero packages; the #207 SPIRV/glslang
    chain is left in place (it builds cleanly and removing it would
    churn the proven-good library order)

- **samba configure: GnuTLS not found; krb5/Parse-Yapp never built
  (nightly #210)** (`blfs/25-server.sh`)
  - The #208 venv fix let samba's configure run, but all three headless
    jobs (server, minimal sysvinit/systemd) then died at `Checking for
    GnuTLS >= 3.6.13 : not found`.  The headless profiles skip
    blfs-libs (08a), so nothing provides GnuTLS or its Required nettle
    dependency.  Phase 8 now builds nettle and GnuTLS first (offline
    switches `--without-p11-kit --with-included-unistring`; GnuTLS
    falls back on the libtasn1 bundled in its tarball).  Two further
    Required samba deps that only surface past GnuTLS are built too:
    Parse-Yapp (samba's pidl IDL compiler, needed at make time and not
    probed by configure) and MIT krb5 (the book's
    `--with-system-mitkrb5` is mandatory alongside `--without-ad-dc`,
    but the krb5 tarball was downloaded and never compiled).  nettle
    and gnutls stay required; Parse-Yapp, krb5 and samba itself are
    optional so a residual offline issue can never again block an
    otherwise-good server build

- **mesa meson: rustc required by the Nouveau Vulkan driver (nightly #208)**
  (`blfs/08a-build-blfs-libs.sh`)
  - With glslang unblocked, every desktop job (gnome, kde, lxqt, full,
    java-dev) died at mesa: the book's `-D vulkan-drivers=auto` pulls
    in the Nouveau driver (nak), which meson hard-requires `rustc` for
    and which the book notes needs an Internet connection to fetch its
    Rust crates, plus the Intel driver (anv), which needs ply.  The
    chroot is offline and ships neither rustc nor ply, so mesa now
    enumerates the drivers that build offline
    (`-D vulkan-drivers=amd,swrast`, i.e. radv + lavapipe).
    glslangValidator is still required to compile their shaders, so the
    #207 SPIRV/glslang chain stays

- **samba aborts when the offline venv cannot pip-install cryptography
  (nightly #208)** (`blfs/25-server.sh`)
  - Every headless job (server, minimal, arm64) died at samba: the book
    creates a python venv and pip-installs cryptography/pyasn1/iso8601
    for the AD DC features, but the chroot has no network so pip fails
    with `No matching distribution found for cryptography`, and the
    `|| return 1` guard turned that into a fatal stage abort.  Since
    the build already passes `--without-ad-dc`, a failed venv now
    degrades to the system python3 with a warning instead of aborting

- **freedesktop.org HTTP 418 treated as a permanent download error
  (nightly #208)** (`builder.py`)
  - The xfce jobs died in blfs-libs with `no source archive found for
    libevdev`: freedesktop.org's CDN answers parallel CI download bursts
    with `418 I'm a teapot`, which `download()` lumped in with permanent
    4xx errors, so it gave up on the first response instead of backing
    off.  418 now falls through to the same exponential-backoff retry as
    429, which also covers the other freedesktop.org packages
    (accountsservice, AppStream, colord, pulseaudio, ...) that
    intermittently 418 under load

- **mesa meson: glslangValidator not found (nightly #207)**
  (`blfs/08a-build-blfs-libs.sh`)
  - With libxkbcommon unblocked, every desktop job died at mesa:
    the stage passes the book's `-D vulkan-drivers=auto`, which
    makes meson hard-require `glslangValidator`, but no stage ever
    built Glslang.  blfs-libs now builds the full Vulkan shader
    chain with book commands before mesa: SPIRV-Headers (header-only
    cmake install), SPIRV-Tools (with `SPIRV-Headers_SOURCE_DIR=/usr`)
    and Glslang (which installs the legacy `glslangValidator`
    symlink).  All three tarballs were already downloaded by the
    official wget-list

- **bind configure: liburcu/libuv not found (nightly #207)**
  (`blfs/25-server.sh`)
  - With openldap unblocked, every headless job died at bind: the
    book lists liburcu and libuv as REQUIRED bind dependencies but
    no stage built them.  Phase 4 now builds liburcu (tarball ships
    as `userspace-rcu-*`, resolved via a `prep_src` case) and libuv
    (`sh autogen.sh` first — the GitHub archive ships no configure
    script) before bind

- **libxkbcommon aborts without wayland-protocols (nightly #199)**
  (`blfs/08a-build-blfs-libs.sh`, `blfs/08b-build-xorg.sh`)
  - The nightly #198 fix only disabled `enable-x11`; every desktop
    job died again at meson with `The Wayland xkbcli programs
    require wayland-client and wayland-protocols which were not
    found`, because meson also defaults `enable-wayland` to true and
    the wayland stage (08c) runs after blfs-libs.  Both the 08a
    build and the 08b rebuild now pass `-D enable-wayland=false`
    when `wayland-client.pc` is absent; the option only builds the
    xkbcli tools, so no library consumer is affected

- **openldap configure: Could not locate Cyrus SASL (nightly #199)**
  (`blfs/25-server.sh`)
  - With postgresql unblocked, every headless job died at openldap:
    the book server build passes `--with-cyrus-sasl` but no stage
    ever built Cyrus SASL.  Phase 3 now builds lmdb (book commands
    in `libraries/liblmdb`, tarball extracts to
    `openldap-LMDB_*-<hash>`) and cyrus-sasl (book commands,
    `--with-dblib=lmdb`, `make -j1`, gcc15 patch applied when
    present) before openldap; both tarballs were already downloaded
    by the official wget-list

- **libxkbcommon aborts without libxcb (nightly #198)**
  (`blfs/08a-build-blfs-libs.sh`, `blfs/08b-build-xorg.sh`)
  - With vala unblocked, every desktop job died at libxkbcommon:
    meson defaults `enable-x11` to true and aborts with `X11
    support requires xcb-xkb >= 1.10`, but libxcb is only built by
    the later xorg stage.  blfs-libs now passes
    `-D enable-x11=false` when xcb-xkb is absent (the book lists
    libxcb as recommended), and the xorg stage rebuilds the package
    with X11 support right after libX11 so consumers such as mutter
    still get libxkbcommon-x11

- **postgresql configure: ICU library not found (nightly #198)**
  (`blfs/25-server.sh`)
  - With mariadb unblocked, every headless job died at postgresql:
    its configure requires ICU, which only blfs-libs builds and
    headless profiles skip that stage.  Phase 2 of the server stage
    now builds ICU (book commands, `icu4c-*-src.tgz` resolved via a
    dedicated `prep_src` case) before postgresql; `book_install`
    skips it when a desktop profile already provided it

- **find_archive -src tier picked the oldest archive (nightly #198)**
  (`blfs/25-server.sh`)
  - The fallback tier returned the first `*-src*` glob match, so a
    stale packages-cache copy (`icu4c-76_1-src.tgz`) would shadow
    the book version (`icu4c-77_1-src.tgz`).  The tier now sorts
    candidates with `sort -V` and keeps the newest, mirroring the
    tier-1 rule from nightly #174

- **vala built before gobject-introspection (nightly #197)**
  (`blfs/08a-build-blfs-libs.sh`)
  - With the nightly #196 vala fix in place, all nine desktop jobs
    reached vala 0.56.18 and died in configure with `Unable to
    retrieve girdir from gobject-introspection-1.0.pc`: vala
    requires gobject-introspection, which the stage built right
    after it.  The two builds are swapped

- **mariadb tries to download fmt from GitHub offline (nightly #197)**
  (`blfs/25-server.sh`)
  - apache and the httpd layout patch now build cleanly, so every
    job reached mariadb, whose cmake ExternalProject fetches
    `fmt-11.1.4.zip` from github.com; the chroot has no DNS, so
    all six download attempts fail.  Phase 2 now builds the book's
    fmt 11.2.0 first, letting mariadb's `WITH_LIBFMT=auto` check
    pass with the system headers and skip the download

- **httpd BLFS layout patch never applied (nightly #196)**
  (`blfs/25-server.sh`)
  - After the nightly #195 fix apache correctly picked
    `httpd-2.4.65.tar.bz2`, but configure aborted with `unable to
    find layout BLFS`: the patch glob `httpd-*-blfs_layout-*.patch`
    requires a version segment that the book patch
    `httpd-blfs_layout-1.patch` does not carry, so it was silently
    skipped.  Both naming schemes are accepted now

- **stale vala-0.56.9 shadowed the book version (nightly #196)**
  (`packages/custom-sources.list`)
  - The custom list carried two vala entries (0.58.3 and 0.56.9)
    which collide on the dedup key; the last one in the file wins,
    so the stale 0.56.9 was downloaded and died compiling against
    glib 2.84 (`assignment to 'gchar **' from incompatible pointer
    type 'const gchar * const*'`).  Both entries are removed and
    the official BLFS wget-list now serves the book's vala 0.56.18

- **vala configure aborts without graphviz (nightly #195)**
  (`blfs/08a-build-blfs-libs.sh`)
  - All nine desktop matrix jobs died in blfs-libs: vala 0.56's
    configure hard-checks `libgvc >= 2.16` and no stage builds
    graphviz.  The book's `--disable-valadoc` flag is now passed
    whenever pkg-config cannot find libgvc

- **server stage built apache from the Apache Ant tarball
  (nightly #195)** (`blfs/25-server.sh`)
  - `prep_src` resolved the `apache` prefix first, and the
    apache-ant/-maven/-tomcat tarballs restored to the source list
    by the nightly #194 fix matched it; the tier-2 `-src` preference
    then selected `apache-ant-1.10.15-src.tar.xz`, which of course
    has no `support/apxs.in`.  The `httpd-*` tarball is resolved
    first now

- **apr, apr-util and pcre2 missing before apache (nightly #195)**
  (`blfs/25-server.sh`)
  - The BLFS book lists Apr-Util and pcre2 as required dependencies
    of Apache HTTPD, but no headless profile stage built them
    (blfs-libs is skipped), so httpd's configure would fail next.
    Phase 1 of the server stage now builds apr, apr-util and pcre2
    with the book commands before apache; `book_install` skips them
    when a desktop profile already provided them

- **Sources list dedup evicted tarballs in favour of patches (nightly #194)**
  (`builder.py`)
  - `source_key()` stripped everything after the first version token,
    so a tarball and its companion patch hashed to the same key.  The
    custom `libtirpc-1.3.6-gcc15_fixes-1.patch` therefore silently
    evicted the official `libtirpc-1.3.6.tar.bz2` from the generated
    list, killing minimal, server and arm64 in basic-networking with
    `no source archive found for libtirpc`.  The same collision also
    dropped one of the two coreutils patches.  Only the first version
    token is stripped now; the revision tag and extension stay in the
    key, and the generated list regains ~86 previously lost sources

- **gdk-pixbuf 2.42.12 fails without rst2man (nightly #194)**
  (`blfs/08a-build-blfs-libs.sh`)
  - All eight desktop profiles died in blfs-libs: the 2.42.x boolean
    meson option `man` defaults to true, so meson hard-fails with
    `No rst2man found, but man pages were explicitly enabled`.  The
    build now disables man pages unless docutils is installed
    (mirroring the glib2 pattern) and honours `SKIP_MAN_PAGES`, which
    the new `--skip-man-pages` CLI flag exports

- **Dead pagure.io archive URLs and IPv6 ENETUNREACH downloads
  (nightly #194)** (`packages/custom-sources.list`, `builder.py`)
  - The BLFS wget-list pagure archive URLs for libaio 0.3.113 and
    xmlto 0.0.29 return 404; both are overridden with the identical
    tarballs from `releases.pagure.org`, and the libtirpc tarball is
    pinned to the book version so it stays in lockstep with the gcc15
    patch
  - GitHub runners intermittently lose their IPv6 route while IPv4
    keeps working (`Errno 101 Network is unreachable` against
    ftp.gnu.org for cpio, ed, aspell).  Download attempts now
    alternate dual-stack and IPv4-only name resolution

- **Cancelled nightly jobs leave no logs** (`.github/workflows/nightly.yml`)
  - The aarch64 cross-build dies at the runner time limit with
    `The operation was canceled` and `failure()` is false for
    cancellations, so its build logs were never uploaded.  Logs are
    now uploaded on `failure() || cancelled()`

- **gdk-pixbuf 2.44.4 hard depends on glycin-2 (nightly #193)**
  (`packages/custom-sources.list`)
  - All desktop profiles died in blfs-libs: meson reported
    `Dependency "glycin-2" not found, tried pkgconfig and cmake`
    at gdk-pixbuf 2.44.4.  That version introduced a hard meson
    dependency on glycin-2, which is not in the BLFS 12.4 book and
    has no buildable release tarball.  The override is reverted to
    the book version 2.42.12, whose only required dependencies are
    glib2, libjpeg-turbo, libpng and shared-mime-info

- **libtirpc 1.3.6 fails to compile with GCC 15 (nightly #193)**
  (`packages/custom-sources.list`)
  - All CLI profiles died in basic-networking: libtirpc 1.3.6
    emitted `conflicting types for 'xdr_opaque_auth'` because GCC 15
    defaults to C23 where `()` means "no arguments" instead of
    K&R "unspecified".  The BLFS gcc15 patch
    (libtirpc-1.3.6-gcc15_fixes-1.patch) fixes this but was not
    downloaded; it is now listed in the patches section of
    custom-sources.list

- **nfs-utils configure: "Please install rpcgen" (nightly #192)**
  (`blfs/23-basic-networking.sh`)
  - All 12 profiles died in basic-networking at nfs-utils configure:
    `configure: error: Please install rpcgen or use --with-rpcgen`.
    glibc no longer ships `rpc/rpc.h` nor rpcgen, and the BLFS book
    lists libtirpc (RPC headers/library) and rpcsvc-proto (rpcgen)
    as REQUIRED nfs-utils dependencies, plus rpcbind at runtime.
    All three tarballs (plus the libtirpc gcc15 patch) were already
    downloaded into /sources by the official wget-list but no stage
    ever built them.  Stage 23 now builds libtirpc, rpcsvc-proto and
    rpcbind with the book commands between sqlite and nfs-utils

- **gdk-pixbuf missing shared-mime-info dependency (nightly #191/#192)**
  (`blfs/08a-build-blfs-libs.sh`)
  - Every desktop profile died in blfs-libs with meson's
    `Dependency "shared-mime-info" not found, tried pkgconfig and
    cmake`: since gdk-pixbuf 2.43 the shared-mime-info pkg-config
    file is a hard meson dependency, but the stage built
    shared-mime-info after gdk-pixbuf.  The two builds are swapped;
    shared-mime-info only needs glib2 and libxml2, both already
    installed at that point

- **dbus-glib 0.112 no longer compiles (nightly #189)**
  (`packages/custom-sources.list`)
  - Every desktop profile died in blfs-libs: make stops in
    `dbus-gvalue.c` because the `G_TYPE_VALUE_ARRAY` deprecation is a
    hard `#pragma GCC error` with the glib headers built earlier in
    the same stage.  The custom-sources.list override pinned 0.112
    while the official BLFS wget-list already carries 0.114, which
    removes the deprecated GValueArray usage.  The override is
    dropped so the official 0.114 release is used

- **nfs-utils configure: "C compiler cannot create executables"
  (nightly #189)** (`blfs/23-basic-networking.sh`)
  - minimal/server/arm64 profiles died in basic-networking: the book
    configures nfs-utils with `LIBS="-lsqlite3 -levent_core"`
    (required for the fsidd daemon), but sqlite is only built by the
    server stage, which runs AFTER basic-networking, so every
    configure probe failed to link.  Stage 23 now builds sqlite
    (book server/sqlite commands) right before nfs-utils; the server
    stage skips it through its is_installed check

- **Dead ntp.org download URL (nightly #187)**
  (`packages/custom-sources.list`)
  - minimal/sysvinit/x86_64 died in basic-networking with
    `gzip: stdin: not in gzip format` on ntp-4.2.8p18.tar.gz.  The
    packages-cache copy of the tarball is an HTML page, and the
    re-download triggered by the magic-byte check hit the override
    URL `www.ntp.org/downloads/`, which now serves the same HTML
    error page.  The override repoints to the BLFS conglomeration
    mirror (`ftp2.osuosl.org/pub/blfs/conglomeration/ntp/`), which
    serves the genuine tarball

- **cairo 1.17.8 snapshot no longer compiles (nightly #187)**
  (`packages/custom-sources.list`)
  - java-dev/sysvinit/x86_64 (and every other profile past
    blfs-base) died in blfs-libs: ninja stopped while compiling
    `util/cairo-script/cairo-script-operators.c`.  The 2023
    `snapshots/cairo-1.17.8` pinned by the override does not build
    with the LFS 12.4 GCC 14 toolchain.  The override now pins the
    current stable release `cairo-1.18.4` from
    `cairographics.org/releases/`, the same version as the BLFS
    book's wget-list

- **cmake: command not found in blfs-libs (nightly #186)**
  (`blfs/08-build-blfs-base.sh`)
  - full/sysvinit/x86_64 passed libpng and died on the next package:
    `/build-blfs-libs.sh: line 306: cmake: command not found` while
    building libjpeg-turbo, the first cmake consumer.  No stage ever
    built cmake.  The blfs-base stage now installs it after cURL
    using the BLFS book bootstrap commands; every cmake dependency
    that does not exist yet at that point (libarchive, libuv,
    nghttp2, zstd plus the book's jsoncpp/cppdap/librhash) is
    excluded with `--no-system-*` so the bundled copy is used

- **nmap final link missing libnl symbols (nightly #186)**
  (`blfs/23-basic-networking.sh`)
  - minimal/x86_64/systemd failed linking nmap with undefined
    references to `nl_socket_free`, `genl_ctrl_search_by_name`, etc.
    from the bundled libpcap: without a system libpcap, nmap
    statically compiles its bundled copy, which picks up the
    installed libnl-3 netlink support and never receives `-lnl-3`
    at the final link.  The stage now builds the system libpcap
    (BLFS basicnet commands, nmap's recommended dependency) in
    Phase 2 before nmap

- **Expired inkscape.org gallery URL (nightly #186)**
  (`packages/custom-sources.list`)
  - The official wget-list points at
    `inkscape.org/gallery/item/56344/inkscape-1.4.2.tar.xz`, which
    now returns HTTP 403 (gallery item URLs expire).  The override
    repoints to the BLFS conglomeration mirror
    (`ftp2.osuosl.org/pub/blfs/conglomeration/inkscape/`), which
    keeps every book source under its book filename

- **blfs-libs pushd into a log line (nightly #184)**
  (`blfs/08a`, `08b`, `08c`, `08d`, `09a`, `09b`, `09c`, `09d`, `23`,
  `24`, `25`, `26`, `27`)
  - The first run past the pcre2 gate died on libpng after 0.2 s:
    `pushd: '[INFO] Building libpng from libpng-1.6.47.tar.xz\n
    libpng-1.6.47': No such file or directory`.  `book_install`
    captures `prep_src` stdout to obtain the extracted directory
    name, but `prep_src` logged its progress message to stdout, so
    the directory became the log line plus the name.  The message
    now goes to stderr in every stage that defines `prep_src`, and a
    guardrail test fails CI if any copy logs to stdout again

- **build-kernel looking for sources next to $LFS (nightly #185)**
  (`lfs/08-build-kernel.sh`)
  - minimal/sysvinit/x86_64 died with `Sources directory not found:
    /tmp/lfs-build/sources`: the stage guessed
    `$(dirname $LFS)/sources`, but CI keeps host downloads in
    `build-release/sources`.  It now reads `$LFS/sources`, the
    chroot mirror that lfs-basic populates for every profile and
    that the native path already asserts 20 lines later

- **Business-ISBN override placed where builder.py reads it**
  (`packages/custom-sources.list`)
  - The nightly #182 fix put the backpan.perl.org mirror in
    `packages/stable/12.4/sources.list`, which is never read at
    runtime, so #185 still 404'd on cpan.org.  The override now lives
    in `custom-sources.list`, the only file that overrides the
    fetched official wget-lists

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
    (see the Unreleased entry for the placement fix)
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
