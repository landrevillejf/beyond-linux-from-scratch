#!/usr/bin/env bash
# Java Development Profile for LFS / BLFS
# Complete Java development environment setup
# Author : Jean-Francois Landreville, landrevillejf@protonmail.com, 2026.
#
# This script must be run as root (or with sudo).
# It installs a full Java development stack into /opt.

set -euo pipefail

# ----------------------------------------------------------------------
# Colors and logging
# ----------------------------------------------------------------------
C_RED='\033[0;31m' C_GREEN='\033[0;32m' C_YELLOW='\033[1;33m' C_BLUE='\033[0;34m' C_NC='\033[0m'
log_info() { echo -e "${C_GREEN}[INFO]${C_NC} $*"; }
log_warning() { echo -e "${C_YELLOW}[WARNING]${C_NC} $*"; }
log_error() { echo -e "${C_RED}[ERROR]${C_NC} $*" >&2; }
log_success() { echo -e "${C_BLUE}[SUCCESS]${C_NC} $*"; }

# ----------------------------------------------------------------------
# Configuration (can be overridden by environment)
# ----------------------------------------------------------------------
JAVA_VERSION="${JAVA_VERSION:-21.0.8}"
MAVEN_VERSION="${MAVEN_VERSION:-3.9.9}"
GRADLE_VERSION="${GRADLE_VERSION:-8.13}"
TOMCAT_VERSION="${TOMCAT_VERSION:-10.1.39}"
NODE_VERSION="${NODE_VERSION:-22.14.0}"
DOCKER_VERSION="${DOCKER_VERSION:-27.4.1}"
JENKINS_VERSION="${JENKINS_VERSION:-2.492.2}"
KUBECTL_VERSION="${KUBECTL_VERSION:-1.32.3}"
SPRING_BOOT_VERSION="${SPRING_BOOT_VERSION:-3.2.0}"

JAVA_HOME="/opt/jdk-${JAVA_VERSION}"
MAVEN_HOME="/opt/maven"
GRADLE_HOME="/opt/gradle"
TOMCAT_HOME="/opt/tomcat"
NODE_HOME="/opt/node"

LFS_USER_HOME="${LFS_USER_HOME:-/home/lfsuser}"
NUM_JOBS="${NUM_JOBS:-$(nproc)}"

# ----------------------------------------------------------------------
# System helpers – package installation on the host (if needed)
# ----------------------------------------------------------------------
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "${ID}"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    elif [ -f /etc/redhat-release ]; then
        echo "rhel"
    else
        echo "unknown"
    fi
}

install_host_packages() {
    local distro="$1" pkgs=("${@:2}")
    log_info "Installing host packages: ${pkgs[*]}"
    case "$distro" in
    debian | ubuntu)
        apt-get update -qq
        apt-get install -y -qq "${pkgs[@]}"
        ;;
    fedora | rhel | centos | rocky)
        if command -v dnf &>/dev/null; then
            dnf install -y "${pkgs[@]}"
        else yum install -y "${pkgs[@]}"; fi
        ;;
    arch | manjaro) pacman -Syu --noconfirm "${pkgs[@]}" ;;
    alpine) apk add "${pkgs[@]}" ;;
    *)
        log_error "Unsupported distro. Install manually: ${pkgs[*]}"
        exit 1
        ;;
    esac
}

ensure_command() {
    local cmd="$1" pkg="$2"
    if ! command -v "$cmd" &>/dev/null; then
        log_warning "'$cmd' not found. Installing via package manager..."
        install_host_packages "$(detect_distro)" "$pkg"
    fi
}

# ----------------------------------------------------------------------
# Download helper with retry and optional checksum
# ----------------------------------------------------------------------
download() {
    local url="$1" dest="$2" sha256="${3:-}" retries=3
    if [ -f "$dest" ]; then
        log_info "Already downloaded: $(basename "$dest")"
        if [ -n "$sha256" ]; then
            echo "$sha256  $dest" | sha256sum -c --quiet 2>/dev/null && return 0
            log_warning "Checksum mismatch, re-downloading."
        else
            return 0
        fi
    fi
    for ((i = 1; i <= retries; i++)); do
        log_info "Downloading $(basename "$dest") (attempt $i/$retries)..."
        if wget -q --show-progress "$url" -O "$dest"; then
            if [ -n "$sha256" ]; then
                echo "$sha256  $dest" | sha256sum -c --quiet && return 0
                log_error "Checksum verification failed for $(basename "$dest")"
                return 1
            fi
            return 0
        fi
        log_warning "Download attempt $i failed."
        sleep 2
    done
    log_error "Failed to download $url"
    return 1
}

# ----------------------------------------------------------------------
# Init system detection and service creation
# ----------------------------------------------------------------------
init_system() {
    if command -v systemctl &>/dev/null; then echo "systemd"; else echo "sysvinit"; fi
}

create_service() {
    local name="$1" description="$2" exec_start="$3" exec_stop="${4:-}" \
        user="${5:-root}" group="${6:-root}" env_vars="${7:-}" type="${8:-forking}"
    case "$(init_system)" in
    systemd)
        cat >"/etc/systemd/system/${name}.service" <<EOF
[Unit]
Description=${description}
After=network.target

[Service]
Type=${type}
User=${user}
Group=${group}
ExecStart=${exec_start}
ExecStop=${exec_stop}
${env_vars:+"Environment=${env_vars}"}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable "${name}.service" 2>/dev/null || true
        ;;
    sysvinit)
        cat >"/etc/init.d/${name}" <<EOF
#!/bin/bash
### BEGIN INIT INFO
# Provides:          ${name}
# Required-Start:    \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: ${description}
# Description:       ${description}
### END INIT INFO

case "\$1" in
    start)
        echo "Starting ${name}..."
        ${exec_start} &
        ;;
    stop)
        echo "Stopping ${name}..."
        ${exec_stop}
        ;;
    restart)
        \$0 stop; sleep 2; \$0 start ;;
    status)
        pidof \$(basename \$(echo ${exec_start} | awk '{print \$1}')) >/dev/null && echo "${name} is running" || echo "${name} is not running"
        ;;
    *) echo "Usage: \$0 {start|stop|restart|status}"; exit 1 ;;
esac
exit 0
EOF
        chmod +x "/etc/init.d/${name}"
        # enable in runlevels
        update-rc.d "${name}" defaults 2>/dev/null || true
        ;;
    esac
}

# ----------------------------------------------------------------------
# Prerequisites check – run as root
# ----------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root. Use sudo."
    exit 1
fi

mkdir -p /sources /opt
ensure_command wget wget
ensure_command tar tar
ensure_command unzip unzip
ensure_command groupadd shadow # usually present on LFS

# ----------------------------------------------------------------------
# 1. Java
# ----------------------------------------------------------------------
install_java() {
    log_info "Installing OpenJDK ${JAVA_VERSION} (Eclipse Temurin)"
    local jdk_url="https://github.com/adoptium/temurin21-binaries/releases/download/jdk-${JAVA_VERSION}%2B9/OpenJDK21U-jdk_x64_linux_hotspot_${JAVA_VERSION}_9.tar.gz"
    local jdk_file="/sources/jdk-${JAVA_VERSION}.tar.gz"
    local sha256=""

    download "$jdk_url" "$jdk_file" "$sha256"
    tar -xzf "$jdk_file" -C /opt
    # Move to expected name
    mv /opt/jdk-${JAVA_VERSION}* "$JAVA_HOME" 2>/dev/null || true
    ln -sf "$JAVA_HOME" /opt/jdk-latest
    cat >/etc/profile.d/java.sh <<EOF
export JAVA_HOME=${JAVA_HOME}
export PATH=\$JAVA_HOME/bin:\$PATH
EOF
    chmod 644 /etc/profile.d/java.sh
    # Verify
    ${JAVA_HOME}/bin/java -version 2>&1 | grep -q "version" || {
        log_error "Java verification failed"
        return 1
    }
    log_success "Java ${JAVA_VERSION} installed"
}

# ----------------------------------------------------------------------
# 2. Maven
# ----------------------------------------------------------------------
install_maven() {
    log_info "Installing Maven ${MAVEN_VERSION}"
    local url="https://dlcdn.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz"
    local file="/sources/apache-maven-${MAVEN_VERSION}.tar.gz"
    download "$url" "$file"
    tar -xzf "$file" -C /opt
    ln -sf "/opt/apache-maven-${MAVEN_VERSION}" "$MAVEN_HOME"
    mkdir -p /opt/maven/repository
    chmod 755 /opt/maven/repository
    chown root:root /opt/maven/repository
    cat >/etc/profile.d/maven.sh <<EOF
export MAVEN_HOME=${MAVEN_HOME}
export PATH=\$MAVEN_HOME/bin:\$PATH
EOF
    chmod 644 /etc/profile.d/maven.sh
    log_success "Maven installed"
}

# ----------------------------------------------------------------------
# 3. Gradle
# ----------------------------------------------------------------------
install_gradle() {
    log_info "Installing Gradle ${GRADLE_VERSION}"
    local url="https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip"
    local file="/sources/gradle-${GRADLE_VERSION}-bin.zip"
    download "$url" "$file"
    unzip -q "$file" -d /opt
    ln -sf "/opt/gradle-${GRADLE_VERSION}" "$GRADLE_HOME"
    cat >/etc/profile.d/gradle.sh <<EOF
export GRADLE_HOME=${GRADLE_HOME}
export PATH=\$GRADLE_HOME/bin:\$PATH
EOF
    chmod 644 /etc/profile.d/gradle.sh
    log_success "Gradle installed"
}

# ----------------------------------------------------------------------
# 4. Tomcat
# ----------------------------------------------------------------------
install_tomcat() {
    log_info "Installing Apache Tomcat ${TOMCAT_VERSION}"
    groupadd -r tomcat 2>/dev/null || true
    useradd -r -g tomcat -d "$TOMCAT_HOME" -s /bin/false tomcat 2>/dev/null || true

    local url="https://dlcdn.apache.org/tomcat/tomcat-10/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz"
    local file="/sources/apache-tomcat-${TOMCAT_VERSION}.tar.gz"
    download "$url" "$file"
    tar -xzf "$file" -C /opt
    ln -sf "/opt/apache-tomcat-${TOMCAT_VERSION}" "$TOMCAT_HOME"
    chown -R tomcat:tomcat "$TOMCAT_HOME"
    chmod +x "$TOMCAT_HOME"/bin/*.sh

    create_service "tomcat" "Apache Tomcat" \
        "${TOMCAT_HOME}/bin/startup.sh" \
        "${TOMCAT_HOME}/bin/shutdown.sh" \
        tomcat tomcat \
        "JAVA_HOME=${JAVA_HOME}"
    log_success "Tomcat installed"
}

# ----------------------------------------------------------------------
# 5. Node.js
# ----------------------------------------------------------------------
install_nodejs() {
    log_info "Installing Node.js ${NODE_VERSION}"
    local url="https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"
    local file="/sources/node-v${NODE_VERSION}.tar.xz"
    download "$url" "$file"
    tar -xJf "$file" -C /opt
    ln -sf "/opt/node-v${NODE_VERSION}-linux-x64" "$NODE_HOME"
    cat >/etc/profile.d/node.sh <<EOF
export NODE_HOME=${NODE_HOME}
export PATH=\$NODE_HOME/bin:\$PATH
EOF
    chmod 644 /etc/profile.d/node.sh
    . /etc/profile.d/node.sh
    npm install -g npm@latest yarn pnpm typescript ts-node nodemon pm2 2>/dev/null || true
    log_success "Node.js installed"
}

# ----------------------------------------------------------------------
# 6. Docker (static binary)
# ----------------------------------------------------------------------
install_docker() {
    log_info "Installing Docker ${DOCKER_VERSION}"
    local url="https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz"
    local file="/sources/docker-${DOCKER_VERSION}.tgz"
    download "$url" "$file"
    tar -xzf "$file" -C /opt
    ln -sf /opt/docker/docker /usr/local/bin/docker
    ln -sf /opt/docker/dockerd /usr/local/bin/dockerd
    groupadd -r docker 2>/dev/null || true
    # shellcheck disable=SC2016
    create_service "docker" "Docker Engine" \
        "/usr/local/bin/dockerd" \
        '/bin/kill -s HUP $(pidof dockerd)' root docker
    log_success "Docker installed"
}

# ----------------------------------------------------------------------
# 7. kubectl
# ----------------------------------------------------------------------
install_kubectl() {
    log_info "Installing kubectl ${KUBECTL_VERSION}"
    local url="https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    local file="/sources/kubectl-${KUBECTL_VERSION}"
    download "$url" "$file"
    install -m 755 "$file" /usr/local/bin/kubectl
    log_success "kubectl installed"
}

# ----------------------------------------------------------------------
# 8. Jenkins
# ----------------------------------------------------------------------
install_jenkins() {
    log_info "Installing Jenkins ${JENKINS_VERSION}"
    groupadd -r jenkins 2>/dev/null || true
    useradd -r -g jenkins -d /var/lib/jenkins -s /bin/false jenkins 2>/dev/null || true
    mkdir -p /var/lib/jenkins /var/log/jenkins /var/cache/jenkins
    chown -R jenkins:jenkins /var/lib/jenkins /var/log/jenkins /var/cache/jenkins

    local url="https://get.jenkins.io/war/${JENKINS_VERSION}/jenkins.war"
    local file="/sources/jenkins-${JENKINS_VERSION}.war"
    download "$url" "$file"
    mkdir -p /opt/jenkins
    cp "$file" /opt/jenkins/jenkins.war
    create_service "jenkins" "Jenkins CI" \
        "${JAVA_HOME}/bin/java -jar /opt/jenkins/jenkins.war --httpPort=8080" \
        "" jenkins jenkins \
        "JAVA_HOME=${JAVA_HOME}" forking
    log_success "Jenkins installed"
}

# ----------------------------------------------------------------------
# 9. Spring Boot CLI
# ----------------------------------------------------------------------
install_spring_boot_cli() {
    log_info "Installing Spring Boot CLI ${SPRING_BOOT_VERSION}"
    local url="https://repo.spring.io/release/org/springframework/boot/spring-boot-cli/${SPRING_BOOT_VERSION}/spring-boot-cli-${SPRING_BOOT_VERSION}-bin.tar.gz"
    local file="/sources/spring-boot-cli-${SPRING_BOOT_VERSION}.tar.gz"
    download "$url" "$file"
    tar -xzf "$file" -C /opt
    ln -sf "/opt/spring-${SPRING_BOOT_VERSION}" /opt/spring-boot-cli
    cat >/etc/profile.d/spring.sh <<EOF
export SPRING_HOME=/opt/spring-boot-cli
export PATH=\$SPRING_HOME/bin:\$PATH
EOF
    chmod 644 /etc/profile.d/spring.sh
    log_success "Spring Boot CLI installed"
}

# ----------------------------------------------------------------------
# Java optimizations and aliases (global)
# ----------------------------------------------------------------------
configure_developer_env() {
    log_info "Setting up Java developer environment"
    cat >/etc/profile.d/java-dev.sh <<'EOF'
# Java developer environment
export JAVA_OPTS="-server -Xms2g -Xmx4g -XX:+UseG1GC -XX:+UseStringDeduplication"
export MAVEN_OPTS="-Xms512m -Xmx2g -XX:MetaspaceSize=256m -XX:MaxMetaspaceSize=512m"
export GRADLE_OPTS="-Dorg.gradle.daemon=true -Dorg.gradle.parallel=true -Dorg.gradle.caching=true -Xms512m -Xmx2g"

# Aliases and functions
alias mci='mvn clean install'
alias mcp='mvn clean package'
alias mct='mvn clean test'
alias gb='gradle build'
alias gt='gradle test'
alias k='kubectl'
alias d='docker'

new-maven-project() {
    mvn archetype:generate -DgroupId=com.example -DartifactId="$1" -DarchetypeArtifactId=maven-archetype-quickstart -DinteractiveMode=false
    cd "$1"
}
new-spring-project() {
    spring init --dependencies=web,lombok,devtools --groupId=com.example --artifactId="$1" "$1"
    cd "$1"
}
java-run() { javac "$1.java" && java "$1"; }
dev-status() {
    echo "Java: $(java -version 2>&1 | head -1)"
    echo "Maven: $(mvn -version 2>&1 | head -1)"
    echo "Docker: $(docker --version 2>/dev/null || echo 'not installed')"
}
EOF
    # Also copy to lfsuser home if exists
    if [ -d "$LFS_USER_HOME" ]; then
        cp /etc/profile.d/java-dev.sh "$LFS_USER_HOME/.java-dev-aliases.sh" 2>/dev/null || true
        echo "source ~/.java-dev-aliases.sh" >>"$LFS_USER_HOME/.bashrc"
        chown lfsuser:lfsuser "$LFS_USER_HOME/.java-dev-aliases.sh" "$LFS_USER_HOME/.bashrc" 2>/dev/null || true
    fi
}

# ----------------------------------------------------------------------
# Cleanup
# ----------------------------------------------------------------------
cleanup() {
    log_info "Cleaning up downloaded archives and temporary directories"
    cd /sources
    rm -rf jdk-*.tar.gz apache-maven-*.tar.gz gradle-*.zip apache-tomcat-*.tar.gz \
        node-v*.tar.xz docker-*.tgz jenkins-*.war spring-boot-cli-*.tar.gz kubectl-*
    # Remove extracted directories inside /sources if any
    find /sources -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} + 2>/dev/null || true
    log_success "Cleanup done"
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
main() {
    log_info "Java Development Environment Installation"
    install_java
    install_maven
    install_gradle
    install_tomcat
    install_nodejs
    install_docker
    install_kubectl
    install_jenkins
    install_spring_boot_cli
    configure_developer_env
    cleanup
    log_success "All components installed successfully"
}

main "$@"
