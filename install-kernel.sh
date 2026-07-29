#!/usr/bin/env bash
# ============================================================================
# KosmOs Kernel Install Script — Run this ON the Raspberry Pi 5
# ============================================================================
# This script takes the kernel package built in your VM and installs it
# onto the Pi's SD card. It's non-destructive: it backs up your existing
# kernel so you can always revert if something goes wrong.
#
# WHAT GETS INSTALLED WHERE:
#
#   Pi 5 Boot Partition Layout (/boot/firmware/):
#   ├── config.txt          ← Bootloader config (we modify this)
#   ├── kernel_2712.img     ← Stock Pi 5 kernel (we DON'T touch this)
#   ├── kernel-kosmos.img  ← OUR custom kernel (added)
#   ├── bcm2712*.dtb        ← Device tree blobs (we update these)
#   └── overlays/           ← Hardware overlay fragments (we update these)
#
#   Module Directory (/lib/modules/):
#   ├── 6.x.y-v8+/         ← Stock kernel modules (untouched)
#   └── 6.x.y-kosmos+/    ← OUR kernel modules (added)
#
# THE SAFETY NET:
#   We don't overwrite the stock kernel. Instead, we add ours alongside it
#   and tell config.txt to use it. If our kernel fails to boot, you can:
#     1. Pull the SD card
#     2. Mount the boot partition on another computer
#     3. Edit config.txt to remove the "kernel=" line
#     4. The Pi reverts to the stock kernel
#
#   This is like having a backup config on a network device — if your new
#   config breaks connectivity, you reload the saved one.
# ============================================================================

set -euo pipefail

# Color output for readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# === Sanity Checks ===
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  KosmOs Kernel Installer for Pi 5${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""

# Must run as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: Run this script with sudo${NC}"
    echo "  sudo bash install-kernel.sh"
    exit 1
fi

# Check we're on a Pi
if ! grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null && \
   ! grep -q "BCM2712" /proc/cpuinfo 2>/dev/null; then
    echo -e "${YELLOW}WARNING: This doesn't look like a Raspberry Pi.${NC}"
    read -p "Continue anyway? (y/N): " confirm
    [ "$confirm" = "y" ] || exit 1
fi

# Determine where we were extracted
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "Package directory: $SCRIPT_DIR"

# Check required files exist
if [ ! -f "$SCRIPT_DIR/boot/kernel-kosmos.img" ]; then
    echo -e "${RED}ERROR: kernel-kosmos.img not found in $SCRIPT_DIR/boot/${NC}"
    echo "       Make sure you extracted the tarball correctly:"
    echo "       mkdir ~/kosmos-kernel && tar xzf kosmos-kernel-*.tar.gz -C ~/kosmos-kernel"
    exit 1
fi

KERNEL_VERSION=$(cat "$SCRIPT_DIR/kernel-version" 2>/dev/null || echo "unknown")
echo "Kernel version:   $KERNEL_VERSION"
echo ""

# === Pi 5 Boot Partition ===
# On Pi OS, the boot partition is mounted at /boot/firmware/
# Older Pi OS versions used /boot/ — we detect which one.
BOOT_DIR="/boot/firmware"
if [ ! -d "$BOOT_DIR" ]; then
    BOOT_DIR="/boot"
fi

if [ ! -f "$BOOT_DIR/config.txt" ]; then
    echo -e "${RED}ERROR: Cannot find config.txt in $BOOT_DIR${NC}"
    echo "       Is this a standard Raspberry Pi OS installation?"
    exit 1
fi

echo "Boot partition:   $BOOT_DIR"
echo ""

# === Step 1: Backup Current Kernel ===
# Like 'copy running-config startup-config' — save what works before changing
BACKUP_DIR="$BOOT_DIR/backup-$(date +%Y%m%d-%H%M%S)"
echo -e "${YELLOW}[1/5] Backing up current kernel...${NC}"
mkdir -p "$BACKUP_DIR"
cp "$BOOT_DIR/config.txt" "$BACKUP_DIR/"

# Back up the current kernel image
# Pi 5 uses kernel_2712.img by default
if [ -f "$BOOT_DIR/kernel_2712.img" ]; then
    cp "$BOOT_DIR/kernel_2712.img" "$BACKUP_DIR/"
    echo "       Backed up kernel_2712.img"
fi

echo "       Backup saved to: $BACKUP_DIR"

# === Step 2: Install Kernel Image ===
echo ""
echo -e "${YELLOW}[2/5] Installing kernel image...${NC}"
cp "$SCRIPT_DIR/boot/kernel-kosmos.img" "$BOOT_DIR/"
echo "       Installed kernel-kosmos.img to $BOOT_DIR/"

# === Step 3: Install Device Tree Blobs ===
# DTBs tell the kernel where every piece of hardware lives in memory.
# Without the matching DTB, the kernel boots but can't find anything.
# It's like a switch booting without its VLAN database — it runs, but
# no interfaces are assigned and nothing works.
echo ""
echo -e "${YELLOW}[3/5] Installing device tree blobs...${NC}"

# Back up existing DTBs first
if ls "$BOOT_DIR"/bcm2712*.dtb 1>/dev/null 2>&1; then
    cp "$BOOT_DIR"/bcm2712*.dtb "$BACKUP_DIR/"
fi

cp "$SCRIPT_DIR/boot/bcm2712"*.dtb "$BOOT_DIR/"
echo "       Installed bcm2712 device tree blobs"

# Install overlays
if [ -d "$SCRIPT_DIR/boot/overlays" ]; then
    cp "$SCRIPT_DIR/boot/overlays/"*.dtbo "$BOOT_DIR/overlays/" 2>/dev/null || true
    echo "       Installed device tree overlays"
fi

# === Step 4: Install Kernel Modules ===
# Modules go under /lib/modules/<kernel-version>/
# Each kernel version has its own directory — they don't conflict.
echo ""
echo -e "${YELLOW}[4/5] Installing kernel modules...${NC}"
cp -r "$SCRIPT_DIR/modules/lib/modules/"* /lib/modules/
echo "       Installed modules to /lib/modules/$KERNEL_VERSION"

# Generate module dependency map
# depmod scans all .ko files and builds a dependency graph so the kernel
# knows "if you load module A, you also need modules B and C."
# Like building a package dependency tree in apt.
depmod "$KERNEL_VERSION"
echo "       Generated module dependency map"

# === Step 5: Update config.txt ===
# config.txt is the Pi bootloader's configuration file. It's the
# equivalent of a bootloader config (GRUB's grub.cfg) but way simpler.
# The 'kernel=' line tells the bootloader which file to load as the kernel.
echo ""
echo -e "${YELLOW}[5/5] Updating boot configuration...${NC}"

# Check if we've already added our kernel to config.txt
if grep -q "kernel=kernel-kosmos.img" "$BOOT_DIR/config.txt"; then
    echo "       config.txt already points to kosmos kernel"
else
    # Add our kernel directive
    # We put it in a [pi5] section so it only applies to Pi 5 hardware.
    # Other Pi models would use the default kernel.
    # This is like a conditional config: "if hardware == Pi5, use this kernel"

    # Check if [pi5] section exists
    if grep -q "^\[pi5\]" "$BOOT_DIR/config.txt"; then
        # Add our kernel line after the [pi5] section header
        sed -i '/^\[pi5\]/a kernel=kernel-kosmos.img' "$BOOT_DIR/config.txt"
    else
        # Create a [pi5] section with our kernel
        cat >> "$BOOT_DIR/config.txt" <<EOF

# KosmOs custom kernel
[pi5]
kernel=kernel-kosmos.img
EOF
    fi
    echo "       Updated config.txt to boot kosmos kernel"
fi

# === Verification ===
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  INSTALLATION COMPLETE${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "  Kernel:     $KERNEL_VERSION"
echo "  Boot image: $BOOT_DIR/kernel-kosmos.img"
echo "  Modules:    /lib/modules/$KERNEL_VERSION/"
echo "  Backup:     $BACKUP_DIR/"
echo ""
echo "  To boot into the new kernel:"
echo "    sudo reboot"
echo ""
echo "  After reboot, verify with:"
echo "    uname -r        # Should show: $KERNEL_VERSION"
echo "    cat /sys/kernel/realtime  # Should show: 1 (RT enabled)"
echo "    modprobe ax25   # Should load without errors"
echo ""
echo -e "  ${YELLOW}TO REVERT if something goes wrong:${NC}"
echo "    1. Pull the SD card, mount boot partition on another computer"
echo "    2. Edit config.txt, remove the line: kernel=kernel-kosmos.img"
echo "    3. Re-insert SD card and boot — stock kernel loads automatically"
echo ""
echo -e "  ${YELLOW}Or from a working SSH session:${NC}"
echo "    sudo sed -i '/kernel=kernel-kosmos.img/d' $BOOT_DIR/config.txt"
echo "    sudo reboot"
echo ""
