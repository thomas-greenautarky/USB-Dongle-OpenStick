# Stock Android Restore on UZ801

How to restore a UZ801 dongle (currently OpenStick / GA-OS or partially-flashed)
back to its factory Stock Android KitKat 4.4.4.

**Status:** ✅ verified working on SIM-WIN-00000014 (IMEI 860018046136249)
on 2026-04-30. Path 3 in our three-flow provisioning model.

## Why this is hard

The standard `flash-uz801.sh` flashes from EDL → OpenStick GA-OS in one go,
but assumes the dongle either currently runs Stock Android (so `adb reboot
edl` works) or is already in EDL via the JZ0145-v33 reset-pin. Neither
path applies once a UZ801 is on OpenStick.

Worse: the docs say *"Reset pin does NOT work on UZ801"*. To get an
OpenStick UZ801 into EDL you need either:

- **`adb reboot edl`** — only works if Stock Android is still installed (gone
  once you've flashed OpenStick)
- **lk1st-fastboot fallback** — reset pin enters lk1st-fastboot (USB ID
  `18d1:d00d`); but `fastboot oem edl` is not implemented in the lk1st 0.5
  bundled with our OpenStick rootfs
- **Hardware D+/USB-GND short** — reliably forces PBL EDL fallback. Plug
  in while shorting D+ to GND on the USB connector for ~3 s, then release.
  This is the entry method confirmed working on UZ801.

## What our backups actually contain

We keep two layers of backup, neither sufficient on its own:

| Source | What's in it | Use for |
|---|---|---|
| `backup/stock_uz801_<IMEI>_<date>/` | per-device `modemst1`, `modemst2`, `fsg`, `sec`, `fsc` (modem cal — preserves IMEI/IMSI radio config) | always |
| `backup/stock_uz801_<IMEI>_<date>/stock_partitions/` | per-device `sbl1`, `aboot`, `rpm`, `tz`, `hyp`, `modem`, `pad` (boot chain matched to the unit's hardware revision) | when restoring boot chain |
| `backup/partitions/` | universal Stock Android image dump (`boot`, `system`, `recovery`, `cache`, `persist`, `splash`, `ssd`, `misc`) + `rawprogram0.xml` partition layout | always (boot/system/etc) |

A complete factory restore requires combining all three — neither
the per-device backup nor the universal one is complete by itself.

## Sector layout — different from OpenStick

Critical insight from the 2026-04-30 SIM-WIN-14 restore: **OpenStick GPT
puts sbl1 at sector 131076; Stock-Android GPT puts it at sector 262144**.
Same SoC, completely different boot-chain offset.

| Partition | Stock-Android sector | OpenStick sector |
|---|---|---|
| modem | 131072 | 150566 |
| sbl1  | **262144** | **131076** |
| aboot | 264192 | 148518 |
| boot  | 396384 | 347174 |
| system | 429152 | (rootfs replaces this at 478246) |
| userdata | 2428000 | (covered by rootfs) |

The bootrom uses the **GPT** to find sbl1, so flashing the right Stock-Android
GPT first is mandatory. Use `gpt.bin` from the per-device `stock_partitions/`
backup — it matches that exact unit's eMMC geometry.

## Tooling pitfalls we hit

These cost us hours; capturing here so the next person doesn't repeat them:

1. **edl auto-loader detection hangs** on `ws` (sector writes) on UZ801. The
   default loader works for `w` (partition by name) but `ws` times out
   silently — observed 14 min hang on a 65 MB modem write. Fix: pass the
   explicit longcheer loader:
   ```bash
   --loader=$HOME/.local/share/pipx/venvs/edlclient/lib/python3.13/site-packages/Loaders/longcheer/007050e100000000_3022817d373fd7f9_fhprg_peek.bin
   ```
   This loader is shipped with `pipx install
   git+https://github.com/bkerler/edl.git`.

2. **`edl xml` doesn't accept `--memory=emmc`.** Without it, sector-size
   negotiation fails on UZ801 ("Sector size in XML 4096 does not match
   disk sector size 512"). Workaround: don't use `xml`; use sector-by-sector
   `ws` writes with `--memory=emmc`, parsed manually from `rawprogram0.xml`.

3. **`edl qfil`** raises a Python `TypeError` after Sahara handshake on
   modern firmware. Skip qfil mode entirely.

4. **`cmd | tail` masks edl exit codes.** A failed `edl` write printed
   "Lun0: boot, Lun0: rootfs" errors but `if ! cmd | tail; then …`
   reported success because tail's exit code is 0. Always check
   `${PIPESTATUS[0]}` or capture and grep the output for `error|fail|
   exception|traceback`.

5. **`edl: command not found` in non-interactive shells.** pipx puts
   binaries in `~/.local/bin`, which non-login shells don't add to PATH.
   Eagerly `export PATH="$HOME/.local/bin:$PATH"` at the top of any
   script that drives edl.

6. **`boot.bin` is an Android sparse image** — the magic
   `ed26ff3a` in the first four bytes. `flash-uz801.sh` writes it via
   `edl w boot` which auto-unsparseifies (so it works), but if you go
   directly with `edl ws <sector> boot.bin` the sparse format goes onto
   eMMC verbatim and the bootrom rejects it. Pre-process with
   `simg2img boot.bin boot.raw` and write the raw output, OR use
   `edl w boot` instead of `ws`.

7. **OpenStick generic `flash/files/uz801/sbl1.mbn` did NOT boot
   SIM-WIN-14.** Likely a sub-variant DDR config mismatch (the file is
   one specific UZ801 build, our SIM-WIN-14 is firmware
   `UZ801-V2.3.15.1` which apparently differs). Workaround:
   use the unit's own `stock_partitions/sbl1.bin` from its IMEI-specific
   backup — guaranteed compatible with that exact hardware.

## Working procedure (verified on SIM-WIN-14)

```bash
cd ~/git/USB-Dongle-OpenStick

# 1. Get the dongle into EDL — D+/USB-GND short while plugging in (3 s)
lsusb | grep 05c6:9008  # confirm

# 2. Set explicit loader path (script does this automatically)
export PATH="$HOME/.local/bin:$PATH"

# 3. Restore: takes per-device boot-chain + modem-cal + universal Stock Android
bash flash/restore-stock-android.sh \
    backup/partitions \
    backup/stock_uz801_<IMEI>_<date>

# 4. Wait for "All N writes successful, 0 failures" + auto edl reset

# 5. Unplug, replug normally (no D+ short, no reset pin)

# 6. Verify: lsusb shows 05c6:f00e or 05c6:9091 (Stock Android with ADB)
adb devices
adb shell getprop ro.build.fingerprint
# expected: qcom/msm8916_32_512/msm8916_32_512:4.4.4/KTU84P/...
```

## Caveat: universal Stock-Android image is incomplete for headless UZ801

After SIM-WIN-14 booted Stock Android, we observed `system_server`
crash-looping with:
```
*** FATAL EXCEPTION IN SYSTEM PROCESS: WindowManager
```
PIDs incrementing every ~2 seconds (5555 → 5837 → 6108 → ...). Only 11
out of ~100+ standard services come up; `iphonesubinfo`, `package`, and
all telephony services are absent. APN ContentProvider throws
NullPointerException because telephony framework never finished init.

Why: the universal Stock-Android image in `backup/partitions/system.bin`
was apparently dumped from a **display-equipped MSM8916 device**, not
the headless UZ801. WindowManager refuses to come up without a working
framebuffer / hardware composer; UZ801 has no display so this dies
immediately, and system_server's crash takes the whole Android userspace
down with it on every restart.

**Implications:**
- ADB works (init starts adbd before system_server)
- The boot chain (sbl1/aboot/kernel) is correct for UZ801
- But Android userspace can't run normally → no SettingsProvider, no
  TelephonyProvider, no `settings put` / `content insert` for APN/WiFi
- Stock Android **as-is** is therefore not a viable provisioning target
  on UZ801 with our current backup set

**To unblock Path 3 we'd need one of:**
1. A `system.img` built specifically for UZ801 (no-display) — would
   either need to be sourced from the OEM/vendor or built from AOSP
   with the UZ801 BoardConfig (no Surfaceflinger, no display HALs)
2. Or accept that Path 3 only configures via direct `/data/system/users/0/`
   file writes (Settings.db SQLite), bypassing the Android framework
   entirely. Possible but messy and version-fragile.
3. Or pick a different "stock"-firmware for UZ801 — e.g. a vendor-supplied
   modem-only firmware (like the ZTE "4G Modem" stack we already use for
   ARROW) which doesn't pull in Android UI.

Recommended: defer Path 3 implementation until we have a UZ801-matching
`system.img`. The eMMC-side tooling (`restore-stock-android.sh`) is
ready and works correctly — we just need the right user partition.

## Path 3 — what's possible now (provisioning via Stock Android)

With Stock Android booted on a UZ801, configuration is via **ADB shell** —
the equivalent of OpenStick's SSH or ARROW's web API:

| Setting | OpenStick path | ARROW path | **Stock Android path** |
|---|---|---|---|
| WiFi SSID | `nmcli connection ...` | `funcNo:1007` | `settings put global wifi_ap_ssid` (via ADB) |
| WiFi PSK | `nmcli ... wpa-psk` | `funcNo:1010` | `settings put global wifi_ap_passphrase` |
| APN | `/etc/default/lte-apn` | `funcNo:1017+1018` | `content insert --uri content://telephony/carriers …` |
| Admin pwd | `chpasswd` | `funcNo:1020` | n/a — ADB has no admin pwd |
| LTE probe | `curl --interface wwan0` | host `/32` route via dongle | `adb shell curl https://ghcr.io/` |
| DB record | `db_record_device` (`OpenStick`) | same (`ARROW`) | same (`STOCK`) |

Open work item (TODO):

- [ ] Write `provision-stock.sh` — like `provision-arrow.sh` but ADB-driven.
      Reuse `db.sh` for DB recording. Use `brand='STOCK'`, `dongle_type='UZ801'`.
- [ ] Decide whether to extract IMEI via Android `service call iphonesubinfo`
      or via ADB shell + `dumpsys iphonesubinfo` — the latter usually works
      on KitKat 4.4.4.

See [docs/vpn-vodafone-iot-apn.md](../../OpenStick-Provisioner/docs/vpn-vodafone-iot-apn.md)
for client-side VPN constraints — those apply identically to Stock Android,
ARROW, and OpenStick paths since the Vodafone IoT APN policy is the same
regardless of which firmware is on the dongle.

## Cross-references

- Tooling: [`flash/restore-stock-android.sh`](../flash/restore-stock-android.sh)
- Variant strategy: [`docs/variant-strategy.md`](variant-strategy.md)
- Per-flow comparison: [`OpenStick-Provisioner/README.md`](../../OpenStick-Provisioner/README.md)
