#!/bin/bash -e
#
# configure-dongle.sh — Configure an OpenStick dongle after flashing
#
# Connects via ADB and sets up:
#   - Device-specific modem + WiFi firmware (from backup)
#   - Device tree patch (JZ0145-v33)
#   - Extlinux boot with correct DTB
#   - Root password + SSH access
#   - Hostname + timezone
#   - NAT gateway (USB → LTE)
#   - WiFi hotspot (optional)
#   - LTE APN (optional)
#
# Usage:
#   bash configure-dongle.sh [options]
#
# Options:
#   --hostname NAME       Set hostname (default: openstick)
#   --root-password PW    Set root password (default: prompted)
#   --ssh-key FILE        Install SSH public key for root
#   --wifi-ssid SSID      Set WiFi hotspot SSID
#   --wifi-password PW    Set WiFi hotspot password
#   --apn APN             Set LTE APN (e.g., "internet")
#   --timezone TZ         Set timezone (e.g., "Europe/Berlin")
#   --no-wifi             Skip WiFi hotspot setup
#   --no-nat              Skip NAT gateway setup
#   --no-firmware         Skip modem firmware copy
#   --no-dtb              Skip DTB patching

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/../backup/partitions"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

# ─── Parse arguments ────────────────────────────────────────────────────────

HOSTNAME="openstick"
ROOT_PASSWORD=""
SSH_KEY=""
WIFI_SSID=""
WIFI_PASSWORD=""
APN=""
TIMEZONE="UTC"
SETUP_WIFI=true
SETUP_NAT=true
SETUP_FIRMWARE=true
SETUP_DTB=true

while [[ $# -gt 0 ]]; do
    case $1 in
        --hostname)       HOSTNAME="$2"; shift 2 ;;
        --root-password)  ROOT_PASSWORD="$2"; shift 2 ;;
        --ssh-key)        SSH_KEY="$2"; shift 2 ;;
        --wifi-ssid)      WIFI_SSID="$2"; shift 2 ;;
        --wifi-password)  WIFI_PASSWORD="$2"; shift 2 ;;
        --apn)            APN="$2"; shift 2 ;;
        --timezone)       TIMEZONE="$2"; shift 2 ;;
        --no-wifi)        SETUP_WIFI=false; shift ;;
        --no-nat)         SETUP_NAT=false; shift ;;
        --no-firmware)    SETUP_FIRMWARE=false; shift ;;
        --no-dtb)         SETUP_DTB=false; shift ;;
        *)                err "Unknown option: $1" ;;
    esac
done

# ─── Check ADB connection ───────────────────────────────────────────────────

log "Checking ADB connection..."
adb devices 2>/dev/null | grep -q "device$" || err "No ADB device found. Is the dongle connected and booted?"

OS=$(adb shell cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')
log "Connected to: $OS"

# ─── Prompt for missing values ───────────────────────────────────────────────

if [ -z "$ROOT_PASSWORD" ]; then
    echo -n "Set root password: "
    read -s ROOT_PASSWORD
    echo ""
    [ -n "$ROOT_PASSWORD" ] || err "Password cannot be empty"
fi

# ─── Copy device-specific modem + WiFi firmware ─────────────────────────────

if $SETUP_FIRMWARE; then
    log "Copying device-specific modem and WiFi firmware from backup..."

    if [ ! -f "$BACKUP_DIR/modem.bin" ] || [ ! -f "$BACKUP_DIR/persist.bin" ]; then
        warn "Backup modem.bin or persist.bin not found in $BACKUP_DIR"
        warn "Skipping firmware copy — modem may not work without device-specific firmware!"
    else
        adb push "$BACKUP_DIR/modem.bin" /tmp/modem.bin
        adb push "$BACKUP_DIR/persist.bin" /tmp/persist.bin

        adb shell '
            mount /tmp/modem.bin /mnt 2>/dev/null
            if [ $? -eq 0 ]; then
                cp /mnt/image/m* /mnt/image/wc* /lib/firmware/ 2>/dev/null || true
                umount /mnt
                echo "Modem firmware copied"
            else
                echo "Warning: could not mount modem.bin"
            fi

            mount /tmp/persist.bin /mnt 2>/dev/null
            if [ $? -eq 0 ]; then
                cp /mnt/WCNSS_qcom_wlan_nv.bin /lib/firmware/wlan/prima/ 2>/dev/null || true
                umount /mnt
                echo "WiFi NV data copied"
            else
                echo "Warning: could not mount persist.bin"
            fi

            rm -f /tmp/modem.bin /tmp/persist.bin
        '
    fi
fi

# ─── Patch device tree for JZ0145-v33 ───────────────────────────────────────

if $SETUP_DTB; then
    log "Patching device tree for JZ0145-v33..."

    which dtc >/dev/null 2>&1 || err "dtc (device-tree-compiler) not installed on host"

    # Extract running device tree
    adb pull /sys/firmware/fdt /tmp/fdt 2>/dev/null

    # Download JZ patch
    PATCH_DTS="/tmp/patch.dts"
    if [ ! -f "$PATCH_DTS" ]; then
        wget -q -O "$PATCH_DTS" \
            "https://gist.github.com/kinsamanka/0b01cd02412bd13ee072072043d46fa2/raw/patch.dts" \
            || err "Failed to download DTB patch"
    fi

    # Compile patched DTB
    dtc -I dtb -O dts /tmp/fdt -o /tmp/default.dts 2>/dev/null
    cat /tmp/default.dts "$PATCH_DTS" | dtc -I dts -O dts -o /tmp/jz01-45-v33.dts 2>/dev/null
    dtc -I dts -O dtb /tmp/jz01-45-v33.dts -o /tmp/jz01-45-v33.dtb 2>/dev/null

    # Push to device
    adb push /tmp/jz01-45-v33.dtb /boot/
    adb push /tmp/jz01-45-v33.dts /boot/

    # Set up extlinux boot
    PARTUUID=$(adb shell blkid /dev/mmcblk0p13 2>/dev/null | grep -oP 'PARTUUID="\K[^"]+')
    [ -n "$PARTUUID" ] || PARTUUID="a7ab80e8-e9d1-e8cd-f157-93f69b1d141e"

    adb shell "
        mkfs.ext2 -F /dev/disk/by-partlabel/boot 2>/dev/null
        mount /dev/disk/by-partlabel/boot /mnt

        mkdir -p /mnt/extlinux
        cat > /mnt/extlinux/extlinux.conf << EXTEOF
linux /vmlinuz
initrd /initrd.img
fdt /default.dtb
append earlycon root=PARTUUID=${PARTUUID} console=ttyMSM0,115200 no_framebuffer=true rw rootwait
EXTEOF

        cp /boot/vmlinuz-* /mnt/vmlinuz
        cp /boot/initrd.img-* /mnt/initrd.img
        cp /boot/jz01-45-v33.dtb /mnt/
        ln -sf jz01-45-v33.dtb /mnt/default.dtb

        grep -q 'by-partlabel/boot' /etc/fstab || \
            echo '/dev/disk/by-partlabel/boot /boot ext2 defaults 0 0' >> /etc/fstab

        umount /mnt
        echo 'Extlinux boot configured'
    "

    rm -f /tmp/fdt /tmp/default.dts /tmp/jz01-45-v33.dts /tmp/jz01-45-v33.dtb
fi

# ─── Configure hostname ─────────────────────────────────────────────────────

log "Setting hostname to '$HOSTNAME'..."
adb shell "echo '$HOSTNAME' > /etc/hostname"
adb shell "sed -i 's/openstick/$HOSTNAME/g' /etc/hosts 2>/dev/null || true"

# ─── Configure root password ────────────────────────────────────────────────

log "Setting root password..."
adb shell "echo 'root:$ROOT_PASSWORD' | chpasswd"

# ─── Configure SSH ───────────────────────────────────────────────────────────

log "Configuring SSH..."
adb shell "
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    # Disable DNS lookups (prevents auth delays)
    grep -q '^UseDNS' /etc/ssh/sshd_config || echo 'UseDNS no' >> /etc/ssh/sshd_config
    # Disable PAM modules that cause hangs on embedded systems
    sed -i 's/^.*pam_loginuid.*/#&/' /etc/pam.d/sshd
    sed -i 's/^.*pam_selinux.*/#&/' /etc/pam.d/sshd
"

if [ -n "$SSH_KEY" ]; then
    if [ -f "$SSH_KEY" ]; then
        log "Installing SSH public key..."
        adb shell "mkdir -p /root/.ssh && chmod 700 /root/.ssh"
        adb push "$SSH_KEY" /tmp/authorized_keys
        adb shell "cat /tmp/authorized_keys > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && rm /tmp/authorized_keys"
    else
        warn "SSH key file not found: $SSH_KEY"
    fi
fi

adb shell "systemctl restart sshd 2>/dev/null || true"

# ─── Configure timezone + clock ──────────────────────────────────────────────

log "Setting timezone to $TIMEZONE..."
adb shell "ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime 2>/dev/null || true"
adb shell "date -s '$(date -u '+%Y-%m-%d %H:%M:%S')' 2>/dev/null || true"

# ─── Configure NAT gateway (USB → LTE) ──────────────────────────────────────

if $SETUP_NAT; then
    log "Setting up NAT gateway (iptables)..."

    adb shell '
        # IP forwarding
        sysctl -w net.ipv4.ip_forward=1 >/dev/null
        echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forward.conf

        # NAT masquerade on wwan0
        iptables -t nat -C POSTROUTING -o wwan0 -j MASQUERADE 2>/dev/null || \
            iptables -t nat -A POSTROUTING -o wwan0 -j MASQUERADE

        # Save rules for persistence
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4

        # Create restore service
        cat > /etc/systemd/system/iptables-restore.service << "SVCEOF"
[Unit]
Description=Restore iptables rules
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF
        systemctl enable iptables-restore 2>/dev/null
        echo "NAT configured and persistent"
    '
fi

# ─── Configure LTE APN ──────────────────────────────────────────────────────

if [ -n "$APN" ]; then
    log "Configuring LTE APN: $APN"
    adb shell "mmcli -m 0 --simple-connect='apn=$APN' 2>/dev/null || \
               nmcli connection add type gsm ifname '*' con-name lte apn '$APN' 2>/dev/null || \
               echo 'APN configuration may need manual setup'"
fi

# ─── Configure WiFi hotspot ──────────────────────────────────────────────────

if $SETUP_WIFI && [ -n "$WIFI_SSID" ]; then
    log "Setting up WiFi hotspot: $WIFI_SSID"
    WIFI_PW_OPTION=""
    if [ -n "$WIFI_PASSWORD" ]; then
        WIFI_PW_OPTION="802-11-wireless-security.key-mgmt wpa-psk 802-11-wireless-security.psk $WIFI_PASSWORD"
    fi

    adb shell "nmcli connection add type wifi ifname wlan0 con-name hotspot \
        autoconnect yes \
        wifi.mode ap \
        wifi.ssid '$WIFI_SSID' \
        ipv4.method shared \
        ipv4.addresses 192.168.4.1/24 \
        $WIFI_PW_OPTION 2>/dev/null || echo 'WiFi hotspot config may need manual setup'"
fi

# ─── Configure LED indicators ────────────────────────────────────────────────

log "Setting up LED indicators..."
adb shell '
    # Red LED: heartbeat (system alive)
    echo heartbeat > /sys/class/leds/red:os/trigger 2>/dev/null || true
    echo "LEDs configured"
'

# ─── Reboot ──────────────────────────────────────────────────────────────────

echo ""
log "Configuration complete!"
echo ""
echo "  Hostname:    $HOSTNAME"
echo "  SSH:         root@192.168.68.1 (password: [set above])"
echo "  USB network: 192.168.68.1/16 (DHCP via dnsmasq)"
if [ -n "$APN" ]; then
    echo "  LTE APN:     $APN"
fi
if $SETUP_WIFI && [ -n "$WIFI_SSID" ]; then
    echo "  WiFi:        $WIFI_SSID (AP mode on wlan0)"
fi
if $SETUP_NAT; then
    echo "  NAT:         enabled (iptables, wwan0 masquerade)"
fi
echo ""
log "Rebooting dongle to apply all changes..."
adb shell reboot

echo ""
log "Done! Wait 30s for reboot, then:"
echo "  ssh root@192.168.68.1"
echo "  # Or: adb shell"
