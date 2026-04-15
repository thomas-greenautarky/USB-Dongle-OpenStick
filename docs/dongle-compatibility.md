# Dongle Compatibility & Known Hardware

## Identifying Your Dongle

All supported dongles use the Qualcomm MSM8916 SoC. They differ in:
- eMMC size (affects GPT layout)
- Board layout (affects which firmware/DTB to use)
- EDL entry method (reset pin vs. web API vs. ADB)

### Hardware Detection via EDL

When in EDL mode, `edl printgpt` reports:
```
HWID:    0x007050e100000000 (MSM_ID:0x007050e1)
CPU:     "MSM8916"
Serial:  0x<unique>
Loader:  longcheer / qualcomm / ...
```

The loader manufacturer and serial help identify the board type.

## Known Dongle Types

### Type A: JZ0145-v33 (confirmed working)

| Property | Value |
|----------|-------|
| Board | JZ0145-v33 |
| SoC | MSM8916 |
| eMMC | 3.73 GB (7,733,248 sectors) |
| Stock USB ID | Unknown (donated pre-flashed) |
| EDL USB ID | `05c6:9008` |
| EDL entry | Reset pin (hold + plug in USB) |
| EDL loader | longcheer |
| Firmware | Dragonboard aboot (299K) |
| DTB | `msm8916-jz01-45-v33.dtb` |
| Status | **Fully supported** |

### Type B: Longcheer variant (boot failure)

| Property | Value |
|----------|-------|
| Board | Unknown (Longcheer) |
| SoC | MSM8916 |
| eMMC | 3.81 GB (7,864,320 sectors) |
| Stock USB ID | `05c6:f00e` (Qualcomm FP3) |
| EDL USB ID | `05c6:9008` |
| EDL entry | Reset pin does NOT work; needs web API or ADB |
| EDL loader | longcheer (`007050e1...3022817d373fd7f9`) |
| EDL Serial | `0x24b5de67` |
| Firmware | Different aboot (1.0 MB vs 299K) |
| DTB | Unknown — JZ0145-v33 DTB does not boot |
| Status | **Not supported yet** — needs matching firmware + DTB |

Stock Android web interface at `http://192.168.100.1` (USB network `192.168.100.x`).

### Type C: Stock Android 4G Modem (untested)

| Property | Value |
|----------|-------|
| Stock USB ID | `05c6:f00e` |
| Web interface | `http://192.168.100.1` |
| API endpoint | `POST http://192.168.100.1:80/ajax` with JSON body |
| EDL entry | Web API: `{"module":"systemCmd","action":1,"command":"reboot edl"}` |
| Status | **Untested** — may be same as Type B |

## EDL Entry Methods

### Method 1: Reset Pin (preferred)

Works for: Type A (JZ0145-v33)

1. Unplug the dongle
2. Insert a pin/needle into the reset hole
3. Hold the button while plugging in USB
4. Keep holding for 5-10 seconds
5. Release — device should appear as `05c6:9008`

### Method 2: Web API

Works for: Dongles running Stock Android with web interface (`05c6:f00e`)

1. Plug in dongle (boots to Stock Android)
2. Wait for USB network interface (`enx*`) and IP via DHCP
3. Access web API:
   ```bash
   # Enable ADB
   curl -s "http://192.168.100.1:80/ajax" \
       -d '{"module":"systemCmd","action":1,"command":"setprop persist.sys.usb.config diag,adb"}'
   
   # Reboot to EDL
   curl -s "http://192.168.100.1:80/ajax" \
       -d '{"module":"systemCmd","action":1,"command":"reboot edl"}'
   ```
   Note: Returns `flag:0` but may not execute — needs further testing.

### Method 3: ADB

Works for: Dongles with ADB enabled

1. Plug in dongle
2. `adb devices` to verify connection
3. `adb reboot edl`

ADB may need to be enabled first via web interface or `setprop`.

### Method 4: Short test points on PCB

Last resort — requires opening the dongle case:
1. Locate the EDL test points on the PCB (varies by board)
2. Short them while plugging in USB
3. This forces the SoC into EDL regardless of software state

## eMMC Sizes

The flash script generates GPT dynamically based on actual eMMC size.
Known sizes:

| Size | Sectors | Backup GPT Sector | Dongle Type |
|------|---------|-------------------|-------------|
| 3.73 GB | 7,733,248 | 7,733,215 | Type A (JZ0145-v33) |
| 3.81 GB | 7,864,320 | 7,864,287 | Type B (Longcheer variant) |

## Firmware Differences

Different boards require different bootloader firmware. Do NOT flash
Type A firmware onto a Type B dongle — it will not boot.

| Component | Type A (JZ0145-v33) | Type B (Longcheer) |
|-----------|--------------------|--------------------|
| sbl1 | 256K (d08adf83) | 512K (45df879a) |
| rpm | 152K (6e17f48a) | 512K (3a639e05) |
| tz | 592K (ce11a70e) | 1.0M (b841cac7) |
| hyp | 12K (13f6c62b) | 512K (c2d81ccd) |
| cdt | 4K (a86a456f) | 4K (b7f1e79b) |
| aboot | 299K (8e0b0294) | 1.0M (7df7846a) |

The flash script should detect the board type (via backup comparison)
and select the correct firmware. This is not yet implemented.

## Backup & Restore

Every flash creates a full backup in `backup/autosave_<timestamp>/`:
- `gpt_primary.bin` — original GPT (first 34 sectors)
- `sbl1.bin`, `rpm.bin`, `tz.bin`, `hyp.bin`, `cdt.bin`, `aboot.bin` — firmware
- `boot.bin` — original boot image (kernel)
- `rootfs.bin` — original rootfs (may fail for large partitions)
- `sec.bin`, `fsc.bin`, `fsg.bin`, `modemst1.bin`, `modemst2.bin` — modem calibration

Restore with:
```bash
cd flash && bash restore-dongle.sh ../backup/autosave_<timestamp>
```
