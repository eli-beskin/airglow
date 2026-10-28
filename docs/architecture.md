# Airglow — Architecture

> **Airglow** — RGB lighting and fan control for Linux desktops.
> Components: `airglow` (CLI/GUI), `airglowd` (lighting daemon), `airglow-fanhelper` (privileged fan service).
>
> Status: **draft** · Last updated: 2026-10-28
> This document records design decisions and the reasons behind them.
> It is updated as the project evolves — see the [Decision log](#14-decision-log).

## 1. Goals and non-goals

**Goals**

- Beautiful, per-LED lighting effects for Linux desktop PCs, computed in **visual space** — a wave travels across the case the way the eye sees it.
- First-class support for **immutable distributions** (Fedora Atomic, Universal Blue, Bazzite, Borshevik).
- **Data-driven hardware support**: new fans, strips and coolers are added as JSON files, not code.
- Later: case fan control with a strict **failsafe**.

**Non-goals (for now)**

- Writing our own hardware drivers — OpenRGB already does this well.
- Windows / macOS support.
- Peripherals (keyboards, mice) — possible later, out of MVP scope.

## 2. System overview

```
┌──────────────┐  D-Bus   ┌───────────────────┐  TCP :6742  ┌──────────┐  USB HID / I²C  ┌──────────┐
│  GUI (Qt)    │ ───────► │ daemon            │ ──────────► │ OpenRGB  │ ──────────────► │ hardware │
│  editor,     │ ◄─────── │ effects engine,   │  SDK proto  │ --server │                 │          │
│  calibration │  frames  │ LED map, profiles │  127.0.0.1  └──────────┘                 └──────────┘
└──────────────┘          └───────────────────┘
                                                  (later)  fan service ──► /sys/class/hwmon
```

## 3. Processes

| Process | Runs as | Responsibility |
|---|---|---|
| **OpenRGB** (Flatpak, `--server`) | user | Hardware access (USB HID, I²C). Exposes the SDK on localhost only. |
| **Daemon** | systemd **user** service | Loads the LED map and active profile, renders frames, pushes them to OpenRGB. No window. Never touches hardware directly. |
| **GUI** (PySide6) | user | Editor, calibration wizard, live preview. Talks to the daemon over D-Bus. Closing the GUI does not stop the lighting. |
| **Fan service** (later) | systemd **system** service | Writes PWM values. Separate and minimal because it needs root. |

Why split daemon and GUI: lighting must work without the GUI open, and the GUI must be safe to crash or restart.
Why D-Bus: it is the standard IPC bus on the Linux desktop (GNOME, systemd and NetworkManager use it); Qt has built-in support.

## 4. Backend: OpenRGB SDK

- OpenRGB 1.x uses **SDK protocol 6**. The `openrgb-python` library supports protocol 4 at most, and there is a known issue where clients below protocol 6 read stale state after a write.
- **Decision:** a thin `Backend` interface (adapter layer) with a few methods: `list_devices`, `resize_zone`, `set_direct_mode`, `push_frame`.
  - First implementation: on top of `openrgb-python`.
  - Fallback: our own minimal protocol-6 client (the protocol is binary but documented, and we need only ~6 packet types).
- All devices are driven in **Direct** mode (per-frame control). Vendor hardware does not persist Direct colors, so the daemon re-applies lighting at every login.
- **`set_mode` resets state.** On the ASUS Aura USB controller, calling `set_mode('direct')` re-initializes the controller and turns all LEDs black — even if it is already in Direct mode (verified 2026-10-28). Rule: call `set_mode` once at start, after a reconnect and after resume — and **always send a full frame right after it**. Partial updates are allowed only when the engine knows the hardware state.
- **Smoke test (2026-10-28):** OpenRGB 1.1 + `openrgb-python` 0.3.8 negotiate protocol 4; reading devices, `resize`, Direct mode and per-LED writes all work. The stale-state bug did not appear in this sequence.
- **Indexing:** the OpenRGB GUI numbers LEDs from 1, the SDK from 0. All files in this project store **0-based SDK indices**.
- **Security:** the SDK server has no authentication, so it must listen on `127.0.0.1` only.

## 5. Data model

Hardware is described in five layers. Each layer knows only about the one below it.

```
1. Channel        OpenRGB: device → zone → linear chain of LEDs, idx 0..N-1
      │
2. Chain layout   what is plugged into the channel:
      │             [component A][component B]…   ← daisy chain (indices continue)
      │             + parallel groups             ← hub/splitter (indices shared)
      │
3. Component      a hardware MODEL from the library (JSON):
      │             LED count, named parts with tags (hub, frame, panel, strip…),
      │             each idx → one or more local positions
      │
4. Placement      where each component instance is, as seen from a viewpoint
      │
5. Effects        consume positions (see §6)
```

Key properties, all driven by real hardware (see §12):

- **One-to-many mapping.** One LED index can light several physical points: mirrored panels on one fan, plus identical fans behind a parallel hub.
- **Area lights.** A position may have a size — e.g. a GPU light bar with one LED, or one LED shining through all fan blades.
- **Weights.** Each position has a weight (visibility, priority). The engine averages the effect color over a LED's positions using these weights.
- **Topology vs geometry** (separation of concerns). *Topology* — which index drives which point of a model — is defined once per component model. *Geometry* — where an instance sits — is defined per installation.

## 6. Coordinate systems

Effects can work in three systems:

1. **Global (x, y)** in **screen space** of the active viewpoint — for waves across the whole case.
2. **Local polar (θ, r)** around a component's center, computed from (x, y) with `atan2` — for rotation and outward pulses.
3. **By tag** — e.g. "all `hub` parts spin, all `frame` parts breathe". Works on any component that has the tag, regardless of model.

**Viewpoint.** Which LEDs are visible depends on where the PC stands (desk vs floor, side vs front glass). A viewpoint is data, not code: a photo taken from the usual viewing position + clicked panel corners + visibility weights. A real 3D model was rejected for MVP: effects exist to be looked at, so matching what the eye sees is simpler and gives better results. `z` can be added later.

## 7. Calibration

- **LED probe:** light one index at a time to discover chain length, order, parallel wiring and which parts an index drives.
- **Templates instead of point-by-point clicking:** `ring`, `matrix`, `strip`, `single`. For a matrix panel the user clicks 4 corners on the photo, and a **perspective transform** lays out the grid. ~16 clicks for the whole reference case instead of hundreds.
- **Calibration = component authoring.** The output of the wizard for unknown hardware is a component JSON that can be submitted to the library.

## 8. Effects engine

- An effect is a pure function `color = f(position, t)`, evaluated **vectorized** with numpy for all LEDs at once.
- Fixed timestep, ~30 FPS; **per-device FPS cap** (I²C devices such as GPUs are slow).
- Send only frames that changed.
- **Gamma correction**, **per-device color balance** and a global **brightness limit** — the main difference between "works" and "looks good".

## 9. Component library and support levels

- Components live in the repository as JSON files, validated by a **JSON Schema** in CI.
- Support levels:
  - `verified` — tested on real hardware following a checklist (the probe procedure from §7);
  - `community` — contributed, not yet verified;
  - `generic` — templates: ring N, strip N, matrix W×H, single LED.
- MVP implements only what the reference hardware needs: `ring`, `matrix`, `single`, parallel groups, one viewpoint (YAGNI). The format is designed to be general from day one because changing it later is expensive.

## 10. Deployment

- Development happens in **toolbox/distrobox**; the host system stays read-only.
- Runtime: a Python venv in `~/.local/share/…` using the host `python3`. Later: Flatpak for the GUI.
- systemd **user** units: `openrgb.service` and the daemon (`Requires=` + `After=`), with reconnect logic in the daemon.
- **Sleep/resume:** the daemon listens to logind's `PrepareForSleep`, turns lights off before sleep and asks OpenRGB to rescan after resume (USB devices are often re-enumerated).
- User services start at **login** (the intended behavior). `loginctl enable-linger` is optional for lighting on the login screen.
- The project stays **distro-agnostic**: no hacks for a specific image.

## 11. Fan control (later)

- Via `/sys/class/hwmon` (PWM). The Super I/O chip is found **by name** (`/sys/class/hwmon/*/name`), never by `hwmonN` number — the number can change between boots.
- Real value over BIOS: **case fan curves driven by GPU temperature**, which the chip and the BIOS cannot see.

**Failsafe: never leave automatic mode.** The chip (e.g. Nuvoton NCT67xx, Smart Fan IV, `pwmN_enable=5`) runs a 5-point temperature curve on its own. Instead of switching a channel to manual mode and writing PWM values in a loop, the service **rewrites the curve points** (`pwmN_auto_pointK_temp/_pwm`) — for example, shifts the case fan curve up when the GPU is hot — and keeps `pwmN_enable=5`. If the service crashes, the chip keeps running the last curve, which still reacts to temperature.

Layers of protection:
1. The chip runs autonomously in automatic mode (hardware-enforced).
2. On start, the service backs up the BIOS curve; `ExecStopPost=` restores it, even after a crash.
3. A reboot reprograms the chip from BIOS settings.
4. The helper rejects unsafe curves (minimum PWM floor, monotonic points, CPU channel never below a safe minimum).

**Privileges.** Writing to sysfs requires root. A small **system service** exposes a narrow, validated API on the D-Bus **system** bus (`SetCurve(channel, points)`), authorized via **polkit**; the GUI and the lighting daemon stay unprivileged. Rejected: a udev rule that makes PWM files writable for a user group — simpler, but any process of that user could stop the fans.

## 12. Reference hardware

The author's machine, fully mapped by manual probing (0-based SDK indices):

```
Motherboard  ASUS PRIME B660-PLUS D4 — ASUS Aura USB controller, 3 ARGB headers

Header 1 → Arctic Freezer 36 A-RGB (single fan)
           12 LED ring, idx 0 = 3 o'clock, clockwise (viewed through side glass)

Aura Mainboard zone → 2 LED in firmware, NOT populated on this board (no physical LEDs) — excluded

Header 2 → empty (zone resized to 0)

Header 3 → DeepCool CG580 4F case hub, 39 LED
           4 built-in fans (1 rear exhaust, 3 side intake) in PARALLEL,
           all with identical LED orientation
           each fan has two flat dot panels beside the propeller, 3 cols × 13 rows:
             col = idx // 13   (0 = inner, next to the propeller; 2 = outer)
             row = idx % 13
             left panel:  row 0 = top, columns go outward
             right panel: same board rotated 180° (row 0 = bottom)
           idx 0–7 also drive 8 blade "petal" sectors, idx 0 = 12 o'clock, clockwise
           → increasing idx: panel dots orbit counter-clockwise, petals clockwise

GPU      → Palit GeForce RTX 3080 LHR, 1 LED (3 light points), Direct mode ✓

Layout (side view): rear fan top-left, CPU cooler center, GPU below the cooler,
                    3 side fans in a vertical column on the right
Viewpoint (author): case on the floor, seen through the side glass →
                    the LEFT panel of every fan faces the viewer
```

Fans (Nuvoton NCT6798, driver nct6775 — not autoloaded,
      enabled via /etc/modules-load.d/nct6775.conf; hwmon name "nct6798"):
  PWM channels: pwm1, pwm2, pwm4, pwm5, pwm6, pwm7 (no pwm3)
  pwm_enable:   1, 2, 4, 5, 6 = 5 (Smart Fan IV, BIOS curves); 7 = 0 (full speed)
  fan2 ≈ 1600 RPM at idle — probably CPU_FAN (to be confirmed in BIOS)
  all other tach inputs read 0 RPM — case fans likely go through the
  SATA-powered case hub (a hub may not report RPM even if it is PWM-controlled)
  ignore: in1–in14 ALARM (max = 0), AUXTIN1/2 (unconnected), intrusion1

Consequences: identical fans behind a parallel hub always show the same pattern; panel point symmetry makes effects that are symmetric under 180° rotation (outward pulse, rotation, breathing, twinkle) look correct from any viewpoint.

## 13. Prior art & positioning

| Project | What it is | What we take from it |
|---|---|---|
| [OpenRGB](https://codeberg.org/OpenRGB/OpenRGB) | Open-source, cross-vendor RGB control with an SDK server | Our backend: drivers and hardware access. Its plugins (Effects, Visual Map) are reference points for UX. |
| [SignalRGB](https://signalrgb.com/linux/) | Closed-source, freemium RGB app; Linux **beta** with native packages for Arch- and Debian-based distros | The **Components** concept: a community JSON library that maps a linear LED chain to a physical layout. Validates our §5 and §9. |
| Vendor tools (Armoury Crate, ThunderMaster…) | Per-vendor, Windows-only | Nothing technical; they show the problem we solve on Linux. |

**Positioning**

- **Open source**, built **on top of OpenRGB**, not a replacement for it.
- **Immutable-friendly**: Flatpak + systemd user units; works on Fedora Atomic-based systems, which SignalRGB's Linux beta does not target.
- **Open, documented component format**: readable, editable, contributed via pull requests.
- **Visual-space effects** with viewpoint-aware maps, per-device color balance and gamma correction.

## 14. Decision log

| # | Decision | Reason |
|---|---|---|
| 1 | Use OpenRGB as the hardware backend | Mature drivers; writing USB/I²C protocols is out of scope |
| 2 | Separate daemon and GUI, connected by D-Bus | Lighting must survive GUI close/crash; standard Linux IPC |
| 3 | `Backend` adapter over the SDK | Protocol 6 vs `openrgb-python` (protocol 4) risk |
| 4 | Store 0-based SDK indices | Single source of truth; GUI is 1-based |
| 5 | Five-layer data model with one-to-many mapping | Required by parallel hubs and mirrored panels |
| 6 | Screen-space map from a viewpoint photo instead of 3D | Simpler, matches what the eye sees |
| 7 | Components as JSON with support levels | New hardware without code changes |
| 8 | PySide6 for the GUI | Custom canvas (photo + points + preview) is easier in Qt |
| 9 | Fan control as a separate root service with `ExecStopPost=` failsafe | Least privilege; safe on crash |

## 15. Open questions

- ~~Project name~~ — **resolved:** Airglow, repository `github.com/eli-beskin/airglow`. Application / D-Bus IDs: `io.github.eli_beskin.Airglow` (session bus), `io.github.eli_beskin.Airglow.FanHelper` (system bus). The hyphen in the GitHub username becomes `_`, following the Flathub app ID convention.
- ~~`openrgb-python` or our own protocol-6 client~~ — **resolved:** start with `openrgb-python` behind the `Backend` adapter; own client stays a fallback if high-FPS streaming hits bugs.
- A zone in OpenRGB is not always real hardware (e.g. unpopulated "Aura Mainboard"). The user must be able to mark zones as empty/excluded.
- SignalRGB component format: is it documented and licensed for reuse? An importer could give access to a large library.
- Real update rate of the GPU over I²C.
- Maximum LEDs per ARGB header on the ASUS Aura USB controller.
- Mapping of PWM channels to board headers (CPU_FAN, CPU_OPT, CHA_FAN…, AIO_PUMP) — confirm in BIOS.
- Is the case hub's PWM input connected to any header? Rewire so that rear and side fans are separate channels?
