#!/bin/bash -e
#
# build.sh — Build a custom OpenStick Debian image for JZ0145-v33 dongles
#
# Usage (via Docker):
#   docker build -t openstick-builder build/
#   docker run --rm --privileged -v $(pwd)/build/output:/output openstick-builder
#
# Usage (via Docker with options):
#   docker run --rm --privileged -v $(pwd)/build/output:/output openstick-builder \
#     --packages "base monitoring diagnostics watchdog vpn-netbird" \
#     --hostname openstick
#
# Package lists (in build/packages/):
#   base.list         — Always installed (networking, modem, SSH, tools)
#   monitoring.list   — Signal monitoring, connection watchdog, data usage
#   diagnostics.list  — tcpdump, mtr, iperf3, tmux, nftables
#   watchdog.list     — Hardware watchdog for unattended deployment
#   vpn-netbird.list  — NetBird mesh VPN for remote management

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
err() { echo -e "${RED}[x]${NC} $1"; exit 1; }

# ─── Defaults ────────────────────────────────────────────────────────────────

PACKAGE_GROUPS="base monitoring watchdog vpn-netbird"
HOST_NAME="openstick"
OUTPUT_DIR="/output"
RELEASE="bookworm"
ROOTFS_SIZE="1536M"

# ─── Parse arguments ────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case $1 in
        --packages)  PACKAGE_GROUPS="$2"; shift 2 ;;
        --hostname)  HOST_NAME="$2"; shift 2 ;;
        --output)    OUTPUT_DIR="$2"; shift 2 ;;
        --release)   RELEASE="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --packages \"list\"   Package groups (default: base monitoring watchdog vpn-netbird)"
            echo "                      Available: base monitoring diagnostics watchdog vpn-netbird"
            echo "  --hostname NAME     Set hostname (default: openstick)"
            echo "  --output DIR        Output directory (default: /output)"
            echo "  --release NAME      Debian release (default: bookworm)"
            exit 0
            ;;
        *) err "Unknown option: $1" ;;
    esac
done

WORKDIR=$(mktemp -d)
CHROOT="$WORKDIR/rootfs"

log "Build configuration:"
echo "  Package groups: $PACKAGE_GROUPS"
echo "  Hostname:       $HOST_NAME"
echo "  Release:        $RELEASE"
echo "  Output:         $OUTPUT_DIR"

# ─── Collect packages ────────────────────────────────────────────────────────

PACKAGES=""
for group in $PACKAGE_GROUPS; do
    list="/build/packages/${group}.list"
    if [ -f "$list" ]; then
        # Read non-comment, non-empty lines
        group_pkgs=$(grep -v '^#' "$list" | grep -v '^\s*$' | tr '\n' ' ')
        PACKAGES="$PACKAGES $group_pkgs"
        log "Package group '$group': $(echo $group_pkgs | wc -w) packages"
    else
        err "Package list not found: $list"
    fi
done

log "Total packages: $(echo $PACKAGES | wc -w)"

# ─── Bootstrap rootfs ───────────────────────────────────────────────────────

log "Bootstrapping Debian $RELEASE (arm64)..."
debootstrap --foreign --arch arm64 \
    --keyring /usr/share/keyrings/debian-archive-keyring.gpg \
    "$RELEASE" "$CHROOT"

cp $(which qemu-aarch64-static) "$CHROOT/usr/bin/"
chroot "$CHROOT" qemu-aarch64-static /bin/bash /debootstrap/debootstrap --second-stage

# ─── Configure apt sources ──────────────────────────────────────────────────

cat > "$CHROOT/etc/apt/sources.list" << EOF
deb http://deb.debian.org/debian ${RELEASE} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian-security/ ${RELEASE}-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${RELEASE}-updates main contrib non-free non-free-firmware
EOF


# ─── Mount for chroot ───────────────────────────────────────────────────────

mount -t proc proc "$CHROOT/proc/"
mount -t sysfs sys "$CHROOT/sys/"
mount -o bind /dev/ "$CHROOT/dev/"
mount -o bind /dev/pts/ "$CHROOT/dev/pts/"
mount -o bind /run "$CHROOT/run/"

# ─── Install packages in chroot ─────────────────────────────────────────────

cat > "$CHROOT/install.sh" << INSTALLEOF
#!/bin/sh -e
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

echo 'tzdata tzdata/Areas select Etc' | debconf-set-selections
echo 'tzdata tzdata/Zones/Etc select UTC' | debconf-set-selections
echo "locales locales/default_environment_locale select en_US.UTF-8" | debconf-set-selections
echo "locales locales/locales_to_be_generated multiselect en_US.UTF-8 UTF-8" | debconf-set-selections
rm -f /etc/locale.gen

# Prevent any service from starting during install (we're in a chroot)
ln -sf /bin/true /usr/sbin/policy-rc.d

# Add third-party apt repos needed by package groups
case " $PACKAGES " in
    *netbird*)
        apt-get update -qq
        apt-get install -qq -y --no-install-recommends wget gnupg ca-certificates
        wget -qO- https://pkgs.netbird.io/debian/public.key \
            | gpg --dearmor -o /usr/share/keyrings/netbird-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/netbird-archive-keyring.gpg] https://pkgs.netbird.io/debian stable main" \
            > /etc/apt/sources.list.d/netbird.list
        ;;
esac

apt-get update -qq
apt-get upgrade -qq -y
apt-get install -qq -y --no-install-recommends $PACKAGES
apt-get autoremove -qq -y
apt-get clean
rm -rf /var/lib/apt/lists/*

rm -f /usr/sbin/policy-rc.d

# Root account: default password (change during provisioning)
echo 'root:openstick' | chpasswd

# Use nftables backend for iptables (kernel 6.6 supports both)
update-alternatives --set iptables /usr/sbin/iptables-nft 2>/dev/null || true
update-alternatives --set ip6tables /usr/sbin/ip6tables-nft 2>/dev/null || true

# Create user account
echo user:1::::/home/user:/bin/bash | newusers
mkdir -p /etc/sudoers.d
echo 'user ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/user
INSTALLEOF

log "Installing packages in chroot..."
chroot "$CHROOT" qemu-aarch64-static /bin/sh /install.sh
rm -f "$CHROOT/install.sh"

# ─── Install postmarketOS MSM8916 kernel ───────────────────────────────────

log "Installing postmarketOS 6.6 kernel (MSM8916)..."
wget -qO - http://mirror.postmarketos.org/postmarketos/v24.06/aarch64/linux-postmarketos-qcom-msm8916-6.6-r5.apk \
    | tar xzf - -C "$CHROOT" --exclude=.PKGINFO --exclude='.SIGN*' 2>/dev/null || true

# Fix /lib symlink: the kernel .apk creates /lib/modules/ as a real directory,
# but Debian bullseye uses usrmerge (/lib -> /usr/lib symlink). Without this fix,
# the dynamic linker /lib/ld-linux-aarch64.so.1 is missing and no ELF can execute.
if [ -d "$CHROOT/lib" ] && [ ! -L "$CHROOT/lib" ]; then
    log "Fixing /lib symlink (usrmerge)..."
    cp -a "$CHROOT/lib/"* "$CHROOT/usr/lib/" 2>/dev/null || true
    rm -rf "$CHROOT/lib"
    ln -s usr/lib "$CHROOT/lib"
fi

# Copy board-specific DTB (JZ0145-v33 — required for SIM card detection)
if [ -f /build/boot/msm8916-jz01-45-v33.dtb ]; then
    mkdir -p "$CHROOT/boot/dtbs/qcom"
    cp /build/boot/msm8916-jz01-45-v33.dtb "$CHROOT/boot/dtbs/qcom/"
fi

# ─── Cross-compile modem support tools (qrtr-ns, rmtfs) ────────────────────

log "Building qrtr-ns and rmtfs for arm64..."
CC=aarch64-linux-gnu-gcc

# qrtr library + nameservice
wget -qO- https://github.com/linux-msm/qrtr/archive/master.tar.gz | tar xz -C /tmp
cd /tmp/qrtr-master
$CC -c -I include lib/qrtr.c -o lib/qrtr.o
$CC -c -I include lib/qmi.c -o lib/qmi.o
$CC -c -I include lib/logging.c -o lib/logging.o
ar rcs libqrtr.a lib/qrtr.o lib/qmi.o lib/logging.o
$CC -static -I include src/addr.c src/lookup.c libqrtr.a -o "$CHROOT/usr/local/bin/qrtr-ns"

# rmtfs (remote filesystem service for modem NV storage)
wget -qO- https://github.com/linux-msm/rmtfs/archive/master.tar.gz | tar xz -C /tmp
cd /tmp/rmtfs-master
for f in rmtfs qmi_rmtfs sharedmem storage util rproc; do
    $CC -I /tmp/qrtr-master/include -c ${f}.c
done
$CC rmtfs.o qmi_rmtfs.o sharedmem.o storage.o util.o rproc.o \
    /tmp/qrtr-master/libqrtr.a -ludev -lpthread -o "$CHROOT/usr/local/bin/rmtfs"

chmod +x "$CHROOT/usr/local/bin/qrtr-ns" "$CHROOT/usr/local/bin/rmtfs"
cd /build

# ─── Install modem firmware (generic, same for all dongles of this type) ────

if [ -d /build/firmware ] && [ -f /build/firmware/modem.mdt ]; then
    log "Installing modem + WiFi firmware from stock backup..."
    mkdir -p "$CHROOT/lib/firmware/wlan/prima"
    cp /build/firmware/*.mdt /build/firmware/*.mbn /build/firmware/*.b* "$CHROOT/lib/firmware/" 2>/dev/null
    # WiFi NV calibration (device-specific RF cal for wcn36xx)
    [ -f /build/firmware/wlan/prima/WCNSS_qcom_wlan_nv.bin ] && \
        cp /build/firmware/wlan/prima/WCNSS_qcom_wlan_nv.bin "$CHROOT/lib/firmware/wlan/prima/"
fi

# ─── Apply overlay ──────────────────────────────────────────────────────────

log "Applying overlay files..."
cp -a /build/overlay/* "$CHROOT/" 2>/dev/null || true

# Make scripts executable
chmod +x "$CHROOT"/usr/local/bin/*.sh 2>/dev/null || true

# Generate module dependency files (for modprobe)
KVER=$(ls "$CHROOT/lib/modules/" 2>/dev/null | head -1)
if [ -n "$KVER" ]; then
    log "Running depmod for kernel $KVER..."
    chroot "$CHROOT" qemu-aarch64-static /sbin/depmod -a "$KVER" 2>/dev/null || true
fi

# Fix cron permissions
chmod 644 "$CHROOT"/etc/cron.d/* 2>/dev/null || true
chmod 644 "$CHROOT"/etc/logrotate.d/* 2>/dev/null || true

# ─── Enable services ──────────────────────────────────────────────────────

log "Enabling services..."

# Disable networking.service (conflicts with NetworkManager, causes "degraded" state)
rm -f "$CHROOT/etc/systemd/system/multi-user.target.wants/networking.service" 2>/dev/null
ln -sf /dev/null "$CHROOT/etc/systemd/system/networking.service" 2>/dev/null

# Enable USB RNDIS gadget
if [ -f "$CHROOT/etc/systemd/system/usb-gadget.service" ]; then
    mkdir -p "$CHROOT/etc/systemd/system/multi-user.target.wants"
    ln -sf /etc/systemd/system/usb-gadget.service \
        "$CHROOT/etc/systemd/system/multi-user.target.wants/usb-gadget.service"
fi

# Ensure /etc/network/interfaces sources interfaces.d/
if ! grep -q "source.*interfaces.d" "$CHROOT/etc/network/interfaces" 2>/dev/null; then
    echo "" >> "$CHROOT/etc/network/interfaces"
    echo "source /etc/network/interfaces.d/*" >> "$CHROOT/etc/network/interfaces"
fi

# Enable iptables NAT restore
if [ -f "$CHROOT/etc/systemd/system/iptables-restore.service" ]; then
    ln -sf /etc/systemd/system/iptables-restore.service \
        "$CHROOT/etc/systemd/system/multi-user.target.wants/iptables-restore.service"
fi

# Enable rmtfs (modem remote filesystem — must start before ModemManager)
if [ -f "$CHROOT/etc/systemd/system/rmtfs.service" ]; then
    ln -sf /etc/systemd/system/rmtfs.service \
        "$CHROOT/etc/systemd/system/multi-user.target.wants/rmtfs.service"
fi

# Enable modem auto-connect (LTE + wwan0 IP config on boot)
if [ -f "$CHROOT/etc/systemd/system/modem-autoconnect.service" ]; then
    ln -sf /etc/systemd/system/modem-autoconnect.service \
        "$CHROOT/etc/systemd/system/multi-user.target.wants/modem-autoconnect.service"
fi

# Enable clock sync (HTTP Date header, runs after LTE connects)
if [ -f "$CHROOT/etc/systemd/system/clock-sync.service" ]; then
    ln -sf /etc/systemd/system/clock-sync.service \
        "$CHROOT/etc/systemd/system/multi-user.target.wants/clock-sync.service"
fi

# Enable dnsmasq
mkdir -p "$CHROOT/etc/systemd/system/multi-user.target.wants"
ln -sf /lib/systemd/system/dnsmasq.service \
    "$CHROOT/etc/systemd/system/multi-user.target.wants/dnsmasq.service" 2>/dev/null || true

# Enable SSH
ln -sf /lib/systemd/system/ssh.service \
    "$CHROOT/etc/systemd/system/multi-user.target.wants/ssh.service" 2>/dev/null || true

# ─── Configure hostname ─────────────────────────────────────────────────────

echo "$HOST_NAME" > "$CHROOT/etc/hostname"
sed -i "/localhost/ s/$/ ${HOST_NAME}/" "$CHROOT/etc/hosts"

# ─── Configure sysctl ───────────────────────────────────────────────────────

echo "net.ipv4.ip_forward=1" > "$CHROOT/etc/sysctl.d/99-forward.conf"

# ─── Cleanup ─────────────────────────────────────────────────────────────────

echo -n > "$CHROOT/root/.bash_history"

# Stop any services that were started during package install (e.g. NetBird)
# so /dev and /proc can be cleanly unmounted
chroot "$CHROOT" qemu-aarch64-static /bin/sh -c "
    # Stop NetBird and any other daemons started by dpkg postinst
    /etc/init.d/netbird stop 2>/dev/null || true
    killall netbird 2>/dev/null; sleep 1; killall -9 netbird 2>/dev/null
    # Kill all remaining processes in the chroot
    fuser -km /proc 2>/dev/null
" || true
sleep 2

for a in run dev/pts dev sys proc; do
    umount "$CHROOT/$a" 2>/dev/null || umount -l "$CHROOT/$a"
done

# ─── Create images ──────────────────────────────────────────────────────────

log "Creating rootfs image..."
mkdir -p "$WORKDIR/mnt" "$OUTPUT_DIR"

truncate -s "$ROOTFS_SIZE" "$WORKDIR/rootfs.raw"
mkfs.ext4 "$WORKDIR/rootfs.raw"
mount "$WORKDIR/rootfs.raw" "$WORKDIR/mnt"
cp -a "$CHROOT"/* "$WORKDIR/mnt/" 2>/dev/null || true

# ─── Verify image contents before finalizing ────────────────────────────────

log "Verifying rootfs contents..."
VERIFY_FAIL=0

for bin in usr/local/bin/modem-autoconnect.sh usr/local/bin/rmtfs usr/local/bin/qrtr-ns usr/sbin/sshd; do
    if [ -f "$WORKDIR/mnt/$bin" ]; then
        log "  OK: /$bin"
    else
        log "  MISSING: /$bin"
        VERIFY_FAIL=1
    fi
done
if echo "$PACKAGE_GROUPS" | grep -q "vpn-netbird"; then
    if [ -f "$WORKDIR/mnt/usr/bin/netbird" ]; then
        log "  OK: /usr/bin/netbird"
    else
        log "  MISSING: /usr/bin/netbird (vpn-netbird package group)"
        VERIFY_FAIL=1
    fi
fi

umount "$WORKDIR/mnt"

[ "$VERIFY_FAIL" -eq 0 ] || err "Rootfs verification failed — aborting"

# Create sparse image for EDL flash
img2simg "$WORKDIR/rootfs.raw" "$OUTPUT_DIR/rootfs.img"

# ─── Create boot image (Android boot image with appended DTB) ──────────────
# The Dragonboard aboot loads this as a standard Android boot image.
# DTB is appended after the gzip-compressed kernel — aboot finds it by scanning
# for the FDT magic (0xd00dfeed) after the gzip stream.

log "Creating boot image (appended DTB)..."

# Use JZ0145-v33 DTB — stock UFI001C DTB doesn't detect SIM card on JZ0145 boards
DTB="$CHROOT/boot/dtbs/qcom/msm8916-jz01-45-v33.dtb"
[ -f "$DTB" ] || err "DTB not found: $DTB"

cat "$CHROOT/boot/vmlinuz" "$DTB" > "$WORKDIR/vmlinuz-dtb"
python3 /build/scripts/mkbootimg \
    --kernel "$WORKDIR/vmlinuz-dtb" \
    --cmdline "earlycon root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e console=ttyMSM0,115200 rw rootwait" \
    --base 0x80000000 \
    --pagesize 2048 \
    --header_version 0 \
    -o "$OUTPUT_DIR/boot.img"

# ─── Copy to flash directory ─────────────────────────────────────────────────

FLASH_DIR="/build/../flash/files"
if [ -d "$FLASH_DIR" ]; then
    log "Copying images to flash/files/..."
    simg2img "$OUTPUT_DIR/rootfs.img" "$FLASH_DIR/rootfs.raw"
    cp "$OUTPUT_DIR/boot.img" "$FLASH_DIR/boot.img"
    log "  rootfs.raw: $(du -h "$FLASH_DIR/rootfs.raw" | cut -f1)"
    log "  boot.img:   $(du -h "$FLASH_DIR/boot.img" | cut -f1)"
fi

# ─── Cleanup ─────────────────────────────────────────────────────────────────

rm -rf "$WORKDIR"

log "Build complete!"
echo ""
echo "Output files:"
ls -lh "$OUTPUT_DIR/"*.img
echo ""
echo "Flash with:"
echo "  cd flash && bash flash-openstick.sh"
echo "  bash configure-dongle.sh"
