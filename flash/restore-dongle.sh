#!/bin/bash -e
#
# restore-dongle.sh — Restore a dongle to its original firmware from backup
#
# Use this when a dongle doesn't boot after flashing. Restores all partitions
# from the auto-backup created during flash-openstick.sh.
#
# Usage:
#   bash restore-dongle.sh <backup-dir>
#   bash restore-dongle.sh ../backup/autosave_20260414_122707
#
# Prerequisites:
#   - Dongle in EDL mode (hold reset button + plug in USB)
#   - edl tool installed: pipx install edlclient

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

BACKUP_DIR="${1:-}"
[ -n "$BACKUP_DIR" ] || err "Usage: bash restore-dongle.sh <backup-dir>"
[ -d "$BACKUP_DIR" ] || err "Backup directory not found: $BACKUP_DIR"

# UZ801 Firehose quirk: must explicitly set memory=emmc to avoid USB Overflow.
# See docs/dongle-compatibility.md § USB-Overflow.
EDL_OPTS=(--memory=emmc)

# All partitions that can be restored
ALL_PARTITIONS=(sbl1 rpm tz hyp cdt aboot boot rootfs sec fsc fsg modemst1 modemst2)

log "Restore from: $BACKUP_DIR"
log "Available partitions:"
RESTORE_COUNT=0
for part in "${ALL_PARTITIONS[@]}"; do
    if [ -f "$BACKUP_DIR/${part}.bin" ]; then
        SIZE=$(du -h "$BACKUP_DIR/${part}.bin" | cut -f1)
        log "  $part ($SIZE)"
        RESTORE_COUNT=$((RESTORE_COUNT + 1))
    fi
done

[ "$RESTORE_COUNT" -gt 0 ] || err "No partition backups found in $BACKUP_DIR"
log "Found $RESTORE_COUNT partitions to restore."

echo ""
warn "This will overwrite the dongle's current firmware!"
echo -ne "${YELLOW}[!]${NC} Continue? [y/N] "
read -r CONTINUE
[ "$CONTINUE" = "y" ] || [ "$CONTINUE" = "Y" ] || err "Aborted by user."

# Check EDL mode
log "Checking for EDL device..."
if ! lsusb 2>/dev/null | grep -q "05c6:9008"; then
    warn "Device not in EDL mode. Please:"
    warn "  1. Unplug the dongle"
    warn "  2. Hold the reset button (pin hole)"
    warn "  3. Plug in while holding reset"
    warn "  4. Hold for 3-5 seconds, then release"
    echo ""
    echo -n "Press Enter when device is in EDL mode..."
    read -r
fi

for i in $(seq 1 15); do
    lsusb 2>/dev/null | grep -q "05c6:9008" && break
    sleep 2
done
lsusb 2>/dev/null | grep -q "05c6:9008" || err "EDL device not found"
log "EDL device detected."

# Restore partitions
log "Restoring partitions..."
FAILED=0
for part in "${ALL_PARTITIONS[@]}"; do
    if [ -f "$BACKUP_DIR/${part}.bin" ]; then
        log "  Writing $part..."
        if ! edl "${EDL_OPTS[@]}" w "$part" "$BACKUP_DIR/${part}.bin" 2>&1 | tail -1; then
            warn "  Failed to write $part"
            FAILED=$((FAILED + 1))
        fi
    fi
done

if [ "$FAILED" -gt 0 ]; then
    warn "$FAILED partitions failed to restore!"
else
    log "All $RESTORE_COUNT partitions restored."
fi

log "Resetting device..."
edl reset 2>&1 | tail -1 || true

echo ""
log "Restore complete. Unplug and re-plug the dongle to boot."
