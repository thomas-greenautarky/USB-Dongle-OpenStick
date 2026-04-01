#!/bin/bash -e
#
# flash-openstick.sh — Flash OpenStick Debian onto a JZ0145-v33 UFI 4G USB dongle
#
# Prerequisites:
#   - edl tool installed: pip install edl (or pipx install edlclient)
#   - adb installed: apt install adb (for entering EDL from stock Android)
#   - Device in EDL mode (reset button + USB plug, or adb reboot edl)
#   - All required files in the flash/files/ directory
#
# Usage:
#   cd flash && bash flash-openstick.sh
#
# This script uses the proven EDL-only flash method for JZ02/JZ0145-v33 boards.
# No fastboot is needed — the Dragonboard aboot's fastboot interface (USB ID
# 18d1:d001 / 05c6:9091) is unreliable and cannot be reached by the host
# fastboot tool.
#
# Flash sequence:
#   1. Enter EDL mode (reset button + USB plug, or adb reboot edl)
#   2. Auto-backup modem calibration (IMEI, RF cal) from device
#   3. Write split GPT (primary at sector 0, backup at end of disk)
#   4. Flash Dragonboard firmware (sbl1, rpm, tz, qhypstub, cdt, aboot)
#   5. Flash boot.img (6.6 kernel with appended DTB, Android boot image format)
#   6. Flash rootfs.raw (Debian)
#   7. Restore modem calibration from auto-backup
#   8. Reset → Debian boots

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"
BACKUP_DIR="$SCRIPT_DIR/../backup/partitions"

# Backup GPT sector for 4GB eMMC (end of disk)
BACKUP_GPT_SECTOR=7733215

# Modem calibration partitions (device-specific, contain IMEI + RF calibration)
MODEM_PARTITIONS=(sec fsc fsg modemst1 modemst2)

# Required flash files
REQUIRED_FILES=(
    "$FILES_DIR/emmc_appsboot-test-signed.mbn"
    "$FILES_DIR/gpt_primary_proper.bin"
    "$FILES_DIR/gpt_backup_proper.bin"
    "$FILES_DIR/sbl1.mbn"
    "$FILES_DIR/rpm.mbn"
    "$FILES_DIR/tz.mbn"
    "$FILES_DIR/qhypstub-test-signed.mbn"
    "$FILES_DIR/sbc_1.0_8016.bin"
    "$FILES_DIR/boot.img"
    "$FILES_DIR/rootfs.raw"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

# ─── Preflight checks ───────────────────────────────────────────────────────

log "Checking required flash files..."
for f in "${REQUIRED_FILES[@]}"; do
    [ -f "$f" ] || err "Missing: $f"
done
log "All flash files present."

which edl >/dev/null 2>&1   || err "edl not found. Install: pipx install edlclient"
which adb >/dev/null 2>&1   || warn "adb not found (optional, for entering EDL from stock Android)"

# ─── Step 1: Enter EDL mode ─────────────────────────────────────────────────

log "Checking device state..."
if lsusb 2>/dev/null | grep -q "05c6:9008"; then
    log "Device already in EDL mode."
elif which adb >/dev/null 2>&1 && adb devices 2>/dev/null | grep -q "device$"; then
    log "Device in ADB mode — rebooting to EDL..."
    adb reboot edl
    sleep 5
else
    warn "Device not detected. Please enter EDL mode manually:"
    warn "  1. Unplug the dongle"
    warn "  2. Hold the reset button (pin hole)"
    warn "  3. Plug in while holding reset"
    warn "  4. Hold for 3-5 seconds, then release"
    echo ""
    echo -n "Press Enter when device is in EDL mode..."
    read
fi

# Wait for EDL
log "Waiting for EDL device (05c6:9008)..."
for i in $(seq 1 30); do
    lsusb 2>/dev/null | grep -q "05c6:9008" && break
    sleep 2
done
lsusb 2>/dev/null | grep -q "05c6:9008" || err "EDL device not found after 60s"
log "EDL device detected."

# ─── Step 2: Auto-backup modem calibration ──────────────────────────────────
# Each dongle has unique IMEI + RF calibration data in these partitions.
# We read them BEFORE flashing so they can be restored afterwards.
# This makes the script safe for any stick — no manual backup needed.

AUTOSAVE_DIR="$SCRIPT_DIR/../backup/autosave_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$AUTOSAVE_DIR"

log "Reading modem calibration from device (IMEI, RF cal)..."
BACKUP_OK=true
for part in "${MODEM_PARTITIONS[@]}"; do
    log "  Reading $part..."
    if edl r "$part" "$AUTOSAVE_DIR/${part}.bin" 2>&1 | grep -q "Read "; then
        log "  Saved $part ($(du -h "$AUTOSAVE_DIR/${part}.bin" | cut -f1))"
    else
        warn "  Failed to read $part from device"
        BACKUP_OK=false
    fi
done

# Verify we got valid data (not all zeros/empty)
VALID_BACKUPS=0
for part in "${MODEM_PARTITIONS[@]}"; do
    f="$AUTOSAVE_DIR/${part}.bin"
    if [ -f "$f" ] && [ "$(stat -c%s "$f")" -gt 0 ]; then
        VALID_BACKUPS=$((VALID_BACKUPS + 1))
    fi
done

if [ "$VALID_BACKUPS" -eq "${#MODEM_PARTITIONS[@]}" ]; then
    log "Auto-backup complete: $AUTOSAVE_DIR ($VALID_BACKUPS/${#MODEM_PARTITIONS[@]} partitions)"
    RESTORE_DIR="$AUTOSAVE_DIR"
elif [ -d "$BACKUP_DIR" ]; then
    # Fall back to existing manual backup
    FALLBACK_OK=true
    for part in "${MODEM_PARTITIONS[@]}"; do
        [ -f "$BACKUP_DIR/${part}.bin" ] || FALLBACK_OK=false
    done
    if $FALLBACK_OK; then
        warn "Auto-backup incomplete ($VALID_BACKUPS/${#MODEM_PARTITIONS[@]}), using existing backup: $BACKUP_DIR"
        RESTORE_DIR="$BACKUP_DIR"
    else
        err "Auto-backup failed and no complete manual backup in $BACKUP_DIR. Aborting to protect modem calibration."
    fi
else
    err "Auto-backup failed and no manual backup found. Aborting to protect modem calibration."
fi

# Also save to the standard backup location if it doesn't exist yet
if [ ! -f "$BACKUP_DIR/sec.bin" ] && [ "$VALID_BACKUPS" -eq "${#MODEM_PARTITIONS[@]}" ]; then
    log "Copying auto-backup to $BACKUP_DIR (first-time backup)..."
    mkdir -p "$BACKUP_DIR"
    cp "$AUTOSAVE_DIR"/*.bin "$BACKUP_DIR/"
fi

echo ""
log "Modem calibration secured. Proceeding with flash..."
echo ""

# ─── Step 3: Write split GPT via EDL ────────────────────────────────────────

log "Writing primary GPT (sector 0)..."
edl ws 0 "$FILES_DIR/gpt_primary_proper.bin"

log "Writing backup GPT (sector $BACKUP_GPT_SECTOR)..."
edl ws "$BACKUP_GPT_SECTOR" "$FILES_DIR/gpt_backup_proper.bin"

# ─── Step 4: Flash Dragonboard firmware via EDL ─────────────────────────────

log "Flashing Dragonboard firmware..."
edl w sbl1  "$FILES_DIR/sbl1.mbn"
edl w rpm   "$FILES_DIR/rpm.mbn"
edl w tz    "$FILES_DIR/tz.mbn"
edl w hyp   "$FILES_DIR/qhypstub-test-signed.mbn"
edl w cdt   "$FILES_DIR/sbc_1.0_8016.bin"
edl w aboot "$FILES_DIR/emmc_appsboot-test-signed.mbn"

# ─── Step 5: Flash boot image + rootfs via EDL ──────────────────────────────

log "Flashing boot image (6.6 kernel + appended DTB)..."
edl w boot "$FILES_DIR/boot.img"

log "Flashing Debian rootfs (this takes 2-5 minutes)..."
edl w rootfs "$FILES_DIR/rootfs.raw"

# ─── Step 6: Restore modem calibration data via EDL ─────────────────────────

log "Restoring modem calibration from: $RESTORE_DIR"
for part in "${MODEM_PARTITIONS[@]}"; do
    log "  Writing $part..."
    edl w "$part" "$RESTORE_DIR/${part}.bin"
done
log "Modem calibration restored."

# ─── Step 7: Reset and verify ───────────────────────────────────────────────

log "Resetting device..."
edl reset 2>&1 | tail -1 || true

log "Waiting for device to boot (45s)..."
sleep 45

# Check if RNDIS gadget appears (Debian with USB networking)
if ! lsusb 2>/dev/null | grep -q "1d6b:0104"; then
    warn "RNDIS gadget not detected after 45s. The device may need more time to boot."
    warn "Check: lsusb | grep 1d6b:0104"
    warn "If the device does not boot, re-enter EDL (reset button + USB plug)"
    echo ""
    log "Modem calibration backup saved in: $RESTORE_DIR"
    exit 1
fi

log "Device booted! RNDIS USB gadget detected."

# ─── Step 8: Copy device-specific modem NV storage via SSH ─────────────────
# These files contain the factory IMEI + RF calibration (CE/RED compliant).
# They MUST come from this specific dongle's backup — never from another device.

DONGLE_IP="192.168.68.1"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SSH_PASS="openstick"

# Wait for SSH to be ready
log "Waiting for SSH..."
for i in $(seq 1 12); do
    if SSHPASS="$SSH_PASS" sshpass -e ssh $SSH_OPTS "root@$DONGLE_IP" "echo OK" >/dev/null 2>&1; then
        break
    fi
    sleep 5
done

if which sshpass >/dev/null 2>&1 && SSHPASS="$SSH_PASS" sshpass -e ssh $SSH_OPTS "root@$DONGLE_IP" "echo OK" >/dev/null 2>&1; then
    log "SSH connected. Copying device-specific modem NV storage..."

    # Copy modemst1 → modem_fs1, modemst2 → modem_fs2, fsg → modem_fsg
    for pair in "modemst1:modem_fs1" "modemst2:modem_fs2" "fsg:modem_fsg"; do
        SRC="${pair%%:*}"
        DST="${pair##*:}"
        if [ -f "$RESTORE_DIR/${SRC}.bin" ]; then
            SSHPASS="$SSH_PASS" sshpass -e scp $SSH_OPTS \
                "$RESTORE_DIR/${SRC}.bin" "root@$DONGLE_IP:/boot/$DST"
            log "  Copied $SRC → /boot/$DST"
        else
            warn "  Missing $RESTORE_DIR/${SRC}.bin — modem may not work"
        fi
    done

    SSHPASS="$SSH_PASS" sshpass -e ssh $SSH_OPTS "root@$DONGLE_IP" "chmod 666 /boot/modem_fs*"
    log "NV storage copied. Rebooting for modem auto-connect..."
    SSHPASS="$SSH_PASS" sshpass -e ssh $SSH_OPTS "root@$DONGLE_IP" "reboot" 2>/dev/null || true

    sleep 60
    log "Waiting for LTE auto-connect (60s)..."
    sleep 60

    if SSHPASS="$SSH_PASS" sshpass -e ssh $SSH_OPTS "root@$DONGLE_IP" \
        "ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1 && echo LTE_OK" 2>/dev/null | grep -q "LTE_OK"; then
        log "LTE data verified!"
    else
        warn "LTE not yet connected. Check: ssh root@$DONGLE_IP mmcli -m 0"
    fi
else
    warn "sshpass not installed or SSH not reachable."
    warn "Copy modem NV storage manually:"
    warn "  scp $RESTORE_DIR/modemst1.bin root@$DONGLE_IP:/boot/modem_fs1"
    warn "  scp $RESTORE_DIR/modemst2.bin root@$DONGLE_IP:/boot/modem_fs2"
    warn "  scp $RESTORE_DIR/fsg.bin root@$DONGLE_IP:/boot/modem_fsg"
fi

echo ""
log "OpenStick flash complete!"
log "Modem calibration backup: $RESTORE_DIR"
log "Keep this backup safe — it contains your device's unique IMEI + RF data."
echo ""
log "Verify with: bash test-dongle.sh"
