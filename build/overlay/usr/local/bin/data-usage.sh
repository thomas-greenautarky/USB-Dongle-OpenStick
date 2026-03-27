#!/bin/bash
# Log daily data usage on wwan0
RX=$(cat /sys/class/net/wwan0/statistics/rx_bytes 2>/dev/null || echo 0)
TX=$(cat /sys/class/net/wwan0/statistics/tx_bytes 2>/dev/null || echo 0)
RX_MB=$((RX / 1024 / 1024))
TX_MB=$((TX / 1024 / 1024))
echo "$(date -Iseconds) rx=${RX_MB}MB tx=${TX_MB}MB total=$((RX_MB + TX_MB))MB" >> /var/log/data-usage.log
