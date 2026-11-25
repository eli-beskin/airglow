#!/usr/bin/env bash
# airglow-stars.sh — temporary "starry sky" effect for the CPU cooler and case fans.
# A stopgap until Airglow is ready. Talks to the OpenRGB SDK server on 127.0.0.1:6742.
# The graphics card glows steadily in its own color.
#
# Colors are read live from ~/.config/airglow/stopgap.json
# (section "stars"), which the GNOME extension's settings window writes. Without that
# file the settings below are used.
#
# Usage:
#   ./airglow-stars.sh          run the effect (Ctrl+C to stop)
#   ./airglow-stars.sh --list   show OpenRGB devices and zones, then exit
#
# Every setting below can also be overridden from the environment, e.g.:
#   DENSITY=0.2 BASE=0.15 ./airglow-stars.sh

set -euo pipefail

# ---------- settings ----------
: "${COLOR:=0,255,94}"        # fans + cooler R,G,B              (stopgap.json: "fans")
: "${GPU:=on}"                # on = also drive the graphics card | off = leave it alone
: "${GPU_COLOR:=$COLOR}"      # GPU R,G,B                         (stopgap.json: "gpu")
: "${GPU_FPS:=12}"            # max GPU updates per second (it sits on a slow I²C bus)
: "${AIRGLOW_CONFIG:=${XDG_CONFIG_HOME:-$HOME/.config}/airglow/stopgap.json}"
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
: "${OFF_FLAG:=${XDG_RUNTIME_DIR:-/tmp}/airglow/off-requested}"  # exists while `airglow-fx off` runs → stop to black

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

export COLOR GPU GPU_COLOR GPU_FPS AIRGLOW_CONFIG \
       BASE PEAK DENSITY DARK DARK_DRIFT DARK_FADE STAR_MIN STAR_MAX FPS GAMMA ON_EXIT \
       DEVICE_MATCH COOLER_ZONE COOLER_LEDS HUB_ZONE HUB_LEDS EMPTY_ZONE \
       OPENRGB_HOST OPENRGB_PORT OFF_FLAG
export AIRGLOW_LIST="${1:-}"

exec "$PY" - <<'PYEOF'
import copy, json, math, os, random, signal, sys, time
from openrgb import OpenRGBClient
from openrgb.utils import RGBColor, DeviceType, ModeFlags

E = os.environ
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


# ---------- live settings: colors (written by the GNOME extension) ----------
SECTION = "stars"


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


class GpuLight:
    """The graphics card's light: one steady color, no blinking. Every write to the card goes
    over its I²C bus inside the NVIDIA driver; on the reference machine that cost ~30 ms of
    CPU per write and made GNOME drop frames while blinking (12 writes/s). So the card is
    written only when its color changes."""

    def __init__(self):
        self.color = (0, 0, 0)

    def configure(self, color):
        self.color = color

    def rgb(self, level=1.0):
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
    "fans": E["COLOR"], "gpu": E["GPU_COLOR"]})
FAN = rgb3(E["COLOR"], (0, 255, 94))
gpu_light = GpuLight()
gpu = GpuOut(E["GPU"] == "on", float(E["GPU_FPS"]))


def apply_config():
    global FAN
    v, d = cfg.values, cfg.defaults
    FAN = rgb3(v["fans"], rgb3(d["fans"], FAN))
    gpu_light.configure(rgb3(v["gpu"], rgb3(d["gpu"], FAN)))


def settings_line():
    hx = lambda c: "#%02X%02X%02X" % tuple(c)
    return f"Settings: fans {hx(FAN)}, GPU {hx(gpu_light.color)}"


cfg.poll(0.0)
apply_config()


def color_at(level):
    """Perceived brightness 0..1 -> gamma-corrected RGBColor of the fan color."""
    k = max(0.0, min(1.0, level)) ** GAMMA
    return RGBColor(round(FAN[0] * k), round(FAN[1] * k), round(FAN[2] * k))


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
    gpu.attach(client)              # same rule for the GPU: its first color follows at once
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
prev = next_t = time.monotonic()
log_due, next_log = True, 0.0
where = f"'{dev.name}'" + (f" and '{gpu.dev.name}'" if gpu.dev else "")
print(f"Starry sky on {where}. Ctrl+C to stop.", flush=True)
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
        if cfg.poll(now):                     # colors changed in the settings
            apply_config()
            log_due = True
        if log_due and now >= next_log:       # journal: what is applied, at most once a second
            print(settings_line(), flush=True)
            log_due, next_log = False, now + 1.0
        frame = build_frame(now)
        if frame != last:                     # send only frames that changed
            dev.set_colors(frame, fast=True)
            last = frame
        gpu.push(gpu_light.rgb(), now)
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
        fill = color_at(1.0) if ON_EXIT == "static" else off_c
        dev.set_colors([fill if z.name in stars else off_c
                        for z in dev.zones for _ in z.leds], fast=True)
        gpu.fill(gpu_light.rgb(1.0) if ON_EXIT == "static" else off_c)
    client.disconnect()
    gpu.close_extra()
except Exception:
    pass
print("Stopped.")
PYEOF
