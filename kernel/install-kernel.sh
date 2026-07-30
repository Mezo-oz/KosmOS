#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# KosmOS Kernel Install Script — Run this ON the Raspberry Pi 5
# ============================================================================
# This script takes the kernel package built in your VM and installs it
# onto the Pi's SD card. It's non-destructive: it backs up your existing
# kernel so you can always revert if something goes wrong.
#
# WHAT GETS INSTALLED WHERE:
#
#   Pi 5 Boot Partition Layout (/boot/firmware/):
#   ├── config.txt            ← the ONLY stock file we modify
#   ├── cmdline.txt           ← untouched (copied, not edited)
#   ├── kernel_2712.img       ← stock kernel, untouched
#   ├── bcm2712*.dtb          ← stock device trees, untouched
#   ├── overlays/             ← stock overlays, untouched
#   └── kosmos/               ← everything of ours lives here
#       ├── kernel-kosmos.img
#       ├── cmdline.txt       ← stock cmdline + KosmOS additions
#       ├── bcm2712*.dtb
#       └── overlays/
#
#   Module Directory (/lib/modules/):
#   ├── <version>/            ← stock kernel modules (untouched)
#   └── <version>-kosmos+/    ← our modules (added)
#
# THE SAFETY NET:
#   The firmware's os_prefix mechanism points at kosmos/ for the kernel, device
#   trees, overlays and command line. Every stock file stays byte-identical, so
#   reverting is genuinely a one-step operation and the stock kernel boots
#   against its own device trees rather than ours.
#
#     1. Delete the KosmOS block from config.txt (or pull the SD card and edit
#        it on another machine if the Pi will not boot)
#     2. Reboot — the firmware falls back to the stock kernel
#
#   config.txt is written LAST, after every file we need is confirmed present.
#   Up to that moment the system still boots exactly as it did before.
# ============================================================================

set -euo pipefail

# Color output for readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# === CONFIGURATION ===

# Subdirectory of the boot partition holding everything KosmOS boots.
# Also the value given to os_prefix (with a trailing slash added).
OS_PREFIX_DIR="kosmos"

# CPUs to run in full-dynticks mode, as a kernel cpulist ("1-3", "2,3", or ""
# to disable). CPU 0 must be excluded to act as the housekeeping core; the
# kernel refuses nohz_full on all CPUs.
#
# BENCHMARK NOTE: this is a second variable alongside PREEMPT_RT. If the question
# being answered is strictly "does PREEMPT_RT reduce latency", isolating cores at
# the same time makes the improvement unattributable. Either set this to "" for
# the A/B runs, or run three configurations (stock, RT alone, RT + dynticks) and
# report them separately.
NOHZ_FULL_CPUS="1-3"

# === Sanity Checks ===
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  KosmOS Kernel Installer for Pi 5${NC}"
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
    read -r -p "Continue anyway? (y/N): " confirm
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

# Fail here rather than defaulting to a placeholder.
#
# This used to fall back to the literal string "unknown", which is not a real
# kernel version -- so "depmod unknown" later in the script failed under set -e
# *after* the modules had been copied but *before* config.txt was updated. That
# leaves a half-installed state: modules on disk, boot config untouched, and an
# error message pointing at depmod rather than at the missing file.
if [ ! -f "$SCRIPT_DIR/kernel-version" ]; then
    echo -e "${RED}ERROR: kernel-version not found in $SCRIPT_DIR${NC}"
    echo "       The package is incomplete. Re-extract the tarball, or rebuild"
    echo "       it with 01-build-kernel.sh."
    exit 1
fi

KERNEL_VERSION=$(tr -d '[:space:]' < "$SCRIPT_DIR/kernel-version")

if [ -z "$KERNEL_VERSION" ]; then
    echo -e "${RED}ERROR: kernel-version is empty.${NC}"
    echo "       Rebuild the package with 01-build-kernel.sh."
    exit 1
fi

# The modules directory must match the version string, or depmod builds a
# dependency map for a kernel that will never boot with these modules.
if [ ! -d "$SCRIPT_DIR/modules/lib/modules/$KERNEL_VERSION" ]; then
    echo -e "${RED}ERROR: no module directory for $KERNEL_VERSION${NC}"
    echo "       Expected: $SCRIPT_DIR/modules/lib/modules/$KERNEL_VERSION"
    echo "       Found:    $(find "$SCRIPT_DIR/modules/lib/modules/" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null | tr '\n' ' ')"
    exit 1
fi

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

# === Step 2: Install Kernel Image, DTBs and Overlays Into Our Own Directory ===
#
# Everything KosmOS loads goes under $BOOT_DIR/$OS_PREFIX_DIR/ and nothing in the
# stock boot directory is modified except config.txt.
#
# WHY THIS CHANGED: the previous version copied our kernel image next to the
# stock one but wrote our DTBs and overlays *over* the stock files in the shared
# boot directory. Two consequences, both bad:
#
#   1. Reverting was not actually clean. Removing the kernel= line restored the
#      stock kernel image, but that kernel then booted against our device trees.
#      Overlays were not even backed up, so there was nothing to restore.
#   2. It breaks the RT benchmark. The whole proof-of-claim rests on "same
#      hardware, same SD card, only the kernel changes between boots" -- which
#      was not true if the stock kernel was running our DTBs.
#
# The Pi firmware supports exactly this via os_prefix, which it prepends to the
# kernel, cmdline.txt and .dtb filenames it loads. Overlays follow through
# overlay_prefix. So each kernel gets a self-contained directory and the two
# never touch.
echo ""
echo -e "${YELLOW}[2/5] Installing kernel, DTBs and overlays to $OS_PREFIX_DIR/...${NC}"

KOSMOS_DIR="$BOOT_DIR/$OS_PREFIX_DIR"
mkdir -p "$KOSMOS_DIR/overlays"

cp "$SCRIPT_DIR/boot/kernel-kosmos.img" "$KOSMOS_DIR/"
echo "       kernel-kosmos.img"

cp "$SCRIPT_DIR/boot/bcm2712"*.dtb "$KOSMOS_DIR/"
echo "       $(find "$KOSMOS_DIR" -maxdepth 1 -name 'bcm2712*.dtb' | wc -l) device tree blob(s)"

if [ -d "$SCRIPT_DIR/boot/overlays" ]; then
    cp "$SCRIPT_DIR/boot/overlays/"*.dtbo "$KOSMOS_DIR/overlays/" 2>/dev/null || true
    echo "       $(find "$KOSMOS_DIR/overlays" -maxdepth 1 -name '*.dtbo' 2>/dev/null | wc -l) overlay(s)"
fi

# === Step 3: Build Our Own cmdline.txt ===
#
# os_prefix applies to cmdline.txt too, so the firmware will look for
# $OS_PREFIX_DIR/cmdline.txt. It MUST exist: without a command line the kernel
# gets no root= and will not boot. Start from the stock one so root=, rootfstype=
# and the rest carry over unchanged, then append only what KosmOS adds.
echo ""
echo -e "${YELLOW}[3/5] Building $OS_PREFIX_DIR/cmdline.txt...${NC}"

if [ ! -f "$BOOT_DIR/cmdline.txt" ]; then
    echo -e "${RED}ERROR: no $BOOT_DIR/cmdline.txt to derive ours from.${NC}"
    echo "       Refusing to guess a kernel command line -- getting root= wrong"
    echo "       produces an unbootable system."
    exit 1
fi

cp "$BOOT_DIR/cmdline.txt" "$BACKUP_DIR/cmdline.txt.stock"
KOSMOS_CMDLINE=$(tr -d '\n' < "$BOOT_DIR/cmdline.txt")

# Full dynticks. CONFIG_NO_HZ_FULL only does anything if the CPUs to run
# tickless are named here, so without this the option was compiled and inert --
# "tickless" was in the project's claims but not in its behaviour.
#
# CPU 0 is deliberately left out: it stays the housekeeping CPU that handles
# timekeeping and unbound interrupts. nohz_full on every core is rejected by the
# kernel. rcu_nocbs matches nohz_full so RCU callbacks are also offloaded off the
# isolated cores, which is what makes the latency benefit actually show up.
if [ -n "$NOHZ_FULL_CPUS" ]; then
    KOSMOS_CMDLINE="$KOSMOS_CMDLINE nohz_full=$NOHZ_FULL_CPUS rcu_nocbs=$NOHZ_FULL_CPUS"
    echo "       Added: nohz_full=$NOHZ_FULL_CPUS rcu_nocbs=$NOHZ_FULL_CPUS"
else
    echo "       NOHZ_FULL_CPUS empty — no dynticks args added"
fi

printf '%s\n' "$KOSMOS_CMDLINE" > "$KOSMOS_DIR/cmdline.txt"
echo "       Wrote $KOSMOS_DIR/cmdline.txt"

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

# Validate the payload BEFORE touching config.txt.
#
# config.txt is the switch that arms all of this. If it points at os_prefix and
# any required file is missing, the Pi does not boot -- and this box is often
# headless, so recovery means pulling the SD card. So every file is confirmed
# present first, and config.txt is written last. Until this point the system is
# still booting exactly as it did before.
echo "       Validating payload before arming config.txt..."

MISSING=""
[ -f "$KOSMOS_DIR/kernel-kosmos.img" ] || MISSING="$MISSING kernel-kosmos.img"
[ -f "$KOSMOS_DIR/cmdline.txt" ]       || MISSING="$MISSING cmdline.txt"
ls "$KOSMOS_DIR"/bcm2712*.dtb >/dev/null 2>&1 || MISSING="$MISSING bcm2712*.dtb"
grep -q "root=" "$KOSMOS_DIR/cmdline.txt" 2>/dev/null || MISSING="$MISSING root=-in-cmdline"

if [ -n "$MISSING" ]; then
    echo -e "${RED}ERROR: refusing to modify config.txt. Missing:$MISSING${NC}"
    echo "       Nothing has been armed, so the system still boots as before."
    echo "       Files staged in $KOSMOS_DIR can be removed safely."
    exit 1
fi
echo "       Payload complete."

if grep -q "^os_prefix=$OS_PREFIX_DIR/" "$BOOT_DIR/config.txt"; then
    echo "       config.txt already points at $OS_PREFIX_DIR/"
else
    # Appended as its own [pi5] section rather than inserted into an existing
    # one. Appending is idempotent and order-independent; the old approach used
    # `sed /^\[pi5\]/a`, which inserts after *every* [pi5] line if the file has
    # more than one.
    #
    # A conditional filter stays in effect until the next one, so [all] at the
    # end returns config.txt to unfiltered -- otherwise anything a later tool
    # appends would silently inherit our [pi5] scope.
    # Guarantee a trailing newline first. If config.txt does not end in one,
    # appending would weld our first line onto the file's last directive and
    # corrupt it.
    if [ -n "$(tail -c 1 "$BOOT_DIR/config.txt")" ]; then
        echo "" >> "$BOOT_DIR/config.txt"
    fi

    # The block begins on the marker line with no blank line before it, so the
    # revert range deletes it exactly and restores config.txt byte-for-byte. A
    # leading blank would survive the range and accumulate on every cycle.
    #
    # The revert one-liner is deliberately NOT printed inside this block. It
    # names both markers, so a copy of it living between them gives sed an early
    # closing match: the range ends on the comment instead of the real end
    # marker, and os_prefix/kernel survive the delete. You would believe you had
    # reverted while still booting the custom kernel. The command lives in the
    # script's closing output and in the README instead.
    cat >> "$BOOT_DIR/config.txt" <<EOF
# --- KosmOS custom kernel -----------------------------------------------------
# Loads the kernel, device trees, overlays and cmdline.txt from $OS_PREFIX_DIR/.
# Stock kernel files are untouched.
#
# TO REVERT: delete every line from this marker down to the end marker below,
# then reboot. The stock kernel loads automatically.
[pi5]
os_prefix=$OS_PREFIX_DIR/
kernel=kernel-kosmos.img
[all]
# --- end KosmOS ---------------------------------------------------------------
EOF
    echo "       Armed: os_prefix=$OS_PREFIX_DIR/"
fi

# === Verification ===
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  INSTALLATION COMPLETE${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "  Kernel:     $KERNEL_VERSION"
echo "  Boot dir:   $KOSMOS_DIR/  (stock boot files untouched)"
echo "  Modules:    /lib/modules/$KERNEL_VERSION/"
echo "  Backup:     $BACKUP_DIR/"
echo "  Cmdline:    $(cat "$KOSMOS_DIR/cmdline.txt")"
echo ""
echo "  To boot into the new kernel:"
echo "    sudo reboot"
echo ""
echo "  After reboot, verify with:"
echo "    uname -r                       # should contain 'kosmos'"
echo "    cat /sys/kernel/realtime       # should show 1"
echo "    cat /sys/devices/system/cpu/nohz_full   # should show ${NOHZ_FULL_CPUS:-'(none)'}"
echo "    sudo modprobe ax25             # should load without errors"
echo ""
echo -e "  ${YELLOW}TO REVERT — from a working SSH session:${NC}"
echo "    sudo sed -i '/--- KosmOS custom kernel/,/--- end KosmOS/d' $BOOT_DIR/config.txt"
echo "    sudo reboot"
echo ""
echo -e "  ${YELLOW}TO REVERT — if the Pi will not boot:${NC}"
echo "    1. Pull the SD card, mount the boot partition on another computer"
echo "    2. Delete the KosmOS block from config.txt (between the --- markers)"
echo "    3. Re-insert and power on — the stock kernel loads automatically"
echo ""
echo "    Stock config.txt is also saved at:"
echo "      $BACKUP_DIR/config.txt"
echo ""
echo -e "  ${YELLOW}TO SWITCH KERNELS for the RT benchmark:${NC}"
echo "    Comment out the two directives to boot stock, uncomment to boot KosmOS."
echo "    Nothing else differs between the two boots — that is what makes the"
echo "    A/B comparison valid."
echo ""
