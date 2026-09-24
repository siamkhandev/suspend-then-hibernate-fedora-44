# Windows-Level Suspend-then-Hibernate for Fedora 44

This project provides automated setup and rollback scripts for enabling Windows-style **Suspend-then-Hibernate** on Fedora 44 (Workstation Edition) with Btrfs, LUKS encryption, and systemd.

## How it Works
1. **Sleep Phase (Fast Resume)**: When you close the lid or trigger sleep on battery, the laptop suspends to RAM immediately.
2. **Timer / Battery Alarm**: The hardware RTC wakes the laptop after 120 minutes (or if the battery drains low), writes your RAM state into an encrypted 24GB Btrfs swapfile on the SSD, and powers off completely (`HibernateMode=shutdown`). The default ACPI S4 "platform" mode can keep USB/wake circuitry powered and was measured draining ~0.7 W (~1.7%/hour) while "hibernated".
3. **AC Power Bypass**: If plugged into the charger, the laptop stays suspended indefinitely (no unnecessary hibernation).
4. **Suspend Button Too**: GNOME's *Suspend* menu item and `systemctl suspend` bypass logind's lid/key settings, so the script overrides `systemd-suspend.service` to suspend-then-hibernate as well.
5. **Lock → Sleep (optional)**: On battery, locking the screen (Super+L) suspends after 30 seconds idle. If an external keyboard/mouse wakes it and nobody unlocks, it goes back to sleep after another 30 seconds. On AC power, locking never sleeps (downloads/builds keep running).
6. **Sleep Battery Report (optional)**: A systemd sleep hook records battery level before/after every sleep. When you unlock after waking, a notification shows how long it slept, whether it hibernated, and how much battery it used. Run `sleep-report` for the full history.
7. **Zero Performance Lag**: Fedora's default `zram0` (in-memory swap) remains at priority 100, while the SSD swapfile is set to priority 10. The SSD is only used for hibernation, never for normal daily multitasking.

---

## Files

- `enable-suspend-then-hibernate.sh`: Creates the swapfile, configures resume offsets, updates dracut/grub, and sets systemd sleep rules.
- `disable-suspend-then-hibernate.sh`: Completely reverts all changes (including the helpers below) and returns the system to default Fedora settings.
- `files/`: Helpers installed by the enable script:
  - `lock-sleep`, `lock-sleep.service` → `/usr/local/bin/`, `/etc/systemd/user/` (enabled globally)
  - `sleep-notify`, `sleep-notify.service` → `/usr/local/bin/`, `/etc/systemd/user/` (enabled globally)
  - `sleep-report` → `/usr/local/bin/`
  - `sleep-battery-hook` → `/usr/lib/systemd/system-sleep/sleep-battery` (logs to `/var/log/sleep-battery.log`)

---

## Usage

### 1. Enable (or Adjust Delay)
Run interactively (you will be prompted to enter the desired delay in minutes):
```bash
sudo bash enable-suspend-then-hibernate.sh
```

Or pass the delay directly as an argument (e.g. 60 minutes, 90 minutes, 180 minutes):
```bash
sudo bash enable-suspend-then-hibernate.sh 60
```

Skip the optional helpers with `--no-lock-sleep` and/or `--no-sleep-report`:
```bash
sudo bash enable-suspend-then-hibernate.sh 30 --no-lock-sleep
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
sudo bash disable-suspend-then-hibernate.sh
```

---

## Tips
- **Lenovo ThinkPads**: disable *Config → USB → Always On USB* in the BIOS (F1 at boot) to minimise drain while hibernated.
- Closing the lid within ~30s of a wake is ignored by logind (`HoldoffTimeoutSec`), so the laptop may stay awake until the idle timer fires. Wait a few seconds after waking before closing the lid again.

---

## Important Rules for Dual-Boot (Windows 11)
- Turn off **Fast Startup** in Windows Control Panel.
- **Never boot into Windows while Linux is hibernated** if you share data partitions (e.g. NTFS), as this can corrupt filesystem caches. Always resume Linux first before booting into Windows.
