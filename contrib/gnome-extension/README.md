# GNOME Quick Settings toggle

A **Lighting** tile in GNOME's Quick Settings menu (top-right corner, next to Wi-Fi and Bluetooth) for the [stopgap effects](../stopgap/).

- Click the tile: lighting on (the last used effect) / off (LEDs go black).
- Click the arrow: pick **Stars**, **Cats** or **Equalizer**, open **Colors and blinking…**, or **Turn off**.
- The subtitle shows what is running; "restarting — is OpenRGB running?" means the effect keeps failing to start.
- Russian or English, following the system language.

It is a thin front end: switching runs `~/.local/bin/airglow-fx`, and the state is read from the systemd user manager over D-Bus, so changes made with `airglow-fx` in a terminal show up in the tile too. When `airglowd` exists, the tile will talk to it over D-Bus instead.

## Settings window

**Colors and blinking…** in the menu (or the gear in the Extensions app) opens the settings window.

**View** — **I look at the case: from the side / from the front.** From the side you see the left panels of the fans through the glass, from the front the right ones, which are the same boards turned 180°. Cats and the equalizer draw for the panel you see, so cats fall down and bars grow up either way.

Then a group for **Stars** and one for **Cats**:

- **Fans and cooler** and **Graphics card** colors: a color wheel (hue around, saturation from the centre), a brightness slider, R / G / B fields, a HEX field (`#00FF5E` or `0, 255, 94`) and quick presets.
- **Graphics card blinking:** 0–4 blinks per second, 0 = steady light; **Smooth blinking** on = breathing, off = sharp flashes.
- **Reset** returns a group to its defaults.
- The top line and the group title show which effect is on the case right now (from `airglow-fx current`, re-checked every 2 s), so it is clear which group changes the lights.

The **Equalizer** group only describes what the graphics card does: its colors follow the music.

The window writes `~/.config/airglow/stopgap.json` about 0.15 s after each change, and the running effect re-reads it within a quarter of a second, so the case changes while you drag. Keys the window does not know about are kept. The file format is described in [../stopgap/README.md](../stopgap/README.md#live-settings-view-colors-and-gpu-blinking).

Tested against the GNOME Shell 50 API (Borshevik / Fedora 44); `metadata.json` also allows 48 and 49.

## Install

Requires the stopgap effects installed as described in [../stopgap/README.md](../stopgap/README.md), including the current `airglow-fx` (it needs the `on` / `off` commands).

```bash
mkdir -p ~/.local/share/gnome-shell/extensions
cp -r airglow@eli-beskin.github.io ~/.local/share/gnome-shell/extensions/
```

Log out and back in (GNOME on Wayland only finds new extensions at login), then:

```bash
gnome-extensions enable airglow@eli-beskin.github.io
```

The extension lives in your home folder; the system image is not touched.

## Update

Copy the folder again (`cp -r …` above) and log out / in. Changes to the settings window alone (`prefs.js`) only need the window to be closed and opened again.

## Troubleshooting

```bash
gnome-extensions info airglow@eli-beskin.github.io     # State: ACTIVE / ERROR
journalctl --user -b -o cat /usr/bin/gnome-shell | grep -i airglow
```

## Files

| File | What |
|---|---|
| `metadata.json` | UUID, name, supported GNOME Shell versions |
| `extension.js` | The toggle: `QuickMenuToggle` + `SystemIndicator`, systemd state over D-Bus, runs `airglow-fx` |
| `prefs.js` | Settings window: libadwaita page, a color wheel widget (`Gtk.Widget` drawing a pre-rendered texture), color rows, blink slider; reads and writes `stopgap.json` |
| `icons/*.svg` | Symbolic icons: tile, stars, cats (the effect's own 3×3 head sprite), equalizer |
