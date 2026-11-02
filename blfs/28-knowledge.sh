#!/bin/bash
set -euo pipefail
#======================================================================
# 28-knowledge.sh - optional local AI assistant "knowledge" (Ollama)
#
# Wires a free, open source, fully local AI assistant into the built
# system. Opt-in: this stage is a no-op unless
# LFS_CONFIG_KNOWLEDGE_ENABLED=true (config/build.conf "knowledge"
# section, or the --with-knowledge CLI flag).
#
# The stage ships the INTEGRATION, never the ENGINE.  $LFS is both the
# live session's squashfs and what the installer copies onto the disk,
# so anything put here is in every image: the engine tarball alone is
# 1.9 GB compressed (ollama-linux-amd64.tgz v0.12.6 = 1903757843 bytes)
# and is already deflate-packed, so xz barely shrinks it and lg3d
# nightlies #68/#69 measured 2856 MB / 2850 MB for an ISO the GitHub
# release API rejects outright (an asset's size must stay under
# 2147483648 bytes).  Running the assistant is the user's decision on
# the target, so the image carries only the CLI wrapper, the service
# files, the model-provisioning one-shot and
# /usr/lib/knowledge/install-engine.sh.  Nothing is downloaded here.
#
# Book deviation (documented in docs/KNOWLEDGE_DESIGN.md): Ollama is not
# a BLFS package.  knowledge.engine_sha256 stays mandatory even though
# the build unpacks nothing any more -- it is the digest the on-demand
# installer verifies, and an installer without a pin is a remote code
# execution vector, so the stage still refuses to run without one.
#
# Environment contract (exported by builder.py):
#   LFS_CONFIG_KNOWLEDGE_ENABLED/ENGINE/ENGINE_VERSION/ENGINE_SHA256
#   LFS_CONFIG_KNOWLEDGE_MODELS/DEFAULT_MODEL/PROVISION_MODELS
#   LFS_CONFIG_KNOWLEDGE_LISTEN/ALLOW_NETWORK
#   LFS_CONFIG_ARCHITECTURE, INIT_SYSTEM, LFS
#======================================================================

log_info() { echo "[knowledge] INFO: $*"; }
log_warn() { echo "[knowledge] WARN: $*" >&2; }
die() {
    echo "[knowledge] ERROR: $*" >&2
    exit 1
}

# builder.py launches every stage as the unprivileged build user (the CI
# runs `sudo -u lfs python3 builder.py`), so each write into the
# root-owned $LFS tree and each chroot must go through sudo -- the same
# run_privileged idiom the sibling blfs stages use.  Without it the very
# first root-owned write (a config file into $LFS/etc) dies "Permission
# denied".  Nightly #61.
run_privileged() {
    if [ "$(whoami)" = "root" ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# ----------------------------------------------------------------------
# Guard: the assistant is strictly opt-in
# ----------------------------------------------------------------------
if [ "${LFS_CONFIG_KNOWLEDGE_ENABLED:-false}" != "true" ]; then
    log_info "knowledge assistant disabled - stage skipped"
    exit 0
fi

[ -n "${LFS:-}" ] || die "LFS is not set"
[ -d "$LFS" ] || die "LFS tree not found: $LFS"

ENGINE_VERSION="${LFS_CONFIG_KNOWLEDGE_ENGINE_VERSION:-0.12.6}"
ENGINE_SHA256="${LFS_CONFIG_KNOWLEDGE_ENGINE_SHA256:-}"
MODELS="${LFS_CONFIG_KNOWLEDGE_MODELS:-}"
DEFAULT_MODEL="${LFS_CONFIG_KNOWLEDGE_DEFAULT_MODEL:-qwen2.5-coder:7b}"
PROVISION="${LFS_CONFIG_KNOWLEDGE_PROVISION_MODELS:-first-boot}"
LISTEN="${LFS_CONFIG_KNOWLEDGE_LISTEN:-127.0.0.1:11434}"
ALLOW_NETWORK="${LFS_CONFIG_KNOWLEDGE_ALLOW_NETWORK:-false}"
ARCH="${LFS_CONFIG_ARCHITECTURE:-x86_64}"
INIT="${INIT_SYSTEM:-sysvinit}"

[ -n "$MODELS" ] || MODELS="$DEFAULT_MODEL"

# Security: the API must stay on loopback unless explicitly overridden
case "$LISTEN" in
127.0.0.1:* | localhost:* | \[::1\]:*) ;;
*)
    [ "$ALLOW_NETWORK" = "true" ] ||
        die "knowledge.listen must stay on loopback unless knowledge.allow_network=true"
    log_warn "knowledge API exposed on $LISTEN (allow_network=true)"
    ;;
esac

# Secure by default: never describe an engine we cannot verify
[ -n "$ENGINE_SHA256" ] ||
    die "knowledge.engine_sha256 must be pinned before installing the engine"

case "$ARCH" in
x86_64) OLLAMA_ARCH=amd64 ;;
aarch64) OLLAMA_ARCH=arm64 ;;
*) die "Unsupported architecture for knowledge: $ARCH" ;;
esac

# Baked into the on-demand installer below, for the target to fetch.
ENGINE_URL="https://github.com/ollama/ollama/releases/download/v${ENGINE_VERSION}/ollama-linux-${OLLAMA_ARCH}.tgz"

run_chroot() {
    run_privileged chroot "$LFS" /usr/bin/env -i \
        HOME=/root TERM="${TERM:-dumb}" \
        PATH=/usr/bin:/usr/sbin:/bin:/sbin \
        /bin/bash -c "$1"
}

# Weights cannot be baked in either: /var/lib/ollama/models is inside
# $LFS, so it would ride into the squashfs exactly like the engine did,
# multiplied by the 5.5 GB of a 7b model.
if [ "$PROVISION" = "build-time" ]; then
    die "provision_models=build-time is not supported: the image ships no engine to pull models with (use provision_models=first-boot, then run /usr/lib/knowledge/install-engine.sh on the target)"
fi

# ----------------------------------------------------------------------
# The engine must not exist in the image (idempotent: a $LFS resumed or
# restored from a pre-fix cache still has one, and it would ride into
# the squashfs exactly as it did in nightly #68/#69)
# ----------------------------------------------------------------------
leftovers=()
for path in "$LFS/usr/bin/ollama" "$LFS/usr/lib/ollama" "$LFS/var/lib/ollama/models"; do
    [ -e "$path" ] || continue
    leftovers+=("$path")
done
if [ ${#leftovers[@]} -gt 0 ]; then
    log_warn "removing the engine from the image: ${leftovers[*]}"
    log_warn "the assistant is installed on the target instead, by /usr/lib/knowledge/install-engine.sh"
    run_privileged rm -rf "${leftovers[@]}"
fi
for path in "$LFS/usr/bin/ollama" "$LFS/usr/lib/ollama"; do
    [ ! -e "$path" ] || die "$path is in the image; the engine must not ship"
done

# ----------------------------------------------------------------------
# Dedicated unprivileged user (idempotent)
# ----------------------------------------------------------------------
if ! run_chroot 'getent group ollama >/dev/null'; then
    run_chroot 'groupadd -r ollama'
fi
if ! run_chroot 'getent passwd ollama >/dev/null'; then
    run_chroot 'useradd -r -g ollama -d /var/lib/ollama -s /bin/false -c "Ollama daemon" ollama'
fi
run_privileged mkdir -p "$LFS/var/lib/ollama"

# ----------------------------------------------------------------------
# Wrapper configuration + knowledge CLI
# ----------------------------------------------------------------------
run_privileged mkdir -p "$LFS/etc/knowledge"
cat <<EOF | run_privileged tee "$LFS/etc/knowledge/config.env" >/dev/null
# knowledge - local AI assistant defaults
KNOWLEDGE_MODEL=$DEFAULT_MODEL
KNOWLEDGE_HOST=$LISTEN
EOF

# The wrapper never executes model output: suggestions are printed for
# the user to review, nothing is eval'ed or piped into a shell.
cat <<'WRAPPER' | run_privileged tee "$LFS/usr/bin/knowledge" >/dev/null
#!/bin/bash
# knowledge - local AI assistant (Ollama wrapper, fully offline)
set -euo pipefail

CONFIG=/etc/knowledge/config.env
[ -r "$CONFIG" ] && . "$CONFIG"
MODEL="${KNOWLEDGE_MODEL:-qwen2.5-coder:7b}"
export OLLAMA_HOST="${KNOWLEDGE_HOST:-127.0.0.1:11434}"

usage() {
    cat <<'USAGE'
knowledge - local AI assistant (free, offline, Ollama backend)

Usage:
  knowledge                     interactive chat (default model)
  knowledge "question"          one-shot question
  knowledge -m <model> "..."    explicit model
  knowledge code <file>         explain/review a file
  knowledge shell "task"        suggest a command (never auto-runs)
  knowledge model list|pull|rm  manage local models
  knowledge status              daemon status and installed models
USAGE
}

daemon_hint() {
    echo "The knowledge daemon is not running." >&2
    if [ ! -x /usr/bin/ollama ]; then
        echo "The engine is not installed - the image ships only the assistant's integration." >&2
        echo "Install it: sudo /usr/lib/knowledge/install-engine.sh" >&2
        return 1
    fi
    echo "Start it: sudo /etc/init.d/ollama start (or systemctl start ollama)" >&2
}

if [ "${1:-}" = "-m" ]; then
    [ $# -ge 3 ] || { usage; exit 1; }
    MODEL="$2"; shift 2
fi

case "${1:-}" in
    "")
        ollama run "$MODEL" || daemon_hint
        ;;
    code)
        [ $# -eq 2 ] || { usage; exit 1; }
        [ -r "$2" ] || { echo "Cannot read: $2" >&2; exit 1; }
        { echo "Explain this code:"; cat "$2"; } |
            ollama run "$MODEL" -f /dev/stdin || daemon_hint
        ;;
    shell)
        shift
        printf 'Suggest ONE shell command for: %s\nPrint only the command.\n' "$*" |
            ollama run "$MODEL" -f /dev/stdin || daemon_hint
        echo "(review before running - knowledge never executes commands for you)"
        ;;
    model)
        shift
        case "${1:-list}" in
            list) ollama list ;;
            pull) [ $# -ge 2 ] || { usage; exit 1; }; ollama pull "$2" ;;
            rm)   [ $# -ge 2 ] || { usage; exit 1; }; ollama rm "$2" ;;
            *) usage; exit 1 ;;
        esac
        ;;
    status)
        if ollama list >/dev/null 2>&1; then
            echo "knowledge daemon: running"
            ollama list
        else
            echo "knowledge daemon: not running"
            daemon_hint
            exit 1
        fi
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        printf '%s\n' "$*" | ollama run "$MODEL" -f /dev/stdin || daemon_hint
        ;;
esac
WRAPPER
run_privileged chmod 0755 "$LFS/usr/bin/knowledge"

# ----------------------------------------------------------------------
# Daemon environment + init service (per $INIT_SYSTEM)
# ----------------------------------------------------------------------
cat <<EOF | run_privileged tee "$LFS/etc/sysconfig/ollama" >/dev/null
OLLAMA_HOST=$LISTEN
OLLAMA_MODELS=/var/lib/ollama/models
EOF

case "$INIT" in
systemd)
    cat <<'UNIT' | run_privileged tee "$LFS/etc/systemd/system/ollama.service" >/dev/null
[Unit]
Description=Ollama service (knowledge AI assistant)
After=network.target
# The engine is not part of the image, so this unit has to stay inert
# until install-engine.sh puts a binary down and enables the service.
ConditionPathExists=/usr/bin/ollama

[Service]
User=ollama
Group=ollama
EnvironmentFile=/etc/sysconfig/ollama
ExecStart=/usr/bin/ollama serve
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
    # Deliberately not linked into multi-user.target.wants: enabling a
    # daemon whose binary is absent only adds boot noise.  The installer
    # run on the target enables it as part of installing the engine.
    ;;
*)
    cat <<'INITD' | run_privileged tee "$LFS/etc/init.d/ollama" >/dev/null
#!/bin/sh
### Begin /etc/init.d/ollama
# knowledge AI assistant daemon (Ollama)
### End /etc/init.d/ollama

. /etc/sysconfig/ollama 2>/dev/null || true
export OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"
export OLLAMA_MODELS="${OLLAMA_MODELS:-/var/lib/ollama/models}"
export HOME=/var/lib/ollama

case "$1" in
    start)
        if [ ! -x /usr/bin/ollama ]; then
            echo "Ollama is not installed: sudo /usr/lib/knowledge/install-engine.sh" >&2
            exit 1
        fi
        echo "Starting Ollama (knowledge)..."
        su -s /bin/sh ollama -c "/usr/bin/ollama serve >/var/log/ollama.log 2>&1 &"
        ;;
    stop)
        echo "Stopping Ollama (knowledge)..."
        pkill -u ollama -x ollama || true
        ;;
    restart)
        "$0" stop
        sleep 1
        "$0" start
        ;;
    status)
        if pkill -0 -u ollama -x ollama 2>/dev/null; then
            echo "Ollama (knowledge) is running."
        else
            echo "Ollama (knowledge) is not running."
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
INITD
    run_privileged chmod 0755 "$LFS/etc/init.d/ollama"
    # Deliberately not linked into rcS.d; see the systemd note above.
    ;;
esac

# ----------------------------------------------------------------------
# On-demand engine installer (runs on the target, never during the build)
# ----------------------------------------------------------------------
run_privileged mkdir -p "$LFS/usr/lib/knowledge"
cat <<'ENGINE' | run_privileged tee "$LFS/usr/lib/knowledge/install-engine.sh" >/dev/null
#!/bin/sh
# Installs the Ollama engine that the "knowledge" assistant fronts.
#
# A WBLFS image ships this script and no engine: the runtime is a ~2 GB
# blob (ollama-linux-amd64.tgz is 1.9 GB compressed and is already
# deflate-packed, so it survives xz almost untouched), and running a
# local model is the operator's decision, not the build's.  Run it when
# you want the assistant:
#
#   sudo /usr/lib/knowledge/install-engine.sh
#
# VERSION and SHA256 below are the digest this build pinned, so a
# tampered archive stops before anything is unpacked.
set -eu

VERSION='__VERSION__'
SHA256='__SHA256__'
URL='__URL__'
BUILD_ARCH='__BUILD_ARCH__'

[ "$(id -u)" -eq 0 ] || { echo "install-engine.sh must run as root" >&2; exit 1; }

if [ -x /usr/bin/ollama ]; then
    echo "Ollama is already installed (/usr/bin/ollama) - nothing to do"
    exit 0
fi

case "$(uname -m)" in
x86_64) ARCH=amd64 ;;
aarch64) ARCH=arm64 ;;
*) ARCH=unknown ;;
esac
# The pin belongs to one architecture; verifying it against another
# would reject a perfectly good engine, so refuse instead.
[ "$ARCH" = "$BUILD_ARCH" ] || {
    echo "this image pins the $BUILD_ARCH engine, and $(uname -m) is not that" >&2
    exit 1
}

TMP="$(mktemp /tmp/ollama-engine-XXXXXX)"
trap 'rm -f "$TMP"' EXIT

echo "Downloading Ollama v$VERSION ($ARCH)..."
curl -fsSL --retry 3 --connect-timeout 15 -o "$TMP" "$URL"

if ! echo "$SHA256  $TMP" | sha256sum --status -c -; then
    echo "engine checksum mismatch - refusing to install" >&2
    exit 1
fi

tar -xzf "$TMP" -C /usr
chown ollama:ollama /var/lib/ollama 2>/dev/null || true

# Enabling the daemon is part of installing it: the service files ship
# inert because /usr/bin/ollama does not exist yet.
if [ -d "/run/systemd/system" ]; then
    systemctl enable --now ollama.service
else
    ln -sf /etc/init.d/ollama /etc/rc.d/rcS.d/S60ollama
    /etc/init.d/ollama start
fi

# Weights are the other multi-gigabyte half, so pull them only now.
if [ -x /usr/lib/knowledge/provision-models.sh ]; then
    su -s /bin/sh ollama -c "/usr/lib/knowledge/provision-models.sh" ||
        echo "model provisioning failed - rerun it once online" >&2
fi

echo "Done.  Check the assistant with: knowledge status"
ENGINE
run_privileged sed -i \
    -e "s|__VERSION__|$ENGINE_VERSION|" \
    -e "s|__SHA256__|$ENGINE_SHA256|" \
    -e "s|__URL__|$ENGINE_URL|" \
    -e "s|__BUILD_ARCH__|$OLLAMA_ARCH|" \
    "$LFS/usr/lib/knowledge/install-engine.sh"
run_privileged chmod 0755 "$LFS/usr/lib/knowledge/install-engine.sh"

# ----------------------------------------------------------------------
# Model provisioning
# ----------------------------------------------------------------------
if [ "$PROVISION" = "first-boot" ]; then
    # One-shot service pulls the weights once the engine exists on the
    # target; the marker keeps it from running twice.
    cat <<'PROV' | run_privileged tee "$LFS/usr/lib/knowledge/provision-models.sh" >/dev/null
#!/bin/sh
# One-shot model provisioning for the knowledge assistant.
set -eu
MARKER=/var/lib/ollama/.models-provisioned
[ -e "$MARKER" ] && exit 0
# No engine in the image, so this is a no-op until the operator installs
# one.  Exiting 0 keeps a boot clean rather than failing a unit.
[ -x /usr/bin/ollama ] || {
    echo "knowledge: no engine installed - run sudo /usr/lib/knowledge/install-engine.sh" >&2
    exit 0
}
. /etc/knowledge/config.env 2>/dev/null || true
export OLLAMA_HOST="${KNOWLEDGE_HOST:-127.0.0.1:11434}"
IFS=','
for m in __MODELS__; do
    [ -n "$m" ] || continue
    /usr/bin/ollama pull "$m" ||
        echo "knowledge: failed to pull $m (offline?)" >&2
done
unset IFS
touch "$MARKER"
PROV
    run_privileged sed -i "s|__MODELS__|$MODELS|" "$LFS/usr/lib/knowledge/provision-models.sh"
    run_privileged chmod 0755 "$LFS/usr/lib/knowledge/provision-models.sh"

    case "$INIT" in
    systemd)
        cat <<'UNIT' | run_privileged tee "$LFS/etc/systemd/system/knowledge-provision.service" >/dev/null
[Unit]
Description=One-shot model provisioning for the knowledge assistant
After=ollama.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=ollama
ExecStart=/usr/lib/knowledge/provision-models.sh

[Install]
WantedBy=multi-user.target
UNIT
        # Not enabled here: provisioning needs an engine the image does
        # not carry.  install-engine.sh pulls the models directly, and
        # `systemctl enable knowledge-provision` remains available.
        ;;
    *)
        cat <<'INITD' | run_privileged tee "$LFS/etc/init.d/knowledge-provision" >/dev/null
#!/bin/sh
### Begin /etc/init.d/knowledge-provision
# One-shot model provisioning for the knowledge assistant
### End /etc/init.d/knowledge-provision

case "$1" in
    start)
        echo "Provisioning knowledge models (one-shot, background)..."
        su -s /bin/sh ollama -c \
            "/usr/lib/knowledge/provision-models.sh >/var/log/knowledge-provision.log 2>&1 &"
        ;;
    stop) ;;
    status) echo "one-shot service" ;;
    *) echo "Usage: $0 {start}"; exit 1 ;;
esac
INITD
        run_privileged chmod 0755 "$LFS/etc/init.d/knowledge-provision"
        # Not linked into rcS.d; see the systemd note above.
        ;;
    esac
fi

log_info "knowledge assistant wired - no engine in the image"
log_info "on the target: sudo /usr/lib/knowledge/install-engine.sh (pinned v$ENGINE_VERSION, models: $MODELS)"
exit 0
