#!/bin/bash
#
# modem-autoconnect.sh — Auto-connect LTE and configure wwan0 on boot
#
# Called by modem-autoconnect.service after ModemManager starts.
# Waits for modem registration, connects with APN, configures wwan0 IP.
#
# APN is read from /etc/default/lte-apn (default: "internet")

APN_FILE="/etc/default/lte-apn"
APN=$(cat "$APN_FILE" 2>/dev/null | grep -v '^#' | head -1)
APN="${APN:-internet}"
LOG="/var/log/modem-autoconnect.log"
MAX_WAIT=120

log() { echo "$(date -Iseconds) $1" | tee -a "$LOG"; }

log "Starting auto-connect (APN=$APN)"

# Wait for modem detection
for i in $(seq 1 30); do
    mmcli -m 0 >/dev/null 2>&1 && break
    sleep 2
done
mmcli -m 0 >/dev/null 2>&1 || { log "ERROR: no modem after 60s"; exit 1; }

# Clear old log
> "$LOG"

get_state() { mmcli -m 0 -K 2>/dev/null | grep "modem.generic.state " | awk -F': ' '{print $2}' | xargs; }

# Enable modem (retry — modem DSP may still be initializing)
for attempt in 1 2 3 4 5; do
    STATE=$(get_state)
    log "Modem state: $STATE (attempt $attempt)"
    if [ "$STATE" = "registered" ] || [ "$STATE" = "connected" ]; then
        break
    elif [ "$STATE" = "disabled" ] || [ "$STATE" = "locked" ] || [ -z "$STATE" ]; then
        log "Enabling modem..."
        mmcli -m 0 --enable 2>/dev/null || true
        sleep 10
    else
        break  # searching, enabling, etc — move to registration wait
    fi
done

# Wait for registration
log "Waiting for registration..."
ELAPSED=0
while [ $ELAPSED -lt $MAX_WAIT ]; do
    STATE=$(get_state)
    [ "$STATE" = "registered" ] || [ "$STATE" = "connected" ] && break
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

[ "$STATE" != "registered" ] && [ "$STATE" != "connected" ] && { log "ERROR: not registered ($STATE)"; exit 1; }

OPER=$(mmcli -m 0 -K 2>/dev/null | grep "modem.3gpp.operator-name" | awk -F': ' '{print $2}' | xargs)
log "Registered: $OPER"

# Connect
if [ "$STATE" != "connected" ]; then
    log "Connecting APN=$APN..."
    mmcli -m 0 --simple-connect="apn=$APN" 2>&1 | tee -a "$LOG" || { log "ERROR: connect failed"; exit 1; }
    sleep 3
fi

# Find the data bearer (simple-connect creates a new one; initial-attach bearer has no IP)
BEARER_PATH=$(mmcli -m 0 -K 2>/dev/null | grep "modem.generic.bearers.value" | tail -1 | awk -F': ' '{print $2}' | xargs)
BEARER_IDX=$(echo "$BEARER_PATH" | grep -o '[0-9]*$')
BEARER_IDX="${BEARER_IDX:-0}"
log "Using bearer $BEARER_IDX"

BEARER=$(mmcli -b "$BEARER_IDX" 2>/dev/null)
echo "$BEARER" | grep -q "connected.*yes" || { log "ERROR: bearer $BEARER_IDX not connected"; exit 1; }

BEARER_K=$(mmcli -b "$BEARER_IDX" -K 2>/dev/null)
IP=$(echo "$BEARER_K" | grep "bearer.ipv4-config.address" | awk -F': ' '{print $2}' | xargs)
PREFIX=$(echo "$BEARER_K" | grep "bearer.ipv4-config.prefix" | awk -F': ' '{print $2}' | xargs)
GW=$(echo "$BEARER_K" | grep "bearer.ipv4-config.gateway" | awk -F': ' '{print $2}' | xargs)
DNS1=$(echo "$BEARER_K" | grep "bearer.ipv4-config.dns.value\[1\]" | awk -F': ' '{print $2}' | xargs)
DNS2=$(echo "$BEARER_K" | grep "bearer.ipv4-config.dns.value\[2\]" | awk -F': ' '{print $2}' | xargs)
MTU=$(echo "$BEARER_K" | grep "bearer.ipv4-config.mtu" | awk -F': ' '{print $2}' | xargs)

log "Bearer: $IP/$PREFIX gw=$GW dns=$DNS1,$DNS2"

ip link set wwan0 up
ip addr flush dev wwan0
ip addr add "$IP/$PREFIX" dev wwan0
[ -n "$MTU" ] && [ "$MTU" != "0" ] && ip link set wwan0 mtu "$MTU"
ip route add default via "$GW" dev wwan0 metric 50 2>/dev/null || \
    ip route add default dev wwan0 metric 50 2>/dev/null

echo "nameserver ${DNS1:-8.8.8.8}" > /etc/resolv.conf
[ -n "$DNS2" ] && echo "nameserver $DNS2" >> /etc/resolv.conf

ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1 && log "LTE verified (ping OK)" || log "WARNING: ping failed"
log "Done"
