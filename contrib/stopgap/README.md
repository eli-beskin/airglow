# Stopgap lighting

Temporary lighting effects that run on the reference machine until the real `airglowd` daemon exists.
They are bash wrappers with an embedded Python loop, started by systemd user services.

> These scripts are hard-wired to the reference hardware (see [architecture §12](../../docs/architecture.md#12-reference-hardware)).
> They are kept here as a working prototype and as the seed of the real effects engine — not as a product.

## Files

| File | Installed to | What |
|---|---|---|
| `airglow-stars.sh` | `~/.local/bin/` | "Starry sky" effect on the fans and the cooler; the graphics card glows in its own color |
| `airglow-cats.sh` | `~/.local/bin/` | "Falling cats" effect; the graphics card glows in its own color |
| `airglow-palms.sh` | `~/.local/bin/` | "Palm beach" (vacation) effect: a palm sways over the sea, water rocks in the cooler, the graphics card glows like a sunset |
| `airglow-eq.sh` | `~/.local/bin/` | "Music equalizer" effect: system audio → bars, spinners on the petals and the cooler, a steady light on the graphics card |
| `airglow-fx` | `~/.local/bin/` | Effect switcher: `airglow-fx stars \| cats \| palms \| eq \| on \| off \| current \| status` |
| `openrgb.service` | `~/.config/systemd/user/` | OpenRGB SDK server, localhost only; waits for the graphics card's I²C buses at login and stops the Flatpak app for real |
| `airglow-stars.service` | `~/.config/systemd/user/` | Stars effect, `DARK=0.15` |
| `airglow-cats.service` | `~/.config/systemd/user/` | Cats effect, green `COLOR=0,255,94`, `Conflicts=airglow-stars.service` |
| `airglow-palms.service` | `~/.config/systemd/user/` | Palms effect, `Conflicts=` with stars, cats and the equalizer |
| `airglow-eq.service` | `~/.config/systemd/user/` | Equalizer effect, `Conflicts=` with stars and cats |

Runtime: a Python venv in `~/.local/share/airglow/venv` with `openrgb-python==0.3.8` and `numpy` (same path as architecture §10). `numpy` is needed only by the equalizer (FFT).

## Install

Requires OpenRGB 1.x from Flathub (`org.openrgb.OpenRGB`). Run from this folder:

```bash
python3 -m venv ~/.local/share/airglow/venv
~/.local/share/airglow/venv/bin/pip install openrgb-python==0.3.8 numpy

mkdir -p ~/.local/bin ~/.config/systemd/user
cp airglow-stars.sh airglow-cats.sh airglow-palms.sh airglow-eq.sh airglow-fx ~/.local/bin/
chmod +x ~/.local/bin/airglow-{stars.sh,cats.sh,palms.sh,eq.sh,fx}
cp openrgb.service airglow-stars.service airglow-cats.service airglow-palms.service airglow-eq.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now openrgb.service
airglow-fx stars
```

Switching:

```bash
airglow-fx cats      # switch to an effect; it stays after the next login
airglow-fx off       # lighting off, LEDs black; stays off after the next login
airglow-fx on        # back to the last used effect (stars the first time)
airglow-fx current   # prints the running effect, or "off"
```

`off` paints the LEDs black even for stars (whose `ON_EXIT=static` would otherwise leave a solid color): while it runs, `airglow-fx` creates `$XDG_RUNTIME_DIR/airglow/off-requested`, and every effect checks that file when it stops. The last effect is remembered in `~/.local/state/airglow/last-effect`.

For a switch in GNOME's Quick Settings menu and a settings window for colors, see [../gnome-extension](../gnome-extension/).

## Live settings: view and colors

The effects read their live settings from `~/.config/airglow/stopgap.json` (`$AIRGLOW_CONFIG` overrides the path): which side of the case you look at (cats and the equalizer), and the colors (stars, cats and palms). The GNOME extension's settings window writes this file; it can also be edited by hand:

```json
{
  "general": {"view": "side"},
  "stars": {"fans": [0, 255, 94], "gpu": [0, 255, 94]},
  "cats":  {"fans": [0, 255, 94], "gpu": [255, 16, 120]},
  "palms": {"fans": [0, 255, 94], "sea": [0, 140, 255], "gpu": [255, 110, 0]}
}
```

| Key | Meaning |
|---|---|
| `general.view` | `side` = you look through the side glass, the LEFT fan panels face you; `front` = through the front panel, the RIGHT panels face you (environment: `VIEW`) |
| `fans` | Fans and cooler color, `[r, g, b]` 0..255; for palms: the palm |
| `sea` | Palms only: the sea on the fans and the water in the cooler (environment: `SEA_COLOR`) |
| `gpu` | Graphics card color, `[r, g, b]` 0..255; a steady light |

- The effects check the file 4× per second and apply changes without a restart. Each applied change is logged, at most once a second: `Settings: fans #FF0000, GPU #0000FF` — watch it with `journalctl --user -f -u 'airglow-*'`.
- A missing key falls back to the environment default (`COLOR`, `GPU_COLOR`); a broken file is ignored with one log line and the last good values stay.
- Old `gpu_blink_hz` / `gpu_smooth` keys are ignored; the settings window drops them on its next save.
- The equalizer reads only `general.view`: its colors follow the music.

After an image update that changes the host Python version, recreate the venv (first two lines).

## How the scripts work

- **Bash wrapper:** finds a Python that has `openrgb` (the venv first), checks that `127.0.0.1:6742` is reachable via `/dev/tcp`, exports settings as environment variables, then `exec`s an embedded Python program from a heredoc (that is why the process shows up as `python -`).
- **Python loop:** `openrgb-python` client, ~30 FPS fixed timestep, gamma 2.2, sends a frame only when it changed, sends a full frame right after `set_mode('direct')` (the Aura controller resets to black), reconnects after sleep/resume (wall-clock jump > 5 s) and on connection loss.
- The motherboard is found by the name substring `B660` (GPU-type devices never match). Zones are resized to 12 / 0 / 39; the unpopulated "Aura Mainboard" zone is kept black.
- The graphics card is the first GPU-type device in OpenRGB. It gets Direct mode at connect and one color for all its LEDs. The Palit RTX 3080 reports a Direct mode whose own brightness or speed is outside its min..max, so `openrgb-python` 0.3.8 refuses to send it ("Mode validation failed"), and its `force=True` path is broken. The effects therefore send a copy of the mode with the values pulled into range (brightness at maximum). If it still fails, the log line shows the mode's flags and values. Its writes are capped at `GPU_FPS=12` per second and sent only when the color changes, because it sits on a slow I²C bus. No Direct mode → one log line and the case is lit alone. `GPU=off` leaves the card untouched.
- **No blinking on the graphics card.** Every write to the card goes over its I²C bus inside the NVIDIA driver. On the reference machine that cost ~30 ms of CPU per write: blinking (12 writes per second) kept OpenRGB at ~38% CPU and made GNOME's animations drop to ~30 fps, while a steady light did neither. So the card glows steadily and is written only when its color changes (at connect, and when you pick another color). The case LEDs sit on a USB controller, where a whole frame is one quick USB transfer, so they animate at 30 fps for free.
- **Card missing at connect.** OpenRGB looks for devices only once, when it starts, so a card it did not list right away may appear later, or only after OpenRGB restarts. While the card is missing, the effects ask OpenRGB again every 3 s for 2 minutes after each connect, over a second connection that then drives the card, so the case animation is not interrupted. Log lines: `No graphics card in OpenRGB yet…`, then `Found '…'; driving it now.` or `Still no graphics card…`.
- **`openrgb.service`.** `flatpak run` moves OpenRGB into its own cgroup scope, so `systemctl --user stop/restart` alone does not stop it: the old instance kept port 6742 (and its device list without the card) and every new start failed with status 1. The unit runs `flatpak kill org.openrgb.OpenRGB` before starting and on stop. Before starting it also waits up to 30 s for a writable NVIDIA I²C bus: right after login the buses or your access to them may not be ready, and an OpenRGB started too early never finds the card. Seen on the reference machine after a reboot: the card stayed in the mode set in Windows (its own stored mode) because nothing drove it.
- Every setting can be overridden via environment variables or `Environment=` lines in the unit file.

Device and zones as reported by OpenRGB 1.1 (`--list`):

```
[0] Palit GeForce RTX 3080 LHR  (GPU)          zone 'GPU Zone': 1
[1] ASUS PRIME B660-PLUS D4  (MOTHERBOARD)     zone 'Aura Mainboard': 2
                                               zone 'Addressable RGB Header 1': 12   ← Arctic Freezer 36 ring
                                               zone 'Addressable RGB Header 2': 0
                                               zone 'Addressable RGB Header 3': 39   ← DeepCool CG580 hub
```

### Stars (`airglow-stars.sh`)

- Fixed color `0,255,94`; dim background `BASE=0.25`; stars rise fast and fade slowly (smoothstep envelope), lifetime 1.2–3.5 s, `DENSITY=0.12`.
- `DARK` = share of LEDs whose background is off; dark gaps re-roll every ~`DARK_DRIFT=8` s and fade over `DARK_FADE=1` s. The service uses `DARK=0.15`.
- Graphics card: steady, same green by default.
- On exit: `ON_EXIT=static` (solid color on the case and the graphics card).

### Cats (`airglow-cats.sh`)

- 3-pixel-wide sprites on the 3×13 fan panels: `head` = `#.#/###/.#.` (default), `body` = `#.#/###/.#./###/#.#`, or a custom sprite.
- Cats move top→bottom at `SPEED=3` rows/s with gaps of 2–6 rows; `SMOOTH=0` (crisp row jumps) by default.
- The cooler ring shows a band that follows each cat (`COOLER=band`; ring y = sine of the LED angle, idx 0 = 3 o'clock, clockwise).
- Panel mapping, `row` 0 = top and `col` 0 = leftmost as you see the panel: `view=side` (left panel faces you, outer column leftmost) → `idx = (2 - col) * 13 + row`; `view=front` (right panel, the same board turned 180°) → `idx = col * 13 + (12 - row)`. Either way the cats fall top→bottom on the panel you see.
- Script default color is hot pink `255,16,120`; the service overrides it to green.
- Graphics card: hot pink, hard on/off at 1 Hz by default.
- `--preview` draws the panel and the GPU in the terminal without OpenRGB.
- On exit: `ON_EXIT=off`.

### Palms (`airglow-palms.sh`)

- A palm on the 3×13 fan panel: trunk from row 10 up to row 4 in the middle column, a crown of five fronds (two long hanging ones, two short ones reaching up, a young leaf in the middle). Every point is drawn with sub-pixel precision (spread over the 2×2 nearest LEDs), so the palm sways smoothly instead of jumping whole columns.
- Wind: two slow sines (`WIND=0.45` columns at the crown) plus gusts every `GUST_MIN=7`…`GUST_MAX=16` s (`GUST=0.5`). The trunk bends more towards the top, the leaves blow downwind, the windward fronds lift, and the tips flutter (`FLUTTER=0.35` rows), harder in a gust. `BEND=0.25` is the trunk's own curve.
- The trunk is dimmer than the crown (`TRUNK=0.7`), with rings: every few half-rows a little darker.
- Sea: the bottom two rows in the sea color. Waves roll left → right (`WAVE_HZ=0.35`); the upper row shows only the crests; sun glints flash on the water (`GLINTS=0.6` per second); the trunk stands in front of the water.
- Coconut: every `COCONUT_MIN=25`…`COCONUT_MAX=60` s one hangs under the crown, shakes, falls with gravity and splashes — a ring of spray runs along the sea rows. `COCONUT=off` turns it off.
- Cooler ring: `COOLER=sea` (default) is a porthole: sea water in the lower half, its surface bobbing with the waves and tilting with the wind, bright foam along the surface. `COOLER=sun` shows slowly turning rays in the graphics card color, `COOLER=off` keeps it black.
- Graphics card: steady sunset orange by default.
- Uses the same panel mapping and `view` as the cats, so the palm stands upright on the panel you see. idx 0–7 also light the petals with whatever the inner column shows.
- `--preview` draws the panel, the cooler ring and the graphics card in the terminal (truecolor), no OpenRGB needed.
- On exit: `ON_EXIT=off`.

### Equalizer (`airglow-eq.sh`)

- **Audio input:** the monitor of the default output through PipeWire (what you hear: Spotify, browser, games), no microphone. Uses `parec` if present, otherwise `pw-record` with `stream.capture.sink=true`. Mono s16le, 48 kHz.
- **Analysis:** 2048-sample Hann-windowed FFT (numpy) → three bands `40–250 / 250–2000 / 2000–12000 Hz`; per-band auto-gain (`DYN=30` dB range, reference falls `AGC_FALL=4` dB/s), silence gate `GATE=-62` dBFS; bass beat detector (level jump over a slow average, 0.25 s cooldown).
- **Fan panels:** three bars, left→right as seen on the viewer-facing panel: bass, mid, treble, growing upward (the same panel mapping as the cats, chosen by `view`). With `view=side` treble is the inner column, next to the propeller; with `view=front` bass is, so the petal LEDs (idx 0–7) share the bottom of the bass bar. Low part tinted per bar (emerald / green / lime), then a shared green → yellow → red meter gradient; white peak dots hold `PEAK_HOLD=0.45` s and fall. Fast attack, `RELEASE=16` rows/s.
- **Petals:** a two-armed comet spinner; speed grows with loudness, gets a kick on every beat, flashes and moves to the next palette color (cyan → violet → magenta → blue). Because idx 0–7 are shared with the top of the treble bar, `PETALS=blend` (default) lets the comet head override the bar there; `PETALS=spinner` and `PETALS=eq` give the shared LEDs to one side only.
- **Cooler ring:** `COOLER=spin` (default) runs the petals' spinner on the ring: same speed, beat kicks and colors, tail scaled to the 12 LEDs, heads pointing the same way as on the petals. `COOLER_ARMS=2` sets the number of comets, `COOLER_DIR=-1` reverses the direction. `COOLER=level` fills the ring from the bottom by overall loudness in the meter colors; `COOLER=pulse` pulses it with the bass in the spinner color.
- **Graphics card:** a steady light in the spinner's first color, light blue (`GPU_COLOR=0,200,255`). It used to flash on the beats, which made GNOME drop frames (see "No blinking on the graphics card" above). `GPU=off` leaves the card alone.
- `--preview` draws panel, petals, cooler and graphics card in the terminal (truecolor) from live audio; `SOURCE=demo` uses a built-in 124 BPM test beat, so no audio and no OpenRGB are needed.
- Light-to-sound latency is about 50–60 ms (capture buffer + analysis window).
- On exit: `ON_EXIT=off`.

### Known hardware effects

- The 4 hub fans are wired in parallel → identical pattern on all of them.
- The right panel is the same board rotated 180°. The effects draw for the panel you look at (`view`); on the other side of the fan, cats crawl up, upside down, and equalizer bars grow from the top down, like a reflection.
- idx 0–7 also light the blade "petals" — the equalizer has to share them between the treble bar and the spinner.

## Measured load

On the reference machine (`top`):

- OpenRGB server: ~0.3% of one core (31 s CPU over 3 h 20 min), 32 MB RES.
- Effect script: < 0.1% of one core, 15 MB RES. The whole system stays 99.6% idle.

## Lessons for the real Airglow

Recorded in [docs/architecture.md](../../docs/architecture.md) (§4, §8, §10, decisions 10–12):

- Zone and device names are not stable across OpenRGB versions → identify devices by location/serial, verify LED counts, let the user pick; never hard-code "Aura …".
- `Restart=on-failure` covers the race "OpenRGB is not ready yet"; the real daemon also retries the connection itself.
- OpenRGB detects devices once, at start: one that was not ready then (the GPU's I²C buses right after login) stays missing. Start OpenRGB after the hardware is ready, watch for devices appearing later, and stop a Flatpak OpenRGB with `flatpak kill`, not by its unit alone.
- Devices differ hugely in write cost: a USB controller takes a full frame at 30 fps for nothing, an I²C GPU controller behind the NVIDIA driver costs ~30 ms of CPU per write and stalls the desktop. Rate limits must be per device, and I²C GPU lighting is effectively static.
- `Conflicts=` gives "only one writer" for free; in Airglow the daemon is the single writer by design.
- Effect parameters as environment variables proved handy for tuning; they map naturally to profile JSON.
- A venv on the host Python breaks silently when an image update changes the Python version.
- The Python effect loops are the seed of `airglowd`'s effects engine (§8).
