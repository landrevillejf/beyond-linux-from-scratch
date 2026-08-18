#!/bin/bash
# Applications – with dynamic source path
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../common/utils.sh" ]; then
    source "$SCRIPT_DIR/../common/utils.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_warning() { echo "[WARNING] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
fi

IN_DOCKER=false
if [ -f /.dockerenv ] || [ -f /run/.containerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
    IN_DOCKER=true
    log_info "Running in Docker container"
fi
if [ "$IN_DOCKER" = true ]; then LFS=${LFS:-/output/image}; else LFS=${LFS:-/mnt/lfs}; fi
[ -n "$LFS" ] || {
    log_error "LFS variable not set"
    exit 1
}
APPS_TO_BUILD="${LFS_CONFIG_APPS_TO_BUILD:-firefox,vlc}"
export APPS_TO_BUILD
run_privileged() { if [ "$(whoami)" = "root" ]; then "$@"; else sudo "$@"; fi; }

log_info "========================================="
log_info "Building applications: $APPS_TO_BUILD"
log_info "========================================="

install_app_metadata() {
    log_info "Docker mode – installing application desktop files and LPM metadata in $LFS"
    run_privileged mkdir -pv "$LFS"/usr/share/applications "$LFS"/usr/share/metainfo "$LFS"/var/lib/lpm/installed "$LFS"/var/lib/lfs-builder/applications
    IFS=',' read -r -a apps <<<"$APPS_TO_BUILD"
    for raw_app in "${apps[@]}"; do
        app="$(echo "$raw_app" | tr '[:upper:]' '[:lower:]' | xargs)"
        [ -n "$app" ] || continue
        case "$app" in
        firefox)
            run_privileged tee "$LFS/usr/share/applications/firefox.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Name=Firefox
Comment=Browse the World Wide Web
Exec=firefox %u
Terminal=false
Type=Application
Icon=firefox
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
EOF
            ;;
        libreoffice)
            run_privileged tee "$LFS/usr/share/applications/libreoffice-startcenter.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Name=LibreOffice
Comment=Office productivity suite
Exec=libreoffice %U
Terminal=false
Type=Application
Icon=libreoffice-startcenter
Categories=Office;
EOF
            ;;
        gimp)
            run_privileged tee "$LFS/usr/share/applications/gimp.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Name=GNU Image Manipulation Program
Comment=Create images and edit photographs
Exec=gimp %U
Terminal=false
Type=Application
Icon=gimp
Categories=Graphics;RasterGraphics;
EOF
            ;;
        vlc)
            run_privileged tee "$LFS/usr/share/applications/vlc.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Name=VLC media player
Comment=Read, capture, broadcast multimedia streams
Exec=vlc --started-from-file %U
Terminal=false
Type=Application
Icon=vlc
Categories=AudioVideo;Player;
EOF
            ;;
        audacity)
            run_privileged tee "$LFS/usr/share/applications/audacity.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Name=Audacity
Comment=Record and edit audio
Exec=audacity %F
Terminal=false
Type=Application
Icon=audacity
Categories=AudioVideo;Audio;
EOF
            ;;
        mumble)
            run_privileged tee "$LFS/usr/share/applications/mumble.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Name=Mumble
Comment=Voice Chat Application
Exec=mumble %u
Terminal=false
Type=Application
Icon=mumble
Categories=Network;Chat;
EOF
            ;;
        hexchat)
            run_privileged tee "$LFS/usr/share/applications/hexchat.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Name=HexChat
Comment=IRC Client
Exec=hexchat
Terminal=false
Type=Application
Icon=hexchat
Categories=Network;IRCClient;
EOF
            ;;
        pidgin)
            run_privileged tee "$LFS/usr/share/applications/pidgin.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Name=Pidgin Internet Messenger
Comment=Chat over IM. Supports AIM, Google Talk, Jabber/XMPP, MSN, Yahoo and more
Exec=pidgin
Terminal=false
Type=Application
Icon=pidgin
Categories=Network;InstantMessaging;
EOF
            ;;
        obsidian)
            run_privileged tee "$LFS/usr/share/applications/obsidian.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Name=Obsidian
Comment=Knowledge base that works on local Markdown files
Exec=obsidian %u
Terminal=false
Type=Application
Icon=obsidian
Categories=Office;
EOF
            ;;
        *)
            log_warning "Unknown application '$app' requested; metadata not installed"
            continue
            ;;
        esac
        run_privileged tee "$LFS/var/lib/lpm/installed/${app}.metadata" >/dev/null <<EOF
name=$app
status=metadata-only
source=docker-mode
requested_by=LFS_CONFIG_APPS_TO_BUILD
EOF
        run_privileged touch "$LFS/var/lib/lfs-builder/applications/${app}.docker"
        log_success "Installed Docker metadata for $app"
    done
}

if [ "$IN_DOCKER" = true ]; then
    install_app_metadata
    exit 0
fi
[ -x "$LFS/bin/bash" ] || {
    log_error "/bin/bash not found in $LFS/bin – run lfs-basic first"
    exit 1
}
if ! run_privileged chroot "$LFS" /bin/bash -c "exit 0" 2>/dev/null; then
    log_error "chroot not working – run lfs-basic first"
    exit 1
fi

mount_chroot_fs() {
    run_privileged mkdir -p "$LFS"/{dev,dev/pts,proc,sys,run,sources}
    run_privileged mountpoint -q "$LFS/dev" || run_privileged mount --bind /dev "$LFS/dev"
    run_privileged mountpoint -q "$LFS/dev/pts" || run_privileged mount -t devpts devpts "$LFS/dev/pts"
    run_privileged mountpoint -q "$LFS/proc" || run_privileged mount -t proc proc "$LFS/proc"
    run_privileged mountpoint -q "$LFS/sys" || run_privileged mount -t sysfs sysfs "$LFS/sys"
    run_privileged mountpoint -q "$LFS/run" || run_privileged mount -t tmpfs tmpfs "$LFS/run"
}
cleanup() {
    if run_privileged mountpoint -q "$LFS/dev/pts" && ! run_privileged umount "$LFS/dev/pts" 2>/dev/null; then log_warning "Could not unmount $LFS/dev/pts"; fi
    if run_privileged mountpoint -q "$LFS/dev" && ! run_privileged umount "$LFS/dev" 2>/dev/null; then log_warning "Could not unmount $LFS/dev"; fi
    if run_privileged mountpoint -q "$LFS/proc" && ! run_privileged umount "$LFS/proc" 2>/dev/null; then log_warning "Could not unmount $LFS/proc"; fi
    if run_privileged mountpoint -q "$LFS/sys" && ! run_privileged umount "$LFS/sys" 2>/dev/null; then log_warning "Could not unmount $LFS/sys"; fi
    if run_privileged mountpoint -q "$LFS/run" && ! run_privileged umount "$LFS/run" 2>/dev/null; then log_warning "Could not unmount $LFS/run"; fi
}
trap cleanup EXIT
mount_chroot_fs

SOURCES_HOST="$(dirname "$LFS")/sources"
if [ -d "$SOURCES_HOST" ] && [ "$(ls -A "$SOURCES_HOST" 2>/dev/null)" ]; then
    log_info "Copying sources from $SOURCES_HOST to $LFS/sources"
    run_privileged mkdir -p "$LFS/sources"
    run_privileged cp -rv "$SOURCES_HOST"/* "$LFS/sources/"
    if ! run_privileged chown -R lfs:lfs "$LFS/sources" 2>/dev/null; then log_warning "Could not chown $LFS/sources to lfs:lfs"; fi
fi

cat <<'INNEREOF' | run_privileged tee "$LFS/build-apps.sh" >/dev/null
#!/bin/bash
set -euo pipefail
log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARNING] $*"; }
log_success() { echo "[SUCCESS] $*"; }
cd /sources
mkdir -p /var/lib/lfs-builder/applications /usr/share/applications
APPS_TO_BUILD="${APPS_TO_BUILD:-firefox,vlc}"
jobs() { nproc 2>/dev/null || echo 1; }
marker_for() { echo "/var/lib/lfs-builder/applications/$1.done"; }
find_archive() { compgen -G "$1" | sort -V | tail -n 1; }
extract_archive() { local archive="$1" dir; dir="$(tar -tf "$archive" | head -n 1 | cut -d/ -f1)"; rm -rf "$dir"; tar -xf "$archive"; printf '%s\n' "$dir"; }
have_pc() { pkg-config --exists "$1" 2>/dev/null; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
missing_items() { local missing=() item; for item in "$@"; do case "$item" in pc:*) have_pc "${item#pc:}" || missing+=("${item#pc:}");; cmd:*) have_cmd "${item#cmd:}" || missing+=("${item#cmd:}");; file:*) [ -e "${item#file:}" ] || missing+=("${item#file:}");; *) have_cmd "$item" || missing+=("$item");; esac; done; printf '%s\n' "${missing[@]}"; }
check_deps() { local app="$1" missing; shift; missing="$(missing_items "$@")"; if [ -n "$missing" ]; then log_warning "$app dependencies missing; skipping $app: $(echo "$missing" | tr '\n' ' ')"; return 1; fi; }
is_installed() { local app="$1"; [ -f "$(marker_for "$app")" ] && return 0; case "$app" in firefox) [ -x /usr/bin/firefox ];; libreoffice) [ -x /usr/bin/libreoffice ];; gimp) [ -x /usr/bin/gimp ];; vlc) [ -x /usr/bin/vlc ];; thunderbird) [ -x /usr/bin/thunderbird ];; inkscape) [ -x /usr/bin/inkscape ];; evolution) [ -x /usr/bin/evolution ];; filezilla) [ -x /usr/bin/filezilla ];; transmission) [ -x /usr/bin/transmission-gtk ] || [ -x /usr/bin/transmission-qt ];; audacity) [ -x /usr/bin/audacity ];; mumble) [ -x /usr/bin/mumble ];; hexchat) [ -x /usr/bin/hexchat ];; pidgin) [ -x /usr/bin/pidgin ];; obsidian) [ -x /usr/bin/obsidian ];; *) return 1;; esac; }
finish_app() { touch "$(marker_for "$1")"; log_success "$1 installed"; }
build_firefox() {
    local app=firefox archive dir rust_version
    if is_installed "$app"; then log_info "Firefox already installed; skipping"; return 0; fi
    if ! check_deps Firefox cmd:rustc cmd:cbindgen cmd:node cmd:yasm cmd:nasm cmd:python3 cmd:perl cmd:tar cmd:make pc:nspr pc:nss pc:icu-uc; then return 1; fi
    rust_version="$(rustc --version | awk '{print $2}')"
    if ! python3 -c "import sys; from distutils.version import LooseVersion; sys.exit(0 if LooseVersion('$rust_version') >= LooseVersion('1.76') else 1)"; then log_warning "Firefox requires rustc >= 1.76; found $rust_version; skipping Firefox"; return 1; fi
    archive="$(find_archive 'firefox-*.tar.*')"; [ -n "$archive" ] || { log_warning "Firefox source archive missing; skipping"; return 1; }
    log_info "Building Firefox from $archive"; dir="$(extract_archive "$archive")"; pushd "$dir" >/dev/null
    cat > .mozconfig <<'EOF'
mk_add_options MOZ_OBJDIR=@TOPSRCDIR@/objdir
ac_add_options --prefix=/usr
ac_add_options --enable-application=browser
ac_add_options --disable-crashreporter
ac_add_options --disable-updater
ac_add_options --enable-official-branding
ac_add_options --with-system-nspr
ac_add_options --with-system-nss
ac_add_options --with-system-icu
EOF
    ./mach configure; ./mach build; ./mach install
    popd >/dev/null; rm -rf "$dir"; finish_app "$app"
}
build_libreoffice() {
    local app=libreoffice archive dir java_flag=--without-java
    if is_installed "$app"; then log_info "LibreOffice already installed; skipping"; return 0; fi
    if ! check_deps LibreOffice cmd:python3 cmd:perl cmd:gpg cmd:make cmd:pkg-config cmd:tar pc:libxml-2.0 pc:cairo pc:gtk+-3.0 pc:hunspell pc:poppler-glib; then return 1; fi
    if have_cmd javac && have_cmd java; then java_flag=--with-java; else log_warning "Java not found; building LibreOffice with --without-java"; fi
    archive="$(find_archive 'libreoffice-*.tar.*')"; [ -n "$archive" ] || { log_warning "LibreOffice source archive missing; skipping"; return 1; }
    log_info "Building LibreOffice from $archive"; dir="$(extract_archive "$archive")"; pushd "$dir" >/dev/null
    ./autogen.sh --prefix=/usr "$java_flag" --disable-firebird-sdbc --disable-gtk4 --with-system-libs --with-vendor="LFS" --with-lang="en-US" --enable-release-build
    make -j"$(jobs)"; make install
    popd >/dev/null; rm -rf "$dir"; finish_app "$app"
}
build_gimp() {
    local app=gimp archive dir
    if is_installed "$app"; then log_info "GIMP already installed; skipping"; return 0; fi
    if ! check_deps GIMP cmd:meson cmd:ninja cmd:pkg-config cmd:tar pc:babl pc:gegl-0.4 pc:glib-2.0 pc:gtk+-3.0 pc:cairo pc:pango pc:poppler-glib; then return 1; fi
    archive="$(find_archive 'gimp-*.tar.*')"; [ -n "$archive" ] || { log_warning "GIMP source archive missing; skipping"; return 1; }
    log_info "Building GIMP from $archive"; dir="$(extract_archive "$archive")"; pushd "$dir" >/dev/null
    rm -rf _build; meson setup _build --prefix=/usr -Dbuildtype=release; ninja -C _build; ninja -C _build install
    popd >/dev/null; rm -rf "$dir"; finish_app "$app"
}
build_vlc() {
    local app=vlc archive dir
    if is_installed "$app"; then log_info "VLC already installed; skipping"; return 0; fi
    if ! check_deps VLC cmd:pkg-config cmd:make cmd:tar pc:libavcodec pc:libavformat pc:alsa pc:libmatroska pc:libebml pc:taglib; then return 1; fi
    archive="$(find_archive 'vlc-*.tar.*')"; [ -n "$archive" ] || { log_warning "VLC source archive missing; skipping"; return 1; }
    log_info "Building VLC from $archive"; dir="$(extract_archive "$archive")"; pushd "$dir" >/dev/null
    ./configure --prefix=/usr --disable-static --enable-alsa --enable-x11 --enable-xcb
    make -j"$(jobs)"; make install
    popd >/dev/null; rm -rf "$dir"; finish_app "$app"
}
build_thunderbird() {
    local app=thunderbird archive dir rust_version
    if is_installed "$app"; then log_info "Thunderbird already installed; skipping"; return 0; fi
    if ! check_deps Thunderbird cmd:rustc cmd:cbindgen cmd:node cmd:yasm cmd:nasm cmd:python3 cmd:perl cmd:tar cmd:make pc:nspr pc:nss pc:icu-uc; then return 1; fi
    rust_version="$(rustc --version | awk '{print $2}')"
    if ! python3 -c "import sys; from distutils.version import LooseVersion; sys.exit(0 if LooseVersion('$rust_version') >= LooseVersion('1.76') else 1)"; then log_warning "Thunderbird requires rustc >= 1.76; found $rust_version; skipping Thunderbird"; return 1; fi
    archive="$(find_archive 'thunderbird-*.tar.*')"; [ -n "$archive" ] || { log_warning "Thunderbird source archive missing; skipping"; return 1; }
    log_info "Building Thunderbird from $archive"; dir="$(extract_archive "$archive")"; pushd "$dir" >/dev/null
    cat > .mozconfig <<'EOF'
mk_add_options MOZ_OBJDIR=@TOPSRCDIR@/objdir
ac_add_options --prefix=/usr
ac_add_options --enable-application=comm/mail
ac_add_options --disable-crashreporter
ac_add_options --disable-updater
ac_add_options --enable-official-branding
ac_add_options --with-system-nspr
ac_add_options --with-system-nss
ac_add_options --with-system-icu
EOF
    ./mach configure; ./mach build; ./mach install
    popd >/dev/null; rm -rf "$dir"; finish_app "$app"
}
build_inkscape() {
    local app=inkscape archive dir
    if is_installed "$app"; then log_info "Inkscape already installed; skipping"; return 0; fi
    if ! check_deps Inkscape cmd:cmake cmd:pkg-config cmd:tar pc:glibmm-2.4 pc:gtkmm-3.0 pc:libxml-2.0 pc:cairo pc:pango; then return 1; fi
    archive="$(find_archive 'inkscape-*.tar.*')"; [ -n "$archive" ] || { log_warning "Inkscape source archive missing; skipping"; return 1; }
    log_info "Building Inkscape from $archive"; dir="$(extract_archive "$archive")"; pushd "$dir" >/dev/null
    cmake -B builddir -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release
    cmake --build builddir -j"$(jobs)"
    cmake --install builddir
    popd >/dev/null; rm -rf "$dir"; finish_app "$app"
}
build_evolution() {
    local app=evolution archive dir
    if is_installed "$app"; then log_info "Evolution already installed; skipping"; return 0; fi
    if ! check_deps Evolution cmd:meson cmd:ninja cmd:pkg-config cmd:tar pc:glib-2.0 pc:gtk+-3.0 pc:webkit2gtk-4.0 pc:nspr pc:nss; then return 1; fi
    archive="$(find_archive 'evolution-*.tar.*')"; [ -n "$archive" ] || { log_warning "Evolution source archive missing; skipping"; return 1; }
    log_info "Building Evolution from $archive"; dir="$(extract_archive "$archive")"; pushd "$dir" >/dev/null
    rm -rf builddir; meson setup builddir --prefix=/usr --buildtype=release; ninja -C builddir; ninja -C builddir install
    popd >/dev/null; rm -rf "$dir"; finish_app "$app"
}
build_filezilla() {
    local app=filezilla archive dir
    if is_installed "$app"; then log_info "FileZilla already installed; skipping"; return 0; fi
    if ! check_deps FileZilla cmd:configure cmd:make cmd:tar pc:wxWidgets pc:libidn pc:gnutls pc:gtk+-2.0; then return 1; fi
    archive="$(find_archive 'filezilla-*.tar.*')"; [ -n "$archive" ] || { log_warning "FileZilla source archive missing; skipping"; return 1; }
    log_info "Building FileZilla from $archive"; dir="$(extract_archive "$archive")"; pushd "$dir" >/dev/null
    ./configure --prefix=/usr --disable-static --with-wx-config=/usr/bin/wx-config
    make -j"$(jobs)"; make install
    popd >/dev/null; rm -rf "$dir"; finish_app "$app"
}
build_transmission() {
    local app=transmission archive dir
    if is_installed "$app"; then log_info "Transmission already installed; skipping"; return 0; fi
    if ! check_deps Transmission cmd:cmake cmd:pkg-config cmd:tar pc:libevent pc:libcurl pc:openssl; then return 1; fi
    archive="$(find_archive 'transmission-*.tar.*')"; [ -n "$archive" ] || { log_warning "Transmission source archive missing; skipping"; return 1; }
    log_info "Building Transmission from $archive"; dir="$(extract_archive "$archive")"; pushd "$dir" >/dev/null
    cmake -B builddir -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release
    cmake --build builddir -j"$(jobs)"
    cmake --install builddir
    popd >/dev/null; rm -rf "$dir"; finish_app "$app"
}
build_audacity() {
    local app=audacity archive dir
    if is_installed "$app"; then log_info "Audacity already installed; skipping"; return 0; fi
    if ! check_deps Audacity cmd:cmake cmd:pkg-config cmd:tar pc:wxWidgets pc:libsoxr pc:ffmpeg pc:flac pc:mp3lame pc:soundtouch; then return 1; fi
    archive="$(find_archive 'audacity-*.tar.*')"; [ -n "$archive" ] || { log_warning "Audacity source archive missing; skipping"; return 1; }
    log_info "Building Audacity from $archive"; dir="$(extract_archive "$archive")"; pushd "$dir" >/dev/null
    cmake -B builddir -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release
    cmake --build builddir -j"$(jobs)"
    cmake --install builddir
    popd >/dev/null; rm -rf "$dir"; finish_app "$app"
}
build_mumble() {
    local app=mumble archive dir
    if is_installed "$app"; then log_info "Mumble already installed; skipping"; return 0; fi
    if ! check_deps Mumble cmd:cmake cmd:pkg-config cmd:tar pc:qt5 pc:opus pc:speex pc:celt; then return 1; fi
    archive="$(find_archive 'mumble-*.tar.*')"; [ -n "$archive" ] || { log_warning "Mumble source archive missing; skipping"; return 1; }
    log_info "Building Mumble from $archive"; dir="$(extract_archive "$archive")"; pushd "$dir" >/dev/null
    cmake -B builddir -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release
    cmake --build builddir -j"$(jobs)"
    cmake --install builddir
    popd >/dev/null; rm -rf "$dir"; finish_app "$app"
}
build_hexchat() {
    local app=hexchat archive dir
    if is_installed "$app"; then log_info "HexChat already installed; skipping"; return 0; fi
    if ! check_deps HexChat cmd:configure cmd:make cmd:tar pc:gtk+-2.0 pc:libnotify pc:libcanberra pc:openssl; then return 1; fi
    archive="$(find_archive 'hexchat-*.tar.*')"; [ -n "$archive" ] || { log_warning "HexChat source archive missing; skipping"; return 1; }
    log_info "Building HexChat from $archive"; dir="$(extract_archive "$archive")"; pushd "$dir" >/dev/null
    ./configure --prefix=/usr --disable-textfe --disable-gtktextfe --enable-libnotify --enable-libcanberra
    make -j"$(jobs)"
    make install
    popd >/dev/null; rm -rf "$dir"; finish_app "$app"
}
build_pidgin() {
    local app=pidgin archive dir
    if is_installed "$app"; then log_info "Pidgin already installed; skipping"; return 0; fi
    if ! check_deps Pidgin cmd:configure cmd:make cmd:tar pc:gtk+-2.0 pc:libpurple pc:gstreamer-1.0 pc:libxml-2.0; then return 1; fi
    archive="$(find_archive 'pidgin-*.tar.*')"; [ -n "$archive" ] || { log_warning "Pidgin source archive missing; skipping"; return 1; }
    log_info "Building Pidgin from $archive"; dir="$(extract_archive "$archive")"; pushd "$dir" >/dev/null
    ./configure --prefix=/usr --disable-gtkui --disable-consoleui --enable-nss --enable-gnutls
    make -j"$(jobs)"
    make install
    popd >/dev/null; rm -rf "$dir"; finish_app "$app"
}
build_obsidian() {
    local app=obsidian archive dir
    if is_installed "$app"; then log_info "Obsidian already installed; skipping"; return 0; fi
    if ! check_deps Obsidian cmd:electron-builder cmd:node cmd:npm; then return 1; fi
    archive="$(find_archive 'obsidian-*.tar.*')"; [ -n "$archive" ] || { log_warning "Obsidian source archive missing; skipping"; return 1; }
    log_info "Building Obsidian from $archive"; dir="$(extract_archive "$archive")"; pushd "$dir" >/dev/null
    npm install
    npm run build
    npm install -g electron-builder
    electron-builder --linux
    popd >/dev/null; rm -rf "$dir"; finish_app "$app"
}
requested_app() { local app="$1" raw normalized; IFS=',' read -r -a requested <<< "$APPS_TO_BUILD"; for raw in "${requested[@]}"; do normalized="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | xargs)"; [ "$normalized" = "$app" ] && return 0; done; return 1; }
log_info "Application selection: $APPS_TO_BUILD"
status=0
for app in firefox libreoffice gimp vlc thunderbird inkscape evolution filezilla transmission audacity mumble hexchat pidgin obsidian; do
    if requested_app "$app"; then
        log_info "Starting $app build"
        if "build_$app"; then log_success "$app build complete"; else log_warning "$app was not built; see dependency/source messages above"; status=1; fi
    fi
done
[ "$status" -eq 0 ] || log_warning "One or more selected applications were skipped"
log_success "Application build stage complete"
exit 0
INNEREOF
run_privileged chmod +x "$LFS/build-apps.sh"
run_privileged chroot "$LFS" /bin/bash -c "export APPS_TO_BUILD='$APPS_TO_BUILD'; /build-apps.sh"
log_success "Applications stage completed"
