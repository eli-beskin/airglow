# GNOME Quick Settings toggle

A **Lighting** tile in GNOME's Quick Settings menu (top-right corner, next to Wi-Fi and Bluetooth) for the [stopgap effects](../stopgap/).

- Click the tile: lighting on (the last used effect) / off (LEDs go black).
- Click the arrow: pick **Stars**, **Cats** or **Equalizer**, or **Turn off**.
- The subtitle shows what is running; "restarting — is OpenRGB running?" means the effect keeps failing to start.
- Russian or English, following the system language.

It is a thin front end: switching runs `~/.local/bin/airglow-fx`, and the state is read from the systemd user manager over D-Bus, so changes made with `airglow-fx` in a terminal show up in the tile too. When `airglowd` exists, the tile will talk to it over D-Bus instead.

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

Copy the folder again (`cp -r …` above) and log out / in.

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
| `icons/*.svg` | Symbolic icons: tile, stars, cats (the effect's own 3×3 head sprite), equalizer |
