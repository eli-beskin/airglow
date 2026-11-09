# Stopgap lighting

Temporary lighting effects that run on the reference machine until the real `airglowd` daemon exists.
They are bash wrappers with an embedded Python loop, started by systemd user services.

> These scripts are hard-wired to the reference hardware (see [architecture §12](../../docs/architecture.md#12-reference-hardware)).
> They are kept here as a working prototype and as the seed of the real effects engine — not as a product.

## Files

| File | Installed to | What |
|---|---|---|
| `airglow-stars.sh` | `~/.local/bin/` | "Starry sky" effect |
| `airglow-cats.sh` | `~/.local/bin/` | "Falling cats" effect |
| `airglow-eq.sh` | `~/.local/bin/` | "Music equalizer" effect: system audio → bars, spinners on the petals and the cooler |
| `airglow-fx` | `~/.local/bin/` | Effect switcher: `airglow-fx stars \| cats \| eq \| on \| off \| current \| status` |
| `openrgb.service` | `~/.config/systemd/user/` | OpenRGB SDK server, localhost only |
| `airglow-stars.service` | `~/.config/systemd/user/` | Stars effect, `DARK=0.15` |
| `airglow-cats.service` | `~/.config/systemd/user/` | Cats effect, green `COLOR=0,255,94`, `Conflicts=airglow-stars.service` |
| `airglow-eq.service` | `~/.config/systemd/user/` | Equalizer effect, `Conflicts=` with stars and cats |

Runtime: a Python venv in `~/.local/share/airglow/venv` with `openrgb-python==0.3.8` and `numpy` (same path as architecture §10). `numpy` is needed only by the equalizer (FFT).

## Install

Requires OpenRGB 1.x from Flathub (`org.openrgb.OpenRGB`). Run from this folder:

```bash
python3 -m venv ~/.local/share/airglow/venv
~/.local/share/airglow/venv/bin/pip install openrgb-python==0.3.8 numpy

mkdir -p ~/.local/bin ~/.config/systemd/user
cp airglow-stars.sh airglow-cats.sh airglow-eq.sh airglow-fx ~/.local/bin/
chmod +x ~/.local/bin/airglow-{stars.sh,cats.sh,eq.sh,fx}
cp openrgb.service airglow-stars.service airglow-cats.service airglow-eq.service ~/.config/systemd/user/
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

For a switch in GNOME's Quick Settings menu, see [../gnome-extension](../gnome-extension/).

After an image update that changes the host Python version, recreate the venv (first two lines).

## How the scripts work

- **Bash wrapper:** finds a Python that has `openrgb` (the venv first), checks that `127.0.0.1:6742` is reachable via `/dev/tcp`, exports settings as environment variables, then `exec`s an embedded Python program from a heredoc (that is why the process shows up as `python -`).
- **Python loop:** `openrgb-python` client, ~30 FPS fixed timestep, gamma 2.2, sends a frame only when it changed, sends a full frame right after `set_mode('direct')` (the Aura controller resets to black), reconnects after sleep/resume (wall-clock jump > 5 s) and on connection loss.
- The device is found by the name substring `B660`; GPU-type devices are always skipped. Zones are resized to 12 / 0 / 39; the unpopulated "Aura Mainboard" zone is kept black.
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
- On exit: `ON_EXIT=static` (solid color).

### Cats (`airglow-cats.sh`)

- 3-pixel-wide sprites on the 3×13 fan panels: `head` = `#.#/###/.#.` (default), `body` = `#.#/###/.#./###/#.#`, or a custom sprite.
- Cats move top→bottom at `SPEED=3` rows/s with gaps of 2–6 rows; `SMOOTH=0` (crisp row jumps) by default.
- The cooler ring shows a band that follows each cat (`COOLER=band`; ring y = sine of the LED angle, idx 0 = 3 o'clock, clockwise).
- Panel mapping: the viewer-facing LEFT panel, outer column (2) is leftmost → `idx = (2 - col_from_left) * 13 + row`.
- Script default color is hot pink `255,16,120`; the service overrides it to green.
- `--preview` draws the panel in the terminal without OpenRGB.
- On exit: `ON_EXIT=off`.

### Equalizer (`airglow-eq.sh`)

- **Audio input:** the monitor of the default output through PipeWire (what you hear: Spotify, browser, games), no microphone. Uses `parec` if present, otherwise `pw-record` with `stream.capture.sink=true`. Mono s16le, 48 kHz.
- **Analysis:** 2048-sample Hann-windowed FFT (numpy) → three bands `40–250 / 250–2000 / 2000–12000 Hz`; per-band auto-gain (`DYN=30` dB range, reference falls `AGC_FALL=4` dB/s), silence gate `GATE=-62` dBFS; bass beat detector (level jump over a slow average, 0.25 s cooldown).
- **Fan panels:** three bars, left→right as seen on the viewer-facing panel: bass (outer), mid, treble (next to the propeller). Low part tinted per bar (emerald / green / lime), then a shared green → yellow → red meter gradient; white peak dots hold `PEAK_HOLD=0.45` s and fall. Fast attack, `RELEASE=16` rows/s.
- **Petals:** a two-armed comet spinner; speed grows with loudness, gets a kick on every beat, flashes and moves to the next palette color (cyan → violet → magenta → blue). Because idx 0–7 are shared with the top of the treble bar, `PETALS=blend` (default) lets the comet head override the bar there; `PETALS=spinner` and `PETALS=eq` give the shared LEDs to one side only.
- **Cooler ring:** `COOLER=spin` (default) runs the petals' spinner on the ring: same speed, beat kicks and colors, tail scaled to the 12 LEDs, heads pointing the same way as on the petals. `COOLER_ARMS=2` sets the number of comets, `COOLER_DIR=-1` reverses the direction. `COOLER=level` fills the ring from the bottom by overall loudness in the meter colors; `COOLER=pulse` pulses it with the bass in the spinner color.
- `--preview` draws panel, petals and cooler in the terminal (truecolor) from live audio; `SOURCE=demo` uses a built-in 124 BPM test beat, so no audio and no OpenRGB are needed.
- Light-to-sound latency is about 50–60 ms (capture buffer + analysis window).
- On exit: `ON_EXIT=off`.

### Known hardware effects

- The 4 hub fans are wired in parallel → identical pattern on all of them.
- The right panel is the same board rotated 180° → cats crawl up, upside down, there; equalizer bars grow from the top down, like a reflection.
- idx 0–7 also light the blade "petals" — the equalizer has to share them between the treble bar and the spinner.

## Measured load

On the reference machine (`top`):

- OpenRGB server: ~0.3% of one core (31 s CPU over 3 h 20 min), 32 MB RES.
- Effect script: < 0.1% of one core, 15 MB RES. The whole system stays 99.6% idle.

## Lessons for the real Airglow

Recorded in [docs/architecture.md](../../docs/architecture.md) (§4, §8, §10, decisions 10–12):

- Zone and device names are not stable across OpenRGB versions → identify devices by location/serial, verify LED counts, let the user pick; never hard-code "Aura …".
- `Restart=on-failure` covers the race "OpenRGB is not ready yet"; the real daemon also retries the connection itself.
- `Conflicts=` gives "only one writer" for free; in Airglow the daemon is the single writer by design.
- Effect parameters as environment variables proved handy for tuning; they map naturally to profile JSON.
- A venv on the host Python breaks silently when an image update changes the Python version.
- The Python effect loops are the seed of `airglowd`'s effects engine (§8).
