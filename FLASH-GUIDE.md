# OpenStick Flash Guide for JZ0145-v33 (UFI 4G Dongle)

This documents the complete flash procedure discovered through extensive
testing. The JZ0145-v33 board has specific boot chain requirements that
differ from standard OpenStick instructions.

## Background

### The Problem

The standard OpenStick flash procedure (kinsamanka's `start.sh`) assumes:
1. Flash a test bootloader to aboot via EDL
2. Reboot to fastboot
3. Flash everything via fastboot

On JZ02/JZ0145-v33 boards, this fails because:
- The stock SBL1 expects **ELF binaries** in the aboot partition
- lk2nd is packaged as an **Android boot image** (not ELF) — SBL1 can't load it
- qhypstub (needed for mainline Linux) **breaks the stock SBL1 boot chain**

### The Solution

Use a **two-stage approach**:

1. **Stage 1** (EDL): Flash the Dragonboard aboot (ELF format) — stock SBL1 can load it
2. **Stage 2** (Fastboot): Flash EVERYTHING including Dragonboard SBL1/RPM/TZ,
   replacing the stock boot chain entirely

After Stage 2, the device boots with the Dragonboard firmware stack which IS
compatible with qhypstub and the mainline Linux kernel.

## Prerequisites

```bash
# EDL tool
pipx install edlclient

# Android tools
sudo apt install fastboot adb

# Verify dongle is connected (stock Android)
adb devices
# Should show: 0  device
```

## Procedure

### Step 1: Enter EDL Mode

From running Android:
```bash
adb reboot edl
```

Or manually: hold reset button (pin hole) while plugging in USB.

Verify:
```bash
lsusb | grep 9008
# Bus xxx Device xxx: ID 05c6:9008 Qualcomm, Inc. Gobi Wireless Modem (QDL mode)
```

### Step 2: Flash Dragonboard Aboot via EDL

```bash
cd flash/files

# Flash the Dragonboard bootloader to aboot partition
edl w aboot emmc_appsboot-test-signed.mbn

# Erase boot partition (forces fastboot mode on next boot)
edl e boot

# Reset the device
edl reset
```

### Step 3: Verify Fastboot

Wait ~10 seconds, then:
```bash
fastboot devices
# Should show: e80fd820  fastboot
```

If no fastboot: the stock SBL1 couldn't load the Dragonboard aboot. Try
power-cycling (unplug, wait 5s, replug without reset button).

### Step 4: Flash Everything via Fastboot

```bash
# Partition table
fastboot flash partition gpt_both0.bin

# Dragonboard firmware (replaces stock boot chain)
fastboot flash aboot emmc_appsboot-test-signed.mbn
fastboot flash hyp   qhypstub-test-signed.mbn
fastboot flash rpm   rpm.mbn
fastboot flash sbl1  sbl1.mbn
fastboot flash tz    tz.mbn
fastboot flash cdt   sbc_1.0_8016.bin

# OpenStick kernel + Debian rootfs
fastboot flash boot  boot-ufi001c.img
fastboot flash rootfs rootfs.img           # Takes 2-5 minutes
```

### Step 5: Restore Modem Calibration

The modem calibration data (IMEI, RF calibration) is device-specific.
Restore from backup:

```bash
cd ../backup/partitions
fastboot flash sec      sec.bin
fastboot flash fsc      fsc.bin
fastboot flash fsg      fsg.bin
fastboot flash modemst1 modemst1.bin
fastboot flash modemst2 modemst2.bin
```

### Step 6: Reboot

```bash
fastboot reboot
```

Wait 30 seconds. Verify:
```bash
adb devices
# Should show: 0123456789  device

adb shell uname -a
# Linux openstick 5.15.0-handsomekernel+ ... aarch64 GNU/Linux
```

## Post-Flash Configuration

### Set Root Password
```bash
adb shell 'echo "root:YOUR_PASSWORD" | chpasswd'
```

### Enable SSH Root Login
```bash
adb shell 'sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config'
adb shell 'systemctl restart sshd'
```

### SSH Access
The dongle creates a USB network interface (RNDIS) at 192.168.68.1:
```bash
# Add IP to your USB network interface
sudo ip addr add 192.168.68.100/16 dev enxXXXXXXXXXXXX
ssh root@192.168.68.1
```

Or via ADB port forward:
```bash
adb forward tcp:2222 tcp:22
ssh -p 2222 root@127.0.0.1
```

### Configure LTE
```bash
adb shell mmcli -m 0 --simple-connect="apn=YOUR_APN"
```

### Configure WiFi Hotspot
```bash
adb shell nmcli connection add type wifi ifname wlan0 con-name hotspot \
  wifi.mode ap wifi.ssid "MY-HOTSPOT" \
  802-11-wireless-security.key-mgmt wpa-psk \
  802-11-wireless-security.psk "MY-PASSWORD" \
  ipv4.method shared ipv4.addresses 192.168.4.1/24
```

### Enable NAT (USB → LTE forwarding)
```bash
adb shell 'sysctl -w net.ipv4.ip_forward=1'
adb shell 'nft add table inet nat'
adb shell 'nft add chain inet nat postrouting { type nat hook postrouting priority 100 \; }'
adb shell 'nft add rule inet nat postrouting oifname "wwan0" masquerade'
```

## Troubleshooting

### No fastboot after Step 2
- Power cycle: unplug, wait 10s, replug (no reset button)
- If still nothing: restore stock aboot via EDL, verify stock Android boots

### Device shows 05c6:9006 but no fastboot
- This is the modem diagnostic interface — the AP isn't booting
- Check if aboot/hyp were flashed correctly

### Kernel boots but no USB network
- DTB mismatch: the boot-ufi001c.img uses the UFI001C device tree
- Future fix: build kernel with JZ0145-v33 device tree

### Need to restore stock firmware
```bash
# Enter EDL (hold reset while plugging in)
cd backup/partitions
edl ws 0 ../full_firmware.bin   # Full 3.7 GB restore
# Or restore GPT + individual partitions:
# edl ws 0 gpt_main0_padded.bin
# edl w sbl1 sbl1.bin
# edl w aboot aboot.bin
# ... etc
```

## Post-Flash Configuration (Critical)

After the initial flash, three additional steps are required before the
dongle is fully functional.

### 1. Copy device-specific modem firmware

The rootfs ships with generic MSM8916 modem firmware. For the modem to
actually connect to LTE networks, you MUST copy the device-specific
firmware from the backup modem partition:

```bash
# Push backup images to the device
adb push backup/partitions/modem.bin /tmp/modem.bin
adb push backup/partitions/persist.bin /tmp/persist.bin

# Mount and copy on device
adb shell 'mount /tmp/modem.bin /mnt && cp /mnt/image/m* /mnt/image/wc* /lib/firmware/ && umount /mnt'
adb shell 'mount /tmp/persist.bin /mnt && cp /mnt/WCNSS_qcom_wlan_nv.bin /lib/firmware/wlan/prima/ && umount /mnt'
adb shell 'rm /tmp/*.bin'
```

Without this step, `mmcli -m 0` shows `DeviceNotReady` errors.

### 2. Patch the device tree

The boot image ships with the UFI001C ("Handsome Openstick") device tree.
For correct LED, SIM slot, and GPIO support, patch it for JZ0145-v33:

```bash
# On the host:
adb pull /sys/firmware/fdt /tmp/fdt
wget -qO /tmp/patch.dts "https://gist.github.com/kinsamanka/0b01cd02412bd13ee072072043d46fa2/raw/patch.dts"
dtc -I dtb -O dts /tmp/fdt -o /tmp/default.dts
cat /tmp/default.dts /tmp/patch.dts | dtc -I dts -O dts -o /tmp/jz01-45-v33.dts
dtc -I dts -O dtb /tmp/jz01-45-v33.dts -o /tmp/jz01-45-v33.dtb
adb push /tmp/jz01-45-v33.dtb /boot/
```

Then set up extlinux boot with the patched DTB:

```bash
adb shell 'mkfs.ext2 /dev/disk/by-partlabel/boot'
adb shell 'mount /dev/disk/by-partlabel/boot /mnt'
adb shell 'mkdir -p /mnt/extlinux'
adb shell 'cat > /mnt/extlinux/extlinux.conf << EOF
linux /vmlinuz
initrd /initrd.img
fdt /default.dtb
append earlycon root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e console=ttyMSM0,115200 no_framebuffer=true rw rootwait
EOF'
adb shell 'cp /boot/vmlinuz-* /mnt/vmlinuz'
adb shell 'cp /boot/initrd.img-* /mnt/initrd.img'
adb shell 'cp /boot/jz01-45-v33.dtb /mnt/ && ln -sf jz01-45-v33.dtb /mnt/default.dtb'
adb shell 'umount /mnt'
```

The Dragonboard aboot (emmc_appsboot) supports extlinux boot natively
from ext2 partitions — no lk2nd needed.

### 3. Set up NAT gateway

```bash
adb shell 'sysctl -w net.ipv4.ip_forward=1'
adb shell 'echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forward.conf'
adb shell 'iptables -t nat -A POSTROUTING -o wwan0 -j MASQUERADE'
adb shell 'mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4'
```

Note: The rootfs does NOT have `nft` installed. Use `iptables` for NAT.

The `configure-dongle.sh` script automates all three steps plus SSH, WiFi,
hostname, and APN configuration.

## Key Learnings

1. **Boot chain compatibility matters**: The stock Juzhen SBL1 is picky about
   what it loads. Only ELF binaries work in aboot. qhypstub breaks the chain.

2. **Two-stage flash is essential**: First get into fastboot (using a compatible
   aboot), then replace the entire firmware stack.

3. **Backup everything first**: The modem calibration data (modemst1/2, fsc, fsg)
   AND the modem firmware partition are unique per device and cannot be regenerated.

4. **Device-specific modem firmware is critical**: The generic firmware in the
   rootfs results in `DeviceNotReady` errors. You must copy firmware from the
   backup modem partition image.

5. **lk2nd goes in BOOT, not ABOOT**: The stock SBL1 expects ELF in aboot.
   lk2nd (Android boot image format) must go in the boot partition where it
   gets loaded as a "kernel" by the stock aboot. lk2nd provides fastboot
   recovery and hardware detection. For initial flash, the Dragonboard aboot
   is used instead.

6. **qhypstub breaks stock SBL1**: The stock Qualcomm hypervisor must be
   replaced along with the entire Dragonboard firmware stack (SBL1, RPM, TZ).
   You cannot mix stock SBL1 with qhypstub.

7. **Mainline kernel requires qhypstub**: Testing confirmed the OpenStick kernel
   crashes immediately under the stock Qualcomm hypervisor. The Dragonboard
   firmware stack (with qhypstub) is mandatory.

8. **Custom GPT breaks boot**: A "hybrid" GPT with modified early partitions
   causes intermittent boot failures. The OpenStick GPT (`gpt_both0.bin`) must
   be flashed via fastboot (which handles sector remapping), not via EDL.

9. **The Dragonboard aboot supports extlinux boot**: `emmc_appsboot` can read
   ext2 boot partitions with extlinux.conf, enabling DTB selection without lk2nd.

10. **USB port matters**: Unreliable USB connections (through hubs) can cause
    EDL writes to fail silently. Use a direct USB port if possible.

11. **SSH PAM modules can hang on embedded**: Disable `pam_loginuid` and
    `pam_selinux` in `/etc/pam.d/sshd`, and add `UseDNS no` to `sshd_config`.

12. **System clock must be set**: The dongle has no RTC battery. Wrong date
    (default: 2021) can cause auth timeouts. Set the date on first boot.
