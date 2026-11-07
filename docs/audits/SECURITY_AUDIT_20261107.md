# Security Audit Report

**Application:** Beyond Linux From Scratch (WBLFS) Builder  
**Application ID:** beyond-linux-from-scratch  
**Version audited:** 0.57.4  
**Audit date:** 2026-11-07 (America/New_York)  
**Auditor:** Automated security audit (audit-securite-conformite)  
**Security baseline:** CIS Controls v8, LFS security recommendations  
**Scope:** Secrets, access control, download security, input validation, service hardening, permissions  

---

## Executive Summary

This audit examines the Beyond Linux From Scratch build system for security vulnerabilities across code, configuration, download practices, and service hardening. The project is an automated LFS/BLFS distribution builder that produces bootable Linux systems.

**Overall security posture: MODERATE — 12 findings (2 CRITICAL, 3 HIGH, 4 MEDIUM, 3 LOW)**

The build system implements substantial security hardening (kernel lockdown, nftables default-deny firewall, PAM password quality, audit rules, SSH hardening, SELinux enforcing). However, two critical findings involve hardcoded credentials in configuration files and disabled TLS certificate verification in the source downloader. The download infrastructure also uses HTTP (unencrypted) for 15 source package URLs, creating supply-chain integrity risks.

---

## Findings Table

| ID | Severity | Category | Location | CIS Control | Status |
|----|----------|----------|----------|-------------|--------|
| S-01 | CRITICAL | Secrets | `config/lfs-build.conf` L50 | 3.3 (Data Protection) | Open |
| S-02 | CRITICAL | Secrets | `packages/custom-scripts/custom-settings.conf` L14 | 3.3 (Data Protection) | Open |
| S-03 | HIGH | Download Security | `builder.py` L946-948 | 7.4 (Supply Chain) | Open |
| S-04 | HIGH | Download Security | `packages/sources.list`, `packages/custom-sources.list` | 7.4 (Supply Chain) | Open |
| S-05 | HIGH | Access Control | `Dockerfile` L19 | 5.4 (Least Privilege) | Open |
| S-06 | MEDIUM | SSH Config | `config/security.conf` L31 | 8.5 (Authentication) | Open |
| S-07 | MEDIUM | Firewall | `config/security.conf` L49 | 13.1 (Network Monitoring) | Open |
| S-08 | MEDIUM | AIDE/FIM | `config/security.conf` L160 | 10.1 (Audit Logs) | Open |
| S-09 | MEDIUM | Input Validation | `blfs/17-first-boot-service.sh` L117-118 | 4.1 (Secure Processes) | Open |
| S-10 | LOW | Permissions | `host/02-prepare-host.sh` L205 | 3.3 (Data Protection) | Open |
| S-11 | LOW | SSH Config | `profiles/server/customization.sh` L126 | 8.5 (Authentication) | Open |
| S-12 | LOW | Configuration | `config/build.conf` L222 | 5.1 (Access Management) | Open |

---

## Detailed Findings

### S-01: Hardcoded LFS User Password in Build Configuration (CRITICAL)

**Location:** `config/lfs-build.conf` line 50  
**CIS Control:** 3.3 — Data Protection; 5.1 — Account Management

**Measurement:**
```bash
# config/lfs-build.conf line 50
LFS_USER_PASSWORD="lfs"
```

**Evidence:** The password for the LFS build user is hardcoded as the plaintext string `"lfs"` in a committed configuration file. This file is tracked in version control and would be included in any distribution of the build system.

**Impact:** Anyone with access to the repository knows the build user's password. While the LFS user is a build-time account (not a runtime user), this violates the principle of least privilege and could allow unauthorized chroot access during builds.

**Recommendation:**
1. Remove the hardcoded password immediately.
2. Generate a random password at build time or use a locked account (`passwd -l lfs`).
3. Add `config/lfs-build.conf` to `.gitignore` or use environment variable injection.
4. Rotate any credentials that used this password in past builds.

**Remediation status:** OPEN

---

### S-02: Hardcoded Default User Password in Custom Settings (CRITICAL)

**Location:** `packages/custom-scripts/custom-settings.conf` line 14  
**CIS Control:** 3.3 — Data Protection; 5.1 — Account Management

**Measurement:**
```bash
# packages/custom-scripts/custom-settings.conf line 13-14
DEFAULT_USER="lfsuser"
DEFAULT_PASSWORD="lfsuser123"
```

**Evidence:** A default user account password is hardcoded in plaintext in a committed configuration file. This password would be applied to the `lfsuser` account in the built system through `first-boot.sh` or `theme-setup.sh`.

**Impact:** Every system built with the default configuration ships with a known password (`lfsuser123`) for the `lfsuser` account. This is a critical security vulnerability — any attacker aware of this project could log into built systems with this credential. Combined with `lfsuser` being in the `wheel` group (sudo access, per `config/build.conf` line 216), this grants full root access.

**Recommendation:**
1. Remove the hardcoded password immediately.
2. Force interactive password setup on first boot (the `blfs/17-first-boot-service.sh` already does this for new installs — leverage it).
3. If a default is needed for automated builds, generate a random password and print it to the console exactly once.
4. Add a prominent security warning in README if default passwords are ever used.

**Remediation status:** OPEN

---

### S-03: TLS Certificate Verification Disabled in Source Downloader (HIGH)

**Location:** `builder.py` lines 943-953  
**CIS Control:** 7.4 — Supply Chain Integrity; 3.10 — Encryption of Data in Transit

**Measurement:**
```python
# builder.py lines 943-953 (SourceDownloader._create_session)
def _create_session(self):
    """Create urllib session with retry logic and permissive SSL"""
    import ssl
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx))
```

**Evidence:** The source downloader explicitly disables TLS hostname verification (`check_hostname = False`) and certificate validation (`verify_mode = ssl.CERT_NONE`). Every source package download — including toolchain components (GCC, Glibc, Binutils) and kernel sources — is vulnerable to man-in-the-middle attacks.

**Impact:** An attacker on the network path could substitute malicious source tarballs for any of the 1,100+ packages downloaded. This is a supply-chain attack vector: compromised sources would be compiled into the final system with no integrity check beyond the optional lockfile (which itself would be generated from the tampered download).

**Recommendation:**
1. Remove `ctx.check_hostname = False` and `ctx.verify_mode = ssl.CERT_NONE`.
2. Use the default SSL context which verifies certificates against the system trust store.
3. If specific mirrors have certificate issues, fix the mirror configuration rather than disabling verification globally.
4. Enable `supply_chain.verify_signatures` and `supply_chain.require_lockfile` in the default configuration.

**Remediation status:** OPEN

---

### S-04: HTTP (Unencrypted) Download URLs for Source Packages (HIGH)

**Location:** `packages/sources.list` (12 URLs), `packages/custom-sources.list` (3 URLs)  
**CIS Control:** 7.4 — Supply Chain Integrity; 3.10 — Encryption of Data in Transit

**Measurement:**
```
# packages/sources.list (12 HTTP URLs):
http://archive.xfce.org/src/xfce/xfce4-dev-tools/4.20/xfce4-dev-tools-4.20.0.tar.bz2
http://dist.schmorp.de/libptytty/libptytty-2.0.tar.gz
http://dist.schmorp.de/rxvt-unicode/Attic/rxvt-unicode-9.31.tar.bz2
http://fcron.free.fr/archives/fcron-3.4.0.src.tar.gz
http://ftp.midnight-commander.org/mc-4.8.33.tar.xz
http://gondor.apana.org.au/~herbert/dash/files/dash-0.5.12.tar.gz
http://libndp.org/files/libndp-1.9.tar.gz
http://links.twibright.com/download/links-2.30.tar.bz2
http://openbox.org/dist/openbox/openbox-3.6.1.tar.gz
http://people.freedesktop.org/~hughsient/appstream-glib/releases/appstream-glib-0.8.3.tar.xz
http://www.andre-simon.de/zip/highlight-4.16.tar.bz2
http://www.mirbsd.org/MirOS/dist/mir/cpio/paxmirabilis-20240817.tgz

# packages/custom-sources.list (3 HTTP URLs):
http://rsync.belnet.be/mirror/ftp.frugalware.org/.../stunnel-5.75.tar.gz
http://mirror.dotsrc.org/kali/pool/main/z/zsh/zsh_5.9.orig.tar.xz
http://smarden.org/runit/runit-2.3.1.tar.gz
```

**Evidence:** 15 out of ~1,132 source URLs use HTTP instead of HTTPS. These downloads are unencrypted and unauthenticated. Combined with S-03 (TLS verification disabled), there is no protection against tampering.

**Impact:** Source packages downloaded over HTTP could be intercepted and modified. While the `checksum_verification: true` setting in `build.conf` (line 255) provides post-download integrity checking, the checksums are only verified if a checksum file exists (which is optional per `verify_checksums()` in builder.py L1307-1311).

**Recommendation:**
1. Replace all HTTP URLs with HTTPS equivalents where available.
2. For mirrors without HTTPS support, use the BLFS conglomeration mirror (`https://ftp2.osuosl.org/pub/blfs/conglomeration`) as a fallback.
3. Make checksum verification mandatory (not optional) for all source downloads.
4. Add a CI check that rejects new HTTP URLs in source lists.

**Remediation status:** OPEN

---

### S-05: Docker Build User Has Unrestricted Passwordless Sudo (HIGH)

**Location:** `Dockerfile` line 19  
**CIS Control:** 5.4 — Least Privilege; 4.1 — Secure Process Configuration

**Measurement:**
```dockerfile
# Dockerfile lines 18-19
RUN useradd -m -s /bin/bash builder && \
    echo "builder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
```

**Evidence:** The Docker build user `builder` is granted unrestricted passwordless sudo access to all commands. While this is inside a container, the built image inherits this sudo configuration if `/etc/sudoers` from the build environment is copied.

**Impact:** If the container's filesystem is incorporated into the final LFS image, the `builder` account (or any account with the same UID) would have unrestricted root access without a password.

**Recommendation:**
1. Scope sudo privileges to only the commands the builder needs.
2. Remove the builder's sudo entry from the final image (add a cleanup step).
3. Use `--privileged` only during build, not in the final image.

**Remediation status:** OPEN

---

### S-06: SSH Key-Only Authentication Disabled (MEDIUM)

**Location:** `config/security.conf` line 31  
**CIS Control:** 8.5 — Authentication Management

**Measurement:**
```bash
# config/security.conf line 31
SSH_KEY_ONLY="false"
```

**Evidence:** The security configuration explicitly allows password-based SSH authentication alongside key-based authentication. CIS Control 8.5 recommends key-based authentication as the primary method for service accounts.

**Impact:** Password-based SSH authentication is susceptible to brute-force attacks. While `FAIL2BAN_ENABLED="true"` (line 69) and `SSH_MAX_AUTH_TRIES="3"` (line 40) mitigate this, key-only authentication is the stronger control.

**Note:** The actual SSH hardening script (`blfs/15-security-hardening.sh` line 231) correctly sets `PasswordAuthentication no` in the sshd drop-in config, so the runtime behavior is more secure than this configuration file suggests.

**Recommendation:** Align `config/security.conf` line 31 to `SSH_KEY_ONLY="true"` to match the actual hardening script behavior.

**Remediation status:** OPEN

---

### S-07: Firewall Backend Mismatch (MEDIUM)

**Location:** `config/security.conf` line 49  
**CIS Control:** 13.1 — Network Boundary Protection

**Measurement:**
```bash
# config/security.conf line 49
FIREWALL_BACKEND="iptables"
# config/build.conf line 119 (JSON)
"backend": "nftables"
```

**Evidence:** The security configuration declares `iptables` as the firewall backend, while the build configuration and actual implementation (`blfs/15-security-hardening.sh` line 336) use `nftables`. This is the same finding as C-03 in the compliance audit.

**Impact:** If a security scanner or operator reads `security.conf` to understand the firewall configuration, they would get incorrect information. The actual runtime firewall (nftables) is correctly configured with default-deny policy.

**Recommendation:** Update `config/security.conf` line 49 to `FIREWALL_BACKEND="nftables"`.

**Remediation status:** OPEN

---

### S-08: AIDE File Integrity Monitoring Disabled (MEDIUM)

**Location:** `config/security.conf` line 160  
**CIS Control:** 10.1 — Audit Log Management; 13.10 — Endpoint Detection

**Measurement:**
```bash
# config/security.conf line 160
ENABLE_AIDE="false"
```

**Evidence:** AIDE (Advanced Intrusion Detection Environment) is disabled despite being configured with monitor directories (`/etc,/usr/bin,/usr/sbin,/bin,/sbin,/boot`). The `blfs/32-runtime-hardening.sh` script conditionally configures AIDE only when the binary is present (the custom-sources.list comments at line 844 explain AIDE is intentionally not downloaded due to heavy crypto dependencies).

**Impact:** Without file integrity monitoring, post-compromise detection of binary modification in critical system directories is not possible. This is a CIS Control 13.10 gap.

**Recommendation:** Document the AIDE gap as an accepted risk in SECURITY.md, or add AIDE to the runtime-hardening download list when the dependency chain is resolved.

**Remediation status:** OPEN

---

### S-09: Password Piped Through Command Line in First Boot Script (MEDIUM)

**Location:** `blfs/17-first-boot-service.sh` lines 117-118, 193-194  
**CIS Control:** 4.1 — Secure Process Configuration; 8.2 — Privileged Account Management

**Measurement:**
```bash
# blfs/17-first-boot-service.sh lines 117-118
echo "root:$ROOT_PASS" | chpasswd 2>/dev/null || \
    passwd root <<< "$ROOT_PASS" 2>/dev/null || true

# blfs/17-first-boot-service.sh lines 193-194
echo "$NEW_USER:$USER_PASS" | chpasswd 2>/dev/null || \
    passwd "$NEW_USER" <<< "$USER_PASS" 2>/dev/null || true
```

**Evidence:** Passwords are passed through `echo` piped to `chpasswd` and through here-strings to `passwd`. While `chpasswd` reads from stdin (not the command line), the `echo` command may briefly expose the password in `/proc/*/cmdline` on some systems. The `unset ROOT_PASS ROOT_PASS2` on line 119 is good practice.

**Impact:** Brief exposure of plaintext passwords in process listings. The `|| true` fallback means a failed password set is silently ignored, potentially leaving accounts without passwords.

**Recommendation:**
1. Use `chpasswd` exclusively (it reads from stdin by design).
2. Remove the `|| true` fallback or replace with explicit error handling.
3. Consider writing passwords to a temporary file with mode 0600, feeding it to `chpasswd`, then securely deleting it.

**Remediation status:** OPEN

---

### S-10: World-Writable /tmp Permission on Sources Directory (LOW)

**Location:** `host/02-prepare-host.sh` line 205  
**CIS Control:** 3.3 — Data Protection

**Measurement:**
```bash
# host/02-prepare-host.sh line 205
chmod a+wt "$LFS/sources" 2>/dev/null || true
```

**Evidence:** The sources directory is set with the sticky bit and world-writable permission (`a+wt`). This is standard practice for `/tmp` but unusual for a build sources directory. The `|| true` suppresses errors if the directory doesn't exist yet.

**Impact:** Any user on the build host could place files in the sources directory. In a shared build environment, a malicious user could substitute a source tarball. However, checksum verification (when enabled) would catch this.

**Recommendation:** Use `chmod 0755` instead of `chmod a+wt` for the sources directory, restricting write access to the owner (`lfs` user).

**Remediation status:** OPEN

---

### S-11: Server Profile Allows Password Authentication for SSH (LOW)

**Location:** `profiles/server/customization.sh` line 126  
**CIS Control:** 8.5 — Authentication Management

**Measurement:**
```bash
# profiles/server/customization.sh lines 125-126
PubkeyAuthentication yes
PasswordAuthentication yes
```

**Evidence:** The server profile's SSH configuration allows password authentication. This contradicts the security hardening script (`blfs/15-security-hardening.sh` line 231: `PasswordAuthentication no`).

**Impact:** Server profiles built with this customization would accept password-based SSH logins, which are susceptible to brute-force attacks. The hardening stage should override this, but the inconsistency could cause confusion.

**Recommendation:** Set `PasswordAuthentication no` in the server profile's SSH configuration to match the hardening baseline.

**Remediation status:** OPEN

---

### S-12: User Auto-Login Enabled by Default (LOW)

**Location:** `config/build.conf` line 223  
**CIS Control:** 5.1 — Access Management; 6.1 — Access Grant

**Measurement:**
```json
// config/build.conf lines 212-224
"users": [
    {
        "name": "lfsuser",
        "groups": ["wheel", "audio", "video", "storage", "docker"],
        "sudo": true,
        "autologin": true
    }
]
```

**Evidence:** The default user `lfsuser` is configured with auto-login enabled and full sudo privileges. Combined with S-02 (hardcoded password), this means any physical or VM console access grants immediate root-level access.

**Impact:** Auto-login bypasses authentication entirely. On a physical machine or shared VM, this allows unauthenticated access to a sudo-privileged account.

**Recommendation:** Set `"autologin": false` as the default. Profiles that need auto-login (e.g., live ISO) should explicitly enable it.

**Remediation status:** OPEN

---

## Positive Security Controls Observed

The audit identified the following security strengths:

| Control | Location | Status |
|---------|----------|--------|
| Kernel lockdown (integrity mode) | `config/build.conf` L111 | ✅ Configured |
| Module signature enforcement | `config/build.conf` L112 | ✅ Configured |
| Default-deny nftables firewall | `blfs/15-security-hardening.sh` L351 | ✅ Implemented |
| SSH hardening (Protocol 2, strong ciphers) | `blfs/15-security-hardening.sh` L228-247 | ✅ Implemented |
| PAM password quality (min 12 chars, 3 classes) | `blfs/15-security-hardening.sh` L155-169 | ✅ Implemented |
| Audit rules for sensitive files | `blfs/15-security-hardening.sh` L307-331 | ✅ Implemented |
| Core dumps disabled | `blfs/15-security-hardening.sh` L182-183 | ✅ Implemented |
| Fail2ban enabled | `config/security.conf` L69 | ✅ Configured |
| SELinux enforcing (targeted) | `config/build.conf` L146-147 | ✅ Configured |
| Supply chain signature verification | `config/build.conf` L160 | ✅ Configured |
| SHA-256 source lockfile support | `builder.py` L1339-1416 | ✅ Implemented |
| Root login disabled (security.conf) | `config/build.conf` L138 | ✅ Configured |
| Login rate limiting (SSH) | `blfs/15-security-hardening.sh` L238 | ✅ Implemented |
| Kernel module blacklist | `blfs/15-security-hardening.sh` L207-223 | ✅ Implemented |
| Sysctl network hardening | `blfs/15-security-hardening.sh` L66-141 | ✅ Implemented |
| Post-build validation gate | `final/16-validate-build.sh` | ✅ Implemented |

---

## Risk Summary

| Severity | Count | Key Areas |
|----------|-------|-----------|
| CRITICAL | 2 | Hardcoded passwords (S-01, S-02) |
| HIGH | 3 | TLS disabled (S-03), HTTP downloads (S-04), Dockerfile sudo (S-05) |
| MEDIUM | 4 | SSH config mismatch (S-06), firewall mismatch (S-07), AIDE disabled (S-08), password piping (S-09) |
| LOW | 3 | Sources permissions (S-10), server SSH password auth (S-11), autologin (S-12) |

---

## Priority Remediation Plan

1. **[CRITICAL — Immediate] S-01, S-02:** Remove all hardcoded passwords from committed configuration files. Use runtime-generated credentials or force interactive setup.
2. **[CRITICAL — Immediate] S-03:** Re-enable TLS certificate verification in `builder.py` `SourceDownloader._create_session()`.
3. **[HIGH — This sprint] S-04:** Migrate all HTTP source URLs to HTTPS. Make checksum verification mandatory.
4. **[HIGH — This sprint] S-05:** Scope Docker sudo privileges and clean up before image finalization.
5. **[MEDIUM — Next sprint] S-06, S-07:** Align `security.conf` with actual hardening implementation.
6. **[MEDIUM — Next sprint] S-08, S-09:** Document AIDE gap; fix password handling in first-boot script.
7. **[LOW — Backlog] S-10, S-11, S-12:** Fix permissions, SSH config consistency, and autologin default.

---

## Evidence

- All measurements taken from repository at `/home/fedora/Documents/beyond-linux-from-scratch-main` on 2026-11-07.
- Security patterns searched with `grep` across all `.sh`, `.py`, and `.conf` files.
- TLS configuration verified by reading `builder.py` source code (lines 943-953).
- HTTP URLs enumerated from `packages/sources.list` and `packages/custom-sources.list`.
- Hardening controls verified against `blfs/15-security-hardening.sh` implementation.

---

*Report generated: 2026-11-07 America/New_York*  
*Audit methodology: audit-securite-conformite skill*  
*Security baseline: CIS Controls v8*  
*Traceability: every finding backed by file path, line number, and measured content*
