#!/usr/bin/env bash
# airglow-stars.sh — temporary "starry sky" effect for the case fans; the CPU cooler ring is a
# black hole's accretion disk in the same color.
# A stopgap until Airglow is ready. Talks to the OpenRGB SDK server on 127.0.0.1:6742.
# The graphics card blinks in its own color.
#
# Colors and the GPU blink rate are read live from ~/.config/airglow/stopgap.json
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
: "${GPU_BLINK_HZ:=0.5}"      # GPU blinks per second, 0 = steady (stopgap.json: "gpu_blink_hz")
: "${GPU_SMOOTH:=1}"          # 1 = smooth breathing, 0 = hard on/off (stopgap.json: "gpu_smooth")
: "${GPU_FPS:=12}"            # max GPU updates per second (it sits on a slow I²C bus)
: "${AIRGLOW_CONFIG:=${XDG_CONFIG_HOME:-$HOME/.config}/airglow/stopgap.json}"
: "${BASE:=0.25}"             # background glow, perceived brightness 0..1 (0 = black sky)
: "${PEAK:=1.0}"              # star peak brightness 0..1
: "${DENSITY:=0.12}"          # average share of LEDs that are a "star" at any moment
: "${DARK:=0}"                # share of LEDs whose background is OFF (dark gaps), e.g. 0.15
: "${DARK_DRIFT:=8}"          # avg seconds before an LED re-rolls dark/lit (gaps slowly wander)
: "${DARK_FADE:=1.0}"         # seconds for a gap to fade in/out
: "${COOLER:=disk}"           # disk = black hole accretion disk on the cooler ring | stars = stars like the fans
: "${DISK_SPEED:=0.6}"        # disk: turns per second of the hot clumps (the bright side turns 5× slower)
: "${DISK_DIR:=1}"            # disk: 1 = clockwise (as seen through the side glass), -1 = the other way
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

export COLOR GPU GPU_COLOR GPU_BLINK_HZ GPU_SMOOTH GPU_FPS AIRGLOW_CONFIG \
       BASE PEAK DENSITY DARK DARK_DRIFT DARK_FADE STAR_MIN STAR_MAX FPS GAMMA ON_EXIT \
       COOLER DISK_SPEED DISK_DIR \
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


# ---------- live settings: colors and GPU blink (written by the GNOME extension) ----------
SECTION = "stars"
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


def color_at(level, white=0.0):
    """Perceived brightness 0..1 -> gamma-corrected RGBColor of the fan color,
    optionally shifted towards white (0..1) for the hottest spots of the disk."""
    k = max(0.0, min(1.0, level)) ** GAMMA
    w = max(0.0, min(1.0, white))
    return RGBColor(*(round((c + (255 - c) * w) * k) for c in FAN))


# ---------- cooler ring: a black hole's accretion disk ----------
COOLER_MODE = E["COOLER"]
DISK_SPEED = float(E["DISK_SPEED"])
DISK_DIR = -1 if E["DISK_DIR"].strip() == "-1" else 1


class AccretionDisk:
    """The cooler ring as a black hole's accretion disk, in the fan color:
    • a brighter side that slowly swings round — relativistic beaming: gas moving
      towards you looks brighter than gas moving away;
    • hot clumps on faster orbits with fading tails, which flare up for a few turns
      and fade, and new ones take their place;
    • slow turbulent flicker along the ring.
    The brightest spots shift towards white, like hotter gas. Positions are in turns
    (0..1) around the ring; LED k sits at k/n, clockwise (idx 0 = 3 o'clock)."""

    CLUMPS = 3

    def __init__(self, n):
        self.n, self.t = n, 0.0
        self.beam = random.random()
        self.swirl = [random.random() for _ in range(n)]
        self.clumps = [self._clump(random.random()) for _ in range(self.CLUMPS)]

    @staticmethod
    def _clump(age_share=0.0):
        life = random.uniform(2.5, 6.0)
        return {"pos": random.random(), "speed": DISK_SPEED * random.uniform(0.7, 1.3),
                "life": life, "age": age_share * life,
                "tail": random.uniform(0.18, 0.32), "power": random.uniform(0.6, 1.0)}

    def step(self, dt):
        self.t += dt
        self.beam = (self.beam + 0.2 * DISK_SPEED * dt) % 1.0
        for i, c in enumerate(self.clumps):
            c["pos"] = (c["pos"] + c["speed"] * dt) % 1.0
            c["age"] += dt
            if c["age"] >= c["life"]:
                self.clumps[i] = self._clump()

    def pixels(self):
        out = []
        for k in range(self.n):
            a = (DISK_DIR * k / self.n) % 1.0
            beaming = (0.5 + 0.5 * math.cos(2 * math.pi * (a - self.beam))) ** 2
            level = 0.24 + 0.4 * beaming                   # always a visible ring
            ph = self.swirl[k]
            level *= 1 + 0.2 * math.sin(2 * math.pi * (0.7 * self.t + ph)) \
                           * math.sin(2 * math.pi * (0.23 * self.t + 2 * ph))
            white = 0.15 * beaming * beaming
            for c in self.clumps:
                d = (c["pos"] - a) % 1.0                 # how far LED k is behind the clump
                if d >= c["tail"]:
                    continue
                v = (1 - d / c["tail"]) ** 2 * math.sin(math.pi * c["age"] / c["life"]) * c["power"]
                level += 0.8 * v
                white += 0.6 * v * v
            out.append((min(1.0, level), min(0.6, white)))
        return out


disk = AccretionDisk(SIZES[E["COOLER_ZONE"]])


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
        if z.name == E["COOLER_ZONE"] and COOLER_MODE == "disk":
            px = disk.pixels()
            frame += [color_at(*px[i]) if i < len(px) else off_c for i in range(len(z.leds))]
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
        disk.step(dt)
        if cfg.poll(now):                     # colors or blink rate changed in the settings
            apply_config()
            log_due = True
        if log_due and now >= next_log:       # journal: what is applied, at most once a second
            print(settings_line(), flush=True)
            log_due, next_log = False, now + 1.0
        frame = build_frame(now)
        if frame != last:                     # send only frames that changed
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
        dev.set_colors([fill if z.name in stars else off_c
                        for z in dev.zones for _ in z.leds], fast=True)
        gpu.fill(blink.rgb(1.0) if ON_EXIT == "static" else off_c)
    client.disconnect()
except Exception:
    pass
print("Stopped.")
PYEOF
