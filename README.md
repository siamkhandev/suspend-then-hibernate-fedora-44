# Windows-Level Suspend-then-Hibernate for Fedora 44

This project provides automated setup and rollback scripts for enabling Windows-style **Suspend-then-Hibernate** on Fedora 44 (Workstation Edition) with Btrfs, LUKS encryption, and systemd.

## How it Works
1. **Sleep Phase (Fast Resume)**: When you close the lid or trigger sleep on battery, the laptop suspends to RAM immediately.
2. **Timer / Battery Alarm**: The hardware RTC wakes the laptop after 120 minutes (or if the battery drains low), writes your RAM state into an encrypted Btrfs swapfile on the SSD, and powers off completely (`HibernateMode=shutdown`). The default ACPI S4 "platform" mode can keep USB/wake circuitry powered and was measured draining ~0.7 W (~1.7%/hour) while "hibernated".
3. **AC Power Bypass**: If plugged into the charger, the laptop stays suspended indefinitely (no unnecessary hibernation).
4. **Suspend Button Too**: GNOME's *Suspend* menu item and `systemctl suspend` bypass logind's lid/key settings, so the script overrides `systemd-suspend.service` to suspend-then-hibernate as well.
5. **Lock → Sleep (optional)**: On battery, locking the screen (Super+L) suspends after 30 seconds idle. If an external keyboard/mouse wakes it and nobody unlocks, it goes back to sleep after another 30 seconds. On AC power, locking never sleeps (downloads/builds keep running).
6. **Sleep Battery Report (optional)**: A systemd sleep hook records battery level before/after every sleep. When you unlock after waking, a notification shows how long it slept, whether it hibernated, and how much battery it used. Run `sleep-report` for the full history.
7. **USB Can't Wake It (optional)**: `usb-wake-guard.service` turns off wakeup for external USB devices and for the USB controllers (xHCI, Thunderbolt/USB4) before every sleep and restores it on resume, so a bumped mouse or keyboard, or a dock, can't wake the laptop. Only the built-in PS/2 or I2C keyboard and trackpad, power button and lid still can. Bluetooth mice (the radio is on USB) can't wake it either. If your built-in keyboard or trackpad is a USB device, use `--no-usb-guard`.
8. **Swap Sized to Your RAM**: The swapfile is sized automatically to installed RAM (rounded up) + 1GB, e.g. 16GB RAM → 17GB, 32GB RAM → 33GB. If an existing swapfile is too small (e.g. after a RAM upgrade), re-running `slumber-setup enable` recreates it and updates the resume offset in every boot entry. Override with `--swap-size=N`.
9. **Zero Performance Lag**: Fedora's default `zram0` (in-memory swap) remains at priority 100, while the SSD swapfile is set to priority 10. The SSD is only used for hibernation, never for normal daily multitasking.

---

## Requirements
- **Fedora** (tested on 44 Workstation) with **Btrfs** root on **LUKS** encryption (Fedora's default encrypted install). The script checks `/etc/os-release` and refuses to run on other distributions or on Fedora Atomic (Silverblue, Kinoite, ...), whose read-only `/usr` and rpm-ostree kernel args it can't configure. Other Fedora versions get a warning.
- **Secure Boot disabled.** On Fedora, Secure Boot turns on kernel lockdown, which blocks hibernation. The script checks this and stops with a message if hibernation isn't allowed.
- Free disk space for the swapfile (RAM + 1GB) plus 4GB headroom.
- **GNOME** for `lock-sleep` and the unlock notification (they use GNOME's lock-screen and idle APIs). The script detects the desktop and, on anything else (KDE, etc.), skips them automatically; suspend-then-hibernate itself works on any desktop.
- The sleep battery log reads `energy_now`, or `charge_now` × `voltage_now` on batteries that only report charge (e.g. many Dells). On desktops without a battery it records nothing.

---

## Files

- `bin/slumber-setup`: `enable` creates the swapfile, configures resume offsets, updates dracut/grub and sets systemd sleep rules; `disable` completely reverts it and returns the system to default Fedora settings; `status` prints the current state.
- `bin/slumber-status`: reports the current state as text or JSON (`--json`). Needs no root; the GUI reads this.
- `bin/slumber-ctl`: everyday controls, no root: `keep-awake [30m|2h|forever]` stops `lock-sleep` sleeping after a lock (so a long task keeps running), `allow-sleep` undoes it, `hibernate` hibernates immediately, `status [--json]` shows the mode. While keep-awake is on it also holds a logind inhibitor lock, so closing the lid, the Suspend button and idle suspend are blocked too. It resets at logout/reboot, and `hibernate` overrides it.
- `bin/` helpers: `lock-sleep`, `sleep-notify`, `sleep-report`, `usb-wake-guard`.
- `data/`: systemd units (`systemd/system`, `systemd/user`) and the sleep hook (`system-sleep/sleep-battery`, logs to `/var/log/sleep-battery.log`).
- `data/gnome-shell/extensions/slumber@sk/`: GNOME Shell extension (Shell 50) that adds a **Keep Awake** tile to the Quick Settings panel: click to toggle, arrow for 30m/1h/2h/4h/until-off, plus **Hibernate now**. It is a front end over `slumber-ctl`. After installing, log out and in once, then run `gnome-extensions enable slumber@sk`.
- `Makefile`: `sudo make install` copies everything to `/usr` (use `DESTDIR`/`PREFIX` when packaging).

The helpers are only installed by `make install` (or the package); `slumber-setup enable` switches them on or off. What is enabled is recorded in `/etc/slumber/slumber.conf`, and the sleep hook stays inactive until the sleep report is enabled there.

---

## Usage

### 1. Install, then enable (or adjust delay)
```bash
sudo make install
```

Run interactively (you will be prompted to enter the desired delay in minutes):
```bash
sudo slumber-setup enable
```

Or pass the delay directly as an argument (e.g. 60 minutes, 90 minutes, 180 minutes):
```bash
sudo slumber-setup enable 60
```

Set the swapfile size yourself (in GB) instead of sizing it to RAM:
```bash
sudo slumber-setup enable 30 --swap-size=40
```

Skip the optional helpers with `--no-lock-sleep`, `--no-sleep-report` and/or `--no-usb-guard` (re-running with different flags switches helpers on or off):
```bash
sudo slumber-setup enable 30 --no-lock-sleep
```

Check the current state:
```bash
slumber-status          # or: slumber-status --json
```

### 2. Test
Test direct hibernation:
```bash
sudo systemctl hibernate
```
Test two-stage suspend-then-hibernate:
```bash
sudo systemctl suspend-then-hibernate
```
See how much battery each sleep used:
```bash
sleep-report
```

### 3. Revert (if ever needed)
```bash
sudo slumber-setup disable
```

---

## Tips
- **Lenovo ThinkPads**: disable *Config → USB → Always On USB* in the BIOS (F1 at boot) to minimise drain while hibernated.
- Closing the lid within ~30s of a wake is ignored by logind (`HoldoffTimeoutSec`), so the laptop may stay awake until the idle timer fires. Wait a few seconds after waking before closing the lid again.

---

## Important Rules for Dual-Boot (Windows 11)
- Turn off **Fast Startup** in Windows Control Panel.
- **Never boot into Windows while Linux is hibernated** if you share data partitions (e.g. NTFS), as this can corrupt filesystem caches. Always resume Linux first before booting into Windows.
