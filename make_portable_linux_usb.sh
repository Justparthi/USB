#!/bin/bash
# Persistent OS Maker - Create a fully portable Linux installation on a USB drive
# WARNING: This will erase the target drive completely!

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)."
  exit 1
fi

if [ $# -ne 2 ]; then
  echo "Usage: sudo ./make_portable_linux_usb.sh /dev/sdX ubuntu-24.04.iso"
  exit 1
fi

TARGET=$1
ISO=$2

# Safety confirmation
echo "==================================================="
echo " About to erase and install Linux onto: $TARGET"
echo " ISO: $ISO"
echo "==================================================="
read -p "Type YES to continue: " CONFIRM
[ "$CONFIRM" == "YES" ] || { echo "Aborted."; exit 1; }

echo "[*] Unmounting and cleaning $TARGET..."
umount ${TARGET}?* || true
swapoff -a || true

echo "[*] Partitioning $TARGET..."
parted -s $TARGET mklabel gpt
parted -s $TARGET mkpart EFI fat32 1MiB 512MiB
parted -s $TARGET set 1 esp on
parted -s $TARGET mkpart root ext4 512MiB 100%

EFI_PART=${TARGET}1
ROOT_PART=${TARGET}2

sleep 2

echo "[*] Formatting partitions..."
mkfs.vfat -F32 -n EFI $EFI_PART
mkfs.ext4 -F -L rootfs $ROOT_PART

echo "[*] Mounting partitions..."
mkdir -p /mnt/usb-root
mount $ROOT_PART /mnt/usb-root
mkdir -p /mnt/usb-root/boot/efi
mount $EFI_PART /mnt/usb-root/boot/efi

echo "[*] Extracting ISO base system..."
mkdir /mnt/iso
mount -o loop $ISO /mnt/iso

echo "[*] Copying ISO content..."
rsync -aHAX /mnt/iso/ /mnt/usb-root/

echo "[*] Installing base system..."
debootstrap --arch amd64 $(ls /mnt/iso/dists | head -n 1) /mnt/usb-root http://archive.ubuntu.com/ubuntu

echo "[*] Preparing chroot environment..."
for dir in dev proc sys run; do
  mount --bind /$dir /mnt/usb-root/$dir
done

cat <<EOF > /mnt/usb-root/root/setup.sh
#!/bin/bash
set -e
echo "[*] Configuring base system..."
echo "root:toor" | chpasswd
apt update
apt install -y linux-generic grub-efi-amd64 grub-pc network-manager sudo
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=PortableLinux --recheck
grub-install --target=i386-pc --boot-directory=/boot --recheck $TARGET
update-grub
EOF

chmod +x /mnt/usb-root/root/setup.sh

echo "[*] Entering chroot to finish installation..."
chroot /mnt/usb-root /root/setup.sh

echo "[*] Cleaning up..."
for dir in dev proc sys run; do
  umount -lf /mnt/usb-root/$dir
done
umount -lf /mnt/usb-root/boot/efi
umount -lf /mnt/usb-root
umount -lf /mnt/iso

echo "==================================================="
echo "✅ Installation complete!"
echo "You now have a fully portable Linux OS on $TARGET"
echo "Boot from it on any computer — your entire system persists."
echo "Default root password: toor"
echo "==================================================="
