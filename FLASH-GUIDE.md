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

On JZ02/JZ0145-v33 boards, the fastboot approach is **unreliable**:
- The Dragonboard aboot's fastboot interface uses USB ID `18d1:d001` or `05c6:9091`
- The host `fastboot` tool (v34.0.5) cannot communicate with either USB ID
- ADB server holds the USB device, preventing fastboot access
- Even with ADB killed, fastboot times out on command responses
- Erasing both boot+recovery doesn't help — device shows 9091 (Android composite)
  with a fastboot interface that doesn't respond

Additionally:
- The stock SBL1 expects **ELF binaries** in the aboot partition
- lk2nd is packaged as an **Android boot image** (not ELF) — SBL1 can't load it
- qhypstub (needed for mainline Linux) **breaks the stock SBL1 boot chain**

### The Solution: EDL-Only Flash

Write everything directly to eMMC via EDL (Qualcomm Emergency Download mode).
No fastboot step is needed. EDL mode is always available via the reset button +
USB plug, even on a completely bricked device.

The key insight is that GPT, firmware, kernel, and rootfs can all be written
as raw sector data via EDL, bypassing the aboot/fastboot layer entirely.

## Prerequisites

```bash
# EDL tool
pipx install edlclient

# Android tools (ADB for post-flash configuration only)
sudo apt install adb

# Verify dongle is connected (stock Android) — optional, for adb reboot edl
adb devices
# Should show: 0  device
```

## Procedure (EDL-Only Method)

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

### Step 2: Write GPT (split primary + backup)

The GPT must be written as two separate files. The original `gpt_both0.bin`
has bugs: rootfs is a 1MB placeholder, and the backup GPT lands at the wrong
sector when written via EDL. The `gpt_both0_fixed.bin` also had issues
(last_usable_lba was 283652, not using the full disk).

The correct approach uses `gpt_primary_proper.bin` + `gpt_backup_proper.bin`,
which have the correct rootfs size (3.6 GB), correct alternate_lba, and
correct backup header at the true end of disk.

```bash
cd flash/files

# Primary GPT at sector 0
edl ws 0 gpt_primary_proper.bin

# Backup GPT at end of disk (sector 7733215 for 4GB eMMC)
edl ws 7733215 gpt_backup_proper.bin
```

### Step 3: Flash Dragonboard Firmware via EDL

```bash
# Dragonboard firmware (replaces stock boot chain)
edl w sbl1  sbl1.mbn
edl w rpm   rpm.mbn
edl w tz    tz.mbn
edl w hyp   qhypstub-test-signed.mbn
edl w cdt   sbc_1.0_8016.bin
edl w aboot emmc_appsboot-test-signed.mbn
```

### Step 4: Flash Boot Image + Rootfs via EDL

```bash
# Boot image with JZ0145-v33 DTB baked in (Android boot image format)
edl w boot boot-jz0145.img

# Debian rootfs (raw image, takes 2-5 minutes)
edl w rootfs rootfs.raw
```

**IMPORTANT**: Use `boot-jz0145.img` (with JZ0145-v33 DTB baked in), NOT
`boot-ufi001c.img`. The JZ0145-v33 DTB provides correct SIM detection, LED
control, and GPIO mappings for this board. The extlinux approach (reformatting
boot to ext2 with extlinux.conf) broke boot because the Dragonboard aboot's
fastboot interface is unreachable from the host, making recovery impossible
without re-flashing via EDL.

### Step 5: Restore Modem Calibration

The modem calibration data (IMEI, RF calibration) is device-specific.
Restore from backup:

```bash
cd ../../backup/partitions
edl w sec      sec.bin
edl w fsc      fsc.bin
edl w fsg      fsg.bin
edl w modemst1 modemst1.bin
edl w modemst2 modemst2.bin
```

### Step 6: Reset and Verify

```bash
edl reset
```

Wait 30 seconds. Verify:
```bash
adb devices
# Should show: 0123456789  device

adb shell uname -a
# Linux openstick 5.15.0-handsomekernel+ ... aarch64 GNU/Linux
```

## Post-Flash Configuration

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

### 2. Fix apt sources and set clock

```bash
# Fix apt sources (Debian 11 bullseye is archived)
adb shell 'sed -i "s|deb.debian.org|archive.debian.org|g" /etc/apt/sources.list'
adb shell 'sed -i "/security.debian.org/d" /etc/apt/sources.list'

# Set system clock (no RTC battery, defaults to 2021)
adb shell "date -s '$(date -u '+%Y-%m-%d %H:%M:%S')'"
```

### 3. Set Root Password
```bash
adb shell 'echo "root:YOUR_PASSWORD" | chpasswd'
```

### 4. Enable SSH Root Login
```bash
adb shell 'sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config'
adb shell 'grep -q "^UseDNS" /etc/ssh/sshd_config || echo "UseDNS no" >> /etc/ssh/sshd_config'
adb shell 'sed -i "s/^.*pam_loginuid.*/#&/" /etc/pam.d/sshd'
adb shell 'sed -i "s/^.*pam_selinux.*/#&/" /etc/pam.d/sshd'
adb shell 'systemctl restart sshd'
```

### 5. SSH Access
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

### 6. Configure LTE
```bash
adb shell mmcli -m 0 --simple-connect="apn=YOUR_APN"
```

### 7. Set up NAT gateway (USB → LTE forwarding)
```bash
adb shell 'sysctl -w net.ipv4.ip_forward=1'
adb shell 'echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forward.conf'
adb shell 'iptables -t nat -A POSTROUTING -o wwan0 -j MASQUERADE'
adb shell 'mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4'
```

Note: The rootfs does NOT have `nft` installed. Use `iptables` for NAT.

### 8. Configure WiFi Hotspot (optional)
```bash
adb shell nmcli connection add type wifi ifname wlan0 con-name hotspot \
  wifi.mode ap wifi.ssid "MY-HOTSPOT" \
  802-11-wireless-security.key-mgmt wpa-psk \
  802-11-wireless-security.psk "MY-PASSWORD" \
  ipv4.method shared ipv4.addresses 192.168.4.1/24
```

## Troubleshooting

### Device not booting after flash
- Re-enter EDL (hold reset button while plugging in USB)
- Verify GPT was written correctly: primary at sector 0, backup at sector 7733215
- Re-flash all firmware partitions via EDL

### Device shows 05c6:9006 but doesn't boot
- This is the modem diagnostic interface — the AP isn't booting
- Check if sbl1/aboot/hyp were flashed correctly via EDL

### Kernel boots but no USB network
- DTB mismatch: make sure you used `boot-jz0145.img` (with JZ0145-v33 DTB),
  NOT `boot-ufi001c.img` (UFI001C DTB)

### SIM not detected
- With JZ0145-v33 DTB (`boot-jz0145.img`), SIM is detected reliably
- If still not detected, try physically unplugging and replugging the dongle
- Once detected, modem connects to LTE automatically

### Modem shows DeviceNotReady
- You must copy device-specific modem firmware from backup (see Post-Flash step 1)
- The generic firmware in the rootfs does not work

### Fastboot not working (expected)
- The Dragonboard aboot fastboot interface uses USB ID `18d1:d001` or `05c6:9091`
- Host `fastboot` tool cannot communicate with either ID
- ADB server may hold the USB device, blocking fastboot access
- This is why we use the EDL-only method — fastboot is not needed

### Need to restore stock firmware (unbricking)
EDL mode is always available via reset button + USB plug, even on a bricked
device. Full stock restore from `backup/partitions/` takes about 5 minutes:

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

Stock Android always boots after a full restore (verified many times).

## Post-Flash Configuration (Critical)

After the initial flash, several steps are required before the dongle is
fully functional. These are covered in detail in the "Post-Flash
Configuration" section above.

The `configure-dongle.sh` script automates all steps: modem firmware copy,
apt sources fix, clock sync, SSH, NAT, WiFi, hostname, and APN configuration.

### Why no extlinux / DTB patching?

Earlier attempts used extlinux boot (reformatting the boot partition to ext2
with extlinux.conf and a patched JZ0145-v33 DTB). This broke boot because
if anything goes wrong, the only recovery path is via the Dragonboard aboot's
fastboot interface, which uses USB ID `18d1:d001` / `05c6:9091` that the host
`fastboot` tool cannot communicate with.

The solution is `boot-jz0145.img` — an Android boot image with the JZ0145-v33
DTB baked in. This works with the Dragonboard aboot (emmc_appsboot) and
provides correct SIM detection, LED control, and GPIO mappings without
needing extlinux or DTB patching at runtime.

## Key Learnings

1. **EDL-only flash is the reliable method**: The Dragonboard aboot's fastboot
   interface (USB ID `18d1:d001` / `05c6:9091`) cannot be reached by the host
   `fastboot` tool. ADB server holds the USB device, and even with ADB killed,
   fastboot times out. Write everything directly via EDL instead.

2. **GPT must be split into primary + backup**: The original `gpt_both0.bin`
   has a 1MB rootfs placeholder and puts the backup GPT at the wrong sector
   when written via EDL. The `gpt_both0_fixed.bin` had `last_usable_lba` of
   283652 (not the full disk). Use `gpt_primary_proper.bin` (sector 0) +
   `gpt_backup_proper.bin` (sector 7733215) for correct rootfs (3.6 GB) and
   correct backup header placement.

3. **Use Android boot image with baked-in DTB**: `boot-jz0145.img` has the
   JZ0145-v33 DTB compiled in. The extlinux approach (reformatting boot to
   ext2) broke boot because recovery via fastboot is impossible on this board.
   Keep the Android boot image format — it works with the Dragonboard aboot.

4. **Backup everything first**: The modem calibration data (modemst1/2, fsc, fsg)
   AND the modem firmware partition are unique per device and cannot be regenerated.

5. **Device-specific modem firmware is critical**: The generic firmware in the
   rootfs results in `DeviceNotReady` errors. You must copy firmware from the
   backup modem partition image.

6. **qhypstub breaks stock SBL1**: The stock Qualcomm hypervisor must be
   replaced along with the entire Dragonboard firmware stack (SBL1, RPM, TZ).
   You cannot mix stock SBL1 with qhypstub.

7. **Mainline kernel requires qhypstub**: Testing confirmed the OpenStick kernel
   crashes immediately under the stock Qualcomm hypervisor. The Dragonboard
   firmware stack (with qhypstub) is mandatory.

8. **SIM detection depends on DTB**: With UFI001C DTB, SIM is often not detected.
   With JZ0145-v33 DTB (baked into `boot-jz0145.img`), SIM is detected reliably.
   Sometimes requires a physical replug. Once detected, modem connects to LTE
   automatically.

9. **Watchdog causes reboot loops**: Hardware watchdog + connection watchdog
   caused reboot loops because the LTE modem needs 60-90s to register after
   boot. Connection watchdog must skip the first 180s (3 min) after boot.
   Do NOT install the watchdog package until boot grace period is tested.
   Connection watchdog must use `systemctl restart ModemManager` (NOT
   `mmcli --disable/--enable`).

10. **EDL is always available for unbricking**: Reset button + USB plug enters
    EDL mode even on a completely bricked device. Full stock restore from
    `backup/partitions/` takes about 5 minutes. Verified many times.

11. **USB port matters**: Unreliable USB connections (through hubs) can cause
    EDL writes to fail silently. Use a direct USB port if possible.

12. **SSH PAM modules can hang on embedded**: Disable `pam_loginuid` and
    `pam_selinux` in `/etc/pam.d/sshd`, and add `UseDNS no` to `sshd_config`.

13. **System clock must be set**: The dongle has no RTC battery. Wrong date
    (default: 2021) can cause auth timeouts. Set the date on first boot.

14. **Fix apt sources for Debian 11**: Bullseye is archived; change
    `deb.debian.org` to `archive.debian.org` and remove the security line.
