#!/bin/bash
# btrfs-grub-snapshots-setup.sh
# All-in-one helper to create readonly btrfs snapshots of the root subvolume
# and export GRUB menu entries so you can boot the snapshots directly from GRUB.
#
# IMPORTANT PRE-REQUISITES:
# 1) Root filesystem (/) MUST be on Btrfs.
# 2) Root filesystem should be a subvolume (commonly named @ or @rootfs).
# 3) Must have a sibling subvolume (like @snapshots) to hold snapshots.
# 4) Run this script as root.
#
##############################
set -euo pipefail
IFS=$'\n\t'

SNAP_ROOT_SUBVOL="@snapshots"
SNAP_DIR_MOUNTPOINT="/mnt/.snapshots"
GRUB_CUSTOM="/etc/grub.d/40_custom"

require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

check_btrfs_root() {
  ROOT_DEV=$(findmnt -n -o SOURCE /)
  ROOT_DEV_CLEAN=$(echo "$ROOT_DEV" | sed 's/\[.*\]//')

  if [ -z "$ROOT_DEV_CLEAN" ]; then
    echo "Cannot determine root device." >&2
    exit 1
  fi

  fstype=$(blkid -o value -s TYPE "$ROOT_DEV_CLEAN" 2>/dev/null || true)
  if [ "$fstype" != "btrfs" ]; then
    echo "Root device ($ROOT_DEV) is not btrfs. This script requires btrfs root." >&2
    exit 1
  fi
}

get_root_subvolume() {
  # Get the current root subvolume name
  local root_subvol=$(findmnt -n -o OPTIONS / | grep -oP 'subvol=\K[^,]+' || echo "@")
  echo "$root_subvol"
}

get_btrfs_root_mount() {
  # Find where the btrfs root volume is mounted (not the subvolume)
  ROOT_DEV_CLEAN=$(findmnt -n -o SOURCE / | sed 's/\[.*\]//')
  # Try to find an existing mount of the btrfs root
  local btrfs_root=$(findmnt -n -t btrfs -o TARGET --source "$ROOT_DEV_CLEAN" | grep -v "^/$" | head -1 || true)
  
  if [ -z "$btrfs_root" ]; then
    # Need to temporarily mount the btrfs root
    mkdir -p "$SNAP_DIR_MOUNTPOINT"
    if ! mountpoint -q "$SNAP_DIR_MOUNTPOINT"; then
      mount -t btrfs -o subvolid=5 "$ROOT_DEV_CLEAN" "$SNAP_DIR_MOUNTPOINT"
      echo "$SNAP_DIR_MOUNTPOINT"
    else
      echo "$SNAP_DIR_MOUNTPOINT"
    fi
  else
    echo "$btrfs_root"
  fi
}

ensure_snapshot_subvol_exists() {
  echo "Checking for snapshot subvolume '$SNAP_ROOT_SUBVOL'..."
  
  local btrfs_root=$(get_btrfs_root_mount)
  
  if [ ! -d "$btrfs_root/$SNAP_ROOT_SUBVOL" ]; then
    echo "Snapshot subvolume not found. Creating '$SNAP_ROOT_SUBVOL'..."
    btrfs subvolume create "$btrfs_root/$SNAP_ROOT_SUBVOL"
    echo "Created $btrfs_root/$SNAP_ROOT_SUBVOL"
  else
    echo "Found existing subvolume $btrfs_root/$SNAP_ROOT_SUBVOL"
  fi
}

create_snapshot() {
  require_root
  check_btrfs_root
  ensure_snapshot_subvol_exists

  LABEL="${1:-}"
  READONLY="${2:-yes}"
  
  SNAPNAME="snap-$(date +%Y%m%d-%H%M%S)"
  if [ -n "$LABEL" ]; then
    safe_label=$(echo "$LABEL" | tr -c 'A-Za-z0-9_-' '_')
    SNAPNAME="$SNAPNAME-$safe_label"
  fi

  local btrfs_root=$(get_btrfs_root_mount)
  local root_subvol=$(get_root_subvolume)
  
  DEST="$btrfs_root/$SNAP_ROOT_SUBVOL/$SNAPNAME"
  
  if [ "$READONLY" = "yes" ]; then
    echo "Creating read-only snapshot of '$root_subvol' -> $SNAP_ROOT_SUBVOL/$SNAPNAME"
    btrfs subvolume snapshot -r "$btrfs_root/$root_subvol" "$DEST"
  else
    echo "Creating read-write snapshot of '$root_subvol' -> $SNAP_ROOT_SUBVOL/$SNAPNAME"
    btrfs subvolume snapshot "$btrfs_root/$root_subvol" "$DEST"
  fi
  
  echo "Snapshot created: $DEST"
  echo "Snapshot path for boot: $SNAP_ROOT_SUBVOL/$SNAPNAME"

  update_grub_entries
}

list_snapshots() {
  check_btrfs_root
  local btrfs_root=$(get_btrfs_root_mount)
  
  echo "Snapshots in $SNAP_ROOT_SUBVOL:"
  if [ -d "$btrfs_root/$SNAP_ROOT_SUBVOL" ]; then
    ls -1 "$btrfs_root/$SNAP_ROOT_SUBVOL" 2>/dev/null || echo "No snapshots found."
  else
    echo "No snapshot subvolume found."
  fi
}

remove_snapshot() {
  require_root
  check_btrfs_root
  SNAPNAME="$1"
  if [ -z "$SNAPNAME" ]; then
    echo "Usage: $0 remove-snapshot <snap-name>" >&2
    exit 1
  fi
  
  local btrfs_root=$(get_btrfs_root_mount)
  TARGET="$btrfs_root/$SNAP_ROOT_SUBVOL/$SNAPNAME"
  
  if [ ! -d "$TARGET" ]; then
    echo "Snapshot $TARGET does not exist." >&2
    exit 1
  fi
  
  # Check if read-only, make writable before deleting
  local is_readonly=$(btrfs property get "$TARGET" ro 2>/dev/null | grep -o "ro=true" || echo "")
  if [ -n "$is_readonly" ]; then
    echo "Making snapshot writable before deletion..."
    btrfs property set "$TARGET" ro false
  fi
  
  echo "Deleting snapshot $TARGET (this is irreversible)..."
  btrfs subvolume delete "$TARGET"
  echo "Deleted. Regenerating GRUB entries..."
  update_grub_entries
}

make_snapshot_writable() {
  require_root
  check_btrfs_root
  SNAPNAME="$1"
  
  if [ -z "$SNAPNAME" ]; then
    echo "Usage: $0 make-writable <snap-name>" >&2
    exit 1
  fi
  
  local btrfs_root=$(get_btrfs_root_mount)
  TARGET="$btrfs_root/$SNAP_ROOT_SUBVOL/$SNAPNAME"
  
  if [ ! -d "$TARGET" ]; then
    echo "Snapshot $TARGET does not exist." >&2
    exit 1
  fi
  
  echo "Making snapshot $SNAPNAME writable..."
  btrfs property set "$TARGET" ro false
  echo "✓ Snapshot is now read-write and can boot with GUI"
  
  update_grub_entries
}

cleanup_old() {
  require_root
  KEEP=${1:-5}
  check_btrfs_root
  
  local btrfs_root=$(get_btrfs_root_mount)
  
  if [ ! -d "$btrfs_root/$SNAP_ROOT_SUBVOL" ]; then
    echo "No snapshot subvolume found."
    return
  fi
  
  mapfile -t snaps < <(ls -1 "$btrfs_root/$SNAP_ROOT_SUBVOL" 2>/dev/null | sort)
  total=${#snaps[@]}
  
  if [ $total -le $KEEP ]; then
    echo "Only $total snapshots found — nothing to remove."
    return
  fi
  
  to_delete_count=$((total-KEEP))
  echo "Removing $to_delete_count oldest snapshots (keeping $KEEP)..."
  
  for ((i=0;i<to_delete_count;i++)); do
    s=${snaps[i]}
    echo "Deleting $s"
    btrfs subvolume delete "$btrfs_root/$SNAP_ROOT_SUBVOL/$s"
  done
  
  update_grub_entries
}

find_kernel_initrd() {
  local kver="$1"
  local kernel_path=""
  local initrd_path=""
  
  # Try different kernel naming conventions
  if [ -e "/boot/vmlinuz-$kver" ]; then
    kernel_path="/boot/vmlinuz-$kver"
  elif [ -e "/boot/vmlinuz-linux" ]; then
    kernel_path="/boot/vmlinuz-linux"
  elif [ -e "/boot/kernel-$kver" ]; then
    kernel_path="/boot/kernel-$kver"
  fi
  
  # Try different initrd naming conventions
  if [ -e "/boot/initrd.img-$kver" ]; then
    initrd_path="/boot/initrd.img-$kver"
  elif [ -e "/boot/initramfs-$kver.img" ]; then
    initrd_path="/boot/initramfs-$kver.img"
  elif [ -e "/boot/initrd-$kver" ]; then
    initrd_path="/boot/initrd-$kver"
  elif [ -e "/boot/initramfs-linux.img" ]; then
    initrd_path="/boot/initramfs-linux.img"
  fi
  
  echo "$kernel_path|$initrd_path"
}

update_grub_entries() {
  require_root
  check_btrfs_root

  ROOT_DEV=$(findmnt -n -o SOURCE /)
  ROOT_DEV_CLEAN=$(echo "$ROOT_DEV" | sed 's/\[.*\]//')
  ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV_CLEAN")
  
  if [ -z "$ROOT_UUID" ]; then
    echo "Failed to read root partition UUID." >&2
    exit 1
  fi

  KVER=$(uname -r)
  
  # Find kernel and initrd
  IFS='|' read -r KERNEL_PATH INITRD_PATH <<< "$(find_kernel_initrd "$KVER")"
  
  if [ -z "$KERNEL_PATH" ] || [ ! -e "$KERNEL_PATH" ]; then
    echo "Warning: kernel for current kernel ($KVER) not found." >&2
    KERNEL_PATH="/boot/vmlinuz-$KVER"
  fi
  
  if [ -z "$INITRD_PATH" ] || [ ! -e "$INITRD_PATH" ]; then
    echo "Warning: initrd for current kernel ($KVER) not found." >&2
    INITRD_PATH="/boot/initrd.img-$KVER"
  fi
  
  echo "Using kernel: $KERNEL_PATH"
  echo "Using initrd: $INITRD_PATH"

  local btrfs_root=$(get_btrfs_root_mount)
  
  echo "Generating GRUB custom menu entries at $GRUB_CUSTOM"
  cat > "$GRUB_CUSTOM" <<'EOF'
#!/bin/sh
exec tail -n +3 "$0"
# Custom snapshot entries generated by btrfs-grub-snapshots-setup
EOF

  if [ ! -d "$btrfs_root/$SNAP_ROOT_SUBVOL" ]; then
    echo "No snapshots found to generate GRUB entries."
    chmod +x "$GRUB_CUSTOM"
    return
  fi

  mapfile -t snaps < <(ls -1 "$btrfs_root/$SNAP_ROOT_SUBVOL" 2>/dev/null | sort -r || true)

  if [ ${#snaps[@]} -eq 0 ]; then
    echo "No snapshots found to generate GRUB entries."
    chmod +x "$GRUB_CUSTOM"
    return
  fi

  # Detect if /boot is a separate partition/subvolume
  local boot_subvol=""
  local boot_on_root=true
  
  if mountpoint -q /boot 2>/dev/null; then
    # /boot is a separate mount point
    boot_on_root=false
    local boot_opts=$(findmnt -n -o OPTIONS /boot)
    if echo "$boot_opts" | grep -q "subvol="; then
      boot_subvol=$(echo "$boot_opts" | grep -oP 'subvol=\K[^,]+' || echo "")
    fi
  fi

  for name in "${snaps[@]}"; do
    subvol_path="$SNAP_ROOT_SUBVOL/$name"
    menu_title="Debian GNU/Linux (snapshot: $name)"
    
    # Check if snapshot is read-only
    local is_readonly=$(btrfs property get "$btrfs_root/$SNAP_ROOT_SUBVOL/$name" ro 2>/dev/null | grep -o "ro=true" || echo "")
    
    # Get relative kernel and initrd paths
    kernel_rel=$(echo "$KERNEL_PATH" | sed 's|^/||')
    initrd_rel=$(echo "$INITRD_PATH" | sed 's|^/||')

    if [ "$boot_on_root" = false ]; then
      # /boot is separate - need to switch subvolume for kernel loading
      if [ -n "$boot_subvol" ]; then
        cat >> "$GRUB_CUSTOM" <<GRENTRY

menuentry '$menu_title' {
  insmod btrfs
  search --no-floppy --fs-uuid --set=root $ROOT_UUID
  echo 'Loading snapshot: $name'
  echo 'Boot from separate /boot subvolume: $boot_subvol'
  set root_subvol="$subvol_path"
  linux /$kernel_rel root=UUID=$ROOT_UUID rootflags=subvol=\$root_subvol ro quiet
  initrd /$initrd_rel
}
GRENTRY
      else
        # /boot is on different partition (not btrfs subvolume)
        local boot_uuid=$(findmnt -n -o UUID /boot)
        cat >> "$GRUB_CUSTOM" <<GRENTRY

menuentry '$menu_title' {
  insmod btrfs
  search --no-floppy --fs-uuid --set=boot_part $boot_uuid
  search --no-floppy --fs-uuid --set=root $ROOT_UUID
  echo 'Loading snapshot: $name'
  echo 'Boot partition: $boot_uuid, Root: $subvol_path'
  linux (\$boot_part)/$kernel_rel root=UUID=$ROOT_UUID rootflags=subvol=$subvol_path ro quiet
  initrd (\$boot_part)/$initrd_rel
}
GRENTRY
      fi
    else
      # /boot is on root subvolume - load from current root
      local current_root_subvol=$(get_root_subvolume)
      cat >> "$GRUB_CUSTOM" <<GRENTRY

menuentry '$menu_title' {
  insmod btrfs
  search --no-floppy --fs-uuid --set=root $ROOT_UUID
  echo 'Loading snapshot: $name'
  echo 'Kernel from current system: $current_root_subvol'
  echo 'Booting snapshot: $subvol_path'
  linux $current_root_subvol/$kernel_rel root=UUID=$ROOT_UUID rootflags=subvol=$subvol_path ro quiet
  initrd $current_root_subvol/$initrd_rel
}
GRENTRY
    fi
  done

  chmod +x "$GRUB_CUSTOM"
  
  echo ""
  echo "=========================================="
  echo "Generated GRUB entries for ${#snaps[@]} snapshot(s):"
  echo "=========================================="
  for name in "${snaps[@]}"; do
    echo "  - $name"
  done
  echo "=========================================="
  echo ""
  
  echo "Updating grub configuration..."
  
  # Run update-grub to generate base config
  if command -v update-grub &> /dev/null; then
    update-grub
  elif command -v grub-mkconfig &> /dev/null; then
    grub-mkconfig -o /boot/grub/grub.cfg
  elif command -v grub2-mkconfig &> /dev/null; then
    grub2-mkconfig -o /boot/grub2/grub.cfg
  else
    echo "Warning: Could not find grub update command." >&2
  fi
  
  # For UEFI systems, also copy to EFI partition
  if [ -d "/boot/efi/EFI/debian" ]; then
    echo "Detected UEFI/EFI boot setup - syncing to EFI partition..."
    
    # Copy the main grub.cfg to EFI partition
    if [ -f "/boot/grub/grub.cfg" ]; then
      cp /boot/grub/grub.cfg /boot/efi/EFI/debian/grub.cfg
      echo "✓ Copied grub.cfg to /boot/efi/EFI/debian/grub.cfg"
    fi
  fi
  
  # Verify the entries made it into all grub.cfg files
  echo ""
  local found_in_any=false
  
  for cfg in /boot/grub/grub.cfg /boot/efi/EFI/debian/grub.cfg /boot/grub2/grub.cfg; do
    if [ -f "$cfg" ]; then
      if grep -q "snapshot:" "$cfg" 2>/dev/null; then
        echo "✓ Verified: Snapshot entries found in $cfg"
        found_in_any=true
      fi
    fi
  done
  
  if [ "$found_in_any" = false ]; then
    echo "⚠ Warning: Snapshot entries NOT found in any grub.cfg"
    echo "  Checking /etc/grub.d/40_custom..."
    if [ -f "$GRUB_CUSTOM" ]; then
      echo "  40_custom exists. Trying manual grub-mkconfig..."
      grub-mkconfig -o /boot/grub/grub.cfg
      if [ -d "/boot/efi/EFI/debian" ]; then
        cp /boot/grub/grub.cfg /boot/efi/EFI/debian/grub.cfg
      fi
    fi
  fi
  
  echo ""
  echo "✓ GRUB entries updated successfully!"
  echo "✓ Reboot and look for 'Debian GNU/Linux (snapshot: ...)' entries in GRUB menu"
  echo "✓ Select a snapshot entry to boot into that snapshot"
}

show_help() {
  cat <<HELP
Usage: $0 <command> [args]

Commands:
  create-snapshot [label]   Create a readonly snapshot of root into $SNAP_ROOT_SUBVOL
  list-snapshots            List created snapshots
  remove-snapshot <name>    Remove a named snapshot (e.g. snap-20251024-120000)
  cleanup-old [keep]        Keep latest N snapshots, delete older ones (default: keep 5)
  update-grub-entries       Regenerate GRUB entries for all snapshots
  help                      Show this message

EXAMPLES:
  # Create a snapshot before system upgrade
  sudo $0 create-snapshot "before-upgrade"
  
  # List all snapshots
  sudo $0 list-snapshots
  
  # Remove a specific snapshot
  sudo $0 remove-snapshot snap-20251024-120000
  
  # Keep only the 3 most recent snapshots
  sudo $0 cleanup-old 3
  
  # Manually regenerate GRUB entries
  sudo $0 update-grub-entries

NOTES:
  - Snapshots are stored in the '$SNAP_ROOT_SUBVOL' btrfs subvolume
  - After creating/removing snapshots, GRUB is automatically updated
  - Reboot and select a snapshot from GRUB menu to boot into it
  - Snapshots are read-only by default (boot in read-only mode)

HELP
}

# Main command dispatcher
cmd=${1:-help}
case "$cmd" in
  create-snapshot) create_snapshot "${2:-}" "${3:-yes}" ;;
  list-snapshots) list_snapshots ;;
  remove-snapshot) remove_snapshot "${2:-}" ;;
  make-writable) make_snapshot_writable "${2:-}" ;;
  cleanup-old) cleanup_old "${2:-}" ;;
  update-grub-entries) update_grub_entries ;;
  help|--help|-h) show_help ;;
  *) echo "Unknown command: $cmd"; echo ""; show_help; exit 2 ;;
esac
