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
sudo apt install adb        # ADB for post-flash configuration
```

### Flash OpenStick (EDL-only method)

```bash
# 1. Enter EDL: hold reset button while plugging in USB
#    (or from stock Android: adb reboot edl)
# 2. Run the flash script:
cd flash
bash flash-openstick.sh

# 3. After Debian boots, configure the dongle:
bash configure-dongle.sh \
  --hostname my-dongle \
  --wifi-ssid "4G-Gateway" \
  --wifi-password "mypassword" \
  --apn "internet" \
  --ssh-key ~/.ssh/id_ed25519.pub \
  --timezone Europe/Berlin
```

### Manual Flash (step by step)

See [FLASH-GUIDE.md](FLASH-GUIDE.md) for the detailed procedure.

## Status

- [x] Phase 1: Full firmware backup via EDL
- [x] Phase 2: Board identified as JZ0145-v33 (xiaoxun,jz0145-v33)
- [x] Phase 3: Boot chain analysis and flash method discovery
- [x] Phase 4: Flash OpenStick — Debian 11 running
- [x] Phase 5: LTE connected, NAT gateway working, SSH access
- [x] Phase 6: Provisioning scripts (flash-openstick.sh + configure-dongle.sh)
- [ ] Phase 7: Home Assistant integration

## TODO

- [ ] **Hardware watchdog**: needs boot grace period testing before deployment.
      The LTE modem takes 60-90s to register after boot. The connection watchdog
      must skip checks during the first 180s (3 min) after boot. The hardware
      watchdog (`/dev/watchdog`) must not trigger during modem registration.
      Caused a reboot loop in testing — do NOT install the watchdog package
      until boot grace period is validated.
      Connection watchdog must use `systemctl restart ModemManager` (NOT
      `mmcli --disable/--enable`).
- [ ] **SIM detection reliability**: SIM detection is intermittent on fresh rootfs.
      With UFI001C DTB, SIM is often not detected. With JZ0145-v33 DTB (baked
      into `boot-jz0145.img`), SIM is detected reliably. Sometimes requires a
      physical replug. Once detected, modem connects to LTE automatically.
- [ ] **Home Assistant integration**: test RNDIS auto-detection by HA.

## What's Running

After a successful flash, the dongle runs:

| Component | Details |
|---|---|
| OS | Debian 11 (bullseye), aarch64 |
| Kernel | 5.15.0-handsomekernel+ |
| RAM | 382 MB (191 MB free) |
| Storage | 3.5 GB rootfs (2.8 GB free) |
| Modem | Qualcomm LTE, managed via ModemManager |
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
Dragonboard SBL1 → qhypstub → Dragonboard aboot → boot-jz0145.img → Debian
```

Key findings:
- **EDL-only flash works reliably** — no fastboot step needed
- **Fastboot is unreliable on this board** — Dragonboard aboot exposes USB ID
  `18d1:d001` / `05c6:9091`, which the host `fastboot` tool (v34.0.5) cannot
  communicate with. ADB server also holds the USB device, blocking fastboot.
- **GPT must be split into primary + backup** — `gpt_both0.bin` has wrong
  rootfs size and incorrect backup GPT sector when written via EDL. Use
  `gpt_primary_proper.bin` (sector 0) + `gpt_backup_proper.bin` (end of disk).
- **Boot image with baked-in DTB** — `boot-jz0145.img` is an Android boot
  image with the JZ0145-v33 DTB compiled in. Extlinux approach broke boot
  because the aboot fastboot interface is unreachable from the host.
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
| Linux kernel 5.15 | GPL-2.0 | msm8916 mainline support, wcn36xx WiFi driver |
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
| OS | Android 4.4.4 (KTU84P) | Debian 11 (bullseye) |
| Kernel | 3.10 (Qualcomm fork) | 5.15 (mainline) |
| Root access | No | Yes (full root) |
| Shell | Limited busybox | Full bash + GNU tools |
| Package manager | None | apt |
| SSH | None | OpenSSH server |
| Modem control | Buggy web API | mmcli / qmicli (CLI) |
| USB networking | RNDIS without gateway | RNDIS with NAT gateway |
| WiFi config | Web UI (Chinese) | NetworkManager CLI/API |
| Cloud services | Chinese update server | None (fully self-hosted) |
| APN config | Manual via web UI | `mmcli --simple-connect` |
| Remote management | None | SSH, ADB |
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
│   ├── Dockerfile            # Docker build environment
│   ├── build.sh              # Image build script
│   ├── packages/             # Package group lists (.list files)
│   │   ├── base.list         # Core packages (always installed)
│   │   ├── monitoring.list   # Signal/connection monitoring
│   │   ├── diagnostics.list  # tcpdump, mtr, iperf3, tmux
│   │   ├── watchdog.list     # Hardware watchdog
│   │   └── vpn-netbird.list  # NetBird mesh VPN
│   └── overlay/              # Files baked into the image
│       ├── usr/local/bin/    # Monitoring scripts
│       └── etc/              # Cron jobs, logrotate, SSH config
├── flash/
│   ├── flash-openstick.sh    # Automated flash script
│   ├── configure-dongle.sh   # Post-flash configuration
│   ├── install-packages.sh   # Post-flash package install (alternative to build)
│   ├── files/                # Flash images
│   │   ├── emmc_appsboot-test-signed.mbn  # Dragonboard bootloader
│   │   ├── gpt_primary_proper.bin         # Primary GPT (sector 0)
│   │   ├── gpt_backup_proper.bin          # Backup GPT (end of disk)
│   │   ├── sbl1.mbn, rpm.mbn, tz.mbn     # Dragonboard firmware
│   │   ├── qhypstub-test-signed.mbn      # Hypervisor stub
│   │   ├── sbc_1.0_8016.bin              # CDT
│   │   ├── boot-jz0145.img               # Linux kernel + JZ0145-v33 DTB
│   │   └── rootfs.raw                    # Debian rootfs (raw image)
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
