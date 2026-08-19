# LPM (LFS Package Manager) - Complete Documentation

**Version:** 2.7.0
**License:** GPL-3.0

---

## Overview

LPM is the package manager of this distribution. It is a single
self-contained Bash script (`blfs/19-lpm.sh`, installed as
`/usr/bin/lpm`) that handles package installation, removal, upgrades,
dependency resolution, integrity verification, source builds and
database management without relying on any external package management
infrastructure.

The complete command reference lives in [`lpm.md`](lpm.md). This page
covers the architecture, the database layout, repository configuration
and the build-time integration.

## Features

- Install / remove / update / upgrade with automatic dependency
  resolution, version constraints (`pkg>=1.2`, `pkg=2.0`) and circular
  dependency detection
- File tracking (`file_index`) and integrity verification (`lpm verify`)
- SHA256 checksum verification and optional GPG signature verification
- Source builds with build-system auto-detection or `.lpm` recipes
  (`lpm build`)
- Package holds (`lpm hold/unhold/holds`), transaction history
  (`lpm history`), upgradable listing (`lpm upgradable`), reverse
  dependency lookup (`lpm why`) and orphan removal (`lpm autoremove`)
- Multi-repository support: local repository plus remote HTTP(S)
  repositories declared in `lpm.conf` or `/etc/lpm/repos.d/*.conf`
- Profile management (`lpm list-profiles`, `lpm add-profile`)
- System root redirection for chroots and testing (`--sysroot`,
  `LPM_ROOT`)
- Build-time database seeding: the finished system ships with a real
  package database and installed registry

## Installation

LPM is installed by the build pipeline (stage `19-lpm`,
`blfs/19-lpm.sh`): the script copies itself to `/usr/bin/lpm`, creates
the database layout, installs `/etc/lpm/lpm.conf` and writes
`/etc/lpm/repos.d/default.conf` pointing at the project's GitHub
releases.

Manual installation:

```bash
install -m 755 blfs/19-lpm.sh /usr/local/bin/lpm
mkdir -p /var/lib/lpm /var/log/lpm /etc/lpm /usr/share/lpm/packages
touch /var/lib/lpm/packages.list /var/lib/lpm/installed.list /var/lib/lpm/file_index
```

## Usage Guide

```bash
lpm update-db                       # Sync the database with the repositories
lpm search python                   # Search the database
lpm list                            # List installed packages
lpm info bash                       # Package details
lpm install firefox                 # Install with dependencies
lpm remove firefox                  # Remove (shared files preserved)
lpm update bash                     # Upgrade a single package
lpm upgrade                         # Upgrade everything (skips holds)
lpm upgradable                      # What would upgrade change?
lpm reinstall curl                  # Force re-fetch and re-install
lpm why ncurses                     # Who depends on this package?
lpm autoremove --dry-run            # Find orphaned packages
lpm hold linux-api-headers          # Pin against upgrades
lpm history                         # Transaction log
lpm verify                          # Integrity check of installed files
lpm build myapp-1.0.tar.xz          # Build a package from source
lpm add-profile java-dev            # Install a predefined profile
```

Global options: `--dry-run`, `--force`, `--quiet`, `--verbose`,
`--no-color`, `--sysroot <dir>`.

## Configuration

### Main configuration file

`/etc/lpm/lpm.conf` is sourced at startup and can override any default
(database paths, `REPO_REMOTE_URLS`, `VERIFY_CHECKSUMS`,
`VERIFY_SIGNATURES`, `GPG_KEYRING`, `BUILD_JOBS`, log retention, ...).
See [`lpm.md`](lpm.md) for the full variable list.

### Repository configuration

Remote repositories are declared either in the `REPO_REMOTE_URLS`
array of `lpm.conf` or in drop-in files under `/etc/lpm/repos.d/*.conf`
(one `name=url` pair per line; comments and blank lines are ignored):

```
# /etc/lpm/repos.d/default.conf
lfs-releases=https://github.com/landrevillejf/beyond-linux-from-scratch/releases/latest/download
```

`lpm update-db` fetches `<url>/packages.list` from every configured
remote. When `VERIFY_SIGNATURES=true`, the matching `.sig` is fetched
and checked against `GPG_KEYRING`. If every remote fails, the existing
local database is kept unchanged and a warning is printed; sample data
is only written when the database is empty and no remote is configured.

## Database

LPM maintains these files under `/var/lib/lpm`:

| File | Format | Purpose |
|------|--------|---------|
| `packages.list` | `name\|version\|description\|deps\|checksum` | Available packages |
| `installed.list` | `name version` | Installed packages |
| `file_index` | `/path package-version` | File ownership |
| `kernel_deps.list` | `pkg\|kernel\|type` | Kernel-dependent packages |
| `holds.list` | one package name per line | Packages pinned against `upgrade` |
| `history.log` | `timestamp\|action\|package\|version` | Transaction history |

### Build-time seeding

Stage 14 (`blfs/14-create-base-packages.sh`) seeds both databases at
build time:

- Versions are resolved from the tarballs actually used by the build
  (`$LFS/sources/*.tar.*`, same name-version split rule as LPM); a
  curated LFS 13.0 table is the fallback.
- `packages.list` receives one entry per base package;
  `installed.list` is seeded with every base package so `lpm list`,
  `lpm upgrade` and `lpm verify` are meaningful on the finished system.
- `/usr/share/lpm/base-packages.list` records the canonical base set
  (used by `lpm autoremove`).
- The manifest is exported to the build output directory
  (`lpm-repo/packages.list` with a `.sha256` checksum and, when a GPG
  key is available, a detached `.sig`). The release pipelines upload it
  as a GitHub release asset, which is exactly what the default
  repository in `repos.d/default.conf` points at.

## System updater integration

`/usr/bin/lfs-update` (stage 18, `blfs/18-system-updater.sh`) builds on
LPM:

```bash
lfs-update check                    # Version + upgradable package count
lfs-update upgrade                  # Backup /etc and /boot, then lpm update-db + upgrade
lfs-update status                   # Version, installed and upgradable counts
```

It fetches remote resources with curl (wget fallback), never assumes a
specific init system, and only updates `/etc/lfs-version` when the
repository manifest declares a new version. A weekly
`/etc/cron.weekly/lfs-update-check` job is installed when cron is
present.

## Package Format

A package is a `tar.xz` archive containing the files to install under
`files/` (full paths relative to root) plus optional
`pre-install.sh` / `post-install.sh` / `pre-remove.sh` /
`post-remove.sh` hooks. Recipes for `lpm build` are plain shell `.lpm`
files; the repository ships the full LFS 13.0 recipe set under
`recipes/lfs/`.

## Development

```bash
# Guardrail and smoke tests for LPM and its integration stages
python3 -m pytest tests/test_lpm.py tests/test_acceptance_shell.py -q

# Static analysis
shellcheck blfs/14-create-base-packages.sh blfs/18-system-updater.sh blfs/19-lpm.sh
```

## License

LPM is licensed under the GNU General Public License v3.0.

---

**Maintained By:** Jean-Francois Landreville
