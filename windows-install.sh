#!/bin/bash
set -e


DISK=/dev/sda
WORK=/mnt/storage

WIN_URL="https://go.microsoft.com/fwlink/?linkid=2345730&culture=en-us&country=us"
VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso"

WIN_ISO="$WORK/winserver.iso"
VIRTIO_ISO="$WORK/virtio.iso"

echo "========================================"
echo "Windows Server 2025 installer"
echo "========================================"
echo
lsblk "$DISK"
# --------------------------------------------------
# 1. Install required tools
# --------------------------------------------------

apt update -y && apt upgrade -y
apt install -y \
    grub2 \
    ntfs-3g \
    wimtools || true

# --------------------------------------------------
# 2. Completely wipe disk
# --------------------------------------------------

echo
echo "Wiping $DISK..."

umount "${DISK}"* 2>/dev/null || true

wipefs -a "$DISK"

# Remove first/last part of disk to ensure clean partition table
dd if=/dev/zero of="$DISK" bs=1M count=10 status=progress
DISK_SIZE=$(blockdev --getsz "$DISK")
dd if=/dev/zero of="$DISK" bs=512 seek=$((DISK_SIZE - 20480)) count=20480 status=progress

sync

# --------------------------------------------------
# 3. Create MBR
# --------------------------------------------------

echo
echo "Creating MBR..."

parted -s "$DISK" mklabel msdos

WINSETUP_SIZE=10GiB

parted "$DISK" --script -- mklabel msdos
parted "$DISK" --script -- mkpart primary ntfs 1MiB "$WINSETUP_SIZE"
parted "$DISK" --script -- mkpart primary ntfs "$WINSETUP_SIZE" 100%

parted -s "$DISK" set 1 boot on

partprobe "$DISK"
sleep 3

# --------------------------------------------------
# 4. Format partitions
# --------------------------------------------------

echo
echo "Formatting..."

mkfs.ntfs -f -L WINSETUP "${DISK}1"
mkfs.ntfs -f -L WINDOWS "${DISK}2"

mkdir -p /mnt/storage
mount "${DISK}2" /mnt/storage
mkdir -p "$WORK"

# --------------------------------------------------
# 5. Download ISO files
# --------------------------------------------------

mkdir -p "$WORK"

echo
echo "Downloading Windows Server ISO..."

wget \
    --user-agent="Mozilla/5.0" \
    -O "$WIN_ISO" \
    "$WIN_URL" || {
    echo "ERROR: Windows ISO download failed"
    exit 1
}

echo
echo "Downloading VirtIO ISO..."

wget \
    -O "$VIRTIO_ISO" \
    "$VIRTIO_URL" || {
    echo "ERROR: VirtIO ISO download failed"
    exit 1
}

# --------------------------------------------------
# 6. Mount partitions / ISOs
# --------------------------------------------------

mkdir -p /mnt/winsetup
mkdir -p /mnt/winiso
mkdir -p /mnt/virtio

mount "${DISK}1" /mnt/winsetup
mount -o loop,ro "$WIN_ISO" /mnt/winiso
mount -o loop,ro "$VIRTIO_ISO" /mnt/virtio

# --------------------------------------------------
# 7. Copy Windows installer
# --------------------------------------------------

echo
echo "Copying Windows installer..."

rsync -aH --info=progress2 \
    /mnt/winiso/ \
    /mnt/winsetup/

# --------------------------------------------------
# 8. Copy VirtIO drivers
# --------------------------------------------------

echo
echo "Copying VirtIO drivers..."

mkdir -p /mnt/winsetup/virtio_drivers

rsync -a \
    /mnt/virtio/ \
    /mnt/winsetup/virtio_drivers/

# --------------------------------------------------
# 9. Inject VirtIO into boot.wim
# --------------------------------------------------

echo
echo "Injecting VirtIO drivers..."

mkdir -p /root/wim

rm -rf /root/wim/virtio_drivers

cp -a \
    /mnt/winsetup/virtio_drivers \
    /root/wim/

cat > /root/wim/update.txt <<'EOT'
add virtio_drivers /virtio_drivers
EOT

cd /root/wim

wimlib-imagex update \
    /mnt/winsetup/sources/boot.wim \
    2 \
    < update.txt

# --------------------------------------------------
# 10. Install GRUB BIOS
# --------------------------------------------------

echo
echo "Installing GRUB..."

grub-install \
    --target=i386-pc \
    --boot-directory=/mnt/winsetup/boot \
    "$DISK"

# --------------------------------------------------
# 11. GRUB config
# --------------------------------------------------

mkdir -p /mnt/winsetup/boot/grub

cat > /mnt/winsetup/boot/grub/grub.cfg <<'EOT'
set timeout=3
set default=0

insmod part_msdos
insmod ntfs

menuentry "Windows Server 2025 Installer" {
    search --no-floppy --file --set=root /bootmgr
    ntldr /bootmgr
}
EOT

# --------------------------------------------------
# 12. Finish
# --------------------------------------------------

sync

echo
echo "Final disk:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS

echo
echo "Unmounting..."

umount /mnt/winiso
umount /mnt/virtio
umount /mnt/winsetup

sync

echo
echo "========================================"
echo "READY"
echo "========================================"
echo
echo "Now reboot and boot from local disk."

reboot
