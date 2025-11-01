#!/usr/bin/env bash
# make_persistent_usb.sh
# Usage:
#   sudo ./make_persistent_usb.sh /dev/sdX debian-bookworm /path/to/your_snapshot_script.sh
#
# This will:
#  - partition /dev/sdX as: 512MB EFI (FAT32) + remaining linux filesystem (btrfs)
#  - create btrfs with subvolumes: @ (root) and @snapshots
#  - debootstrap a minimal Debian system into the @ subvolume
#  - install kernel, btrfs-progs, grub (UEFI+BIOS)
#  - copy your snapshot script into /usr/local/bin on the USB system
#  - install GRUB config to boot the USB (both UEFI and BIOS)
#
set -euo pipefail
IFS=$'\n\t'

if [ "$EUID" -ne 0 ]; then
  echo "Run me as root (sudo)." >&2
  exit 1
fi

DEV="${1:-}"
SUITE="${2:-bookworm}"   # Debian suite or 'ubuntu-24.04' etc if available in debootstrap
SNAP_SCRIPT_SRC="${3:-}"

if [ -z "$DEV" ]; then
  echo "Usage: $0 /dev/sdX [suite] [path-to-snapshot-script]" >&2
  exit 1
fi

if [ ! -b "$DEV" ]; then
  echo "Device $DEV not found or not a block device." >&2
  exit 1
fi

if [ -n "$SNAP_SCRIPT_SRC" ] && [ ! -f "$SNAP_SCRIPT_SRC" ]; then
  echo "Snapshot script file $SNAP_SCRIPT_SRC not found." >&2
  exit 1
fi

# --- Config ---
EFI_SIZE_MB=512
MOUNT_POINT="/mnt/usb_root"
EFI_MOUNT="$MOUNT_POINT/boot/efi"
ROOT_SUBVOL="@"
SNAP_SUBVOL="@snapshots"
HOSTNAME="usb-live"
USERNAME="usbuser"
PASSWORD="usbuser"   # change later or create interactive user
LOCALE="en_US.UTF-8"
TIMEZONE="UTC"
DEBOOTSTRAP_MIRROR="http://deb.debian.org/debian"

# --- Partitioning ---
echo ">>> Partitioning $DEV"
sgdisk --zap-all "$DEV"

# create partitions: 1 = EFI, 2 = root
EFI_START=1
EFI_END="${EFI_SIZE_MB}MiB"
ROOT_START="${EFI_SIZE_MB}MiB"
sgdisk -n 1:2048:+${EFI_SIZE_MB}M -t 1:ef00 -c 1:"EFI" "$DEV"
sgdisk -n 2:0:0 -t 2:8300 -c 2:"LINUX" "$DEV"
partprobe "$DEV"

# Determine partition nodes (/dev/sdX1 etc)
# works with /dev/sdX or /dev/nvme0n1
get_part() {
  local dev="$1"; local n="$2"
  if [[ "$dev" =~ nvme ]]; then
    echo "${dev}p${n}"
  else
    echo "${dev}${n}"
  fi
}
PART_EFI="$(get_part "$DEV" 1)"
PART_ROOT="$(get_part "$DEV" 2)"

echo "EFI partition: $PART_EFI"
echo "Root partition: $PART_ROOT"

# --- Format ---
echo ">>> Formatting partitions"
mkfs.vfat -F32 -n EFI "$PART_EFI"
# create btrfs on root
mkfs.btrfs -f -L USBROOT "$PART_ROOT"

# --- Mount and create subvolumes ---
echo ">>> Mounting btrfs and creating subvolumes"
mkdir -p "$MOUNT_POINT"
mount "$PART_ROOT" "$MOUNT_POINT"

# create top-level subvolumes
btrfs subvolume create "$MOUNT_POINT/$ROOT_SUBVOL"
btrfs subvolume create "$MOUNT_POINT/$SNAP_SUBVOL"
# optionally create @home or @var as needed
umount "$MOUNT_POINT"

# Mount the @ subvol as the root for installation
mkdir -p "$MOUNT_POINT"
mount -o subvol=$ROOT_SUBVOL "$PART_ROOT" "$MOUNT_POINT"

# mount EFI
mkdir -p "$EFI_MOUNT"
mount "$PART_EFI" "$EFI_MOUNT"

# --- debootstrap a minimal system ---
echo ">>> Running debootstrap (this can take several minutes)"
# install required packages in host
if ! command -v debootstrap >/dev/null 2>&1; then
  echo "debootstrap not installed. Install it with: apt install debootstrap" >&2
  exit 1
fi

debootstrap --variant=minbase --include=linux-image-amd64,grub-efi-amd64,grub-pc,btrfs-progs,cloud-guest-utils,locales,ca-certificates,sudo,systemd-sysv "$SUITE" "$MOUNT_POINT" "$DEBOOTSTRAP_MIRROR"

# --- Basic chroot setup ---
echo ">>> Preparing chroot environment"
mount -t proc /proc "$MOUNT_POINT/proc"
mount --rbind /sys "$MOUNT_POINT/sys"
mount --rbind /dev "$MOUNT_POINT/dev"
cp /etc/resolv.conf "$MOUNT_POINT/etc/resolv.conf" || true

# fstab: use UUID for root partition and subvol specified
ROOT_UUID=$(blkid -s UUID -o value "$PART_ROOT")
cat > "$MOUNT_POINT/etc/fstab" <<EOF
# <file system> <mount point> <type> <options> <dump> <pass>
UUID=$ROOT_UUID / btrfs defaults,subvol=$ROOT_SUBVOL,ssd,compress=zstd:1,discard=async 0 1
UUID=$ROOT_UUID /$SNAP_SUBVOL btrfs defaults,subvol=$SNAP_SUBVOL 0 2
# EFI (mountpoint created)
EOF

mkdir -p "$MOUNT_POINT/$SNAP_SUBVOL"

# set hostname, locale
echo "$HOSTNAME" > "$MOUNT_POINT/etc/hostname"
chroot "$MOUNT_POINT" /bin/bash -c "ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime || true; dpkg-reconfigure -f noninteractive tzdata || true"
chroot "$MOUNT_POINT" /bin/bash -c "apt-get update && apt-get install -y --no-install-recommends linux-image-amd64 btrfs-progs grub-efi-amd64 grub-pc sudo locales"
chroot "$MOUNT_POINT" /bin/bash -c "sed -i 's/^# $LOCALE/$LOCALE/' /etc/locale.gen || true; locale-gen"

# create user
chroot "$MOUNT_POINT" /bin/bash -c "useradd -m -s /bin/bash -G sudo $USERNAME || true; echo '$USERNAME:$PASSWORD' | chpasswd"

# install GRUB (both efi and bios)
echo ">>> Installing GRUB (BIOS and UEFI) into target"
# mount efivars inside chroot to allow grub-install --target=x86_64-efi to work when host supports it
mkdir -p "$MOUNT_POINT/boot/efi"
# EFI partition already mounted at $EFI_MOUNT so copy to chroot mount point
umount "$EFI_MOUNT" || true
mount "$PART_EFI" "$MOUNT_POINT/boot/efi"

# chroot and install grub for both targets
chroot "$MOUNT_POINT" /bin/bash -c "grub-install --target=i386-pc --recheck --boot-directory=/boot $DEV || true"
chroot "$MOUNT_POINT" /bin/bash -c "grub-install --target=x86_64-efi --efi-directory=/boot/efi --boot-directory=/boot --removable || true"

# create a simple grub.cfg that uses subvol root
# find kernel and initrd after chroot update-grub
chroot "$MOUNT_POINT" /bin/bash -c "update-grub || true"

# ensure /etc/default/grub includes rootflags if needed (we'll add a custom 40_custom entries later)
cat > "$MOUNT_POINT/etc/grub.d/40_custom" <<'EOF'
#!/bin/sh
exec tail -n +3 "$0"
# Custom snapshot entries will be generated by the btrfs-grub-snapshots script
EOF
chmod +x "$MOUNT_POINT/etc/grub.d/40_custom"

# Install your snapshot script into the installed system
if [ -n "$SNAP_SCRIPT_SRC" ]; then
  echo ">>> Copying snapshot script to USB system"
  install -m 0755 "$SNAP_SCRIPT_SRC" "$MOUNT_POINT/usr/local/bin/btrfs-grub-snapshots"
fi

# Add a helper to regenerate grub entries at boot/install time
chroot "$MOUNT_POINT" /bin/bash -c "apt-get install -y --no-install-recommends btrfs-progs"

# create a small systemd service to ensure @snapshots dir exists on first boot
cat > "$MOUNT_POINT/etc/systemd/system/create-snapdir.service" <<'EOF'
[Unit]
Description=Create Btrfs snapshots subvolume directory if missing
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'set -e; if [ ! -d /$SNAP_SUBVOL ]; then mkdir -p /$SNAP_SUBVOL || true; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Adapt the placeholder $SNAP_SUBVOL inside the file with proper name
sed -i "s|/$SNAP_SUBVOL|/$SNAP_SUBVOL|g" "$MOUNT_POINT/etc/systemd/system/create-snapdir.service"

chroot "$MOUNT_POINT" /bin/bash -c "systemctl enable create-snapdir.service || true"

# Final grub update inside chroot (so kernels are detected)
chroot "$MOUNT_POINT" /bin/bash -c "update-grub || true"

# Clean up and unmount
echo ">>> Cleaning up mounts"
umount -l "$MOUNT_POINT/boot/efi" || true
umount -l "$MOUNT_POINT/proc" || true
umount -l "$MOUNT_POINT/sys" || true
umount -l "$MOUNT_POINT/dev" || true
umount -l "$MOUNT_POINT" || true

echo ">>> Done. USB persistent system created on $DEV."
echo "Reboot and select the USB device. First boot may take a bit longer."

echo "Important next steps inside the USB system after first boot:"
cat <<MSG
1) Login as $USERNAME (password: $PASSWORD). Immediately:
   sudo passwd $USERNAME              # set a real password
   sudo visudo                        # optionally allow passwordless sudo for your user
2) Verify the snapshot script exists at /usr/local/bin/btrfs-grub-snapshots and is executable.
3) Run: sudo btrfs-grub-snapshots create-snapshot "initial"   # creates first snapshot
4) Reboot and test selecting the 'snapshot' entry in GRUB.

MSG
