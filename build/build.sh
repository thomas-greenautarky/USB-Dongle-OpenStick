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
#     --packages "base monitoring diagnostics watchdog" \
#     --hostname openstick \
#     --vpn netbird
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

PACKAGE_GROUPS="base monitoring watchdog"
HOST_NAME="openstick"
INSTALL_VPN=""
OUTPUT_DIR="/output"
RELEASE="bullseye"
ROOTFS_SIZE="1536M"

# ─── Parse arguments ────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case $1 in
        --packages)  PACKAGE_GROUPS="$2"; shift 2 ;;
        --hostname)  HOST_NAME="$2"; shift 2 ;;
        --vpn)       INSTALL_VPN="$2"; shift 2 ;;
        --output)    OUTPUT_DIR="$2"; shift 2 ;;
        --release)   RELEASE="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --packages \"list\"   Package groups to install (default: base monitoring watchdog)"
            echo "                      Available: base monitoring diagnostics watchdog"
            echo "  --hostname NAME     Set hostname (default: openstick)"
            echo "  --vpn netbird       Install NetBird VPN"
            echo "  --output DIR        Output directory (default: /output)"
            echo "  --release NAME      Debian release (default: bullseye)"
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
echo "  VPN:            ${INSTALL_VPN:-none}"
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
deb http://deb.debian.org/debian ${RELEASE} main contrib non-free
deb http://deb.debian.org/debian-security/ ${RELEASE}-security main contrib non-free
deb http://deb.debian.org/debian ${RELEASE}-updates main contrib non-free
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

apt-get update -qq
apt-get upgrade -qq -y
apt-get install -qq -y --no-install-recommends $PACKAGES
apt-get autoremove -qq -y
apt-get clean
rm -rf /var/lib/apt/lists/*

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

# Override with board-specific DTB
mkdir -p "$CHROOT/boot/dtbs/qcom"
cp /build/boot/msm8916-jz01-45-v33.dtb "$CHROOT/boot/dtbs/qcom/"

# ─── Install NetBird VPN if requested ────────────────────────────────────────

if [ "$INSTALL_VPN" = "netbird" ]; then
    log "Installing NetBird VPN..."
    cat > "$CHROOT/install-vpn.sh" << 'VPNEOF'
#!/bin/sh -e
export DEBIAN_FRONTEND=noninteractive
curl -fsSL https://pkgs.netbird.io/install.sh | bash
apt-get clean
rm -rf /var/lib/apt/lists/*
VPNEOF
    chroot "$CHROOT" qemu-aarch64-static /bin/sh /install-vpn.sh
    rm -f "$CHROOT/install-vpn.sh"
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

for a in proc sys dev/pts dev run; do
    umount "$CHROOT/$a"
done

# ─── Create images ──────────────────────────────────────────────────────────

log "Creating rootfs image..."
mkdir -p "$WORKDIR/mnt" "$OUTPUT_DIR"

truncate -s "$ROOTFS_SIZE" "$WORKDIR/rootfs.raw"
mkfs.ext2 -q "$WORKDIR/rootfs.raw"
mount "$WORKDIR/rootfs.raw" "$WORKDIR/mnt"
cp -a "$CHROOT"/* "$WORKDIR/mnt/" 2>/dev/null || true

# Add extlinux boot config to rootfs (lk2nd scans ext2 partitions for this)
mkdir -p "$WORKDIR/mnt/boot/extlinux" "$WORKDIR/mnt/boot/dtbs/qcom"
cp /build/boot/extlinux.conf "$WORKDIR/mnt/boot/extlinux/"
cp "$CHROOT/boot/vmlinuz" "$WORKDIR/mnt/boot/"
cp "$CHROOT/boot/dtbs/qcom/msm8916-jz01-45-v33.dtb" "$WORKDIR/mnt/boot/dtbs/qcom/"

umount "$WORKDIR/mnt"

# Create sparse image for fastboot
img2simg "$WORKDIR/rootfs.raw" "$OUTPUT_DIR/rootfs.img"

log "Creating boot image (lk2nd + ext2 kernel)..."

# lk2nd occupies the first 512 KiB of the boot partition.
# After booting, lk2nd scans for ext2 at 512K offset with /extlinux/extlinux.conf.
LK2ND_SIZE=524288  # 512 KiB
BOOT_TOTAL=67108864  # 64 MiB
EXT2_SIZE=$((BOOT_TOTAL - LK2ND_SIZE))

# Step 1: Create 64MB raw image with lk2nd at offset 0
truncate -s "$BOOT_TOTAL" "$WORKDIR/boot.raw"
dd if=/build/boot/lk2nd-msm8916.img of="$WORKDIR/boot.raw" conv=notrunc 2>/dev/null

# Step 2: Create ext2 filesystem for kernel area (64MB - 512K)
truncate -s "$EXT2_SIZE" "$WORKDIR/boot_ext2.raw"
mkfs.ext2 -q "$WORKDIR/boot_ext2.raw"

# Step 3: Populate ext2 with kernel, DTB, extlinux.conf
mount "$WORKDIR/boot_ext2.raw" "$WORKDIR/mnt"
cp "$CHROOT/boot/vmlinuz" "$WORKDIR/mnt/vmlinuz"
mkdir -p "$WORKDIR/mnt/dtbs/qcom"
cp "$CHROOT/boot/dtbs/qcom/msm8916-jz01-45-v33.dtb" "$WORKDIR/mnt/dtbs/qcom/"
mkdir -p "$WORKDIR/mnt/extlinux"
cp /build/boot/extlinux.conf "$WORKDIR/mnt/extlinux/"
umount "$WORKDIR/mnt"

# Step 4: Combine — dd ext2 at 512K offset (after lk2nd reservation)
dd if="$WORKDIR/boot_ext2.raw" of="$WORKDIR/boot.raw" bs="$LK2ND_SIZE" seek=1 conv=notrunc 2>/dev/null

# Output as raw (64MB, no sparse conversion needed for EDL)
cp "$WORKDIR/boot.raw" "$OUTPUT_DIR/boot.img"

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
