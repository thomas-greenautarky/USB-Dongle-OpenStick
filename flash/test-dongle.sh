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
[[ -n "$HOSTNAME" ]] && pass "Hostname ($HOSTNAME)" || fail "Hostname" "empty"

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

# Firmware files (modem + WiFi)
FW_OK=true
for f in modem.mdt mba.mbn wcnss.mdt; do
    if ssh_cmd "test -f /lib/firmware/$f"; then
        pass "Firmware: $f"
    else
        fail "Firmware: $f" "missing (should be in build)"
        FW_OK=false
    fi
done

# WiFi NV calibration
if ssh_cmd "test -f /lib/firmware/wlan/prima/WCNSS_qcom_wlan_nv.bin"; then
    pass "WiFi NV: WCNSS_qcom_wlan_nv.bin"
else
    fail "WiFi NV" "missing /lib/firmware/wlan/prima/WCNSS_qcom_wlan_nv.bin"
fi

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

# WiFi interface (wcn36xx)
if ssh_cmd "test -d /sys/class/net/wlan0"; then
    pass "WiFi interface (wlan0)"
else
    fail "WiFi interface" "wlan0 not present (check wcnss firmware + NV cal)"
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

# Try both bearer 0 and 1 (bearer 0 is initial-attach, bearer 1 is data)
BEARER=$(ssh_cmd "mmcli -b 1 2>/dev/null")
echo "$BEARER" | grep -q "connected.*yes" || BEARER=$(ssh_cmd "mmcli -b 0 2>/dev/null")
if echo "$BEARER" | grep -q "connected.*yes"; then
    IP=$(echo "$BEARER" | grep "address:" | head -1 | awk '{print $NF}')
    pass "LTE bearer (IP: $IP)"

    # LTE data path reachability — HTTPS probe, NOT raw-IP ping.
    #
    # Many IoT APNs (e.g. Vodafone inetd.vodafone.iot with an FQDN-whitelist
    # ACL) blackhole raw-IP ICMP/TCP; `ping 8.8.8.8` therefore fails on
    # perfectly-working SIMs (false negative) and `ping google.com` fails
    # both on DNS (google.com may not be in the ACL) and ICMP. The HTTPS
    # probe to a whitelisted FQDN simultaneously verifies DNS + TCP + TLS
    # + cert chain + system clock + ACL allowance — a much better single
    # health signal for real-world SIMs.
    #
    # Default target `ghcr.io` is known-whitelisted on the Greenautarky
    # Vodafone IoT ACL. Override with LTE_PROBE_URL for other fleets.
    LTE_PROBE_URL="${LTE_PROBE_URL:-https://ghcr.io/}"
    LTE_PROBE=$(ssh_cmd "curl -sS --max-time 10 -o /dev/null -w '%{http_code}|%{ssl_verify_result}|%{time_total}' '$LTE_PROBE_URL' 2>&1")
    HTTP_CODE=$(echo "$LTE_PROBE" | awk -F'|' '{print $1}')
    SSL_OK=$(echo "$LTE_PROBE"    | awk -F'|' '{print $2}')
    RTT_S=$(echo "$LTE_PROBE"     | awk -F'|' '{print $3}')
    if [ -n "$HTTP_CODE" ] && [ "$HTTP_CODE" != "000" ] && [ "$SSL_OK" = "0" ]; then
        RTT_MS=$(awk -v s="$RTT_S" 'BEGIN{printf "%.0f", s*1000}' 2>/dev/null)
        pass "LTE HTTPS ($LTE_PROBE_URL → HTTP $HTTP_CODE, TLS ok, ${RTT_MS}ms)"
    else
        fail "LTE HTTPS" "$LTE_PROBE_URL unreachable (http=${HTTP_CODE:-none}, tls=${SSL_OK:-?})"
    fi

    # DNS — use a FQDN that's in the carrier ACL (derived from LTE_PROBE_URL).
    # `google.com` is NOT in the Greenautarky ACL, so looking it up from the
    # dongle's resolver fails even when DNS itself works fine.
    DNS_HOST=$(echo "$LTE_PROBE_URL" | awk -F'/' '{print $3}')
    if ssh_cmd "getent hosts '$DNS_HOST' 2>/dev/null | head -1" | grep -q "$DNS_HOST"; then
        pass "DNS resolution ($DNS_HOST)"
    else
        fail "DNS" "$DNS_HOST not resolving"
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

# ─── 10. Boot Persistence ─────────────────────────────────────────────────────

echo ""
echo "── 10. Boot Persistence ──"

# iptables rules file (loaded at boot by iptables-restore.service)
if ssh_cmd "test -f /etc/iptables/rules.v4"; then
    pass "iptables rules.v4 present"
else
    fail "iptables rules.v4" "missing — NAT won't survive reboot"
fi

# iptables-restore service
IPTREST=$(ssh_cmd "systemctl is-active iptables-restore 2>/dev/null")
[[ "$IPTREST" == "active" ]] && pass "iptables-restore.service" || fail "iptables-restore" "$IPTREST"

# modem-autoconnect service (active=running, inactive=completed successfully, activating=still working)
AUTOCONN=$(ssh_cmd "systemctl is-active modem-autoconnect 2>/dev/null")
[[ "$AUTOCONN" =~ active|inactive|activating ]] && pass "modem-autoconnect.service ($AUTOCONN)" || fail "modem-autoconnect" "$AUTOCONN"

# clock-sync service
CLOCK=$(ssh_cmd "systemctl is-active clock-sync 2>/dev/null")
[[ "$CLOCK" == "active" ]] || [[ "$CLOCK" == "inactive" ]] && pass "clock-sync.service (ran)" || fail "clock-sync" "$CLOCK"

# System clock sanity (should be 2025+ not 1970)
YEAR=$(ssh_cmd "date +%Y")
[[ "$YEAR" -ge 2025 ]] && pass "System clock ($YEAR)" || fail "System clock" "year=$YEAR (not synced)"

# APN config
APN=$(ssh_cmd "cat /etc/default/lte-apn 2>/dev/null | grep -v '^#' | head -1")
[[ -n "$APN" ]] && pass "APN config ($APN)" || fail "APN config" "missing /etc/default/lte-apn"

# ─── 11. Resources ───────────────────────────────────────────────────────────

echo ""
echo "── 11. Resources ──"

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
