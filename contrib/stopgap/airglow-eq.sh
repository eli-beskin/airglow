#!/usr/bin/env bash
# airglow-eq.sh — temporary music equalizer for the case fans, blade petals and CPU cooler.
#
# Captures what is playing on the default audio output (Spotify, browser, anything you hear)
# through PipeWire — no microphone — splits it into bass / mid / treble and draws:
#   • fan dot panels: 3 equalizer bars (bass | mid | treble), green → yellow → red, peak dots
#   • blade petals:   a two-armed spinner that speeds up with the music and kicks on beats,
#                     changing color on every beat
#   • cooler ring:    a "liquid level" of the overall loudness
# The GPU is never touched.
#
# Usage:
#   ./airglow-eq.sh                         run the effect (Ctrl+C to stop)
#   ./airglow-eq.sh --preview               draw it in the terminal (audio yes, OpenRGB no)
#   SOURCE=demo ./airglow-eq.sh --preview   built-in test beat, no audio and no OpenRGB needed
#   ./airglow-eq.sh --list                  show OpenRGB devices and zones, then exit
#
# Settings can be overridden from the environment, e.g.:
#   SPIN_GAIN=2 COOLER=pulse ./airglow-eq.sh

set -euo pipefail

# ---------- settings ----------
: "${SOURCE:=monitor}"        # monitor = default output (what you hear) | demo = built-in test beat
                              # | anything else = PipeWire target for pw-record (experimental)
: "${BANDS:=40-250,250-2000,2000-12000}"   # Hz per bar, left→right as you see the panel
: "${DYN:=30}"                # dB range of a full bar (smaller = jumpier bars)
: "${GAIN:=0}"                # dB; raise if bars are too low, lower if they always hit the top
: "${AGC_FALL:=4}"            # dB/s: how fast the auto-gain adapts to quieter music
: "${GATE:=-62}"              # dBFS: below this the input counts as silence
: "${ATTACK:=0.6}"            # 0..1: how fast bars jump up
: "${RELEASE:=16}"            # rows/s: how fast bars fall
: "${PEAK_HOLD:=0.45}"        # seconds a peak dot hangs before falling
: "${PEAK_FALL:=9}"           # rows/s: peak dot fall speed
: "${SMOOTH:=1}"              # 1 = top cell lights partially (smooth), 0 = whole cells only
: "${COLUMN_COLORS:=0,255,120;0,255,20;150,255,0}"   # low part of each bar: bass, mid, treble
: "${YELLOW:=255,160,0}"
: "${RED:=255,0,12}"
: "${PEAK_COLOR:=255,255,255}"
: "${PALETTE:=0,200,255;140,0,255;255,0,160;0,70,255}"  # spinner colors, next one on every beat
: "${PETALS:=blend}"          # blend = spinner over the treble bar | spinner = petals belong to the
                              # spinner | eq = petals just follow the treble bar
: "${BLEND:=0.5}"             # in blend mode the spinner wins where it is brighter than bar × BLEND
: "${ARMS:=2}"                # spinner arms
: "${TAIL:=2.5}"              # spinner tail length, in petals
: "${SPIN_BASE:=0.25}"        # rev/s when quiet
: "${SPIN_GAIN:=1.2}"         # extra rev/s at full loudness
: "${KICK:=1.5}"              # extra rev/s on a beat (decays)
: "${COOLER:=level}"          # level = loudness fills the ring | pulse = ring pulses with the bass | off
: "${BRIGHT:=1.0}"            # global brightness 0..1
: "${FPS:=30}"
: "${GAMMA:=2.2}"
: "${ON_EXIT:=off}"           # off = black, keep = freeze last frame
: "${OFF_FLAG:=${XDG_RUNTIME_DIR:-/tmp}/airglow/off-requested}"  # exists while `airglow-fx off` runs → stop to black
: "${PW_LATENCY:=20ms}"       # pw-record node latency (only used when parec is missing)

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

# ---------- find a Python that has openrgb-python and numpy ----------
VENV_PY="$HOME/.local/share/airglow/venv/bin/python"
PY=""
for cand in "${AIRGLOW_PYTHON:-}" "$VENV_PY" python3; do
    [[ -n "$cand" ]] || continue
    if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import openrgb, numpy' 2>/dev/null; then
        PY="$cand"; break
    fi
done
if [[ -z "$PY" ]]; then
    cat >&2 <<EOF
openrgb-python or numpy not found. Install them into the venv once:
  python3 -m venv ~/.local/share/airglow/venv
  ~/.local/share/airglow/venv/bin/pip install openrgb-python==0.3.8 numpy
EOF
    exit 1
fi

# ---------- is the OpenRGB SDK server listening? (not needed for --preview) ----------
if [[ "$MODE" != "--preview" ]] && ! (exec 3<>"/dev/tcp/$OPENRGB_HOST/$OPENRGB_PORT") 2>/dev/null; then
    echo "OpenRGB SDK server is not reachable on $OPENRGB_HOST:$OPENRGB_PORT." >&2
    echo "Start OpenRGB with --server (or: systemctl --user start openrgb) and try again." >&2
    exit 1
fi

export SOURCE BANDS DYN GAIN AGC_FALL GATE ATTACK RELEASE PEAK_HOLD PEAK_FALL SMOOTH \
       COLUMN_COLORS YELLOW RED PEAK_COLOR PALETTE PETALS BLEND ARMS TAIL \
       SPIN_BASE SPIN_GAIN KICK COOLER BRIGHT FPS GAMMA ON_EXIT PW_LATENCY \
       DEVICE_MATCH COOLER_ZONE COOLER_LEDS HUB_ZONE HUB_LEDS EMPTY_ZONE \
       OPENRGB_HOST OPENRGB_PORT OFF_FLAG
export AIRGLOW_MODE="$MODE"

exec "$PY" - <<'PYEOF'
import math, os, shutil, signal, subprocess, sys, threading, time
import numpy as np

E = os.environ
MODE = E["AIRGLOW_MODE"]


def rgb(s):
    return tuple(float(v) for v in s.split(","))


def rgbs(s):
    return [rgb(p) for p in s.split(";") if p.strip()]


SOURCE = E["SOURCE"]
BANDS = [tuple(float(v) for v in b.split("-")) for b in E["BANDS"].split(",")]
if len(BANDS) != 3:
    raise SystemExit("BANDS must have exactly 3 ranges, e.g. 40-250,250-2000,2000-12000")
DYN, GAIN, AGC_FALL, GATE = (float(E[k]) for k in ("DYN", "GAIN", "AGC_FALL", "GATE"))
ATTACK, RELEASE = float(E["ATTACK"]), float(E["RELEASE"])
PEAK_HOLD, PEAK_FALL = float(E["PEAK_HOLD"]), float(E["PEAK_FALL"])
SMOOTH = E["SMOOTH"] == "1"
LOW, YELLOW, RED, PEAKC = rgbs(E["COLUMN_COLORS"]), rgb(E["YELLOW"]), rgb(E["RED"]), rgb(E["PEAK_COLOR"])
if len(LOW) != 3:
    raise SystemExit("COLUMN_COLORS must have 3 colors: bass;mid;treble")
PALETTE = rgbs(E["PALETTE"])
PETALS_MODE, BLEND = E["PETALS"], float(E["BLEND"])
ARMS, TAIL = max(1, int(E["ARMS"])), max(0.5, float(E["TAIL"]))
SPIN_BASE, SPIN_GAIN, KICK = float(E["SPIN_BASE"]), float(E["SPIN_GAIN"]), float(E["KICK"])
COOLER_MODE = E["COOLER"]
BRIGHT, FPS, GAMMA = float(E["BRIGHT"]), float(E["FPS"]), float(E["GAMMA"])
ON_EXIT = E["ON_EXIT"]
DT = 1.0 / FPS

ROWS, COLS, PETALS = 13, 3, 8
HUB, COOL = E["HUB_ZONE"], E["COOLER_ZONE"]
SIZES = {COOL: int(E["COOLER_LEDS"]), HUB: int(E["HUB_LEDS"]), E["EMPTY_ZONE"]: 0}
RATE, NFFT = 48000, 2048          # ~43 ms of audio per analysis window


# ---------- audio sources ----------
class Capture:
    """Runs a recorder (parec / pw-record) that writes mono s16le PCM to stdout and keeps
    the newest NFFT samples in a ring buffer. Restarts the recorder if it dies."""

    def __init__(self, cmd, label):
        self.cmd, self.label = cmd, label
        self.buf = np.zeros(NFFT, np.float32)
        self.lock = threading.Lock()
        self.last = 0.0
        self.proc = None
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        while True:
            try:
                self.proc = subprocess.Popen(self.cmd, stdout=subprocess.PIPE)
                rest = b""
                while True:
                    chunk = self.proc.stdout.read1(8192)
                    if not chunk:
                        break
                    data = rest + chunk
                    n = len(data) & ~1
                    rest = data[n:]
                    s = np.frombuffer(data[:n], "<i2").astype(np.float32) / 32768.0
                    with self.lock:
                        if len(s) >= NFFT:
                            self.buf[:] = s[-NFFT:]
                        elif len(s):
                            self.buf[:-len(s)] = self.buf[len(s):]
                            self.buf[-len(s):] = s
                    self.last = time.monotonic()
            except Exception as e:
                print(f"Audio capture error: {e}", file=sys.stderr, flush=True)
            print("Audio capture ended; restarting in 3 s…", file=sys.stderr, flush=True)
            time.sleep(3)

    def samples(self):
        if time.monotonic() - self.last > 0.3:
            return None               # nothing is playing, or the recorder is restarting
        with self.lock:
            return self.buf.copy()

    def close(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()


class Demo:
    """Synthetic 124 BPM groove (kick, bass, snare, hi-hats, pad) for testing without audio."""
    label = "built-in demo beat (124 BPM)"

    def __init__(self):
        self.t0 = time.monotonic()

    def samples(self):
        t = (time.monotonic() - self.t0) - np.arange(NFFT)[::-1] / RATE
        beat = 60 / 124
        ph = np.mod(t, beat)
        kick = np.sin(2 * np.pi * (45 + 80 * np.exp(-ph * 25)) * ph) * np.exp(-ph * 8)
        bar = np.mod(t, beat * 4)
        bass_f = np.where(bar < beat * 2, 55.0, 73.4)
        bass = 0.3 * np.sin(2 * np.pi * bass_f * t)
        noise = np.random.standard_normal(NFFT)
        snare = 0.35 * noise * np.exp(-np.mod(t - beat, beat * 2) * 16)
        hats = 0.5 * np.diff(noise, prepend=0.0) * np.exp(-np.mod(t, beat / 2) * 45)
        swell = 0.5 + 0.5 * np.sin(2 * np.pi * t / (beat * 8))
        pad = 0.12 * swell * sum(np.sin(2 * np.pi * f * t) for f in (440, 554, 659, 880))
        return (0.25 * (kick + bass + snare + hats + pad)).astype(np.float32)

    def close(self):
        pass


def make_source():
    if SOURCE == "demo":
        return Demo()
    if SOURCE == "monitor" and shutil.which("parec"):
        return Capture(["parec", "--device=@DEFAULT_MONITOR@", "--raw", "--format=s16le",
                        f"--rate={RATE}", "--channels=1", "--latency-msec=20"],
                       "default output (parec)")
    if shutil.which("pw-record"):
        cmd = ["pw-record", "--rate", str(RATE), "--channels", "1", "--format", "s16"]
        if E["PW_LATENCY"]:
            cmd += ["--latency", E["PW_LATENCY"]]
        if SOURCE == "monitor":
            cmd += ["-P", "{ stream.capture.sink = true }"]     # record what the speakers play
            label = "default output (pw-record)"
        else:
            cmd += ["--target", SOURCE]
            label = f"PipeWire target {SOURCE!r} (pw-record)"
        return Capture(cmd + ["-"], label)
    raise SystemExit("No audio recorder found: need parec (pulseaudio-utils) or pw-record (pipewire-utils).")


# ---------- analysis ----------
WIN = np.hanning(NFFT).astype(np.float32)
FREQS = np.fft.rfftfreq(NFFT, 1 / RATE)
MASKS = [(FREQS >= lo) & (FREQS < hi) for lo, hi in BANDS]


class Analyzer:
    """Band levels 0..1 with per-band auto-gain, overall loudness and a simple bass beat detector."""

    def __init__(self):
        self.ref = [None] * 3          # loudest recent dB per band (auto-gain reference)
        self.bass_slow = 0.0
        self.last_beat = 0.0

    def update(self, x, now, dt):
        if x is None:
            return [0.0] * 3, 0.0, False
        rms_db = 20 * math.log10(float(np.sqrt(np.mean(x * x))) + 1e-9)
        if rms_db < GATE:                                  # silence: keep the auto-gain frozen
            return [0.0] * 3, 0.0, False
        spec = np.abs(np.fft.rfft(x * WIN)) ** 2
        lv = []
        for i, m in enumerate(MASKS):
            d = 10 * math.log10(float(spec[m].sum()) + 1e-12)
            r = self.ref[i]
            r = d if r is None else max(d, r - AGC_FALL * dt)
            self.ref[i] = r
            lv.append(min(1.0, max(0.0, (d + GAIN - (r - DYN)) / DYN)))
        loud = 0.5 * lv[0] + 0.3 * lv[1] + 0.2 * lv[2]
        beat = lv[0] - self.bass_slow > 0.15 and lv[0] > 0.55 and now - self.last_beat > 0.25
        if beat:
            self.last_beat = now
        self.bass_slow += (lv[0] - self.bass_slow) * min(1.0, dt / 0.35)
        return lv, loud, beat


# ---------- visuals ----------
def lerp(a, b, t):
    return tuple(x + (y - x) * t for x, y in zip(a, b))


def eq_color(col, t):
    """Classic meter gradient by height t (0 = bottom, 1 = top), low part tinted per bar."""
    if t <= 0.5:
        return LOW[col]
    if t <= 0.72:
        return lerp(LOW[col], YELLOW, (t - 0.5) / 0.22)
    if t <= 0.9:
        return lerp(YELLOW, RED, (t - 0.72) / 0.18)
    return RED


class Bars:
    def __init__(self):
        self.h = [0.0] * 3             # bar height in rows (0..13)
        self.pk = [0.0] * 3            # peak dot height
        self.pk_t = [0.0] * 3

    def update(self, lv, now, dt):
        for i in range(3):
            target = lv[i] * ROWS
            if target > self.h[i]:
                self.h[i] += (target - self.h[i]) * ATTACK
            else:
                self.h[i] = max(target, self.h[i] - RELEASE * dt)
            if self.h[i] >= self.pk[i]:
                self.pk[i], self.pk_t[i] = self.h[i], now
            elif now - self.pk_t[i] > PEAK_HOLD:
                self.pk[i] = max(self.h[i], self.pk[i] - PEAK_FALL * dt)


class Spinner:
    def __init__(self):
        self.pos, self.kick, self.flash, self.loud = 0.0, 0.0, 0.0, 0.0
        self.pal, self.mix = 0, 1.0

    def update(self, loud, beat, dt):
        if beat:
            self.kick += KICK
            self.flash = 1.0
            self.pal = (self.pal + 1) % len(PALETTE)
            self.mix = 0.0
        self.kick *= math.exp(-3.0 * dt)
        self.flash *= math.exp(-7.0 * dt)
        self.mix = min(1.0, self.mix + dt / 0.25)          # 0.25 s cross-fade to the new color
        self.loud = loud
        speed = SPIN_BASE + SPIN_GAIN * loud + self.kick    # revolutions per second
        self.pos = (self.pos + speed * PETALS * dt) % PETALS

    def color(self):
        return lerp(PALETTE[self.pal - 1], PALETTE[self.pal], self.mix)

    def petal(self, k):
        """(color, intensity) of petal k: comet heads with fading tails, idx 0 = 12 o'clock."""
        span = PETALS / ARMS
        d = (self.pos - k) % span                          # how far petal k is behind a head
        comet = (1 - d / TAIL) ** 1.6 if d < TAIL else 0.0
        comet = max(comet, d - (span - 1))                 # fade in the petal just ahead
        inten = comet * (0.35 + 0.65 * self.loud) + 0.5 * self.flash
        return self.color(), min(1.0, inten)


def panel_index(row, col_from_left):
    """Viewer-facing LEFT panel: row 0 = top, outer column is leftmost, inner column (idx 0..12)
    is next to the propeller; idx 0..7 also drive the blade petals."""
    return (COLS - 1 - col_from_left) * ROWS + row


BLACK = ((0.0, 0.0, 0.0), 0.0)


def hub_pixels(bars, sp):
    px = [BLACK] * (ROWS * COLS)
    for c in range(COLS):
        h, pk = bars.h[c], bars.pk[c]
        pk_cell = min(ROWS - 1, int(pk))
        for row in range(ROWS):
            hb = ROWS - 1 - row                            # cell height from the bottom
            fill = min(1.0, max(0.0, h - hb)) if SMOOTH else (1.0 if hb < round(h) else 0.0)
            i = panel_index(row, c)
            if fill > 0.02:
                cur = (eq_color(c, hb / (ROWS - 1)), fill)
            elif hb == pk_cell and pk > 0.6 and pk - h > 0.5:
                cur = (PEAKC, 0.75)
            else:
                cur = BLACK
            if i < PETALS and PETALS_MODE != "eq":         # shared LED: panel dot + blade petal
                s = sp.petal(i)
                if PETALS_MODE == "spinner" or s[1] > cur[1] * BLEND:
                    cur = s
            px[i] = cur
    return px


def cooler_pixels(n, lv, loud, sp):
    out = []
    for k in range(n):
        y = math.sin(math.radians(k * 360 / n))           # idx 0 = 3 o'clock, clockwise, +y = down
        hh = (1 - y) / 2                                   # 0 = bottom of the ring, 1 = top
        if COOLER_MODE == "level":
            fill = min(1.0, max(0.0, (loud * 1.15 - hh) / 0.15))
            out.append((eq_color(1, hh), fill))
        elif COOLER_MODE == "pulse":
            out.append((sp.color(), min(1.0, 0.12 + 0.88 * lv[0] + 0.4 * sp.flash)))
        else:
            out.append(BLACK)
    return out


src = make_source()
an, bars, sp = Analyzer(), Bars(), Spinner()
state = {"lv": [0.0] * 3, "loud": 0.0}


def tick(now, dt):
    lv, loud, beat = an.update(src.samples(), now, dt)
    bars.update(lv, now, dt)
    sp.update(loud, beat, dt)
    state["lv"], state["loud"] = lv, loud


# ---------- terminal preview ----------
if MODE == "--preview":
    RESET = "\033[0m"

    def term(p, text="██"):
        (r, g, b), k = p
        return f"\033[38;2;{round(r * k)};{round(g * k)};{round(b * k)}m{text}"

    def meter(v):
        n = round(v * 20)
        return "█" * n + "·" * (20 - n)

    sys.stdout.write("\033[?25l\033[2J")
    try:
        last = time.monotonic()
        while True:
            now = time.monotonic()
            tick(now, min(0.1, now - last))
            last = now
            hub = hub_pixels(bars, sp)
            cool = cooler_pixels(SIZES[COOL], state["lv"], state["loud"], sp)
            lines = [f"Airglow EQ preview — {src.label}   Ctrl+C to stop", "",
                     "   left fan panel (as you see it)    bass  mid  treble"]
            for row in range(ROWS):
                lines.append("   " + " ".join(term(hub[panel_index(row, c)]) for c in range(COLS)) + RESET)
            lines.append("")
            lines.append("   petals 12→ " + " ".join(term(hub[k], "●") for k in range(PETALS)) + RESET)
            lines.append("   cooler  3→ " + " ".join(term(p, "●") for p in cool) + RESET)
            lines.append("")
            lv = state["lv"]
            lines.append(f"   bass   {meter(lv[0])}")
            lines.append(f"   mid    {meter(lv[1])}")
            lines.append(f"   treble {meter(lv[2])}")
            lines.append(f"   beat   {'●' if sp.flash > 0.3 else ' '}")
            sys.stdout.write("\033[H" + "\n".join(lines) + "\033[J")
            sys.stdout.flush()
            time.sleep(max(0.0, DT - (time.monotonic() - now)))
    except KeyboardInterrupt:
        pass
    finally:
        src.close()
        sys.stdout.write(RESET + "\033[?25h\n")
    sys.exit(0)


# ---------- OpenRGB ----------
from openrgb import OpenRGBClient
from openrgb.utils import RGBColor, DeviceType


def led(p):
    (r, g, b), k = p
    k = BRIGHT * max(0.0, min(1.0, k)) ** GAMMA          # gamma on intensity only: hue stays put
    return RGBColor(round(r * k), round(g * k), round(b * k))


def connect():
    client = OpenRGBClient(E["OPENRGB_HOST"], int(E["OPENRGB_PORT"]), "airglow-eq")
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
    client = OpenRGBClient(E["OPENRGB_HOST"], int(E["OPENRGB_PORT"]), "airglow-eq")
    for i, d in enumerate(client.devices):
        print(f"[{i}] {d.name}  ({d.type.name})")
        for z in d.zones:
            print(f"      zone '{z.name}': {len(z.leds)} LEDs")
    client.disconnect()
    src.close()
    sys.exit(0)

client, dev = connect()
OFF = RGBColor(0, 0, 0)
running = True


def stop(*_):
    global running
    running = False


signal.signal(signal.SIGINT, stop)
signal.signal(signal.SIGTERM, stop)


def build_frame():
    zl = {HUB: hub_pixels(bars, sp),
          COOL: cooler_pixels(SIZES[COOL], state["lv"], state["loud"], sp)}
    frame = []
    for z in dev.zones:
        px = zl.get(z.name)
        for i in range(len(z.leds)):
            frame.append(led(px[i]) if px and i < len(px) else OFF)
    return frame


last, last_wall = None, time.time()
prev = next_t = time.monotonic()
print(f"Equalizer on '{dev.name}', audio: {src.label}. Ctrl+C to stop.", flush=True)
while running:
    try:
        wall = time.time()
        if wall - last_wall > 5:              # we slept/resumed: hardware lost its state
            client.disconnect()
            client, dev = connect()
            last = None
        last_wall = wall
        now = time.monotonic()
        tick(now, min(0.1, now - prev))
        prev = now
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
        next_t = prev = time.monotonic()
        continue
    next_t += DT
    time.sleep(max(0.0, next_t - time.monotonic()))

src.close()
if os.path.exists(E["OFF_FLAG"]):    # `airglow-fx off`: stop to black whatever ON_EXIT says
    ON_EXIT = "off"

try:
    if ON_EXIT == "off":
        dev.set_colors([OFF for z in dev.zones for _ in z.leds], fast=True)
    client.disconnect()
except Exception:
    pass
print("Stopped.")
PYEOF
