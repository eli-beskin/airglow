#!/usr/bin/env bash
# airglow-cats.sh — temporary "falling cats" effect for the case fans and CPU cooler.
# Pink 3-pixel-wide cats move top→bottom over the fan dot panels (3 cols × 13 rows),
# the cooler ring shows a pink band that follows the cats. Background is black.
# The graphics card blinks in its own color.
#
# Colors and the GPU blink rate are read live from ~/.config/airglow/stopgap.json
# (section "cats"), which the GNOME extension's settings window writes. Without that
# file the settings below are used.
#
# Usage:
#   ./airglow-cats.sh            run the effect (Ctrl+C to stop)
#   ./airglow-cats.sh --preview  draw the fan panel and the GPU blink in the terminal, no OpenRGB needed
#   ./airglow-cats.sh --list     show OpenRGB devices and zones, then exit
#
# Settings can be overridden from the environment, e.g.:
#   CAT=body SPEED=2 ./airglow-cats.sh

set -euo pipefail

# ---------- settings ----------
: "${COLOR:=255,16,120}"      # fans + cooler R,G,B, hot pink    (stopgap.json: "fans")
: "${GPU:=on}"                # on = also drive the graphics card | off = leave it alone
: "${GPU_COLOR:=255,16,120}"  # GPU R,G,B                         (stopgap.json: "gpu")
: "${GPU_BLINK_HZ:=1}"        # GPU blinks per second, 0 = steady (stopgap.json: "gpu_blink_hz")
: "${GPU_SMOOTH:=0}"          # 1 = smooth breathing, 0 = hard on/off (stopgap.json: "gpu_smooth")
: "${GPU_FPS:=12}"            # max GPU updates per second (it sits on a slow I²C bus)
: "${AIRGLOW_CONFIG:=${XDG_CONFIG_HOME:-$HOME/.config}/airglow/stopgap.json}"
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
: "${OFF_FLAG:=${XDG_RUNTIME_DIR:-/tmp}/airglow/off-requested}"  # exists while `airglow-fx off` runs → stop to black

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

export COLOR GPU GPU_COLOR GPU_BLINK_HZ GPU_SMOOTH GPU_FPS AIRGLOW_CONFIG \
       CAT SPEED GAP_MIN GAP_MAX SMOOTH COOLER BAND_WIDTH PEAK FPS GAMMA ON_EXIT \
       DEVICE_MATCH COOLER_ZONE COOLER_LEDS HUB_ZONE HUB_LEDS EMPTY_ZONE \
       OPENRGB_HOST OPENRGB_PORT OFF_FLAG
export AIRGLOW_MODE="$MODE"

exec "$PY" - <<'PYEOF'
import copy, json, math, os, random, signal, sys, time
from openrgb import OpenRGBClient
from openrgb.utils import RGBColor, DeviceType, ModeFlags

E = os.environ
MODE = E["AIRGLOW_MODE"]
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


# ---------- live settings: colors and GPU blink (written by the GNOME extension) ----------
SECTION = "cats"
MAX_HZ = 4.0


def rgb3(v, fallback):
    """[r, g, b] list or "r,g,b" string -> tuple of 3 ints 0..255; fallback on anything else."""
    try:
        parts = v.split(",") if isinstance(v, str) else list(v)
        if len(parts) != 3:
            return fallback
        return tuple(max(0, min(255, int(p))) for p in parts)
    except (TypeError, ValueError):
        return fallback


def num(v, lo, hi, fallback):
    try:
        x = float(v)
    except (TypeError, ValueError):
        return fallback
    return max(lo, min(hi, x)) if math.isfinite(x) else fallback


def flag(v, fallback):
    if isinstance(v, bool):
        return v
    if isinstance(v, str) and v.strip() in ("0", "1"):
        return v.strip() == "1"
    return fallback


class LiveConfig:
    """Re-reads one section of stopgap.json whenever the file changes (checked 4× per second).
    Keys missing from the file fall back to the environment defaults; a broken file keeps
    the last good values."""

    def __init__(self, path, section, defaults):
        self.path, self.section, self.defaults = path, section, defaults
        self.values, self.sig, self.next_check = dict(defaults), None, 0.0

    def poll(self, now):
        if now < self.next_check:
            return False
        self.next_check = now + 0.25
        try:
            st = os.stat(self.path)
            sig = (st.st_mtime_ns, st.st_size)
        except OSError:
            sig = None
        if sig == self.sig:
            return False
        self.sig = sig
        data = {}
        if sig is not None:
            try:
                with open(self.path, encoding="utf-8") as f:
                    data = json.load(f).get(self.section) or {}
                if not isinstance(data, dict):
                    raise ValueError("section is not an object")
            except (OSError, ValueError, AttributeError) as e:
                print(f"Ignoring {self.path}: {e}", file=sys.stderr, flush=True)
                return False
        self.values = {k: data.get(k, d) for k, d in self.defaults.items()}
        return True


class Blinker:
    """GPU light that blinks at a set rate. The phase is integrated over time, so moving
    the frequency slider changes the speed without a jump."""

    def __init__(self):
        self.phase, self.hz, self.smooth = 0.0, 0.0, True
        self.color = (0, 0, 0)

    def configure(self, color, hz, smooth):
        self.color, self.hz, self.smooth = color, hz, smooth

    def level(self, dt):
        if self.hz <= 0:
            return 1.0                                     # 0 Hz = steady light
        self.phase = (self.phase + self.hz * dt) % 1.0
        if not self.smooth:
            return 1.0 if self.phase < 0.5 else 0.0        # hard on/off
        return 0.5 - 0.5 * math.cos(2 * math.pi * self.phase)   # smooth breathing

    def rgb(self, level):
        k = max(0.0, min(1.0, level)) ** GAMMA
        return RGBColor(*(round(c * k) for c in self.color))


def direct_mode(dev):
    """The device's Direct mode, ready for set_mode().

    openrgb-python 0.3.8 validates a mode before sending it, and some drivers report a
    Direct mode whose own speed or brightness is outside its min..max (the Palit RTX 3080
    does: "Mode validation failed. Required values invalid or not present"). Its
    force=True path is broken in 0.3.8, so we send a copy with the values pulled into
    range instead: brightness at its maximum, speed at its minimum."""
    mode = next((m for m in dev.modes if m.name.lower() == "direct"), None)
    if mode is None:
        raise ValueError("no Direct mode")
    m = copy.copy(mode)

    def fit(value, lo, hi, prefer):
        if lo is None or hi is None:
            return value
        if value is None or not min(lo, hi) <= value <= max(lo, hi):
            return prefer
        return value

    if ModeFlags.HAS_SPEED in m.flags:
        m.speed = fit(m.speed, m.speed_min, m.speed_max, m.speed_min)
    else:
        m.speed = m.speed_min = m.speed_max = None
    if ModeFlags.HAS_BRIGHTNESS in m.flags:
        top = None if m.brightness_min is None or m.brightness_max is None \
            else max(m.brightness_min, m.brightness_max)
        m.brightness = fit(m.brightness, m.brightness_min, m.brightness_max, top)
    else:
        m.brightness = m.brightness_min = m.brightness_max = None
    if ModeFlags.HAS_MODE_SPECIFIC_COLOR in m.flags:
        colors = list(m.colors or [])
        lo = m.colors_min or 0
        hi = m.colors_max if m.colors_max is not None else max(lo, len(colors))
        m.colors = colors[:hi] + [RGBColor(0, 0, 0)] * max(0, lo - len(colors))
    else:
        m.colors = m.colors_min = m.colors_max = None
    return m


class GpuOut:
    """The graphics card as a separate OpenRGB device: Direct mode, one color for all its
    LEDs, at most GPU_FPS writes per second and only when the color changed."""

    def __init__(self, enabled, fps):
        self.enabled, self.dt = enabled, 1.0 / max(1.0, fps)
        self.dev, self.last, self.next_t = None, None, 0.0

    def attach(self, client):
        self.dev, self.last = None, None
        if not self.enabled:
            return
        gpu = next((d for d in client.devices if d.type == DeviceType.GPU and d.leds), None)
        if gpu is None:
            print("No graphics card in OpenRGB; lighting the case only.", file=sys.stderr, flush=True)
            return
        try:
            gpu.set_mode(direct_mode(gpu))
        except Exception as e:  # noqa: BLE001 — no Direct mode, or the card refused
            m = next((m for m in gpu.modes if m.name.lower() == "direct"), None)
            detail = "" if m is None else (
                f"; Direct mode: flags={int(m.flags)} speed={m.speed} [{m.speed_min}..{m.speed_max}]"
                f" brightness={m.brightness} [{m.brightness_min}..{m.brightness_max}]"
                f" colors={len(m.colors or [])} [{m.colors_min}..{m.colors_max}]")
            print(f"Cannot drive '{gpu.name}' ({e}{detail}); lighting the case only.",
                  file=sys.stderr, flush=True)
            return
        self.dev = gpu

    def push(self, color, now):
        if self.dev is None or now < self.next_t or color == self.last:
            return
        self.dev.set_colors([color] * len(self.dev.leds), fast=True)
        self.last, self.next_t = color, now + self.dt

    def fill(self, color):
        if self.dev is not None:
            self.dev.set_colors([color] * len(self.dev.leds), fast=True)


cfg = LiveConfig(os.path.expanduser(E["AIRGLOW_CONFIG"]), SECTION, {
    "fans": E["COLOR"], "gpu": E["GPU_COLOR"],
    "gpu_blink_hz": E["GPU_BLINK_HZ"], "gpu_smooth": E["GPU_SMOOTH"]})
FAN = rgb3(E["COLOR"], (0, 255, 94))
blink = Blinker()
gpu = GpuOut(E["GPU"] == "on", float(E["GPU_FPS"]))


def apply_config():
    global FAN
    v, d = cfg.values, cfg.defaults
    FAN = rgb3(v["fans"], rgb3(d["fans"], FAN))
    blink.configure(rgb3(v["gpu"], rgb3(d["gpu"], FAN)),
                    num(v["gpu_blink_hz"], 0.0, MAX_HZ, num(d["gpu_blink_hz"], 0.0, MAX_HZ, 0.0)),
                    flag(v["gpu_smooth"], flag(d["gpu_smooth"], True)))


def settings_line():
    hx = lambda c: "#%02X%02X%02X" % tuple(c)
    rate = "steady" if blink.hz <= 0 else f"{blink.hz:g} Hz {'smooth' if blink.smooth else 'hard'}"
    return f"Settings: fans {hx(FAN)}, GPU {hx(blink.color)} {rate}"


cfg.poll(0.0)
apply_config()


def color_at(level):
    """Perceived brightness 0..1 -> gamma-corrected RGBColor of the fan color."""
    k = max(0.0, min(1.0, level)) ** GAMMA
    return RGBColor(round(FAN[0] * k), round(FAN[1] * k), round(FAN[2] * k))


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
            if cfg.poll(time.monotonic()):
                apply_config()
            step(DT * 2)
            lv = hub_levels()
            g = blink.level(DT * 2)
            lines = []
            for row in range(ROWS):
                line = ""
                for c in range(COLS):
                    v = lv[panel_index(row, c)]
                    line += shades[min(len(shades) - 1, int(v * (len(shades) - 1) + 0.5))] * 2
                lines.append("  |" + line + "|")
            gpu_bar = shades[min(len(shades) - 1, int(g * (len(shades) - 1) + 0.5))] * 6
            lines += ["", f"  GPU |{gpu_bar}|  {blink.hz:.1f} Hz {'smooth' if blink.smooth else 'hard'}"]
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
    gpu.attach(client)              # same rule for the GPU: its first color follows at once
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
prev = next_t = time.monotonic()
log_due, next_log = True, 0.0
where = f"'{dev.name}'" + (f" and '{gpu.dev.name}'" if gpu.dev else "")
print(f"Falling cats on {where}. Ctrl+C to stop.", flush=True)
while running:
    try:
        wall = time.time()
        if wall - last_wall > 5:              # we slept/resumed: hardware lost its state
            client.disconnect()
            client, dev = connect()
            last = None
        last_wall = wall
        now = time.monotonic()
        dt, prev = min(0.1, now - prev), now
        if cfg.poll(now):                     # colors or blink rate changed in the settings
            apply_config()
            log_due = True
        if log_due and now >= next_log:       # journal: what is applied, at most once a second
            print(settings_line(), flush=True)
            log_due, next_log = False, now + 1.0
        step(DT)
        frame = build_frame()
        if frame != last:
            dev.set_colors(frame, fast=True)
            last = frame
        gpu.push(blink.rgb(blink.level(dt)), now)
    except (ConnectionError, OSError, BrokenPipeError) as e:
        print(f"OpenRGB connection lost ({e}); retrying in 3 s…", file=sys.stderr, flush=True)
        time.sleep(3)
        try:
            client, dev = connect()
            last = None
        except Exception:
            pass
        next_t = prev = time.monotonic()
        continue
    next_t += DT
    time.sleep(max(0.0, next_t - time.monotonic()))

if os.path.exists(E["OFF_FLAG"]):    # `airglow-fx off`: stop to black whatever ON_EXIT says
    ON_EXIT = "off"

try:
    if ON_EXIT in ("static", "off"):
        fill = color_at(1.0) if ON_EXIT == "static" else off_c
        dev.set_colors([fill if z.name in (HUB, COOL) else off_c
                        for z in dev.zones for _ in z.leds], fast=True)
        gpu.fill(blink.rgb(1.0) if ON_EXIT == "static" else off_c)
    client.disconnect()
except Exception:
    pass
print("Stopped.")
PYEOF
