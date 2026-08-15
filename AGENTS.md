# AGENTS.md — Way Beyond Linux From Scratch

This file provides context and guidelines for AI agents (e.g. GitHub Copilot, automated coding assistants) working in this repository.

---

## Repository overview

**Way Beyond Linux From Scratch** is an automated LFS/BLFS distribution builder. It orchestrates host preparation, toolchain construction, LFS core build, BLFS layers, kernel generation, installer creation, and optional live ISO output through a single Python entry point (`builder.py`).

- **Version**: 0.52.4  
- **License**: GPLv3  
- **Primary language**: Python 3 (orchestrator) + Bash (stage scripts)  
- **Author**: Jean-Francois Landreville, landrevillejf@protonmail.com

---

## Goal

The goal of this project is to provide a fully automated, reproducible, and customizable Linux distribution build system that adheres to the principles of LFS and BLFS. It allows users to create a complete Linux system from source, with options for different desktop environments, init systems, and target architectures.
- Should contain the kernel, bootloader, and initramfs for a fully functional system.
- Can be built using a GitHub workflow or locally on a Linux host with Python 3.10+.
- Should be able to produce rootfs tarballs, bootable disk images, and optionally live ISO images.
- Should be able to produce a live ISO image with optional branding and customization.
- Should be able to use all the params defined in `config/build.conf`, used by the builder.py and the selected profile.
- Should be able to use cache packages to speed up the build process, and allow for resuming builds from a specific stage.
---

## Project structure

```
.
├── builder.py                  # Main orchestrator — only Python entry point
├── config/
│   ├── build.conf              # Primary JSON configuration file
│   └── build-cross.conf        # Cross-compile configuration
├── host/                       # Stage scripts: host checks and toolchain
├── lfs/                        # Stage scripts: core LFS system
├── blfs/                       # Stage scripts: desktop, apps, package manager
├── final/                      # Stage scripts: initramfs, bootloader, ISO
├── packages/                   # Package source lists
├── profiles/                   # Build profile definitions
├── branding/                   # Branding assets and TOML configuration
├── tests/                      # Python test suite (pytest + pytest-bdd)
├── docs/                       # Extended documentation
├── tools/                      # Utility scripts
├── wblfs-wallpaper-generator.py
├── requirements.txt
└── .github/workflows/          # CI/CD workflows
```

---

## Key components

### `builder.py`

The sole Python orchestrator. Responsibilities:

- CLI argument parsing (`argparse`)
- Loading and merging `config/build.conf` + profile overrides
- Exporting a flattened shell environment (`LFS_CONFIG_*`, `LFS_PROFILE_*`)
- Executing ordered stage scripts via `ScriptExecutor`
- Source downloading via `SourceDownloader`
- Profile management via `ProfileManager`
- Cache metadata handling (`--use-cache`, `--cache-only`)

**Do not split its responsibilities into separate modules without a thorough understanding of how environment propagation works.**

### Stage shell scripts

All stages are pure Bash scripts. They receive configuration exclusively through exported environment variables — they must not read files outside the build tree or make network calls beyond what is defined by builder.py source lists.

Stage execution order (xfce profile, live enabled):

1. `host-check` → `host/01-check-host.sh`
2. `host-prepare` → `host/02-prepare-host.sh`
3. `disk-image` → `host/03-create-disk-image.sh`
4. `toolchain` → `host/04-build-toolchain.sh`
5. `lfs-basic` → `lfs/05-build-lfs-basic.sh`
6. `lfs-system` → `lfs/06-build-lfs-system.sh`
7. … (see `BUILD_STAGES` in `builder.py` for the complete list)

### `branding/`

Contains branding presets (subdirectories) and a `branding.toml` central config. Branding is applied during the `branding` stage. Configuration is driven from `config/build.conf` under the `branding` key.

---

## Build profiles

Profiles live in `ProfileManager` (inside `builder.py`). Each profile specifies: desktop environment, init system, target architecture, live ISO flag, and included/excluded stages.

Available profiles: `minimal`, `gnu-free`, `gnu-free-full`, `xfce`, `gnome`, `kde`, `lxqt`, `java-dev`, `server`, `secure`, `full`, `audio-cli`, `audio-studio`, `arm64`, `pinebook`, `brax3`, `custom`.

---

## Development workflow

### Setting up the environment

```bash
git clone https://github.com/landrevillejf/beyond-linux-from-scratch.git
cd beyond-linux-from-scratch
python3 -m pip install -r tests/requirements.txt
```

### Running the test suite

```bash
# Full test run with coverage
python3 -m pytest tests/ --cov=builder --cov-report=term-missing

# Fast parallel run
python3 -m pytest tests/ -n auto

# Single test file
python3 -m pytest tests/test_builder.py -v
```

Test dependencies (from `tests/requirements-test.txt`):

- `pytest >= 7.0`
- `pytest-cov`
- `pytest-mock`
- `pytest-timeout`
- `pytest-xdist`
- `requests-mock`
- `pytest-bdd`

### Linting

```bash
flake8 . --count --select=E9,F63,F7,F82 --show-source --statistics
flake8 . --count --max-complexity=10 --max-line-length=127 --statistics --exit-zero
```

The CI enforces a max line length of **127 characters**.

### Coverage target

- `builder.py` coverage target: **100%**

---

## CI/CD workflows

All workflows live in `.github/workflows/`. Key pipelines:

| Workflow | Trigger | Purpose |
|---|---|---|
| `python-app.yml` | push/PR to `main` | Lint, test, coverage upload (Python 3.10–3.13 matrix) |
| `codeql.yml` | push/PR/schedule | CodeQL security analysis |
| `codacy-security-scan.yml` | push/PR | Codacy SAST |
| `xfce-sysvinit-x86_64-build-cache.yml` | manual/schedule | Build reusable cache rootfs |
| `xfce-systemd-x86_64-build-cache.yml` | manual/schedule | Build reusable cache rootfs |
| `build-iso-from-cache.yml` | manual | Reconstruct ISO from cache archive |
| `xfce-live-boot-iso.yml` | manual/tag | Full live ISO release pipeline |
| `release.yml` | tag push | Tagged release build pipeline |
| `nightly.yml` | schedule | Matrix nightly profile builds |
| `cross-compile.yml` | push/PR | ARM64 cross-compile verification |

---

## Guidelines for agents

### What agents should do

1. **Follow existing patterns** — stage scripts are pure Bash receiving env vars from `builder.py`; new stages must follow this contract.
2. **Keep `builder.py` as the single orchestrator** — do not introduce secondary Python entry points.
3. **Write tests for every change to `builder.py`** — the coverage target is 100%. Add or update tests in `tests/test_builder.py` or the relevant test file.
4. **Use `pytest` and `pytest-bdd`** — BDD scenarios belong in `tests/features/*.feature`.
5. **Validate JSON configuration** — all changes to `config/build.conf` must be valid JSON. Use `python3 -m json.tool config/build.conf` to verify.
6. **Respect the flattened env var contract** — stage scripts read `LFS_CONFIG_*` and `LFS_PROFILE_*`. Any new configuration key added to `build.conf` must be exported in `builder.py`'s environment propagation logic.
7. **Document new profiles** — add new profiles to the profile table in `README.md` and `builder.py`'s `ProfileManager`.

---

## 1. Commit Convention

Commit messages must follow this format:

```
<type>(<scope>): <short subject>

[optional body explaining why and how]

[optional footer with references]
```

**Allowed types:**

| Type | Usage |
|------|-------|
| `feat` | New feature (profile, option, stage) |
| `fix` | Bug fix (build, script, test) |
| `docs` | Documentation changes (README, comments) |
| `style` | Formatting, indentation, no functional change |
| `refactor` | Code rewrite without behavior change |
| `test` | Adding or modifying tests |
| `chore` | Maintenance tasks (deps, CI, config) |
| `perf` | Performance optimization |

**Common scopes:**

- `builder`: changes to `builder.py`
- `lfs`: scripts in `lfs/`
- `host`: scripts in `host/`
- `blfs`: scripts in `blfs/`
- `final`: scripts in `final/`
- `config`: config files (`config/build.conf`)
- `tests`: test files (`tests/`)
- `docs`: documentation
- `ci`: GitHub Actions workflows
- `profile`: profile modifications (`ProfileManager`)
- `branding`: branding system

**Examples:**

```
feat(profile): add audio-studio profile
fix(lfs): search C++ libs in /tools/lib and /tools/lib64
test(builder): add test for cross-compile environment
docs(readme): update stage order table
chore(ci): update GitHub Actions runner version
```

**Rules:**

- Subject must be in **imperative** mood (e.g., "add", "fix", "update").
- Subject must not exceed **50 characters**.
- Body (if present) must be separated from subject by a blank line, and limited to **72 characters per line**.
- Issue references must be in the footer (e.g., `Fixes #123`).

---

## 2. Code Structure

- **`builder.py`** is the single orchestrator. Any new logic must be integrated there via methods or classes.
- **Stage scripts** (`host/*.sh`, `lfs/*.sh`, etc.) are pure Bash scripts that receive environment variables from `builder.py`. They must **not** call other Python scripts or modify the environment globally.
- **Any new configuration** added in `config/build.conf` must be exported in `builder.py` via `_get_env()` as `LFS_CONFIG_*` and `LFS_PROFILE_*` variables.
- **Profiles** are defined in `ProfileManager` and must be documented in the table in `README.md`.

---

## 3. Testing

- **Coverage of `builder.py` must be 100%.** Any change to `builder.py` must be accompanied by corresponding tests.
- **Use `pytest`** (unit tests, integration tests) and `pytest-bdd` for functional scenarios.
- Tests must be run before every push:
  ```bash
  python3 -m pytest tests/ --cov=builder --cov-report=term-missing
  ```
- New BDD scenarios must be added in `tests/features/*.feature` with corresponding steps.

---

## 4. Documentation

- **Any stage modification** (addition, removal, reordering) must be reflected in the `README.md` table (section "Default stage order").
- **Any new CLI option** must be added to the "Command line reference" section of `README.md`.
- **Any new profile** must appear in the profile table (`README.md` and `builder.py`).
- **Comments in code** should explain *why* (not *what*).

---

## 5. Quality and Validation

- **ShellCheck**: all Bash scripts must be validated with `shellcheck` before commit.
  ```bash
  shellcheck lfs/*.sh host/*.sh blfs/*.sh final/*.sh
  ```
- **JSON**: the config file `config/build.conf` must be valid.
  ```bash
  python3 -m json.tool config/build.conf > /dev/null
  ```
- **PEP8**: Python code must follow PEP8. Use `black` or `flake8` if available.

---

## 6. Development Process

- **Do not commit directly to `main`** — use feature branches and open PRs.
- **PRs must include**: a clear description, issue references, and test results.
- **Before merging**: ensure all tests pass and coverage remains at 100%.
- **Breaking changes** must be discussed in an issue before implementation.

---

## 7. GitHub Actions Workflows

- **CI/CD workflows** are defined in `.github/workflows/`. Do not change their behavior without verifying that artifacts are still produced.
- **Cache workflows** (`packages-cache`, `rootfs-cache`) must be tested separately.

---

## 8. General Best Practices

- **Keep it simple**: avoid unnecessary complexity.
- **Follow existing patterns**: if a stage uses a certain approach, the new stage should do the same.
- **Do not introduce unnecessary external dependencies**.
- **Test on multiple distributions** (Debian, Fedora, Arch) if possible.

---

## 9. Ideal Commit Example

```
fix(lfs): search C++ libs in both /tools/lib and /tools/lib64

The toolchain installs C++ runtime libraries into /tools/lib64 on some
systems. The previous cp command failed because it only looked in /tools/lib.

Now the script searches both directories and copies from whichever exists.
Also add -L/tools/lib64 and corresponding rpath flags to CXX and LDFLAGS
to ensure the linker can find them.

Fixes the "cannot stat" error during the lfs-system stage.
```

---

### What agents should avoid

- **Do not modify stage execution order** without understanding downstream dependencies. Stages are tightly sequenced.
- **Do not add Python package dependencies** unless strictly necessary; `builder.py` is designed to run on a minimal host with only the Python standard library.
- **Do not commit secrets or credentials**. The build system uses shell variables; ensure no API keys, tokens, or passwords are hardcoded.
- **Do not rely on bash features unavailable in a minimal LFS chroot** — stage scripts target bash, but should avoid features that require a fully installed distro environment (e.g. bash completion libraries, `/etc/profile.d` sourcing). Prefer POSIX-compatible constructs where there is no functional reason to use bash-specific syntax.
- **Do not alter the branding directory structure** without updating `branding/branding.toml` and the branding stage script.
- **Do not remove or skip existing tests** to increase coverage artificially.
- **Do not touch docs.yml or mkdocs.yml** NEVER.

### Making changes to `builder.py`

1. Read `BUILD_STAGES`, `ProfileManager`, `LFSConfig`, `ScriptExecutor`, and `SourceDownloader` before making changes.
2. Ensure any new CLI flag is documented in the `README.md` command-line reference table.
3. Run `flake8` and `pytest` locally before pushing.
4. If adding a new profile, add it to the profiles table in `README.md`.

### Making changes to shell stage scripts

1. All stage scripts must be idempotent where possible (safe to re-run).
2. Use `set -e` and `set -u` at the top of every stage script.
3. Log meaningful progress messages — CI pipelines parse log output.
4. Honour the `--resume-from` flag by ensuring stages can detect already-completed work.

### Documentation

- `README.md` — primary user-facing documentation; keep the CLI reference table in sync with `builder.py`.
- `CHANGELOG.md` — add an entry for every user-visible change.
- `docs/` — extended documentation rendered by MkDocs (`mkdocs.yml`).
- `ADVANCED.md` — advanced usage and internal notes.
- `SECURITY.md` — security policy; consult before making security-sensitive changes.

---

## Running a build (not required for code changes)

```bash
# List available profiles
python3 builder.py --list-profiles

# Build default (xfce) profile
python3 builder.py

# Resume after a failure
python3 builder.py --resume-from <stage-name> --profile <profile> --output <output-dir>

# Build with cache
python3 builder.py --use-cache
```

Requires: Linux x86_64 host, 8+ GB RAM, 50+ GB free disk, Python 3.10+.

---

## Environment variables set by `builder.py` for stage scripts

| Variable | Description |
|---|---|
| `LFS` | Root mount point for the build tree |
| `PROFILE` | Active build profile name |
| `INIT_SYSTEM` | Init system (`systemd`, `sysvinit`, `openrc`, `runit`, `s6`) |
| `KERNEL_TYPE` | Kernel variant (`linux`, `linux-libre`, `gnu-hurd`, `freebsd`) |
| `BOOTLOADER` | Bootloader (`grub`, `uboot`, `aboot`) |
| `LFS_CONFIG_*` | Flattened keys from `config/build.conf` |
| `LFS_PROFILE_*` | Flattened keys from the active profile |

These variables are also preserved inside the built system at `/etc/lfs-builder-params.env`.
