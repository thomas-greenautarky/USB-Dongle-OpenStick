# USB-Dongle-OpenStick — TODO

Items tracked here belong to the **rootfs build** (kernel config, baked-in
services, default files). Provisioner-side TODOs live in
`OpenStick-Provisioner/TODO.md`.

## Backup completeness (HIGH PRIORITY — found 2026-04-30)

Audit of `backup/stock_uz801_*/` revealed **0 of 30 backups are complete**.
ALL of them are missing `system.bin` (the Stock Android user filesystem,
~800 MB). Most also miss `boot.bin`. Without these, we cannot restore
any unit to factory Stock Android — Path 3 provisioning blocked until
either a vendor image arrives or we full-dump a fresh untouched UZ801.

- [ ] **Extend `flash-uz801.sh` backup phase to do a FULL eMMC dump.**
      Current ADB-pull phase only grabs boot-chain + modem-cal because
      pulling system+userdata via ADB is slow (5-10 min). Switch to
      EDL-side `edl rl <dir>` after the boot-chain backup — gives us
      every partition including system.bin and userdata.bin in one
      sweep. Trade-off: adds ~5 min to provisioning time but provides
      full reversibility.

- [ ] **Add `flash/verify-backup.sh` (one-shot audit tool)** that takes
      a backup directory and prints a completeness report. Required
      files: sbl1, sbl1bak, aboot, abootbak, rpm, rpmbak, tz, tzbak,
      hyp, hypbak, modem, modemst1, modemst2, fsg, sec, fsc, boot,
      system, recovery, persist, cache, misc, splash, ssd, pad +
      device_info.txt with IMEI + firmware version + dump-method.
      Refuse-to-flash gate: `flash-uz801.sh` should run this on the
      pre-flash backup dir and abort unless backup verifies complete
      (or `--accept-incomplete-backup` is passed explicitly).

- [ ] **Re-dump all currently-OpenStick UZ801s** (the 12+ already-flashed
      units we have today) **before any future flash operation**. Once
      we re-flash one, its remaining factory data goes — and we cannot
      restore it to stock without the missing system.bin. So: install
      a side-channel for "stock-or-not" tracking and do `edl rl`
      backups on every unit while they are still in some bootable state.
      For units already on OpenStick: flash-uz801.sh's backup is what
      we have, accept the irreversibility and move on.

- [ ] **Vendor request to Yiming/Longcheer** for UZ801-V2.3.15.1
      `system.img` (and matching `boot.img`, both signed). Without
      these, Path 3 / "Stock-Android-Provisioning" stays theoretical.
      See [docs/stock-android-restore.md](docs/stock-android-restore.md)
      for context.

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
      - Related: `modem-autoconnect.sh` currently defaults to
        `APN=internet` at boot, which Vodafone IoT SIMs reject with
        `ServiceOptionNotSubscribed`. It does read `/etc/default/lte-apn`
        but that file doesn't exist yet on first boot (Provisioner writes
        it in Step 4). Fix in rootfs: either bake the real APN into the
        image, or make the service retry after a delay so it has a chance
        to pick up `/etc/default/lte-apn` written by the provisioner.

## Operator visibility

- [ ] Add per-write heartbeat ticks to `flash/flash-uz801.sh`. The rootfs
      write (2–5 min) and the modem-firmware-copy phase emit no output
      until the write finishes, so the operator can't tell "still running"
      from "deadlocked". `OpenStick-Provisioner/provision.sh` already has
      a `run_with_tick` helper that prints `[label] still working... Xs
      elapsed` every 5s — port the same pattern around the `edl w ...`
      calls for rootfs and the modem-firmware loop. Keep ticks below ~10
      lines for a normal run.

## Nice-to-have

- [ ] Bake the improved `led-status.sh` (netdev-trigger-aware) into the
      rootfs directly, so fresh flashes have it even before the
      Provisioner gets to run.

- [ ] LED colour semantics tied to connection *quality*, not just the
      link flag:
      - `green:wlan` (or a dedicated status LED) → solid green **only
        when** modem is `connected`, a bearer is up, default route is
        via wwan0, AND signal-quality is >= a threshold (e.g. >= 50 %).
      - red / amber when modem registered but signal poor or bearer
        flapping.
      - red when modem not registered at all (parked SIM, no service).
      A simple state machine fed by `mmcli -m 0 -K` every 5s would do
      the job. Today's led-lte-watcher.service only uses the link flag
      so a poor-signal-but-still-connected state looks the same as a
      great connection.
- [ ] Document the fact that UZ801 v3.0 has no RTC battery in README —
      users will hit cert-not-yet-valid on any HTTPS call until first
      NTP sync. Provisioner's time push is a bandaid; real fix is
      a fake-hwclock package in the rootfs so the clock at least moves
      forward by the last known time on each boot.
