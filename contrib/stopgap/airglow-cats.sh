#!/usr/bin/env bash
# airglow-cats.sh — temporary "falling cats" effect for the case fans and CPU cooler.
# Pink 3-pixel-wide cats move top→bottom over the fan dot panels (3 cols × 13 rows),
# the cooler ring shows a pink band that follows the cats. Background is black.
# The GPU is never touched.
#
# Usage:
#   ./airglow-cats.sh            run the effect (Ctrl+C to stop)
#   ./airglow-cats.sh --preview  draw the fan panel in the terminal, no OpenRGB needed
#   ./airglow-cats.sh --list     show OpenRGB devices and zones, then exit
#
# Settings can be overridden from the environment, e.g.:
#   CAT=body SPEED=2 ./airglow-cats.sh

set -euo pipefail

# ---------- settings ----------
: "${COLOR:=255,16,120}"      # hot pink R,G,B
: "${CAT:=head}"              # head | body | your own sprite, e.g. '#.#/###/.#.'
: "${SPEED:=3}"               # rows per second (the panel is 13 rows tall)
: "${GAP_MIN:=2}"             # empty rows between cats (random between MIN and MAX)
: "${GAP_MAX:=6}"
: "${SMOOTH:=0}"              # 0 = jump row by row (crisp pixel art), 1 = glide between rows (softer, blurrier)
: "${COOLER:=band}"           # band = pink band on the cooler follows the cats, off = black
: "${BAND_WIDTH:=0.45}"       # band thickness on the ring (ring height = 2.0)
: "${PEAK:=1.0}"              # max brightness 0..1
: "${FPS:=30}"
: "${GAMMA:=2.2}"
: "${ON_EXIT:=off}"           # off = black, static = solid COLOR, keep = freeze last frame

# Reference hardware (architecture.md §12), 0-based SDK indices
: "${DEVICE_MATCH:=B660}"
: "${COOLER_ZONE:=Addressable RGB Header 1}"  # Arctic Freezer 36 ring, idx 0 = 3 o'clock, clockwise
: "${COOLER_LEDS:=12}"
: "${HUB_ZONE:=Addressable RGB Header 3}"     # DeepCool CG580 hub: col = idx // 13, row = idx % 13
: "${HUB_LEDS:=39}"
: "${EMPTY_ZONE:=Addressable RGB Header 2}"

: "${OPENRGB_HOST:=127.0.0.1}"
: "${OPENRGB_PORT:=6742}"

MODE="${1:-}"

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

# ---------- is the OpenRGB SDK server listening? (not needed for --preview) ----------
if [[ "$MODE" != "--preview" ]] && ! (exec 3<>"/dev/tcp/$OPENRGB_HOST/$OPENRGB_PORT") 2>/dev/null; then
    echo "OpenRGB SDK server is not reachable on $OPENRGB_HOST:$OPENRGB_PORT." >&2
    echo "Start OpenRGB with --server (or: systemctl --user start openrgb) and try again." >&2
    exit 1
fi

export COLOR CAT SPEED GAP_MIN GAP_MAX SMOOTH COOLER BAND_WIDTH PEAK FPS GAMMA ON_EXIT \
       DEVICE_MATCH COOLER_ZONE COOLER_LEDS HUB_ZONE HUB_LEDS EMPTY_ZONE \
       OPENRGB_HOST OPENRGB_PORT
export AIRGLOW_MODE="$MODE"

exec "$PY" - <<'PYEOF'
import math, os, random, signal, sys, time
from openrgb import OpenRGBClient
from openrgb.utils import RGBColor, DeviceType

E = os.environ
MODE = E["AIRGLOW_MODE"]
R, G, B = (int(v) for v in E["COLOR"].split(","))
SPEED = float(E["SPEED"])
GAP_MIN, GAP_MAX = float(E["GAP_MIN"]), float(E["GAP_MAX"])
SMOOTH = E["SMOOTH"] == "1"
COOLER_MODE, BAND = E["COOLER"], float(E["BAND_WIDTH"])
PEAK, FPS, GAMMA = float(E["PEAK"]), float(E["FPS"]), float(E["GAMMA"])
ON_EXIT = E["ON_EXIT"]
DT = 1.0 / FPS
SIZES = {E["COOLER_ZONE"]: int(E["COOLER_LEDS"]),
         E["HUB_ZONE"]: int(E["HUB_LEDS"]),
         E["EMPTY_ZONE"]: 0}
HUB, COOL = E["HUB_ZONE"], E["COOLER_ZONE"]

ROWS, COLS = 13, 3

# Sprites, drawn as the viewer sees them: top row first, '#' = lit.
SPRITES = {
    "head": "#.#/###/.#.",            # ears, head, chin
    "body": "#.#/###/.#./###/#.#",    # ears, head, neck, body, paws
}
sprite_src = SPRITES.get(E["CAT"], E["CAT"])
SPRITE = [row for row in sprite_src.split("/")]
if any(len(r) != COLS for r in SPRITE):
    raise SystemExit(f"Sprite rows must be {COLS} characters wide: {sprite_src!r}")
H = len(SPRITE)
PIXELS = [(r, c) for r in range(H) for c in range(COLS) if SPRITE[r][c] == "#"]


def color_at(level):
    k = max(0.0, min(1.0, level)) ** GAMMA
    return RGBColor(round(R * k), round(G * k), round(B * k))


def panel_index(row, col_from_left):
    """Viewer-facing LEFT panel: row 0 = top, col 0 = inner (next to the propeller).
    The left panel sits left of the propeller, so the outer column (2) is leftmost."""
    return (COLS - 1 - col_from_left) * ROWS + row


# ---------- cat simulation ----------
cats = []            # top row of each cat (float), moving down
next_gap = random.uniform(GAP_MIN, GAP_MAX)


def step(dt):
    global next_gap
    for i in range(len(cats)):
        cats[i] += SPEED * dt
    while cats and cats[0] >= ROWS:                 # left the panel at the bottom
        cats.pop(0)
    # spawn a new cat above the panel once the previous one is far enough down
    if not cats or cats[-1] >= next_gap:
        start = (cats[-1] - H - next_gap) if cats else -H
        cats.append(min(start, -H))
        next_gap = random.uniform(GAP_MIN, GAP_MAX)


def hub_levels():
    lv = [0.0] * (ROWS * COLS)
    for top in cats:
        for r, c in PIXELS:
            y = top + r
            if SMOOTH:
                r0 = math.floor(y); f = y - r0
                parts = ((r0, 1 - f), (r0 + 1, f))
            else:
                parts = ((math.floor(y + 0.5), 1.0),)
            for row, w in parts:
                if 0 <= row < ROWS and w > 0:
                    i = panel_index(row, c)
                    lv[i] = max(lv[i], w * PEAK)
    return lv


def cooler_levels():
    n = SIZES[COOL]
    if COOLER_MODE != "band" or n == 0:
        return [0.0] * n
    lv = [0.0] * n
    for top in cats:
        # cat centre 0..1 over the panel -> band position on the ring, overshooting a bit
        yc = (top + H / 2) / ROWS
        yb = -1.3 + 2.6 * yc
        for k in range(n):
            y = math.sin(math.radians(k * 360 / n))   # idx 0 = 3 o'clock, clockwise, +y = down
            d = abs(y - yb) / BAND
            if d < 1:
                s = 1 - d
                lv[k] = max(lv[k], s * s * (3 - 2 * s) * PEAK)
    return lv


# ---------- terminal preview ----------
if MODE == "--preview":
    print("Fan panel as you see it (3 × 13). Ctrl+C to stop.")
    shades = " .:-=+*#@"
    try:
        while True:
            step(DT * 2)
            lv = hub_levels()
            lines = []
            for row in range(ROWS):
                line = ""
                for c in range(COLS):
                    v = lv[panel_index(row, c)]
                    line += shades[min(len(shades) - 1, int(v * (len(shades) - 1) + 0.5))] * 2
                lines.append("  |" + line + "|")
            sys.stdout.write("\033[H\033[J" + "\n".join(lines) + "\n")
            sys.stdout.flush()
            time.sleep(DT * 2)
    except KeyboardInterrupt:
        print()
    sys.exit(0)


# ---------- OpenRGB ----------
def connect():
    client = OpenRGBClient(E["OPENRGB_HOST"], int(E["OPENRGB_PORT"]), "airglow-cats")
    dev = next((d for d in client.devices
                if d.type != DeviceType.GPU and E["DEVICE_MATCH"].lower() in d.name.lower()
                and any(z.name == HUB for z in d.zones)), None)
    if dev is None:
        raise SystemExit(f"No device matching {E['DEVICE_MATCH']!r} with zone {HUB!r}. "
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


if MODE == "--list":
    client = OpenRGBClient(E["OPENRGB_HOST"], int(E["OPENRGB_PORT"]), "airglow-cats")
    for i, d in enumerate(client.devices):
        print(f"[{i}] {d.name}  ({d.type.name})")
        for z in d.zones:
            print(f"      zone '{z.name}': {len(z.leds)} LEDs")
    client.disconnect()
    sys.exit(0)

client, dev = connect()
off_c = RGBColor(0, 0, 0)
running = True


def stop(*_):
    global running
    running = False


signal.signal(signal.SIGINT, stop)
signal.signal(signal.SIGTERM, stop)


def build_frame():
    zl = {HUB: hub_levels(), COOL: cooler_levels()}
    frame = []
    for z in dev.zones:
        levels = zl.get(z.name)
        for i in range(len(z.leds)):
            frame.append(color_at(levels[i]) if levels and i < len(levels) else off_c)
    return frame


last, last_wall = None, time.time()
next_t = time.monotonic()
print(f"Falling cats on '{dev.name}'. Ctrl+C to stop.", flush=True)
while running:
    try:
        wall = time.time()
        if wall - last_wall > 5:              # we slept/resumed: hardware lost its state
            client.disconnect()
            client, dev = connect()
            last = None
        last_wall = wall
        step(DT)
        frame = build_frame()
        if frame != last:
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
        dev.set_colors([fill if z.name in (HUB, COOL) else off_c
                        for z in dev.zones for _ in z.leds], fast=True)
    client.disconnect()
except Exception:
    pass
print("Stopped.")
PYEOF
