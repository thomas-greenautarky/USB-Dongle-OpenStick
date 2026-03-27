#!/bin/bash
# Wait for modem, then enable it if disabled
sleep 15
for i in $(seq 1 10); do
    if mmcli -m 0 >/dev/null 2>&1; then
        STATE=$(mmcli -m 0 2>/dev/null | grep "state:" | head -1 | awk -F: '{print $NF}' | xargs)
        if [ "$STATE" = "disabled" ]; then
            mmcli -m 0 --enable 2>/dev/null
            echo "$(date -Iseconds) modem enabled" >> /var/log/connection-watchdog.log
        fi
        break
    fi
    sleep 5
done
