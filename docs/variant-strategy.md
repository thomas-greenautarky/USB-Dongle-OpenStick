# Dongle Variant Strategy

How this project handles multiple physical MSM8916 dongle variants without
building separate rootfs images per variant.

## TL;DR

**One universal rootfs image + orchestrator-level adaptation** — not per-type
builds. Adding a new variant should be a matter of adding a DTB, recording
HWID/eMMC in the DB, and (optionally) type-specific post-boot patches, not
spinning up a new rootfs build pipeline.

## Problem space

We encounter MSM8916-based USB dongles in multiple physical shapes:

| Known variants | eMMC | Entry method | Flash script |
|---|---|---|---|
| UZ801 v3 (Yiming) | 3.6 GB | ADB reboot EDL | `flash-uz801.sh` |
| JZ0145-v33 | 3.7 GB | reset pin | `flash-openstick.sh` |
| 3.84 GB variant (unknown) | 3.84 GB | PBL fallback | TBD (needs DTB research) |

All share the same SoC (MSM8916 / Snapdragon 410), same basic Linux
support (kernel 6.6 with msm8916 platform), and same Debian userland.
They differ in:

1. **DTB** — board-specific device tree (PMIC, USB controller wiring,
   WiFi antenna, LEDs, SIM slot, reset pin).
2. **Partition layout quirks** — eMMC size → rootfs size varies.
3. **Modem firmware blobs** — often identical for MSM8916 but some
   variants use slightly different builds.
4. **Entry method** — how to reach EDL (reset pin works on JZ0145,
   not UZ801 v3 → uses `adb reboot edl` from Stock Android instead).

## Two approaches and why we pick one

### Rejected: per-variant rootfs builds

Build `rootfs-uz801.raw`, `rootfs-jz0145.raw`, `rootfs-variant3.raw`
separately with each one's firmware, DTB, and tweaks baked in.

**Against this:**
- N variants → N Docker builds → N artifacts to ship and keep in sync
- Adding a new variant requires a full build cycle (slow)
- Most of the content is identical across variants — rebuilds duplicate work
- Doesn't scale to unknown variants that we haven't built for

### Chosen: universal rootfs + orchestrator adaptation

Build **one** `rootfs.raw` that works on any MSM8916 variant, with
adaptation happening at three layers:

1. **lk2nd boot-time DTB selection**
   - `boot.bin` ships all known MSM8916 DTBs.
   - `extlinux.conf` points lk2nd at the right DTB via `fdtdir`.
   - Result: one boot.bin, one rootfs, many physical dongles.

2. **Variant-agnostic overlay in rootfs**
   - Services and helpers written to pattern-match hardware, not hardcode
     names. Example: `led-status.sh` iterates `/sys/class/leds/*` and
     matches on suffix (`*:wan`, `*:wlan`) — works whether the LED is
     called `blue:wan`, `red:wan`, or anything else.
   - Firmware files in `/lib/firmware/` cover the whole MSM8916 family.

3. **`provision.sh` as the adaptation layer**
   - **Detect variant** via pre-flash EDL probe (HWID, eMMC sectors) and
     post-flash DT model (`/sys/firmware/devicetree/base/model`).
   - **Pick flash strategy** (`flash-uz801.sh` vs `flash-openstick.sh`)
     based on detected USB ID + eMMC.
   - **Patch post-boot** for anything the rootfs can't know about in
     advance: LED service, firmware auto-heal, modem-autoconnect reset.
   - **Record** the variant in the DB so fleet reporting distinguishes them.

## Rules for keeping the universal rootfs universal

When adding new functionality to the overlay/build, follow these rules:

1. **Pattern-match hardware, don't hardcode.**
   If you need to touch `/sys/class/leds/blue:wan`, iterate and match
   instead. If you need a specific GPIO, look it up via device-tree label
   rather than `/sys/class/gpio/NN`.

2. **Fail-safe on missing hardware.**
   A service targeting a component that doesn't exist on a variant must
   exit 0, not fail. `|| true`, `[ -e /path ] || continue`.

3. **Firmware files: ship the superset.**
   If variant A needs `foo.b00` and variant B needs `bar.b00`, ship both
   in `/lib/firmware/`. The kernel loads what it needs.

4. **DTBs: ship all known MSM8916 variants in boot.bin.**
   lk2nd picks the right one at boot via the dongle's board-id or serial
   console probe. No rebuild per variant.

5. **If it's truly variant-specific, do it in provision.sh.**
   E.g. an APN table that only applies to one carrier's SIM, or a
   per-variant calibration tweak.

## Handling unknown variants

When `provision.sh` encounters a dongle whose EDL probe doesn't match
anything in the DB:

1. **Record what we learned** (HWID, eMMC size, DT model) in the DB with
   `dongle_type='unknown'` so we have ground truth for next time.
2. **Try the universal UZ801 flash strategy** (lk2nd + all DTBs) — this
   has the best chance of working because lk2nd picks DTB at boot.
3. **If boot fails** (no RNDIS after 90 s) flag the dongle as
   "needs DTB research" in the DB/memory. Add its DTB to `boot.bin`
   in a follow-up and retry.

## Current status (2026-04-17)

- Universal rootfs: **partially in place** — one rootfs.raw, lk2nd
  selects DTB via extlinux, overlay mostly variant-agnostic.
- Firmware superset: **done** — `flash/files/uz801/modem_firmware/`
  is the reference and gets copied to any dongle that doesn't already
  have it (both at flash time and via provision.sh auto-heal).
- LED service: **variant-agnostic** via pattern matching (this doc).
- Orchestrator adaptation: **in place** — HWID probe, auto-heal,
  modem-autoconnect reset, LED service install.
- Per-variant flash scripts: **still split** (`flash-uz801.sh` vs
  `flash-openstick.sh`) — long-term TODO to unify on lk2nd across the
  board.

## Decision rule

Before adding anything variant-specific, ask: **can this be done in the
orchestrator or via pattern matching in the rootfs?** If yes, do that.
Only reach for a per-type rootfs build if no other option works — and
even then, prefer a per-type **overlay** over a per-type image.
