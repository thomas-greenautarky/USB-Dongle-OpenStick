# Dongle Compatibility & Provisioning Guide

## Overview

All supported dongles use the Qualcomm MSM8916 SoC. The provisioning system
auto-detects the dongle type by USB ID and selects the correct flash strategy.

```
Dongle plugged in
       │
       ├── 05c6:f00e (Stock Android) → UZ801 flow
       │     Login → ADB enable → Backup → adb reboot edl → Flash
       │
       ├── 05c6:9008 (EDL mode) → JZ0145-v33 flow or UZ801 flow
       │     Backup → Flash
       │
       └── 1d6b:0104 (RNDIS/Debian) → Already flashed
             Skip flash, configure only (--skip-flash)
```

## Supported Dongle Types

### UZ801 v3 (primary target)

| Property | Value |
|----------|-------|
| Board | UZ801 v3 (Yiming) |
| SoC | MSM8916 |
| eMMC | 3.6 GB (7,634,944 sectors) |
| Stock USB ID | `05c6:f00e` (Stock Android "4G Modem") |
| Stock web UI | `http://192.168.100.1` (admin/admin) |
| Flash script | `flash-uz801.sh` |
| Bootloader | lk2nd (replaces stock aboot) |
| DTB | `msm8916-yiming-uz801v3.dtb` (auto-selected by lk2nd) |
| Boot method | lk2nd reads `extlinux.conf` from boot partition |
| Status | **Fully supported** |

**EDL entry:** Automatic via web API → ADB → `adb reboot edl`
- Reset pin does NOT work on UZ801
- The flash script handles this automatically

**Web API endpoints:**
| Endpoint | Purpose |
|----------|---------|
| `POST /ajax {"funcNo":1000,"username":"admin","password":"admin"}` | Login, returns IMEI + firmware version |
| `POST /ajax {"funcNo":2001}` | Enable ADB (hidden page `/usbdebug.html`) |

### JZ0145-v33

| Property | Value |
|----------|-------|
| Board | JZ0145-v33 |
| SoC | MSM8916 |
| eMMC | 3.73 GB (7,733,248 sectors) |
| Stock USB ID | Unknown (received pre-flashed) |
| Flash script | `flash-openstick.sh` |
| Bootloader | Dragonboard aboot (stock replacement) |
| DTB | `msm8916-jz01-45-v33.dtb` (appended to kernel) |
| Boot method | aboot loads Android boot.img with appended DTB |
| Status | **Fully supported** |

**EDL entry:** Reset pin (hold + plug in USB, 10-15 seconds)

## Universal Flash Architecture

Both dongle types use the same partition layout after flashing:

```
Partition  Name       Size        Content
────────────────────────────────────────────────
 1         cdt        2 KB        Clock data
 2         sbl1       512 KB      Secondary bootloader 1
 3         rpm        512 KB      Resource/Power manager
 4         tz         1 MB        TrustZone
 5         hyp        512 KB      Hypervisor
 6         sec        16 KB       Security
 7         modemst1   2 MB        Modem calibration (IMEI, RF)
 8         modemst2   2 MB        Modem calibration backup
 9         fsc        1 KB        Modem FSC
10         fsg        2 MB        Modem FSG
11         aboot      1 MB        Bootloader (lk2nd or Dragonboard)
12         modem      64 MB       Modem firmware
13         persist    32 MB       Persistent storage
14         boot       64 MB       Kernel + DTBs (ext2)
15         rootfs     ~3.4 GB     Debian 12 (ext4)
```

Key design decisions:
- **GPT is generated dynamically** (`sgdisk`) based on actual eMMC size
- **rootfs PARTUUID is fixed** (`a7ab80e8-e9d1-e8cd-f157-93f69b1d141e`) to match `extlinux.conf`
- **Firmware** (sbl1, rpm, tz) comes from Linaro DragonBoard410c (universal for MSM8916)
- **Modem firmware + calibration** is backed up from each dongle and restored after flash

## Provisioning Flow

### Full automatic (UZ801 — `./provision.sh`)

```
1. Plug in dongle (boots to Stock Android)
2. Run ./provision.sh
3. Scan QR code
4. AUTO: Login web API → enable ADB → backup 25 partitions → adb reboot edl
5. AUTO: Read disk size → generate GPT → flash all partitions
6. AUTO: Boot → SSH → configure (hostname, WiFi, APN, NetBird, RNDIS)
7. AUTO: Verify (23 tests) → DB record → system test (48 tests)
```

### Manual steps required (JZ0145-v33)

```
1. Enter EDL: hold reset pin + plug in USB (10-15 seconds)
2. Run ./provision.sh
3. Scan QR code
4. AUTO: Backup → flash → boot → configure → verify
```

## Backup & Restore

### UZ801 backup (via ADB — 25 files)

Created automatically during provisioning at:
`backup/stock_uz801_<IMEI>_<date>/`

Contents:
- `device_info.txt` — IMEI, firmware version, partition map
- `modem.bin` — modem firmware (64 MB)
- `sbl1.bin`, `rpm.bin`, `tz.bin`, `hyp.bin`, `aboot.bin` + backups — bootloader firmware
- `boot.bin`, `recovery.bin` — stock kernel images
- `modemst1.bin`, `modemst2.bin`, `fsg.bin`, `fsc.bin`, `sec.bin` — modem calibration
- `gpt_primary.bin` — original GPT
- `DDR.bin`, `ssd.bin`, `misc.bin`, `splash.bin`, `pad.bin`, `persist.bin` — misc

### JZ0145-v33 backup (via EDL)

Created during flash at `backup/autosave_<timestamp>/`:
- Modem calibration (modemst1, modemst2, fsg, fsc, sec)
- Boot partitions (sbl1, rpm, tz, hyp, cdt, aboot, boot)
- GPT

### Restore

```bash
# UZ801: requires EDL (enter via adb reboot edl from Stock Android,
# or if already flashed with lk2nd, dongle shows as fastboot 18d1:d00d)
cd flash && bash flash-uz801.sh --restore ../backup/stock_uz801_<IMEI>_<date>/

# JZ0145-v33: requires EDL (reset pin + plug in)
cd flash && bash restore-dongle.sh ../backup/autosave_<timestamp>/
```

## Known Issues & Lessons Learned

### Reset pin does not work on UZ801
The hardware reset button on UZ801 dongles does NOT enter EDL mode.
EDL must be reached via: Stock Android → ADB enable → `adb reboot edl`.
After flashing with lk2nd, the dongle shows as fastboot (`18d1:d00d`).

### Modem firmware must be backed up and restored
The `modem` partition (64 MB) contains the baseband firmware. If not
restored after flashing, ModemManager can't read the IMEI and LTE won't work.
The flash script backs up and restores this automatically.

### PARTUUID must match extlinux.conf
The prebuilt `boot.bin` (from OpenStick-Builder) has `root=PARTUUID=a7ab80e8-...`
hardcoded in `extlinux.conf`. The GPT generation sets this UUID explicitly
on the rootfs partition. Mismatched UUIDs cause kernel panic (no root).

### Board-specific DTB is critical
Flashing the wrong DTB (e.g. JZ0145-v33 DTB on a UZ801) causes the kernel
to hang with no USB output — the dongle appears dead. lk2nd auto-selects
the correct DTB when booting via `extlinux.conf` with `fdtdir`.

### Stock Android GPT has 27 partitions, ours has 15
Our GPT replaces the stock layout entirely. The stock `system`, `cache`,
`recovery`, and `userdata` partitions are merged into one large `rootfs`.
The stock partition backup allows full restoration if needed.

## eMMC Sizes

| Dongle | Sectors | Size | Notes |
|--------|---------|------|-------|
| UZ801 v3 | 7,634,944 | 3.6 GB | Most common |
| JZ0145-v33 | 7,733,248 | 3.7 GB | |
| UZ801 variant | 7,864,320 | 3.8 GB | Seen on some units |

GPT is generated dynamically — any eMMC size works.

## Prerequisites

| Tool | Install | Required for |
|------|---------|-------------|
| `edl` | `pipx install edlclient` | EDL flash protocol |
| `adb` | `apt install adb` | UZ801 ADB reboot to EDL |
| `sgdisk` | `apt install gdisk` | Dynamic GPT generation |
| `sshpass` | `apt install sshpass` | SSH automation |
| `curl` | _(pre-installed)_ | UZ801 web API |
| `psql` | `apt install postgresql-client` | DB tracking (optional) |

### Host machine setup (once)

```bash
# Prevent dongle from hijacking host internet
nmcli connection add type ethernet con-name "dongle-no-route" \
    match.interface-name "enx*" ipv4.never-default yes ipv4.dns-priority 200 \
    ipv6.method disabled connection.autoconnect yes connection.autoconnect-priority 100
```

## File Structure

```
USB-Dongle-OpenStick/
├── flash/
│   ├── flash-openstick.sh    # JZ0145-v33 flash script
│   ├── flash-uz801.sh        # UZ801 flash script (auto-detect, ADB, lk2nd)
│   ├── restore-dongle.sh     # Restore from backup
│   ├── files/
│   │   ├── rootfs.raw        # Our custom Debian rootfs (built by build.sh)
│   │   ├── boot.img          # JZ0145-v33 boot image (kernel + appended DTB)
│   │   ├── sbl1.mbn          # JZ0145-v33 firmware
│   │   └── uz801/
│   │       ├── aboot.mbn     # lk2nd (universal bootloader)
│   │       ├── boot.bin      # Kernel + all DTBs (ext2, from OpenStick-Builder)
│   │       ├── hyp.mbn       # qhypstub
│   │       ├── sbl1.mbn      # Linaro DragonBoard firmware
│   │       ├── rpm.mbn
│   │       └── tz.mbn
│   └── test-dongle.sh        # Hardware test suite
├── build/
│   ├── build.sh              # Debian rootfs builder (Docker)
│   ├── Dockerfile
│   └── overlay/              # Files copied into rootfs
├── backup/
│   ├── stock_uz801_<IMEI>_<date>/  # Per-dongle stock backups
│   └── autosave_<timestamp>/       # EDL auto-backups
├── logs/
│   └── flash_uz801_<timestamp>.log # Per-flash logs
└── docs/
    └── dongle-compatibility.md     # This file
```
