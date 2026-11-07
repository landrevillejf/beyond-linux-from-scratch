#!/bin/bash
# Server Profile for LFS
# Optimized for production server workloads

set -e

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_success() { echo -e "\033[0;34m[SUCCESS]\033[0m $1"; }
log_warning() { echo -e "\033[1;33m[WARNING]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }

# ============================================================================
# CONFIGURATION
# ============================================================================

NUM_JOBS=${NUM_JOBS:-$(nproc)}
SERVER_TYPE="${SERVER_TYPE:-general}" # general, web, database, container, mail
# shellcheck disable=SC2034
PACKAGE_LIST="profiles/server/packages.list"

# ============================================================================
# SERVER OPTIMIZED KERNEL CONFIGURATION
# ============================================================================
configure_server_kernel() {
    log_info "Configuring server-optimized kernel..."

    cat >/etc/sysctl.d/99-server.conf <<'EOF'
# ============================================================================
# SERVER KERNEL OPTIMIZATIONS
# ============================================================================

# Network optimizations
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.core.rmem_default = 65536
net.core.wmem_default = 65536
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728

net.ipv4.tcp_rmem = 4096 65536 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 500000

net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# File system
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192

# Memory
vm.swappiness = 10
vm.dirty_ratio = 30
vm.dirty_background_ratio = 5
vm.vfs_cache_pressure = 50
vm.overcommit_memory = 0
vm.max_map_count = 262144

# Process limits
kernel.pid_max = 65536
kernel.threads-max = 65536
EOF

    sysctl -p /etc/sysctl.d/99-server.conf

    log_success "Server kernel configured"
}

# ============================================================================
# CONFIGURE SYSTEM LIMITS
# ============================================================================
configure_system_limits() {
    log_info "Configuring system limits for server..."

    cat >/etc/security/limits.d/99-server.conf <<'EOF'
# Server limits
* soft nofile 65535
* hard nofile 65535
* soft nproc 65535
* hard nproc 65535
* soft memlock unlimited
* hard memlock unlimited
root soft nofile 65535
root hard nofile 65535
EOF

    # PAM limits
    if [ -f /etc/pam.d/common-session ]; then
        grep -q "pam_limits.so" /etc/pam.d/common-session ||
            echo "session required pam_limits.so" >>/etc/pam.d/common-session
    fi

    log_success "System limits configured"
}

# ============================================================================
# CONFIGURE SSH FOR SERVER
# ============================================================================
configure_ssh_server() {
    log_info "Configuring SSH server (hardened)..."

    cat >/etc/ssh/sshd_config <<'EOF'
# Server SSH Configuration
Port 22
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

# Security
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes

# Session
X11Forwarding no
PrintMotd no
PrintLastLog yes
TCPKeepAlive yes
ClientAliveInterval 300
ClientAliveCountMax 3
MaxAuthTries 3
MaxSessions 10
LoginGraceTime 30

# Logging
SyslogFacility AUTH
LogLevel VERBOSE

# Ciphers (strong only)
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256

# Disable legacy protocols
Protocol 2
PermitEmptyPasswords no
HostbasedAuthentication no
IgnoreRhosts yes
StrictModes yes

# Allow specific users (optional)
AllowUsers lfsuser root
EOF

    # Generate host keys if missing
    if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
        ssh-keygen -t rsa -b 4096 -f /etc/ssh/ssh_host_rsa_key -N ""
        ssh-keygen -t ecdsa -b 521 -f /etc/ssh/ssh_host_ecdsa_key -N ""
        ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N ""
    fi

    # Restart SSH if running
    if command -v systemctl &>/dev/null; then
        systemctl restart sshd
        systemctl enable sshd
    fi

    log_success "SSH server configured"
}

# ============================================================================
# CONFIGURE FIREWALL (Server)
# ============================================================================
configure_firewall() {
    log_info "Configuring server firewall..."

    # Ensure firewall is installed
    if command -v nft &>/dev/null; then
        cat >/etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        # Allow loopback
        iif lo accept

        # Allow established connections
        ct state established,related accept

        # Allow SSH
        tcp dport 22 accept

        # Allow HTTP/HTTPS (for web servers)
        tcp dport { 80, 443 } accept

        # Allow ICMP (ping)
        ip protocol icmp icmp type { echo-request, echo-reply } accept
        ip6 nexthdr icmpv6 icmpv6 type { echo-request, echo-reply } accept

        # Allow DNS (if DNS server)
        # udp dport 53 accept
        # tcp dport 53 accept

        # Log dropped packets
        log prefix "nftables INPUT drop: " counter drop
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF

        systemctl enable nftables
        nft -f /etc/nftables.conf
    fi

    log_success "Firewall configured"
}

# ============================================================================
# INSTALL FAIL2BAN
# ============================================================================
install_fail2ban() {
    log_info "Installing and configuring fail2ban..."

    if command -v fail2ban-server &>/dev/null; then
        # Configure fail2ban
        cat >/etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
destemail = root@localhost
action = %(action_mwl)s

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 7200

[sshd-ddos]
enabled = true
port = ssh
filter = sshd-ddos
logpath = /var/log/auth.log
maxretry = 2

[nginx-http-auth]
enabled = true
port = http,https
filter = nginx-http-auth
logpath = /var/log/nginx/error.log

[apache-auth]
enabled = true
port = http,https
filter = apache-auth
logpath = /var/log/apache2/error.log
EOF

        systemctl enable fail2ban
        systemctl start fail2ban
    fi

    log_success "Fail2ban configured"
}

# ============================================================================
# CONFIGURE LOGGING (Server)
# ============================================================================
configure_logging() {
    log_info "Configuring centralized logging..."

    # Configure rsyslog for server
    cat >/etc/rsyslog.conf <<'EOF'
# rsyslog server configuration
module(load="imuxsock")
module(load="imklog")
module(load="imudp")
module(load="imtcp")

# UDP syslog reception
input(type="imudp" port="514")

# TCP syslog reception
input(type="imtcp" port="514")

# Templates
$template RemoteLogs,"/var/log/remote/%HOSTNAME%/%PROGRAMNAME%.log"
*.* ?RemoteLogs

# Local logs
auth,authpriv.*                 /var/log/auth.log
*.*;auth,authpriv.none          -/var/log/syslog
cron.*                          /var/log/cron.log
daemon.*                        -/var/log/daemon.log
kern.*                          -/var/log/kern.log
lpr.*                           -/var/log/lpr.log
mail.*                          -/var/log/mail.log
user.*                          -/var/log/user.log

# Log rotation
$ActionFileDefaultTemplate RSYSLOG_TraditionalFileFormat
$RepeatedMsgReduction on
$FileOwner root
$FileGroup adm
$FileCreateMode 0640
$DirCreateMode 0755
$Umask 0022
$WorkDirectory /var/spool/rsyslog

# Discard emergency messages
*.emerg :omusrmsg:*
EOF

    systemctl restart rsyslog
    systemctl enable rsyslog

    # Configure logrotate
    cat >/etc/logrotate.d/server-logs <<'EOF'
/var/log/remote/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 0640 root adm
    sharedscripts
    postrotate
        /usr/bin/systemctl kill -s HUP rsyslog
    endscript
}
EOF

    log_success "Logging configured"
}

# ============================================================================
# CONFIGURE MONITORING
# ============================================================================
configure_monitoring() {
    log_info "Configuring monitoring tools..."

    # Node Exporter for Prometheus
    if command -v node_exporter &>/dev/null; then
        cat >/etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=/usr/local/bin/node_exporter
Restart=always

[Install]
WantedBy=multi-user.target
EOF

        systemctl enable node_exporter
        systemctl start node_exporter
    fi

    # Netdata for real-time monitoring
    if command -v netdata &>/dev/null; then
        systemctl enable netdata
        systemctl start netdata
    fi

    log_success "Monitoring configured"
}

# ============================================================================
# OPTIMIZE DATABASE (If installed)
# ============================================================================
optimize_database() {
    log_info "Optimizing database settings..."

    # PostgreSQL optimization
    if command -v postgres &>/dev/null; then
        cat >>/etc/postgresql/*/main/postgresql.conf <<'EOF'
# Performance tuning
shared_buffers = '2GB'
effective_cache_size = '6GB'
maintenance_work_mem = '512MB'
work_mem = '16MB'
wal_buffers = '16MB'
max_connections = 200
EOF
    fi

    # MySQL/MariaDB optimization
    if [ -f /etc/mysql/my.cnf ]; then
        cat >>/etc/mysql/my.cnf <<'EOF'
[mysqld]
innodb_buffer_pool_size = 2G
innodb_log_file_size = 512M
innodb_flush_log_at_trx_commit = 2
query_cache_size = 0
query_cache_type = 0
max_connections = 200
EOF
    fi

    # Redis optimization
    if [ -f /etc/redis/redis.conf ]; then
        sed -i 's/^# maxmemory <bytes>/maxmemory 2gb/' /etc/redis/redis.conf
        sed -i 's/^# maxmemory-policy noeviction/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf
    fi

    log_success "Database optimized"
}

# ============================================================================
# CREATE BACKUP SCRIPT
# ============================================================================
create_backup_script() {
    log_info "Creating backup script..."

    cat >/usr/local/sbin/backup-system.sh <<'EOF'
#!/bin/bash
# Automated backup script for server

BACKUP_DIR="/backups"
RETENTION_DAYS=30

# Create backup
create_backup() {
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="${BACKUP_DIR}/lfs-backup-${TIMESTAMP}.tar.gz"

    echo "Creating backup: $BACKUP_FILE"

    tar -czf "$BACKUP_FILE" \
        --exclude=/proc \
        --exclude=/sys \
        --exclude=/dev \
        --exclude=/tmp \
        --exclude=/run \
        --exclude=/mnt \
        --exclude=/media \
        --exclude=/backups \
        --exclude=/var/cache \
        /

    # Encrypt backup
    if command -v gpg &> /dev/null; then
        gpg --symmetric --cipher-algo AES256 "$BACKUP_FILE"
        rm "$BACKUP_FILE"
    fi
}

# Clean old backups
clean_backups() {
    find "$BACKUP_DIR" -name "lfs-backup-*.tar.gz.gpg" -mtime +$RETENTION_DAYS -delete
}

# Main
mkdir -p "$BACKUP_DIR"
create_backup
clean_backups

echo "Backup completed: $BACKUP_DIR"
EOF

    chmod +x /usr/local/sbin/backup-system.sh

    # Add to cron
    cat >/etc/cron.daily/backup <<'EOF'
#!/bin/bash
/usr/local/sbin/backup-system.sh
EOF
    chmod +x /etc/cron.daily/backup

    log_success "Backup script created"
}

# ============================================================================
# CREATE STATUS PAGE
# ============================================================================
create_status_page() {
    log_info "Creating server status page..."

    cat >/usr/local/sbin/status.sh <<'EOF'
#!/bin/bash
# Server status script

echo "=========================================="
echo "LFS Server Status Report"
echo "=========================================="
echo "Hostname: $(hostname)"
echo "Kernel: $(uname -r)"
echo "Uptime: $(uptime -p)"
echo ""
echo "=== CPU ==="
echo "Load: $(uptime | awk -F'load average:' '{print $2}')"
echo "CPU: $(nproc) cores"
echo ""
echo "=== Memory ==="
free -h
echo ""
echo "=== Disk ==="
df -h
echo ""
echo "=== Network ==="
ip addr show | grep -E "inet " | grep -v "127.0.0.1"
echo ""
echo "=== Services ==="
systemctl list-units --type=service --state=running | head -10
echo ""
echo "=== Active Connections ==="
ss -tunp | head -10
echo ""
echo "=== Last 5 Logins ==="
last -n 5
echo ""
echo "=========================================="
EOF

    chmod +x /usr/local/sbin/status.sh

    log_success "Status page created"
}

# ============================================================================
# CLEANUP
# ============================================================================
cleanup() {
    log_info "Cleaning up server build..."

    # Remove unnecessary documentation
    rm -rf /usr/share/doc/* 2>/dev/null || true
    rm -rf /usr/share/info/* 2>/dev/null || true

    # Remove development files (if not needed)
    find /usr/lib -name "*.a" -delete 2>/dev/null || true
    find /usr/lib -name "*.la" -delete 2>/dev/null || true

    log_success "Cleanup complete"
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    log_info "========================================="
    log_info "LFS Server Installation"
    log_info "========================================="

    configure_server_kernel
    configure_system_limits
    configure_ssh_server
    configure_firewall
    install_fail2ban
    configure_logging
    configure_monitoring
    optimize_database
    create_backup_script
    create_status_page
    cleanup

    log_success "========================================="
    log_success "Server Installation Complete!"
    log_success "========================================="
    echo ""
    echo "LFS Server is ready for production."
    echo ""
    echo "Installed services:"
    echo "  - SSH (port 22)"
    echo "  - Firewall (nftables)"
    echo "  - Fail2ban (brute force protection)"
    echo "  - Monitoring (node_exporter, netdata)"
    echo "  - Backup system (daily)"
    echo ""
    echo "Commands:"
    echo "  status.sh           - View server status"
    echo "  backup-system.sh    - Run manual backup"
    echo ""
    echo "Logs:"
    echo "  /var/log/auth.log   - Authentication logs"
    echo "  /var/log/syslog     - System logs"
    echo "  /var/log/remote/    - Remote logs"
    echo "========================================="
}

# Run main function
main "$@"
