# OpenStick for UFI 4G USB Dongle — Project Plan

## Goal

Replace the stock Android 4.4 firmware on a UFI 4G USB dongle with **Debian Linux
(OpenStick)** to get full control: root access, proper RNDIS gateway, APN automation,
SSH, and reliable USB internet for Home Assistant.

## Current Hardware

```
Device:     UFI 4G USB WiFi Dongle (Amazon B0C3SC6ZG6)
SoC:        Qualcomm MSM8916 (Snapdragon 410), 4x Cortex-A53
RAM:        512 MB (394 MB usable)
Storage:    3.7 GB eMMC (mmcblk0)
Board Type: JZxx-series (likely jz01-45-v33, UFI variant)
USB ID:     05c6:9024 (Android mode)
Modem:      Qualcomm LTE (baseband PM.1.0.c7-00193)
Current OS: Android 4.4.4 (KTU84P), build eng.richal.20251104
```

## Why OpenStick?

| Problem (Android 4.4) | Solution (OpenStick/Debian) |
|---|---|
| Web API crashes with curl (AndroidAsync bug) | No web API needed — direct config via SSH |
| No root access via ADB | Full root access |
| Can't automate APN config | Direct control over modem via mmcli/qmicli |
| RNDIS has no gateway → HA can't use it | Proper NAT gateway via iptables/nftables |
| No SSH, limited shell tools | Full Debian with apt, SSH, systemd |
| Encrypted/obfuscated app (jiagu) | Open source, transparent config |
| Chinese cloud update server (privacy?) | No phone-home, fully self-hosted |

## Phases

### Phase 1: Backup (CRITICAL — do first, before anything else)

**Goal:** Full backup of the original firmware so we can restore if something goes wrong.

- [ ] 1.1 Test EDL mode (press reset button while plugging in USB)
- [ ] 1.2 Install `edl` tool (Qualcomm Emergency Download) on host PC
- [ ] 1.3 Dump all partitions via EDL: `edl rf orig_fw.bin`
- [ ] 1.4 Also backup via ADB what we can:
  - `adb pull /sdcard/hostapd.conf` (WiFi config)
  - `adb shell getprop` > props.txt (all device properties)
  - Partition table: `adb shell cat /proc/partitions`
- [ ] 1.5 Store backup safely (this repo, encrypted if needed)
- [ ] 1.6 Verify backup integrity (checksum)

**Tools needed:**
```bash
pip3 install edl        # Qualcomm EDL tool
sudo apt install adb    # Already installed
```

### Phase 2: Identify Exact Board Variant

**Goal:** Confirm which OpenStick device tree blob (DTB) to use.

- [ ] 2.1 Check if dongle has a reset button (needed for EDL mode)
- [ ] 2.2 Compare partition layout with known boards:
  - `jz01-45-v33` (JZxx series — most likely for our "UFI" device)
  - `thwc-ufi001c` (UFI001C variant)
- [ ] 2.3 Check PCB markings if possible (open the case)
- [ ] 2.4 Compare `adb shell getprop` output with community databases
- [ ] 2.5 Test booting with each DTB before flashing

**Known partition layout (matches standard MSM8916):**
```
sbl1, aboot, boot, system, userdata, modem, persist,
recovery, cache, firmware, rpm, tz, hyp, ...
```

### Phase 3: Build OpenStick Image

**Goal:** Create a Debian image tailored for our dongle.

- [ ] 3.1 Clone OpenStick-Builder: `git clone https://github.com/kinsamanka/OpenStick-Builder`
- [ ] 3.2 Configure for our board variant (DTB selection)
- [ ] 3.3 Build the image (Docker-based build system)
- [ ] 3.4 Customize image:
  - Pre-configure RNDIS USB gadget as NAT gateway
  - Enable SSH server (dropbear or openssh)
  - Pre-install modem tools: `modemmanager`, `libqmi-utils`
  - Set static IP for USB gadget (e.g., 192.168.8.1)
  - Configure dnsmasq for DHCP on USB interface
  - Auto-connect LTE modem on boot
- [ ] 3.5 Test image in a safe way (boot without flashing if possible)

### Phase 4: Flash OpenStick

**Goal:** Install Debian on the dongle.

- [ ] 4.1 Enter EDL mode (reset button + USB plug)
- [ ] 4.2 Flash bootloader (lk2nd — Little Kernel 2nd stage)
- [ ] 4.3 Flash partition table (gpt_both0.bin)
- [ ] 4.4 Flash boot partition (kernel + initramfs)
- [ ] 4.5 Flash rootfs partition (Debian)
- [ ] 4.6 First boot — verify serial console via USB
- [ ] 4.7 Verify modem firmware is intact

### Phase 5: Configure Network (RNDIS Gateway for HA)

**Goal:** Make the dongle a proper USB internet gateway that Home Assistant
can use automatically.

- [ ] 5.1 Configure USB gadget mode (ECM or RNDIS)
  ```
  Host PC ←USB→ Dongle (192.168.8.1) ←LTE→ Internet
  ```
- [ ] 5.2 Set up NAT/masquerading:
  ```bash
  # On the dongle (Debian):
  iptables -t nat -A POSTROUTING -o wwan0 -j MASQUERADE
  echo 1 > /proc/sys/net/ipv4/ip_forward
  ```
- [ ] 5.3 Configure dnsmasq on USB interface:
  - DHCP range: 192.168.8.100-192.168.8.200
  - Gateway: 192.168.8.1 (the dongle itself)
  - DNS: forward to upstream
- [ ] 5.4 Configure LTE modem:
  ```bash
  mmcli -m 0 --simple-connect="apn=internet.provider.com"
  ```
- [ ] 5.5 Test from host PC:
  ```bash
  ping -I usb0 8.8.8.8
  curl --interface usb0 http://httpbin.org/ip
  ```
- [ ] 5.6 Test with Home Assistant:
  - Plug dongle into HA host
  - Verify HA gets default route via USB
  - Verify HA can reach the internet

### Phase 6: Provisioning Script

**Goal:** Automate the full setup for mass deployment.

- [ ] 6.1 Script to flash OpenStick via EDL (one-shot)
- [ ] 6.2 Script to configure a freshly-flashed dongle via SSH:
  - Set APN
  - Set WiFi SSID/password (if hostapd is used)
  - Set hostname
  - Set SSH keys
- [ ] 6.3 Integrate with the existing `configure-dongle.sh` from the
      USB-Dongle-WIFI-Configurator repo (or replace it)
- [ ] 6.4 Batch provisioning: flash + configure in one step

### Phase 7: Home Assistant Integration (Future)

**Goal:** Make the dongle a first-class HA peripheral.

- [ ] 7.1 Auto-detect dongle connection in HA
- [ ] 7.2 Failover: switch to 4G when primary internet is down
- [ ] 7.3 Monitor signal strength, data usage via HA sensors
- [ ] 7.4 SMS notification integration (send/receive SMS via HA)
- [ ] 7.5 GPS tracking if modem supports it

## Risks

| Risk | Mitigation |
|---|---|
| Bricking the dongle | Full backup via EDL before flashing, EDL restore always works |
| Wrong DTB → no boot | Test multiple DTBs, lk2nd bootloader allows recovery |
| Modem firmware corrupted | Modem partition is separate, won't be touched during flash |
| WiFi not working | wcn36xx driver in mainline kernel, well-tested on MSM8916 |
| No RNDIS | USB gadget configfs is standard in mainline kernel |

## References

- [OpenStick-Builder](https://github.com/kinsamanka/OpenStick-Builder) — Debian image builder
- [OpenStick GitHub](https://github.com/OpenStick/OpenStick) — Original project
- [JZxx installation guide](https://gist.github.com/kinsamanka/0b01cd02412bd13ee072072043d46fa2)
- [Supported devices](https://deepwiki.com/kinsamanka/OpenStick-Builder/7.2-supported-devices)
- [postmarketOS MSM8916](https://wiki.postmarketos.org/wiki/Qualcomm_Snapdragon_410/412_(MSM8916)) — kernel source

## Phase 2 Findings: Board Identification

### Confirmed Board Type

| Property | Value |
|---|---|
| Board | **Juzhen (矩阵) UFI** |
| OpenStick DTB | `msm8916-jz01-45-v33.dtb` |
| lk2nd device | `lk2nd-msm8916` |
| Build product | `msm8916_32_512` |
| HWID | `0x007050e100000000` |
| EDL Serial | `0x1f7ca289` |
| CPU | MSM8916, unfused (any loader works) |
| RAM | 512 MB |
| eMMC | 3.7 GB (mmcblk0) |

### Discovery: Juzhen Configuration Properties

All dongle settings are stored as Android system properties (`persist.sys.juzhen.*`):

```
persist.sys.juzhen.type        = ufi          # device type
persist.sys.juzhen.ssid.prefix = 4G-UFI-      # SSID prefix
persist.sys.juzhen.ssid.suffix = 2            # digits from IMEI for SSID
persist.sys.juzhen.ssid.pd     = 1234567890   # WiFi password
persist.sys.juzhen.web.pd      = admin        # Web admin password
persist.sys.juzhen.sncode      = 35158010517311  # serial number
persist.sys.juzhen.sim.pd      = UFIadmin88888   # SIM management password
persist.sys.juzhen.sn          = 1            # unknown
```

These properties might be writable via `adb shell setprop` — needs testing.
If so, this provides a MUCH simpler way to change WiFi/web passwords on the
stock Android firmware (no hostapd.conf editing, no HTTP API needed).

### OpenStick Installation Method

For JZxx boards, use the kinsamanka installation script:
```bash
# 1. Enter EDL mode (reset button + USB plug)
# 2. Run:
wget https://gist.github.com/kinsamanka/0b01cd02412bd13ee072072043d46fa2/raw/start.sh
bash start.sh
```

The script handles: bootloader (lk2nd) → partition table → kernel → Debian rootfs.

## Phase 3 Findings: Boot Chain Analysis

### Critical Discovery: lk2nd Goes in BOOT, Not ABOOT

The stock SBL1 expects an **ELF binary** in the aboot partition. lk2nd is packaged
as an **Android boot image** (zImage). Placing lk2nd in aboot causes SBL1 to fail
silently — no USB, no fastboot, nothing.

**Correct approach:** Keep stock aboot (ELF), place lk2nd in the boot partition.
Stock aboot loads lk2nd as a "kernel", then lk2nd provides fastboot and chainloads
the real Linux kernel.

### Board Identity (confirmed by lk2nd fastboot)

```
lk2nd:model       = JZ0145 v33 4G Modem Stick
lk2nd:compatible  = xiaoxun,jz0145-v33
lk2nd:version     = 22.0
serialno          = e80fd820
wifimacaddr       = 02:00:E8:0F:D8:20
```

### qhypstub Breaks the Boot Chain

Replacing stock hyp with `qhypstub-test-signed.mbn` prevents SBL1 from booting
entirely. Stock hyp must remain for the bootloader chain to work. This creates a
potential conflict since mainline Linux may require qhypstub for proper SMP and
memory management.

### GPT Layout Constraints

The stock SBL1 requires early partitions (modem through hyp) at their original
sectors. A "hybrid GPT" was created that keeps stock layout for firmware partitions
but replaces system/userdata/cache with a single rootfs partition.

### Working Boot Sequence (proven)

```
1. Full stock restore → verify Android boots via ADB
2. `adb reboot edl` → EDL mode (no button press needed)
3. `edl w boot lk2nd-msm8916.img` → flash lk2nd to boot partition
4. `edl reset` → lk2nd fastboot appears
5. `fastboot oem reboot-edl` → back to EDL without button press
```

### Current Blocker

`fastboot boot boot-ufi001c.img` (temporary kernel boot) crashes immediately.
Likely causes: no rootfs partition (stock GPT, PARTUUID mismatch) and/or
stock hyp incompatible with mainline kernel. Need to test with hybrid GPT
(rootfs present) while keeping stock hyp.
