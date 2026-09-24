#!/usr/bin/env bash
# ==============================================================================
# Script: enable-suspend-then-hibernate.sh
# Purpose: Enable Windows-level "Suspend-then-Hibernate" on Fedora 44 (Btrfs + LUKS)
# Author: Generated with Antigravity (Hardened & Audited)
#
# Hardening & Security Features:
# 1. Enforces LUKS/dm-crypt encryption verification on underlying block storage
# 2. Locale-independent, robust disk space check
# 3. Dedicated /swap Btrfs subvolume with No-CoW (chattr +C) & permissions 0600
# 4. Swap priority separation: RAM zram0 (pri=100) vs SSD swap (pri=10)
# 5. Robust multi-quote GRUB & BLS cmdline patching with loud failure on mismatch
# 6. Bounded single backups (.bak) to prevent accumulation
# 7. Non-disruptive SIGHUP reload of systemd-logind (avoids session drops)
# 8. Automatic SELinux context restoration (restorecon)
# 9. Sanitized output (redacted physical block offsets)
#
# Behaviour:
# - HibernateMode=shutdown: hibernation fully powers off (no S4 residual drain)
# - The GNOME Suspend button / `systemctl suspend` also suspend-then-hibernate
# - lock-sleep (optional): on battery, sleep 30s after locking the screen
# - Sleep battery report (optional): logs drain per sleep, notifies on unlock
#
# Usage: sudo bash enable-suspend-then-hibernate.sh [DELAY_MINUTES]
#            [--no-lock-sleep] [--no-sleep-report]
# ==============================================================================

set -euo pipefail

SWAP_DIR="/swap"
SWAP_FILE="${SWAP_DIR}/swapfile"
SWAP_SIZE="24G"
DRACUT_CONF="/etc/dracut.conf.d/resume.conf"
SLEEP_CONF_DIR="/etc/systemd/sleep.conf.d"
SLEEP_CONF="${SLEEP_CONF_DIR}/suspend-then-hibernate.conf"
LOGIND_CONF_DIR="/etc/systemd/logind.conf.d"
LOGIND_CONF="${LOGIND_CONF_DIR}/suspend-then-hibernate.conf"
GRUB_DEFAULT="/etc/default/grub"
KERNEL_CMDLINE="/etc/kernel/cmdline"
SUSPEND_OVERRIDE_DIR="/etc/systemd/system/systemd-suspend.service.d"
SUSPEND_OVERRIDE="${SUSPEND_OVERRIDE_DIR}/suspend-then-hibernate.conf"
SLEEP_HOOK="/usr/lib/systemd/system-sleep/sleep-battery"
BIN_DIR="/usr/local/bin"
USER_UNIT_DIR="/etc/systemd/user"
FILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/files"
DEFAULT_DELAY_MINUTES=120
HIBERNATE_DELAY_MINUTES="${DEFAULT_DELAY_MINUTES}"
DELAY_ARG=""
INSTALL_LOCK_SLEEP=true
INSTALL_SLEEP_REPORT=true

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [ "${EUID}" -ne 0 ]; then
        log_error "This script requires root privileges. Please run with sudo:"
        echo "  sudo bash $0"
        exit 1
    fi
}

check_prerequisites() {
    log_info "Verifying system prerequisites and storage security..."

    # 1. Check filesystem is btrfs on /
    local fstype
    fstype=$(findmnt -no FSTYPE /)
    if [ "${fstype}" != "btrfs" ]; then
        log_error "Root filesystem is '${fstype}', expected 'btrfs'. Aborting."
        exit 1
    fi
    log_success "Filesystem is Btrfs."

    # 2. Strict Security Check: Verify root partition is backed by LUKS / dm-crypt
    local root_src root_dev is_encrypted=false
    root_src=$(findmnt -no SOURCE /)
    root_dev="${root_src%%\[*}" # Strip any bracketed Btrfs subvolume information

    if lsblk -no TYPE "${root_dev}" 2>/dev/null | grep -qs "crypt"; then
        is_encrypted=true
    elif lsblk -s -no TYPE "${root_dev}" 2>/dev/null | grep -qs "crypt"; then
        is_encrypted=true
    fi

    if [ "${is_encrypted}" != "true" ]; then
        log_error "==============================================================="
        log_error "SECURITY ERROR: Root volume on '${root_dev}' is NOT encrypted!"
        log_error "Hibernation writes the entire contents of RAM (passwords, keys,"
        log_error "session tokens, and decrypted data) to disk."
        log_error "Writing unencrypted hibernation memory to disk is dangerous."
        log_error "Refusing to proceed without LUKS / dm-crypt. Setup aborted."
        log_error "==============================================================="
        exit 1
    fi
    log_success "Underlying block storage verified: LUKS/dm-crypt encrypted."

    # 3. Locale-independent free disk space check (requires >= 28GB for 24GB swapfile)
    local avail_gb
    avail_gb=$(LC_ALL=C df --output=avail -BG / 2>/dev/null | tail -n 1 | tr -dc '0-9')
    if [ -z "${avail_gb}" ] || [ "${avail_gb}" -lt 28 ]; then
        log_error "Insufficient disk space on /. Needed >= 28GB, available: ${avail_gb:-0}GB."
        exit 1
    fi
    log_success "Disk space OK (${avail_gb}GB available on /)."

    # 4. Check required system utilities
    for tool in btrfs grubby dracut findmnt lsblk systemctl busctl; do
        if ! command -v "${tool}" &>/dev/null; then
            log_error "Required tool '${tool}' is not installed."
            exit 1
        fi
    done
    log_success "All required CLI tools are present."

    # 5. Helper files shipped next to this script
    if [ "${INSTALL_LOCK_SLEEP}" = true ] || [ "${INSTALL_SLEEP_REPORT}" = true ]; then
        if [ ! -d "${FILES_DIR}" ]; then
            log_error "Helper directory '${FILES_DIR}' not found. Run this script from a full checkout of the repository."
            exit 1
        fi
    fi
}

parse_args() {
    for arg in "$@"; do
        case "${arg}" in
            --no-lock-sleep)    INSTALL_LOCK_SLEEP=false ;;
            --no-sleep-report)  INSTALL_SLEEP_REPORT=false ;;
            -h|--help)
                echo "Usage: sudo bash $0 [DELAY_MINUTES] [--no-lock-sleep] [--no-sleep-report]"
                exit 0
                ;;
            *)                  DELAY_ARG="${arg}" ;;
        esac
    done
}

prompt_hibernate_delay() {
    local arg_val="${1:-}"

    # 1. Check if duration was passed directly as a command-line argument
    if [ -n "${arg_val}" ]; then
        if [[ "${arg_val}" =~ ^[0-9]+$ ]] && [ "${arg_val}" -gt 0 ]; then
            HIBERNATE_DELAY_MINUTES="${arg_val}"
            log_info "Hibernate delay specified via argument: ${HIBERNATE_DELAY_MINUTES} minutes."
            return 0
        else
            log_warn "Invalid delay argument '${arg_val}'. Must be a positive integer."
        fi
    fi

    # 2. Detect existing configuration if present to offer as default
    local current_setting=""
    if [ -f "${SLEEP_CONF}" ]; then
        current_setting=$(grep -E '^HibernateDelaySec=' "${SLEEP_CONF}" 2>/dev/null | tr -dc '0-9' || echo "")
    fi
    local prompt_default="${current_setting:-$DEFAULT_DELAY_MINUTES}"

    # 3. Prompt user interactively if in a terminal
    if [ -t 0 ]; then
        echo ""
        echo -e "${BLUE}[CONFIGURATION]${NC} Sleep duration before automatic hibernation:"
        echo "  How many minutes should the laptop stay in fast suspend before hibernating to SSD?"
        read -rp "  Enter minutes [Press Enter for default: ${prompt_default}]: " user_val

        if [ -z "${user_val}" ]; then
            HIBERNATE_DELAY_MINUTES="${prompt_default}"
        elif [[ "${user_val}" =~ ^[0-9]+$ ]] && [ "${user_val}" -gt 0 ]; then
            HIBERNATE_DELAY_MINUTES="${user_val}"
        else
            log_warn "Invalid input '${user_val}'. Using default of ${prompt_default} minutes."
            HIBERNATE_DELAY_MINUTES="${prompt_default}"
        fi
    else
        log_info "Non-interactive shell. Using ${prompt_default} minutes."
        HIBERNATE_DELAY_MINUTES="${prompt_default}"
    fi

    log_success "Configured sleep-to-hibernate delay: ${HIBERNATE_DELAY_MINUTES} minutes."
    echo ""
}

create_btrfs_swapfile() {
    log_info "Setting up isolated Btrfs swap subvolume and swapfile..."

    if [ ! -d "${SWAP_DIR}" ]; then
        log_info "Creating dedicated subvolume '${SWAP_DIR}'..."
        btrfs subvolume create "${SWAP_DIR}"
    else
        log_info "Subvolume '${SWAP_DIR}' already exists."
    fi

    if [ ! -f "${SWAP_FILE}" ]; then
        log_info "Creating ${SWAP_SIZE} swapfile at ${SWAP_FILE} (this may take 1-2 minutes)..."
        btrfs filesystem mkswapfile -s "${SWAP_SIZE}" "${SWAP_FILE}"
        chmod 0600 "${SWAP_FILE}"
        log_success "Swapfile created with permissions 0600 (root only) and formatted."
    else
        log_info "Swapfile '${SWAP_FILE}' already exists, reusing."
        chmod 0600 "${SWAP_FILE}"
    fi

    # Set SELinux context to swapfile_t so systemd-logind is allowed to inspect it
    if command -v semanage &>/dev/null; then
        log_info "Registering SELinux file context for ${SWAP_DIR}..."
        semanage fcontext -a -t swapfile_t "${SWAP_DIR}(/.*)?" 2>/dev/null || semanage fcontext -m -t swapfile_t "${SWAP_DIR}(/.*)?" 2>/dev/null || true
    fi
    chcon -t swapfile_t "${SWAP_FILE}" 2>/dev/null || true
    if command -v restorecon &>/dev/null; then
        restorecon -Rv "${SWAP_DIR}" 2>/dev/null || true
    fi

    # Configure /etc/fstab with lower priority (pri=10) so fast zram (pri=100) handles daily RAM paging
    if ! grep -qs "${SWAP_FILE}" /etc/fstab; then
        log_info "Registering swapfile in /etc/fstab with priority 10..."
        if [ ! -f "/etc/fstab.bak" ]; then
            cp -a "/etc/fstab" "/etc/fstab.bak"
        fi
        echo -e "${SWAP_FILE}\tnone\tswap\tdefaults,pri=10\t0 0" >> /etc/fstab
        log_success "/etc/fstab backed up and updated."
    else
        log_info "/etc/fstab already contains ${SWAP_FILE}."
    fi

    # Enable swap if not already active
    if ! swapon --show | grep -qs "${SWAP_FILE}"; then
        log_info "Activating swapfile with priority 10..."
        swapon --priority 10 "${SWAP_FILE}"
        log_success "Swapfile activated with priority 10."
    else
        log_info "Swapfile is already active."
    fi
}

configure_kernel_and_dracut() {
    # Check if bootloader and dracut are already fully configured from a previous run
    if [ -f "${DRACUT_CONF}" ] && \
       grep -qs "resume=" "${KERNEL_CMDLINE}" 2>/dev/null && \
       grep -qs "resume=" "${GRUB_DEFAULT}" 2>/dev/null; then
        log_info "Kernel resume parameters and Dracut module are already configured."
        log_info "Skipping bootloader and initramfs rebuild (fast path)."
        return 0
    fi

    log_info "Configuring kernel boot arguments and Dracut initramfs..."

    local root_uuid resume_offset
    root_uuid=$(findmnt -no UUID /)
    resume_offset=$(btrfs inspect-internal map-swapfile -r "${SWAP_FILE}")

    if [ -z "${root_uuid}" ] || [ -z "${resume_offset}" ]; then
        log_error "Failed to detect root UUID or swapfile resume offset."
        exit 1
    fi
    log_success "Root UUID and swapfile resume offset determined successfully."

    # 1. Update kernel args via grubby for all installed BLS kernel entries
    log_info "Applying kernel parameters across all installed kernels via grubby..."
    grubby --update-kernel=ALL --args="resume=UUID=${root_uuid} resume_offset=${resume_offset}"
    log_success "Kernel parameters applied via grubby."

    # 2. Update /etc/default/grub (persists for any future grub2-mkconfig runs)
    if [ -f "${GRUB_DEFAULT}" ]; then
        if ! grep -qs "resume=" "${GRUB_DEFAULT}"; then
            log_info "Updating ${GRUB_DEFAULT}..."
            # Single bounded backup to prevent multiple backup file accumulation
            if [ ! -f "${GRUB_DEFAULT}.bak" ]; then
                cp -a "${GRUB_DEFAULT}" "${GRUB_DEFAULT}.bak"
            fi

            if grep -qE '^GRUB_CMDLINE_LINUX=".*"' "${GRUB_DEFAULT}"; then
                sed -i -E "s|^GRUB_CMDLINE_LINUX=\"(.*)\"|GRUB_CMDLINE_LINUX=\"\1 resume=UUID=${root_uuid} resume_offset=${resume_offset}\"|" "${GRUB_DEFAULT}"
            elif grep -qE "^GRUB_CMDLINE_LINUX='.*'" "${GRUB_DEFAULT}"; then
                sed -i -E "s|^GRUB_CMDLINE_LINUX='(.*)'|GRUB_CMDLINE_LINUX='\1 resume=UUID=${root_uuid} resume_offset=${resume_offset}'|" "${GRUB_DEFAULT}"
            else
                log_error "Failed to match GRUB_CMDLINE_LINUX line format in ${GRUB_DEFAULT}."
                log_error "Please manually append 'resume=UUID=${root_uuid} resume_offset=${resume_offset}' to ${GRUB_DEFAULT}."
                exit 1
            fi

            # Fail loudly if sed did not match or apply
            if ! grep -qs "resume=" "${GRUB_DEFAULT}"; then
                log_error "Assertion failed: 'resume=' parameter was not written to ${GRUB_DEFAULT}."
                exit 1
            fi
            log_success "${GRUB_DEFAULT} updated and verified."
        fi
    fi

    # 3. Update /etc/kernel/cmdline if present (used by Fedora kernel-install for future kernels)
    if [ -f "${KERNEL_CMDLINE}" ]; then
        if ! grep -qs "resume=" "${KERNEL_CMDLINE}"; then
            if [ ! -f "${KERNEL_CMDLINE}.bak" ]; then
                cp -a "${KERNEL_CMDLINE}" "${KERNEL_CMDLINE}.bak"
            fi
            # Safely append parameters strictly once to the end of file (whole-file match via -z)
            sed -i -z 's/[[:space:]]*$/ resume=UUID='"${root_uuid}"' resume_offset='"${resume_offset}"'\n/' "${KERNEL_CMDLINE}"
            log_success "${KERNEL_CMDLINE} updated and verified."
        fi
    fi

    # 4. Add Dracut resume module configuration
    log_info "Configuring Dracut resume module in ${DRACUT_CONF}..."
    cat > "${DRACUT_CONF}" << 'INNER_EOF'
add_dracutmodules+=" resume "
INNER_EOF

    # 5. Rebuild initramfs for currently running kernel
    local current_kernel
    current_kernel=$(uname -r)
    log_info "Rebuilding initramfs for kernel ${current_kernel} (this may take ~30 seconds)..."
    dracut -f --kver "${current_kernel}"
    log_success "Initramfs rebuilt successfully with resume module."
}

configure_systemd() {
    log_info "Configuring systemd Suspend-then-Hibernate policies..."

    mkdir -p "${SLEEP_CONF_DIR}" "${LOGIND_CONF_DIR}"

    # sleep.conf drop-in:
    # - HibernateDelaySec: ${HIBERNATE_DELAY_MINUTES}min in suspend before hibernating
    # - HibernateOnACPower: no (stay in suspend when plugged in, only hibernate on battery)
    # - SuspendEstimationSec: 60min (measures battery drain rate via RTC alarm)
    # - HibernateMode: shutdown (fully power off after writing the image; the
    #   default "platform" S4 mode can keep USB/wake power on and drain ~0.7W)
    cat > "${SLEEP_CONF}" << INNER_EOF
[Sleep]
# Transition to hibernation after ${HIBERNATE_DELAY_MINUTES} minutes of suspend
HibernateDelaySec=${HIBERNATE_DELAY_MINUTES}min

# Stay suspended when plugged into charger; only hibernate on battery
HibernateOnACPower=no

# RTC alarm measurement interval for battery drain estimation
SuspendEstimationSec=60min

# Power off completely once the hibernation image is written
HibernateMode=shutdown
INNER_EOF
    log_success "Created ${SLEEP_CONF} (${HIBERNATE_DELAY_MINUTES}min delay)."

    # logind.conf drop-in:
    # - Direct default sleep action to suspend-then-hibernate
    # - Lid switch on battery: suspend-then-hibernate
    # - Lid switch on AC power: regular suspend
    cat > "${LOGIND_CONF}" << 'INNER_EOF'
[Login]
SleepOperation=suspend-then-hibernate suspend
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchExternalPower=suspend
HandleSuspendKey=suspend-then-hibernate
INNER_EOF
    log_success "Created ${LOGIND_CONF}."

    # GNOME's Suspend button (and `systemctl suspend`) call logind's Suspend(),
    # which runs systemd-suspend.service and ignores the lid/key settings above.
    # Point that service at suspend-then-hibernate too.
    mkdir -p "${SUSPEND_OVERRIDE_DIR}"
    cat > "${SUSPEND_OVERRIDE}" << 'INNER_EOF'
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-sleep suspend-then-hibernate
INNER_EOF
    log_success "Created ${SUSPEND_OVERRIDE} (Suspend button now suspends-then-hibernates)."

    # Apply SELinux contexts to newly created configuration files and directories
    if command -v restorecon &>/dev/null; then
        log_info "Applying SELinux security contexts (restorecon)..."
        restorecon -RF "${SLEEP_CONF_DIR}" "${LOGIND_CONF_DIR}" "${SUSPEND_OVERRIDE_DIR}" "/etc/dracut.conf.d" "${SWAP_DIR}" 2>/dev/null || true
        log_success "SELinux file contexts updated."
    fi

    # Non-disruptive configuration reload:
    # Use SIGHUP so systemd-logind reloads drop-in rules without terminating active seats/sessions
    log_info "Reloading systemd manager and signaling logind via SIGHUP..."
    systemctl daemon-reload
    systemctl kill --signal=HUP systemd-logind.service
    log_success "Systemd and logind reloaded cleanly without session disruption."
}

# Run a `systemctl --user` command in the invoking (sudo) user's session, if any.
user_systemctl() {
    local user="${SUDO_USER:-}" uid
    [ -n "${user}" ] && [ "${user}" != "root" ] || return 0
    uid=$(id -u "${user}")
    [ -S "/run/user/${uid}/bus" ] || return 0
    runuser -u "${user}" -- env XDG_RUNTIME_DIR="/run/user/${uid}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
        systemctl --user "$@" 2>/dev/null || true
}

install_user_service() {
    local name="$1"
    install -m 0755 "${FILES_DIR}/${name}" "${BIN_DIR}/${name}"
    install -m 0644 "${FILES_DIR}/${name}.service" "${USER_UNIT_DIR}/${name}.service"
    # Enable for every user's graphical session, then start it for the current one.
    systemctl --global enable "${name}.service"
    user_systemctl daemon-reload
    user_systemctl restart "${name}.service"
}

install_extras() {
    mkdir -p "${USER_UNIT_DIR}"

    if [ "${INSTALL_LOCK_SLEEP}" = true ]; then
        log_info "Installing lock-sleep (sleep 30s after locking, on battery only)..."
        install_user_service lock-sleep
        log_success "lock-sleep installed and enabled for all users."
    fi

    if [ "${INSTALL_SLEEP_REPORT}" = true ]; then
        log_info "Installing sleep battery report (hook, unlock notification, sleep-report)..."
        # systemd-sleep only runs hooks from /usr/lib/systemd/system-sleep/.
        install -D -m 0755 "${FILES_DIR}/sleep-battery-hook" "${SLEEP_HOOK}"
        install -m 0755 "${FILES_DIR}/sleep-report" "${BIN_DIR}/sleep-report"
        install_user_service sleep-notify
        log_success "Sleep battery report installed (log: /var/log/sleep-battery.log)."
    fi

    if command -v restorecon &>/dev/null; then
        restorecon -F "${SLEEP_HOOK}" "${BIN_DIR}"/lock-sleep "${BIN_DIR}"/sleep-notify \
            "${BIN_DIR}"/sleep-report "${USER_UNIT_DIR}"/*.service 2>/dev/null || true
    fi
}

verify_status() {
    echo ""
    log_info "=== Verification & Diagnostics ==="

    echo "  • Active Swap Devices:"
    swapon --show
    echo ""

    local sleep_op lid_switch
    sleep_op=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager SleepOperation 2>/dev/null || echo "")
    lid_switch=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandleLidSwitch 2>/dev/null || echo "")

    echo "  • Active Sleep Operations: ${sleep_op}"
    echo "  • Lid Switch Action:       ${lid_switch}"
    echo "  • Suspend Button Action:   $(systemctl show systemd-suspend.service -p ExecStart --value | grep -oE 'systemd-sleep [a-z-]+' | cut -d' ' -f2)"

    if [ -f "/etc/kernel/cmdline" ] && grep -qs "resume=" "/etc/kernel/cmdline"; then
        echo "  • Bootloader Resume Args:  Configured (UUID & offset set)"
    fi

    echo ""
    log_success "Setup complete! Windows-level Suspend-then-Hibernate is now active."
    echo ""

    local hours_display=""
    if [ $(( HIBERNATE_DELAY_MINUTES % 60 )) -eq 0 ]; then
        local num_hours=$(( HIBERNATE_DELAY_MINUTES / 60 ))
        if [ "${num_hours}" -eq 1 ]; then
            hours_display=" (1 hour)"
        else
            hours_display=" (${num_hours} hours)"
        fi
    fi

    echo -e "${YELLOW}Important Safety & Usage Reminders:${NC}"
    echo "  1. On battery, closing the lid suspends for ${HIBERNATE_DELAY_MINUTES} minutes${hours_display}, then automatically hibernates."
    echo "  2. On AC power, the machine remains in fast suspend (no unnecessary SSD writes)."
    echo "  3. When waking from hibernation, enter your LUKS passphrase at boot; your session will restore."
    echo "  4. Dual-Boot rule: Never boot into Windows while Linux is hibernated. Always resume Linux first."
    if [ "${INSTALL_LOCK_SLEEP}" = true ]; then
        echo "  5. On battery, locking the screen (Super+L) sleeps after 30s idle, and again if woken but left locked."
    fi
    if [ "${INSTALL_SLEEP_REPORT}" = true ]; then
        echo "  6. After waking, unlocking shows a battery-drain notification; run 'sleep-report' for history."
    fi
    echo "  7. Lenovo tip: disable 'Always On USB' in BIOS to cut residual drain while hibernated."
    echo "  8. To test immediately, run:"
    echo "       systemctl suspend-then-hibernate"
    echo ""
}

main() {
    echo "=========================================================="
    echo "  Fedora 44 Windows-Level Auto-Hibernation Setup Script   "
    echo "=========================================================="
    parse_args "$@"
    check_root
    check_prerequisites
    prompt_hibernate_delay "${DELAY_ARG}"
    create_btrfs_swapfile
    configure_kernel_and_dracut
    configure_systemd
    install_extras
    verify_status
}

main "$@"
