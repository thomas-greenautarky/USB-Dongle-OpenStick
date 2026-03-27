#!/bin/bash -e
#
# install-packages.sh — Install recommended packages on an OpenStick dongle
#
# Run via ADB after flashing and configuring:
#   adb push install-packages.sh /tmp/
#   adb shell bash /tmp/install-packages.sh
#
# Or directly on the dongle via SSH:
#   bash install-packages.sh [--minimal] [--diagnostics] [--vpn netbird|tailscale]
#
# Package groups:
#   BASE        Always installed — essential tools for operation
#   DIAGNOSTICS Optional — network debugging tools
#   VPN         Optional — mesh VPN for remote management

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

# ─── Parse arguments ────────────────────────────────────────────────────────

INSTALL_DIAGNOSTICS=true
INSTALL_VPN=""
MINIMAL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --minimal)       MINIMAL=true; INSTALL_DIAGNOSTICS=false; shift ;;
        --diagnostics)   INSTALL_DIAGNOSTICS=true; shift ;;
        --no-diagnostics) INSTALL_DIAGNOSTICS=false; shift ;;
        --vpn)           INSTALL_VPN="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--minimal] [--diagnostics] [--no-diagnostics] [--vpn netbird|tailscale]"
            echo ""
            echo "  --minimal         Only install base packages"
            echo "  --diagnostics     Include network diagnostics (default)"
            echo "  --no-diagnostics  Skip diagnostics packages"
            echo "  --vpn NAME        Install VPN (netbird or tailscale)"
            exit 0
            ;;
        *)  err "Unknown option: $1" ;;
    esac
done

# ─── Preflight ───────────────────────────────────────────────────────────────

[ "$(id -u)" -eq 0 ] || err "Must run as root"

log "Checking internet connectivity..."
ping -c 1 -W 5 deb.debian.org >/dev/null 2>&1 || err "No internet. Connect LTE first: mmcli -m 0 --simple-connect='apn=internet'"

log "Disk space: $(df -h / | tail -1 | awk '{print $4}') available"

# ─── Update package lists ───────────────────────────────────────────────────

log "Updating package lists..."
apt-get update -qq

# ─── Base packages (always installed) ────────────────────────────────────────

BASE_PACKAGES=(
    # Network essentials
    iproute2            # ip command — routing, interfaces, addresses
    curl                # HTTP client — health checks, API calls, downloads

    # System management
    cron                # Scheduled tasks (signal monitoring, cleanup)
    logrotate           # Log rotation — prevent disk fill on 3.5GB
    # watchdog          # TODO: hardware watchdog needs boot grace period testing first
    nano                # Text editor for config files
    less                # Pager for log files
    jq                  # JSON parser — scripting, API responses

    # Already installed but ensure present
    htop                # Process monitor
    openssh-server      # SSH access
    dnsmasq             # DHCP/DNS on USB interface
)

log "Installing base packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${BASE_PACKAGES[@]}"

# ─── Configure watchdog ─────────────────────────────────────────────────────

log "Configuring watchdog..."
if [ -e /dev/watchdog ]; then
    cat > /etc/watchdog.conf << 'EOF'
# Hardware watchdog — reboot if system hangs
watchdog-device = /dev/watchdog
watchdog-timeout = 60
interval = 15

# Reboot if these fail
ping = 127.0.0.1
retry-timeout = 60

# Reboot if load too high (4 cores)
max-load-1 = 24

# Reboot if memory critical
min-memory = 10000

# Log watchdog actions
log-dir = /var/log/watchdog
EOF
    systemctl enable watchdog 2>/dev/null || true
    log "Watchdog enabled (60s timeout)"
else
    warn "No hardware watchdog device found — skipping"
fi

# ─── Configure logrotate ─────────────────────────────────────────────────────

log "Configuring logrotate for embedded storage..."
cat > /etc/logrotate.d/dongle << 'EOF'
/var/log/syslog
/var/log/daemon.log
/var/log/kern.log
/var/log/auth.log
{
    rotate 2
    weekly
    maxsize 5M
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate 2>/dev/null || true
    endscript
}
EOF

# ─── Configure cron jobs ─────────────────────────────────────────────────────

log "Setting up monitoring cron jobs..."

mkdir -p /usr/local/bin

# Signal quality monitor — logs signal strength every 5 min
cat > /usr/local/bin/signal-monitor.sh << 'SCRIPT'
#!/bin/bash
# Log LTE signal quality
SIGNAL=$(mmcli -m 0 2>/dev/null | grep "signal quality" | grep -oE "[0-9]+%")
OPERATOR=$(mmcli -m 0 2>/dev/null | grep "operator name" | awk -F: '{print $NF}' | xargs)
STATE=$(mmcli -m 0 2>/dev/null | grep "state:" | head -1 | awk -F: '{print $NF}' | xargs)
TECH=$(mmcli -m 0 2>/dev/null | grep "access tech" | awk -F: '{print $NF}' | xargs)
echo "$(date -Iseconds) signal=$SIGNAL operator=$OPERATOR state=$STATE tech=$TECH" >> /var/log/signal.log
SCRIPT
chmod +x /usr/local/bin/signal-monitor.sh

# Connection watchdog — restart modem if connection drops
cat > /usr/local/bin/connection-watchdog.sh << 'SCRIPT'
#!/bin/bash
# Check LTE connectivity, restart modem if down
if ! ping -c 1 -W 10 8.8.8.8 >/dev/null 2>&1; then
    echo "$(date -Iseconds) connection lost, restarting modem" >> /var/log/connection-watchdog.log
    mmcli -m 0 --disable 2>/dev/null
    sleep 5
    mmcli -m 0 --enable 2>/dev/null
    sleep 15
    if ! ping -c 1 -W 10 8.8.8.8 >/dev/null 2>&1; then
        echo "$(date -Iseconds) modem restart failed, rebooting" >> /var/log/connection-watchdog.log
        reboot
    else
        echo "$(date -Iseconds) modem restart succeeded" >> /var/log/connection-watchdog.log
    fi
fi
SCRIPT
chmod +x /usr/local/bin/connection-watchdog.sh

# Data usage tracker
cat > /usr/local/bin/data-usage.sh << 'SCRIPT'
#!/bin/bash
# Log daily data usage on wwan0
RX=$(cat /sys/class/net/wwan0/statistics/rx_bytes 2>/dev/null || echo 0)
TX=$(cat /sys/class/net/wwan0/statistics/tx_bytes 2>/dev/null || echo 0)
RX_MB=$((RX / 1024 / 1024))
TX_MB=$((TX / 1024 / 1024))
echo "$(date -Iseconds) rx=${RX_MB}MB tx=${TX_MB}MB total=$((RX_MB + TX_MB))MB" >> /var/log/data-usage.log
SCRIPT
chmod +x /usr/local/bin/data-usage.sh

# Install crontab
cat > /etc/cron.d/dongle-monitoring << 'CRON'
# Signal quality every 5 minutes
*/5 * * * * root /usr/local/bin/signal-monitor.sh

# Connection watchdog every 3 minutes
*/3 * * * * root /usr/local/bin/connection-watchdog.sh

# Data usage every hour
0 * * * * root /usr/local/bin/data-usage.sh

# Sync clock daily (no RTC battery)
0 3 * * * root date -s "$(curl -sI http://google.com 2>/dev/null | grep -i '^date:' | cut -d' ' -f2-)" 2>/dev/null || true
CRON

# Logrotate for monitoring logs
cat > /etc/logrotate.d/dongle-monitoring << 'EOF'
/var/log/signal.log
/var/log/connection-watchdog.log
/var/log/data-usage.log
{
    rotate 4
    weekly
    maxsize 1M
    compress
    missingok
    notifempty
}
EOF

# ─── Diagnostics packages (optional) ────────────────────────────────────────

if $INSTALL_DIAGNOSTICS; then
    DIAG_PACKAGES=(
        tcpdump             # Packet capture
        mtr-tiny            # Combined ping + traceroute
        iperf3              # Bandwidth testing
        tmux                # Persistent SSH sessions
        nftables            # Modern firewall (alternative to iptables)
    )

    log "Installing diagnostics packages..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${DIAG_PACKAGES[@]}"
fi

# ─── VPN (optional) ─────────────────────────────────────────────────────────

if [ "$INSTALL_VPN" = "netbird" ]; then
    log "Installing NetBird..."
    curl -fsSL https://pkgs.netbird.io/install.sh | bash
    log "NetBird installed. Connect with: netbird up"

elif [ "$INSTALL_VPN" = "tailscale" ]; then
    log "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | bash
    log "Tailscale installed. Connect with: tailscale up"

elif [ -n "$INSTALL_VPN" ]; then
    warn "Unknown VPN: $INSTALL_VPN (supported: netbird, tailscale)"
fi

# ─── Cleanup ─────────────────────────────────────────────────────────────────

log "Cleaning up..."
apt-get clean
rm -rf /var/lib/apt/lists/*

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
log "Installation complete!"
echo ""
echo "  Base packages:   installed"
echo "  Watchdog:        $(systemctl is-enabled watchdog 2>/dev/null || echo 'not available')"
echo "  Logrotate:       configured"
echo "  Cron monitoring:"
echo "    - Signal quality:      every 5 min  → /var/log/signal.log"
echo "    - Connection watchdog: every 3 min  → auto-restart modem/reboot"
echo "    - Data usage:          every hour   → /var/log/data-usage.log"
echo "    - Clock sync:          daily"
if $INSTALL_DIAGNOSTICS; then
    echo "  Diagnostics:     tcpdump, mtr, iperf3, tmux, nftables"
fi
if [ -n "$INSTALL_VPN" ]; then
    echo "  VPN:             $INSTALL_VPN (run '${INSTALL_VPN} up' to connect)"
fi
echo ""
echo "  Disk used: $(df -h / | tail -1 | awk '{print $3}') / $(df -h / | tail -1 | awk '{print $2}')"
echo ""
