# USB Dongle OpenStick

Replace stock Android 4.4 on a UFI 4G USB dongle with **Debian Linux** using the
[OpenStick](https://github.com/OpenStick/OpenStick) project.

## Why?

Turn a cheap 4G USB dongle into a proper **USB internet gateway** for Home Assistant:

```
Home Assistant ──USB──► Dongle (Debian) ──LTE──► Internet
                  │
                  ├── RNDIS with gateway (auto-detected by HA)
                  ├── SSH for management
                  └── No WiFi adapter needed
```

The stock Android firmware has bugs and limitations (see
[USB-Dongle-WIFI-Configurator](https://github.com/thomas-greenautarky/USB-Dongle-WIFI-Configurator)
for details). OpenStick gives us full root, SSH, proper NAT routing, and
automated APN configuration.

## Hardware

- UFI 4G USB WiFi Dongle ([Amazon](https://www.amazon.de/dp/B0C3SC6ZG6))
- Qualcomm MSM8916 (Snapdragon 410), 512 MB RAM, 4 GB eMMC
- Board: **JZ0145 v33** (xiaoxun,jz0145-v33) — confirmed by lk2nd

## Quick Start

### Prerequisites

```bash
# Install tools
pipx install edlclient     # Qualcomm EDL flash tool
sudo apt install android-sdk-libsparse-utils  # simg2img for image conversion
```

### Flash OpenStick (EDL-only method)

```bash
# 1. Enter EDL: hold reset button while plugging in USB
#    (or from stock Android: adb reboot edl)

# 2. Run the flash script:
cd flash
bash flash-openstick.sh
# The script automatically:
#   - Backs up device-specific modem calibration (IMEI, RF cal) before flashing
#   - Flashes GPT, firmware, kernel, and Debian rootfs via EDL
#   - Restores modem calibration after flashing
# No manual backup step needed — safe for any stick, including brand-new ones.

# 3. After Debian boots, configure the dongle:
bash configure-dongle.sh \
  --hostname my-dongle \
  --derive-wifi-psk \
  --apn "internet" \
  --ssh-key ~/.ssh/id_ed25519.pub \
  --timezone Europe/Berlin
# WiFi SSID (GA-XXXX) and password are auto-derived from IMEI + shared secret in .env
```

### Manual Flash (step by step)

See [FLASH-GUIDE.md](FLASH-GUIDE.md) for the detailed procedure.

## Status

- [x] Phase 1: Full firmware backup via EDL
- [x] Phase 2: Board identified as JZ0145-v33 (xiaoxun,jz0145-v33)
- [x] Phase 3: Boot chain analysis and flash method discovery
- [x] Phase 4: Flash OpenStick — Debian 12 (bookworm) running
- [x] Phase 5: LTE connected, NAT gateway working, SSH access
- [x] Phase 6: Provisioning scripts (flash-openstick.sh + configure-dongle.sh)
- [x] Phase 7: Full LTE data via ModemManager 1.20 + BAM-DMUX
- [ ] Phase 8: Home Assistant integration

## TODO

- [x] **Modem auto-connect on boot**: modem-autoconnect.service enables modem,
      waits for registration, runs `mmcli --simple-connect`, configures wwan0 IP.
      APN configurable via `/etc/default/lte-apn`.
- [x] **NAT persistence**: iptables-restore.service loads `/etc/iptables/rules.v4`
      at boot (MASQUERADE on wwan0).
- [x] **Watchdog**: connection-watchdog.sh (cron every 3 min) with 5 min grace
      period. Recovery: re-autoconnect → restart MM → reboot.
- [x] **Clock sync**: clock-sync.service syncs via HTTP Date header after LTE.
- [x] **Modem firmware in build**: 53 firmware files baked into rootfs.
      Only device-specific NV storage (IMEI/RF cal) copied per dongle.
- [x] **WiFi PSK derivation**: HMAC-SHA256 from SSID + shared secret.
- [x] **SSID schema**: `GA-XXXX` format using last 4 digits of IMEI.
- [x] **Test suite**: `bash test-dongle.sh` — 39 automated tests (USB, SSH,
      kernel, modules, services, modem, LTE, NAT, resources).
- [ ] **Fleet batch provisioning**: flash + configure multiple dongles in sequence.
- [ ] **Home Assistant integration**: test RNDIS auto-detection by HA.
- [ ] **Web GUI**: management interface for WiFi, APN, signal, data usage.

## WiFi PSK Derivation

Each OpenStick's WiFi password is **derived deterministically** from its SSID using
a shared secret. This allows KiBu (iHost) devices to auto-connect to any OpenStick
without per-device pairing.

### Algorithm

```
SSID = "GA-" + last_4_digits_of_IMEI
PSK  = HMAC-SHA256(SHARED_SECRET, SSID)[:16]
```

- **HMAC-SHA256** — keyed hash, prevents length-extension attacks
- **SSID as message** — acts as natural salt (unique per device)
- **First 16 hex chars** — 64-bit password, sufficient for WPA2-PSK
- **Shared secret** — 256-bit key, stored externally (never in this repo)

### Shell Implementation

```bash
# Derive WiFi password from SSID + shared secret
derive_wifi_psk() {
    local ssid="$1"
    local secret="$2"
    echo -n "$ssid" | openssl dgst -sha256 -hmac "$secret" | cut -d' ' -f2 | cut -c1-16
}

# Example usage in configure-dongle.sh:
IMEI=$(mmcli -m 0 -K | grep 'modem.3gpp.imei' | awk -F': ' '{print $2}')
SSID="GA-${IMEI: -4}"
PSK=$(derive_wifi_psk "$SSID" "$OPENSTICK_WIFI_SECRET")
```

### Secret Management

The shared secret is **not stored in this repository** (public-safe):

| Location | How secret is provided |
|----------|----------------------|
| **This repo** | `.env` file (gitignored): `OPENSTICK_WIFI_SECRET=<key>` |
| **KiBu OS** | Baked at build time from `secrets/openstick-wifi.key` |
| **CI** | GitHub Secret `OPENSTICK_WIFI_KEY` |
| **ga-flasher** | Credentials DB or environment variable |

The **algorithm is intentionally public** — security comes from the secret, not
the method ([Kerckhoffs' principle](https://en.wikipedia.org/wiki/Kerckhoffs%27s_principle)).

### Provisioning Flow

```
1. Flash OpenStick with Debian (flash-openstick.sh)
2. Configure with PSK derivation:
   configure-dongle.sh --derive-wifi-psk    # reads IMEI, derives SSID+PSK from .env secret
3. KiBu auto-discovers GA-XXXX SSID, derives same PSK, connects
```

## USB Connectivity (RNDIS over USB)

The dongle acts as a **USB ethernet adapter** (RNDIS gadget) — no ADB, no
Android tools needed. Just plug it in and SSH:

```
Host PC ←──USB──→ Dongle (192.168.68.1)
              │
              ├── RNDIS ethernet (auto-detected by host)
              ├── DHCP server gives host 192.168.68.100-200
              ├── SSH: ssh root@192.168.68.1
              └── NAT gateway: host traffic → LTE
```

How it works:
- `usb-gadget.service` creates an RNDIS gadget via configfs at boot
- `usb0` gets static IP `192.168.68.1`
- `dnsmasq` serves DHCP on `usb0`
- `iptables` NAT masquerades traffic from `usb0` → `wwan0` (LTE)

All configured in the build overlay — no post-flash setup needed for basic
SSH access.

## What's Running

After a successful flash, the dongle runs:

| Component | Details |
|---|---|
| OS | Debian 12 (bookworm), aarch64 |
| Kernel | 6.6.0-msm8916 (postmarketOS, appended DTB boot) |
| RAM | 382 MB (191 MB free) |
| Storage | 3.5 GB rootfs (2.8 GB free) |
| Modem | Qualcomm LTE via ModemManager 1.20 + BAM-DMUX + rmtfs |
| WiFi | wcn36xx (AP mode via hostapd/NetworkManager) |
| USB | RNDIS gadget at 192.168.68.1 |
| SSH | OpenSSH server on port 22 |
| DNS/DHCP | dnsmasq on USB interface |

## Boot Chain (JZ0145-v33 specific)

Understanding the boot chain was critical. This board requires a specific
flash approach that differs from the standard OpenStick instructions:

```
EDL → Write GPT + Dragonboard firmware + kernel + rootfs directly to eMMC
                                              ↓
Dragonboard SBL1 → qhypstub → Dragonboard aboot → boot.img (6.6 kernel + appended DTB) → Debian
```

Key findings:
- **EDL-only flash works reliably** — no fastboot step needed
- **Appended DTB boot format** — the kernel (vmlinuz) and DTB are concatenated
  (`cat vmlinuz dtb > kernel`) and packed into an Android boot image with mkbootimg.
  The Dragonboard aboot finds the DTB by scanning for FDT magic after the gzip stream.
- **Stock postmarketOS DTB** — `msm8916-thwc-ufi001c.dtb` from the kernel package
  works for JZ0145-v33 boards. Custom DTBs are not needed.
- **GPT must be split into primary + backup** — use `gpt_primary_proper.bin` (sector 0)
  + `gpt_backup_proper.bin` (end of disk).
- **Modem support** — rmtfs and qrtr-ns are cross-compiled in the Docker build.
  rmtfs provides NV storage (IMEI, RF cal) to the modem DSP via shared memory.
  Device-specific modem firmware must be copied from backup post-flash.
- **qhypstub breaks stock SBL1** — must use Dragonboard firmware stack
- **EDL mode is always available** — reset button + USB plug, even on a
  bricked device. Full stock restore from backup takes ~5 min.

See [FLASH-GUIDE.md](FLASH-GUIDE.md) for full details.

## Open Source vs Proprietary Components

The dongle runs a mix of open source software and proprietary Qualcomm
firmware. This is the same situation as any Qualcomm-based phone running
a mainline kernel (PostmarketOS, LineageOS, etc.).

### Open Source (kernel + userspace)

| Component | License | Notes |
|---|---|---|
| Linux kernel 6.6 | GPL-2.0 | postmarketOS msm8916 mainline, all netfilter modules |
| Debian 11 userspace | Various FOSS | apt, systemd, SSH, ModemManager, NetworkManager |
| qhypstub | GPL-2.0 | Replaces the proprietary Qualcomm hypervisor |
| dnsmasq | GPL-2.0 | DHCP/DNS on USB interface |
| USB gadget (RNDIS) | GPL-2.0 | Mainline kernel driver |

### Proprietary (firmware + bootloader)

| Component | Source | Runs on | Purpose |
|---|---|---|---|
| **SBL1** (Secondary Boot Loader) | Dragonboard 410c | Application CPU | First code after ROM, initializes DDR, loads aboot |
| **emmc_appsboot** (aboot) | Dragonboard 410c, based on LK | Application CPU | Bootloader, loads kernel, provides fastboot |
| **TZ** (TrustZone) | Dragonboard 410c | ARM Secure World | Secure monitor, cryptographic services |
| **RPM firmware** | Dragonboard 410c | RPM coprocessor | Power management (clocks, regulators, sleep) |
| **Modem firmware** (MPSS) | Device backup | Hexagon DSP | LTE/3G/2G baseband, runs on dedicated DSP |
| **WiFi firmware** (wcnss) | Device backup | WCNSS coprocessor | 802.11 MAC/PHY, runs on dedicated processor |
| **WiFi NV calibration** | Device backup (persist) | WCNSS coprocessor | Per-device RF calibration data |
| **CDT** (Config Data Table) | Dragonboard 410c | SBL1 | Board configuration for early boot |

### Why proprietary firmware is needed

Qualcomm MSM8916 has **4 coprocessors** in addition to the main ARM CPU:

```
┌─────────────────────────────────────────────────┐
│  MSM8916 SoC                                    │
│                                                 │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐      │
│  │ ARM CPU  │  │ Hexagon  │  │  WCNSS   │      │
│  │ (4x A53) │  │   DSP    │  │ (WiFi)   │      │
│  │          │  │ (Modem)  │  │          │      │
│  │ Linux    │  │ MPSS FW  │  │ wcnss FW │      │
│  │ (open)   │  │ (closed) │  │ (closed) │      │
│  └──────────┘  └──────────┘  └──────────┘      │
│                                                 │
│  ┌──────────┐  ┌──────────┐                     │
│  │   RPM    │  │TrustZone │                     │
│  │ (power)  │  │ (secure) │                     │
│  │          │  │          │                     │
│  │ rpm FW   │  │  tz FW   │                     │
│  │ (closed) │  │ (closed) │                     │
│  └──────────┘  └──────────┘                     │
└─────────────────────────────────────────────────┘
```

Each coprocessor runs its own proprietary firmware loaded by the kernel
via the `remoteproc` framework. Qualcomm does not publish source code
for any of these firmwares. The modem and WiFi firmware are
device-specific (tied to RF calibration), which is why we copy them
from the stock firmware backup rather than using generic versions.

The only component we replaced with open source is the **hypervisor**
(qhypstub replaces the stock Qualcomm HYP), which is necessary because
the mainline Linux kernel requires standard ARM hypervisor interfaces
that the stock Qualcomm hypervisor does not provide.

## Before and After

| | Stock Android 4.4 | OpenStick Debian 11 |
|---|---|---|
| OS | Android 4.4.4 (KTU84P) | Debian 12 (bookworm) |
| Kernel | 3.10 (Qualcomm fork) | 6.6 (postmarketOS mainline) |
| Root access | No | Yes (full root) |
| Shell | Limited busybox | Full bash + GNU tools |
| Package manager | None | apt |
| SSH | None | OpenSSH server |
| Modem control | Buggy web API | mmcli / qmicli (CLI) |
| USB networking | RNDIS without gateway | RNDIS with NAT gateway |
| WiFi config | Web UI (Chinese) | NetworkManager CLI/API |
| Cloud services | Chinese update server | None (fully self-hosted) |
| APN config | Manual via web UI | `mmcli --simple-connect` |
| Remote management | None | SSH over USB (RNDIS) |
| Storage available | ~100 MB (locked) | 2.8 GB free |
| Automation | None | systemd, cron, scripts |

## Custom Image Build (Docker)

Build a custom Debian image with your choice of package groups:

```bash
# Build the Docker image
docker build -t openstick-builder build/

# Build with defaults (base + monitoring + watchdog)
docker run --rm --privileged -v $(pwd)/build/output:/output openstick-builder

# Build with all packages + NetBird VPN
docker run --rm --privileged -v $(pwd)/build/output:/output openstick-builder \
  --packages "base monitoring diagnostics watchdog" \
  --vpn netbird \
  --hostname my-dongle
```

### After building: prepare for flash

The build produces two images:
- `rootfs.img` — sparse Android format (~370 MB), needs conversion to raw
- `boot.img` — Android boot image with appended DTB (~7 MB), ready to flash

```bash
# Convert rootfs sparse → raw (needed for EDL flash)
simg2img build/output/rootfs.img flash/files/rootfs.raw

# Copy boot image (already raw)
cp build/output/boot.img flash/files/boot.img

# Then flash as usual
cd flash && bash flash-openstick.sh
```

`simg2img` is available via `apt install android-sdk-libsparse-utils`.

### Package Groups

| Group | File | Contents |
|---|---|---|
| **base** | `build/packages/base.list` | Networking, modem, SSH, iptables, curl, jq, nano, htop |
| **monitoring** | `build/packages/monitoring.list` | Signal monitor, connection watchdog, data usage (cron scripts) |
| **diagnostics** | `build/packages/diagnostics.list` | tcpdump, mtr, iperf3, tmux, nftables |
| **watchdog** | `build/packages/watchdog.list` | Hardware watchdog — auto-reboot on hang |
| **vpn-netbird** | `build/packages/vpn-netbird.list` | NetBird mesh VPN for remote management |

Default build includes: `base monitoring watchdog`

### Monitoring (included via overlay)

The build bakes in cron scripts that run automatically:

| Script | Interval | Log file |
|---|---|---|
| `signal-monitor.sh` | 5 min | `/var/log/signal.log` |
| `connection-watchdog.sh` | 3 min | Auto-restarts modem, reboots if needed |
| `data-usage.sh` | 1 hour | `/var/log/data-usage.log` |
| Clock sync | daily | NTP via HTTP Date header |

## File Structure

```
├── backup/
│   ├── partitions/     # Full stock firmware backup (Phase 1)
│   ├── checksums.sha256
│   └── getprop.txt     # Stock Android system properties
├── build/
│   ├── Dockerfile            # Docker build environment (cross-compiler, arm64 libs)
│   ├── build.sh              # Image build script (kernel, rootfs, boot image, rmtfs)
│   ├── scripts/mkbootimg     # AOSP mkbootimg for Android boot image creation
│   ├── packages/             # Package group lists (.list files)
│   │   ├── base.list         # Core packages (always installed)
│   │   ├── monitoring.list   # Signal/connection monitoring
│   │   ├── diagnostics.list  # tcpdump, mtr, iperf3, tmux
│   │   ├── watchdog.list     # Hardware watchdog
│   │   └── vpn-netbird.list  # NetBird mesh VPN
│   └── overlay/              # Files baked into the image
│       ├── usr/local/bin/    # Monitoring scripts
│       └── etc/              # Cron jobs, logrotate, SSH, rmtfs.service, modem modules
├── backup/
│   ├── partitions/           # Stock firmware + modem calibration backup
│   ├── autosave_*/           # Auto-backups created by flash script (timestamped)
│   └── README.md
├── flash/
│   ├── flash-openstick.sh    # Automated flash script (auto-backups modem cal)
│   ├── configure-dongle.sh   # Post-flash configuration
│   ├── install-packages.sh   # Post-flash package install (alternative to build)
│   ├── files/                # Flash images
│   │   ├── emmc_appsboot-test-signed.mbn  # Dragonboard bootloader
│   │   ├── gpt_primary_proper.bin         # Primary GPT (sector 0)
│   │   ├── gpt_backup_proper.bin          # Backup GPT (end of disk)
│   │   ├── sbl1.mbn, rpm.mbn, tz.mbn     # Dragonboard firmware
│   │   ├── qhypstub-test-signed.mbn      # Hypervisor stub
│   │   ├── sbc_1.0_8016.bin              # CDT
│   │   ├── boot.img                      # 6.6 kernel + appended DTB (Android boot image)
│   │   └── rootfs.raw                    # Debian rootfs (ext4, raw image)
│   └── start.sh              # Original kinsamanka flash script (reference)
├── PLAN.md             # Detailed project plan + findings
├── FLASH-GUIDE.md      # Step-by-step flash guide
└── README.md
```

## Restoring Stock Firmware

A full stock firmware backup was created in Phase 1. To restore:

```bash
# Enter EDL: hold reset button while plugging in USB
# Then run from backup/partitions/:
edl wf ../full_firmware.bin   # Writes entire 3.7 GB firmware
# Or restore individual partitions — see backup/partitions/rawprogram0.xml
```

## Related

- [OpenStick](https://github.com/OpenStick/OpenStick) — Original project
- [OpenStick-Builder](https://github.com/kinsamanka/OpenStick-Builder) — Image builder
- [JZxx installation guide](https://gist.github.com/kinsamanka/0b01cd02412bd13ee072072043d46fa2) — kinsamanka's start.sh
- [USB-Dongle-WIFI-Configurator](https://github.com/thomas-greenautarky/USB-Dongle-WIFI-Configurator) — Stock Android provisioning

## License

MIT
