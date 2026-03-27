#!/bin/bash
# Check LTE connectivity, restart modem service if down
# Skip during first 3 minutes after boot (modem needs time to register on LTE)
UPTIME=$(awk '{print int($1)}' /proc/uptime)
if [ "$UPTIME" -lt 180 ]; then
    exit 0
fi

if ! ping -c 1 -W 10 8.8.8.8 >/dev/null 2>&1; then
    echo "$(date -Iseconds) connection lost, restarting ModemManager" >> /var/log/connection-watchdog.log
    systemctl restart ModemManager
    sleep 30
    if ! ping -c 1 -W 10 8.8.8.8 >/dev/null 2>&1; then
        echo "$(date -Iseconds) ModemManager restart failed, rebooting" >> /var/log/connection-watchdog.log
        reboot
    else
        echo "$(date -Iseconds) ModemManager restart succeeded" >> /var/log/connection-watchdog.log
    fi
fi
