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
| `airglow-fx` | `~/.local/bin/` | Effect switcher: `airglow-fx stars \| cats \| status` |
| `openrgb.service` | `~/.config/systemd/user/` | OpenRGB SDK server, localhost only |
| `airglow-stars.service` | `~/.config/systemd/user/` | Stars effect, `DARK=0.15` |
| `airglow-cats.service` | `~/.config/systemd/user/` | Cats effect, green `COLOR=0,255,94`, `Conflicts=airglow-stars.service` |

Runtime: a Python venv in `~/.local/share/airglow/venv` with `openrgb-python==0.3.8` (same path as architecture §10).

## Install

Requires OpenRGB 1.x from Flathub (`org.openrgb.OpenRGB`). Run from this folder:

```bash
python3 -m venv ~/.local/share/airglow/venv
~/.local/share/airglow/venv/bin/pip install openrgb-python==0.3.8

mkdir -p ~/.local/bin ~/.config/systemd/user
cp airglow-stars.sh airglow-cats.sh airglow-fx ~/.local/bin/
chmod +x ~/.local/bin/airglow-{stars.sh,cats.sh,fx}
cp openrgb.service airglow-stars.service airglow-cats.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now openrgb.service
airglow-fx stars
```

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

### Known hardware effects

- The 4 hub fans are wired in parallel → identical pattern on all of them.
- The right panel is the same board rotated 180° → cats crawl up, upside down, there.
- idx 0–7 also light the blade "petals".

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
