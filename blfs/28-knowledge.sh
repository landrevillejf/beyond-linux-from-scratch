#!/bin/bash
set -euo pipefail
#======================================================================
# 28-knowledge.sh - optional local AI assistant "knowledge" (Ollama)
#
# Installs a free, open source, fully local AI assistant into the
# built system. Opt-in: this stage is a no-op unless
# LFS_CONFIG_KNOWLEDGE_ENABLED=true (config/build.conf "knowledge"
# section, or the --with-knowledge CLI flag).
#
# Book deviation (documented in docs/KNOWLEDGE_DESIGN.md): Ollama is
# not a BLFS package, so the official prebuilt release tarball is
# installed, pinned by version AND by a mandatory sha256 checksum
# (knowledge.engine_sha256). The stage refuses to install anything
# without a pinned checksum, and aborts on any mismatch.
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

# Secure by default: never unpack an engine without a pinned checksum
[ -n "$ENGINE_SHA256" ] ||
    die "knowledge.engine_sha256 must be pinned before installing the engine"

case "$ARCH" in
x86_64) OLLAMA_ARCH=amd64 ;;
aarch64) OLLAMA_ARCH=arm64 ;;
*) die "Unsupported architecture for knowledge: $ARCH" ;;
esac

ENGINE_URL="https://github.com/ollama/ollama/releases/download/v${ENGINE_VERSION}/ollama-linux-${OLLAMA_ARCH}.tgz"
TARBALL="$LFS/sources/ollama-linux-${OLLAMA_ARCH}-${ENGINE_VERSION}.tgz"

run_chroot() {
    chroot "$LFS" /usr/bin/env -i \
        HOME=/root TERM="${TERM:-dumb}" \
        PATH=/usr/bin:/usr/sbin:/bin:/sbin \
        /bin/bash -c "$1"
}

# Rough GGUF weight budget per model family (kilobytes)
model_size_kb() {
    case "$1" in
    *0.5b* | *1b* | *3b*) echo 2621440 ;; # ~2.5 GB
    *7b* | *8b*) echo 5767168 ;;          # ~5.5 GB
    *) echo 8388608 ;;                    # ~8 GB, conservative
    esac
}

# ----------------------------------------------------------------------
# Disk preflight: build-time provisioning bakes weights into the image
# ----------------------------------------------------------------------
if [ "$PROVISION" = "build-time" ]; then
    required_kb=2097152 # engine + runners ~2 GB
    IFS=',' read -r -a preflight_models <<<"$MODELS"
    for m in "${preflight_models[@]}"; do
        required_kb=$((required_kb + $(model_size_kb "$m")))
    done
    avail_kb=$(df -Pk "$LFS" | awk 'NR==2 {print $4}')
    if [ "$avail_kb" -lt "$required_kb" ]; then
        die "Not enough disk for build-time models: need $((required_kb / 1024)) MB, have $((avail_kb / 1024)) MB (use provision_models=first-boot or grow filesystem.size_mb)"
    fi
fi

# ----------------------------------------------------------------------
# Engine install (idempotent: skip when the binary is already there)
# ----------------------------------------------------------------------
if [ ! -x "$LFS/usr/bin/ollama" ]; then
    mkdir -p "$LFS/sources"
    log_info "Downloading Ollama v$ENGINE_VERSION ($OLLAMA_ARCH)"
    curl -fsSL --retry 3 --connect-timeout 15 -o "$TARBALL.part" "$ENGINE_URL"
    mv "$TARBALL.part" "$TARBALL"

    actual_sha256=$(sha256sum "$TARBALL" | awk '{print $1}')
    if [ "$actual_sha256" != "$ENGINE_SHA256" ]; then
        rm -f "$TARBALL"
        die "Engine sha256 mismatch: expected $ENGINE_SHA256, got $actual_sha256"
    fi
    log_info "Engine checksum verified"

    tar -xzf "$TARBALL" -C "$LFS/usr"
    log_info "Engine installed into /usr"
else
    log_info "Engine already installed - skipping download"
fi

# ----------------------------------------------------------------------
# Dedicated unprivileged user (idempotent)
# ----------------------------------------------------------------------
if ! run_chroot 'getent group ollama >/dev/null'; then
    run_chroot 'groupadd -r ollama'
fi
if ! run_chroot 'getent passwd ollama >/dev/null'; then
    run_chroot 'useradd -r -g ollama -d /var/lib/ollama -s /bin/false -c "Ollama daemon" ollama'
fi
mkdir -p "$LFS/var/lib/ollama"

# ----------------------------------------------------------------------
# Wrapper configuration + knowledge CLI
# ----------------------------------------------------------------------
mkdir -p "$LFS/etc/knowledge"
cat >"$LFS/etc/knowledge/config.env" <<EOF
# knowledge - local AI assistant defaults
KNOWLEDGE_MODEL=$DEFAULT_MODEL
KNOWLEDGE_HOST=$LISTEN
EOF

# The wrapper never executes model output: suggestions are printed for
# the user to review, nothing is eval'ed or piped into a shell.
cat >"$LFS/usr/bin/knowledge" <<'WRAPPER'
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
chmod 0755 "$LFS/usr/bin/knowledge"

# ----------------------------------------------------------------------
# Daemon environment + init service (per $INIT_SYSTEM)
# ----------------------------------------------------------------------
cat >"$LFS/etc/sysconfig/ollama" <<EOF
OLLAMA_HOST=$LISTEN
OLLAMA_MODELS=/var/lib/ollama/models
EOF

case "$INIT" in
systemd)
    cat >"$LFS/etc/systemd/system/ollama.service" <<'UNIT'
[Unit]
Description=Ollama service (knowledge AI assistant)
After=network.target

[Service]
User=ollama
Group=ollama
EnvironmentFile=/etc/sysconfig/ollama
ExecStart=/usr/bin/ollama serve
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
    mkdir -p "$LFS/etc/systemd/system/multi-user.target.wants"
    ln -sf ../ollama.service \
        "$LFS/etc/systemd/system/multi-user.target.wants/ollama.service"
    ;;
*)
    cat >"$LFS/etc/init.d/ollama" <<'INITD'
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
    chmod 0755 "$LFS/etc/init.d/ollama"
    mkdir -p "$LFS/etc/rc.d/rcS.d"
    ln -sf /etc/init.d/ollama "$LFS/etc/rc.d/rcS.d/S60ollama"
    ;;
esac

# ----------------------------------------------------------------------
# Model provisioning
# ----------------------------------------------------------------------
if [ "$PROVISION" = "first-boot" ]; then
    # One-shot service pulls the weights after installation, when the
    # machine has network; the marker keeps it from running twice.
    mkdir -p "$LFS/usr/lib/knowledge"
    cat >"$LFS/usr/lib/knowledge/provision-models.sh" <<'PROV'
#!/bin/sh
# One-shot model provisioning for the knowledge assistant.
set -eu
MARKER=/var/lib/ollama/.models-provisioned
[ -e "$MARKER" ] && exit 0
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
    sed -i "s|__MODELS__|$MODELS|" "$LFS/usr/lib/knowledge/provision-models.sh"
    chmod 0755 "$LFS/usr/lib/knowledge/provision-models.sh"

    case "$INIT" in
    systemd)
        cat >"$LFS/etc/systemd/system/knowledge-provision.service" <<'UNIT'
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
        ln -sf ../knowledge-provision.service \
            "$LFS/etc/systemd/system/multi-user.target.wants/knowledge-provision.service"
        ;;
    *)
        cat >"$LFS/etc/init.d/knowledge-provision" <<'INITD'
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
        chmod 0755 "$LFS/etc/init.d/knowledge-provision"
        ln -sf /etc/init.d/knowledge-provision \
            "$LFS/etc/rc.d/rcS.d/S61knowledge-provision"
        ;;
    esac
fi

if [ "$PROVISION" = "build-time" ]; then
    log_info "Provisioning models at build time"
    run_chroot 'chown -R ollama:ollama /var/lib/ollama'
    chroot "$LFS" /usr/bin/env -i \
        HOME=/var/lib/ollama \
        PATH=/usr/bin:/usr/sbin:/bin:/sbin \
        /bin/sh -c 'su -s /bin/sh ollama -c "OLLAMA_HOST=127.0.0.1:11434 /usr/bin/ollama serve" >/var/log/ollama-build.log 2>&1 &'

    daemon_up=false
    for _ in $(seq 1 30); do
        if run_chroot 'curl -fsS http://127.0.0.1:11434/ >/dev/null 2>&1'; then
            daemon_up=true
            break
        fi
        sleep 1
    done
    "$daemon_up" || die "ollama daemon did not start for build-time model provisioning"

    IFS=',' read -r -a provision_models <<<"$MODELS"
    for m in "${provision_models[@]}"; do
        log_info "Pulling model: $m"
        run_chroot "su -s /bin/sh ollama -c '/usr/bin/ollama pull $m'" ||
            die "Failed to pull model $m at build time"
    done
    run_chroot 'pkill -u ollama -x ollama' || true
fi

log_info "knowledge assistant installed (engine v$ENGINE_VERSION, model: $DEFAULT_MODEL)"
exit 0
