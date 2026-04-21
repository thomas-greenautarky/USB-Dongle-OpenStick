# USB-Dongle-OpenStick — TODO

Items tracked here belong to the **rootfs build** (kernel config, baked-in
services, default files). Provisioner-side TODOs live in
`OpenStick-Provisioner/TODO.md`.

## Kernel config

- [ ] **Enable `CONFIG_LEDS_TRIGGER_NETDEV`** in the kernel fragment used to
      build the rootfs. Once this is in, the `*:wan` LED can be wired to
      `wwan0` link state directly by `/usr/local/bin/led-status.sh` (no
      userspace polling needed).
      - Consequence: the `led-lte-watcher.service` deployed by
        `OpenStick-Provisioner/provision.sh` becomes redundant and can be
        removed from provisioning. Leave a compat check — if the kernel
        trigger exists, don't install the watcher.
      - Verify after rebuild: on a flashed dongle, `cat
        /sys/class/leds/blue:wan/trigger` must contain `netdev` as an option.

## Baked-in services (currently patched in by Provisioner)

- [ ] **`clock-sync.service`** already ships in the rootfs but needs
      retries / longer grace period — on first boot it runs before
      `modem-autoconnect` has brought up the default bearer, so NTP
      fails and the dongle stays on the rootfs build date. Workaround
      today: Provisioner pushes host time via `date -u -s` before
      `netbird up`. Fix in rootfs: make `clock-sync.service` wait for
      `network-online.target` AND for wwan0 to have a default route, with
      a long retry loop (because LTE attach + bearer can take 60-90s).
      - Point it at `time.cloudflare.com` — confirmed whitelisted in the
        Vodafone IoT `EP_GreenAutarky_ACL`. `pool.ntp.org` is NOT whitelisted.

- [ ] **`modem-autoconnect.service`** sometimes races modem registration
      on first boot and gives up before the bearer is up, leaving wwan0
      without an IP. Workaround today: Provisioner calls `mmcli
      --simple-connect` and applies bearer IP/GW/DNS manually before
      `netbird up`. Fix in rootfs: retry loop with backoff, wait for
      `modem.generic.state == registered` before attempting connect.

## Nice-to-have

- [ ] Bake the improved `led-status.sh` (netdev-trigger-aware) into the
      rootfs directly, so fresh flashes have it even before the
      Provisioner gets to run.
- [ ] Document the fact that UZ801 v3.0 has no RTC battery in README —
      users will hit cert-not-yet-valid on any HTTPS call until first
      NTP sync. Provisioner's time push is a bandaid; real fix is
      a fake-hwclock package in the rootfs so the clock at least moves
      forward by the last known time on each boot.
