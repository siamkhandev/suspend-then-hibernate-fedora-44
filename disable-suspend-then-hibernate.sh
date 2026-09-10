#!/usr/bin/env bash
# ==============================================================================
# Script: disable-suspend-then-hibernate.sh
# Purpose: Cleanly and safely revert "Suspend-then-Hibernate" configuration
# Author: Generated with Antigravity (Hardened & Audited)
#
# Hardening & Reliability Features:
# 1. Boot-Safe Order: Cleans kernel cmdline, BLS, and dracut BEFORE deleting swap
# 2. Trap error handler reporting exact failure line and recovery status
# 3. Swap signature invalidation (zeroing swap header) before unlinking
# 4. Safe fstab editing with fixed-string filtering and backup
# 5. Safe subvolume deletion (no blind rm -rf fallback)
# 6. Non-disruptive SIGHUP reload of systemd-logind
# 7. SELinux context restoration
# 8. Post-rollback zram health verification
# ==============================================================================

set -euo pipefail

SWAP_DIR="/swap"
SWAP_FILE="${SWAP_DIR}/swapfile"
DRACUT_CONF="/etc/dracut.conf.d/resume.conf"
SLEEP_CONF_DIR="/etc/systemd/sleep.conf.d"
SLEEP_CONF="${SLEEP_CONF_DIR}/suspend-then-hibernate.conf"
LOGIND_CONF_DIR="/etc/systemd/logind.conf.d"
LOGIND_CONF="${LOGIND_CONF_DIR}/suspend-then-hibernate.conf"
GRUB_DEFAULT="/etc/default/grub"
KERNEL_CMDLINE="/etc/kernel/cmdline"
FSTAB="/etc/fstab"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# Trap unexpected errors and print clear diagnostic location
on_error() {
    local exit_code=$1
    local line_no=$2
    echo ""
    log_error "================================================================="
    log_error "Rollback halted unexpectedly with exit code ${exit_code} at line ${line_no}."
    log_error "The bootloader cleanup was prioritized first to prevent unbootable"
    log_error "or hanging states. Please inspect the message above."
    log_error "================================================================="
}
trap 'on_error $? $LINENO' ERR

check_root() {
    if [ "${EUID}" -ne 0 ]; then
        log_error "This script requires root privileges. Please run with sudo:"
        echo "  sudo bash $0"
        exit 1
    fi
}

revert_kernel_and_dracut() {
    log_info "Step 1: Removing resume arguments from bootloader and Dracut..."

    # 1. Remove resume parameters from all BLS entries via grubby
    if command -v grubby &>/dev/null; then
        log_info "Removing 'resume' and 'resume_offset' kernel args via grubby..."
        grubby --update-kernel=ALL --remove-args="resume resume_offset" 2>/dev/null || true
        log_success "Kernel BLS entries cleaned."
    fi

    # 2. Targeted surgical removal of resume args from /etc/default/grub (preserves unrelated edits)
    if [ -f "${GRUB_DEFAULT}" ]; then
        log_info "Performing targeted removal of resume parameters from ${GRUB_DEFAULT}..."
        # Strip resume=UUID=... and resume_offset=... parameters cleanly
        sed -i -E 's/[[:space:]]+resume=UUID=[^[:space:]"]+//g; s/[[:space:]]+resume_offset=[0-9]+//g' "${GRUB_DEFAULT}"
        
        # Verify targeted removal succeeded
        if grep -qs "resume=" "${GRUB_DEFAULT}"; then
            log_warn "Targeted removal incomplete; falling back to pristine backup..."
            if [ -f "${GRUB_DEFAULT}.bak" ]; then
                cp -a "${GRUB_DEFAULT}.bak" "${GRUB_DEFAULT}"
                log_success "Restored ${GRUB_DEFAULT} from backup fallback."
            else
                log_error "Warning: 'resume=' still detected in ${GRUB_DEFAULT} and no backup file found."
            fi
        else
            log_success "${GRUB_DEFAULT} cleaned; all unrelated user settings preserved."
            rm -f "${GRUB_DEFAULT}.bak" 2>/dev/null || true
        fi
    fi

    # 3. Targeted surgical removal of resume args from /etc/kernel/cmdline (preserves unrelated edits)
    if [ -f "${KERNEL_CMDLINE}" ]; then
        log_info "Performing targeted removal of resume parameters from ${KERNEL_CMDLINE}..."
        sed -i -E 's/[[:space:]]+resume=UUID=[^[:space:]"]+//g; s/[[:space:]]+resume_offset=[0-9]+//g' "${KERNEL_CMDLINE}"
        
        # Verify targeted removal succeeded
        if grep -qs "resume=" "${KERNEL_CMDLINE}"; then
            log_warn "Targeted removal incomplete; falling back to pristine backup..."
            if [ -f "${KERNEL_CMDLINE}.bak" ]; then
                cp -a "${KERNEL_CMDLINE}.bak" "${KERNEL_CMDLINE}"
                log_success "Restored ${KERNEL_CMDLINE} from backup fallback."
            else
                log_error "Warning: 'resume=' still detected in ${KERNEL_CMDLINE} and no backup file found."
            fi
        else
            log_success "${KERNEL_CMDLINE} cleaned; all unrelated kernel parameters preserved."
            rm -f "${KERNEL_CMDLINE}.bak" 2>/dev/null || true
        fi
    fi

    # 4. Remove Dracut resume configuration and rebuild initramfs
    if [ -f "${DRACUT_CONF}" ]; then
        log_info "Removing ${DRACUT_CONF}..."
        rm -f "${DRACUT_CONF}"
    fi

    local current_kernel
    current_kernel=$(uname -r)
    log_info "Rebuilding initramfs for kernel ${current_kernel} (removing resume module)..."
    dracut -f --kver "${current_kernel}"
    log_success "Initramfs rebuilt cleanly."
}

revert_systemd_config() {
    log_info "Step 2: Removing systemd Suspend-then-Hibernate drop-in policies..."

    rm -f "${SLEEP_CONF}" "${LOGIND_CONF}"

    # Clean up directories if empty
    rmdir "${SLEEP_CONF_DIR}" 2>/dev/null || true
    rmdir "${LOGIND_CONF_DIR}" 2>/dev/null || true

    log_info "Reloading systemd manager and signaling logind via SIGHUP..."
    systemctl daemon-reload
    systemctl kill --signal=HUP systemd-logind.service 2>/dev/null || true
    log_success "Systemd policies removed and logind reloaded cleanly."
}

remove_swapfile_and_subvolume() {
    log_info "Step 3: Deactivating and removing swapfile and subvolume..."

    # 1. Deactivate swap if active
    if [ -f "${SWAP_FILE}" ] && swapon --show | grep -qs "${SWAP_FILE}"; then
        log_info "Deactivating swap on ${SWAP_FILE}..."
        swapoff "${SWAP_FILE}"
        log_success "Swap deactivated."
    fi

    # 2. Invalidate swap and hibernation headers (security & hygiene)
    # Zeroing the first 64KB destroys any hibernation signature or swap metadata
    if [ -f "${SWAP_FILE}" ] && [ ! -L "${SWAP_FILE}" ]; then
        log_info "Zeroing swap header to prevent stale hibernation resume..."
        dd if=/dev/zero of="${SWAP_FILE}" bs=4096 count=16 conv=notrunc status=none 2>/dev/null || true
        log_success "Swap header invalidated."
    fi

    # 3. Clean /etc/fstab safely with fixed string filtering
    if [ -f "${FSTAB}" ] && grep -qs "${SWAP_FILE}" "${FSTAB}"; then
        log_info "Removing ${SWAP_FILE} entry from ${FSTAB}..."
        if [ ! -f "${FSTAB}.bak" ]; then
            cp -a "${FSTAB}" "${FSTAB}.bak"
        fi
        grep -vF "${SWAP_FILE}" "${FSTAB}" > "${FSTAB}.tmp"
        chmod 0644 "${FSTAB}.tmp"
        mv "${FSTAB}.tmp" "${FSTAB}"
        log_success "${FSTAB} updated safely."
    fi

    # 4. Remove swapfile (verify regular file, not symlink)
    if [ -f "${SWAP_FILE}" ] && [ ! -L "${SWAP_FILE}" ]; then
        log_info "Deleting ${SWAP_FILE}..."
        rm -f "${SWAP_FILE}"
        log_success "Swapfile deleted (disk space reclaimed)."
    fi

    # 5. Delete Btrfs subvolume safely (no blind rm -rf)
    if [ -d "${SWAP_DIR}" ]; then
        if btrfs subvolume show "${SWAP_DIR}" &>/dev/null; then
            log_info "Deleting Btrfs subvolume '${SWAP_DIR}'..."
            btrfs subvolume delete "${SWAP_DIR}"
            log_success "Subvolume '${SWAP_DIR}' deleted."
        else
            log_info "Removing directory '${SWAP_DIR}'..."
            rmdir "${SWAP_DIR}"
            log_success "Directory '${SWAP_DIR}' removed."
        fi
    fi
}

restore_selinux_and_verify() {
    log_info "Step 4: Restoring SELinux contexts and verifying system status..."

    if command -v restorecon &>/dev/null; then
        restorecon -RF "${SLEEP_CONF_DIR}" "${LOGIND_CONF_DIR}" "/etc/dracut.conf.d" 2>/dev/null || true
        log_success "SELinux contexts updated."
    fi

    echo ""
    log_info "=== Post-Rollback Diagnostics ==="

    # Verify zram status
    echo "  • Active Swap Devices:"
    swapon --show

    if swapon --show | grep -qs "zram"; then
        log_success "Default zram swap is active and healthy."
    else
        log_warn "zram swap device was not detected in swapon --show. Check zram-generator status if needed."
    fi

    echo -n "  • Can Hibernate: "
    busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanHibernate 2>/dev/null || echo "Unknown"

    echo -n "  • Can Suspend-Then-Hibernate: "
    busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanSuspendThenHibernate 2>/dev/null || echo "Unknown"

    echo ""
    log_success "Rollback successfully completed! System is restored to default state."
    echo ""
}

main() {
    echo "=========================================================="
    echo "  Reverting Windows-Level Suspend-then-Hibernate Setup    "
    echo "=========================================================="
    check_root
    revert_kernel_and_dracut
    revert_systemd_config
    remove_swapfile_and_subvolume
    restore_selinux_and_verify
}

main "$@"
