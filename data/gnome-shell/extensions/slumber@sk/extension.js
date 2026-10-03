// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Muhammad Siam

// Quick Settings tile for Slumber. A thin front end over `slumber-ctl`:
// toggling the tile runs `slumber-ctl keep-awake` / `allow-sleep`, and the
// state is read straight from the file slumber-ctl keeps in $XDG_RUNTIME_DIR.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';

const ICON_AWAKE = 'weather-clear-symbolic';
const ICON_SLEEPY = 'weather-clear-night-symbolic';
const SYNC_SECONDS = 10; // also notices expiry and changes made from a terminal

const DURATIONS = [
    ['30 minutes', '30m'],
    ['1 hour', '1h'],
    ['2 hours', '2h'],
    ['4 hours', '4h'],
    ['Until I turn it off', 'forever'],
];

function ctlPath() {
    return GLib.find_program_in_path('slumber-ctl') ?? '/usr/bin/slumber-ctl';
}

function stateFile() {
    const dir = GLib.getenv('SLUMBER_STATE_DIR') ??
        GLib.build_filenamev([GLib.get_user_runtime_dir(), 'slumber']);
    return GLib.build_filenamev([dir, 'keep-awake']);
}

// -> {awake: bool, until: epoch seconds | null}
function readState() {
    try {
        const [ok, bytes] = GLib.file_get_contents(stateFile());
        if (!ok)
            return {awake: false, until: null};
        const text = new TextDecoder().decode(bytes).trim();
        if (text === 'forever')
            return {awake: true, until: null};
        const until = parseInt(text, 10);
        if (until > Date.now() / 1000)
            return {awake: true, until};
    } catch (e) {
        // no state file: normal behaviour
    }
    return {awake: false, until: null};
}

function formatUntil(until) {
    if (until === null)
        return 'Until turned off';
    const mins = Math.max(1, Math.ceil((until - Date.now() / 1000) / 60));
    const h = Math.floor(mins / 60);
    const m = mins % 60;
    if (h === 0)
        return `${m}m left`;
    return m === 0 ? `${h}h left` : `${h}h ${m}m left`;
}

function runCtl(args, onError) {
    try {
        const proc = Gio.Subprocess.new([ctlPath(), ...args],
            Gio.SubprocessFlags.STDERR_PIPE);
        proc.communicate_utf8_async(null, null, (p, res) => {
            try {
                const [, , stderr] = p.communicate_utf8_finish(res);
                if (!p.get_successful())
                    onError?.(stderr?.trim() || 'slumber-ctl failed');
            } catch (e) {
                onError?.(e.message);
            }
        });
    } catch (e) {
        onError?.(e.message);
    }
}

const SlumberToggle = GObject.registerClass(
class SlumberToggle extends QuickSettings.QuickMenuToggle {
    _init(onChange) {
        super._init({
            title: 'Keep Awake',
            iconName: ICON_SLEEPY,
            toggleMode: false,
        });
        this._onChange = onChange;

        this.menu.setHeader(ICON_AWAKE, 'Keep Awake',
            'Skip sleep after locking and block lid-close sleep');

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem('Stay awake for'));
        for (const [label, arg] of DURATIONS) {
            this.menu.addAction(label, () => {
                this._run(['keep-awake', arg]);
                this.menu.close();
            });
        }

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._stopItem = this.menu.addAction('Allow sleep again', () => {
            this._run(['allow-sleep']);
            this.menu.close();
        });
        this._hibernateItem = this.menu.addAction('Hibernate now', () => {
            this.menu.close();
            Main.panel.statusArea.quickSettings.menu.close();
            this._run(['hibernate']);
        });

        this.connect('clicked', () => {
            this._run(this.checked ? ['allow-sleep'] : ['keep-awake', 'forever']);
        });
        this.menu.connect('open-state-changed', (_menu, open) => {
            if (open)
                this.sync();
        });
        this.sync();
    }

    _run(args) {
        runCtl(args, msg => Main.notifyError('Slumber', msg));
        // slumber-ctl writes its state synchronously before returning; give it
        // a moment, then refresh.
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 300, () => {
            this._onChange();
            return GLib.SOURCE_REMOVE;
        });
    }

    sync() {
        const {awake, until} = readState();
        this.set({
            checked: awake,
            iconName: awake ? ICON_AWAKE : ICON_SLEEPY,
            subtitle: awake ? formatUntil(until) : 'Sleeps after lock',
        });
        this._stopItem.visible = awake;
    }
});

const SlumberIndicator = GObject.registerClass(
class SlumberIndicator extends QuickSettings.SystemIndicator {
    _init() {
        super._init();

        // A small sun in the panel only while keep-awake is on.
        this._indicator = this._addIndicator();
        this._indicator.iconName = ICON_AWAKE;

        this._toggle = new SlumberToggle(() => this.sync());
        this.quickSettingsItems.push(this._toggle);

        this._timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, SYNC_SECONDS, () => {
            this.sync();
            return GLib.SOURCE_CONTINUE;
        });
        this.sync();
    }

    sync() {
        this._toggle.sync();
        this._indicator.visible = this._toggle.checked;
    }

    destroy() {
        if (this._timer) {
            GLib.Source.remove(this._timer);
            this._timer = null;
        }
        this.quickSettingsItems.forEach(item => item.destroy());
        super.destroy();
    }
});

export default class SlumberExtension extends Extension {
    enable() {
        this._indicator = new SlumberIndicator();
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicator);
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}
