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
sudo apt install fastboot adb
```

### Flash OpenStick

```bash
# 1. Connect dongle running stock Android
# 2. Run the flash script:
cd flash
bash flash-openstick.sh

# 3. Configure the dongle:
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
- [ ] Phase 5: Configure RNDIS gateway for HA
- [ ] Phase 6: Provisioning script (flash + configure)
- [ ] Phase 7: Home Assistant integration

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
Stock SBL1 → Dragonboard aboot (fastboot) → Flash everything via fastboot
                                              ↓
Dragonboard SBL1 → qhypstub → Dragonboard aboot → OpenStick kernel → Debian
```

Key findings:
- **lk2nd goes in BOOT, not ABOOT** — stock SBL1 expects ELF in aboot
- **qhypstub breaks stock SBL1** — must use Dragonboard firmware stack
- **Stock GPT must be used initially** — custom GPT breaks boot chain
- **The start.sh two-stage approach works**: EDL → Dragonboard aboot → fastboot → flash all

See [FLASH-GUIDE.md](FLASH-GUIDE.md) for full details.

## File Structure

```
├── backup/
│   ├── partitions/     # Full stock firmware backup (Phase 1)
│   ├── checksums.sha256
│   └── getprop.txt     # Stock Android system properties
├── flash/
│   ├── flash-openstick.sh    # Automated flash script
│   ├── configure-dongle.sh   # Post-flash configuration
│   ├── files/                # Flash images
│   │   ├── emmc_appsboot-test-signed.mbn  # Dragonboard bootloader
│   │   ├── gpt_both0.bin                  # OpenStick partition table
│   │   ├── sbl1.mbn, rpm.mbn, tz.mbn     # Dragonboard firmware
│   │   ├── qhypstub-test-signed.mbn      # Hypervisor stub
│   │   ├── sbc_1.0_8016.bin              # CDT
│   │   ├── boot-ufi001c.img              # Linux kernel + initramfs
│   │   ├── rootfs.img                    # Debian rootfs (sparse)
│   │   └── lk2nd-msm8916.img            # lk2nd bootloader
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
