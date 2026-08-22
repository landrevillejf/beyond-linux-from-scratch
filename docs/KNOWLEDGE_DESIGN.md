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
to today's output. When enabled, the builder installs the Ollama daemon,
an init service matching the chosen init system, the `knowledge` CLI
wrapper, and (optionally) pre-provisioned model weights.

---

## 2. Goals

- **Free and open source**: Ollama engine + open-weight models only.
  No paid API keys, no vendor lock-in, no telemetry.
- **Opt-in**: disabled by default in `config/build.conf`; no profile
  ships it unless the user asks for it (`--with-knowledge`).
- **Offline-first**: the assistant must work with no network connection.
  Model weights are either baked into the image at build time or pulled
  once at first boot, then cached locally.
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
/usr/bin/ollama                  engine binary (+ bundled runner libs)
/usr/bin/knowledge               wrapper script
/etc/knowledge/config.env        assistant defaults (model, listen addr)
/var/lib/ollama/                 model storage (owned by user `ollama`)
/etc/sysvinit/ollama             OR /etc/systemd/system/ollama.service
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
- `engine_sha256` — **mandatory when enabled**: the stage refuses to
  install the engine without a pinned sha256 checksum (secure by
  default; no unverified binary is ever unpacked into the rootfs).
- `provision_models` — `build-time` (weights downloaded during the
  build and baked into the image; fully offline first boot) or
  `first-boot` (image stays small; a one-shot boot service pulls models
  when network is available). Default is `first-boot` to keep images
  small and CI builds fast.
- `listen` — bind address; defaults to loopback only. A non-loopback
  address is rejected unless `allow_network=true` is set explicitly.
- `web_ui` — reserved for the deferred Open WebUI phase.

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
3. **Checksum check**: refuse to continue with an empty `engine_sha256`.
4. **Disk preflight** (`build-time` provisioning): estimate engine +
   model sizes and fail fast with a clear message when the target
   filesystem is too small.
5. **Install engine**: download the pinned release tarball from
   `github.com/ollama/ollama/releases`, verify the sha256, extract into
   `/usr` (idempotent: skipped when the binary already exists).
6. **Create user/group** `ollama` (system account, no login shell,
   home `/var/lib/ollama`).
7. **Install init service** per `$INIT_SYSTEM` (section 9).
8. **Install `knowledge` wrapper** + `/etc/knowledge/config.env`.
9. **Provision models**: `build-time` starts the daemon, pulls each
   model, stops the daemon; `first-boot` installs a one-shot provision
   service instead.

---

## 8. Engine Source Strategy (Decision)

Ollama is not (yet) a BLFS book package, so the source strategy is a
project decision:

| Option | Pros | Cons |
|---|---|---|
| A. Official prebuilt tarball (release asset) | Simple, reproducible, matches upstream exactly, no Go toolchain needed | Not built from source; deviates from LFS philosophy |
| B. Build from source with Go | Full LFS/BLFS spirit | Requires bootstrapping Go in the chroot; long build; CI time cost |

**Decision: Option A** (prebuilt tarball) with hard integrity controls,
mirroring how the java-dev stage already consumes upstream binaries:

- Download from the pinned release URL
  `https://github.com/ollama/ollama/releases/download/v<version>/ollama-linux-<arch>.tgz`.
- The sha256 **must** be pinned in configuration (`engine_sha256`);
  the stage refuses to run without it and aborts on any mismatch.
- Support both `x86_64` and `aarch64` archives selected from
  `$LFS_CONFIG_ARCHITECTURE`.

Option B is recorded as a future improvement for users who require a
100% from-source system.

---

## 9. Init System Integration

The daemon starts at boot only when enabled, following the
`$INIT_SYSTEM` conditional pattern already used in the BLFS stages.

### 9.1 sysvinit

```
/etc/sysvinit/ollama            start/stop/status, runs as user `ollama`
/etc/rc.d/rcS.d/S60ollama       boot symlink
/etc/sysconfig/ollama           OLLAMA_HOST / OLLAMA_MODELS env file
```

### 9.2 systemd

```
/etc/systemd/system/ollama.service
```

`User=ollama`, `Restart=on-failure`, `After=network.target`,
`WantedBy=multi-user.target`. Installed only when
`$INIT_SYSTEM = systemd`.

### 9.3 openrc / runit / s6 (follow-up)

Service definitions are straightforward to add later; they are out of
scope for the first implementation because CI does not currently build
those inits end-to-end.

---

## 10. LPM Integration

- The assistant's files live under standard paths, so stage 14's
  per-package manifest capture produces real binary packages once
  registered — installed systems can then reinstall/upgrade through
  the normal LPM repository pipeline.
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
- Works with the daemon down: prints a hint to start the service.

---

## 12. Security and Privacy

- Daemon binds to `127.0.0.1` only; the stage rejects a non-loopback
  listen address unless `allow_network=true` is set explicitly.
- Runs as dedicated system user `ollama` (no login shell, no sudo).
- Engine binary is installed only after sha256 verification against
  the pinned `engine_sha256`; an empty or mismatched checksum aborts.
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

| Item | Size (approx.) |
|---|---|
| Ollama engine + runners | 1.5 GB |
| `llama3.2:3b` weights | 2.0 GB |
| `qwen2.5-coder:7b` weights | 4.7 GB |
| Runtime RAM (3b / 7b) | ~4 GB / ~8 GB |

Implications:

- `provision_models=build-time` grows the image accordingly; the stage
  runs a disk preflight and fails fast with a clear message instead of
  dying mid-copy.
- Default `provision_models=first-boot` keeps images and CI builds
  small; the one-shot service pulls weights after installation.

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
   - Refuses to install without a pinned sha256; verifies the checksum
     before extraction.
   - Listen address defaults to loopback; non-loopback requires the
     explicit override.
   - Init service installed only for the active `$INIT_SYSTEM`.
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
