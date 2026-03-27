#!/bin/bash -e
#
# configure-dongle.sh — Configure an OpenStick dongle after flashing
#
# Connects via ADB and sets up:
#   - Root password
#   - SSH access (key + password auth)
#   - Hostname
#   - WiFi hotspot (hostapd)
#   - LTE APN
#   - USB network gateway (NAT)
#   - Timezone
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

# ─── Configure hostname ─────────────────────────────────────────────────────

log "Setting hostname to '$HOSTNAME'..."
adb shell "echo '$HOSTNAME' > /etc/hostname"
adb shell "sed -i 's/openstick/$HOSTNAME/g' /etc/hosts 2>/dev/null || true"

# ─── Configure root password ────────────────────────────────────────────────

log "Setting root password..."
adb shell "echo 'root:$ROOT_PASSWORD' | chpasswd"

# ─── Configure SSH ───────────────────────────────────────────────────────────

log "Enabling SSH root login..."
adb shell "sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config"
adb shell "sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config"

if [ -n "$SSH_KEY" ]; then
    if [ -f "$SSH_KEY" ]; then
        log "Installing SSH public key..."
        adb shell "mkdir -p /root/.ssh && chmod 700 /root/.ssh"
        adb push "$SSH_KEY" /tmp/authorized_keys
        adb shell "cat /tmp/authorized_keys >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && rm /tmp/authorized_keys"
    else
        warn "SSH key file not found: $SSH_KEY"
    fi
fi

adb shell "systemctl restart sshd 2>/dev/null || true"

# ─── Configure timezone ─────────────────────────────────────────────────────

log "Setting timezone to $TIMEZONE..."
adb shell "ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime 2>/dev/null || echo 'Timezone not available'"

# ─── Configure USB network gateway (NAT) ────────────────────────────────────

if $SETUP_NAT; then
    log "Setting up NAT gateway on USB interface..."
    adb shell 'cat > /etc/nftables.conf << "NFTEOF"
#!/usr/sbin/nft -f
flush ruleset

table inet nat {
    chain postrouting {
        type nat hook postrouting priority 100;
        oifname "wwan0" masquerade
        oifname "wlan0" masquerade
    }
}

table inet filter {
    chain forward {
        type filter hook forward priority 0;
        policy accept;
    }
}
NFTEOF'

    adb shell 'echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forward.conf'
    adb shell 'sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true'

    # Enable nftables on boot
    adb shell 'systemctl enable nftables 2>/dev/null || true'
    adb shell 'nft -f /etc/nftables.conf 2>/dev/null || true'
fi

# ─── Configure LTE APN ──────────────────────────────────────────────────────

if [ -n "$APN" ]; then
    log "Configuring LTE APN: $APN"
    adb shell "nmcli connection add type gsm ifname '*' con-name lte apn '$APN' 2>/dev/null || \
               mmcli -m 0 --simple-connect='apn=$APN' 2>/dev/null || \
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

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
log "Configuration complete!"
echo ""
echo "  Hostname:    $HOSTNAME"
echo "  SSH:         root@192.168.68.1 (password auth enabled)"
echo "  USB network: 192.168.68.1/16 (DHCP via dnsmasq)"
if [ -n "$APN" ]; then
    echo "  LTE APN:     $APN"
fi
if $SETUP_WIFI && [ -n "$WIFI_SSID" ]; then
    echo "  WiFi:        $WIFI_SSID (AP mode on wlan0)"
fi
if $SETUP_NAT; then
    echo "  NAT:         enabled (forwarding via wwan0/wlan0)"
fi
echo ""
log "Reboot the dongle to apply all changes: adb shell reboot"
