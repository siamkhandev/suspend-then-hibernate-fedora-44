# Windows-Level Suspend-then-Hibernate for Fedora 44

This project provides automated setup and rollback scripts for enabling Windows-style **Suspend-then-Hibernate** on Fedora 44 (Workstation Edition) with Btrfs, LUKS encryption, and systemd.

## How it Works
1. **Sleep Phase (Fast Resume)**: When you close the lid or trigger sleep on battery, the laptop suspends to RAM immediately.
2. **Timer / Battery Alarm**: The hardware RTC wakes the laptop after 120 minutes (or if the battery drains low), writes your RAM state into an encrypted 24GB Btrfs swapfile on the SSD, and turns off completely (0% battery drain).
3. **AC Power Bypass**: If plugged into the charger, the laptop stays suspended indefinitely (no unnecessary hibernation).
4. **Zero Performance Lag**: Fedora's default `zram0` (in-memory swap) remains at priority 100, while the SSD swapfile is set to priority 10. The SSD is only used for hibernation, never for normal daily multitasking.

---

## Files

- `enable-suspend-then-hibernate.sh`: Creates the swapfile, configures resume offsets, updates dracut/grub, and sets systemd sleep rules.
- `disable-suspend-then-hibernate.sh`: Completely reverts all changes and returns the system to default Fedora settings.

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

### 2. Test
Test direct hibernation:
```bash
sudo systemctl hibernate
```
Test two-stage suspend-then-hibernate:
```bash
sudo systemctl suspend-then-hibernate
```

### 3. Revert (if ever needed)
```bash
sudo bash disable-suspend-then-hibernate.sh
```

---

## Important Rules for Dual-Boot (Windows 11)
- Turn off **Fast Startup** in Windows Control Panel.
- **Never boot into Windows while Linux is hibernated** if you share data partitions (e.g. NTFS), as this can corrupt filesystem caches. Always resume Linux first before booting into Windows.
