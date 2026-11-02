# Design: Opt-In Local AI Assistant "knowledge" via Ollama

**Status:** Implemented design — see `../blfs/28-knowledge.sh`
**Created:** 2026-08-21
**Target:** Way Beyond Linux From Scratch (builder v0.52.x)

---

## 1. Executive Summary

This document describes an **optional, opt-in, fully local AI assistant
named "knowledge"** for systems built by this project. The runtime is
[Ollama](https://ollama.com) (MIT-licensed, free, open source) serving
open-weight models entirely on the user's machine. Nothing is sent to any
cloud service, which aligns with the project's privacy stance
(`blfs/16-privacy-tools.sh`, `security.privacy.disable_telemetry`).

When disabled (the default), the built system is byte-for-byte identical
to today's output. When enabled, the builder wires the assistant into the
image: the `knowledge` CLI wrapper, `/etc/knowledge/config.env`, an inert
init service for the chosen init system, the one-shot model provisioner,
and `/usr/lib/knowledge/install-engine.sh` — the pinned installer the
operator runs on the target. Neither the Ollama engine nor its weights is
ever part of the image (section 8 explains why, with measurements).

---

## 2. Goals

- **Free and open source**: Ollama engine + open-weight models only.
  No paid API keys, no vendor lock-in, no telemetry.
- **Opt-in**: disabled by default in `config/build.conf`; the `lg3d`
  showcase profile is the only one that turns it on by default (its
  `ProfileManager` entry sets `knowledge: True`), and any other profile
  can opt in with `--with-knowledge` or an explicit
  `knowledge.enabled=true`.
- **Offline-first**: once the operator has installed the engine and
  pulled weights on the target, the assistant works with no network
  connection at all. The image itself is deliberately the small half:
  integration, not runtime.
- **Follow the existing architecture contract**: one new Bash stage
  script driven by `LFS_CONFIG_*` environment variables exported from
  `builder.py`; no new Python entry point.
- **Init-system agnostic**: works with sysvinit and systemd first
  (the two CI-tested inits), with openrc/runit/s6 service definitions
  as a follow-up.

## 3. Non-Goals

- No cloud LLM backends (OpenAI, Anthropic, etc.) — out of scope by design.
- No training or fine-tuning pipeline; we only run pre-trained models.
- No GUI application of our own. The optional web UI (Open WebUI) is a
  third-party component, deferred to a later phase.
- No integration into the LFS/BLFS build process itself (the assistant
  is a feature of the *built* system, not of the builder).

---

## 4. Component Selection

| Component | Choice | License | Why |
|---|---|---|---|
| Inference engine | Ollama | MIT | Single Go binary + runner libs, daemon + CLI, GGUF model registry, first-class Linux support, no telemetry |
| Default model (8 GB+ RAM) | `qwen2.5-coder:7b` | Apache-2.0 | Strong coding assistant, runs on CPU-only hardware |
| Default model (4 GB RAM) | `llama3.2:3b` | Llama 3.2 Community | Small, general-purpose fallback |
| ARM64 models | Same GGUF families | — | Ollama ships aarch64 builds; models are arch-neutral GGUF |
| Web UI (later phase) | Open WebUI | MIT | Optional; heavy (Python/Node stack), therefore deferred |
| CLI wrapper | `knowledge` (new, small Bash script) | GPLv3 | Thin UX layer over `ollama run` |

Model defaults live in configuration, never hardcoded in scripts, so
users can swap any GGUF model available in the Ollama registry.

---

## 5. Architecture

```
+------------------------------------------------------------------+
| Built system                                                     |
|                                                                  |
|  knowledge (CLI wrapper, /usr/bin/knowledge)                     |
|       |                                                          |
|       v                                                          |
|  ollama CLI (/usr/bin/ollama) -----> ollama daemon (127.0.0.1)   |
|                                          |                       |
|                                          v                       |
|                                /var/lib/ollama/models (GGUF)     |
|                                                                  |
|  Init service: sysvinit bootscript OR systemd unit               |
+------------------------------------------------------------------+
```

Runtime layout inside the target rootfs:

```
/usr/bin/knowledge                  wrapper script
/etc/knowledge/config.env           assistant defaults (model, listen addr)
/etc/sysconfig/ollama               OLLAMA_HOST / OLLAMA_MODELS env file
/etc/init.d/ollama                  OR /etc/systemd/system/ollama.service
/usr/lib/knowledge/install-engine.sh   pinned on-demand engine installer
/usr/lib/knowledge/provision-models.sh one-shot model puller
/var/lib/ollama/                    model storage (owned by user `ollama`)

# Written by install-engine.sh on the target, never by the build:
/usr/bin/ollama                     engine binary
/usr/lib/ollama/                    bundled runner libraries
```

### 5.1 Request flow

1. User runs `knowledge "explain this error: ..."` (or plain
   `knowledge` for an interactive session).
2. The wrapper selects the configured model and invokes
   `ollama run <model>` with a project system prompt.
3. The daemon loads the GGUF weights from `/var/lib/ollama/models` and
   streams the answer on stdout. No network traffic leaves localhost.

---

## 6. Configuration Design

### 6.1 New key in `config/build.conf`

```json
"knowledge": {
  "enabled": false,
  "engine": "ollama",
  "engine_version": "0.12.6",
  "engine_sha256": "",
  "models": ["qwen2.5-coder:7b"],
  "default_model": "qwen2.5-coder:7b",
  "provision_models": "first-boot",
  "listen": "127.0.0.1:11434",
  "allow_network": false,
  "web_ui": false,
  "system_prompt_file": ""
}
```

Key semantics:

- `enabled` — master switch; the stage skips everything when false.
- `engine_sha256` — **mandatory when enabled**: the stage refuses to run
  without a pinned sha256. It no longer guards an unpack (the build
  unpacks nothing); it is the digest baked into `install-engine.sh`, so
  an empty value would ship an installer that trusts whatever the network
  returns.
- `provision_models` — only `first-boot` is supported. `build-time`
  provisioning started a daemon in the chroot and pulled weights into
  `$LFS/var/lib/ollama/models`, which *is* the image, so the stage now
  aborts on it and points at the on-demand installer.
- `listen` — bind address; defaults to loopback only. A non-loopback
  address is rejected unless `allow_network=true` is set explicitly.
- `web_ui` — reserved for the deferred Open WebUI phase.

The `lg3d` profile wires the assistant by default, so `config/build.conf`
pins `engine_sha256` to the verified `ollama-linux-amd64.tgz` v0.12.6
digest (`de82adce2ab79235115d511ff22fcb099ac53b67127870f12b80198c033ec0a1`)
while keeping `enabled=false` globally: `_apply_profile_settings()` flips
`knowledge.enabled` on only for `lg3d` (from its `knowledge: True` flag),
and that digest is what the on-demand installer verifies on the target.
Any other profile that opts in inherits the same pinned checksum.

### 6.2 Environment contract

Per AGENTS.md, every key is flattened and exported by `builder.py`
`_get_env()` / `_flatten_config()`:

```
LFS_CONFIG_KNOWLEDGE_ENABLED=true
LFS_CONFIG_KNOWLEDGE_ENGINE=ollama
LFS_CONFIG_KNOWLEDGE_ENGINE_VERSION=0.12.6
LFS_CONFIG_KNOWLEDGE_ENGINE_SHA256=<64 hex chars>
LFS_CONFIG_KNOWLEDGE_MODELS=qwen2.5-coder:7b
LFS_CONFIG_KNOWLEDGE_DEFAULT_MODEL=qwen2.5-coder:7b
LFS_CONFIG_KNOWLEDGE_PROVISION_MODELS=first-boot
LFS_CONFIG_KNOWLEDGE_LISTEN=127.0.0.1:11434
LFS_CONFIG_KNOWLEDGE_ALLOW_NETWORK=false
```

The stage script reads only these variables; it never parses
`config/build.conf` itself.

### 6.3 CLI flag

New optional flag on `builder.py`:

```
--with-knowledge    Enable the local "knowledge" AI assistant (Ollama)
```

The flag is a convenience override; `config/build.conf` remains the
source of truth. Documented in the README command-line reference table.

---

## 7. Stage Design: `../blfs/28-knowledge.sh`

### 7.1 Placement

- Master list `BUILD_STAGES`: after `printing-scanning`, before
  `base-packages`.
- Runtime `get_build_stages()`: appended only when
  `knowledge.enabled=true`, immediately before the package-manager
  block so stage 14's manifest capture includes the assistant files
  in the LPM base set.

### 7.2 Script contract

Follows the same rules as every other stage:

- `set -euo pipefail`; idempotent (safe to re-run after
  `--resume-from knowledge`).
- Target-side commands run through a clean-environment chroot:
  `chroot "$LFS" /usr/bin/env -i HOME=/root TERM=... PATH=...`.
- Disabled runs exit 0 with a "skipped" log line — never fail a build
  that did not ask for the assistant.
- Dependencies already present at that point: curl, ca-certificates,
  tar (from blfs-base). No new hard dependencies.

### 7.3 Steps

1. **Guard**: `[ "$LFS_CONFIG_KNOWLEDGE_ENABLED" = "true" ] || exit 0`.
2. **Listen address check**: loopback only unless `allow_network=true`.
3. **Checksum check**: refuse to continue with an empty `engine_sha256`
   (it is the digest `install-engine.sh` will verify on the target).
4. **Architecture check**: `x86_64`/`aarch64` only — a pinned digest
   belongs to one archive.
5. **Reject `build-time` provisioning**: the weights would land inside
   `$LFS`, which is the image.
6. **Strip any engine already in `$LFS`** (`/usr/bin/ollama`,
   `/usr/lib/ollama`, `/var/lib/ollama/models`) and abort if it is still
   there — a resumed build or a restored pre-fix cache must not ship it.
7. **Create user/group** `ollama` (system account, no login shell,
   home `/var/lib/ollama`).
8. **Install wrapper + configuration**: `/usr/bin/knowledge`,
   `/etc/knowledge/config.env`, `/etc/sysconfig/ollama`.
9. **Install the init service, inert** (section 9): written, not enabled.
10. **Write `install-engine.sh`** with the pinned version, URL, digest and
    architecture substituted.
11. **Write `provision-models.sh`** and its one-shot service; both exit
    successfully while the engine is absent, so a boot stays clean.

---

## 8. Engine Source Strategy (Decision)

Ollama is not (yet) a BLFS book package, so the source strategy is a
project decision:

| Option | Pros | Cons |
|---|---|---|
| A. Official prebuilt tarball (release asset) | Simple, reproducible, matches upstream exactly, no Go toolchain needed | Not built from source; deviates from LFS philosophy |
| B. Build from source with Go | Full LFS/BLFS spirit | Requires bootstrapping Go in the chroot; long build; CI time cost |

**Decision: Option A** (prebuilt tarball) with hard integrity controls,
delivered **on the target rather than in the image**, mirroring how the
java-dev stage already consumes upstream binaries:

- The build downloads nothing. It generates
  `/usr/lib/knowledge/install-engine.sh`, which fetches the pinned URL
  `https://github.com/ollama/ollama/releases/download/v<version>/ollama-linux-<arch>.tgz`
  when the operator runs it.
- The sha256 **must** be pinned in configuration (`engine_sha256`): the
  stage refuses to run without it, and the generated installer verifies
  the digest and refuses to unpack a mismatch (verified by running the
  generated script against a wrong digest: it stops with `/usr`
  untouched).
- It also refuses to run unprivileged, re-checks `uname -m` against the
  architecture the pin was made for, and cleans its temporary archive on
  exit.
- Support both `x86_64` and `aarch64` archives selected from
  `$LFS_CONFIG_ARCHITECTURE`.

**Why not ship the engine**: `ollama-linux-amd64.tgz` v0.12.6 is
1 903 757 843 bytes of already deflate-packed data, so `mksquashfs -comp
xz` recovers almost none of it. With the engine inside, the lg3d live ISO
measured 2856 MB (systemd) / 2850 MB (sysvinit) in nightly #68/#69 --
above the 2 147 483 648-byte ceiling that makes GitHub reject the release
asset outright, and above the point where "the showcase ships an
assistant" silently meant "every image carries an inference runtime, plus
whatever weights the operator's model list pulls next". `$LFS` is both
the live squashfs and the tree Calamares copies to disk, so shipping it
also removed the user's choice.

Option B is recorded as a future improvement for users who require a
100% from-source system.

---

## 9. Init System Integration

The daemon starts at boot only when enabled, following the
`$INIT_SYSTEM` conditional pattern already used in the BLFS stages.

### 9.1 sysvinit

```
/etc/init.d/ollama              start/stop/status, runs as user `ollama`;
                                start refuses with a hint while
                                /usr/bin/ollama is absent
/etc/rc.d/rcS.d/S60ollama       boot symlink - created by install-engine.sh,
                                never by the build
/etc/sysconfig/ollama           OLLAMA_HOST / OLLAMA_MODELS env file
```

### 9.2 systemd

```
/etc/systemd/system/ollama.service
```

`User=ollama`, `Restart=on-failure`, `After=network.target`,
`WantedBy=multi-user.target`, and
`ConditionPathExists=/usr/bin/ollama` so the unit stays inert while the
engine is absent. The build does **not** link it into
`multi-user.target.wants`: enabling a daemon whose binary does not exist
only produces a failed unit at every boot. `install-engine.sh` runs
`systemctl enable --now ollama.service` once the binary is in place.
Installed only when `$INIT_SYSTEM = systemd`.

### 9.3 openrc / runit / s6 (follow-up)

Service definitions are straightforward to add later; they are out of
scope for the first implementation because CI does not currently build
those inits end-to-end.

---

## 10. LPM Integration

- The assistant's integration files live under standard paths, so stage
  14's per-package manifest capture produces a real binary package once
  registered — installed systems can then reinstall/upgrade the
  integration through the normal LPM repository pipeline.
- The engine is never part of that manifest, because it is not in `$LFS`
  when stage 14 runs. Putting it on a host system is
  `install-engine.sh`'s job, outside LPM: upstream ships no package
  metadata we could track, and its version cadence is pinned in
  configuration instead (section 17).
- Models are **not** LPM packages: weights are large, versioned
  independently, and live in `/var/lib/ollama`. Management stays with
  `ollama pull/rm` (and `knowledge model ...` wrappers).
- Removal path documented: removing the engine leaves
  `/var/lib/ollama` untouched; users delete weights manually.

---

## 11. `knowledge` CLI Wrapper (Design)

A small Bash wrapper (`/usr/bin/knowledge`) over `ollama run`:

```
knowledge                       start interactive chat (default model)
knowledge "question"            one-shot question
knowledge -m <model> "..."      explicit model
knowledge code <file>           explain/review a file (pipes content in)
knowledge shell "task"          suggest a shell command (never auto-runs)
knowledge model list|pull|rm    manage local models
knowledge status                daemon status, installed models
```

Design rules:

- Reads `/etc/knowledge/config.env` for the default model; user
  overrides via flags.
- **Never executes generated commands automatically.** Suggestions are
  printed for the user to review. This is a hard safety requirement
  (no `eval`, no `bash -c "$model_output"`).
- Works with the daemon down: prints a hint to start the service, and
  when the engine is not installed at all, points at
  `/usr/lib/knowledge/install-engine.sh` instead of failing obscurely.

---

## 12. Security and Privacy

- Daemon binds to `127.0.0.1` only; the stage rejects a non-loopback
  listen address unless `allow_network=true` is set explicitly.
- Runs as dedicated system user `ollama` (no login shell, no sudo).
- The engine is never installed by the build. On the target it is
  installed only after sha256 verification against the pinned
  `engine_sha256`; a mismatch, a wrong architecture or a non-root caller
  aborts before anything is unpacked.
- No telemetry: Ollama does not phone home except for explicit
  `ollama pull` downloads.
- Firewall: existing nftables rules from
  `blfs/15-security-hardening.sh` already deny inbound by default; no
  new inbound rule is added for the assistant.
- The assistant has **no elevated privileges**: it cannot write files
  or run commands on the user's behalf (see section 11).

---

## 13. Profile Integration

- No existing profile changes behavior. The assistant activates only
  through `knowledge.enabled=true` or `--with-knowledge`.
- Hardware guidance per profile (documented, not enforced):
  - `minimal`, `server`: works with `llama3.2:3b` on 4 GB RAM.
  - `xfce`/`gnome`/`kde` desktops: recommend 8 GB+ for the 7b model.
  - `arm64`/`pinebook`: 3b model only (RAM-constrained boards).

---

## 14. Resource Budget

| Item | Size (approx.) | In the image? |
|---|---|---|
| Ollama engine archive (`ollama-linux-amd64.tgz`) | 1.9 GB compressed | no |
| Ollama engine + runners, unpacked | ~2 GB | no (target only) |
| `llama3.2:3b` weights | 2.0 GB | no (target only) |
| `qwen2.5-coder:7b` weights | 4.7 GB | no (target only) |
| Integration shipped by blfs/28 | < 1 MB | yes |
| Runtime RAM (3b / 7b) | ~4 GB / ~8 GB | n/a |

Implications:

- `provision_models=build-time` is rejected outright: the weights land in
  `$LFS/var/lib/ollama/models`, which is inside the image, and the engine
  that would pull them is not there either.
- The image carries the integration only, so live ISOs stay within
  GitHub's 2 147 483 648-byte release-asset ceiling and the operator
  decides whether to spend 2 GB of disk and a multi-gigabyte download on
  an inference runtime.

---

## 15. Test Plan

Following project rules (builder.py coverage 100%, guardrails for every
behavioral change):

1. **Unit tests (`tests/test_builder.py`)**
   - Default config ships the `knowledge` section, disabled.
   - `--with-knowledge` sets `knowledge.enabled=true` and refreshes
     the executor.
   - `LFS_CONFIG_KNOWLEDGE_*` flattening (booleans lowered, lists
     comma-joined).
   - `get_build_stages()` includes the stage only when enabled, placed
     before `base-packages`.
   - Master `BUILD_STAGES` lists the stage between `printing-scanning`
     and `base-packages`.
2. **Guardrail tests (`tests/test_acceptance_shell.py`)**
   - `../blfs/28-knowledge.sh` exists, shellcheck-clean,
     `set -euo pipefail`, guarded on `LFS_CONFIG_KNOWLEDGE_ENABLED`.
   - Refuses to run without a pinned sha256; the generated installer
     keeps the verification, the root gate and the architecture gate.
   - The build fetches and unpacks nothing (`curl`/`tar`/`wget` appear
     only inside the installer written for the target), and strips an
     engine a resumed or restored `$LFS` may still hold.
   - Services ship inert: no enable symlink at build time, and
     `ConditionPathExists=/usr/bin/ollama` on the unit.
   - `build-time` provisioning is rejected.
   - Both generated target scripts parse as POSIX `sh` after token
     substitution.
   - `final/16-validate-build.sh` fails the build when the engine is
     present in the finished rootfs.
   - Listen address defaults to loopback; non-loopback requires the
     explicit override.
   - The `knowledge` wrapper never contains `eval` or auto-execution
     of model output.

---

## 16. Documentation Updates Required

- `README.md`: stage order table, CLI reference (`--with-knowledge`).
- `CHANGELOG.md`: entry under Added.
- This design document (`docs/KNOWLEDGE_DESIGN.md`).
- **Do not touch `mkdocs.yml`** (per AGENTS.md).

---

## 17. Follow-Up Roadmap

- [ ] openrc/runit/s6 service definitions
- [ ] `first-boot` provisioning polish (proxy support)
- [ ] Evaluate Open WebUI as optional `web_ui=true`
- [ ] Evaluate from-source Go build for 100%-source purists
- [ ] Curated system prompt tuned for LFS/BLFS support questions

---

## 18. Open Questions

1. Pin a specific Ollama release cadence policy (pin one version per
   project release, bump with changelog entry + new sha256).
2. Should the `full` profile default `knowledge.enabled=true`?
   Proposal: no — keep it opt-in everywhere for at least one release.
3. Whether to ship a curated system prompt as a branding asset.
