#!/bin/bash -e
#
# flash-openstick.sh — Flash OpenStick Debian onto a JZ0145-v33 UFI 4G USB dongle
#
# Prerequisites:
#   - edl tool installed: pip install edl (or pipx install edlclient)
#   - fastboot installed: apt install fastboot
#   - adb installed: apt install adb
#   - Device connected and visible via ADB (stock Android running)
#   - All required files in the flash/files/ directory
#
# Usage:
#   cd flash && bash flash-openstick.sh
#
# This script follows the proven flash sequence for JZ02/JZ0145-v33 boards:
#   1. Stock aboot loads Dragonboard aboot via EDL
#   2. Dragonboard aboot provides fastboot
#   3. Fastboot flashes new GPT + Dragonboard firmware + OpenStick boot/rootfs
#   4. Modem calibration data restored from backup
#
# IMPORTANT: A full backup must exist in ../backup/partitions/ before running.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"
BACKUP_DIR="$SCRIPT_DIR/../backup/partitions"

# Required flash files
REQUIRED_FILES=(
    "$FILES_DIR/emmc_appsboot-test-signed.mbn"
    "$FILES_DIR/gpt_both0.bin"
    "$FILES_DIR/sbl1.mbn"
    "$FILES_DIR/rpm.mbn"
    "$FILES_DIR/tz.mbn"
    "$FILES_DIR/qhypstub-test-signed.mbn"
    "$FILES_DIR/sbc_1.0_8016.bin"
    "$FILES_DIR/boot-ufi001c.img"
    "$FILES_DIR/rootfs.img"
)

# Required backup files (modem calibration)
REQUIRED_BACKUP=(
    "$BACKUP_DIR/sec.bin"
    "$BACKUP_DIR/fsc.bin"
    "$BACKUP_DIR/fsg.bin"
    "$BACKUP_DIR/modemst1.bin"
    "$BACKUP_DIR/modemst2.bin"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

# ─── Preflight checks ───────────────────────────────────────────────────────

log "Checking required files..."
for f in "${REQUIRED_FILES[@]}"; do
    [ -f "$f" ] || err "Missing: $f"
done
for f in "${REQUIRED_BACKUP[@]}"; do
    [ -f "$f" ] || err "Missing backup: $f (run Phase 1 backup first)"
done
log "All files present."

which edl >/dev/null 2>&1   || err "edl not found. Install: pipx install edlclient"
which fastboot >/dev/null 2>&1 || err "fastboot not found. Install: apt install fastboot"
which adb >/dev/null 2>&1   || err "adb not found. Install: apt install adb"

# ─── Step 1: Enter EDL mode ─────────────────────────────────────────────────

log "Checking device state..."
if adb devices 2>/dev/null | grep -q "device$"; then
    log "Device in ADB mode — rebooting to EDL..."
    adb reboot edl
    sleep 5
elif lsusb 2>/dev/null | grep -q "05c6:9008"; then
    log "Device already in EDL mode."
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

# ─── Step 2: Flash Dragonboard aboot + erase boot via EDL ───────────────────

log "Flashing Dragonboard aboot to aboot partition..."
edl w aboot "$FILES_DIR/emmc_appsboot-test-signed.mbn" 2>&1 | tail -1

log "Erasing boot partition (forces fastboot on next boot)..."
edl e boot 2>&1 | tail -3

log "Resetting device..."
edl reset 2>&1 | tail -1 || true
sleep 2

# ─── Step 3: Wait for fastboot ──────────────────────────────────────────────

log "Waiting for fastboot..."
for i in $(seq 1 30); do
    fastboot devices 2>/dev/null | grep -q "fastboot" && break
    sleep 2
done
fastboot devices 2>/dev/null | grep -q "fastboot" || err "Fastboot not found after 60s"
log "Fastboot connected: $(fastboot devices 2>/dev/null | head -1)"

# ─── Step 4: Flash everything via fastboot ───────────────────────────────────

log "Flashing partition table..."
fastboot flash partition "$FILES_DIR/gpt_both0.bin"

log "Flashing Dragonboard firmware..."
fastboot flash aboot "$FILES_DIR/emmc_appsboot-test-signed.mbn"
fastboot flash hyp   "$FILES_DIR/qhypstub-test-signed.mbn"
fastboot flash rpm   "$FILES_DIR/rpm.mbn"
fastboot flash sbl1  "$FILES_DIR/sbl1.mbn"
fastboot flash tz    "$FILES_DIR/tz.mbn"
fastboot flash cdt   "$FILES_DIR/sbc_1.0_8016.bin"

log "Flashing OpenStick boot image..."
fastboot flash boot  "$FILES_DIR/boot-ufi001c.img"

log "Flashing Debian rootfs (this takes 2-5 minutes)..."
fastboot flash rootfs "$FILES_DIR/rootfs.img"

# ─── Step 5: Restore modem calibration data ──────────────────────────────────

log "Restoring modem calibration data from backup..."
fastboot flash sec      "$BACKUP_DIR/sec.bin"
fastboot flash fsc      "$BACKUP_DIR/fsc.bin"
fastboot flash fsg      "$BACKUP_DIR/fsg.bin"
fastboot flash modemst1 "$BACKUP_DIR/modemst1.bin"
fastboot flash modemst2 "$BACKUP_DIR/modemst2.bin"

# ─── Step 6: Reboot ─────────────────────────────────────────────────────────

log "Rebooting..."
fastboot reboot

log "Waiting for device to boot (30s)..."
sleep 30

# Check if ADB appears
if adb devices 2>/dev/null | grep -q "device$"; then
    log "Device booted! ADB connected."
    echo ""
    adb shell uname -a
    adb shell cat /etc/os-release | head -3
    echo ""
    log "OpenStick flash complete!"
    log "Default root password needs to be set. Run configure-dongle.sh next."
else
    warn "ADB not detected after 30s. The device may need more time to boot."
    warn "Check: lsusb | grep 05c6"
    warn "       adb devices"
fi
