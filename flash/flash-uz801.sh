#!/bin/bash -e
#
# flash-uz801.sh — Flash OpenStick Debian onto UZ801 (and compatible) USB dongles
#
# Supports dongles running Stock Android (05c6:f00e) or already in EDL (05c6:9008).
# Uses lk2nd as universal bootloader (replaces stock aboot).
#
# Flow:
#   1. Detect dongle state (Stock Android / EDL / Fastboot)
#   2. If Stock Android: enable ADB via web API, backup all partitions, adb reboot edl
#   3. If EDL: backup partitions via edl
#   4. Flash: GPT + firmware + lk2nd (aboot) + boot (kernel+DTBs) + rootfs
#   5. Reset and verify boot
#
# Prerequisites:
#   - edl: pipx install edlclient
#   - adb: apt install adb
#   - sgdisk: apt install gdisk
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
    ROOTFS_FORMAT="raw"
elif [ -f "$FILES_DIR/rootfs.bin" ]; then
    ROOTFS_FILE="$FILES_DIR/rootfs.bin"
    ROOTFS_FORMAT="sparse"
else
    err "No rootfs found. Build one or download prebuilt."
fi

log "Checking required files..."
for f in "${REQUIRED_FILES[@]}"; do
    [ -f "$f" ] || err "Missing: $f"
done
log "All files present. Rootfs: $ROOTFS_FILE ($ROOTFS_FORMAT)"

which edl >/dev/null 2>&1 || err "edl not found. Install: pipx install edlclient"
which adb >/dev/null 2>&1 || warn "adb not found (needed for Stock Android dongles)"
which sgdisk >/dev/null 2>&1 || err "sgdisk not found. Install: apt install gdisk"

# ─── Logging ────────────────────────────────────────────────────────────────

mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/flash_uz801_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1
log "Logging to: $LOGFILE"

# ─── Step 1: Detect dongle state ───────────────────────────────────────────

log "=== Step 1: Detect dongle ==="

DONGLE_STATE="unknown"
DONGLE_IMEI=""

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
    else
        err "No supported dongle detected."
    fi
fi

# ─── Step 2: If Stock Android, enable ADB and backup ───────────────────────

if [ "$DONGLE_STATE" = "android" ]; then
    log "=== Step 2: Stock Android → ADB → Backup ==="

    # Find web interface
    # Find the dongle's web interface by trying the API login on known IPs.
    # Do NOT use ping/gateway detection — it picks up the host's router.
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

    # Login
    # Reuse the login result from the detection loop (already authenticated)
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

        # NOTE: Partition backups (modemst, fsg, etc.) are done via EDL in Step 5
        # (ADB dd over USB is unreliable on Stock Android 4.4)
        log "  Partition backups will be done via EDL (more reliable than ADB)"

        # Modem firmware as individual files (raw partition dump has FAT corruption via ADB dd)
        log "  Backing up modem firmware files..."
        MODEM_FW_DIR="$BACKUP_DIR/modem_firmware"
        mkdir -p "$MODEM_FW_DIR"
        adb shell "mount -o ro /dev/block/bootdevice/by-name/modem /firmware 2>/dev/null; ls /firmware/image/ 2>/dev/null" | tr -d '\r' | while read -r f; do
            [ -n "$f" ] && adb pull "/firmware/image/$f" "$MODEM_FW_DIR/$f" >/dev/null 2>&1
        done
        # Verify firmware files via hash
        FW_COUNT=$(ls "$MODEM_FW_DIR" 2>/dev/null | wc -l)
        if [ "$FW_COUNT" -gt 0 ]; then
            FW_ERRORS=0
            for fw in "$MODEM_FW_DIR"/*; do
                FNAME=$(basename "$fw")
                REMOTE_MD5=$(adb shell "busybox md5sum /firmware/image/$FNAME 2>/dev/null || md5sum /firmware/image/$FNAME 2>/dev/null" | awk '{print $1}' | tr -d '\r')
                LOCAL_MD5=$(md5sum "$fw" 2>/dev/null | awk '{print $1}')
                if [ "$REMOTE_MD5" != "$LOCAL_MD5" ] || [ -z "$REMOTE_MD5" ]; then
                    warn "    $FNAME: hash mismatch"
                    FW_ERRORS=$((FW_ERRORS + 1))
                fi
            done
            [ "$FW_ERRORS" -eq 0 ] && log "  Modem firmware: $FW_COUNT files (all verified)" || warn "  Modem firmware: $FW_COUNT files ($FW_ERRORS hash errors)"
        else
            warn "  No modem firmware files found on /firmware/image/"
        fi

        log "  Backup complete: $(ls "$BACKUP_DIR"/*.bin 2>/dev/null | wc -l) partitions + $FW_COUNT firmware files"
        log "  Restore with: bash flash-uz801.sh --restore $BACKUP_DIR"
    else
        warn "  Skipping backup (--skip-backup)"
    fi

    # Reboot to EDL
    log "  Rebooting to EDL..."
    adb reboot edl 2>/dev/null
    sleep 5

    DONGLE_STATE="edl"
fi

# ─── Step 3: Wait for EDL ──────────────────────────────────────────────────

if [ "$DONGLE_STATE" = "fastboot" ]; then
    log "Rebooting from Fastboot to EDL..."
    fastboot reboot 2>/dev/null || true
    sleep 8
fi

log "Waiting for EDL device (05c6:9008)..."
for i in $(seq 1 30); do
    lsusb 2>/dev/null | grep -q "05c6:9008" && break
    sleep 2
done
lsusb 2>/dev/null | grep -q "05c6:9008" || err "EDL device not found."
log "EDL device detected."

# ─── Step 4: Read disk geometry ─────────────────────────────────────────────

log "=== Step 4: Read disk geometry ==="
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

# ─── Step 5: EDL backup of NV storage (always — ADB dd is unreliable) ──────

if ! $SKIP_BACKUP; then
    log "=== Step 5: EDL Backup (NV storage) ==="
    if [ -z "$BACKUP_DIR" ]; then
        BACKUP_DIR="$BACKUP_BASE/edl_backup_$(date +%Y%m%d_%H%M%S)"
    fi
    mkdir -p "$BACKUP_DIR"

    # Always backup NV partitions via EDL (ADB dd over USB corrupts data)
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
                warn "    $part: $SIZE (verify FAILED — read twice, got different data)"
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
fi

# ─── Step 6: Generate GPT ──────────────────────────────────────────────────

log "=== Step 6: Generate GPT ==="

# Calculate modem partition size dynamically from backup
MODEM_START=150566
MODEM_END=282137  # default: 64.2 MB
if [ -n "$BACKUP_DIR" ] && [ -f "$BACKUP_DIR/modem.bin" ]; then
    MODEM_BYTES=$(stat -c%s "$BACKUP_DIR/modem.bin")
    MODEM_SECTORS=$(( (MODEM_BYTES + 511) / 512 ))  # round up
    MODEM_END=$(( MODEM_START + MODEM_SECTORS - 1 ))
    log "  Modem partition sized to backup: $MODEM_SECTORS sectors ($(( MODEM_BYTES / 1024 / 1024 )) MB)"
fi
PERSIST_START=$(( MODEM_END + 1 ))

# Generate GPT with sgdisk matching the actual disk size
GPT_IMG=$(mktemp)
truncate -s $((TOTAL_SECTORS_DEC * 512)) "$GPT_IMG"
sgdisk --zap-all "$GPT_IMG" >/dev/null 2>&1

# The rootfs partition MUST have PARTUUID a7ab80e8-e9d1-e8cd-f157-93f69b1d141e
# because the prebuilt boot.bin extlinux.conf hardcodes root=PARTUUID=<this value>.
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
BACKUP_GPT_SECTOR=$((TOTAL_SECTORS_DEC - 33))
log "  GPT: 15 partitions, rootfs ends at sector $LAST_USABLE"
log "  Backup GPT at sector $BACKUP_GPT_SECTOR"

# Extract primary + backup GPT
dd if="$GPT_IMG" of="$GPT_IMG.primary" bs=512 count=34 2>/dev/null
dd if="$GPT_IMG" of="$GPT_IMG.backup" bs=512 skip=$((TOTAL_SECTORS_DEC - 33)) count=33 2>/dev/null

# ─── Step 7: Flash everything ──────────────────────────────────────────────

log "=== Step 7: Flash ==="

log "  Primary GPT..."
edl ws 0 "$GPT_IMG.primary" 2>&1 | tail -1

log "  Backup GPT..."
edl ws "$BACKUP_GPT_SECTOR" "$GPT_IMG.backup" 2>&1 | tail -1

log "  Firmware (sbl1, rpm, tz, hyp, cdt)..."
edl w sbl1  "$FILES_DIR/sbl1.mbn"  2>&1 | tail -1
edl w rpm   "$FILES_DIR/rpm.mbn"   2>&1 | tail -1
edl w tz    "$FILES_DIR/tz.mbn"    2>&1 | tail -1
edl w hyp   "$FILES_DIR/hyp.mbn"   2>&1 | tail -1
[ -f "$FILES_DIR/sbc_1.0_8016.bin" ] && edl w cdt "$FILES_DIR/sbc_1.0_8016.bin" 2>&1 | tail -1

log "  Bootloader (lk2nd as aboot)..."
edl w aboot "$FILES_DIR/aboot.mbn" 2>&1 | tail -1

log "  Boot partition (kernel + DTBs)..."
edl w boot  "$FILES_DIR/boot.bin"  2>&1 | tail -1

log "  Rootfs (this takes 2-5 minutes)..."
if [ "$ROOTFS_FORMAT" = "sparse" ]; then
    edl w rootfs "$ROOTFS_FILE" 2>&1 | tail -1
else
    edl w rootfs "$ROOTFS_FILE" 2>&1 | tail -1
fi

# Restore modem firmware + calibration if we have a backup
if [ -n "$BACKUP_DIR" ]; then
    MODEM_FW_DIR="$BACKUP_DIR/modem_firmware"
    if [ -d "$MODEM_FW_DIR" ] && [ "$(ls "$MODEM_FW_DIR" 2>/dev/null | wc -l)" -gt 0 ]; then
        # Create fresh vfat with firmware files (raw modem.bin dump has FAT corruption)
        log "  Creating modem firmware partition ($( ls "$MODEM_FW_DIR" | wc -l) files)..."
        MODEM_VFAT=$(mktemp)
        MODEM_SECTORS=$((MODEM_END - MODEM_START + 1))
        dd if=/dev/zero of="$MODEM_VFAT" bs=512 count=$MODEM_SECTORS 2>/dev/null
        mkfs.vfat -n "NON-HLOS" "$MODEM_VFAT" >/dev/null 2>&1
        # Use mcopy to add files without mounting (no sudo needed)
        if which mcopy >/dev/null 2>&1; then
            mmd -i "$MODEM_VFAT" ::/image 2>/dev/null
            mcopy -i "$MODEM_VFAT" "$MODEM_FW_DIR"/* ::/image/ 2>/dev/null
        else
            # Fallback: use Docker to mount and copy
            docker run --rm --privileged -v "$MODEM_FW_DIR":/fw -v "$MODEM_VFAT":/tmp/vfat.img alpine sh -c "
                mount -o loop /tmp/vfat.img /mnt && mkdir -p /mnt/image &&
                cp /fw/* /mnt/image/ && umount /mnt" 2>/dev/null
        fi
        edl w modem "$MODEM_VFAT" 2>&1 | tail -1
        rm -f "$MODEM_VFAT"
    elif [ -f "$BACKUP_DIR/modem.bin" ]; then
        log "  Restoring modem firmware (raw, 64 MB)..."
        edl w modem "$BACKUP_DIR/modem.bin" 2>&1 | tail -1
    fi
    if [ -f "$BACKUP_DIR/modemst1.bin" ] && [ "$(stat -c%s "$BACKUP_DIR/modemst1.bin")" -gt 1024 ]; then
        log "  Restoring modem calibration..."
        for part in sec fsc fsg modemst1 modemst2; do
            [ -f "$BACKUP_DIR/${part}.bin" ] && edl w "$part" "$BACKUP_DIR/${part}.bin" 2>&1 | tail -1
        done
    else
        warn "  No valid modemst backup — NV storage will be empty (IMEI may be missing)"
    fi
    log "  Modem restored."
fi

rm -f "$GPT_IMG" "$GPT_IMG.primary" "$GPT_IMG.backup"

# ─── Step 8: Reset and verify ──────────────────────────────────────────────

log "=== Step 8: Boot ==="
edl reset 2>&1 | tail -1 || true

log "Waiting for device to boot (90s)..."
BOOTED=false
for i in $(seq 1 18); do
    sleep 5
    if lsusb 2>/dev/null | grep -q "1d6b:0104"; then
        log "RNDIS USB gadget detected after $((i*5))s!"
        BOOTED=true
        break
    fi
    # lk2nd fastboot means boot partition is OK but kernel didn't start
    if lsusb 2>/dev/null | grep -q "18d1:d00d"; then
        warn "Fastboot detected — lk2nd booted but kernel not found."
        warn "The extlinux.conf DTB may need adjustment."
        warn "Connect via: fastboot oem edl → edl → fix extlinux.conf"
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

    # Copy modem firmware files to /lib/firmware/ if we have them
    MODEM_FW_DIR="${BACKUP_DIR:-}/modem_firmware"
    if [ -d "$MODEM_FW_DIR" ] && [ "$(ls "$MODEM_FW_DIR" 2>/dev/null | wc -l)" -gt 0 ]; then
        log "Copying modem firmware to dongle..."
        SSHPASS="$SSH_PASS_FW" sshpass -e ssh $SSH_OPTS_FW "root@$DONGLE_SSH_IP" "mkdir -p /lib/firmware" 2>/dev/null
        for fw in "$MODEM_FW_DIR"/*; do
            SSHPASS="$SSH_PASS_FW" sshpass -e scp $SSH_OPTS_FW "$fw" "root@$DONGLE_SSH_IP:/lib/firmware/" 2>/dev/null
        done
        FW_COPIED=$(ls "$MODEM_FW_DIR" | wc -l)
        log "  Copied $FW_COPIED firmware files to /lib/firmware/"

        # Copy NV storage from partitions to /boot
        log "Copying modem NV storage..."
        SSHPASS="$SSH_PASS_FW" sshpass -e ssh $SSH_OPTS_FW "root@$DONGLE_SSH_IP" "
            dd if=/dev/mmcblk0p7 of=/boot/modem_fs1 bs=1M 2>/dev/null
            dd if=/dev/mmcblk0p8 of=/boot/modem_fs2 bs=1M 2>/dev/null
            dd if=/dev/mmcblk0p10 of=/boot/modem_fsg bs=1M 2>/dev/null
            chmod 666 /boot/modem_fs*
        " 2>/dev/null
        log "  NV storage copied to /boot/"

        # Reboot for modem to pick up firmware
        log "Rebooting dongle for modem init..."
        SSHPASS="$SSH_PASS_FW" sshpass -e ssh $SSH_OPTS_FW "root@$DONGLE_SSH_IP" "reboot" 2>/dev/null || true
        sleep 30
        for i in $(seq 1 12); do
            SSHPASS="$SSH_PASS_FW" sshpass -e ssh $SSH_OPTS_FW "root@$DONGLE_SSH_IP" "echo OK" 2>/dev/null | grep -q OK && break
            sleep 5
        done
        log "Dongle back after reboot."
    else
        warn "No modem firmware files found in backup — IMEI may not work"
    fi

    if ping -c 1 -W 5 "$DONGLE_SSH_IP" >/dev/null 2>&1; then
        log "Dongle reachable at $DONGLE_SSH_IP"
    else
        warn "Dongle not reachable at $DONGLE_SSH_IP"
    fi
elif ! lsusb 2>/dev/null | grep -q "18d1:d00d"; then
    warn "Device not detected after 90s."
    echo ""
    warn "Try:"
    warn "  1. Unplug and re-plug the dongle (without reset pin)"
    warn "  2. If it shows as fastboot (18d1:d00d): adjust DTB in extlinux.conf"
    warn "  3. If nothing: restore backup with: bash flash-uz801.sh --restore $BACKUP_DIR"
fi

echo ""
log "═══════════════════════════════════════"
log "  Flash complete!"
log "  IMEI:    ${DONGLE_IMEI:-unknown}"
log "  Rootfs:  $ROOTFS_FILE"
log "  Backup:  ${BACKUP_DIR:-none}"
log "  Log:     $LOGFILE"
log "═══════════════════════════════════════"
