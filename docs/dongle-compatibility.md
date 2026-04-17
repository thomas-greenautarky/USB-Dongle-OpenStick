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

## EDL Instabilität & Mitigation

Das Sahara/Firehose Protokoll auf MSM8916 ist **zustandsbehaftet** und
unverzeihlich bei Fehlern. Die häufigsten Probleme und ihre Ursachen:

### Sahara hat nur ein Hello-Paket
Nach einem Fehlschlag (Timeout, Loader-Upload abgebrochen, USB-Glitch) bleibt
der PBL im Error-State. Weitere `edl` Kommandos schlagen mit
`"Connection already detected, quiting"` oder `"Sahara timeout"` fehl —
**ohne vollen Power-Cycle ist kein Recovery möglich**.

→ Mitigation: Nach JEDEM Fehler Dongle unplug → 3 s warten → replug.
Niemals `edl` Kommandos auf demselben USB-Plug wiederholen.

### EDL-Timeout bei zu später Aktion
Bleibt der Dongle zu lange in EDL ohne Firehose-Upload, triggert der PBL
einen internen Timeout. Nächster Kontakt schlägt fehl.

→ Mitigation: Zwischen `adb reboot edl` und erstem `edl`-Kommando minimal
Zeit vergehen lassen. Script macht `edl printgpt` als Erstkontakt sofort nach
USB-Enumeration.

### USB Power / Kabel / Hub
Generische Sahara-Probleme bei unsauberer Power-Delivery: Enumeration-Flackern
bricht den Sahara-Handshake ab.

→ Mitigation: Dongle **direkt** am Host anschließen, kein Hub. Kurzes,
qualitätsgeprüftes Kabel. Bei wackeligen Verbindungen USB-Port wechseln.

### Hardware-Revisionen
UZ801 existiert als V1.1, V3.0, V3.2, V3.4.33 mit teils unterschiedlichen
PBL-Versionen und EDL-Testpunkten. Nicht alle Revisionen verhalten sich gleich.

→ Mitigation: Bei neuen Dongles PCB-Revision prüfen (Aufdruck). Wenn ein
Dongle wiederholt EDL-Fehler hat obwohl andere funktionieren: wahrscheinlich
abweichende Hardware-Revision.

### Peek-Loader können eMMC schreiben
Häufiges Missverständnis: `*_peek.bin` Loader sind keine read-only Variante.
Der Name bezieht sich auf RAM-peek/poke-Primitiven, nicht auf Storage-Zugriff.
`edl w partition file` funktioniert mit peek-Loadern.

→ Die "Connection detected"-Fehlermeldung beim Schreiben kommt NICHT vom
Loader-Typ, sondern vom korrupten Sahara-State (siehe oben).

### USB-Overflow beim ersten Write (reproduzierbar auf UZ801)
**Symptom:** Reads im EDL laufen durch, der **erste Write** crasht mit
`USBError(75, 'Overflow')` → Firehose geht in Error-State → Abort.

**Reproduziert am 2026-04-17** auf zwei unabhängigen UZ801 (SIM-WIN-00000014,
SIM-WIN-00000002) mit edlclient 3.62 auf Python 3.13.5.

**Zwei Ursachen — beide müssen adressiert werden:**

1. **Falscher MaxPayload bei Autodetect:** Wenn `edl` den Memory-Type nicht
   explizit bekommt, autodetected er bei einigen Firehose-Loadern falsch
   und verhandelt eine zu große MaxPayload. Siehe
   [bkerler/edl #103](https://github.com/bkerler/edl/issues/103).
   → Fix: Bei allen `edl` Aufrufen explizit `--memory=emmc` setzen
   (außer `reset`, das unterstützt das Flag nicht).

2. **Kumulierter USB-State nach vielen Reads:** Auch mit `--memory=emmc`
   tritt Overflow auf, wenn vor dem ersten Write viele Read-Kommandos
   liefen (jedes `edl r` startet eine neue Sahara-Session, lädt Loader
   neu hoch). Empirisch: ≤10 Reads gehen, ~23 Reads inkl. 64MB modem-Read
   brechen den State. Der dry-run mit nur 1 Write (ohne Reads vorher) ging
   auch ohne Fix #2 durch.
   → Fix: Stock-Partition-Backup (12 edl-r Calls inkl. modem 64MB) ist
   **standardmäßig deaktiviert** — via `--full-stock-backup` aktivierbar
   wenn wirklich nötig (zum Restore-Zweck). NV-Backup (5 kleine Reads)
   bleibt immer an — unverzichtbar für IMEI/RF-Kalibrierung.

→ Script `flash-uz801.sh` und `restore-dongle.sh` setzen das überall.

**Validiert 2026-04-17:** SIM-WIN-00000002 mit kombiniertem Fix:
Flash komplett durchgelaufen, 47/48 Tests PASS, LTE + NetBird funktionieren.

### lk2nd unterstützt kein `fastboot flash partition`
Obwohl der Dongle nach dem Flash als Fastboot (`18d1:d00d`) erscheint,
implementiert lk2nd **kein GPT-flashing**. Ein `fastboot flash rootfs`
korrumpiert die Partitionstabelle (siehe SIM-WIN-00000016).

→ Mitigation: Alle Flash-Operationen ausschließlich via EDL in einer Session.
Das Script macht das automatisch (all-EDL approach).

**Quellen:**
- [bkerler/edl Issues #398, #588, #647](https://github.com/bkerler/edl/issues)
- [96Boards QDL Docs](https://www.96boards.org/documentation/consumer/guides/qdl.md.html)
- [u0d7i/uz801 README](https://github.com/u0d7i/uz801)
- [OpenStick/OpenStick Issue #46, #69, #87](https://github.com/OpenStick/OpenStick/issues)

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

Use the provided script in `USB-Dongle-WIFI-Configurator/setup-host.sh`.
It creates the NetworkManager profile `dongle-local` that matches **by
driver** (`rndis_host`) rather than by interface name — this avoids
matching real USB ethernet adapters on the host.

```bash
sudo bash setup-host.sh
```

Key properties of the profile:
- `match.driver=rndis_host` — only flashed dongles, not real ethernet
- `ipv4.method=auto` — DHCP works for both Stock Android and Debian dongles
- `ipv4.never-default=yes` — host's default route is untouched
- `ipv4.ignore-auto-dns=yes` — host's DNS is untouched

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
