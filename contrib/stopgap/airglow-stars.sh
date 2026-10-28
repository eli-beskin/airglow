#!/usr/bin/env bash
# airglow-stars.sh — temporary "starry sky" effect for the CPU cooler and case fans.
# A stopgap until Airglow is ready. Talks to the OpenRGB SDK server on 127.0.0.1:6742.
# The GPU is never touched.
#
# Usage:
#   ./airglow-stars.sh          run the effect (Ctrl+C to stop)
#   ./airglow-stars.sh --list   show OpenRGB devices and zones, then exit
#
# Every setting below can also be overridden from the environment, e.g.:
#   DENSITY=0.2 BASE=0.15 ./airglow-stars.sh

set -euo pipefail

# ---------- settings ----------
: "${COLOR:=0,255,94}"        # fixed R,G,B for every LED
: "${BASE:=0.25}"             # background glow, perceived brightness 0..1 (0 = black sky)
: "${PEAK:=1.0}"              # star peak brightness 0..1
: "${DENSITY:=0.12}"          # average share of LEDs that are a "star" at any moment
: "${DARK:=0}"                # share of LEDs whose background is OFF (dark gaps), e.g. 0.15
: "${DARK_DRIFT:=8}"          # avg seconds before an LED re-rolls dark/lit (gaps slowly wander)
: "${DARK_FADE:=1.0}"         # seconds for a gap to fade in/out
: "${STAR_MIN:=1.2}"          # star lifetime, seconds (random between MIN and MAX)
: "${STAR_MAX:=3.5}"
: "${FPS:=30}"
: "${GAMMA:=2.2}"             # gamma correction for smooth fades
: "${ON_EXIT:=static}"        # static = solid COLOR, off = black, keep = freeze last frame

# Reference hardware (architecture.md §12), 0-based SDK indices
: "${DEVICE_MATCH:=B660}"                     # substring of the motherboard device name
: "${COOLER_ZONE:=Addressable RGB Header 1}"  # Arctic Freezer 36 ring
: "${COOLER_LEDS:=12}"
: "${HUB_ZONE:=Addressable RGB Header 3}"     # DeepCool CG580 hub, 4 fans in parallel
: "${HUB_LEDS:=39}"
: "${EMPTY_ZONE:=Addressable RGB Header 2}"   # empty header -> size 0

: "${OPENRGB_HOST:=127.0.0.1}"
: "${OPENRGB_PORT:=6742}"

# ---------- find a Python that has openrgb-python ----------
VENV_PY="$HOME/.local/share/airglow/venv/bin/python"
PY=""
for cand in "${AIRGLOW_PYTHON:-}" "$VENV_PY" python3; do
    [[ -n "$cand" ]] || continue
    if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import openrgb' 2>/dev/null; then
        PY="$cand"; break
    fi
done
if [[ -z "$PY" ]]; then
    cat >&2 <<EOF
openrgb-python not found. Create a venv once:
  python3 -m venv ~/.local/share/airglow/venv
  ~/.local/share/airglow/venv/bin/pip install openrgb-python==0.3.8
EOF
    exit 1
fi

# ---------- is the OpenRGB SDK server listening? ----------
if ! (exec 3<>"/dev/tcp/$OPENRGB_HOST/$OPENRGB_PORT") 2>/dev/null; then
    echo "OpenRGB SDK server is not reachable on $OPENRGB_HOST:$OPENRGB_PORT." >&2
    echo "Start OpenRGB with --server (or enable SDK Server in its settings) and try again." >&2
    exit 1
fi

export COLOR BASE PEAK DENSITY DARK DARK_DRIFT DARK_FADE STAR_MIN STAR_MAX FPS GAMMA ON_EXIT \
       DEVICE_MATCH COOLER_ZONE COOLER_LEDS HUB_ZONE HUB_LEDS EMPTY_ZONE \
       OPENRGB_HOST OPENRGB_PORT
export AIRGLOW_LIST="${1:-}"

exec "$PY" - <<'PYEOF'
import math, os, random, signal, sys, time
from openrgb import OpenRGBClient
from openrgb.utils import RGBColor, DeviceType

E = os.environ
R, G, B = (int(v) for v in E["COLOR"].split(","))
BASE, PEAK = float(E["BASE"]), float(E["PEAK"])
DENSITY = float(E["DENSITY"])
DARK, DRIFT, FADE = float(E["DARK"]), float(E["DARK_DRIFT"]), float(E["DARK_FADE"])
SMIN, SMAX = float(E["STAR_MIN"]), float(E["STAR_MAX"])
FPS, GAMMA = float(E["FPS"]), float(E["GAMMA"])
ON_EXIT = E["ON_EXIT"]
DT = 1.0 / FPS
SIZES = {E["COOLER_ZONE"]: int(E["COOLER_LEDS"]),
         E["HUB_ZONE"]: int(E["HUB_LEDS"]),
         E["EMPTY_ZONE"]: 0}
ACTIVE = (E["COOLER_ZONE"], E["HUB_ZONE"])   # zones that get the effect; others stay black

# rate at which an idle LED becomes a star, so that ~DENSITY of LEDs are lit on average
AVG = (SMIN + SMAX) / 2
SPAWN = DENSITY / max(1e-6, (1 - DENSITY) * AVG)


def color_at(level):
    """Perceived brightness 0..1 -> gamma-corrected RGBColor of the fixed hue."""
    k = max(0.0, min(1.0, level)) ** GAMMA
    return RGBColor(round(R * k), round(G * k), round(B * k))


def envelope(p):
    """Star shape over its life p=0..1: quick rise (25%), slow fade, smoothstep-eased."""
    x = p / 0.25 if p < 0.25 else (1 - p) / 0.75
    return x * x * (3 - 2 * x)


def connect():
    client = OpenRGBClient(E["OPENRGB_HOST"], int(E["OPENRGB_PORT"]), "airglow-stars")
    dev = next((d for d in client.devices
                if d.type != DeviceType.GPU and E["DEVICE_MATCH"].lower() in d.name.lower()
                and any(z.name == E["HUB_ZONE"] for z in d.zones)), None)
    if dev is None:
        raise SystemExit(f"No device matching {E['DEVICE_MATCH']!r} with zone {E['HUB_ZONE']!r}. "
                         "Run with --list to see names.")
    resized = False
    for z in dev.zones:
        want = SIZES.get(z.name)
        if want is not None and len(z.leds) != want:
            z.resize(want)
            resized = True
    if resized:
        dev.update()
    dev.set_mode("direct")          # resets Aura to black -> full frame must follow at once
    return client, dev


def list_devices():
    client = OpenRGBClient(E["OPENRGB_HOST"], int(E["OPENRGB_PORT"]), "airglow-stars")
    for i, d in enumerate(client.devices):
        print(f"[{i}] {d.name}  ({d.type.name})")
        for z in d.zones:
            print(f"      zone '{z.name}': {len(z.leds)} LEDs")
    client.disconnect()


if os.environ.get("AIRGLOW_LIST") == "--list":
    list_devices()
    sys.exit(0)

client, dev = connect()

# one star slot per LED of each active zone: (start_time, duration) or None
stars = {name: [None] * SIZES[name] for name in ACTIVE}
# background per LED: target (0 or BASE) and current level, which eases toward the target
bg_target = {n: [0.0 if random.random() < DARK else BASE for _ in range(SIZES[n])] for n in ACTIVE}
bg_level = {n: list(bg_target[n]) for n in ACTIVE}
off_c = RGBColor(0, 0, 0)
REROLL = DT / DRIFT if DARK > 0 and DRIFT > 0 else 0.0
STEP = BASE * DT / FADE if FADE > 0 else BASE
running = True


def stop(*_):
    global running
    running = False


signal.signal(signal.SIGINT, stop)
signal.signal(signal.SIGTERM, stop)


def build_frame(now):
    frame = []
    for z in dev.zones:
        if z.name not in stars:
            frame += [off_c] * len(z.leds)      # unpopulated "Aura Mainboard" etc.
            continue
        slots, tgt, lvl = stars[z.name], bg_target[z.name], bg_level[z.name]
        for i in range(len(z.leds)):
            if i >= len(slots):
                frame.append(off_c)
                continue
            if random.random() < REROLL:                  # gaps slowly wander
                tgt[i] = 0.0 if random.random() < DARK else BASE
            d = tgt[i] - lvl[i]
            lvl[i] += max(-STEP, min(STEP, d))
            bg = lvl[i]
            s = slots[i]
            if s is None:
                if random.random() < SPAWN * DT:
                    slots[i] = (now, random.uniform(SMIN, SMAX))
                frame.append(color_at(bg))
                continue
            p = (now - s[0]) / s[1]
            if p >= 1:
                slots[i] = None
                frame.append(color_at(bg))
            else:
                frame.append(color_at(bg + (PEAK - bg) * envelope(p)))
    return frame


last, last_wall = None, time.time()
next_t = time.monotonic()
print(f"Starry sky on '{dev.name}'. Ctrl+C to stop.", flush=True)
while running:
    try:
        wall = time.time()
        if wall - last_wall > 5:              # we slept/resumed: hardware lost its state
            client.disconnect()
            client, dev = connect()
            last = None
        last_wall = wall
        frame = build_frame(time.monotonic())
        if frame != last:                     # send only frames that changed
            dev.set_colors(frame, fast=True)
            last = frame
    except (ConnectionError, OSError, BrokenPipeError) as e:
        print(f"OpenRGB connection lost ({e}); retrying in 3 s…", file=sys.stderr, flush=True)
        time.sleep(3)
        try:
            client, dev = connect()
            last = None
        except Exception:
            pass
        next_t = time.monotonic()
        continue
    next_t += DT
    time.sleep(max(0.0, next_t - time.monotonic()))

try:
    if ON_EXIT in ("static", "off"):
        fill = color_at(1.0) if ON_EXIT == "static" else off_c
        dev.set_colors([fill if z.name in stars else off_c
                        for z in dev.zones for _ in z.leds], fast=True)
    client.disconnect()
except Exception:
    pass
print("Stopped.")
PYEOF
