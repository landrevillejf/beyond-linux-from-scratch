# Security hardening and compliance control matrix

This document maps the hardening controls the builder applies to the finished
rootfs onto the compliance frameworks they serve, and explains how the
`validate` gate and the `compliance-evidence` stage prove those controls
landed. It is the reference for reviewers who need to answer "which control
covers CIS / DISA STIG / PCI-DSS / FIPS 140-3, and where is the evidence?".

All controls are gated: a default build stays green, and a control only becomes
a hard requirement when the matching configuration is switched on.

## How the gate works

Two stages close out every build:

| Stage | Script | Role | Fails the build? |
|---|---|---|---|
| `compliance-evidence` | `final/17-compliance-evidence.sh` | Best-effort scanner run (lynis, OpenSCAP) that records what ran into a JSON manifest and ships scanner reports inside the rootfs at `/var/log/compliance`. Scheduled only when `security.compliance.profiles` is non-empty. | Never |
| `validate` | `final/16-validate-build.sh` | Always-last authoritative gate. Section 13 re-checks the hardening controls statically and turns a missing control into a FAIL or a WARN according to `security.compliance.fail_on_gap`. | Only when a checked control is missing and `fail_on_gap` is true |

The `validate` section-13 assertions run only when `SECURITY_HARDENING=true`
(that is, the active profile scheduled `blfs/15-security-hardening.sh`), so the
`minimal`, `server` and audio profiles that never enable hardening are
unaffected.

## Configuration keys

Under the `security` section of `config/build.conf`:

| Key | Type | Default | Effect |
|---|---|---|---|
| `compliance.profiles` | list | `[]` | Non-empty list opts the build into the `compliance-evidence` stage; each token is passed to `oscap xccdf eval --profile`. Flattened to `LFS_CONFIG_SECURITY_COMPLIANCE_PROFILES` (comma-joined). |
| `compliance.fail_on_gap` | bool | `false` | When true, a control missing from the finished rootfs fails the `validate` stage; when false it is only a warning. Flattened to `LFS_CONFIG_SECURITY_COMPLIANCE_FAIL_ON_GAP`. |
| `selinux.mode` | string | `enforcing` | Resolved mode; `enforcing` adds the SELinux assertion in section 13. See `get_selinux_mode()`. |
| `fips.enabled` | bool | `false` | Resolved FIPS state; `true` adds the `/etc/system-fips` marker assertion. See `get_fips_enabled()`. |
| `boot_integrity.measured_boot` | bool | `false` | Opt-in IMA/EVM measured boot wiring (Phase 5). |
| `boot_integrity.secure_boot` | bool | `false` | Optional UEFI Secure Boot signing (Phase 5). |
| `baseline_all_profiles` | bool | `false` | When true, `get_build_stages()` schedules the hardened baseline (`security` + its `selinux`/`runtime-hardening` companions) for **every** profile regardless of the per-profile `security_hardening` flag (Phase 8). Heavier items -- LUKS encryption, the privacy/Tor stack, FIPS-mode and compliance evidence -- keep their own gates and stay opt-in, so a baseline roll cannot pull them into a lean `minimal`/`server` build. Resolved read-only by `get_security_baseline()`, which also overrides the `SECURITY_HARDENING` env so this gate fires whenever the security stage ran. |

## Control matrix

"Asserted" means `final/16-validate-build.sh` section 13 checks it directly on
the built rootfs.

| Control | Where it is applied | Asserted artifact | CIS | DISA STIG | PCI-DSS | FIPS 140-3 |
|---|---|---|---|---|---|---|
| Kernel lockdown (integrity) | curated `config/kernel-config*` + `lfs/08-build-kernel.sh` | `CONFIG_LOCKDOWN_KERNEL_FORCE_INTEGRITY=y` in the installed `/boot/config-*` | 1.6.x | SI-17 | 11.5 | yes (module integrity) |
| Mandatory module signing | kernel config | `CONFIG_MODULE_SIG_FORCE=y` in the installed `/boot/config-*` | 1.6.x | SI-17 | 11.5 | yes |
| Audit rule set immutable | `blfs/15` (`/etc/audit/rules.d/hardening.rules`) | line `-e 2` | 4.1.2.x | AU-3 | 10.x | - |
| Default-deny firewall | `blfs/15` (`/etc/nftables.conf`) | `policy drop` | 3.5.x | SC-7 | 1.2, 1.3 | - |
| USB mass-storage disabled | `blfs/15` (`/etc/modprobe.d/hardening-blacklist.conf`) | `install usb-storage /bin/false` | 1.1.x | MP-7 | - | - |
| SELinux enforcing | `blfs/31` + `blfs/15` (`/etc/selinux/config`) | `SELINUX=enforcing` (only when resolved mode is enforcing) | 1.4.x | AC-3, AC-33 | - | - |
| FIPS-mode crypto | `blfs/08` (OpenSSL 3 FIPS provider) + kernel `CONFIG_CRYPTO_FIPS` | `/etc/system-fips` marker (only when FIPS resolved on) | - | SC-13 | 3.x, 4.x | yes |
| Runtime intrusion tooling | `blfs/32-runtime-hardening.sh` (fail2ban, rkhunter, lynis, aide, usbguard) | built binaries present in the rootfs | 6.2.x | SI-4 | 11.4 | - |
| Supply-chain pinning | `SourceDownloader` + `packages/sources.lock` (Phase 6) | sha256 lock verification, GPG signature check | - | SR-3, SR-11 | 6.3 | - |
| Signed release artifacts | CI cosign/SLSA (Phase 6b) | ISO/manifest `.cosign.bundle` + SLSA provenance attestation | - | SR-4 | 6.3 | - |

Framework columns are indicative mappings for reviewer orientation, not a
certification claim. The builder does not itself produce a certified artifact;
it produces the configuration and the evidence a certification process
consumes.

## Compliance evidence output

When `security.compliance.profiles` is non-empty, `final/17-compliance-evidence.sh`
writes a manifest the reviewer can diff against the control matrix:

```json
{
  "profiles": "xccdf_org.ssgproject.content_profile_pci-dss",
  "runs": [
    {"tool": "lynis", "status": "ok", "artifact": "/var/log/compliance/lynis-report.dat"},
    {"tool": "oscap:xccdf_org.ssgproject.content_profile_pci-dss", "status": "ok", "artifact": "/var/log/compliance/oscap-...-report.html"}
  ]
}
```

`status` is one of `ok` (scanner ran), `skipped` (scanner present but could not
run, e.g. the stage did not run as root), or `absent` (scanner not built into
the rootfs). This lets a reviewer tell "no scanner present" apart from "scanner
ran and here is its report".

OpenSCAP is an operator opt-in build: the builder does not download
`scap-security-guide` by default, so `oscap` records `absent` unless the operator
built it into the rootfs. lynis is built by `blfs/32` whenever
`security_hardening` is on.

## Enforcing compliance in CI

To turn the gate on for a compliance-scoped build, set in the active
`config/build.conf` (or a profile override):

```json
"security": {
  "compliance": {"profiles": ["xccdf_org.ssgproject.content_profile_pci-dss"], "fail_on_gap": true}
}
```

With `fail_on_gap: true`, any control in the matrix that is missing from the
finished rootfs fails the `validate` stage and therefore the build, which is
what a compliance pipeline wants. Leave `fail_on_gap` false (the default) for
ordinary desktop/server builds so an optional control degrades to a warning.
