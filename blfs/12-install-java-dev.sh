#!/bin/bash
# blfs/12-install-java-dev.sh – with dynamic source path
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
set -e

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

if [ "$IN_DOCKER" = true ]; then
    LFS=${LFS:-/output/image}
else
    LFS=${LFS:-/mnt/lfs}
fi

if [ -z "$LFS" ]; then
    log_error "LFS variable not set"
    exit 1
fi

run_privileged() {
    if [ "$(whoami)" = "root" ]; then
        "$@"
    else
        sudo "$@"
    fi
}

log_info "========================================="
log_info "Java Development Environment"
log_info "========================================="

if [ "$IN_DOCKER" = true ]; then
    log_info "Docker mode – skipping Java installation"
    exit 0
fi

log_info "Native mode – installing Java tools inside chroot"

if [ ! -f "$LFS/bin/bash" ]; then
    log_error "/bin/bash not found in $LFS/bin – run lfs-basic first"
    exit 1
fi
if ! run_privileged chroot "$LFS" /bin/bash -c "exit 0" 2>/dev/null; then
    log_error "chroot not working – run lfs-basic first"
    exit 1
fi

run_privileged mount --bind /dev "$LFS"/dev 2>/dev/null || true
run_privileged mount -t devpts devpts "$LFS"/dev/pts 2>/dev/null || true
run_privileged mount -t proc proc "$LFS"/proc 2>/dev/null || true
run_privileged mount -t sysfs sysfs "$LFS"/sys 2>/dev/null || true
run_privileged mount -t tmpfs tmpfs "$LFS"/run 2>/dev/null || true

# --- DYNAMIC SOURCE PATH ---
SOURCES_HOST="$(dirname "$LFS")/sources"
if [ -d "$SOURCES_HOST" ] && [ "$(ls -A "$SOURCES_HOST" 2>/dev/null)" ]; then
    log_info "Copying sources from $SOURCES_HOST to $LFS/sources"
    run_privileged mkdir -p "$LFS/sources"
    run_privileged cp -rv "$SOURCES_HOST"/* "$LFS/sources/"
    run_privileged chown -R lfs:lfs "$LFS/sources"
fi

cat > "$LFS/install-java.sh" << 'INNEREOF'
#!/bin/bash
set -e
cd /sources

install_package() {
    local archive=$1
    local target_dir=$2
    local name=$(basename "$archive" | sed -E 's/\.tar\.[a-z0-9]+$//')
    echo "=== Installing $name ==="
    tar -xf "$archive"
    local dir=$(tar -tf "$archive" | head -1 | cut -d/ -f1)
    mv "$dir" "$target_dir"
    echo "=== $name installed to $target_dir ==="
}

if ls OpenJDK21U-jdk_*.tar.gz 1> /dev/null 2>&1; then
    mkdir -p /opt
    install_package $(ls OpenJDK21U-jdk_*.tar.gz | head -n1) /opt/jdk
    cat > /etc/profile.d/java.sh << 'EOF'
export JAVA_HOME=/opt/jdk
export PATH=$JAVA_HOME/bin:$PATH
EOF
    chmod +x /etc/profile.d/java.sh
    /opt/jdk/bin/java -version
fi

if ls apache-maven-*.tar.gz 1> /dev/null 2>&1; then
    install_package $(ls apache-maven-*.tar.gz | head -n1) /opt/maven
    cat > /etc/profile.d/maven.sh << 'EOF'
export MAVEN_HOME=/opt/maven
export PATH=$MAVEN_HOME/bin:$PATH
EOF
    chmod +x /etc/profile.d/maven.sh
fi

if ls gradle-*.zip 1> /dev/null 2>&1; then
    unzip -q $(ls gradle-*.zip | head -n1) -d /opt
    mv /opt/gradle-* /opt/gradle
    cat > /etc/profile.d/gradle.sh << 'EOF'
export GRADLE_HOME=/opt/gradle
export PATH=$GRADLE_HOME/bin:$PATH
EOF
    chmod +x /etc/profile.d/gradle.sh
fi

if ls apache-tomcat-*.tar.gz 1> /dev/null 2>&1; then
    install_package $(ls apache-tomcat-*.tar.gz | head -n1) /opt/tomcat
    groupadd -r tomcat 2>/dev/null || true
    useradd -r -g tomcat -d /opt/tomcat tomcat 2>/dev/null || true
    chown -R tomcat:tomcat /opt/tomcat
fi

if [ -f jenkins.war ]; then
    mkdir -p /opt/jenkins
    cp jenkins.war /opt/jenkins/
    groupadd -r jenkins 2>/dev/null || true
    useradd -r -g jenkins -d /opt/jenkins jenkins 2>/dev/null || true
    chown -R jenkins:jenkins /opt/jenkins
fi

if ls docker-*.tgz 1> /dev/null 2>&1; then
    tar -xf $(ls docker-*.tgz | head -n1) -C /opt
    mv /opt/docker /opt/docker-bin
    ln -sf /opt/docker-bin/docker /usr/local/bin/docker
    ln -sf /opt/docker-bin/dockerd /usr/local/bin/dockerd
    groupadd -r docker 2>/dev/null || true
fi

if [ -f kubectl ]; then
    install -m 755 kubectl /usr/local/bin/kubectl
fi

echo "Java tools installed."
INNEREOF

run_privileged chmod +x "$LFS/install-java.sh"
run_privileged chroot "$LFS" /bin/bash /install-java.sh

run_privileged umount "$LFS"/dev/pts 2>/dev/null || true
run_privileged umount "$LFS"/dev 2>/dev/null || true
run_privileged umount "$LFS"/proc 2>/dev/null || true
run_privileged umount "$LFS"/sys 2>/dev/null || true
run_privileged umount "$LFS"/run 2>/dev/null || true

log_success "Java development tools installed"