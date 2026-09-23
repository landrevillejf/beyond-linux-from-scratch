# LPM Control Application Contract — lg3d desktop

A binding specification for the agent that builds the **graphical application
that controls LPM**, the package manager of this Beyond Linux From Scratch
(BLFS) system, running inside the **Project Looking Glass (lg3d)** 3D desktop.

> **Audience.** The lg3d application agent (and any human reviewing its work).
> **The one rule.** The application is a *front-end*. It MUST drive LPM only
> through the installed `/usr/bin/lpm` command-line interface. It MUST NOT
> re-implement, fork, or bypass LPM's dependency resolution, database writes,
> locking, checksum/GPG verification, transactional rollback, or history.
> **Companion contract.** The runtime display rules are normative in
> [`lfs-x11-contract.md`](lfs-x11-contract.md); this document inherits them and
> only adds the LPM-control requirements.
> **Keywords.** MUST / MUST NOT / SHOULD follow RFC 2119. Everything under
> §4 (Requirements), §5 (Integration contract) and §7 (Prohibitions) is
> normative.

---

## 1. Mandate

Deliver a single graphical application — referred to here as the **LPM
Console** — that lets a user browse, install, remove, upgrade, hold, verify and
build packages on the running BLFS system, and manage repositories and profiles,
**by invoking `lpm`**. The application runs as a client inside the lg3d session
described in `lfs-x11-contract.md` and appears composited in the 3D scene like
any other X11/Java window.

LPM is already installed on the target by build stage 19 (`blfs/19-lpm.sh` →
`/usr/bin/lpm`, version **2.7.0**, GPLv3). The application is a *controller* of
that binary, never a replacement for it.

## 2. Why a front-end only (rationale)

LPM is a single self-contained Bash program that owns all correctness-critical
behaviour:

- **Mutual exclusion.** Every mutating command takes an exclusive `flock` on
  `/var/lock/lpm.lock` (with an atomic-`mkdir` fallback). Only one writer may
  touch the database at a time; a second instance exits with
  `Another lpm instance is running. Exiting.` and status `1`.
- **Transactional installs.** File installation is atomic with automatic
  rollback on failure; the system is left unchanged if a copy fails.
- **Integrity & authenticity.** SHA256 checksum verification and optional GPG
  signature verification run inside LPM before files land on disk.
- **Dependency resolution.** Version constraints (`pkg>=1.2`, `pkg=2.0`),
  topological install order and circular-dependency detection are LPM's job.
- **Auditability.** Every install/upgrade/reinstall/remove/hold/unhold appends a
  `timestamp|action|package|version` record to `/var/lib/lpm/history.log`.

Re-implementing any of this in the GUI would fork the source of truth, skip the
lock, and corrupt the database. The GUI therefore **shells out to `lpm`** and
presents its results.

## 3. Runtime environment (normative, inherited)

The application MUST run inside the lg3d X11 session and honour
`lfs-x11-contract.md`:

- **Display.** A bare **Xorg on `:0`** with lg3d as the sole window
  manager/compositor. No Wayland, no XWayland, no second WM/DE.
- **Java.** **JDK 21** (`JAVA_HOME=/opt/jdk-21`), the runtime the `java-dev`
  stage installs and lg3d itself runs on. Gradle, if used, is pinned to 8.14
  (which cannot run on Java 25+).
- **Composited window.** The application MUST appear as an ordinary top-level
  window that lg3d redirects and textures into the scene (a native X11 client or
  a Java/Swing window). It MUST NOT attempt to claim `SubstructureRedirect`,
  act as a WM, or otherwise compete with lg3d for display ownership.
- **X client libraries.** AWT/Swing link against the `libX*` stack listed in
  `lfs-x11-contract.md` §3.4; the host already provides them.

Recommended implementation: a **Java 21 Swing** application (Swing renders over
the same X11 client stack lg3d composites, needs no extra toolkit, and shares the
pinned JDK). Any toolkit that produces a standard X11 top-level window is
acceptable provided it runs on the host without adding a display server or WM.

## 4. Functional requirements (normative — MUST provide)

The LPM Console MUST expose, at minimum, the operations below. Each maps to one
`lpm` invocation; the mapping is normative (do not invent flags).

| Feature | Underlying command | Notes |
|---|---|---|
| List installed packages | `lpm --no-color list` | name, version, description |
| Search the database | `lpm --no-color search <pattern>` | case-insensitive literal substring |
| Package details | `lpm --no-color info <pkg>` | version, description, deps, checksum, status |
| Reverse dependencies | `lpm --no-color why <pkg>` (alias `rdepends`) | who depends on `<pkg>`, installed marked |
| Install | `lpm install <pkg>` | resolves deps; supports `name-version` |
| Remove | `lpm remove <pkg>` | `--keep-files` option preserved |
| Upgrade one | `lpm update <pkg>` | atomic reinstall to DB version |
| Upgrade all | `lpm upgrade` | skips held packages |
| Preview upgrades | `lpm --no-color upgradable` | read-only; flags `(held)` |
| Reinstall | `lpm reinstall <pkg>` | forced re-fetch of an installed package |
| Orphan removal | `lpm autoremove` | never touches base/held packages |
| Hold / unhold / list holds | `lpm hold <pkg>` / `lpm unhold <pkg>` / `lpm holds` | pins against `upgrade` |
| History | `lpm --no-color history [N]` | default 50 entries |
| Integrity check | `lpm verify [pkg]` (alias `check`) | non-zero exit if any file modified/missing |
| Sync database | `lpm update-db` | fetches `<url>/packages.list` per remote |
| Clean cache | `lpm clean` | removes cached `.tar.xz` + build artifacts |
| Profiles | `lpm --no-color list-profiles`, `lpm add-profile <prof>` | predefined package collections |
| Kernel deps | `lpm --no-color kernel-deps [--all]`, `lpm rebuild-kernel` | kernel-dependent package set |
| Build from source | `lpm build <source\|.lpm>` | honours `--recipe/--no-install/--desc/--deps` |
| Version / help | `lpm version`, `lpm help` | surface LPM version in the UI |

Global options the UI MUST be able to pass through: `--dry-run`, `--force`,
`--quiet`, `--verbose`, `--no-color`, `--sysroot <dir>`.

### 4.1 Dry-run preview (MUST)

Every mutating action (install, remove, update, upgrade, autoremove,
add-profile, reinstall, rebuild-kernel, build) MUST offer a **preview** that runs
the same command with `--dry-run` and shows exactly what LPM reports before the
user commits. `--dry-run` is a first-class LPM feature; the UI MUST NOT simulate
the plan itself.

### 4.2 Confirmation (MUST)

Destructive or system-wide actions (`remove`, `autoremove`, `upgrade`,
`rebuild-kernel`) MUST require explicit user confirmation showing the resolved
package list from the `--dry-run` preview.

## 5. Integration contract (normative — how to talk to LPM)

### 5.1 Invocation

- The application MUST call the installed binary **`/usr/bin/lpm`** (discoverable
  via `PATH`); it MUST NOT embed a copy of `blfs/19-lpm.sh` or re-implement it.
- Every invocation MUST pass **`--no-color`** so output contains no ANSI escape
  sequences, and MUST capture **stdout and stderr separately**. LPM writes
  progress/log lines (`[INFO]`, `[WARNING]`, `[ERROR]`, `[SUCCESS]`, `[DEBUG]`)
  to **stderr** and most tabular data to **stdout**.
- Arguments MUST be passed as an argument vector (no shell string interpolation)
  to avoid word-splitting and injection; package names/patterns come from the
  user.
- Use the **canonical command names**. The dispatcher only recognises the aliases
  `why|rdepends`, `verify|check`, `help|--help|-h` and `version|--version|-v`;
  other aliases quoted in `docs/lpm.md` (e.g. `add`, `rm`, `ls`, `find`, `sync`)
  are **not** wired in `main()` and fall through to `Unknown command` with status
  `1`. The UI MUST issue `install`, `remove`, `list`, `search`, `update-db`.

### 5.2 Exit codes and error surfacing (MUST)

- `0` = success. Non-zero = failure; LPM's fatal path is `die()` → status `1`.
- `lpm verify` returns **non-zero when any file is modified or missing** even
  though it "ran fine"; the UI MUST treat non-zero verify as a *result state*
  (integrity problems found), not merely a crash.
- On any non-zero exit the UI MUST surface LPM's own stderr message verbatim
  (e.g. `Checksum mismatch for <pkg>`, `Circular dependency detected: <pkg>`,
  `Package file not found: …`, `Another lpm instance is running. Exiting.`). It
  MUST NOT swallow the error or replace it with a generic dialog.

### 5.3 Concurrency / locking (MUST)

- LPM holds `/var/lock/lpm.lock` for the duration of a mutating command. The UI
  MUST serialize its own LPM calls (one at a time), MUST disable mutating
  controls while an operation is running, and MUST gracefully present the
  `Another lpm instance is running. Exiting.` failure (e.g. a terminal or another
  UI holds the lock) with a retry affordance.

### 5.4 Privilege escalation (MUST)

- Mutating operations require root (`REQUIRE_ROOT=true` in LPM defaults); reading
  may also need access to `/var/lib/lpm`. The application SHOULD run its own
  process **unprivileged** and escalate **per-operation**.
- Escalation MUST use a mechanism present on the host — preferred: **`pkexec`
  (polkit)** with a dedicated policy action for LPM; acceptable fallback: a
  graphical `sudo` prompt. The UI MUST NOT hard-code credentials and MUST NOT run
  the whole GUI as root when an unprivileged read path is possible.
- Read-only views (`list`, `search`, `info`, `upgradable`, `history`, `holds`,
  `why`, `version`) SHOULD run unprivileged.

### 5.5 Reading state (MAY read the DB directly, read-only)

For fast, structured listing the application MAY read LPM's database files
**read-only** instead of scraping text, using these exact formats:

| File (`/var/lib/lpm`) | Format | Use |
|---|---|---|
| `packages.list` | `name\|version\|description\|deps\|checksum` | available packages |
| `installed.list` | `name version` | installed packages |
| `file_index` | `/path package-version` | file ownership |
| `holds.list` | one package name per line | pinned packages |
| `history.log` | `timestamp\|action\|package\|version` | transaction log |
| `kernel_deps.list` | `pkg\|kernel\|type` | kernel-dependent packages |

Config lives at `/etc/lpm/lpm.conf`, repositories at `/etc/lpm/repos.d/*.conf`
(`name=url` lines), profiles at `/etc/lpm/profiles.json`. **Any write to these
paths MUST go through the corresponding `lpm` command**, never by editing the
files from the GUI (that would bypass the lock, history and validation).

### 5.6 Long-running operations (MUST)

`install`, `upgrade`, `build`, `update-db`, `add-profile` and `verify` can run
for a long time. The UI MUST run them off the event-dispatch thread, stream
stdout/stderr into a log view live, show an indeterminate or stage-based progress
indicator, and allow the user to view (not silently kill) the running output. If
cancellation is offered it MUST terminate the child `lpm` process group cleanly;
the UI MUST NOT leave a half-applied state that LPM's own rollback would not
already handle.

## 6. Packaging, installation and launch (normative)

- The application MUST be delivered as a native **LPM package** (`.tar.xz` with
  the `files/` + optional hooks layout described in `docs/lpm.md`), so LPM itself
  installs and tracks it. It SHOULD be installable with `lpm install
  lpm-console`.
- Recommended install layout (adjust names consistently if changed):
  - Program tree under `/opt/lpm-console/`.
  - Launcher symlink `/usr/bin/lpm-console`.
  - A `.desktop` file under `/usr/share/applications/` (name, icon,
    `Exec=lpm-console`, `Categories=System;PackageManager;`) so lg3d's
    application launcher/switcher can start it.
  - If polkit is used: a policy file under `/usr/share/polkit-1/actions/`.
- The application MUST start correctly when launched as an lg3d session client on
  `:0` (it MUST NOT require a display manager, a system tray, or a specific DE).

## 7. Prohibitions (normative — MUST NOT)

- **MUST NOT** re-implement LPM logic (dependency resolution, checksums, GPG,
  rollback, DB writes) or copy `blfs/19-lpm.sh` into the app.
- **MUST NOT** write to `/var/lib/lpm`, `/etc/lpm`, `/var/log/lpm` or the lock
  file directly; all mutations go through `lpm`.
- **MUST NOT** run mutating `lpm` commands concurrently or bypass `/var/lock/
  lpm.lock`.
- **MUST NOT** parse colorized output — always pass `--no-color`.
- **MUST NOT** act as a window manager/compositor or claim the X root; it must
  coexist with lg3d per `lfs-x11-contract.md`.
- **MUST NOT** require Wayland/XWayland, a display manager, or a second desktop
  environment.
- **MUST NOT** hard-code passwords/tokens; use polkit/`sudo` escalation.
- **MUST NOT** assume a specific init system or a network beyond what `lpm
  update-db` already performs.

## 8. Acceptance criteria (how the agent proves compliance)

All of the following MUST hold before the application is declared compliant. Run
them inside the provisioned lg3d session on `:0`.

1. **Launch.** The app starts from the lg3d desktop (launcher or
   `lpm-console`) and its window is composited in the 3D scene; no `BadAccess`,
   no second WM, no crash. `glxinfo -B` still reports direct rendering (lg3d
   owns GL).
2. **Read path.** Installed list, `search`, `info`, `upgradable`, `history`,
   `holds` and `why` display data that matches `lpm --no-color <cmd>` output and
   the DB files in §5.5.
3. **Preview parity.** For install/upgrade/remove/autoremove, the `--dry-run`
   preview shows the exact package set LPM would change, and committing runs the
   same command without `--dry-run`.
4. **Install end-to-end.** Installing a package with dependencies succeeds, the
   progress/log view streams LPM's stderr, the new package appears in `list`, and
   a matching record is appended to `history.log`.
5. **Lock handling.** With a second `lpm` holding the lock, a mutating action
   surfaces `Another lpm instance is running. Exiting.` and offers retry instead
   of hanging or corrupting state.
6. **Privilege separation.** The GUI process runs unprivileged; a mutating action
   triggers exactly one polkit/`sudo` prompt; cancelling the prompt aborts the
   action cleanly with no partial change.
7. **Error fidelity.** A forced failure (e.g. installing a non-existent package,
   or a checksum mismatch) shows LPM's verbatim `[ERROR]` message and a non-zero
   status is reflected in the UI.
8. **Verify state.** `lpm verify` non-zero (a modified file) is presented as an
   integrity result, not as an application crash.
9. **Self-packaging.** `lpm install lpm-console` (or `lpm remove lpm-console`)
   installs/removes the app cleanly via its own `.tar.xz` package; `lpm info
   lpm-console` reports it.

Record the output/evidence of (1)–(9) as the compliance artefact.

## 9. Deliverables

1. Source tree for the LPM Console (Java 21 / Swing recommended), buildable with
   the pinned toolchain (Gradle 8.14 if Gradle is used).
2. The LPM `.tar.xz` package plus the `post-install.sh`/`post-remove.sh` hooks
   needed to register the launcher, `.desktop` entry and polkit action.
3. A short README covering: how to build, how to install via `lpm`, how to launch
   inside lg3d, and the exact `lpm` commands each screen issues.
4. The §8 acceptance evidence.

## 10. References

- [`lfs-x11-contract.md`](lfs-x11-contract.md) — normative lg3d / Xorg display
  contract (display ownership, extensions, JDK 21, session unit).
- [`docs/lpm.md`](docs/lpm.md) — full LPM command reference, package format,
  database layout, hooks, global options.
- [`docs/LPM_DOCUMENTATION.md`](docs/LPM_DOCUMENTATION.md) — LPM architecture,
  build-time DB seeding, system-updater integration.
- `blfs/19-lpm.sh` — the LPM implementation (`/usr/bin/lpm`, v2.7.0); the
  authoritative command surface and exit behaviour.
- `blfs/30-install-lg3d.sh` — the lg3d install/session stage (where `/opt/lg3d`,
  `/usr/bin/lg3d` and the systemd session unit come from).
- `config/lpm.conf`, `config/lpm-profiles.json` — shipped LPM configuration and
  profile definitions.
