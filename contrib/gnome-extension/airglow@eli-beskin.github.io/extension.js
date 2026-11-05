// Airglow Lighting — a Quick Settings toggle for the stopgap lighting effects.
//
// What it does
//   • the tile turns the lighting on (last used effect) or off;
//   • the arrow opens a menu: Stars / Cats / Equalizer / Turn off.
//
// How it works
//   • Switching runs ~/.local/bin/airglow-fx (contrib/stopgap), so the logic lives
//     in one script and behaves the same from a terminal.
//   • State is read from the systemd user manager over D-Bus (ActiveState/SubState
//     of airglow-{stars,cats,eq}.service), so the tile also follows changes made
//     from a terminal or a crashed effect.
//   • Later the same tile can talk to airglowd (io.github.eli_beskin.Airglow)
//     instead of systemd.

import GObject from 'gi://GObject';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {QuickMenuToggle, SystemIndicator} from 'resource:///org/gnome/shell/ui/quickSettings.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const EFFECTS = ['stars', 'cats', 'eq'];
const RUNNING = new Set(['active', 'activating', 'reloading']);

const SYSTEMD = 'org.freedesktop.systemd1';
const SYSTEMD_PATH = '/org/freedesktop/systemd1';
const MANAGER_IFACE = 'org.freedesktop.systemd1.Manager';
const UNIT_IFACE = 'org.freedesktop.systemd1.Unit';
const PROPS_IFACE = 'org.freedesktop.DBus.Properties';

// ---------- tiny built-in translation: Russian or English ----------
const STRINGS = {
    en: {
        title: 'Lighting',
        stars: 'Stars',
        cats: 'Cats',
        eq: 'Equalizer',
        off: 'Off',
        turnOff: 'Turn off',
        starting: 'starting…',
        restarting: 'restarting — is OpenRGB running?',
        failed: 'Error',
        cmdFailed: 'Airglow: command failed',
        missing: 'Not found: ~/.local/bin/airglow-fx. Install the stopgap effects first (contrib/stopgap).',
    },
    ru: {
        title: 'Подсветка',
        stars: 'Звёзды',
        cats: 'Котики',
        eq: 'Эквалайзер',
        off: 'Выкл',
        turnOff: 'Выключить',
        starting: 'запуск…',
        restarting: 'перезапуск — OpenRGB запущен?',
        failed: 'Ошибка',
        cmdFailed: 'Airglow: команда не выполнилась',
        missing: 'Не найден ~/.local/bin/airglow-fx. Сначала установи stopgap-эффекты (contrib/stopgap).',
    },
};
const T = GLib.get_language_names()[0].startsWith('ru') ? STRINGS.ru : STRINGS.en;

function isCancelled(e) {
    return e instanceof GLib.Error && e.matches(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED);
}

const AirglowToggle = GObject.registerClass(
class AirglowToggle extends QuickMenuToggle {
    _init(extension) {
        super._init({
            title: T.title,
            subtitle: T.off,
            menuButtonAccessibleName: T.title,
        });

        this._path = extension.path;
        this._cancellable = new Gio.Cancellable();
        this._destroyed = false;
        this._units = new Map();   // effect id -> {path, active, sub}
        this._paths = new Map();   // D-Bus object path -> effect id

        this._mainIcon = this._icon('airglow-symbolic');
        this.gicon = this._mainIcon;
        this.menu.setHeader(this._mainIcon, T.title, T.off);

        // ---- menu ----
        this._items = new Map();
        for (const fx of EFFECTS) {
            const item = new PopupMenu.PopupImageMenuItem(T[fx], this._icon(`airglow-${fx}-symbolic`));
            item.connect('activate', () => this._run(fx));
            this.menu.addMenuItem(item);
            this._items.set(fx, item);
        }
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._offItem = this.menu.addAction(T.turnOff, () => this._run('off'));

        // ---- tile click: on <-> off ----
        this.connect('clicked', () => {
            const wasOn = this.checked;
            this.checked = !wasOn;              // instant feedback; D-Bus confirms
            this._run(wasOn ? 'off' : 'on');
        });

        // Re-read the state whenever the menu opens, just in case.
        this.menu.connect('open-state-changed', (_menu, open) => {
            if (open)
                this._refresh();
        });

        this.connect('destroy', () => this._onDestroy());

        this._initSystemd();
        this._sync();
    }

    _icon(name) {
        return Gio.FileIcon.new(Gio.File.new_for_path(`${this._path}/icons/${name}.svg`));
    }

    // ---------- systemd over D-Bus ----------

    _initSystemd() {
        const bus = Gio.DBus.session;

        // systemd only sends unit signals once some client has subscribed.
        // We do not unsubscribe on disable: the connection is shared by the whole
        // shell, and systemd drops the subscription itself when the shell exits.
        bus.call(SYSTEMD, SYSTEMD_PATH, MANAGER_IFACE, 'Subscribe',
            null, null, Gio.DBusCallFlags.NONE, -1, this._cancellable,
            (conn, res) => {
                try {
                    conn.call_finish(res);
                } catch (e) {
                    // "already subscribed" is fine
                }
            });

        // One subscription for PropertiesChanged of any unit; we filter by path.
        this._signalId = bus.signal_subscribe(SYSTEMD, PROPS_IFACE, 'PropertiesChanged',
            null, UNIT_IFACE, Gio.DBusSignalFlags.NONE,
            (_conn, _sender, path, _iface, _signal, params) => this._onUnitChanged(path, params));

        for (const fx of EFFECTS) {
            bus.call(SYSTEMD, SYSTEMD_PATH, MANAGER_IFACE, 'LoadUnit',
                new GLib.Variant('(s)', [`airglow-${fx}.service`]),
                new GLib.VariantType('(o)'), Gio.DBusCallFlags.NONE, -1, this._cancellable,
                (conn, res) => {
                    let path;
                    try {
                        [path] = conn.call_finish(res).deepUnpack();
                    } catch (e) {
                        if (!isCancelled(e))
                            console.warn(`Airglow: LoadUnit airglow-${fx}.service: ${e.message}`);
                        return;
                    }
                    this._units.set(fx, {path, active: 'inactive', sub: 'dead'});
                    this._paths.set(path, fx);
                    this._readUnit(fx);
                });
        }
    }

    _readUnit(fx) {
        const unit = this._units.get(fx);
        if (!unit)
            return;
        Gio.DBus.session.call(SYSTEMD, unit.path, PROPS_IFACE, 'GetAll',
            new GLib.Variant('(s)', [UNIT_IFACE]),
            new GLib.VariantType('(a{sv})'), Gio.DBusCallFlags.NONE, -1, this._cancellable,
            (conn, res) => {
                let props;
                try {
                    [props] = conn.call_finish(res).recursiveUnpack();
                } catch (e) {
                    if (!isCancelled(e))
                        console.warn(`Airglow: reading airglow-${fx}.service: ${e.message}`);
                    return;
                }
                unit.active = props.ActiveState ?? unit.active;
                unit.sub = props.SubState ?? unit.sub;
                this._sync();
            });
    }

    _refresh() {
        for (const fx of this._units.keys())
            this._readUnit(fx);
    }

    _onUnitChanged(path, params) {
        const fx = this._paths.get(path);
        if (!fx || this._destroyed)
            return;
        const unit = this._units.get(fx);
        const changed = params.get_child_value(1);
        const active = changed.lookup_value('ActiveState', null);
        const sub = changed.lookup_value('SubState', null);
        if (active)
            unit.active = active.unpack();
        if (sub)
            unit.sub = sub.unpack();
        if (active || sub)
            this._sync();
        else
            this._readUnit(fx);   // value only invalidated: ask for it
    }

    // ---------- UI ----------

    _sync() {
        if (this._destroyed)
            return;

        let running = null, failed = null;
        for (const fx of EFFECTS) {
            const unit = this._units.get(fx);
            if (!unit)
                continue;
            if (!running && RUNNING.has(unit.active))
                running = fx;
            else if (!failed && unit.active === 'failed')
                failed = fx;
        }

        let subtitle = T.off;
        if (running) {
            const unit = this._units.get(running);
            subtitle = T[running];
            if (unit.active === 'activating')
                subtitle += ` · ${unit.sub === 'auto-restart' ? T.restarting : T.starting}`;
        } else if (failed) {
            subtitle = `${T.failed}: ${T[failed]}`;
        }

        this.checked = running !== null;
        this.subtitle = subtitle;
        this.menu.setHeader(this._mainIcon, T.title, subtitle);

        for (const [fx, item] of this._items) {
            item.setOrnament(fx === running
                ? PopupMenu.Ornament.CHECK
                : PopupMenu.Ornament.NONE);
        }
        this._offItem.visible = running !== null;
    }

    // ---------- running airglow-fx ----------

    _run(arg) {
        const script = GLib.build_filenamev([GLib.get_home_dir(), '.local', 'bin', 'airglow-fx']);
        if (!GLib.file_test(script, GLib.FileTest.IS_EXECUTABLE)) {
            Main.notifyError(T.title, T.missing);
            this._sync();
            return;
        }

        let proc;
        try {
            proc = Gio.Subprocess.new([script, arg],
                Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_PIPE);
        } catch (e) {
            Main.notifyError(T.cmdFailed, e.message);
            this._sync();
            return;
        }

        proc.communicate_utf8_async(null, this._cancellable, (p, res) => {
            try {
                const [, , stderr] = p.communicate_utf8_finish(res);
                if (!p.get_successful())
                    Main.notifyError(T.cmdFailed, stderr?.trim() || `airglow-fx ${arg}`);
            } catch (e) {
                if (isCancelled(e))
                    return;
                console.warn(`Airglow: airglow-fx ${arg}: ${e.message}`);
            }
            if (!this._destroyed)
                this._refresh();
        });
    }

    _onDestroy() {
        this._destroyed = true;
        this._cancellable.cancel();
        if (this._signalId) {
            Gio.DBus.session.signal_unsubscribe(this._signalId);
            this._signalId = 0;
        }
        // The menu lives in the Quick Settings overlay, not inside the tile,
        // so it is not destroyed together with the tile.
        this.menu?.destroy();
    }
});

const AirglowIndicator = GObject.registerClass(
class AirglowIndicator extends SystemIndicator {
    _init(extension) {
        super._init();
        this.quickSettingsItems.push(new AirglowToggle(extension));
    }
});

export default class AirglowExtension extends Extension {
    enable() {
        this._indicator = new AirglowIndicator(this);
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicator);
    }

    disable() {
        this._indicator.quickSettingsItems.forEach(item => item.destroy());
        this._indicator.destroy();
        this._indicator = null;
    }
}
