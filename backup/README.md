# Firmware Backup

Full backup of the original Android 4.4 firmware from the UFI 4G USB dongle,
created via Qualcomm EDL (Emergency Download) mode on 2026-03-25.

## Files (not in git — too large, stored locally)

### Full dump
- `full_firmware.bin` — Complete eMMC dump (3.7 GB)

### Individual partitions (in `partitions/` directory)
| Partition | Size | Description |
|-----------|------|-------------|
| sbl1.bin | 512 KB | Secondary Boot Loader |
| aboot.bin | 1 MB | Application Bootloader (LK) |
| boot.bin | 16 MB | Linux kernel + ramdisk |
| system.bin | 800 MB | Android system (apps, framework) |
| userdata.bin | 2.6 GB | User data (app data, settings) |
| modem.bin | 64 MB | LTE modem firmware |
| recovery.bin | 16 MB | Recovery mode image |
| persist.bin | 32 MB | Persistent data (WiFi calibration, etc.) |
| cache.bin | 128 MB | Android cache |
| splash.bin | 10 MB | Boot splash screen |
| fsg.bin | 1.5 MB | Modem golden copy |
| modemst1.bin | 1.5 MB | Modem storage 1 (EFS) |
| modemst2.bin | 1.5 MB | Modem storage 2 (EFS backup) |
| rpm.bin | 512 KB | Resource Power Manager firmware |
| tz.bin | 512 KB | TrustZone firmware |
| hyp.bin | 512 KB | Hypervisor |
| DDR.bin | 32 KB | DDR training data |
| sec.bin | 16 KB | Security partition |
| gpt_main0.bin | 4.5 KB | GPT partition table |
| rawprogram0.xml | 8.3 KB | EDL flash layout (for restore) |

### Integrity
- `checksums.sha256` — SHA-256 checksums for all files

### ADB snapshots
- `getprop.txt` — Android system properties
- `partitions.txt` — Partition table from /proc
- `partition_names.txt` — Named partition symlinks
- `hostapd.conf` — WiFi AP configuration

## How to Restore

To restore the original firmware:

```bash
# 1. Put dongle in EDL mode (hold reset button while plugging in USB)

# 2. Restore full firmware
edl wf backup/full_firmware.bin

# 3. OR restore individual partitions
edl w boot backup/partitions/boot.bin
edl w system backup/partitions/system.bin
edl w userdata backup/partitions/userdata.bin
# ... etc

# 4. Reset the dongle (unplug and replug)
```

## Backup Device Info

```
HWID:     0x007050e100000000 (MSM8916)
Serial:   0x1f7ca289
Build:    eng.richal.20251104
Firmware: UFI-JZ_V3.0.0
Software: KTJQV1.0.1_0120
```
