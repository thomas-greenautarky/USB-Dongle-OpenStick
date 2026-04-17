#!/bin/bash -e
#
# flash-uz801.sh — Flash OpenStick Debian onto UZ801 (and compatible) USB dongles
#
# Based on findings from:
#   - https://github.com/kinsamanka/OpenStick-Builder (flash method)
#   - https://github.com/OpenStick/OpenStick/issues/91 (EDL limitations)
#   - https://github.com/OpenStick/OpenStick/issues/46 (UZ801 v3 support)
#
# EDL NOTES:
#   - peek loaders CAN write to eMMC (peek/poke refers to RAM, not storage)
#   - "Connection detected, quiting" = Sahara error state, needs clean replug
#   - All writes are done in a single EDL session after clean adb reboot edl
#
# Flow:
#   1. Detect dongle state (Stock Android / EDL / Fastboot)
#   2. If Stock Android: enable ADB via web API, backup firmware files
#   3. adb reboot edl → clean EDL entry
#   4. In EDL: backup NV storage (verified) + stock partitions
#   5. In EDL: flash GPT + all firmware + boot + rootfs + modem + NV restore
#   6. Reset and verify boot
#
# Supports two dongle types:
#   - UZ801 v3 (Stock Android 05c6:f00e) — this script
#   - JZ0145-v33 (EDL only 05c6:9008) — use flash-openstick.sh instead
#
# Prerequisites:
#   - edl: pipx install edlclient
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

# UZ801 Firehose quirk: must explicitly set memory=emmc to avoid USB Overflow
# on the first write. See docs/dongle-compatibility.md § USB-Overflow.
EDL_OPTS=(--memory=emmc)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

# ─── Sahara error recovery ──────────────────────────────────────────────────
# Sahara has only one Hello packet — any failure leaves PBL in error state
# that survives until a full power cycle. Detect these errors, prompt for
# unplug/replug, and retry the command once.
# See docs/dongle-compatibility.md § EDL Instabilität for details.

is_sahara_error() {
    echo "$1" | grep -qiE "connection (already|detected)|sahara.*(timeout|fail|error)|no response|device.*not.*(found|detected)"
}

wait_for_edl() {
    local timeout=${1:-30}
    for i in $(seq 1 "$timeout"); do
        lsusb 2>/dev/null | grep -q "05c6:9008" && return 0
        sleep 1
    done
    return 1
}

require_replug() {
    warn "Sahara/EDL error detected — PBL needs power cycle."
    warn "Unplug the dongle, wait 3 seconds, then plug it back in."
    echo -ne "${YELLOW}[!]${NC} Press Enter when dongle is back in EDL..."
    read -r
    wait_for_edl 30 || err "EDL device not detected after replug."
    log "EDL device back online."
}

# edl_run <label> <edl args...> — run edl with EDL_OPTS, retry once with replug on Sahara error
edl_run() {
    local label="$1"; shift
    local out
    out=$(edl "${EDL_OPTS[@]}" "$@" 2>&1) || true
    if is_sahara_error "$out"; then
        warn "$label: Sahara error"
        echo "$out" | tail -3
        require_replug
        out=$(edl "${EDL_OPTS[@]}" "$@" 2>&1) || true
        if is_sahara_error "$out"; then
            echo "$out" | tail -3
            err "$label: Sahara error persists after replug. Abort."
        fi
    fi
    echo "$out" | tail -1
}

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

which edl >/dev/null 2>&1    || err "edl not found. Install: pipx install edlclient"
which adb >/dev/null 2>&1    || warn "adb not found (needed for Stock Android dongles)"
which sgdisk >/dev/null 2>&1 || err "sgdisk not found. Install: apt install gdisk"

# EDL stability: connect dongle directly to host, not through a USB hub.
# See docs/dongle-compatibility.md § EDL Instabilität.
warn "EDL tip: plug dongle directly into the host (avoid USB hubs) for stable Sahara."

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

    # Find web interface by API login
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
    if ! adb devices 2>/dev/null | grep -q "device$"; then
        warn "ADB not detected after enable. Waiting 10s..."
        sleep 10
    fi
    adb devices 2>/dev/null | grep -q "device$" || err "ADB not available."
    log "  ADB connected."

    # Backup firmware files
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
        } > "$BACKUP_DIR/device_info.txt" 2>&1

        # Modem firmware as individual files via adb pull
        log "  Backing up modem firmware files..."
        MODEM_FW_DIR="$BACKUP_DIR/modem_firmware"
        mkdir -p "$MODEM_FW_DIR"
        adb shell "mount -o ro /dev/block/bootdevice/by-name/modem /firmware 2>/dev/null; ls /firmware/image/ 2>/dev/null" | tr -d '\r' | while read -r f; do
            [ -n "$f" ] && adb pull "/firmware/image/$f" "$MODEM_FW_DIR/$f" >/dev/null 2>&1
        done
        FW_COUNT=$(ls "$MODEM_FW_DIR" 2>/dev/null | wc -l)
        log "  Modem firmware: $FW_COUNT files"
        log "  Partition backups will be done via EDL (Step 3)"
    else
        warn "  Skipping backup (--skip-backup)"
    fi

    # Reboot to EDL (clean entry — critical for EDL writes to work)
    log "  Rebooting to EDL..."
    adb reboot edl 2>/dev/null
    sleep 5
    DONGLE_STATE="edl"
fi

# ─── Step 3: EDL phase — backup + flash everything ─────────────────────────

if [ "$DONGLE_STATE" = "fastboot" ]; then
    warn "Dongle in Fastboot. Need EDL for flashing."
    warn "Unplug dongle, then plug in with reset pin held (or use adb reboot edl)."
    echo -n "Press Enter when in EDL mode..."
    read -r
    DONGLE_STATE="edl"
fi

log "=== Step 3: EDL Phase ==="
log "Waiting for EDL device (05c6:9008)..."
for i in $(seq 1 30); do
    lsusb 2>/dev/null | grep -q "05c6:9008" && break
    sleep 2
done
lsusb 2>/dev/null | grep -q "05c6:9008" || err "EDL device not found."
log "EDL device detected."

# ─── Step 3a: Read disk geometry ───────────────────────────────────────────

log "--- Reading disk geometry ---"
DISK_INFO=$(timeout 15 edl "${EDL_OPTS[@]}" printgpt 2>&1 | grep -i "Total disk size" || true)
TOTAL_SECTORS=$(echo "$DISK_INFO" | grep -oP 'sectors:0x\K[0-9a-fA-F]+' | head -1)
if [ -n "$TOTAL_SECTORS" ]; then
    TOTAL_SECTORS_DEC=$((16#$TOTAL_SECTORS))
    DISK_SIZE_MB=$((TOTAL_SECTORS_DEC * 512 / 1024 / 1024))
    log "  Disk: ${DISK_SIZE_MB} MB ($TOTAL_SECTORS_DEC sectors)"
else
    warn "Could not read disk size. Using 3.6 GB default."
    TOTAL_SECTORS_DEC=7634944
fi

# ─── Step 3b: NV backup via EDL (verified) ─────────────────────────────────

if ! $SKIP_BACKUP; then
    log "--- NV Backup (verified) ---"
    if [ -z "$BACKUP_DIR" ]; then
        BACKUP_DIR="$BACKUP_BASE/edl_backup_$(date +%Y%m%d_%H%M%S)"
    fi
    mkdir -p "$BACKUP_DIR"

    NV_PARTS="sec fsc fsg modemst1 modemst2"
    NV_OK=0
    NV_TOTAL=0
    for part in $NV_PARTS; do
        NV_TOTAL=$((NV_TOTAL + 1))
        log "  Reading $part..."
        if edl "${EDL_OPTS[@]}" r "$part" "$BACKUP_DIR/${part}.bin" 2>&1 | grep -q "Read \|Dumped"; then
            SIZE=$(du -h "$BACKUP_DIR/${part}.bin" | cut -f1)
            edl "${EDL_OPTS[@]}" r "$part" "$BACKUP_DIR/${part}.verify" 2>&1 >/dev/null
            if [ -f "$BACKUP_DIR/${part}.verify" ] && cmp -s "$BACKUP_DIR/${part}.bin" "$BACKUP_DIR/${part}.verify"; then
                log "    $part: $SIZE ✓"
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
        log "  NV backup: $NV_OK/$NV_TOTAL verified ✓"
    else
        warn "  NV backup: $NV_OK/$NV_TOTAL verified"
        echo -ne "${YELLOW}[!]${NC} Continue? IMEI may be lost. [y/N] "
        read -r CONTINUE
        [ "$CONTINUE" = "y" ] || [ "$CONTINUE" = "Y" ] || err "Aborted."
    fi

    # Stock partition backup
    log "--- Stock partition backup ---"
    STOCK_DIR="$BACKUP_DIR/stock_partitions"
    mkdir -p "$STOCK_DIR"
    edl "${EDL_OPTS[@]}" rs 0 40 "$STOCK_DIR/gpt.bin" 2>&1 >/dev/null && log "    gpt ✓" || true
    STOCK_PARTS="sbl1 sbl1bak aboot abootbak rpm rpmbak tz tzbak hyp hypbak pad modem"
    for part in $STOCK_PARTS; do
        echo -n "    $part... "
        if edl "${EDL_OPTS[@]}" r "$part" "$STOCK_DIR/${part}.bin" 2>&1 | grep -q "Read \|Dumped"; then
            echo "$(du -h "$STOCK_DIR/${part}.bin" | cut -f1) ✓"
        else
            echo "skip"
            rm -f "$STOCK_DIR/${part}.bin"
        fi
    done
fi

# ─── Step 3c: Generate GPT ─────────────────────────────────────────────────

log "--- Generate GPT ---"

MODEM_START=150566
MODEM_END=282137
MODEM_FW_DIR="${BACKUP_DIR:-}/modem_firmware"
if [ -d "$MODEM_FW_DIR" ] && [ "$(ls "$MODEM_FW_DIR" 2>/dev/null | wc -l)" -gt 0 ]; then
    FW_TOTAL=$(du -sb "$MODEM_FW_DIR" 2>/dev/null | cut -f1)
    FW_SECTORS=$(( (FW_TOTAL * 120 / 100 + 511) / 512 ))
    if [ "$FW_SECTORS" -gt 131072 ]; then
        MODEM_END=$(( MODEM_START + FW_SECTORS - 1 ))
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
BACKUP_GPT_SECTOR=$((TOTAL_SECTORS_DEC - 33))
log "  GPT: 15 partitions, rootfs ends at sector $LAST_USABLE"

# Extract primary + backup GPT
dd if="$GPT_IMG" of="$GPT_IMG.primary" bs=512 count=34 2>/dev/null
dd if="$GPT_IMG" of="$GPT_IMG.backup" bs=512 skip=$((TOTAL_SECTORS_DEC - 33)) count=33 2>/dev/null

# ─── Step 3d: Flash everything via EDL ──────────────────────────────────────

log "--- Flash via EDL ---"

log "  Primary GPT..."
edl_run "gpt-primary" ws 0 "$GPT_IMG.primary"

log "  Backup GPT..."
edl_run "gpt-backup" ws "$BACKUP_GPT_SECTOR" "$GPT_IMG.backup"

log "  Firmware (sbl1, rpm, tz, hyp, cdt)..."
edl_run "sbl1" w sbl1 "$FILES_DIR/sbl1.mbn"
edl_run "rpm"  w rpm  "$FILES_DIR/rpm.mbn"
edl_run "tz"   w tz   "$FILES_DIR/tz.mbn"
edl_run "hyp"  w hyp  "$FILES_DIR/hyp.mbn"
[ -f "$FILES_DIR/sbc_1.0_8016.bin" ] && edl_run "cdt" w cdt "$FILES_DIR/sbc_1.0_8016.bin"

log "  Bootloader (lk2nd as aboot)..."
edl_run "aboot" w aboot "$FILES_DIR/aboot.mbn"

log "  Boot partition (kernel + DTBs)..."
edl_run "boot" w boot "$FILES_DIR/boot.bin"

log "  Rootfs (this takes 2-5 minutes)..."
edl_run "rootfs" w rootfs "$ROOTFS_FILE"

# Create and flash modem vfat partition
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
        docker run --rm --privileged -v "$MODEM_FW_DIR":/fw -v "$MODEM_VFAT":/tmp/vfat.img alpine sh -c "
            mount -o loop /tmp/vfat.img /mnt && mkdir -p /mnt/image &&
            cp /fw/* /mnt/image/ && umount /mnt" 2>/dev/null
    fi
    edl_run "modem" w modem "$MODEM_VFAT"
    rm -f "$MODEM_VFAT"
fi

# Restore NV storage
if [ -n "$BACKUP_DIR" ] && [ -f "$BACKUP_DIR/modemst1.bin" ] && [ "$(stat -c%s "$BACKUP_DIR/modemst1.bin")" -gt 1024 ]; then
    log "  Restoring NV storage..."
    for part in sec fsc fsg modemst1 modemst2; do
        [ -f "$BACKUP_DIR/${part}.bin" ] && edl_run "nv-$part" w "$part" "$BACKUP_DIR/${part}.bin"
    done
    log "  NV storage restored."
else
    warn "  No valid NV backup — IMEI may be missing"
fi

rm -f "$GPT_IMG" "$GPT_IMG.primary" "$GPT_IMG.backup"

# ─── Step 4: Reset and verify ──────────────────────────────────────────────

log "=== Step 4: Boot ==="
edl "${EDL_OPTS[@]}" reset 2>&1 | tail -1 || true

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
        warn "Fastboot detected — lk2nd booted but kernel didn't start."
        break
    fi
done

if ! $BOOTED; then
    warn "Device not detected. Try unplugging and re-plugging (without reset pin)."
    echo -ne "${GREEN}[+]${NC} Press Enter after re-plugging..."
    read -r
    for i in $(seq 1 12); do
        lsusb 2>/dev/null | grep -q "1d6b:0104" && BOOTED=true && break
        sleep 5
    done
fi

if $BOOTED; then
    log "Device booted!"
    DONGLE_SSH_IP="192.168.68.1"
    SSH_OPTS_FW="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
    SSH_PASS_FW="openstick"

    log "Waiting for SSH..."
    for i in $(seq 1 12); do
        SSHPASS="$SSH_PASS_FW" sshpass -e ssh $SSH_OPTS_FW "root@$DONGLE_SSH_IP" "echo OK" 2>/dev/null | grep -q OK && break
        sleep 5
    done

    # Copy modem firmware to /lib/firmware/
    MODEM_FW_DIR="${BACKUP_DIR:-}/modem_firmware"
    if [ -d "$MODEM_FW_DIR" ] && [ "$(ls "$MODEM_FW_DIR" 2>/dev/null | wc -l)" -gt 0 ]; then
        log "Copying modem firmware to dongle..."
        for fw in "$MODEM_FW_DIR"/*; do
            [ -f "$fw" ] && SSHPASS="$SSH_PASS_FW" sshpass -e scp $SSH_OPTS_FW "$fw" "root@$DONGLE_SSH_IP:/lib/firmware/" 2>/dev/null
        done
        log "  Copied $(ls "$MODEM_FW_DIR" -1 2>/dev/null | wc -l) firmware files"

        log "Copying NV storage to /boot..."
        SSHPASS="$SSH_PASS_FW" sshpass -e ssh $SSH_OPTS_FW "root@$DONGLE_SSH_IP" "
            dd if=/dev/mmcblk0p7 of=/boot/modem_fs1 bs=1M 2>/dev/null
            dd if=/dev/mmcblk0p8 of=/boot/modem_fs2 bs=1M 2>/dev/null
            dd if=/dev/mmcblk0p10 of=/boot/modem_fsg bs=1M 2>/dev/null
            chmod 666 /boot/modem_fs*
        " 2>/dev/null

        log "Rebooting for modem init..."
        SSHPASS="$SSH_PASS_FW" sshpass -e ssh $SSH_OPTS_FW "root@$DONGLE_SSH_IP" "reboot" 2>/dev/null || true
        sleep 30
        for i in $(seq 1 12); do
            SSHPASS="$SSH_PASS_FW" sshpass -e ssh $SSH_OPTS_FW "root@$DONGLE_SSH_IP" "echo OK" 2>/dev/null | grep -q OK && break
            sleep 5
        done
        log "Dongle back after reboot."
    fi
else
    warn "Device did not boot."
fi

echo ""
log "═══════════════════════════════════════"
log "  Flash complete!"
log "  IMEI:    ${DONGLE_IMEI:-unknown}"
log "  Rootfs:  $ROOTFS_FILE"
log "  Backup:  ${BACKUP_DIR:-none}"
log "  Log:     $LOGFILE"
log "═══════════════════════════════════════"
