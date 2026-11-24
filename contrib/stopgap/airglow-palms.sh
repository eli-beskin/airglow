#!/usr/bin/env bash
# airglow-palms.sh — temporary "palm beach" (vacation) effect for the case fans and CPU cooler.
# A palm tree sways in the wind on the fan dot panels (3 cols × 13 rows): the trunk bends,
# the fronds flutter, gusts come now and then and once in a while a coconut drops into
# the sea. The sea rolls along the bottom rows with sun glints on the water. The cooler
# ring is a porthole with sea water rocking in it (or the sun). The graphics card glows
# like a sunset.
#
# Colors and the GPU blink rate are read live from ~/.config/airglow/stopgap.json
# (section "palms"), which the GNOME extension's settings window writes. Without that
# file the settings below are used.
#
# Usage:
#   ./airglow-palms.sh            run the effect (Ctrl+C to stop)
#   ./airglow-palms.sh --preview  draw the panel, the cooler and the GPU in the terminal, no OpenRGB needed
#   ./airglow-palms.sh --list     show OpenRGB devices and zones, then exit
#
# Settings can be overridden from the environment, e.g.:
#   WIND=0.8 COCONUT_MIN=5 COCONUT_MAX=10 ./airglow-palms.sh --preview

set -euo pipefail

# ---------- settings ----------
: "${VIEW:=side}"             # side = through the side glass (left fan panels face you)
                              # | front = through the front panel (right panels face you)  (stopgap.json: "general": "view")
: "${COLOR:=0,255,94}"        # palm R,G,B, green                 (stopgap.json: "fans")
: "${SEA_COLOR:=0,140,255}"   # sea R,G,B, blue                   (stopgap.json: "sea")
: "${GPU:=on}"                # on = also drive the graphics card | off = leave it alone
: "${GPU_COLOR:=255,110,0}"   # GPU R,G,B, sunset orange          (stopgap.json: "gpu")
: "${GPU_BLINK_HZ:=0.2}"      # GPU blinks per second, 0 = steady (stopgap.json: "gpu_blink_hz")
: "${GPU_SMOOTH:=1}"          # 1 = smooth breathing, 0 = hard on/off (stopgap.json: "gpu_smooth")
: "${GPU_FPS:=12}"            # max GPU updates per second (it sits on a slow I²C bus)
: "${AIRGLOW_CONFIG:=${XDG_CONFIG_HOME:-$HOME/.config}/airglow/stopgap.json}"
: "${WIND:=0.45}"             # how far the crown sways, in panel columns (0 = calm)
: "${GUST:=0.5}"              # extra lean during a gust, in columns
: "${GUST_MIN:=7}"            # seconds between gusts (random between MIN and MAX)
: "${GUST_MAX:=16}"
: "${FLUTTER:=0.35}"          # how much the frond tips flutter, in rows
: "${BEND:=0.25}"             # the trunk's own curve, in columns (+ = to the right as you see it)
: "${TRUNK:=0.7}"             # trunk brightness 0..1, dimmer than the crown (rings alternate around it)
: "${SEA_BASE:=0.35}"         # calm water brightness 0..1
: "${SEA_AMP:=0.5}"           # wave height in brightness
: "${WAVE_HZ:=0.35}"          # waves per second
: "${GLINTS:=0.6}"            # sun glints on the water per second (whole panel)
: "${COCONUT:=on}"            # on = a coconut falls into the sea now and then | off
: "${COCONUT_MIN:=25}"        # seconds between coconuts (random between MIN and MAX)
: "${COCONUT_MAX:=60}"
: "${COOLER:=sea}"            # sea = water rocking in a porthole (sea color) | sun = rotating rays
                              # in the GPU color | off = black
: "${PEAK:=1.0}"              # max brightness 0..1
: "${FPS:=30}"
: "${GAMMA:=2.2}"
: "${ON_EXIT:=off}"           # off = black, static = solid palm color, keep = freeze last frame
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

export COLOR SEA_COLOR GPU GPU_COLOR GPU_BLINK_HZ GPU_SMOOTH GPU_FPS AIRGLOW_CONFIG VIEW \
       WIND GUST GUST_MIN GUST_MAX FLUTTER BEND TRUNK SEA_BASE SEA_AMP WAVE_HZ GLINTS \
       COCONUT COCONUT_MIN COCONUT_MAX COOLER PEAK FPS GAMMA ON_EXIT \
       DEVICE_MATCH COOLER_ZONE COOLER_LEDS HUB_ZONE HUB_LEDS EMPTY_ZONE \
       OPENRGB_HOST OPENRGB_PORT OFF_FLAG
export AIRGLOW_MODE="$MODE"

exec "$PY" - <<'PYEOF'
import copy, json, math, os, random, signal, sys, time
from openrgb import OpenRGBClient
from openrgb.utils import RGBColor, DeviceType, ModeFlags

E = os.environ
MODE = E["AIRGLOW_MODE"]
WIND, GUST = float(E["WIND"]), float(E["GUST"])
GUST_MIN, GUST_MAX = float(E["GUST_MIN"]), float(E["GUST_MAX"])
FLUTTER, BEND, TRUNK = float(E["FLUTTER"]), float(E["BEND"]), float(E["TRUNK"])
SEA_BASE, SEA_AMP, WAVE_HZ = float(E["SEA_BASE"]), float(E["SEA_AMP"]), float(E["WAVE_HZ"])
GLINTS = float(E["GLINTS"])
COCONUT = E["COCONUT"] == "on"
COCONUT_MIN, COCONUT_MAX = float(E["COCONUT_MIN"]), float(E["COCONUT_MAX"])
COOLER_MODE = E["COOLER"]
PEAK, FPS, GAMMA = float(E["PEAK"]), float(E["FPS"]), float(E["GAMMA"])
ON_EXIT = E["ON_EXIT"]
DT = 1.0 / FPS
SIZES = {E["COOLER_ZONE"]: int(E["COOLER_LEDS"]),
         E["HUB_ZONE"]: int(E["HUB_LEDS"]),
         E["EMPTY_ZONE"]: 0}
HUB, COOL = E["HUB_ZONE"], E["COOLER_ZONE"]

ROWS, COLS = 13, 3


# ---------- live settings: colors and GPU blink (written by the GNOME extension) ----------
SECTION = "palms"
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

    LOOK_EVERY, LOOK_FOR = 3.0, 120.0     # seconds: how often / how long to look for a missing card

    def __init__(self, enabled, fps):
        self.enabled, self.dt = enabled, 1.0 / max(1.0, fps)
        self.dev, self.last, self.next_t = None, None, 0.0
        self.extra, self.look_until, self.next_look = None, 0.0, 0.0

    @staticmethod
    def _find(client):
        return next((d for d in client.devices if d.type == DeviceType.GPU and d.leds), None)

    def attach(self, client):
        self.close_extra()
        self.dev, self.last = None, None
        if not self.enabled:
            return
        gpu = self._find(client)
        if gpu is None:
            self.look_until = time.monotonic() + self.LOOK_FOR
            self.next_look = time.monotonic() + self.LOOK_EVERY
            print("No graphics card in OpenRGB yet; lighting the case and looking again "
                  f"for {self.LOOK_FOR:.0f} s.", file=sys.stderr, flush=True)
            return
        self._drive(gpu)

    def _drive(self, gpu):
        """Direct mode on the card; True if it can be driven."""
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
            return False
        self.dev = gpu
        return True

    def look_again(self, now):
        """OpenRGB scans for devices once, when it starts, and may list the card later than the
        board — or not at all, if the card's I²C buses were not ready yet. While the card is
        missing, ask again every few seconds for a while after each connect, over a second
        connection that then drives the card, so the case animation is not interrupted."""
        if not self.enabled or self.dev is not None or not self.next_look <= now < self.look_until:
            return
        self.next_look = now + self.LOOK_EVERY
        try:
            c = OpenRGBClient(E["OPENRGB_HOST"], int(E["OPENRGB_PORT"]), "airglow-gpu")
        except Exception:  # noqa: BLE001 — OpenRGB busy or restarting: try again later
            return
        gpu = self._find(c)
        if gpu is not None:
            self.look_until = 0.0                 # found: stop looking, whatever _drive says
            if self._drive(gpu):
                self.extra = c
                print(f"Found '{gpu.name}' in OpenRGB; driving it now.", flush=True)
                return
        try:
            c.disconnect()
        except Exception:  # noqa: BLE001
            pass
        if gpu is None and self.next_look >= self.look_until:
            print("Still no graphics card in OpenRGB; lighting the case only. "
                  "Restarting OpenRGB usually helps: systemctl --user restart openrgb.service",
                  file=sys.stderr, flush=True)

    def close_extra(self):
        if self.extra is not None:
            try:
                self.extra.disconnect()
            except Exception:  # noqa: BLE001
                pass
            self.extra = None

    def push(self, color, now):
        if self.dev is None or now < self.next_t or color == self.last:
            return
        self.dev.set_colors([color] * len(self.dev.leds), fast=True)
        self.last, self.next_t = color, now + self.dt

    def fill(self, color):
        if self.dev is not None:
            self.dev.set_colors([color] * len(self.dev.leds), fast=True)


cfg = LiveConfig(os.path.expanduser(E["AIRGLOW_CONFIG"]), SECTION, {
    "fans": E["COLOR"], "sea": E["SEA_COLOR"], "gpu": E["GPU_COLOR"],
    "gpu_blink_hz": E["GPU_BLINK_HZ"], "gpu_smooth": E["GPU_SMOOTH"]})
FAN = rgb3(E["COLOR"], (0, 255, 94))
SEA = rgb3(E["SEA_COLOR"], (0, 140, 255))
blink = Blinker()
gpu = GpuOut(E["GPU"] == "on", float(E["GPU_FPS"]))


def apply_config():
    global FAN, SEA
    v, d = cfg.values, cfg.defaults
    FAN = rgb3(v["fans"], rgb3(d["fans"], FAN))
    SEA = rgb3(v["sea"], rgb3(d["sea"], SEA))
    blink.configure(rgb3(v["gpu"], rgb3(d["gpu"], FAN)),
                    num(v["gpu_blink_hz"], 0.0, MAX_HZ, num(d["gpu_blink_hz"], 0.0, MAX_HZ, 0.0)),
                    flag(v["gpu_smooth"], flag(d["gpu_smooth"], True)))


def settings_line():
    hx = lambda c: "#%02X%02X%02X" % tuple(c)
    rate = "steady" if blink.hz <= 0 else f"{blink.hz:g} Hz {'smooth' if blink.smooth else 'hard'}"
    return f"Settings: palm {hx(FAN)}, sea {hx(SEA)}, GPU {hx(blink.color)} {rate}"


cfg.poll(0.0)
apply_config()


# Which fan panel faces the viewer (stopgap.json: "general": {"view": "side" | "front"}).
VIEWS = ("side", "front")
view_cfg = LiveConfig(os.path.expanduser(E["AIRGLOW_CONFIG"]), "general", {"view": E["VIEW"]})
VIEW = "side"


def apply_view():
    global VIEW
    v = view_cfg.values["view"]
    VIEW = v if v in VIEWS else (E["VIEW"] if E["VIEW"] in VIEWS else "side")


view_cfg.poll(0.0)
apply_view()


def mix(palm, sea, sun=0.0):
    """Two light layers on one LED: palm color + sea color (+ GPU color for the sun),
    each gamma-corrected, added and clipped."""
    kp = max(0.0, min(1.0, palm)) ** GAMMA
    ks = max(0.0, min(1.0, sea)) ** GAMMA
    ku = max(0.0, min(1.0, sun)) ** GAMMA
    sc = blink.color
    return RGBColor(*(min(255, round(FAN[i] * kp + SEA[i] * ks + sc[i] * ku)) for i in range(3)))


def panel_index(row, col_from_left):
    """(row, column) as the viewer sees the fan panel -> LED index (0-based, SDK).
    side:  the LEFT panel faces you: row 0 = top, the outer column (2) is leftmost,
           the inner column (idx 0..12) is next to the propeller.
    front: the RIGHT panel faces you. It is the same board turned 180°, so idx 0 is at the
           bottom, in the inner column, which is on your left next to the propeller.
    idx 0..7 also drive the blade petals."""
    if VIEW == "front":
        return col_from_left * ROWS + (ROWS - 1 - row)
    return (COLS - 1 - col_from_left) * ROWS + row


# ---------- the beach ----------
# Panel coordinates as the viewer sees them: x = column 0..2 (left → right), y = row 0..12
# (top → bottom), LED centres on whole numbers. Shapes are drawn with sub-pixel precision
# (each point is spread over the 2×2 nearest LEDs), so the palm sways smoothly instead of
# jumping a whole column — on a panel 3 LEDs wide that is what makes it look alive.

SEA_TOP = ROWS - 2               # rows 11 and 12 are the sea
TRUNK_BASE, TRUNK_TOP = 10.6, 4.0
TRUNK_X = 1.0                    # the trunk stands in the middle column

# Fronds: (side, length in columns, rise, droop, brightness). A frond point at u = 0..1
# along the leaf sits at dx = side * length * u, dy = -rise * u + droop * u² (+dy = down):
# it goes up from the crown, then hangs down.
FRONDS = (
    (-1, 1.8, 1.3, 2.7, 1.00),   # long fronds hanging left and right
    (+1, 1.8, 1.3, 2.7, 1.00),
    (-1, 1.1, 2.5, 1.1, 0.90),   # shorter fronds reaching up
    (+1, 1.1, 2.5, 1.1, 0.90),
    (0, 0.0, 2.9, 0.0, 0.75),    # the young leaf in the middle, straight up
)
FROND_STEPS = 7


class Beach:
    def __init__(self):
        self.t = 0.0
        self.gust, self.gust_target, self.gust_end = 0.0, 0.0, 0.0
        self.next_gust = random.uniform(GUST_MIN, GUST_MAX) * 0.5
        self.lean = 0.0
        self.glints = []                     # (x, y, start, duration)
        self.coconut = None                  # dict: x, y, vy, state, t0
        self.splash = None                   # (x, start)
        self.next_coconut = random.uniform(COCONUT_MIN, COCONUT_MAX) * 0.5
        self.phases = [random.uniform(0, 2 * math.pi) for _ in FRONDS]

    # --- time ---
    def step(self, dt):
        t = self.t = self.t + dt
        # gusts: a quick push (≈1.5 s), then the wind eases off (≈3 s)
        if t >= self.next_gust:
            self.gust_target = random.uniform(0.6, 1.0)
            self.gust_end = t + random.uniform(1.0, 2.0)
            self.next_gust = t + random.uniform(GUST_MIN, GUST_MAX)
        if t >= self.gust_end:
            self.gust_target = 0.0
        rate = 1 / 1.5 if self.gust_target > self.gust else 1 / 3.0
        self.gust += (self.gust_target - self.gust) * min(1.0, rate * dt * 3)
        # steady breeze: two slow sines that never quite repeat, plus the gust
        self.lean = (WIND * (0.65 * math.sin(2 * math.pi * 0.16 * t)
                             + 0.35 * math.sin(2 * math.pi * 0.41 * t + 1.3))
                     + GUST * self.gust)
        # sun glints on the water
        self.glints = [g for g in self.glints if t - g[2] < g[3]]
        if random.random() < GLINTS * dt:
            self.glints.append((random.randrange(COLS), random.choice((SEA_TOP, SEA_TOP + 1)),
                                t, random.uniform(0.15, 0.45)))
        self._coconut_step(dt)

    def _coconut_step(self, dt):
        t = self.t
        if self.splash and t - self.splash[1] > 0.8:
            self.splash = None
        c = self.coconut
        if c is None:
            if COCONUT and t >= self.next_coconut:
                xt, yt = self.top()
                self.coconut = {"dx": random.choice((-0.6, 0.6)), "y": yt + 0.7,
                                "vy": 0.0, "state": "hang", "t0": t}
            return
        if c["state"] == "hang":                         # wobbles a bit, then lets go
            if t - c["t0"] > 1.2:
                c["state"] = "fall"
                c["x"] = self.top()[0] + c["dx"]
        else:
            c["vy"] += 30.0 * dt                         # rows / s²
            c["y"] += c["vy"] * dt
            if c["y"] >= SEA_TOP:
                self.splash = (c["x"], t)
                self.coconut = None
                self.next_coconut = t + random.uniform(COCONUT_MIN, COCONUT_MAX)

    # --- shape ---
    def trunk_x(self, y):
        """Trunk centre at row y: the base is fixed, the top leans with the wind."""
        s = max(0.0, min(1.0, (TRUNK_BASE - y) / (TRUNK_BASE - TRUNK_TOP)))
        return TRUNK_X + (BEND + self.lean) * s * s

    def top(self):
        return self.trunk_x(TRUNK_TOP), TRUNK_TOP

    def palm_points(self):
        """(x, y, brightness) points of the palm and the coconut."""
        pts = []
        t = self.t
        # trunk, with rings: alternate brightness every row
        y = TRUNK_TOP + 0.5
        while y <= TRUNK_BASE:
            ring = 0.8 if int(y * 2) % 3 == 0 else 1.0
            pts.append((self.trunk_x(y), y, 0.5 * TRUNK * ring))   # 2 points per row
            y += 0.5
        xc, yc = self.top()
        pts.append((xc, yc - 0.2, 1.0))                  # the heart of the crown
        gust_flutter = 1.0 + 1.5 * self.gust
        for k, (side, length, rise, droop, level) in enumerate(FRONDS):
            wobble = math.sin(2 * math.pi * 1.3 * t + self.phases[k]) * FLUTTER * gust_flutter
            for j in range(1, FROND_STEPS + 1):
                u = j / FROND_STEPS
                dx = side * length * u
                dy = -rise * u + droop * u * u
                # the wind blows the leaves downwind; the windward ones lift, the others hang
                dx += 0.6 * self.lean * u * u
                dy += (-0.5 * side * self.lean + wobble) * u * u
                # ~2–3 points fall on one LED: scale down so the crown keeps its shape
                pts.append((xc + dx, yc + dy, 0.6 * level * (1.0 - 0.2 * u)))
        c = self.coconut
        if c is not None:
            if c["state"] == "hang":
                shake = 0.15 * math.sin(2 * math.pi * 6 * (t - c["t0"]))
                pts.append((xc + c["dx"] + shake, c["y"], 1.0))
            else:
                pts.append((c["x"], c["y"], 1.0))
        return pts

    def sea_level(self, x, y):
        """Water brightness at LED (x, y), 0 above the sea."""
        if y < SEA_TOP:
            return 0.0
        t = self.t
        phase = 2 * math.pi * WAVE_HZ * t - x * 1.3      # waves roll left → right
        w = 0.5 + 0.5 * math.sin(phase)
        if y == SEA_TOP:                                 # upper row: only the crests show
            lv = SEA_BASE * 0.4 + SEA_AMP * max(0.0, (w - 0.45) / 0.55)
        else:
            lv = SEA_BASE + SEA_AMP * w
        for gx, gy, g0, gd in self.glints:
            if gx == x and gy == y:
                p = (t - g0) / gd
                lv = max(lv, math.sin(math.pi * p))
        if self.splash:
            sx, s0 = self.splash
            p = (t - s0) / 0.8
            d = abs(x - sx) - p * 2.5                    # a ring of spray running outwards
            lv = max(lv, (1 - p) * max(0.0, 1 - abs(d)))
        return lv


def splat(grid, x, y, level):
    """Spread a point over the 2×2 nearest LEDs (bilinear), adding light."""
    x0, y0 = math.floor(x), math.floor(y)
    fx, fy = x - x0, y - y0
    for cx, wx in ((x0, 1 - fx), (x0 + 1, fx)):
        if not 0 <= cx < COLS or wx <= 0:
            continue
        for cy, wy in ((y0, 1 - fy), (y0 + 1, fy)):
            if 0 <= cy < ROWS and wy > 0:
                grid[cy][cx] += level * wx * wy


beach = Beach()


def panel_layers():
    """Palm and sea brightness for every LED, as the viewer sees the panel: [row][col]."""
    palm = [[0.0] * COLS for _ in range(ROWS)]
    for x, y, lv in beach.palm_points():
        splat(palm, x, y, lv)
    sea = [[beach.sea_level(c, r) for c in range(COLS)] for r in range(ROWS)]
    for r in range(ROWS):
        for c in range(COLS):
            palm[r][c] = min(1.0, palm[r][c]) * PEAK
            sea[r][c] = min(1.0, sea[r][c]) * PEAK
            if r >= SEA_TOP and palm[r][c] > 0:           # the trunk stands in front of the water
                sea[r][c] *= 1 - palm[r][c]
    return palm, sea


def hub_colors():
    palm, sea = panel_layers()
    out = [RGBColor(0, 0, 0)] * (ROWS * COLS)
    for r in range(ROWS):
        for c in range(COLS):
            out[panel_index(r, c)] = mix(palm[r][c], sea[r][c])
    return out


def cooler_colors():
    """Cooler ring, idx 0 = 3 o'clock, clockwise.
    sea: a porthole — water in the lower part, its surface tilting with the wind and bobbing
         with the waves; sun: slowly turning rays in the GPU color."""
    n = SIZES[COOL]
    t = beach.t
    out = []
    for k in range(n):
        a = math.radians(k * 360 / n)
        x, y = math.cos(a), math.sin(a)                  # +y = down
        if COOLER_MODE == "sea":
            level = 0.1 + 0.15 * math.sin(2 * math.pi * WAVE_HZ * t)
            tilt = 0.3 * math.sin(2 * math.pi * 0.13 * t) + 0.25 * beach.lean
            depth = y - (-level + tilt * x)              # > 0 under the surface
            water = max(0.0, min(1.0, depth / 0.3 + 0.5))          # soft edge at the surface
            shimmer = 0.5 + 0.5 * math.sin(2 * math.pi * WAVE_HZ * t * 2 - 2 * x)
            lv = water * (0.65 + 0.25 * shimmer)
            lv = max(lv, max(0.0, 1 - abs(depth - 0.15) / 0.35))   # bright foam along the surface
            out.append(mix(0.0, lv * PEAK))
        elif COOLER_MODE == "sun":
            rays = 0.5 + 0.5 * math.cos(4 * a - 0.5 * t)
            out.append(mix(0.0, 0.0, (0.5 + 0.4 * rays) * PEAK))
        else:
            out.append(RGBColor(0, 0, 0))
    return out


# ---------- terminal preview ----------
if MODE == "--preview":
    def term(c, ch="██"):
        return f"\033[38;2;{c.red};{c.green};{c.blue}m{ch}\033[0m"

    print(f"Palm beach, view: {VIEW}. Ctrl+C to stop.")
    try:
        while True:
            now = time.monotonic()
            if cfg.poll(now):
                apply_config()
            if view_cfg.poll(now):
                apply_view()
            beach.step(DT)
            hub = hub_colors()
            lines = ["  fan panel as you see it"]
            for r in range(ROWS):
                lines.append("    |" + "".join(term(hub[panel_index(r, c)]) for c in range(COLS)) + "|")
            ring = cooler_colors()
            lines += ["", "  cooler 3→ " + " ".join(term(c, "●") for c in ring)]
            g = blink.rgb(blink.level(DT))
            rate = "steady" if blink.hz <= 0 else f"{blink.hz:.1f} Hz {'smooth' if blink.smooth else 'hard'}"
            lines += [f"  GPU       {term(g, '██████')}  {rate}",
                      f"  wind {beach.lean:+.2f}  gust {beach.gust:.2f}"
                      + ("  coconut!" if beach.coconut or beach.splash else "")]
            sys.stdout.write("\033[H\033[J" + "\n".join(lines) + "\n")
            sys.stdout.flush()
            time.sleep(DT)
    except KeyboardInterrupt:
        print()
    sys.exit(0)


# ---------- OpenRGB ----------
def connect():
    client = OpenRGBClient(E["OPENRGB_HOST"], int(E["OPENRGB_PORT"]), "airglow-palms")
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
    client = OpenRGBClient(E["OPENRGB_HOST"], int(E["OPENRGB_PORT"]), "airglow-palms")
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
    zc = {HUB: hub_colors(), COOL: cooler_colors()}
    frame = []
    for z in dev.zones:
        colors = zc.get(z.name)
        for i in range(len(z.leds)):
            frame.append(colors[i] if colors and i < len(colors) else off_c)
    return frame


last, last_wall = None, time.time()
prev = next_t = time.monotonic()
log_due, next_log = True, 0.0
where = f"'{dev.name}'" + (f" and '{gpu.dev.name}'" if gpu.dev else "")
print(f"Palm beach on {where}. Ctrl+C to stop.", flush=True)
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
        if view_cfg.poll(now):                # turned to the other side of the case
            apply_view()
            log_due = True
        if log_due and now >= next_log:       # journal: what is applied, at most once a second
            print(f"{settings_line()}, view {VIEW}", flush=True)
            log_due, next_log = False, now + 1.0
        beach.step(dt)
        frame = build_frame()
        if frame != last:
            dev.set_colors(frame, fast=True)
            last = frame
        gpu.push(blink.rgb(blink.level(dt)), now)
        gpu.look_again(now)
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
        fill = mix(1.0, 0.0) if ON_EXIT == "static" else off_c
        dev.set_colors([fill if z.name in (HUB, COOL) else off_c
                        for z in dev.zones for _ in z.leds], fast=True)
        gpu.fill(blink.rgb(1.0) if ON_EXIT == "static" else off_c)
    client.disconnect()
    gpu.close_extra()
except Exception:
    pass
print("Stopped.")
PYEOF
