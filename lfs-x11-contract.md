# LFS Host Contract — X11 (Xorg), **not** Wayland

A binding specification for the agent that builds and provisions the **Linux From
Scratch (LFS)** host on which Project Looking Glass (lg3d) runs as the display's
**window manager + compositor**.

> **Audience.** The system-provisioning agent (and any human reviewing its work).
> **The one rule.** Install and boot a **bare X11 / Xorg** session. **Do not**
> install or boot a **Wayland** compositor as the session, and **do not** rely on
> **XWayland**. lg3d's display-ownership features are X11-only; on Wayland they
> do not work and cannot be made to work by configuration.
> **Keywords.** MUST / MUST NOT / SHOULD follow RFC 2119. Everything under
> §3 (Requirements) and §4 (Prohibitions) is normative.

---

## 1. Mandate

The LFS host MUST provide a **dedicated Xorg server on `:0`** with **no display
manager** and **no other window manager or compositor** running, and MUST start
**lg3d as the X session** (the WM/compositor). Wayland (GNOME/mutter, KDE KWin,
wlroots, Sway, Hyprland, …) MUST NOT be the session, and XWayland MUST NOT be
treated as a substitute.

This is not a preference. It is a hard consequence of how lg3d owns a display
(§2). A host that violates this contract will fail at lg3d startup, not degrade
gracefully.

## 2. Rationale (why X11 and why not Wayland)

lg3d's compositor mode revives the original 2006 ambition — running **real X11
applications as textured windows inside the 3D scene**. To do that it must *be*
the window manager and compositor of the X display:

- It claims **`SubstructureRedirect`** on the **root window** (the WM takeover)
  and calls **`CompositeRedirectSubwindows`**, so the X server redirects every
  top-level client window into an off-screen pixmap.
- On each **`DamageNotify`** it reads the damaged region back (via **MIT-SHM**,
  falling back to `GetImage`) into a `BufferedImage` and uploads it as a texture
  on that window's `NativeWindow3D` quad.
- Physical input on the `Canvas3D` is picked in 3D, mapped back to the client
  window's pixel coordinates, and re-injected with **XTest**; focus follows the
  pointer via `XSetInputFocus`.

Why that **cannot** run on Wayland:

1. **`SubstructureRedirect` requires being the only WM.** lg3d MUST be the sole
   window manager on the display. Under any existing session (GNOME/mutter, KDE,
   or XWayland) the claim fails immediately with **`BadAccess`**.
2. **XWayland has no single redirectable X root.** In a Wayland session
   `DISPLAY=:0` is **XWayland**, whose root is already owned by the Wayland
   compositor and whose top-level X windows are each mapped to their own Wayland
   surface. There is no X root for lg3d to redirect and composite.
3. **No client-side redirect / foreign-toplevel on Wayland.** A Wayland *client*
   cannot enumerate, redirect, or focus other applications' surfaces. Compositing
   foreign windows is only possible for the compositor itself — i.e. only if lg3d
   *were* the Wayland compositor.
4. **No Wayland compositor exists in this codebase.** lg3d has Wayland *detection*
   only; there is no Wayland protocol implementation. X11 is therefore the sole
   supported display-ownership path today.
5. **Global keys (e.g. real Alt+Tab).** A Wayland/XWayland host (GNOME) globally
   grabs keys such as `Alt+Tab`, so lg3d never receives them. Only when lg3d owns
   the X display does it receive the real `Alt+Tab` (the trigger for the
   application-switcher feature and for cycling *external* apps).

## 3. Requirements (normative — MUST provide)

### 3.1 Display server
- **Xorg** (the `xorg-server` package) running on **`:0`**, started with no
  competing WM/DE. `-nolisten tcp` SHOULD be set (local socket only).
- Input driver stack: **`xf86-input-libinput`** (or `xf86-input-evdev`) and
  **`xkeyboard-config`**.
- Session hand-off via **`xinit`** (or an equivalent that starts Xorg and launches
  lg3d as the session client, and exits Xorg when lg3d exits). No display manager
  is required; if one is used it MUST launch a **bare Xorg session with no WM**.

### 3.2 X extensions
Xorg MUST expose all of the following (they are built into a stock Xorg build and
MUST NOT be disabled). This is the exact set lg3d negotiates at startup:

| Extension | Purpose in lg3d |
|---|---|
| **Composite** | redirect client windows into off-screen pixmaps |
| **DAMAGE** | repaint notifications for redirected windows |
| **XFIXES** | cursor-shape notifications and region primitives |
| **XTEST** | synthetic pointer/keyboard injection (input forwarding) |
| **SHAPE** | non-rectangular window support |
| **MIT-SHM** | shared-memory pixel readback (fast path) |

### 3.3 OpenGL / GLX
- **Mesa** (or the vendor driver) providing **GLX** with **DRI3** and the GPU
  **DDX** (`modesetting` or the vendor X driver), plus `libdrm`. Java 3D (Jogamp)
  needs a **hardware GL context** on the `Canvas3D`; software-only GL is not a
  supported production target.

### 3.4 X client libraries for the JDK
OpenJDK's AWT/Swing links against the X11 client stack at runtime. The host MUST
provide (typical BLFS package names): **`libX11`, `libXext`, `libXrender`,
`libXtst`, `libXi`, `libXrandr`, `libXinerama`, `libXcursor`, `libXxf86vm`,
`libXfixes`, `libXt`, `libXScrnSaver`, `libxcb`, `libXau`, `libXdmcp`**, plus
**`fontconfig`** and **`freetype`**.

### 3.5 Java runtime
- **JDK 21** (`JAVA_HOME` set). Gradle 8.14 cannot run on Java 25+; the toolchain
  is pinned to 21. A headless JRE is insufficient — a real display + GL are
  required.

### 3.6 lg3d launch configuration
lg3d MUST be started in compositor mode:
- `./run-lg3d.sh -x`  — or —  `./gradlew :lg3d-core:run -Pcompositor`.
- This selects `lg.configurl=lgconfig_1p_x_composite.xml`
  (`WinSysAWT` + `X11IntegrationModule`), sets `lg3d.x11.compositor=true`, and
  applies the required `java.desktop` `--add-exports`/`--add-opens` JVM arguments.
  **`lg3d-core/build.gradle` is the source of truth for those JVM flags** — do not
  hand-maintain a divergent list.
- lg3d normally discovers its own `Canvas3D` window id automatically (that is what
  the `--add-exports java.desktop/sun.awt=ALL-UNNAMED` enables). If discovery
  fails on the target, pin it with `-Dlg3d.x11.ownwindowid=<id>` (e.g. via
  `JAVA_TOOL_OPTIONS`).

A systemd unit expressing the required hand-off (see also the README's
*Deployment target (Linux From Scratch)*):

```ini
# /etc/systemd/system/lg3d-compositor.service
[Unit]
Description=Project Looking Glass as the X11 session (window manager + compositor)
After=systemd-user-sessions.service

[Service]
Environment=JAVA_HOME=/opt/jdk-21
ExecStart=/usr/bin/xinit /opt/lg3d/run-lg3d.sh -x -- /usr/bin/Xorg :0 vt1 -nolisten tcp
Restart=on-failure

[Install]
WantedBy=graphical.target
```

## 4. Prohibitions (normative — MUST NOT)

- **MUST NOT** install or enable a Wayland compositor as the session
  (gnome-shell/mutter, kwin_wayland, wlroots, sway, hyprland, …).
- **MUST NOT** rely on **XWayland** to satisfy the X11 requirement — it cannot
  (see §2.2).
- **MUST NOT** run any other window manager or desktop environment on `:0`
  alongside lg3d (it must be the sole WM, or the `SubstructureRedirect` claim
  fails with `BadAccess`).
- **MUST NOT** disable or omit any extension in §3.2, and MUST NOT build Xorg
  without Composite/Damage/XTest/XFixes/SHAPE/MIT-SHM.
- **MUST NOT** substitute a software-only GL stack for the production target.

## 5. Acceptance criteria (how the agent proves compliance)

All of the following MUST hold on the provisioned host before it is declared
compliant:

1. **Extension probe (authoritative).** From the lg3d checkout, with the target
   Xorg running and `DISPLAY=:0`:
   ```bash
   ./gradlew :lg3d-core:verifyX11Extensions        # add --args=':N' for a non-default display
   ```
   Output MUST end with `All required X extensions are available. Stage 0 verified.`
   and exit `0`. Any `MISSING` line (or a non-zero exit) fails the contract. The
   task self-skips when `$DISPLAY`/the X socket is absent — that skip is **not** a
   pass; run it against the real session.
2. **Cross-check with X tooling.** `xdpyinfo -queryExtensions | grep -Ei
   'Composite|DAMAGE|XFIXES|XTEST|SHAPE|MIT-SHM'` lists all six.
3. **Sole-WM check.** lg3d starts in compositor mode **without** a `BadAccess`
   error on the root-window `SubstructureRedirect` claim (proves no competing
   WM/compositor and that `:0` is real Xorg, not XWayland).
4. **GL check.** `glxinfo -B` reports a GLX context with direct rendering on the
   GPU (Java 3D can create its `Canvas3D`).
5. **End-to-end.** lg3d boots as the session, and an external X client launched
   from the desktop (e.g. `xterm`, `xeyes`) appears **composited inside the 3D
   scene** as a `NativeWindow3D` quad and receives forwarded input.
6. **Key ownership (forward-looking).** lg3d receives the real `Alt+Tab`
   (not swallowed by a host shell), enabling the application switcher to cycle
   external apps.

Record the output of (1)–(5) as the compliance evidence.

## 6. Development exception (nested Xephyr) — **not** the target

For development on an existing Wayland desktop, lg3d can run inside a **nested
Xephyr** X server (`./run-lg3d.sh --nested [<display>]`), where lg3d is the
WM/compositor of *that* nested server. This is a convenience for exercising the
compositor without logging out of Wayland; it is **not** the production LFS
target, and Xephyr has **no direct GL by default** (Java 3D may fail to obtain a
hardware context). The provisioned LFS host MUST satisfy §3–§5 with a **bare
Xorg** session, not Xephyr.

## 7. References

- README → **X11 compositor mode**, **Deployment target (Linux From Scratch)**,
  **Try it on a Wayland host (nested Xephyr)**.
- `lg3d-core/src/classes/org/jdesktop/lg3d/displayserver/nativewindow/x11/`
  — `X11Compositor`, `X11WindowManager`, `CompositeWindowImageLoader`,
  `X11InputForwarder`, `X11CompositeExt` / `X11DamageExt` / `X11ShmExt` /
  `X11FixesExt`, and **`VerifyX11Extensions`** (the §5.1 probe).
- Gradle task `:lg3d-core:verifyX11Extensions` (defined in
  `lg3d-core/build.gradle`).
- BLFS: *X Window System*, *MesaLib*, and the *libX\** client libraries named in
  §3.4.
