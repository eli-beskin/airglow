// Airglow Lighting — settings window (opens from Quick Settings → Lighting → Colors…,
// or from the Extensions app).
//
// What it sets:
//   • which side of the case you look at (side glass or front panel), so the fan strip
//     animations of cats and the equalizer face you;
//   • per effect (stars, cats): fans + cooler color, graphics card color — a color wheel,
//     brightness, R/G/B, HEX, presets — and how the graphics card blinks.
// The equalizer picks its colors from the music, so it only gets a short description.
//
// How it works
//   • Settings are written to ~/.config/airglow/stopgap.json (atomically, ~0.15 s after a
//     change). The effect scripts re-read that file 4× per second, so the case changes
//     while you drag. No GSettings schema: the Python effects read plain JSON.
//   • Keys the window does not know are kept when it saves.

import Adw from 'gi://Adw';
import Gdk from 'gi://Gdk';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import Graphene from 'gi://Graphene';
import Gtk from 'gi://Gtk';

import {ExtensionPreferences} from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

const CONFIG_DIR = GLib.build_filenamev([GLib.get_user_config_dir(), 'airglow']);
const CONFIG = GLib.build_filenamev([CONFIG_DIR, 'stopgap.json']);
const SAVE_DELAY_MS = 150;
const MAX_HZ = 4;

// Must match the defaults in contrib/stopgap/airglow-{stars,cats,eq}.sh and their units.
const DEFAULTS = {
    general: {view: 'side'},
    stars: {fans: [0, 255, 94], gpu: [0, 255, 94], gpu_blink_hz: 0.5, gpu_smooth: true},
    cats: {fans: [0, 255, 94], gpu: [255, 16, 120], gpu_blink_hz: 1, gpu_smooth: false},
};
const SECTIONS = Object.keys(DEFAULTS);
const VIEWS = ['side', 'front'];

const PRESETS = [
    [0, 255, 94], [0, 255, 20], [0, 200, 255], [0, 70, 255], [140, 0, 255],
    [255, 0, 160], [255, 16, 120], [255, 0, 12], [255, 100, 0], [255, 200, 0], [255, 255, 255],
];

// ---------- tiny built-in translation: Russian or English ----------
const STRINGS = {
    en: {
        page: 'Lighting',
        pageHint: 'Changes apply right away while the effect is running.',
        nowOn: 'Now on the case',
        nowOff: 'Lighting is off',
        onCase: 'on the case',
        viewGroup: 'View',
        view: 'I look at the case',
        viewHint: 'Side: through the glass, front: through the front panel. Cats and the equalizer turn their fan strip animations to face you.',
        viewSide: 'From the side',
        viewFront: 'From the front',
        stars: 'Stars',
        starsHint: 'Starry sky on the fans, a black hole accretion disk on the cooler; the graphics card blinks.',
        cats: 'Cats',
        catsHint: 'Falling cats on the fans; the graphics card blinks.',
        eq: 'Equalizer',
        eqHint: 'Colors follow the music — nothing to set here.',
        eqGpu: 'Flashes on every bass beat in the color of the blade spinner and glows dimly with the bass in between.',
        fans: 'Fans and cooler',
        gpu: 'Graphics card',
        blink: 'Graphics card blinking',
        steady: 'Steady — no blinking',
        perSecond: 'blinks per second',
        smooth: 'Smooth blinking',
        smoothHint: 'Off: sharp on/off flashes',
        reset: 'Reset',
        pick: 'Pick a color',
        brightness: 'Brightness',
    },
    ru: {
        page: 'Подсветка',
        pageHint: 'Изменения применяются сразу, если эффект запущен.',
        nowOn: 'Сейчас на корпусе',
        nowOff: 'Подсветка выключена',
        onCase: 'на корпусе',
        viewGroup: 'Вид',
        view: 'Смотрю на корпус',
        viewHint: 'Сбоку — через стекло, спереди — через переднюю панель. Котики и эквалайзер развернут анимацию на полосках вентиляторов к тебе.',
        viewSide: 'Сбоку',
        viewFront: 'Спереди',
        stars: 'Звёзды',
        starsHint: 'Звёздное небо на вентиляторах, на кулере — аккреционный диск чёрной дыры, видеокарта мигает.',
        cats: 'Котики',
        catsHint: 'Падающие котики на вентиляторах, видеокарта мигает.',
        eq: 'Эквалайзер',
        eqHint: 'Цвета подстраиваются под музыку — настраивать нечего.',
        eqGpu: 'Вспыхивает на каждый удар баса цветом спиннера на лопастях, между ударами тускло светится в такт басу.',
        fans: 'Вентиляторы и кулер',
        gpu: 'Видеокарта',
        blink: 'Мигание видеокарты',
        steady: 'Не мигает — горит ровно',
        perSecond: 'вспышек в секунду',
        smooth: 'Плавное мигание',
        smoothHint: 'Выключено — резкие вспышки',
        reset: 'Сбросить',
        pick: 'Выбрать цвет',
        brightness: 'Яркость',
    },
};
const RU = GLib.get_language_names()[0].startsWith('ru');
const T = RU ? STRINGS.ru : STRINGS.en;

const clone = v => JSON.parse(JSON.stringify(v));
const isObject = v => v !== null && typeof v === 'object' && !Array.isArray(v);
const fmtNumber = v => (RU ? v.toFixed(1).replace('.', ',') : v.toFixed(1));

// ---------- colors ----------
function hex(rgb) {
    return `#${rgb.map(c => c.toString(16).padStart(2, '0')).join('')}`.toUpperCase();
}

function parseColor(text) {
    const s = text.trim();
    let m = s.match(/^#?([0-9a-f]{6})$/i);
    if (m)
        return [0, 2, 4].map(i => parseInt(m[1].slice(i, i + 2), 16));
    m = s.match(/^(\d{1,3})[\s,;]+(\d{1,3})[\s,;]+(\d{1,3})$/);
    if (m && m.slice(1).every(c => Number(c) <= 255))
        return m.slice(1).map(Number);
    return null;
}

function rgbToHsv([r, g, b]) {
    r /= 255; g /= 255; b /= 255;
    const max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min;
    let h = 0;
    if (d > 0) {
        if (max === r)
            h = ((g - b) / d) % 6;
        else if (max === g)
            h = (b - r) / d + 2;
        else
            h = (r - g) / d + 4;
        h *= 60;
        if (h < 0)
            h += 360;
    }
    return [h, max === 0 ? 0 : d / max, max];
}

function hsvToRgb(h, s, v) {
    const f = n => {
        const k = (n + h / 60) % 6;
        return v - v * s * Math.max(0, Math.min(k, 4 - k, 1));
    };
    return [f(5), f(3), f(1)].map(c => Math.round(c * 255));
}

// ---------- settings file ----------
function sanitize(key, v) {
    if (key === 'fans' || key === 'gpu') {
        return Array.isArray(v) && v.length === 3 &&
            v.every(c => Number.isInteger(c) && c >= 0 && c <= 255) ? [...v] : undefined;
    }
    if (key === 'gpu_blink_hz') {
        return typeof v === 'number' && Number.isFinite(v)
            ? Math.round(Math.min(MAX_HZ, Math.max(0, v)) * 10) / 10 : undefined;
    }
    if (key === 'gpu_smooth')
        return typeof v === 'boolean' ? v : undefined;
    if (key === 'view')
        return VIEWS.includes(v) ? v : undefined;
    return undefined;
}

class Store {
    constructor() {
        this._raw = {};
        this._timer = 0;
        this.cfg = clone(DEFAULTS);
        this._load();
    }

    _load() {
        let text;
        try {
            const [, bytes] = GLib.file_get_contents(CONFIG);
            text = new TextDecoder().decode(bytes);
        } catch (e) {
            return;                                  // no file yet: defaults
        }
        let data;
        try {
            data = JSON.parse(text);
        } catch (e) {
            console.warn(`Airglow: ${CONFIG} is not valid JSON (${e.message}); starting from defaults`);
            return;
        }
        if (!isObject(data))
            return;
        this._raw = data;
        for (const fx of SECTIONS) {
            if (!isObject(data[fx]))
                continue;
            for (const key of Object.keys(DEFAULTS[fx])) {
                const v = sanitize(key, data[fx][key]);
                if (v !== undefined)
                    this.cfg[fx][key] = v;
            }
        }
    }

    get(fx, key) {
        return this.cfg[fx][key];
    }

    set(fx, key, value) {
        this.cfg[fx][key] = value;
        this._schedule();
    }

    reset(fx) {
        this.cfg[fx] = clone(DEFAULTS[fx]);
        this._schedule();
    }

    _schedule() {
        if (this._timer)
            return;
        this._timer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, SAVE_DELAY_MS, () => {
            this._timer = 0;
            this._save();
            return GLib.SOURCE_REMOVE;
        });
    }

    flush() {
        if (!this._timer)
            return;
        GLib.source_remove(this._timer);
        this._timer = 0;
        this._save();
    }

    _save() {
        const out = {...this._raw};
        for (const fx of SECTIONS)
            out[fx] = {...(isObject(this._raw[fx]) ? this._raw[fx] : {}), ...this.cfg[fx]};
        try {
            GLib.mkdir_with_parents(CONFIG_DIR, 0o755);
            // file_set_contents writes a temp file and renames it: the effects never
            // read a half-written file.
            GLib.file_set_contents(CONFIG, `${JSON.stringify(out, null, 2)}\n`);
            this._raw = out;
        } catch (e) {
            console.warn(`Airglow: cannot save ${CONFIG}: ${e.message}`);
        }
    }
}

// ---------- color wheel widget ----------
const WHEEL = 200;   // size in logical pixels
const PAD = 6;       // room for the marker at the rim

let wheelTexture = null;

// Hue around the circle (red at 3 o'clock, counter-clockwise), saturation from the
// centre (white) to the rim. Rendered once at 2× for HiDPI screens.
function getWheelTexture() {
    if (wheelTexture)
        return wheelTexture;
    const n = WHEEL * 2, c = n / 2, r = c - PAD * 2;
    const data = new Uint8Array(n * n * 4);
    for (let y = 0; y < n; y++) {
        for (let x = 0; x < n; x++) {
            const dx = x + 0.5 - c, dy = y + 0.5 - c;
            const d = Math.hypot(dx, dy);
            if (d > r + 1)
                continue;
            let h = Math.atan2(-dy, dx) * 180 / Math.PI;
            if (h < 0)
                h += 360;
            const [cr, cg, cb] = hsvToRgb(h, Math.min(1, d / r), 1);
            const i = (y * n + x) * 4;
            data[i] = cr;
            data[i + 1] = cg;
            data[i + 2] = cb;
            data[i + 3] = Math.round(Math.max(0, Math.min(1, r + 0.5 - d)) * 255);   // smooth rim
        }
    }
    wheelTexture = Gdk.MemoryTexture.new(n, n, Gdk.MemoryFormat.R8G8B8A8, new GLib.Bytes(data), n * 4);
    return wheelTexture;
}

const ColorWheel = GObject.registerClass(
class AirglowColorWheel extends Gtk.Widget {
    _init() {
        super._init({halign: Gtk.Align.CENTER, valign: Gtk.Align.CENTER});
        this._h = 0;
        this._s = 0;
        this._v = 1;
        this.onPick = null;
        this.set_cursor_from_name('crosshair');

        const drag = new Gtk.GestureDrag();
        drag.connect('drag-begin', (_g, x, y) => {
            this._start = [x, y];
            this._pick(x, y);
        });
        drag.connect('drag-update', (_g, dx, dy) => this._pick(this._start[0] + dx, this._start[1] + dy));
        this.add_controller(drag);
    }

    vfunc_measure(_orientation, _forSize) {
        return [WHEEL, WHEEL, -1, -1];
    }

    setColor(h, s, v) {
        [this._h, this._s, this._v] = [h, s, v];
        this.queue_draw();
    }

    _geometry() {
        const w = this.get_width(), h = this.get_height();
        const size = Math.min(w, h);
        return {
            size, cx: w / 2, cy: h / 2,
            x0: (w - size) / 2, y0: (h - size) / 2,
            r: size / 2 - PAD * size / WHEEL,
        };
    }

    _pick(x, y) {
        const g = this._geometry();
        const dx = x - g.cx, dy = y - g.cy;
        let hue = Math.atan2(-dy, dx) * 180 / Math.PI;
        if (hue < 0)
            hue += 360;
        this._h = hue;
        this._s = Math.min(1, Math.hypot(dx, dy) / g.r);
        this.queue_draw();
        this.onPick?.(this._h, this._s);
    }

    vfunc_snapshot(snapshot) {
        const g = this._geometry();
        const rect = new Graphene.Rect().init(g.x0, g.y0, g.size, g.size);
        snapshot.append_texture(getWheelTexture(), rect);

        const cr = snapshot.append_cairo(rect);
        if (this._v < 1) {                           // show the brightness on the wheel
            cr.arc(g.cx, g.cy, g.r + 0.5, 0, 2 * Math.PI);
            cr.setSourceRGBA(0, 0, 0, 1 - this._v);
            cr.fill();
        }
        const a = this._h * Math.PI / 180;
        const mx = g.cx + Math.cos(a) * this._s * g.r;
        const my = g.cy - Math.sin(a) * this._s * g.r;
        cr.setLineWidth(4);
        cr.setSourceRGBA(0, 0, 0, 0.5);
        cr.arc(mx, my, 8, 0, 2 * Math.PI);
        cr.stroke();
        cr.setLineWidth(2);
        cr.setSourceRGB(1, 1, 1);
        cr.arc(mx, my, 8, 0, 2 * Math.PI);
        cr.stroke();
        cr.$dispose();
    }
});

function makeSwatch(getRgb, size) {
    const area = new Gtk.DrawingArea({
        content_width: size, content_height: size,
        halign: Gtk.Align.CENTER, valign: Gtk.Align.CENTER,
    });
    area.set_draw_func((_a, cr, w, h) => {
        const [r, g, b] = getRgb();
        cr.arc(w / 2, h / 2, Math.min(w, h) / 2 - 1, 0, 2 * Math.PI);
        cr.setSourceRGB(r / 255, g / 255, b / 255);
        cr.fillPreserve();
        cr.setLineWidth(1);
        cr.setSourceRGBA(0.5, 0.5, 0.5, 0.6);
        cr.stroke();
        cr.$dispose();
    });
    return area;
}

// ---------- color picker: wheel + brightness + R/G/B + HEX + presets ----------
class ColorPicker {
    constructor(rgb, onChange) {
        this._onChange = onChange;
        this._busy = false;
        this._rgb = [...rgb];
        [this._h, this._s, this._v] = rgbToHsv(this._rgb);

        this.widget = new Gtk.Box({
            orientation: Gtk.Orientation.VERTICAL, spacing: 12,
            margin_top: 12, margin_bottom: 12, margin_start: 12, margin_end: 12,
        });

        this._wheel = new ColorWheel();
        this._wheel.onPick = (h, s) => this._fromWheel(h, s);
        this.widget.append(this._wheel);

        const brightness = new Gtk.Box({spacing: 8});
        brightness.append(new Gtk.Label({label: T.brightness, xalign: 0}));
        this._value = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 100, 1);
        this._value.hexpand = true;
        this._value.connect('value-changed', () => this._fromValue());
        brightness.append(this._value);
        this.widget.append(brightness);

        const fields = new Gtk.Box({spacing: 6, halign: Gtk.Align.CENTER});
        this._spins = ['R', 'G', 'B'].map(name => {
            fields.append(new Gtk.Label({label: name, css_classes: ['dim-label']}));
            const spin = Gtk.SpinButton.new_with_range(0, 255, 1);
            spin.numeric = true;
            spin.width_chars = 3;
            spin.connect('value-changed', () => this._fromSpins());
            fields.append(spin);
            return spin;
        });
        fields.append(new Gtk.Label({label: 'HEX', css_classes: ['dim-label'], margin_start: 6}));
        this._hex = new Gtk.Entry({max_length: 7, width_chars: 8});
        this._hex.connect('activate', () => this._fromHex());
        const focus = new Gtk.EventControllerFocus();
        focus.connect('leave', () => this._fromHex());
        this._hex.add_controller(focus);
        fields.append(this._hex);
        this.widget.append(fields);

        const presets = new Gtk.FlowBox({
            max_children_per_line: PRESETS.length, min_children_per_line: 6,
            selection_mode: Gtk.SelectionMode.NONE, halign: Gtk.Align.CENTER,
            column_spacing: 2, row_spacing: 2,
        });
        for (const p of PRESETS) {
            const button = new Gtk.Button({
                child: makeSwatch(() => p, 20), css_classes: ['flat', 'circular'], tooltip_text: hex(p),
            });
            button.connect('clicked', () => this.setRgb(p, true));
            presets.append(button);
        }
        this.widget.append(presets);

        this._sync();
    }

    get rgb() {
        return [...this._rgb];
    }

    setRgb(rgb, emit = false) {
        this._rgb = [...rgb];
        this._takeHsvFromRgb();
        this._sync();
        if (emit)
            this._emit();
    }

    _takeHsvFromRgb() {
        const [h, s, v] = rgbToHsv(this._rgb);
        if (s > 0 && v > 0)
            this._h = h;                             // grays have no hue: keep the old one
        if (v > 0)
            this._s = s;
        this._v = v;
    }

    _fromWheel(h, s) {
        if (this._busy)
            return;
        this._h = h;
        this._s = s;
        if (this._v < 0.05)
            this._v = 1;                             // picking a hue on black: make it visible
        this._rgb = hsvToRgb(this._h, this._s, this._v);
        this._sync();
        this._emit();
    }

    _fromValue() {
        if (this._busy)
            return;
        this._v = this._value.get_value() / 100;
        this._rgb = hsvToRgb(this._h, this._s, this._v);
        this._sync();
        this._emit();
    }

    _fromSpins() {
        if (this._busy)
            return;
        this._rgb = this._spins.map(s => s.get_value_as_int());
        this._takeHsvFromRgb();
        this._sync();
        this._emit();
    }

    _fromHex() {
        if (this._busy)
            return;
        const rgb = parseColor(this._hex.text);
        if (rgb && hex(rgb) !== hex(this._rgb))
            this.setRgb(rgb, true);
        else
            this._sync();                            // put back the valid value
    }

    _sync() {
        this._busy = true;
        this._wheel.setColor(this._h, this._s, this._v);
        this._value.set_value(Math.round(this._v * 100));
        this._spins.forEach((s, i) => s.set_value(this._rgb[i]));
        this._hex.text = hex(this._rgb);
        this._busy = false;
    }

    _emit() {
        this._onChange(this.rgb);
    }
}

// ---------- rows ----------
function describe(rgb) {
    return `${hex(rgb)} · ${rgb.join(', ')}`;
}

function colorRow(title, rgb, onChange) {
    let current = [...rgb];
    const row = new Adw.ActionRow({title, subtitle: describe(current)});
    const swatch = makeSwatch(() => current, 28);
    const button = new Gtk.MenuButton({
        child: swatch, valign: Gtk.Align.CENTER, css_classes: ['flat'], tooltip_text: T.pick,
    });
    const show = c => {
        current = c;
        swatch.queue_draw();
        row.subtitle = describe(c);
    };
    const picker = new ColorPicker(current, c => {
        show(c);
        onChange(c);
    });
    const popover = new Gtk.Popover({child: picker.widget});
    button.set_popover(popover);
    row.add_suffix(button);
    row.activatable_widget = button;
    return {
        row,
        setRgb(c) {
            picker.setRgb(c);
            show([...c]);
        },
    };
}

// Title and value on one line, the slider full-width below: a slider as a row suffix
// squeezes the title on narrow windows.
function blinkRow(value, onChange) {
    const row = new Adw.PreferencesRow({title: T.blink, activatable: false});
    const box = new Gtk.Box({
        orientation: Gtk.Orientation.VERTICAL, spacing: 2,
        margin_top: 10, margin_bottom: 6, margin_start: 12, margin_end: 12,
    });
    const header = new Gtk.Box({spacing: 12});
    header.append(new Gtk.Label({label: T.blink, xalign: 0, hexpand: true, wrap: true}));
    const valueLabel = new Gtk.Label({xalign: 1, css_classes: ['dim-label', 'numeric']});
    header.append(valueLabel);
    box.append(header);

    const scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, MAX_HZ, 0.1);
    scale.round_digits = 1;
    scale.draw_value = false;
    scale.hexpand = true;
    for (let m = 0; m <= MAX_HZ; m++)
        scale.add_mark(m, Gtk.PositionType.BOTTOM, String(m));
    box.append(scale);
    row.set_child(box);

    const show = v => {
        valueLabel.label = v < 0.05 ? T.steady : `${fmtNumber(v)} ${T.perSecond}`;
    };
    scale.set_value(value);           // before connecting: opening the window saves nothing
    show(value);
    scale.connect('value-changed', () => {
        const v = Math.round(scale.get_value() * 10) / 10;
        show(v);
        onChange(v);
    });
    return {row, set: v => scale.set_value(v)};
}

function effectGroup(store, fx) {
    const group = new Adw.PreferencesGroup({title: T[fx], description: T[`${fx}Hint`]});
    const reset = new Gtk.Button({label: T.reset, valign: Gtk.Align.CENTER, css_classes: ['flat']});
    group.set_header_suffix(reset);

    const fans = colorRow(T.fans, store.get(fx, 'fans'), c => store.set(fx, 'fans', c));
    const gpu = colorRow(T.gpu, store.get(fx, 'gpu'), c => store.set(fx, 'gpu', c));
    const smooth = new Adw.SwitchRow({
        title: T.smooth, subtitle: T.smoothHint, active: store.get(fx, 'gpu_smooth'),
    });
    const blink = blinkRow(store.get(fx, 'gpu_blink_hz'), v => {
        store.set(fx, 'gpu_blink_hz', v);
        smooth.sensitive = v > 0;
    });
    smooth.sensitive = store.get(fx, 'gpu_blink_hz') > 0;
    smooth.connect('notify::active', () => store.set(fx, 'gpu_smooth', smooth.active));

    for (const r of [fans.row, gpu.row, blink.row, smooth])
        group.add(r);

    reset.connect('clicked', () => {
        const d = DEFAULTS[fx];
        store.reset(fx);
        fans.setRgb(d.fans);
        gpu.setRgb(d.gpu);
        blink.set(d.gpu_blink_hz);
        smooth.active = d.gpu_smooth;
    });
    return group;
}

function viewGroup(store) {
    const group = new Adw.PreferencesGroup({title: T.viewGroup});
    const row = new Adw.ComboRow({
        title: T.view, subtitle: T.viewHint, subtitle_lines: 0,
        model: Gtk.StringList.new([T.viewSide, T.viewFront]),
        selected: Math.max(0, VIEWS.indexOf(store.get('general', 'view'))),
    });
    row.connect('notify::selected', () => store.set('general', 'view', VIEWS[row.selected] ?? 'side'));
    group.add(row);
    return group;
}

function equalizerGroup() {
    const group = new Adw.PreferencesGroup({title: T.eq, description: T.eqHint});
    group.add(new Adw.ActionRow({title: T.gpu, subtitle: T.eqGpu, subtitle_lines: 0}));
    return group;
}

// Which effect is running: `airglow-fx current` prints stars | cats | eq | off.
// Shown in the window so it is clear which group changes the case right now.
function readCurrentEffect(cancellable, callback) {
    const script = GLib.build_filenamev([GLib.get_home_dir(), '.local', 'bin', 'airglow-fx']);
    let proc;
    try {
        proc = Gio.Subprocess.new([script, 'current'],
            Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE);
    } catch (e) {
        callback(null);                              // airglow-fx not installed
        return;
    }
    proc.communicate_utf8_async(null, cancellable, (p, res) => {
        try {
            const [, stdout] = p.communicate_utf8_finish(res);
            callback(stdout?.trim() || null);
        } catch (e) {
            if (!e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                callback(null);
        }
    });
}

export default class AirglowPreferences extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const store = new Store();
        window.set_default_size(620, 860);
        window.search_enabled = false;

        const page = new Adw.PreferencesPage({
            title: T.page, icon_name: 'preferences-color-symbolic', description: T.pageHint,
        });
        const groups = {
            stars: effectGroup(store, 'stars'),
            cats: effectGroup(store, 'cats'),
            eq: equalizerGroup(),
        };
        page.add(viewGroup(store));
        for (const g of Object.values(groups))
            page.add(g);
        window.add(page);

        // Mark the running effect, and re-check every 2 s while the window is open.
        const cancellable = new Gio.Cancellable();
        let shown;
        const refresh = () => readCurrentEffect(cancellable, fx => {
            if (fx === shown)
                return;
            shown = fx;
            for (const [id, g] of Object.entries(groups))
                g.title = id === fx ? `${T[id]} · ${T.onCase}` : T[id];
            const now = fx in groups ? `${T.nowOn}: ${T[fx]}.` : fx === 'off' ? `${T.nowOff}.` : '';
            page.description = now ? `${T.pageHint} ${now}` : T.pageHint;
        });
        refresh();
        let timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 2, () => {
            refresh();
            return GLib.SOURCE_CONTINUE;
        });

        window.connect('close-request', () => {
            if (timer)
                GLib.source_remove(timer);
            timer = 0;
            cancellable.cancel();
            store.flush();
            return false;
        });
    }
}
