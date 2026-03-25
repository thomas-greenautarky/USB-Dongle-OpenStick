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
- Board variant: JZxx-series (compatible with OpenStick `jz01-45-v33` DTB)

## Status

See [PLAN.md](PLAN.md) for the detailed implementation plan.

- [ ] Phase 1: Backup original firmware
- [ ] Phase 2: Identify exact board variant
- [ ] Phase 3: Build OpenStick image
- [ ] Phase 4: Flash OpenStick
- [ ] Phase 5: Configure RNDIS gateway for HA
- [ ] Phase 6: Provisioning script
- [ ] Phase 7: Home Assistant integration

## Related

- [USB-Dongle-WIFI-Configurator](https://github.com/thomas-greenautarky/USB-Dongle-WIFI-Configurator) — Provisioning script for stock Android firmware

## License

MIT
