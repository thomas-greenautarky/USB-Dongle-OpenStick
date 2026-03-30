#!/bin/bash
#
# usb-gadget.sh — Configure USB RNDIS network gadget via configfs
#
# Creates a USB RNDIS ethernet adapter so the host PC sees the dongle
# as a network device. The dongle gets IP 192.168.68.1, the host gets
# an IP via DHCP (dnsmasq) and can SSH into the dongle.
#
# This replaces ADB — we use standard SSH over USB networking.

set -e

GADGET_DIR="/sys/kernel/config/usb_gadget/g1"

# Tear down if already running
if [ -d "$GADGET_DIR" ]; then
    echo "" > "$GADGET_DIR/UDC" 2>/dev/null || true
    rm -f "$GADGET_DIR/configs/c.1/rndis.usb0" 2>/dev/null || true
    rmdir "$GADGET_DIR/configs/c.1/strings/0x409" 2>/dev/null || true
    rmdir "$GADGET_DIR/configs/c.1" 2>/dev/null || true
    rmdir "$GADGET_DIR/functions/rndis.usb0" 2>/dev/null || true
    rmdir "$GADGET_DIR/strings/0x409" 2>/dev/null || true
    rmdir "$GADGET_DIR" 2>/dev/null || true
fi

# Load modules
modprobe configfs 2>/dev/null || true
modprobe libcomposite 2>/dev/null || true
modprobe usb_f_rndis 2>/dev/null || true

# Mount configfs if needed
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config

# Create gadget
mkdir -p "$GADGET_DIR"
cd "$GADGET_DIR"

echo 0x1d6b > idVendor   # Linux Foundation
echo 0x0104 > idProduct   # Multifunction Composite Gadget
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB

# Device strings
mkdir -p strings/0x409
echo "openstick" > strings/0x409/serialnumber
echo "OpenStick" > strings/0x409/manufacturer
echo "OpenStick RNDIS" > strings/0x409/product

# RNDIS function
mkdir -p functions/rndis.usb0

# Generate a stable MAC from the hostname so it doesn't change across reboots
HOST_HASH=$(echo -n "$(cat /etc/hostname 2>/dev/null || echo openstick)" | md5sum | cut -c1-10)
echo "02:${HOST_HASH:0:2}:${HOST_HASH:2:2}:${HOST_HASH:4:2}:${HOST_HASH:6:2}:${HOST_HASH:8:2}" > functions/rndis.usb0/dev_addr
echo "12:${HOST_HASH:0:2}:${HOST_HASH:2:2}:${HOST_HASH:4:2}:${HOST_HASH:6:2}:${HOST_HASH:8:2}" > functions/rndis.usb0/host_addr

# Configuration
mkdir -p configs/c.1/strings/0x409
echo "RNDIS" > configs/c.1/strings/0x409/configuration
echo 500 > configs/c.1/MaxPower

# Link function to configuration
ln -s functions/rndis.usb0 configs/c.1/

# Bind to UDC (USB Device Controller)
UDC=$(ls /sys/class/udc/ 2>/dev/null | head -1)
if [ -z "$UDC" ]; then
    echo "ERROR: No UDC found" >&2
    exit 1
fi
echo "$UDC" > UDC

# Wait for usb0 to appear
for i in $(seq 1 10); do
    ip link show usb0 >/dev/null 2>&1 && break
    sleep 1
done

# Configure IP directly — no dependency on networking.service timing
ip link set usb0 up
ip addr add 192.168.68.1/24 dev usb0 2>/dev/null || true

echo "USB RNDIS gadget active on $UDC, usb0 at 192.168.68.1"
