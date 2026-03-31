#!/bin/bash
#
# test-dongle.sh — Verify a flashed OpenStick dongle is working
#
# Connects via SSH over RNDIS and checks all key services.
# Requires: sshpass, dongle at 192.168.68.1
#
# Usage:
#   bash test-dongle.sh [password]   # default password: openstick

DONGLE_IP="192.168.68.1"
PASS="${1:-openstick}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

which sshpass >/dev/null 2>&1 || { echo "Install sshpass: apt install sshpass"; exit 1; }

run() { SSHPASS="$PASS" sshpass -e ssh $SSH_OPTS "root@${DONGLE_IP}" "$1" 2>/dev/null; }

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

check() {
    local name="$1"
    local result="$2"
    local expect="$3"
    if echo "$result" | grep -q "$expect"; then
        echo -e "  ${GREEN}PASS${NC}  $name: $result"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "  ${RED}FAIL${NC}  $name: $result (expected: $expect)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

echo "=== OpenStick Dongle Test ==="
echo ""

# 0. USB check
echo "[Host]"
RNDIS=$(lsusb 2>/dev/null | grep "1d6b:0104")
check "RNDIS USB gadget" "${RNDIS:-not found}" "1d6b:0104"

PING=$(ping -c 1 -W 2 "$DONGLE_IP" 2>/dev/null | grep "1 received")
check "Ping $DONGLE_IP" "${PING:-no reply}" "1 received"

# 1. SSH connection
echo ""
echo "[SSH]"
CONN=$(run "echo OK")
check "SSH connection" "${CONN:-failed}" "OK"

if [ "$CONN" != "OK" ]; then
    echo ""
    echo "Cannot connect via SSH. Aborting."
    exit 1
fi

# 2. System
echo ""
echo "[System]"
KERNEL=$(run "uname -r")
check "Kernel" "$KERNEL" "msm8916\|handsomekernel"

OS=$(run "cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"'")
check "OS" "$OS" "Debian"

HOSTNAME=$(run "hostname")
check "Hostname" "$HOSTNAME" "openstick"

UPTIME=$(run "uptime -p")
check "Uptime" "$UPTIME" "up"

# 3. Network services
echo ""
echo "[Services]"
check "usb-gadget" "$(run 'systemctl is-active usb-gadget')" "active"
check "dnsmasq" "$(run 'systemctl is-active dnsmasq')" "active"
check "ssh" "$(run 'systemctl is-active ssh')" "active"
check "ModemManager" "$(run 'systemctl is-active ModemManager')" "active"

# 4. Network config
echo ""
echo "[Network]"
USB0_IP=$(run "ip -4 addr show usb0 2>/dev/null | grep inet | awk '{print \$2}'")
check "usb0 IP" "${USB0_IP:-not set}" "192.168.68.1"

FWD=$(run "sysctl -n net.ipv4.ip_forward")
check "IP forwarding" "$FWD" "1"

# 5. iptables/NAT
echo ""
echo "[NAT]"
MODULES=$(run "ls /lib/modules/ 2>/dev/null | head -1")
check "Kernel modules dir" "${MODULES:-missing}" "msm8916\|handsomekernel"

IPTABLES=$(run "iptables -t nat -L POSTROUTING -n 2>/dev/null | grep MASQ")
check "NAT masquerade" "${IPTABLES:-not loaded}" "MASQUERADE"

# 6. Modem
echo ""
echo "[Modem]"
MODEM=$(run "mmcli -L 2>/dev/null | head -1")
check "Modem detected" "${MODEM:-none}" "Qualcomm\|QUALCOMM\|/Modem"

# 7. Resources
echo ""
echo "[Resources]"
DISK=$(run "df -h / | tail -1 | awk '{print \$4}'")
check "Free disk" "$DISK" "G"

MEM=$(run "free -m | awk '/Mem/{print \$7}'")
check "Available RAM" "${MEM}MB" "[0-9]"

# Summary
echo ""
echo "================================"
echo -e "  ${GREEN}PASS: $PASS_COUNT${NC}  ${RED}FAIL: $FAIL_COUNT${NC}"
echo "================================"

exit $FAIL_COUNT
