#!/usr/bin/env python3
"""
Production-Ready Btrfs Persistent USB Creator
Creates a fully persistent, portable Linux USB with Btrfs snapshots
Supports cross-computer session persistence and recovery
"""
import os
import subprocess
import sys
import shutil
import time
import stat
import signal

# Mount points
ISO_MOUNT = "/mnt/iso_temp"
USB_BOOT = "/mnt/usb_boot"
USB_PERSIST = "/mnt/usb_persist"
ESP_MOUNT = "/mnt/esp_temp"

# Partition sizes
BOOT_SIZE_GB = 4
ESP_SIZE_MB = 512

# Timeout for operations
MOUNT_TIMEOUT = 10
SYNC_TIMEOUT = 30


class TimeoutError(Exception):
    pass


def timeout_handler(signum, frame):
    raise TimeoutError("Operation timed out")


def run_cmd(cmd, check=True, capture=False, ignore_error=False, shell=True, timeout=None):
    """Run shell command safely with better error handling."""
    print(f">> {cmd}")
    try:
        if capture:
            result = subprocess.check_output(
                cmd, shell=shell, text=True, stderr=subprocess.PIPE,
                timeout=timeout
            )
            return result.strip()
        
        result = subprocess.run(
            cmd, shell=shell, check=check,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            timeout=timeout
        )
        
        if result.stdout:
            print(result.stdout)
        if result.stderr and not ignore_error:
            print(result.stderr)
            
        return True
    except subprocess.TimeoutExpired:
        print(f"⚠️  Command timed out: {cmd}")
        return None if ignore_error else False
    except subprocess.CalledProcessError as e:
        if ignore_error:
            print(f"⚠️  Ignored error: {cmd}")
            if e.stderr:
                print(f"   Details: {e.stderr}")
            return None
        print(f"❌ Command failed: {cmd}")
        print(f"💡 Error: {e.stderr if e.stderr else str(e)}")
        return False
    except Exception as e:
        print(f"❌ Unexpected error: {e}")
        return False


def check_root():
    """Verify script is running as root."""
    if os.geteuid() != 0:
        print("❌ This script must be run as root (use sudo)")
        sys.exit(1)


def check_requirements():
    """Ensure required tools exist."""
    print("\n🔍 Checking system requirements...\n")
    required = {
        "parted": "parted",
        "mkfs.vfat": "dosfstools",
        "mkfs.btrfs": "btrfs-progs",
        "btrfs": "btrfs-progs",
        "rsync": "rsync",
        "grub-install": "grub2-common grub-efi-amd64-bin grub-pc-bin",
        "mount": "mount",
        "lsblk": "util-linux",
        "blockdev": "util-linux",
    }
    
    missing = []
    missing_packages = []
    for tool, package in required.items():
        if shutil.which(tool) is None:
            print(f"⚠️  Missing: {tool} (package: {package})")
            missing.append(tool)
            missing_packages.extend(package.split())
    
    if missing:
        print(f"\n📦 Installing missing packages...")
        packages = ' '.join(set(missing_packages))
        run_cmd("apt-get update -qq", ignore_error=True, timeout=120)
        run_cmd(f"apt-get install -y {packages}", timeout=300)
        
        if shutil.which("mkfs.btrfs") is None:
            print("❌ Failed to install btrfs-progs. Please install manually:")
            print("   sudo apt-get install btrfs-progs")
            sys.exit(1)
    else:
        print("✅ All required tools are installed")


def is_mounted(path):
    """Check if mount point is currently mounted."""
    try:
        result = subprocess.run(
            ["mountpoint", "-q", path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5
        )
        return result.returncode == 0
    except:
        try:
            result = subprocess.run(
                f"mount | grep -q ' {path} '",
                shell=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=5
            )
            return result.returncode == 0
        except:
            return False


def force_unmount(path, max_attempts=3):
    """Forcefully unmount a path with retries."""
    if not os.path.exists(path):
        return True
        
    for attempt in range(max_attempts):
        if not is_mounted(path):
            return True
        
        print(f"   Unmounting {path} (attempt {attempt + 1}/{max_attempts})")
        
        # Try to kill processes using the mount
        if attempt > 0:
            run_cmd(f"fuser -km {path} 2>/dev/null", check=False, ignore_error=True, timeout=5)
            time.sleep(0.5)
        
        # Try normal unmount first
        result = run_cmd(f"umount {path} 2>/dev/null", check=False, ignore_error=True, timeout=10)
        time.sleep(0.5)
        
        if not is_mounted(path):
            print(f"   ✓ Unmounted {path}")
            return True
        
        # Try lazy unmount on last attempt
        if attempt == max_attempts - 1:
            print(f"   Using lazy unmount for {path}")
            run_cmd(f"umount -l {path} 2>/dev/null", check=False, ignore_error=True, timeout=5)
            time.sleep(1)
    
    # Final check
    if not is_mounted(path):
        return True
    
    print(f"⚠️  Warning: Could not fully unmount {path}")
    return False


def unmount_all(device):
    """Safely unmount all device partitions and mount points."""
    print(f"\n🔍 Unmounting all partitions on {device}...\n")
    
    # Kill any processes using these mount points
    all_mounts = [ISO_MOUNT, USB_BOOT, USB_PERSIST, ESP_MOUNT, 
                  "/mnt/iso", "/mnt/usb", "/mnt/esp"]
    
    for mount in all_mounts:
        if os.path.exists(mount):
            run_cmd(f"fuser -km {mount} 2>/dev/null", check=False, ignore_error=True, timeout=5)
    
    time.sleep(1)
    
    # Unmount all our known mount points
    for mount_point in all_mounts:
        if os.path.exists(mount_point):
            force_unmount(mount_point)
    
    # Unmount all device partitions
    try:
        partitions = run_cmd(
            f"lsblk -ln -o NAME {device} 2>/dev/null | tail -n +2",
            capture=True, ignore_error=True, timeout=10
        )
        if partitions:
            for part in partitions.split('\n'):
                if part.strip():
                    part_path = f"/dev/{part.strip()}"
                    run_cmd(f"umount -l {part_path} 2>/dev/null", 
                           check=False, ignore_error=True, timeout=5)
    except:
        pass
    
    # Final sweep with lazy unmount
    run_cmd(f"umount -l {device}* 2>/dev/null", check=False, ignore_error=True, timeout=5)
    
    print("✓ Unmount complete\n")
    time.sleep(1)


def prepare_mount_points():
    """Ensure mount directories exist."""
    for path in [ISO_MOUNT, USB_BOOT, USB_PERSIST, ESP_MOUNT]:
        try:
            os.makedirs(path, exist_ok=True)
            os.chmod(path, 0o755)
        except Exception as e:
            print(f"⚠️  Could not create {path}: {e}")


def get_partition_names(device):
    """Determine correct partition naming scheme."""
    base_name = os.path.basename(device)
    if base_name.startswith(('mmcblk', 'nvme', 'loop')):
        return f"{device}p1", f"{device}p2", f"{device}p3"
    else:
        return f"{device}1", f"{device}2", f"{device}3"


def wait_for_partitions(device, timeout=15):
    """Wait for partition devices to appear."""
    print("⏳ Waiting for kernel to recognize new partitions...")
    
    run_cmd(f"partprobe {device} 2>/dev/null", ignore_error=True, timeout=10)
    run_cmd(f"blockdev --rereadpt {device} 2>/dev/null", ignore_error=True, timeout=10)
    
    part1, part2, part3 = get_partition_names(device)
    
    for i in range(timeout):
        if os.path.exists(part1) and os.path.exists(part2) and os.path.exists(part3):
            print(f"✅ Partitions detected: {part1}, {part2}, {part3}")
            time.sleep(2)
            return True
        time.sleep(1)
        if i % 3 == 0:
            run_cmd(f"partprobe {device} 2>/dev/null", ignore_error=True, timeout=5)
    
    print("⚠️  Partition detection timeout, continuing anyway...")
    return os.path.exists(part1) and os.path.exists(part2)


def create_partitions(device):
    """Create GPT partitions: ESP (512MB) + Boot (4GB FAT32) + Persistence (rest, Btrfs)."""
    print(f"\n💽 Creating partition layout on {device}...\n")
    
    # Wipe existing data
    print("🧹 Wiping existing partition signatures...")
    run_cmd(f"wipefs -af {device} 2>/dev/null", ignore_error=True, timeout=15)
    run_cmd(f"dd if=/dev/zero of={device} bs=1M count=10 conv=notrunc 2>/dev/null", 
           ignore_error=True, timeout=15)
    time.sleep(2)
    
    # Create GPT partition table
    print("📝 Creating GPT partition table...")
    run_cmd(f"parted -s {device} mklabel gpt", timeout=20)
    
    # Partition 1: EFI System Partition (ESP) - 512MB
    print("📝 Creating EFI System Partition (512MB)...")
    run_cmd(f"parted -s -a optimal {device} mkpart primary fat32 1MiB {ESP_SIZE_MB}MiB", timeout=20)
    run_cmd(f"parted -s {device} set 1 esp on", timeout=10)
    
    # Partition 2: Boot partition (FAT32, 4GB)
    boot_end = ESP_SIZE_MB + (BOOT_SIZE_GB * 1024)
    print(f"📝 Creating boot partition ({BOOT_SIZE_GB}GB FAT32)...")
    run_cmd(f"parted -s -a optimal {device} mkpart primary fat32 {ESP_SIZE_MB}MiB {boot_end}MiB", timeout=20)
    run_cmd(f"parted -s {device} set 2 boot on", timeout=10)
    
    # Partition 3: Btrfs persistence
    print("📝 Creating Btrfs persistence partition (remaining space)...")
    run_cmd(f"parted -s -a optimal {device} mkpart primary btrfs {boot_end}MiB 100%", timeout=20)
    
    if not wait_for_partitions(device):
        print("⚠️  Warning: Partitions may not be ready")
    
    part1, part2, part3 = get_partition_names(device)
    
    # Format partitions
    print(f"\n💾 Formatting partitions...")
    
    print(f"   Formatting {part1} as FAT32 (ESP)...")
    run_cmd(f"umount {part1} 2>/dev/null", check=False, ignore_error=True, timeout=5)
    time.sleep(1)
    run_cmd(f"mkfs.vfat -F 32 -n EFI {part1}", timeout=30)
    
    print(f"   Formatting {part2} as FAT32 (BOOT)...")
    run_cmd(f"umount {part2} 2>/dev/null", check=False, ignore_error=True, timeout=5)
    time.sleep(1)
    run_cmd(f"mkfs.vfat -F 32 -n BOOT {part2}", timeout=30)
    
    print(f"   Formatting {part3} as Btrfs (PERSISTENCE)...")
    run_cmd(f"umount {part3} 2>/dev/null", check=False, ignore_error=True, timeout=5)
    time.sleep(1)
    run_cmd(f"mkfs.btrfs -f -L persistence -m single -d single {part3}", timeout=60)
    
    print("✅ Partitioning complete!\n")
    time.sleep(2)


def setup_btrfs_subvolumes(device):
    """Create Btrfs subvolumes for better snapshot management."""
    print("\n🌳 Setting up Btrfs subvolumes...\n")
    
    _, _, part3 = get_partition_names(device)
    
    prepare_mount_points()
    force_unmount(USB_PERSIST)
    time.sleep(1)
    
    # Mount Btrfs partition
    print(f"⚙️  Mounting Btrfs partition: {part3}")
    if not run_cmd(f"mount -o compress=zstd,noatime {part3} {USB_PERSIST}", timeout=15):
        print("⚠️  Failed to mount Btrfs partition, skipping subvolumes")
        return False
    
    # Create subvolumes
    print("📁 Creating Btrfs subvolumes...")
    subvolumes = ["@rootfs", "@home", "@snapshots", "@work"]
    
    for subvol in subvolumes:
        run_cmd(f"btrfs subvolume create {USB_PERSIST}/{subvol}", 
               ignore_error=True, timeout=15)
    
    # Create structure
    try:
        os.makedirs(f"{USB_PERSIST}/@rootfs/upper", exist_ok=True)
        os.makedirs(f"{USB_PERSIST}/@rootfs/work", exist_ok=True)
        os.makedirs(f"{USB_PERSIST}/@home/user", exist_ok=True)
    except Exception as e:
        print(f"⚠️  Could not create directories: {e}")
    
    print("✅ Btrfs subvolumes created!")
    
    force_unmount(USB_PERSIST)
    return True


def copy_iso_contents(iso_path, device):
    """Mount ISO and copy its contents to USB boot partition."""
    print("\n📀 Copying ISO contents to USB...\n")
    
    prepare_mount_points()
    _, part2, _ = get_partition_names(device)
    
    # Mount ISO
    print(f"⚙️  Mounting ISO: {iso_path}")
    force_unmount(ISO_MOUNT)
    
    if not run_cmd(f"mount -o loop,ro {iso_path} {ISO_MOUNT}", timeout=15):
        print("❌ Failed to mount ISO!")
        return False
    
    # Mount USB boot partition
    print(f"⚙️  Mounting USB boot partition: {part2}")
    force_unmount(USB_BOOT)
    time.sleep(1)
    
    if not run_cmd(f"mount {part2} {USB_BOOT}", timeout=15):
        print("❌ Failed to mount USB boot partition!")
        force_unmount(ISO_MOUNT)
        return False
    
    print("\n📋 Copying ISO files (this may take 5-15 minutes)...")
    print("    Progress updates will appear below...\n")
    
    # Copy with rsync - no timeout as this can take a while
    rsync_cmd = (
        "rsync -avh --no-perms --no-owner --no-group "
        "--modify-window=1 "
        "--exclude='lost+found' "
        "--info=progress2 "
        f"{ISO_MOUNT}/ {USB_BOOT}/ 2>&1"
    )
    
    run_cmd(rsync_cmd, check=False)
    
    print("\n⏳ Syncing filesystem (this may take 30 seconds)...")
    # Don't use run_cmd for sync as it has no output
    subprocess.run("sync", shell=True, timeout=SYNC_TIMEOUT)
    print("✓ Sync complete")
    time.sleep(2)
    
    force_unmount(USB_BOOT)
    force_unmount(ISO_MOUNT)
    
    print("✅ ISO contents copied!")
    return True


def configure_persistence(device):
    """Configure advanced Btrfs-based persistence."""
    print("\n⚙️  Configuring persistence system...\n")
    
    _, part2, _ = get_partition_names(device)
    
    force_unmount(USB_BOOT)
    time.sleep(1)
    
    if not run_cmd(f"mount {part2} {USB_BOOT}", timeout=15):
        print("❌ Failed to mount boot partition!")
        return False
    
    # Create persistence configuration
    print("📝 Creating persistence.conf...")
    persistence_conf = os.path.join(USB_BOOT, "persistence.conf")
    try:
        with open(persistence_conf, "w") as f:
            f.write("/ union\n")
        print(f"✅ Created: {persistence_conf}")
    except Exception as e:
        print(f"⚠️  Warning: Could not create persistence.conf: {e}")
    
    # Modify boot configuration if exists
    boot_params = "persistence persistence-storage=btrfs,ext4"
    
    grub_cfg = os.path.join(USB_BOOT, "boot/grub/grub.cfg")
    if os.path.exists(grub_cfg):
        print("📝 Updating GRUB configuration...")
        try:
            with open(grub_cfg, 'r') as f:
                grub_content = f.read()
            
            if 'persistence' not in grub_content:
                grub_content = grub_content.replace(
                    'boot=live',
                    f'boot=live {boot_params}'
                )
                with open(grub_cfg, 'w') as f:
                    f.write(grub_content)
                print("✅ GRUB config updated")
        except Exception as e:
            print(f"⚠️  Could not modify GRUB config: {e}")
    
    subprocess.run("sync", shell=True, timeout=SYNC_TIMEOUT)
    time.sleep(1)
    
    force_unmount(USB_BOOT)
    
    print("✅ Persistence configured!")
    return True


def install_bootloader(device):
    """Install GRUB bootloader for both UEFI and BIOS."""
    print("\n🚀 Installing bootloader...\n")
    
    part1, part2, _ = get_partition_names(device)
    
    force_unmount(USB_BOOT)
    time.sleep(1)
    
    if not run_cmd(f"mount {part2} {USB_BOOT}", timeout=15):
        print("⚠️  Could not mount boot partition")
        return False
    
    # Install GRUB for BIOS
    print("📀 Installing GRUB for BIOS/Legacy boot...")
    grub_install_cmd = f"grub-install --target=i386-pc --boot-directory={USB_BOOT}/boot {device}"
    result = run_cmd(grub_install_cmd, check=False, ignore_error=True, timeout=60)
    
    if result:
        print("✅ GRUB installed for BIOS boot")
    else:
        print("⚠️  GRUB BIOS installation had issues (may still work)")
    
    # Install GRUB for UEFI
    prepare_mount_points()
    force_unmount(ESP_MOUNT)
    
    if run_cmd(f"mount {part1} {ESP_MOUNT}", check=False, ignore_error=True, timeout=15):
        print("📀 Installing GRUB for UEFI boot...")
        
        grub_efi_cmd = (
            f"grub-install --target=x86_64-efi --efi-directory={ESP_MOUNT} "
            f"--boot-directory={USB_BOOT}/boot --removable --recheck {device}"
        )
        result = run_cmd(grub_efi_cmd, check=False, ignore_error=True, timeout=60)
        
        if result:
            print("✅ GRUB installed for UEFI boot")
        else:
            print("⚠️  GRUB UEFI installation had issues")
        
        force_unmount(ESP_MOUNT)
    else:
        print("⚠️  Could not install UEFI bootloader")
    
    force_unmount(USB_BOOT)
    
    print("✅ Bootloader installation complete!")
    return True


def create_readme(device):
    """Create README file with usage instructions."""
    _, part2, _ = get_partition_names(device)
    
    force_unmount(USB_BOOT)
    
    if run_cmd(f"mount {part2} {USB_BOOT}", check=False, ignore_error=True, timeout=15):
        readme_path = os.path.join(USB_BOOT, "README.txt")
        try:
            with open(readme_path, "w") as f:
                f.write("""
═══════════════════════════════════════════════════════════
  BTRFS PERSISTENT USB - PORTABLE LINUX SYSTEM
═══════════════════════════════════════════════════════════

🎯 WHAT IS THIS?
This USB contains a fully persistent Debian/Ubuntu system
that saves all changes, files, and settings automatically.

🚀 HOW TO USE:
1. Boot from this USB on any computer (UEFI or BIOS)
2. Select "Live with Persistence" from boot menu
3. Use normally - all changes are saved automatically
4. Shut down and take USB with you
5. Boot on another computer - your session continues!

💾 PARTITION LAYOUT:
- Partition 1: EFI System (512MB) - UEFI boot
- Partition 2: Boot (4GB FAT32) - OS files + BIOS boot  
- Partition 3: Persistence (rest) - Btrfs with snapshots

🌳 BTRFS FEATURES:
- Automatic compression (zstd) for space saving
- Snapshot capability for backups
- Better data integrity

📁 YOUR DATA:
All changes persist across reboots:
- Installed packages
- User files and documents
- System settings
- Everything!

💡 TIPS:
- First boot may take longer (system initialization)
- Install software normally with apt-get
- Create snapshots before major changes

⚠️  SAFETY:
- Don't remove USB while system is running
- Use "Shut Down" properly before unplugging

═══════════════════════════════════════════════════════════
""")
            print("✅ Created README.txt")
        except Exception as e:
            print(f"⚠️  Could not create README: {e}")
        
        force_unmount(USB_BOOT)


def validate_device(device):
    """Validate that device exists and is a block device."""
    if not os.path.exists(device):
        print(f"❌ Device not found: {device}")
        return False
    
    try:
        mode = os.stat(device).st_mode
        if not stat.S_ISBLK(mode):
            print(f"❌ Not a block device: {device}")
            return False
    except Exception as e:
        print(f"❌ Cannot validate device: {e}")
        return False
    
    # Safety check
    try:
        lsblk_output = run_cmd(
            f"lsblk -ln -o NAME,MOUNTPOINT {device}",
            capture=True,
            ignore_error=True,
            timeout=10
        )
        
        if lsblk_output:
            critical_mounts = ['/', '/boot', '/boot/efi', '/home', '/usr', '/var']
            
            for line in lsblk_output.split('\n'):
                parts = line.split()
                if len(parts) >= 2:
                    mountpoint = parts[1]
                    if mountpoint in critical_mounts:
                        print(f"❌ Safety check: {device} mounted at {mountpoint}")
                        print(f"   This is your system disk!")
                        return False
    except Exception as e:
        print(f"⚠️  Could not verify device safety: {e}")
    
    return True


def validate_iso(iso_path):
    """Validate ISO file exists and appears valid."""
    if not os.path.exists(iso_path):
        print(f"❌ ISO file not found: {iso_path}")
        return False
    
    if not os.path.isfile(iso_path):
        print(f"❌ Not a regular file: {iso_path}")
        return False
    
    size_mb = os.path.getsize(iso_path) / (1024 * 1024)
    if size_mb < 100:
        print(f"⚠️  Warning: ISO file seems small ({size_mb:.1f} MB)")
    
    print(f"📀 ISO size: {size_mb:.1f} MB")
    return True


def show_device_info(device):
    """Display information about target device."""
    print(f"\n📊 Device information for {device}:")
    print("─" * 60)
    
    try:
        size_bytes = run_cmd(f"blockdev --getsize64 {device}", capture=True, timeout=10)
        if size_bytes:
            size_gb = int(size_bytes) / (1024**3)
            print(f"   Size: {size_gb:.2f} GB")
    except:
        pass
    
    try:
        parts = run_cmd(f"lsblk -o NAME,SIZE,TYPE,MOUNTPOINT {device}", 
                       capture=True, timeout=10)
        if parts:
            print(f"\n   Current layout:")
            print("   " + "\n   ".join(parts.split('\n')))
    except:
        pass
    
    print("─" * 60)


def main():
    """Main execution flow."""
    print("=" * 70)
    print("  🌳 Production-Ready Btrfs Persistent USB Creator")
    print("  Portable Linux System with Full Session Persistence")
    print("=" * 70)
    
    if len(sys.argv) != 3:
        print("\n📖 Usage: sudo ./persistent_usb.py <path-to-iso> <target-device>")
        print("\n📚 Examples:")
        print("   sudo ./persistent_usb.py debian-13.1.0-amd64-netinst.iso /dev/sdb")
        print("   sudo ./persistent_usb.py ubuntu-22.04-desktop-amd64.iso /dev/sdc")
        print("\n🌟 Features:")
        print("   ✓ Btrfs filesystem with compression")
        print("   ✓ Full session persistence")
        print("   ✓ Works on any computer (plug & play)")
        print("   ✓ Both UEFI and BIOS support")
        print("   ✓ No hanging - proper timeouts")
        sys.exit(1)
    
    iso_path, device = sys.argv[1], sys.argv[2]
    
    check_root()
    
    if not validate_iso(iso_path):
        sys.exit(1)
    
    if not validate_device(device):
        sys.exit(1)
    
    show_device_info(device)
    
    print(f"\n⚠️  WARNING: This will PERMANENTLY ERASE all data on {device}")
    print(f"\n💾 Target: {device}")
    print(f"📀 Source: {iso_path}")
    print(f"\n❓ Type 'YES' to continue: ", end="")
    
    if input().strip() != "YES":
        print("❌ Operation cancelled")
        sys.exit(0)
    
    print("\n" + "=" * 70)
    print("  🚀 Starting USB creation...")
    print("=" * 70)
    
    try:
        check_requirements()
        unmount_all(device)
        create_partitions(device)
        setup_btrfs_subvolumes(device)
        
        if not copy_iso_contents(iso_path, device):
            raise Exception("Failed to copy ISO")
        
        if not configure_persistence(device):
            raise Exception("Failed to configure persistence")
        
        install_bootloader(device)
        create_readme(device)
        
        print("\n🧹 Final cleanup...")
        unmount_all(device)
        subprocess.run("sync", shell=True, timeout=SYNC_TIMEOUT)
        
        print("\n" + "=" * 70)
        print("  ✅ SUCCESS! Persistent USB Created!")
        print("=" * 70)
        print(f"\n📀 Your portable Linux system is ready on {device}")
        print("\n💡 How to use:")
        print("   1. Boot from USB")
        print("   2. Select 'Live with Persistence'")
        print("   3. All changes save automatically")
        print("\n📖 Check README.txt on USB for details")
        print("\n✅ Safe to remove USB now")
        
    except KeyboardInterrupt:
        print("\n\n❌ Cancelled by user")
        unmount_all(device)
        sys.exit(1)
    except Exception as e:
        print(f"\n\n❌ Error: {e}")
        print("\n🧹 Cleaning up...")
        unmount_all(device)
        sys.exit(1)


if __name__ == "__main__":
    main()