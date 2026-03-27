#!/bin/bash
# Log LTE signal quality
SIGNAL=$(mmcli -m 0 2>/dev/null | grep "signal quality" | grep -oE "[0-9]+%")
OPERATOR=$(mmcli -m 0 2>/dev/null | grep "operator name" | awk -F: '{print $NF}' | xargs)
STATE=$(mmcli -m 0 2>/dev/null | grep "state:" | head -1 | awk -F: '{print $NF}' | xargs)
TECH=$(mmcli -m 0 2>/dev/null | grep "access tech" | awk -F: '{print $NF}' | xargs)
echo "$(date -Iseconds) signal=$SIGNAL operator=$OPERATOR state=$STATE tech=$TECH" >> /var/log/signal.log
