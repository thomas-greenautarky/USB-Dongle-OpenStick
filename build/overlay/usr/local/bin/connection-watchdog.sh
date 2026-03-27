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
