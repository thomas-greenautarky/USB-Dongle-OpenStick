#!/bin/bash -e
#
# flash-uz801.sh — Flash OpenStick Debian onto UZ801 (and compatible) USB dongles
#
# Based on the flash method from kinsamanka/OpenStick-Builder:
#   https://github.com/kinsamanka/OpenStick-Builder
#
# KEY INSIGHT: UZ801 EDL supports only ONE command per session. After each EDL
# command the dongle must be re-plugged. Therefore we use EDL only minimally:
#   - EDL: backup NV storage + write lk2nd as aboot + erase boot + reset
#   - Fastboot (via lk2nd): flash everything else (GPT, firmware, boot, rootfs)
#
# This approach is based on OpenStick issue #91 which documented the single-command
# EDL limitation: https://github.com/OpenStick/OpenStick/issues/91
#
# Flow:
#   1. Detect dongle state (Stock Android / EDL / Fastboot)
#   2. If Stock Android: enable ADB via web API, backup firmware files, adb reboot edl
#   3. In EDL: backup NV storage (verified), backup stock partitions
#   4. In EDL: write lk2nd as aboot (single write), erase boot, reset
#   5. Dongle reboots into lk2nd Fastboot (18d1:d00d)
#   6. Via Fastboot: flash GPT, firmware, boot, rootfs, modem, NV storage
#   7. Reboot and verify
#
# Supports two dongle types:
#   - UZ801 v3 (Stock Android 05c6:f00e) — auto-detected, ADB→EDL→Fastboot
#   - JZ0145-v33 (EDL only 05c6:9008) — use flash-openstick.sh instead
#
# Prerequisites:
#   - edl: pipx install edlclient
#   - fastboot: apt install fastboot (or android-sdk-platform-tools)
#   - adb: apt install adb
#   - sgdisk: apt install gdisk
#   - mtools: apt install mtools (for modem vfat partition)
#   - curl, sshpass
#   - Prebuilt files in flash/files/uz801/ (from OpenStick-Builder or custom build)
#
# Usage:
#   bash flash-uz801.sh                    # interactive
#   bash flash-uz801.sh --skip-backup      # skip partition backup (dangerous!)
#   bash flash-uz801.sh --restore <dir>    # restore from backup

export PATH="$HOME/.local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files/uz801"
LOG_DIR="$SCRIPT_DIR/../logs"
BACKUP_BASE="$SCRIPT_DIR/../backup"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

# ─── Parse arguments ────────────────────────────────────────────────────────

SKIP_BACKUP=false
RESTORE_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-backup)  SKIP_BACKUP=true; shift ;;
        --restore)      RESTORE_DIR="$2"; shift 2 ;;
        *) err "Unknown option: $1" ;;
    esac
done

# ─── Restore mode ───────────────────────────────────────────────────────────

if [ -n "$RESTORE_DIR" ]; then
    log "=== Restore Mode ==="
    [ -d "$RESTORE_DIR" ] || err "Backup directory not found: $RESTORE_DIR"
    log "Restoring from: $RESTORE_DIR"
    bash "$SCRIPT_DIR/restore-dongle.sh" "$RESTORE_DIR"
    exit $?
fi

# ─── Preflight checks ──────────────────────────────────────────────────────

REQUIRED_FILES=(
    "$FILES_DIR/aboot.mbn"
    "$FILES_DIR/hyp.mbn"
    "$FILES_DIR/sbl1.mbn"
    "$FILES_DIR/rpm.mbn"
    "$FILES_DIR/tz.mbn"
    "$FILES_DIR/boot.bin"
)

# rootfs: prefer our custom rootfs, fall back to prebuilt
if [ -f "$SCRIPT_DIR/files/rootfs.raw" ]; then
    ROOTFS_FILE="$SCRIPT_DIR/files/rootfs.raw"
elif [ -f "$FILES_DIR/rootfs.bin" ]; then
    ROOTFS_FILE="$FILES_DIR/rootfs.bin"
else
    err "No rootfs found. Build one or download prebuilt."
fi

log "Checking required files..."
for f in "${REQUIRED_FILES[@]}"; do
    [ -f "$f" ] || err "Missing: $f"
done
log "All files present. Rootfs: $ROOTFS_FILE"

which edl >/dev/null 2>&1      || err "edl not found. Install: pipx install edlclient"
which fastboot >/dev/null 2>&1  || err "fastboot not found. Install: apt install fastboot"
which adb >/dev/null 2>&1      || warn "adb not found (needed for Stock Android dongles)"
which sgdisk >/dev/null 2>&1   || err "sgdisk not found. Install: apt install gdisk"

# ─── Logging ────────────────────────────────────────────────────────────────

mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/flash_uz801_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1
log "Logging to: $LOGFILE"

# ─── Step 1: Detect dongle state ───────────────────────────────────────────

log "=== Step 1: Detect dongle ==="

DONGLE_STATE="unknown"
DONGLE_IMEI=""
BACKUP_DIR=""

if lsusb 2>/dev/null | grep -q "05c6:9008"; then
    DONGLE_STATE="edl"
    log "Dongle in EDL mode (05c6:9008)"
elif lsusb 2>/dev/null | grep -q "18d1:d00d"; then
    DONGLE_STATE="fastboot"
    log "Dongle in Fastboot/lk2nd mode (18d1:d00d)"
elif lsusb 2>/dev/null | grep -q "05c6:f00e\|05c6:90b6"; then
    DONGLE_STATE="android"
    log "Dongle in Stock Android mode"
else
    warn "No dongle detected. Please plug in a dongle."
    echo -n "Press Enter when dongle is connected..."
    read -r
    if lsusb 2>/dev/null | grep -q "05c6:9008"; then
        DONGLE_STATE="edl"
    elif lsusb 2>/dev/null | grep -q "05c6:f00e\|05c6:90b6"; then
        DONGLE_STATE="android"
    elif lsusb 2>/dev/null | grep -q "18d1:d00d"; then
        DONGLE_STATE="fastboot"
    else
        err "No supported dongle detected."
    fi
fi

# ─── Step 2: If Stock Android, enable ADB and backup firmware files ────────

if [ "$DONGLE_STATE" = "android" ]; then
    log "=== Step 2: Stock Android → ADB → Backup ==="

    # Find web interface by trying API login on known dongle IPs
    DONGLE_WEB=""
    log "  Waiting for dongle web interface..."
    for attempt in $(seq 1 20); do
        for ip in 192.168.100.1 192.168.0.1; do
            RESULT=$(curl -s --connect-timeout 2 --max-time 5 "http://$ip:80/ajax" \
                -d '{"funcNo":1000,"username":"admin","password":"admin"}' 2>/dev/null)
            if echo "$RESULT" | grep -q '"flag":"1"'; then
                DONGLE_WEB="$ip"
                break 2
            fi
        done
        sleep 3
    done

    [ -n "$DONGLE_WEB" ] || err "Cannot reach dongle web interface after 60s."
    log "  Web interface: http://$DONGLE_WEB"

    # Reuse the login result from detection
    LOGIN_RESULT="$RESULT"
    DONGLE_IMEI=$(echo "$LOGIN_RESULT" | grep -oP '"imei":"[^"]*"' | cut -d'"' -f4)
    [ -n "$DONGLE_IMEI" ] || err "IMEI not found in web API response."
    log "  IMEI: $DONGLE_IMEI"
    log "  Firmware: $(echo "$LOGIN_RESULT" | grep -oP '"fwversion":"[^"]*"' | cut -d'"' -f4)"

    # Enable ADB
    log "  Enabling ADB via /usbdebug.html (funcNo:2001)..."
    curl -s --connect-timeout 5 --max-time 10 "http://$DONGLE_WEB:80/ajax" -d '{"funcNo":2001}' >/dev/null 2>&1 || true
    log "  Waiting for ADB..."
    sleep 5

    # Verify ADB
    if ! adb devices 2>/dev/null | grep -q "device$"; then
        warn "ADB not detected after enable. Waiting 10s..."
        sleep 10
    fi
    adb devices 2>/dev/null | grep -q "device$" || err "ADB not available."
    log "  ADB connected."

    # Backup
    if ! $SKIP_BACKUP; then
        BACKUP_DIR="$BACKUP_BASE/stock_uz801_${DONGLE_IMEI}_$(date +%Y%m%d)"
        mkdir -p "$BACKUP_DIR"
        log "  Backing up to: $BACKUP_DIR"

        # Device info
        {
            echo "IMEI: $DONGLE_IMEI"
            echo "Date: $(date -Iseconds)"
            echo "Firmware: $(echo "$LOGIN_RESULT" | grep -oP '"fwversion":"[^"]*"' | cut -d'"' -f4)"
            echo ""
            echo "=== Partitions ==="
            adb shell "ls -la /dev/block/bootdevice/by-name/" 2>/dev/null
            echo ""
            echo "=== Properties ==="
            adb shell "getprop ro.product.model; getprop ro.build.display.id; getprop ro.board.platform" 2>/dev/null
        } > "$BACKUP_DIR/device_info.txt" 2>&1

        # NOTE: Partition backups are done via EDL in Step 3 (ADB dd is unreliable)
        log "  Partition backups will be done via EDL (more reliable than ADB)"

        # Modem firmware as individual files via adb pull
        log "  Backing up modem firmware files..."
        MODEM_FW_DIR="$BACKUP_DIR/modem_firmware"
        mkdir -p "$MODEM_FW_DIR"
        adb shell "mount -o ro /dev/block/bootdevice/by-name/modem /firmware 2>/dev/null; ls /firmware/image/ 2>/dev/null" | tr -d '\r' | while read -r f; do
            [ -n "$f" ] && adb pull "/firmware/image/$f" "$MODEM_FW_DIR/$f" >/dev/null 2>&1
        done
        FW_COUNT=$(ls "$MODEM_FW_DIR" 2>/dev/null | wc -l)
        log "  Modem firmware: $FW_COUNT files"

        log "  Backup saved: $BACKUP_DIR"
    else
        warn "  Skipping backup (--skip-backup)"
    fi

    # Reboot to EDL
    log "  Rebooting to EDL..."
    adb reboot edl 2>/dev/null
    sleep 5

    DONGLE_STATE="edl"
fi

# ─── Step 3: EDL phase (backup + write aboot only) ─────────────────────────

if [ "$DONGLE_STATE" = "edl" ]; then
    log "Waiting for EDL device (05c6:9008)..."
    for i in $(seq 1 30); do
        lsusb 2>/dev/null | grep -q "05c6:9008" && break
        sleep 2
    done
    lsusb 2>/dev/null | grep -q "05c6:9008" || err "EDL device not found."
    log "EDL device detected."

    # Read disk geometry
    log "=== Step 3a: Read disk geometry ==="
    DISK_INFO=$(timeout 15 edl printgpt 2>&1 | grep -i "Total disk size" || true)
    TOTAL_SECTORS=$(echo "$DISK_INFO" | grep -oP 'sectors:0x\K[0-9a-fA-F]+' | head -1)
    if [ -n "$TOTAL_SECTORS" ]; then
        TOTAL_SECTORS_DEC=$((16#$TOTAL_SECTORS))
        DISK_SIZE_MB=$((TOTAL_SECTORS_DEC * 512 / 1024 / 1024))
        log "  Disk: ${DISK_SIZE_MB} MB ($TOTAL_SECTORS_DEC sectors)"
    else
        warn "Could not read disk size. Using 3.6 GB default."
        TOTAL_SECTORS_DEC=7634944
    fi

    # NV backup via EDL (verified, always)
    if ! $SKIP_BACKUP; then
        log "=== Step 3b: EDL Backup (NV storage) ==="
        if [ -z "$BACKUP_DIR" ]; then
            BACKUP_DIR="$BACKUP_BASE/edl_backup_$(date +%Y%m%d_%H%M%S)"
        fi
        mkdir -p "$BACKUP_DIR"

        NV_PARTS="sec fsc fsg modemst1 modemst2"
        NV_OK=0
        NV_TOTAL=0
        for part in $NV_PARTS; do
            NV_TOTAL=$((NV_TOTAL + 1))
            log "  Reading $part via EDL..."
            if edl r "$part" "$BACKUP_DIR/${part}.bin" 2>&1 | grep -q "Read \|Dumped"; then
                SIZE=$(du -h "$BACKUP_DIR/${part}.bin" | cut -f1)
                # Verify: read back and compare
                edl r "$part" "$BACKUP_DIR/${part}.verify" 2>&1 >/dev/null
                if [ -f "$BACKUP_DIR/${part}.verify" ] && cmp -s "$BACKUP_DIR/${part}.bin" "$BACKUP_DIR/${part}.verify"; then
                    log "    $part: $SIZE (verified ✓)"
                    NV_OK=$((NV_OK + 1))
                else
                    warn "    $part: $SIZE (verify FAILED)"
                fi
                rm -f "$BACKUP_DIR/${part}.verify"
            else
                warn "    $part: read failed"
            fi
        done

        if [ "$NV_OK" -eq "$NV_TOTAL" ]; then
            log "  NV backup complete: $NV_OK/$NV_TOTAL partitions verified ✓"
        else
            warn "  NV backup incomplete: $NV_OK/$NV_TOTAL verified"
            echo -ne "${YELLOW}[!]${NC} Continue? IMEI may be lost if NV backup is bad. [y/N] "
            read -r CONTINUE
            [ "$CONTINUE" = "y" ] || [ "$CONTINUE" = "Y" ] || err "Aborted."
        fi

        # Stock partition backup (non-critical, for full restore)
        log "  Backing up stock partitions via EDL..."
        STOCK_DIR="$BACKUP_DIR/stock_partitions"
        mkdir -p "$STOCK_DIR"
        edl rs 0 40 "$STOCK_DIR/gpt.bin" 2>&1 >/dev/null && log "    gpt ✓" || true
        STOCK_PARTS="sbl1 sbl1bak aboot abootbak rpm rpmbak tz tzbak hyp hypbak pad modem DDR splash ssd misc boot recovery persist"
        STOCK_COUNT=0
        for part in $STOCK_PARTS; do
            echo -n "    $part... "
            if edl r "$part" "$STOCK_DIR/${part}.bin" 2>&1 | grep -q "Read \|Dumped"; then
                echo "$(du -h "$STOCK_DIR/${part}.bin" | cut -f1) ✓"
                STOCK_COUNT=$((STOCK_COUNT + 1))
            else
                echo "skip"
                rm -f "$STOCK_DIR/${part}.bin"
            fi
        done
        log "  Stock backup: $STOCK_COUNT partitions"
    fi

    # Write lk2nd as aboot via EDL (single command — UZ801 EDL limitation)
    log "=== Step 3c: Write lk2nd as aboot via EDL ==="
    log "  NOTE: UZ801 EDL supports only ~1 command per session."
    log "  Writing aboot only, rest via Fastboot."
    edl w aboot "$FILES_DIR/aboot.mbn" 2>&1 | tail -1

    # Erase boot partition so lk2nd falls to Fastboot mode
    log "  Erasing boot partition..."
    edl e boot 2>&1 | tail -1 || true

    # Reset to boot into lk2nd Fastboot
    log "  Resetting device..."
    edl reset 2>&1 | tail -1 || true

    DONGLE_STATE="fastboot"
fi

# ─── Step 4: Wait for Fastboot (lk2nd) ─────────────────────────────────────

log "=== Step 4: Waiting for Fastboot (lk2nd) ==="
log "  If dongle doesn't appear: unplug and re-plug (without reset pin)"
for i in $(seq 1 30); do
    lsusb 2>/dev/null | grep -q "18d1:d00d" && break
    sleep 2
done

if ! lsusb 2>/dev/null | grep -q "18d1:d00d"; then
    warn "Fastboot not detected. Unplug and re-plug the dongle."
    echo -ne "${GREEN}[+]${NC} Press Enter after re-plugging..."
    read -r
    for i in $(seq 1 15); do
        lsusb 2>/dev/null | grep -q "18d1:d00d" && break
        sleep 2
    done
fi

lsusb 2>/dev/null | grep -q "18d1:d00d" || err "Fastboot device not found."
log "Fastboot device detected!"

# Wait for fastboot to stabilize
sleep 2
fastboot devices 2>/dev/null | grep -q fastboot || err "Fastboot not responding."

# ─── Step 5: Generate GPT ──────────────────────────────────────────────────

log "=== Step 5: Generate GPT ==="

# Calculate modem partition size from firmware files
MODEM_START=150566
MODEM_END=282137  # default
MODEM_FW_DIR="${BACKUP_DIR:-}/modem_firmware"
if [ -d "$MODEM_FW_DIR" ] && [ "$(ls "$MODEM_FW_DIR" 2>/dev/null | wc -l)" -gt 0 ]; then
    # Estimate: sum of all firmware files + 20% overhead for FAT
    FW_TOTAL=$(du -sb "$MODEM_FW_DIR" 2>/dev/null | cut -f1)
    FW_SECTORS=$(( (FW_TOTAL * 120 / 100 + 511) / 512 ))
    if [ "$FW_SECTORS" -gt 131072 ]; then
        MODEM_END=$(( MODEM_START + FW_SECTORS - 1 ))
        log "  Modem partition sized to firmware: $FW_SECTORS sectors"
    fi
fi
PERSIST_START=$(( MODEM_END + 1 ))

GPT_IMG=$(mktemp)
truncate -s $((TOTAL_SECTORS_DEC * 512)) "$GPT_IMG"
sgdisk --zap-all "$GPT_IMG" >/dev/null 2>&1

ROOTFS_PARTUUID="a7ab80e8-e9d1-e8cd-f157-93f69b1d141e"

sgdisk -a 1 \
    -n 1:131072:131075        -c 1:cdt       -t 1:a01b \
    -n 2:131076:132099        -c 2:sbl1      -t 2:a012 \
    -n 3:132100:133123        -c 3:rpm       -t 3:a018 \
    -n 4:133124:135171        -c 4:tz        -t 4:a016 \
    -n 5:135172:136195        -c 5:hyp       -t 5:a017 \
    -n 6:136196:136227        -c 6:sec       -t 6:a01d \
    -n 7:136228:140323        -c 7:modemst1  -t 7:a027 \
    -n 8:140324:144419        -c 8:modemst2  -t 8:a028 \
    -n 9:144420:144421        -c 9:fsc       -t 9:a029 \
    -n 10:144422:148517       -c 10:fsg      -t 10:a02a \
    -n 11:148518:150565       -c 11:aboot    -t 11:a015 \
    -n 12:${MODEM_START}:${MODEM_END}  -c 12:modem    -t 12:0700 \
    -n 13:${PERSIST_START}:347173      -c 13:persist  -t 13:0700 \
    -n 14:347174:478245       -c 14:boot     -t 14:a036 \
    -n 15:478246:0            -c 15:rootfs   -t 15:8300 \
    -u 15:"$ROOTFS_PARTUUID" \
    "$GPT_IMG" >/dev/null 2>&1 || err "GPT generation failed"

LAST_USABLE=$((TOTAL_SECTORS_DEC - 34))
log "  GPT: 15 partitions, rootfs ends at sector $LAST_USABLE"

# Extract GPT for fastboot (gpt_both0 format = primary + backup combined)
dd if="$GPT_IMG" of="$GPT_IMG.gpt" bs=512 count=34 2>/dev/null

# ─── Step 6: Flash everything via Fastboot ──────────────────────────────────

log "=== Step 6: Flash via Fastboot ==="

log "  GPT..."
fastboot flash partition "$GPT_IMG.gpt" 2>&1 | tail -1

log "  Firmware (aboot, hyp, sbl1, rpm, tz)..."
fastboot flash aboot "$FILES_DIR/aboot.mbn" 2>&1 | tail -1
fastboot flash hyp   "$FILES_DIR/hyp.mbn"   2>&1 | tail -1
fastboot flash sbl1  "$FILES_DIR/sbl1.mbn"  2>&1 | tail -1
fastboot flash rpm   "$FILES_DIR/rpm.mbn"   2>&1 | tail -1
fastboot flash tz    "$FILES_DIR/tz.mbn"    2>&1 | tail -1
[ -f "$FILES_DIR/sbc_1.0_8016.bin" ] && fastboot flash cdt "$FILES_DIR/sbc_1.0_8016.bin" 2>&1 | tail -1

log "  Boot partition (kernel + DTBs)..."
fastboot flash boot "$FILES_DIR/boot.bin" 2>&1 | tail -1

log "  Rootfs (this may take a few minutes)..."
fastboot flash rootfs "$ROOTFS_FILE" 2>&1 | tail -1

# Create modem vfat partition with firmware files
MODEM_FW_DIR="${BACKUP_DIR:-}/modem_firmware"
if [ -d "$MODEM_FW_DIR" ] && [ "$(ls "$MODEM_FW_DIR" 2>/dev/null | wc -l)" -gt 0 ]; then
    log "  Modem firmware partition ($(ls "$MODEM_FW_DIR" | wc -l) files)..."
    MODEM_VFAT=$(mktemp)
    MODEM_SECTORS=$((MODEM_END - MODEM_START + 1))
    dd if=/dev/zero of="$MODEM_VFAT" bs=512 count=$MODEM_SECTORS 2>/dev/null
    mkfs.vfat -n "NON-HLOS" "$MODEM_VFAT" >/dev/null 2>&1
    if which mcopy >/dev/null 2>&1; then
        mmd -i "$MODEM_VFAT" ::/image 2>/dev/null
        mcopy -i "$MODEM_VFAT" "$MODEM_FW_DIR"/* ::/image/ 2>/dev/null
    else
        warn "  mtools not installed — using Docker fallback"
        docker run --rm --privileged -v "$MODEM_FW_DIR":/fw -v "$MODEM_VFAT":/tmp/vfat.img alpine sh -c "
            mount -o loop /tmp/vfat.img /mnt && mkdir -p /mnt/image &&
            cp /fw/* /mnt/image/ && umount /mnt" 2>/dev/null
    fi
    fastboot flash modem "$MODEM_VFAT" 2>&1 | tail -1
    rm -f "$MODEM_VFAT"
fi

# Restore NV storage
if [ -n "$BACKUP_DIR" ] && [ -f "$BACKUP_DIR/modemst1.bin" ] && [ "$(stat -c%s "$BACKUP_DIR/modemst1.bin")" -gt 1024 ]; then
    log "  Restoring NV storage..."
    for part in sec fsc fsg modemst1 modemst2; do
        [ -f "$BACKUP_DIR/${part}.bin" ] && fastboot flash "$part" "$BACKUP_DIR/${part}.bin" 2>&1 | tail -1
    done
    log "  NV storage restored."
else
    warn "  No valid NV backup — modem IMEI may be missing"
fi

rm -f "$GPT_IMG" "$GPT_IMG.gpt"

# ─── Step 7: Reboot and verify ─────────────────────────────────────────────

log "=== Step 7: Reboot ==="
fastboot reboot 2>&1 | tail -1 || true

log "Waiting for device to boot (90s)..."
BOOTED=false
for i in $(seq 1 18); do
    sleep 5
    if lsusb 2>/dev/null | grep -q "1d6b:0104"; then
        log "RNDIS USB gadget detected after $((i*5))s!"
        BOOTED=true
        break
    fi
    if lsusb 2>/dev/null | grep -q "18d1:d00d"; then
        warn "Still in Fastboot — kernel may not have loaded."
        break
    fi
done

if $BOOTED; then
    log "Device booted! Waiting for SSH..."
    DONGLE_SSH_IP="192.168.68.1"
    SSH_OPTS_FW="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
    SSH_PASS_FW="openstick"

    for i in $(seq 1 12); do
        if SSHPASS="$SSH_PASS_FW" sshpass -e ssh $SSH_OPTS_FW "root@$DONGLE_SSH_IP" "echo OK" 2>/dev/null | grep -q OK; then
            log "SSH connected."
            break
        fi
        sleep 5
    done

    # Copy modem firmware files to /lib/firmware/
    MODEM_FW_DIR="${BACKUP_DIR:-}/modem_firmware"
    if [ -d "$MODEM_FW_DIR" ] && [ "$(ls "$MODEM_FW_DIR" 2>/dev/null | wc -l)" -gt 0 ]; then
        log "Copying modem firmware to dongle..."
        for fw in "$MODEM_FW_DIR"/*; do
            [ -f "$fw" ] && SSHPASS="$SSH_PASS_FW" sshpass -e scp $SSH_OPTS_FW "$fw" "root@$DONGLE_SSH_IP:/lib/firmware/" 2>/dev/null
        done
        log "  Copied $(ls "$MODEM_FW_DIR" -1 2>/dev/null | wc -l) firmware files"

        # Copy NV storage to /boot
        log "Copying NV storage to /boot..."
        SSHPASS="$SSH_PASS_FW" sshpass -e ssh $SSH_OPTS_FW "root@$DONGLE_SSH_IP" "
            dd if=/dev/mmcblk0p7 of=/boot/modem_fs1 bs=1M 2>/dev/null
            dd if=/dev/mmcblk0p8 of=/boot/modem_fs2 bs=1M 2>/dev/null
            dd if=/dev/mmcblk0p10 of=/boot/modem_fsg bs=1M 2>/dev/null
            chmod 666 /boot/modem_fs*
        " 2>/dev/null
        log "  NV storage copied."

        # Reboot for modem to pick up firmware
        log "Rebooting for modem init..."
        SSHPASS="$SSH_PASS_FW" sshpass -e ssh $SSH_OPTS_FW "root@$DONGLE_SSH_IP" "reboot" 2>/dev/null || true
        sleep 30
        for i in $(seq 1 12); do
            SSHPASS="$SSH_PASS_FW" sshpass -e ssh $SSH_OPTS_FW "root@$DONGLE_SSH_IP" "echo OK" 2>/dev/null | grep -q OK && break
            sleep 5
        done
        log "Dongle back after reboot."
    fi

    if ping -c 1 -W 5 "$DONGLE_SSH_IP" >/dev/null 2>&1; then
        log "Dongle reachable at $DONGLE_SSH_IP"
    else
        warn "Dongle not reachable at $DONGLE_SSH_IP"
    fi
else
    warn "Device did not boot. Try unplugging and re-plugging."
fi

echo ""
log "═══════════════════════════════════════"
log "  Flash complete!"
log "  IMEI:    ${DONGLE_IMEI:-unknown}"
log "  Rootfs:  $ROOTFS_FILE"
log "  Backup:  ${BACKUP_DIR:-none}"
log "  Log:     $LOGFILE"
log "═══════════════════════════════════════"
