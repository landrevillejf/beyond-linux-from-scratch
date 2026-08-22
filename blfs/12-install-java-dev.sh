#!/bin/bash
# blfs/12-install-java-dev.sh
# Java Development Environment installation
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
#
# Fail-fast policy (profile completeness audit): every component of the
# java-dev profile promise (JDK, Maven, Gradle, Tomcat, Jenkins, Docker,
# kubectl) is REQUIRED.  The previous `if ls <tarball>` guards turned a
# missing source into a silent no-op and the stage logged success on an
# image without Java.  A missing archive or a failed verification now
# aborts the stage.
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

# Dynamic source path
SOURCES_HOST="$(dirname "$LFS")/sources"
if [ -d "$SOURCES_HOST" ] && [ "$(ls -A "$SOURCES_HOST" 2>/dev/null)" ]; then
    log_info "Copying sources from $SOURCES_HOST to $LFS/sources"
    run_privileged mkdir -p "$LFS/sources"
    run_privileged cp -rv "$SOURCES_HOST"/* "$LFS/sources/"
    run_privileged chown -R lfs:lfs "$LFS/sources"
fi

cat >"$LFS/install-java.sh" <<'INNEREOF'
#!/bin/bash
set -euo pipefail
cd /sources

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }

fail() {
    log_error "$*"
    exit 1
}

# Resolve a required source archive; abort the stage when missing.
require_file() {
    local pattern="$1" f
    # shellcheck disable=SC2086
    f="$(ls $pattern 2>/dev/null | head -n1 || true)"
    [ -n "$f" ] || fail "required source archive missing: $pattern"
    printf '%s\n' "$f"
}

install_tarball() {
    local archive="$1" target="$2" dir
    dir="$(tar -tf "$archive" | head -n1 | cut -d/ -f1)"
    tar -xf "$archive"
    rm -rf "$target"
    mv "$dir" "$target"
    log_info "$(basename "$archive") installed to $target"
}

# Temurin OpenJDK 21 (required by every other component)
jdk_archive="$(require_file 'OpenJDK21U-jdk_*.tar.gz')"
mkdir -p /usr/lib/java
install_tarball "$jdk_archive" /usr/lib/java/jdk
cat > /etc/profile.d/java.sh << 'EOF'
export JAVA_HOME=/usr/lib/java/jdk
export PATH=$JAVA_HOME/bin:$PATH
EOF
chmod +x /etc/profile.d/java.sh
export JAVA_HOME=/usr/lib/java/jdk
export PATH="$JAVA_HOME/bin:$PATH"
java -version

# Maven
mvn_archive="$(require_file 'apache-maven-*-bin.tar.gz')"
install_tarball "$mvn_archive" /usr/lib/maven
cat > /etc/profile.d/maven.sh << 'EOF'
export MAVEN_HOME=/usr/lib/maven
export PATH=$MAVEN_HOME/bin:$PATH
EOF
chmod +x /etc/profile.d/maven.sh
/usr/lib/maven/bin/mvn --version

# Gradle (zip archive; LFS ships python3, not unzip)
gradle_zip="$(require_file 'gradle-*-bin.zip')"
rm -rf /usr/lib/gradle
python3 -m zipfile -e "$gradle_zip" /usr/lib
mv /usr/lib/gradle-* /usr/lib/gradle
cat > /etc/profile.d/gradle.sh << 'EOF'
export GRADLE_HOME=/usr/lib/gradle
export PATH=$GRADLE_HOME/bin:$PATH
EOF
chmod +x /etc/profile.d/gradle.sh
/usr/lib/gradle/bin/gradle --version

# Tomcat
tomcat_archive="$(require_file 'apache-tomcat-*.tar.gz')"
install_tarball "$tomcat_archive" /usr/lib/tomcat
groupadd -r tomcat 2>/dev/null || true
useradd -r -g tomcat -d /usr/lib/tomcat tomcat 2>/dev/null || true
chown -R tomcat:tomcat /usr/lib/tomcat
[ -x /usr/lib/tomcat/bin/catalina.sh ] || fail "Tomcat install incomplete: catalina.sh missing"

# Jenkins
jenkins_war="$(require_file 'jenkins.war')"
mkdir -p /usr/lib/jenkins
cp "$jenkins_war" /usr/lib/jenkins/jenkins.war
groupadd -r jenkins 2>/dev/null || true
useradd -r -g jenkins -d /usr/lib/jenkins jenkins 2>/dev/null || true
chown -R jenkins:jenkins /usr/lib/jenkins

# Docker (static binaries)
docker_archive="$(require_file 'docker-*.tgz')"
tar -xf "$docker_archive" -C /usr/lib
rm -rf /usr/lib/docker-bin
mv /usr/lib/docker /usr/lib/docker-bin
for tool in docker dockerd containerd containerd-shim-runc-v2 ctr runc docker-init docker-proxy; do
    [ -x "/usr/lib/docker-bin/$tool" ] || fail "Docker install incomplete: $tool missing"
    ln -sf "/usr/lib/docker-bin/$tool" "/usr/bin/$tool"
done
groupadd -r docker 2>/dev/null || true
docker --version

# kubectl
kubectl_bin="$(require_file 'kubectl')"
install -m 755 "$kubectl_bin" /usr/bin/kubectl
kubectl version --client

log_info "Java tools installed."
INNEREOF

run_privileged chmod +x "$LFS/install-java.sh"
run_privileged chroot "$LFS" /bin/bash /install-java.sh

run_privileged umount "$LFS"/dev/pts 2>/dev/null || true
run_privileged umount "$LFS"/dev 2>/dev/null || true
run_privileged umount "$LFS"/proc 2>/dev/null || true
run_privileged umount "$LFS"/sys 2>/dev/null || true
run_privileged umount "$LFS"/run 2>/dev/null || true

log_success "Java development tools installed"
