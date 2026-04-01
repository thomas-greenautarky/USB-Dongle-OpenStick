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

## Automated Flash (recommended)

The flash script handles everything automatically, including modem calibration
backup/restore:

```bash
cd flash && bash flash-openstick.sh
```

The script will:
1. Detect the device (EDL, ADB, or prompt for manual EDL entry)
2. **Auto-backup modem calibration** (IMEI, RF cal) from the device before flashing
3. Write GPT, firmware, kernel, and rootfs via EDL
4. **Restore modem calibration** from the auto-backup
5. Reset and verify boot

This is safe for **any stick** — no manual backup step needed. The script reads
the device's unique calibration data before overwriting anything.

See [Modem Calibration (Auto-Backup)](#modem-calibration-auto-backup) below
for details on how this works.

After the flash completes:
```bash
bash configure-dongle.sh
```

## Manual Flash (step by step)

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
# Boot image: 6.6 kernel with appended DTB (Android boot image format, ~7 MB)
edl w boot boot.img

# Debian rootfs (ext4, raw image, takes 2-5 minutes)
edl w rootfs rootfs.raw
```

The boot image is built by the Docker build pipeline: the postmarketOS 6.6 kernel
(vmlinuz) is concatenated with `msm8916-thwc-ufi001c.dtb` and packed into an
Android boot image with mkbootimg. The Dragonboard aboot finds the DTB by scanning
for the FDT magic (0xd00dfeed) after the gzip kernel data.

The rootfs includes cross-compiled modem tools (rmtfs, qrtr-ns) and systemd
services for automatic modem initialization at boot.

### Step 5: Restore Modem Calibration

The modem calibration data (IMEI, RF calibration) is device-specific.
If you used the automated script, this was handled automatically.
For manual flash, restore from backup:

```bash
cd ../../backup/partitions
edl w sec      sec.bin
edl w fsc      fsc.bin
edl w fsg      fsg.bin
edl w modemst1 modemst1.bin
edl w modemst2 modemst2.bin
```

**WARNING**: If you skip this step, the modem will have no IMEI and RF
calibration will be wrong. The modem may not connect to any network.

### Step 6: Reset and Verify

```bash
edl reset
```

Wait 30-45 seconds for Debian to boot. Verify:
```bash
# Check for RNDIS USB gadget
lsusb | grep 1d6b:0104
# Bus xxx Device xxx: ID 1d6b:0104 Linux Foundation Multifunction Composite Gadget

# Set up host IP on the USB network interface
sudo ip addr add 192.168.68.100/24 dev enxXXXXXXXXXXXX

# SSH into the dongle (default password: openstick)
ssh root@192.168.68.1
# Linux openstick 6.6.0-msm8916 ... aarch64 GNU/Linux
```

## Post-Flash Configuration

All configuration is done via **SSH** over the RNDIS USB network. No ADB needed.

### Connect to the dongle

```bash
# Find the RNDIS interface (shows as enxXXXX after plugging in)
ip link show | grep enx

# Add an IP on the host side
sudo ip addr add 192.168.68.100/24 dev enxXXXXXXXXXXXX

# SSH in (default password: openstick)
ssh root@192.168.68.1
```

### 1. Copy device-specific modem firmware + NV storage

The modem needs two things from the device backup:
- **Firmware blobs** — modem DSP code, WiFi firmware (from modem.bin FAT16 image)
- **NV storage** — IMEI, RF calibration, carrier config (from modemst1/modemst2/fsg)

```bash
# From the host, extract modem firmware and copy to dongle
# 1. Mount modem backup (FAT16 partition image) and extract firmware
mkdir /tmp/modem_mnt
sudo mount -o loop,ro backup/partitions/modem.bin /tmp/modem_mnt
scp /tmp/modem_mnt/image/* root@192.168.68.1:/lib/firmware/
sudo umount /tmp/modem_mnt

# 2. Copy NV storage files (modem EFS + golden copy)
scp backup/partitions/modemst1.bin root@192.168.68.1:/boot/modem_fs1
scp backup/partitions/modemst2.bin root@192.168.68.1:/boot/modem_fs2
scp backup/partitions/fsg.bin root@192.168.68.1:/boot/modem_fsg

# 3. Reboot to start modem with firmware + NV storage
ssh root@192.168.68.1 reboot
```

After reboot, rmtfs.service starts automatically, provides NV storage to the
modem DSP, and the modem should respond to AT commands:
```bash
ssh root@192.168.68.1
echo -e "ATI\r" > /dev/wwan0at0 && sleep 1 && cat /dev/wwan0at0
# Should show: Manufacturer: QUALCOMM INCORPORATED, IMEI, firmware version
```

Without modem firmware, the modem DSP crashes in a loop. Without NV storage
(modem_fs files), the modem boots but has no IMEI and can't register on networks.

### 2. Fix apt sources and set clock

```bash
# Fix apt sources (Debian 11 bullseye is archived)
sed -i 's|deb.debian.org|archive.debian.org|g' /etc/apt/sources.list
sed -i '/security.debian.org/d' /etc/apt/sources.list

# Set system clock (no RTC battery, defaults to 2021)
date -s "$(wget -qO- --save-headers http://google.com 2>&1 | grep -i '^Date:' | cut -d' ' -f2-)"
```

### 3. Change Root Password
```bash
# Default password is "openstick" — change it!
passwd root
```

### 4. Configure LTE
```bash
mmcli -m 0 --simple-connect="apn=YOUR_APN"
```

### 5. NAT gateway (USB → LTE forwarding)

NAT is pre-configured in the image (`iptables` rules + `ip_forward`).
Verify:
```bash
sysctl net.ipv4.ip_forward      # should show 1
iptables -t nat -L POSTROUTING   # should show MASQUERADE on wwan0
```

### 6. Configure WiFi Hotspot (optional)
```bash
nmcli connection add type wifi ifname wlan0 con-name hotspot \
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
- Verify boot image was built with appended DTB (stock pmos msm8916-thwc-ufi001c.dtb)
- Check UART serial console (115200 baud, 3.3V) for kernel panic messages
- Common cause: /lib symlink broken (must be symlink to /usr/lib for usrmerge)

### Modem not detected (mmcli -L shows nothing)
- Verify modem firmware is in `/lib/firmware/` (modem.mdt, mba.mbn, wcnss.mdt, etc.)
- Verify rmtfs is running: `systemctl status rmtfs`
- Verify modem_fs files exist: `/boot/modem_fs1`, `/boot/modem_fs2`, `/boot/modem_fsg`
- These must be copied from the device backup (modemst1.bin, modemst2.bin, fsg.bin)
- Check `dmesg | grep remoteproc` — modem DSP should show "now up" without "fatal error"

### SIM not detected
- Verify modem responds to AT commands: `echo -e "AT\r" > /dev/wwan0at0`
- If `AT+CPIN?` returns "SIM not inserted", check physical SIM card
- Some boards need a physical replug after first boot

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

### Boot image format: appended DTB

The boot image uses the "appended DTB" format: the gzip-compressed kernel
(vmlinuz) is concatenated with the flat device tree blob (.dtb), then packed
into a standard Android boot image with mkbootimg. The Dragonboard aboot
scans for the FDT magic byte (0xd00dfeed) after the gzip stream to find the DTB.

**Why not extlinux/lk2nd?** Extensive testing showed that lk2nd's ext2
partition scanning doesn't work on this board (the boot partition split
never happens, and the ext2 mount fails silently on all partitions).
The QCDT DTB matching also failed because `board_hardware_id()` is unknown.
The appended-DTB format bypasses all these issues.

**Why not lk1st?** SBL1 rejects the test-signed lk1st binary. Only the
stock Dragonboard emmc_appsboot (ELF format) is accepted by SBL1.

**DTB choice:** The stock postmarketOS `msm8916-thwc-ufi001c.dtb` works for
JZ0145-v33 boards. The custom `msm8916-jz01-45-v33.dtb` from OpenStick-Builder
also boots but has `compatible = "thwc,ufi001c"` anyway.

## Modem Calibration (Auto-Backup)

Each USB dongle has **unique, device-specific** modem calibration data stored
in 5 eMMC partitions. This data includes:

| Partition | Content |
|-----------|---------|
| `sec` | Security/device identity |
| `fsc` | Factory Service Configuration |
| `fsg` | Factory Service Golden copy (modem firmware golden backup) |
| `modemst1` | Modem EFS storage 1 (IMEI, RF calibration, carrier config) |
| `modemst2` | Modem EFS storage 2 (backup of modemst1) |

This data **cannot be regenerated** — it is written at the factory during
RF calibration. If lost, the modem will have no IMEI and cannot connect
to any mobile network.

### How auto-backup works

The `flash-openstick.sh` script automatically handles calibration:

```
1. Device enters EDL mode
2. Script reads all 5 calibration partitions via EDL (edl r <part>)
3. Saves to backup/autosave_YYYYMMDD_HHMMSS/
4. Validates all files are non-empty
5. Flashes GPT, firmware, kernel, rootfs (overwrites everything)
6. Restores the 5 calibration partitions from the auto-backup
```

### Fallback behavior

- If auto-backup succeeds → uses auto-backup for restore
- If auto-backup partially fails → falls back to existing manual backup
  in `backup/partitions/` (if complete)
- If no backup is available at all → **script aborts** to prevent
  losing calibration data
- First successful auto-backup is also copied to `backup/partitions/`
  as a permanent backup

### Flashing a brand-new stick

When flashing a stick for the first time, the script will:
1. Read the stock calibration from the device (works in EDL even on stock Android)
2. Save it before overwriting anything
3. Restore it after flashing Debian

No manual `edl r` backup step is needed. Just enter EDL and run the script.

### Multiple sticks

Each auto-backup is timestamped (`autosave_20260330_151200/`), so flashing
multiple sticks in sequence is safe — each gets its own backup directory.

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

3. **Appended DTB boot format**: Concatenate vmlinuz + DTB, pack with mkbootimg.
   The Dragonboard aboot finds the DTB by scanning for FDT magic after the gzip
   stream. lk2nd/extlinux doesn't work on this board (ext2 mount fails, QCDT
   matching fails). lk1st is rejected by SBL1.

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

8. **Modem needs rmtfs for NV storage**: The modem DSP accesses its calibration
   data (IMEI, RF cal) via rmtfs (remote filesystem service). Without rmtfs running
   BEFORE the modem starts, the modem enters a crash loop (`fs_device_efs_rmts.c`).
   rmtfs needs modem_fs1/fs2/fsg files in `/boot/` (copied from modemst1/modemst2/fsg
   backup partitions). The build includes rmtfs.service that starts automatically.

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
    These are pre-configured in the build overlay (`etc/ssh/sshd_config.d/dongle.conf`).

13. **System clock must be set**: The dongle has no RTC battery. Wrong date
    (default: 2021) can cause auth timeouts. Set the date on first boot.

14. **Fix apt sources for Debian 11**: Bullseye is archived; change
    `deb.debian.org` to `archive.debian.org` and remove the security line.

15. **No ADB needed**: The dongle uses RNDIS USB networking + SSH instead
    of Android ADB. The `usb-gadget.service` creates an RNDIS gadget at
    boot, assigns IP `192.168.68.1`, and `dnsmasq` serves DHCP. Default
    root password is `openstick`. All management is via SSH.

16. **No initramfs needed with 6.6 kernel**: The postmarketOS 6.6 kernel has
    ext4 built-in and can mount the rootfs directly. The old 5.15 kernel
    needed a 6.3 MB initramfs. With 6.6, the boot image is just kernel + DTB.

17. **usrmerge /lib symlink is critical**: The postmarketOS kernel .apk creates
    `/lib/modules/` as a real directory, replacing Debian bullseye's `/lib → /usr/lib`
    symlink. Without this symlink, the dynamic linker `/lib/ld-linux-aarch64.so.1`
    is missing and NO ELF binary can execute (kernel panic: "init failed error -2").
    The build.sh fixes this automatically after kernel extraction.

18. **UART serial console**: 3.3V UART directly from PCB pads. FTDI FT232R
    adapter at 115200 baud. Essential for debugging boot issues — without it,
    kernel panics are invisible (no USB output until systemd starts).
