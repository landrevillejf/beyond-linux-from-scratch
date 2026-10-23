# Security Policy

## Supported Versions

Use this section to tell people about which versions of your project are
currently being supported with security updates.

| Version | Supported          |
| ------- | ------------------ |
| 5.1.x   | :white_check_mark: |
| 5.0.x   | :x:                |
| 4.0.x   | :white_check_mark: |
| < 4.0   | :x:                |

## Reporting a Vulnerability

Use this section to tell people how to report a vulnerability.

Tell them where to go, how often they can expect to get an update on a
reported vulnerability, what to expect if the vulnerability is accepted or
declined, etc.

## Hardened builds

The builder ships a defence-in-depth hardening program that is off by default
and switched on per profile or per configuration key. It covers:

- Kernel lockdown (integrity mode) and mandatory module signing.
- SELinux targeted policy (resolved mode via `get_selinux_mode()`).
- FIPS-mode crypto (OpenSSL 3 FIPS provider + kernel `CONFIG_CRYPTO_FIPS`).
- Runtime intrusion tooling (fail2ban, rkhunter, lynis, aide, usbguard).
- Boot integrity (IMA/EVM measured boot, optional UEFI Secure Boot signing).
- Supply-chain integrity (sha256 source lock file, GPG signature verification,
  cosign-signed release artifacts and SLSA provenance in CI).

Every build closes with a `validate` gate (`final/16-validate-build.sh`) whose
section 13 statically re-checks the hardening controls on the finished rootfs.
A missing control is a warning by default and becomes a hard failure when
`security.compliance.fail_on_gap` is true. An optional, best-effort
`compliance-evidence` stage (`final/17-compliance-evidence.sh`) runs lynis and
OpenSCAP and records a JSON evidence manifest.

See [docs/security-hardening.md](docs/security-hardening.md) for the full
control matrix (CIS, DISA STIG, PCI-DSS, FIPS 140-3) and the configuration keys
that drive it.
