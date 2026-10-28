# Airglow

**RGB lighting and fan control for Linux desktops.**

> 🚧 **Status: early development.** Hardware discovery and architecture are done; the main code is starting now. Until then, the reference machine runs [stopgap effects](contrib/stopgap/) built from the same findings.

Airglow turns the lights inside your PC case into one canvas. Instead of setting colors device by device, you calibrate where every LED physically is — and effects flow across the whole case the way you see it: from the CPU cooler through the fans to the graphics card.

Later, Airglow will also control case fans — including curves driven by **GPU temperature**, which the BIOS cannot see — with a hardware-level failsafe.

## Why

- Vendor tools (Armoury Crate and others) are Windows-only.
- OpenRGB supports a huge range of hardware on Linux, but it controls devices one by one and has no notion of where LEDs are in space.
- Immutable distributions (Fedora Atomic, Bazzite, Universal Blue) need software that installs without modifying the system image.

## Planned features

- **Visual-space effects** — waves, pulses and rotations computed from real LED positions, not LED numbers.
- **Calibration wizard** — light LEDs one by one, mark them on a photo of your case. Fan and strip templates make it a few clicks instead of hundreds.
- **Viewpoint-aware maps** — what you see depends on where your PC stands; the map follows your point of view.
- **Component library** — fans, coolers and strips described as JSON files. New hardware is added without code changes.
- **Quality details** — gamma correction, per-device color balance, brightness limit.
- **Runs in the background** — a systemd user service applies your lighting at login and after sleep; the GUI is only an editor.
- **Fan control** (later) — temperature curves written into the fan controller chip, so fans stay safe even if Airglow crashes.

## How it works

```
GUI (Qt) ──D-Bus──► airglowd (effects engine) ──SDK──► OpenRGB ──► hardware
```

Airglow is built **on top of [OpenRGB](https://codeberg.org/OpenRGB/OpenRGB)**: OpenRGB talks to the hardware, Airglow decides what every LED should show.

Design decisions and their reasons: [docs/architecture.md](docs/architecture.md).

## Roadmap

- [x] Hardware discovery on the reference machine
- [x] Architecture
- [x] OpenRGB SDK smoke test (OpenRGB 1.1, headless server)
- [x] Stopgap effects as systemd user services ([contrib/stopgap](contrib/stopgap/))
- [ ] Backend adapter and LED probe tool
- [ ] Calibration and LED map
- [ ] Effects engine (~30 FPS)
- [ ] Background daemon (systemd user service)
- [ ] GUI (PySide6)
- [ ] Component library with support levels
- [ ] Fan control with hardware failsafe
- [ ] Flatpak package

## Reference hardware

Developed and tested on:

- ASUS PRIME B660-PLUS D4 (ASUS Aura USB, 3 ARGB headers; Nuvoton NCT6798 fan controller)
- Arctic Freezer 36 A-RGB
- DeepCool CG580 4F case with 4 built-in ARGB fans
- Palit GeForce RTX 3080 LHR
- Borshevik (Fedora Atomic / Universal Blue based), GNOME on Wayland

## License

[GPL-3.0](LICENSE)
