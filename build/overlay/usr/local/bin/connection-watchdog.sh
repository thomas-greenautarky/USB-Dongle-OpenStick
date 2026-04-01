#!/bin/bash
#
# connection-watchdog.sh — Monitor LTE connectivity, restart if down
#
# Called by cron every 3 minutes. Skips the first 5 minutes after boot
# to allow modem registration + auto-connect to complete.
#
# Recovery strategy:
#   1. Ping fails → restart modem-autoconnect (reconnect LTE)
#   2. Still fails → restart ModemManager (full modem reset)
#   3. Still fails → reboot (last resort)

LOG="/var/log/connection-watchdog.log"
GRACE_PERIOD=300  # seconds after boot to skip checks

log() { echo "$(date -Iseconds) $1" >> "$LOG"; }

# Skip during boot grace period
UPTIME=$(awk '{print int($1)}' /proc/uptime)
if [ "$UPTIME" -lt "$GRACE_PERIOD" ]; then
    exit 0
fi

# Check connectivity
if ping -c 1 -W 10 8.8.8.8 >/dev/null 2>&1; then
    exit 0
fi

log "connection lost, attempting recovery"

# Step 1: re-run auto-connect
systemctl restart modem-autoconnect
sleep 30
if ping -c 1 -W 10 8.8.8.8 >/dev/null 2>&1; then
    log "recovered via modem-autoconnect restart"
    exit 0
fi

# Step 2: restart ModemManager
log "auto-connect failed, restarting ModemManager"
systemctl restart ModemManager
sleep 10
systemctl restart modem-autoconnect
sleep 30
if ping -c 1 -W 10 8.8.8.8 >/dev/null 2>&1; then
    log "recovered via ModemManager restart"
    exit 0
fi

# Step 3: reboot
log "all recovery failed, rebooting"
reboot
