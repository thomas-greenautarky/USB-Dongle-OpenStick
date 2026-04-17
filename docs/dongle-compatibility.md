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
- **Reference modem firmware** (`flash/files/uz801/modem_firmware/`) is shipped
  as fallback for EDL-only flashes (no ADB access)

## Pre-Flash Hardware Probe

Before flashing, `flash-uz801.sh` reads identifying info via Sahara from the
PBL so orchestrators can know what they're dealing with:

| Feld | Wert (UZ801 v3) | Beschreibung |
|---|---|---|
| HWID | `0x007050e100000000` | Full HWID including OEM/MODEL fuses |
| MSM_ID | `0x007050e1` | Chip family — 0x007050e1 = MSM8916/APQ8016 |
| eMMC sectors | 7634944 (3.6 GB) | Varies per dongle revision |
| MemoryName | eMMC | from Firehose storage response |

Run via `--probe-only` (diagnostic, no flash) or `--probe-file <path>`
(writes key=value env file for consumption by provision.sh).

provision.sh reads this plus the device-tree model from Debian post-boot
(`/sys/firmware/devicetree/base/model` and `compatible`) and stores
everything in the DB for fleet management.

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

## EDL Instability & Mitigation

The Sahara/Firehose protocol on MSM8916 is **stateful** and unforgiving
on errors. Known failure modes and mitigations:

### Sahara has only one Hello packet
After any failure (timeout, aborted loader upload, USB glitch), the PBL
stays in an error state. Subsequent `edl` commands fail with
`"Connection already detected, quiting"` or `"Sahara timeout"` —
**full power cycle is the only way out**.

→ Mitigation: after any failure, unplug → wait 3 s → replug. Never retry
`edl` commands on the same USB session.

### EDL timeout when idle too long
If the dongle stays in EDL without uploading the Firehose programmer,
the PBL triggers an internal timeout. The next command fails.

→ Mitigation: keep the gap between `adb reboot edl` and the first `edl`
command minimal. The script issues `edl printgpt` as its first contact
immediately after USB enumeration.

### USB power / cables / hubs
Generic Sahara issues with unclean power delivery: enumeration glitches
kill the Sahara handshake.

→ Mitigation: plug the dongle **directly** into the host, no hub. Short,
quality-tested cable. Switch USB port if connection is flaky.

### Hardware revisions
UZ801 ships as V1.1, V3.0, V3.2, V3.4.33 with varying PBL versions and
EDL testpoints. Not all revisions behave the same.

→ Mitigation: on new dongles, check the PCB silkscreen revision. If one
dongle reproducibly fails EDL while others succeed, it's likely a
different hardware revision.

### Peek loaders CAN write eMMC
Common misconception: `*_peek.bin` loaders are **not** a read-only variant.
The name refers to RAM peek/poke primitives, not storage access.
`edl w partition file` works fine with peek loaders.

→ The "Connection detected" error on write is NOT caused by the loader
type — it's a corrupted Sahara state (see above).

### USB Overflow on first write (reproducible on UZ801)
**Symptom:** EDL reads succeed, but the **first write** crashes with
`USBError(75, 'Overflow')` → Firehose enters error state → abort.

**Reproduced on 2026-04-17** on two independent UZ801 units
(SIM-WIN-00000014, SIM-WIN-00000002) using edlclient 3.62 on Python 3.13.5.

**Two causes — both need to be addressed:**

1. **Wrong MaxPayload on auto-detect:** Without an explicit memory type,
   `edl` auto-detects incorrectly for some Firehose loaders and negotiates
   a MaxPayload too large for the device's USB endpoint. See
   [bkerler/edl #103](https://github.com/bkerler/edl/issues/103).
   → Fix: pass `--memory=emmc` explicitly on every `edl` invocation
   (except `reset`, which does not accept the flag).

2. **Cumulative USB state after many reads:** Even with `--memory=emmc`,
   overflow occurs when many read commands ran before the first write
   (each `edl r` opens a fresh Sahara session and re-uploads the loader).
   Empirically: ≤10 reads work; ~23 reads including the 64 MB modem read
   break the state. A dry-run with a single write (no reads first) also
   succeeded without fix #2.
   → Fix: the stock-partition backup (12 `edl r` calls including the 64 MB
   modem partition) is **disabled by default** — enable with
   `--full-stock-backup` when genuinely needed (full restore scenario).
   NV backup (5 small reads) is always on — indispensable for IMEI and
   RF calibration.

→ `flash-uz801.sh` and `restore-dongle.sh` apply both fixes everywhere.

**Validated 2026-04-17:** SIM-WIN-00000002 with combined fix ran the
complete flash through, 47/48 tests PASS, LTE + NetBird operational.

### Hardware-specific Firehose loader (overflow despite fixes)
**Symptom:** Even with `--memory=emmc` set AND few reads beforehand, the
first write still throws `USBError(75, 'Overflow')` on **some** dongles.

**Reproduced 2026-04-17** on SIM-WIN-00000014: flashing fails on the first
write with all mitigations above. Same code works on 002/012/013 without
issue → hardware-specific incompatibility with the default loader.

**Cause:** `edl` auto-selects a Firehose loader (typically `longcheer` for
MSM8916). Some individual dongles' USB endpoints cannot buffer the payload
that loader version negotiates. Alternative loaders (e.g.
`qualcomm/factory/msm8916`) negotiate a smaller payload that works.

**Fix:** `flash-uz801.sh` accepts `--loader <path>` (or `EDL_LOADER` env
variable) to force a specific loader. For 014-style symptoms, set it to:

```
~/.local/share/pipx/venvs/edlclient/lib/python3.13/site-packages/edlclient/../Loaders/qualcomm/factory/msm8916/007050e100000000_8ecf3eaa03f772e2_fhprg_peek.bin
```

**Validated 2026-04-17:** SIM-WIN-00000014 with this loader → full flash
succeeded, Debian booted in 10s, full rescue from previously-unrecoverable
state.

### Modem firmware segments missing after EDL-only flash
**Symptom:** Debian boots, modem DSP runs, but `mmcli -m 0 --enable`
returns `QMI Protocol Error (52) DeviceNotReady`, signal 0, not registered.

**Cause:** Modem/MBA firmware is loaded by the kernel via
`request_firmware()` from `/lib/firmware/`. This requires ALL binary
segments (`.b00`, `.b01`, `.b04`, etc.) in addition to the `.mdt` metadata
header. Our rootfs ships only the `.mdt` stubs — the `.b00+` segments are
normally pulled at flash time via ADB from `/firmware/image/` on Stock
Android, then copied via SCP into `/lib/firmware/` on the booted Debian.
**In EDL-only flashes (no ADB access) this step is skipped** → `.b00+`
segments never copied → modem firmware incomplete.

**Affected dongles:** any dongle reaching the flash pipeline from EDL
without passing through Stock Android — e.g. partially-flashed or bricked
dongles that fell back to EDL via the PBL (SIM-WIN-00000001,
SIM-WIN-00000014 after recovery attempts).

**Fix (two-pronged):**
1. **Repository-bundled reference set:** `flash/files/uz801/modem_firmware/`
   ships a complete copy of firmware files (186 files, ~50 MB) dumped
   from a known-good UZ801. Force-added past the `*.bin` .gitignore rule.
2. **flash-uz801.sh fallback:** when `MODEM_FW_DIR` is empty after Step 2
   (no ADB backup), the reference set is used automatically when writing
   the `modem` (vfat) partition.
3. **provision.sh auto-heal:** after SSH is up, the script checks whether
   `/lib/firmware/modem.b00` exists on the dongle. If not → copies the
   reference set via SCP, restarts rmtfs + remoteproc + ModemManager,
   waits 15 s.

**Validated 2026-04-17:** SIM-WIN-00000014 (EDL-only flashed) went from
`DeviceNotReady` to `registered, LTE, operator L LUXGSM, signal 65`
after automatic firmware copy.

### modem-autoconnect stuck in failed state (systemd oneshot)
**Symptom:** modem registered, good signal, but no data bearer active
→ no LTE connectivity → red LED on the dongle.

**Cause:** `modem-autoconnect.service` is a systemd **oneshot** service
that runs `mmcli -m 0 --simple-connect` at boot. If modem firmware is not
yet ready at boot time, the connect fails and systemd marks the service
as `failed`. Oneshot services are **not automatically retried**.

**Fix in provision.sh:** after the firmware-heal step, check the service
state; if failed (or if we just healed firmware this session):
`systemctl reset-failed modem-autoconnect` followed by
`systemctl restart modem-autoconnect`. The service then brings up the
bearer successfully.

**Long-term fix (TODO):** convert the service to `type=simple` with
`Restart=on-failure` so systemd retries automatically until the modem
is ready.

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
