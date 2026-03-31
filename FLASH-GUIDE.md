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
# Linux openstick 5.15.0-handsomekernel+ ... aarch64 GNU/Linux
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

### 1. Copy device-specific modem firmware

The rootfs ships with generic MSM8916 modem firmware. For the modem to
actually connect to LTE networks, you MUST copy the device-specific
firmware from the backup modem partition:

```bash
# From the host, copy backup images to the dongle
scp backup/partitions/modem.bin root@192.168.68.1:/tmp/
scp backup/partitions/persist.bin root@192.168.68.1:/tmp/

# On the dongle (via SSH):
mount /tmp/modem.bin /mnt && cp /mnt/image/m* /mnt/image/wc* /lib/firmware/ && umount /mnt
mount /tmp/persist.bin /mnt && cp /mnt/WCNSS_qcom_wlan_nv.bin /lib/firmware/wlan/prima/ && umount /mnt
rm /tmp/*.bin
```

Without this step, `mmcli -m 0` shows `DeviceNotReady` errors.

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
    These are pre-configured in the build overlay (`etc/ssh/sshd_config.d/dongle.conf`).

13. **System clock must be set**: The dongle has no RTC battery. Wrong date
    (default: 2021) can cause auth timeouts. Set the date on first boot.

14. **Fix apt sources for Debian 11**: Bullseye is archived; change
    `deb.debian.org` to `archive.debian.org` and remove the security line.

15. **No ADB needed**: The dongle uses RNDIS USB networking + SSH instead
    of Android ADB. The `usb-gadget.service` creates an RNDIS gadget at
    boot, assigns IP `192.168.68.1`, and `dnsmasq` serves DHCP. Default
    root password is `openstick`. All management is via SSH.

16. **Android boot images need initramfs**: The Dragonboard aboot loads an
    Android boot image (kernel + ramdisk). If the ramdisk is missing or
    empty (`/dev/null`), the kernel boots but cannot mount the root
    filesystem and the dongle appears dead on USB. The working
    `boot-jz01.img` has a 6.3 MB gzip initramfs — always include one.

17. **Kernel modules must match the boot image kernel**: The 5.15-handsomekernel
    boot image has netfilter compiled as modules (`=m`) but the `.ko` files
    were never shipped. Without `/lib/modules/`, `iptables` and `nftables`
    cannot load — NAT does not work. The postmarketOS 6.6 kernel includes
    all modules in its `.apk` package. When switching kernels, always include
    the matching modules in the rootfs overlay (`build/overlay/lib/modules/`).
