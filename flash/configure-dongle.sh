#!/bin/bash -e
#
# configure-dongle.sh — Configure an OpenStick dongle after flashing
#
# Connects via ADB and sets up:
#   - Device-specific modem + WiFi firmware (from backup)
#   - Apt sources fix (Debian 11 bullseye is archived)
#   - System clock (no RTC battery)
#   - Root password + SSH access
#   - Hostname + timezone
#   - NAT gateway (USB → LTE)
#   - WiFi hotspot (optional)
#   - LTE APN (optional)
#
# NOTE: DTB patching / extlinux setup is no longer needed. The boot-jz0145.img
# has the JZ0145-v33 DTB baked in. The extlinux approach broke boot because
# the Dragonboard aboot's fastboot interface is unreachable from the host.
#
# Usage:
#   bash configure-dongle.sh [options]
#
# Options:
#   --hostname NAME       Set hostname (default: openstick)
#   --root-password PW    Set root password (default: prompted)
#   --ssh-key FILE        Install SSH public key for root
#   --wifi-ssid SSID      Set WiFi hotspot SSID (manual)
#   --wifi-password PW    Set WiFi hotspot password (manual)
#   --derive-wifi-psk     Auto-derive SSID (GA-XXXX) and PSK from IMEI + shared secret
#   --apn APN             Set LTE APN (e.g., "internet")
#   --timezone TZ         Set timezone (e.g., "Europe/Berlin")
#   --no-wifi             Skip WiFi hotspot setup
#   --no-nat              Skip NAT gateway setup
#   --no-firmware         Skip modem firmware copy
#   --no-apt-fix          Skip apt sources fix

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/../backup/partitions"
ENV_FILE="$SCRIPT_DIR/../.env"

# Load .env if present
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

# ─── Parse arguments ────────────────────────────────────────────────────────

HOSTNAME="openstick"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
SSH_KEY=""
WIFI_SSID=""
WIFI_PASSWORD="${WIFI_PASSWORD:-}"
APN="internet"
TIMEZONE="UTC"
NETBIRD_SETUP_KEY="${NETBIRD_SETUP_KEY:-}"
OPENSTICK_WIFI_SECRET="${OPENSTICK_WIFI_SECRET:-}"
DERIVE_WIFI_PSK=false
SETUP_WIFI=true
SETUP_NAT=true
SETUP_FIRMWARE=true
SETUP_APT_FIX=true
SETUP_NETBIRD=true

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
        --no-apt-fix)     SETUP_APT_FIX=false; shift ;;
        --no-netbird)     SETUP_NETBIRD=false; shift ;;
        --netbird-key)    NETBIRD_SETUP_KEY="$2"; shift 2 ;;
        --derive-wifi-psk) DERIVE_WIFI_PSK=true; shift ;;
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

# ─── Fix apt sources (Debian 11 bullseye is archived) ────────────────────────

if $SETUP_APT_FIX; then
    log "Fixing apt sources (Debian 11 bullseye → archive.debian.org)..."

    adb shell '
        if grep -q "deb.debian.org" /etc/apt/sources.list 2>/dev/null; then
            sed -i "s|deb.debian.org|archive.debian.org|g" /etc/apt/sources.list
            sed -i "/security.debian.org/d" /etc/apt/sources.list
            echo "apt sources updated to archive.debian.org"
        else
            echo "apt sources already fixed or not using deb.debian.org"
        fi
    '
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

# ─── Derive WiFi PSK from IMEI (if requested) ───────────────────────────────

if $DERIVE_WIFI_PSK; then
    if [ -z "$OPENSTICK_WIFI_SECRET" ]; then
        err "OPENSTICK_WIFI_SECRET not set (check .env or use --no-wifi)"
    fi
    log "Deriving WiFi SSID and PSK from IMEI..."
    IMEI=$(adb shell 'mmcli -m 0 -K 2>/dev/null | grep "modem.3gpp.imei" | cut -d: -f2 | tr -d " \r\n"')
    if [ -z "$IMEI" ] || [ ${#IMEI} -lt 4 ]; then
        err "Could not read IMEI from modem (got: '$IMEI')"
    fi
    IMEI_LAST4="${IMEI: -4}"
    WIFI_SSID="GA-${IMEI_LAST4}"
    WIFI_PASSWORD=$(echo -n "$WIFI_SSID" | openssl dgst -sha256 -hmac "$OPENSTICK_WIFI_SECRET" | cut -d' ' -f2 | cut -c1-16)
    log "  IMEI:     ...${IMEI_LAST4}"
    log "  SSID:     ${WIFI_SSID}"
    log "  PSK:      ${WIFI_PASSWORD} (HMAC-SHA256 derived)"
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

# ─── Configure NetBird VPN ───────────────────────────────────────────────────

if $SETUP_NETBIRD && [ -n "$NETBIRD_SETUP_KEY" ]; then
    log "Connecting NetBird VPN..."
    if adb shell 'which netbird >/dev/null 2>&1'; then
        adb shell "netbird up --setup-key $NETBIRD_SETUP_KEY" 2>&1
        NB_IP=$(adb shell 'netbird status 2>/dev/null | grep "NetBird IP" | awk "{print \$NF}"' 2>/dev/null | tr -d '\r')
        NB_FQDN=$(adb shell 'netbird status 2>/dev/null | grep "FQDN" | awk "{print \$NF}"' 2>/dev/null | tr -d '\r')
        log "NetBird connected: $NB_IP ($NB_FQDN)"
    else
        warn "NetBird not installed. Run install-packages.sh --vpn netbird first."
    fi
elif $SETUP_NETBIRD; then
    warn "NetBird: no setup key (set NETBIRD_SETUP_KEY in .env or use --netbird-key)"
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
echo "  SSH:         root@192.168.68.1 (password auth enabled)"
echo "  USB network: 192.168.68.1/16 (DHCP via dnsmasq)"
if [ -n "$APN" ]; then
    echo "  LTE APN:     $APN (auto-connect on boot)"
fi
if $SETUP_WIFI && [ -n "$WIFI_SSID" ]; then
    echo "  WiFi:        $WIFI_SSID (AP mode on wlan0)"
fi
if $SETUP_NAT; then
    echo "  NAT:         enabled (iptables, wwan0 masquerade)"
fi
if [ -n "$NB_FQDN" ]; then
    echo "  NetBird:     $NB_IP ($NB_FQDN)"
fi
echo ""
log "Rebooting dongle to apply all changes..."
adb shell reboot

echo ""
log "Done! Wait 60s for reboot, then:"
echo "  ssh root@192.168.68.1"
if [ -n "$NB_FQDN" ]; then
    echo "  ssh root@$NB_FQDN  (via NetBird)"
fi
echo "  # Or: adb shell"
