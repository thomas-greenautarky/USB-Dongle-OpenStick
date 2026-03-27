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
#   2. Write split GPT (primary at sector 0, backup at end of disk)
#   3. Flash Dragonboard firmware (sbl1, rpm, tz, qhypstub, cdt, aboot)
#   4. Flash boot-jz0145.img (kernel with JZ0145-v33 DTB baked in)
#   5. Flash rootfs.raw (Debian)
#   6. Restore modem calibration from backup (sec, fsc, fsg, modemst1, modemst2)
#   7. Reset → Debian boots
#
# IMPORTANT: A full backup must exist in ../backup/partitions/ before running.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"
BACKUP_DIR="$SCRIPT_DIR/../backup/partitions"

# Backup GPT sector for 4GB eMMC (end of disk)
BACKUP_GPT_SECTOR=7733215

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
    "$FILES_DIR/boot-jz0145.img"
    "$FILES_DIR/rootfs.raw"
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

# ─── Step 2: Write split GPT via EDL ────────────────────────────────────────
# The GPT must be written as two separate files:
#   - gpt_primary_proper.bin at sector 0
#   - gpt_backup_proper.bin at the end of disk
#
# The original gpt_both0.bin has bugs: rootfs is 1MB placeholder, backup GPT
# at wrong sector via EDL. The proper files have correct rootfs (3.6GB),
# correct alternate_lba, and correct backup header.

log "Writing primary GPT (sector 0)..."
edl ws 0 "$FILES_DIR/gpt_primary_proper.bin"

log "Writing backup GPT (sector $BACKUP_GPT_SECTOR)..."
edl ws "$BACKUP_GPT_SECTOR" "$FILES_DIR/gpt_backup_proper.bin"

# ─── Step 3: Flash Dragonboard firmware via EDL ─────────────────────────────

log "Flashing Dragonboard firmware..."
edl w sbl1  "$FILES_DIR/sbl1.mbn"
edl w rpm   "$FILES_DIR/rpm.mbn"
edl w tz    "$FILES_DIR/tz.mbn"
edl w hyp   "$FILES_DIR/qhypstub-test-signed.mbn"
edl w cdt   "$FILES_DIR/sbc_1.0_8016.bin"
edl w aboot "$FILES_DIR/emmc_appsboot-test-signed.mbn"

# ─── Step 4: Flash boot image + rootfs via EDL ──────────────────────────────

log "Flashing boot image (boot-jz0145.img with JZ0145-v33 DTB)..."
edl w boot "$FILES_DIR/boot-jz0145.img"

log "Flashing Debian rootfs (this takes 2-5 minutes)..."
edl w rootfs "$FILES_DIR/rootfs.raw"

# ─── Step 5: Restore modem calibration data via EDL ─────────────────────────

log "Restoring modem calibration data from backup..."
edl w sec      "$BACKUP_DIR/sec.bin"
edl w fsc      "$BACKUP_DIR/fsc.bin"
edl w fsg      "$BACKUP_DIR/fsg.bin"
edl w modemst1 "$BACKUP_DIR/modemst1.bin"
edl w modemst2 "$BACKUP_DIR/modemst2.bin"

# ─── Step 6: Reset and verify ───────────────────────────────────────────────

log "Resetting device..."
edl reset 2>&1 | tail -1 || true

log "Waiting for device to boot (30s)..."
sleep 30

# Check if ADB appears
if which adb >/dev/null 2>&1 && adb devices 2>/dev/null | grep -q "device$"; then
    log "Device booted! ADB connected."
    echo ""
    adb shell uname -a
    adb shell cat /etc/os-release | head -3
    echo ""
    log "OpenStick flash complete!"
    log "Run configure-dongle.sh next to set up modem firmware, SSH, NAT, etc."
else
    warn "ADB not detected after 30s. The device may need more time to boot."
    warn "Check: lsusb | grep 05c6"
    warn "       adb devices"
    warn ""
    warn "If the device does not boot, re-enter EDL (reset button + USB plug)"
    warn "and try again. EDL mode is always available for recovery."
fi
