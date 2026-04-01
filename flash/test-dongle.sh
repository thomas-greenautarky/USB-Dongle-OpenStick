#!/bin/bash
#
# test-dongle.sh — End-to-end test suite for OpenStick dongle
#
# Connects via SSH over RNDIS and verifies all key functions.
# Tests are ordered by dependency: if USB/SSH fails, modem tests are skipped.
#
# Usage:
#   bash test-dongle.sh              # default: 192.168.68.1, password openstick
#   bash test-dongle.sh 192.168.68.1 openstick
#
# Prerequisites:
#   - sshpass installed on host
#   - Dongle booted and reachable via USB RNDIS
#   - For modem tests: firmware + NV storage copied (post-flash step)

HOST="${1:-192.168.68.1}"
PASS="${2:-openstick}"
SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

which sshpass >/dev/null 2>&1 || { echo "Install sshpass: apt install sshpass"; exit 1; }

ssh_cmd() { SSHPASS="$PASS" sshpass -e ssh $SSH_OPTS "root@$HOST" "$1" 2>/dev/null; }

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASSED=0
FAILED=0
SKIPPED=0

pass() { echo -e "  ${GREEN}PASS${NC}  $1"; PASSED=$((PASSED + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}  $1 — $2"; FAILED=$((FAILED + 1)); }
skip() { echo -e "  ${YELLOW}SKIP${NC}  $1 — $2"; SKIPPED=$((SKIPPED + 1)); }

echo ""
echo "╔═══════════════════════════════════════╗"
echo "║   OpenStick Dongle Test Suite         ║"
echo "╚═══════════════════════════════════════╝"

# ─── 1. USB RNDIS ───────────────────────────────────────────────────────────

echo ""
echo "── 1. USB RNDIS ──"

if lsusb 2>/dev/null | grep -q "1d6b:0104"; then
    pass "RNDIS gadget detected (1d6b:0104)"
else
    fail "RNDIS gadget" "not found in lsusb"
fi

if ping -c 1 -W 3 "$HOST" >/dev/null 2>&1; then
    pass "Ping $HOST"
else
    fail "Ping $HOST" "unreachable — aborting"
    echo -e "\nResults: $PASSED passed, $FAILED failed"
    exit 1
fi

# ─── 2. SSH ──────────────────────────────────────────────────────────────────

echo ""
echo "── 2. SSH Access ──"

if ssh_cmd "echo OK" | grep -q OK; then
    pass "SSH login (root@$HOST)"
else
    fail "SSH login" "connection failed — aborting"
    echo -e "\nResults: $PASSED passed, $FAILED failed"
    exit 1
fi

# ─── 3. System ───────────────────────────────────────────────────────────────

echo ""
echo "── 3. System Basics ──"

KVER=$(ssh_cmd "uname -r")
[[ "$KVER" == *"6.6"*"msm8916"* ]] && pass "Kernel ($KVER)" || fail "Kernel" "got: $KVER"

DEBIAN=$(ssh_cmd "cat /etc/debian_version")
[[ "$DEBIAN" == 12* ]] && pass "Debian ($DEBIAN = bookworm)" || fail "Debian version" "got: $DEBIAN"

HOSTNAME=$(ssh_cmd "hostname")
[[ "$HOSTNAME" == "openstick" ]] && pass "Hostname ($HOSTNAME)" || fail "Hostname" "got: $HOSTNAME"

SYSTEMD=$(ssh_cmd "systemctl is-system-running 2>/dev/null")
[[ "$SYSTEMD" =~ running|degraded ]] && pass "systemd ($SYSTEMD)" || fail "systemd" "got: $SYSTEMD"

LIB=$(ssh_cmd "readlink /lib")
[[ "$LIB" == "usr/lib" ]] && pass "/lib → usr/lib (usrmerge)" || fail "/lib symlink" "got: $LIB"

# ─── 4. Kernel Modules ──────────────────────────────────────────────────────

echo ""
echo "── 4. Kernel Modules ──"

for mod in nf_nat nf_conntrack nf_tables xt_MASQUERADE; do
    if ssh_cmd "lsmod | grep -q $mod || modprobe $mod 2>/dev/null && lsmod | grep -q $mod"; then
        pass "$mod"
    else
        fail "$mod" "not loadable"
    fi
done

for mod in qcom_bam_dmux rmnet rpmsg_wwan_ctrl; do
    mod_under="${mod//-/_}"
    if ssh_cmd "lsmod | grep -q $mod_under || modprobe $mod 2>/dev/null && lsmod | grep -q $mod_under"; then
        pass "$mod"
    else
        fail "$mod" "not loadable"
    fi
done

# ─── 5. Services ─────────────────────────────────────────────────────────────

echo ""
echo "── 5. Services ──"

for svc in ssh dnsmasq usb-gadget rmtfs ModemManager; do
    STATE=$(ssh_cmd "systemctl is-active $svc 2>/dev/null")
    [[ "$STATE" == "active" ]] && pass "$svc" || fail "$svc" "$STATE"
done

# ─── 6. USB Network ─────────────────────────────────────────────────────────

echo ""
echo "── 6. USB Network ──"

USB_IP=$(ssh_cmd "ip -4 addr show usb0 | grep -oP 'inet \K[^ ]+'")
[[ "$USB_IP" == "192.168.68.1/24" ]] && pass "usb0 IP ($USB_IP)" || fail "usb0 IP" "got: $USB_IP"

FWD=$(ssh_cmd "sysctl -n net.ipv4.ip_forward")
[[ "$FWD" == "1" ]] && pass "IP forwarding" || fail "IP forwarding" "got: $FWD"

# ─── 7. Modem Hardware ──────────────────────────────────────────────────────

echo ""
echo "── 7. Modem ──"

# Firmware files
FW_OK=true
for f in modem.mdt mba.mbn; do
    if ssh_cmd "test -f /lib/firmware/$f"; then
        pass "Firmware: $f"
    else
        skip "Firmware: $f" "not copied (post-flash step)"
        FW_OK=false
    fi
done

# NV storage
for f in modem_fs1 modem_fs2 modem_fsg; do
    if ssh_cmd "test -f /boot/$f"; then
        pass "NV storage: $f"
    else
        skip "NV storage: $f" "not copied (post-flash step)"
        FW_OK=false
    fi
done

# Remoteproc
RPROC=$(ssh_cmd "cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null")
if [[ "$RPROC" == "running" ]]; then
    pass "Modem DSP (running)"
else
    skip "Modem DSP" "state=$RPROC"
fi

# QMI device
if ssh_cmd "test -c /dev/wwan0qmi0"; then
    pass "QMI port (/dev/wwan0qmi0)"
else
    skip "QMI port" "not present"
fi

# IMEI (via mmcli — AT port is held by ModemManager)
IMEI=$(ssh_cmd "mmcli -m 0 -K 2>/dev/null | grep modem.3gpp.imei | awk -F': ' '{print \$2}' | xargs")
if [ -n "$IMEI" ] && [ "$IMEI" != "--" ]; then
    pass "IMEI: $IMEI"
else
    skip "IMEI" "modem not detected"
fi

# SIM (via mmcli)
SIM_STATE=$(ssh_cmd "mmcli -m 0 -K 2>/dev/null | grep modem.generic.sim | head -1 | awk -F': ' '{print \$2}' | xargs")
if [ -n "$SIM_STATE" ] && [ "$SIM_STATE" != "--" ]; then
    pass "SIM card (detected)"
else
    skip "SIM card" "not detected"
fi

# ModemManager detection
MMCLI=$(ssh_cmd "mmcli -m 0 2>/dev/null")
if echo "$MMCLI" | grep -q "state"; then
    OPER=$(echo "$MMCLI" | grep "operator name" | awk -F': ' '{print $2}' | xargs)
    STATE=$(echo "$MMCLI" | grep "^\s*state" | awk -F': ' '{print $2}' | xargs)
    TECH=$(echo "$MMCLI" | grep "access tech" | awk -F': ' '{print $2}' | xargs)
    pass "ModemManager ($STATE, $OPER, $TECH)"
else
    skip "ModemManager" "no modem detected"
fi

# ─── 8. LTE Data ────────────────────────────────────────────────────────────

echo ""
echo "── 8. LTE Data ──"

BEARER=$(ssh_cmd "mmcli -b 0 2>/dev/null")
if echo "$BEARER" | grep -q "connected.*yes"; then
    IP=$(echo "$BEARER" | grep "address:" | head -1 | awk '{print $NF}')
    pass "LTE bearer (IP: $IP)"

    LTE_PING=$(ssh_cmd "ping -c 2 -W 5 8.8.8.8 2>/dev/null")
    if echo "$LTE_PING" | grep -q "bytes from"; then
        RTT=$(echo "$LTE_PING" | grep avg | awk -F'/' '{print $5}')
        pass "LTE ping 8.8.8.8 (${RTT}ms)"
    else
        fail "LTE ping" "no reply"
    fi

    DNS=$(ssh_cmd "ping -c 1 -W 5 google.com 2>/dev/null")
    if echo "$DNS" | grep -q "bytes from"; then
        pass "DNS resolution (google.com)"
    else
        fail "DNS" "not resolving"
    fi
else
    skip "LTE data" "not connected (run: mmcli -m 0 --simple-connect=\"apn=YOUR_APN\")"
fi

# ─── 9. NAT Gateway ─────────────────────────────────────────────────────────

echo ""
echo "── 9. NAT Gateway ──"

NAT=$(ssh_cmd "iptables -t nat -L POSTROUTING -n 2>/dev/null")
if echo "$NAT" | grep -q "MASQUERADE"; then
    pass "iptables MASQUERADE"
else
    fail "iptables MASQUERADE" "no rule found"
fi

# ─── 10. Resources ───────────────────────────────────────────────────────────

echo ""
echo "── 10. Resources ──"

DISK=$(ssh_cmd "df -h / | tail -1 | awk '{print \$4}'")
pass "Free disk: $DISK"

MEM=$(ssh_cmd "free -m | awk '/Mem/{print \$7}'")
pass "Available RAM: ${MEM}MB"

UPTIME=$(ssh_cmd "uptime -p")
pass "Uptime: $UPTIME"

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "╔═══════════════════════════════════════╗"
TOTAL=$((PASSED + FAILED + SKIPPED))
printf "║  ${GREEN}PASS: %-3d${NC}  ${RED}FAIL: %-3d${NC}  ${YELLOW}SKIP: %-3d${NC}  ║\n" $PASSED $FAILED $SKIPPED
echo "╚═══════════════════════════════════════╝"

if [ "$FAILED" -gt 0 ]; then
    echo -e "${RED}Some tests FAILED${NC}"
    exit 1
elif [ "$SKIPPED" -gt 0 ]; then
    echo -e "${YELLOW}All passed, some skipped (normal for fresh flash without modem setup)${NC}"
    exit 0
else
    echo -e "${GREEN}ALL TESTS PASSED${NC}"
    exit 0
fi
