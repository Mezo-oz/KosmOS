#!/usr/bin/env bash
# ============================================================================
# KosmOs Kernel Build Script for Raspberry Pi 5
# ============================================================================
# Run this inside your Debian ARM64 UTM VM.
#
# WHAT THIS DOES:
#   1. Installs build dependencies
#   2. Clones the Raspberry Pi kernel source (their fork, not mainline)
#   3. Starts from the Pi 5's default config (bcm2712_defconfig)
#   4. Merges our SDR/RT customizations on top
#   5. Opens menuconfig so you can review and tweak
#   6. Builds the kernel, modules, and device tree blobs
#   7. Packages everything into a tarball ready to SCP
#
# WHY THE PI KERNEL FORK AND NOT MAINLINE:
#   The Raspberry Pi Foundation maintains their own kernel fork at
#   github.com/raspberrypi/linux. It's based on mainline Linux but includes
#   patches for Pi-specific hardware (VideoCore GPU, PCIe controller, the
#   RP1 I/O chip on Pi 5, etc). Think of it like how Cisco IOS is based on
#   BSD but with Cisco-specific drivers bolted on. You *can* use mainline,
#   but you'd be missing drivers for half the hardware on the board.
#
# WHY bcm2712_defconfig:
#   This is the Pi Foundation's known-good starting config for the Pi 5's
#   BCM2712 SoC. It's like using a vendor's default switch template —
#   everything that the hardware needs is already enabled, and you customize
#   from there instead of guessing what's needed.
# ============================================================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Two separate locations, resolved from the script's own path so the repo can be
# cloned anywhere:
#
#   SELF_DIR  = kernel/    — this script, sdr-rt.config, install-kernel.sh
#   REPO_ROOT = the repo   — needed because 02-post-install.sh lives in
#                            userspace/, not beside this script
#
# Both are packaged into the kernel tarball, so both paths must be right or the
# tarball silently ships without its installer.
#
# Deliberately not named KERNEL_DIR: that is already the kernel *source* tree
# ($BUILD_DIR/linux) further down, and confusing the two would be easy.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"

# === CONFIGURATION ===
# Change these if you want a different kernel branch or build directory
KERNEL_BRANCH="rpi-6.12.y"       # Latest Pi LTS branch with RT support
BUILD_DIR="$HOME/kosmos"         # scratch workspace: kernel source + artifacts
KERNEL_DIR="$BUILD_DIR/linux"
OUTPUT_DIR="$BUILD_DIR/output"
PACKAGE_DIR="$BUILD_DIR/kosmos-kernel-pkg"

# Number of parallel build jobs — use all cores
# This is like setting worker threads on a build server.
# More cores = faster build, but also more RAM usage (~1.5GB per job).
# On 4GB VM RAM, use $(nproc). If you get OOM kills, drop to 2.
JOBS=$(nproc)

# Gate the build on the options that define this kernel.
#
# merge_config.sh warns about options whose dependencies are unmet and then
# carries on, and menuconfig lets you toggle anything back off by accident. Both
# failure modes are silent: you would spend 45-90 minutes building, install,
# reboot, and only find out at the post-install check that PREEMPT_RT never made
# it in -- at which point the entire point of the kernel is gone and the only
# remedy is to build again.
#
# Called twice: once after the merge (so a dependency problem is diagnosed
# immediately) and once after menuconfig (so the state actually compiled is the
# state verified).
verify_critical_config() {
    local when="$1"
    local failed=0

    echo ""
    echo "       Verifying critical options ($when)..."

    for opt in CONFIG_PREEMPT_RT=y CONFIG_HZ_1000=y CONFIG_IKCONFIG_PROC=y; do
        if grep -qx -- "$opt" .config; then
            echo "         $opt"
        else
            echo "         MISSING: $opt"
            failed=1
        fi
    done

    if [ "$failed" -ne 0 ]; then
        echo ""
        echo "ERROR: required options are missing from .config ($when)."
        echo "       Building now would produce a kernel that does not do what"
        echo "       KosmOs claims, and nothing would tell you until after the"
        echo "       install and reboot."
        echo ""
        echo "       Inspect with:  grep -E 'PREEMPT|CONFIG_HZ|IKCONFIG' .config"
        echo "       An unmet dependency in the kernel branch or defconfig is the"
        echo "       usual cause when this fails right after the merge."
        exit 1
    fi

    # A string option, so it needs its own test rather than the loop above.
    # Non-fatal: the kernel still works, it just is not identifiable.
    if ! grep -q '^CONFIG_LOCALVERSION="-kosmos"' .config; then
        echo ""
        echo "       WARNING: CONFIG_LOCALVERSION is not \"-kosmos\". The build will"
        echo "                work, but uname -r will not identify this kernel as"
        echo "                KosmOs and 02-post-install.sh will report a failed"
        echo "                version check."
    fi
}

echo "============================================"
echo "  KosmOs Kernel Build for Raspberry Pi 5"
echo "============================================"
echo "Branch:     $KERNEL_BRANCH"
echo "Build dir:  $BUILD_DIR"
echo "CPU cores:  $JOBS"
echo ""

# === STEP 1: Install Build Dependencies ===
# These are the tools the kernel build system needs.
# Think of this as installing the toolchain before you can compile firmware.
echo "[1/7] Installing build dependencies..."
sudo apt-get update
sudo apt-get install -y \
    git bc bison flex libssl-dev \
    libncurses-dev \
    libelf-dev dwarves \
    build-essential \
    kmod cpio \
    rsync

# === STEP 2: Clone the Pi Kernel Source ===
# --depth 1 = shallow clone (only latest commit, not full history)
# This saves ~3GB of download. It's like doing a partial sync instead of
# a full database replication — you get the current state without the
# entire changelog.
echo ""
echo "[2/7] Cloning Raspberry Pi kernel source..."
echo "       (This is ~1.5GB, may take a while)"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

if [ -d "$KERNEL_DIR" ]; then
    echo "       Kernel source already exists, pulling latest..."
    cd "$KERNEL_DIR"
    git pull
else
    git clone --depth 1 --branch "$KERNEL_BRANCH" \
        https://github.com/raspberrypi/linux.git
    cd "$KERNEL_DIR"
fi

# === STEP 3: Start From Pi 5 Default Config ===
# bcm2712_defconfig is the Pi Foundation's blessed config for Pi 5.
# This sets ~4000 config options to sane defaults for the BCM2712 SoC.
# We'll layer our SDR customizations on top of this.
echo ""
echo "[3/7] Loading Pi 5 default config (bcm2712_defconfig)..."
make bcm2712_defconfig

# === STEP 4: Apply SDR/RT Kernel Config Fragment ===
# A "config fragment" is a partial .config that overrides specific options.
# Think of it like a YAML override file — the base config has everything,
# and the fragment says "change these specific knobs."
#
# The merge_config.sh script is built into the kernel source tree.
# It takes the current .config and merges in our fragment, resolving
# any dependency chains automatically. For example, if we enable AX25,
# the script also enables CONFIG_HAMRADIO because AX25 depends on it.
echo ""
echo "[4/7] Merging SDR/RT config fragment..."

# The fragment ships next to this script, so locate it relative to the script
# itself rather than relative to BUILD_DIR. BUILD_DIR is a scratch workspace
# (that is where the kernel source gets cloned); it is not where the repo
# lives. Deriving the path from $HOME/kosmos meant the script only worked if
# you had copied the repo to exactly that directory, and failed here otherwise.
FRAGMENT_PATH="$SELF_DIR/sdr-rt.config"

if [ ! -f "$FRAGMENT_PATH" ]; then
    echo "ERROR: Config fragment not found at $FRAGMENT_PATH"
    echo "       sdr-rt.config should sit next to this script."
    exit 1
fi

# merge_config.sh lives in scripts/kconfig/ inside the kernel source
# The -m flag tells it to merge (not replace) with the existing .config
./scripts/kconfig/merge_config.sh -m .config "$FRAGMENT_PATH"

verify_critical_config "after merge_config.sh"

# === STEP 5: Interactive Review ===
# menuconfig lets you see what we've changed and make your own tweaks.
# Every SDR-related option from our fragment will already be set.
# You can browse around, verify things look right, and save.
#
# NAVIGATION REMINDER:
#   Arrow keys = move, Enter = enter submenu, Space = toggle option
#   Y = built-in [*], M = module [M], N = disabled [ ]
#   / = search for a config option by name
#   ? on any option = show help text explaining what it does
echo ""
echo "[5/7] Opening menuconfig for review..."
echo "       Our SDR/RT changes are already applied."
echo "       Review, tweak if needed, then Save and Exit."
echo ""
echo "       KEY SECTIONS TO CHECK:"
echo "         General setup → Preemption Model → should say 'Full RT'"
echo "         Networking → Amateur Radio → AX.25 should be [M]"
echo "         Device Drivers → Multimedia → RTL2832 SDR should be [M]"
echo ""
read -p "       Press Enter to open menuconfig..."

make menuconfig

# Re-verify: this is the state that will actually be compiled.
verify_critical_config "after menuconfig, before build"

# === STEP 6: Build Everything ===
# This is the big one. On a 4-core ARM64 VM with 4GB RAM, expect:
#   - ~45-90 minutes for a full build
#   - ~2GB of disk space for build artifacts
#
# What gets built:
#   - Image         : The kernel binary itself (what the Pi bootloader loads)
#   - modules       : .ko files (loadable kernel modules, like plugins)
#   - dtbs          : Device Tree Blobs (hardware description files —
#                     think of these as a manifest that tells the kernel
#                     "here's what hardware is on this board and where
#                     it's mapped in memory." Without the right DTB, the
#                     kernel boots but can't find the USB controller, GPU,
#                     etc. It's like an ARP table for hardware.)
echo ""
echo "[6/7] Building kernel (this will take a while)..."
echo "       Using $JOBS parallel jobs"
echo "       Started at: $(date)"
echo ""

# Build the kernel image
make -j"$JOBS" Image

# Build loadable modules
make -j"$JOBS" modules

# Build device tree blobs and overlays
make -j"$JOBS" dtbs

echo ""
echo "       Build finished at: $(date)"

# === STEP 7: Package for Transfer ===
# We now collect everything the Pi needs into a single tarball:
#   - Image                    → goes to /boot/firmware/
#   - modules (.ko files)      → go to /lib/modules/<version>/
#   - dtbs and overlays        → go to /boot/firmware/
#   - System.map               → kernel symbol table (for debugging)
#
# On the Pi, the install script will put each piece in the right place.
echo ""
echo "[7/7] Packaging kernel for transfer..."

# -s and tail -1: without them this captures anything else make writes to stdout
# (a syncconfig run, "Entering directory" chatter), which would then poison both
# the tarball name and the kernel-version file the installer depends on.
KERNEL_VERSION=$(make -s kernelrelease | tail -1)

if [ -z "$KERNEL_VERSION" ]; then
    echo "ERROR: could not determine kernel version from 'make kernelrelease'."
    exit 1
fi
echo "       Kernel version: $KERNEL_VERSION"

rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR"/{boot,modules}

# Copy kernel image
# The Pi 5 bootloader looks for "kernel_2712.img" by default,
# but we'll use a custom name and point config.txt at it.
cp arch/arm64/boot/Image "$PACKAGE_DIR/boot/kernel-kosmos.img"

# Install modules to our package directory
# INSTALL_MOD_PATH tells make "pretend this is the root filesystem"
make modules_install INSTALL_MOD_PATH="$PACKAGE_DIR/modules"

# Copy device tree blobs
cp arch/arm64/boot/dts/broadcom/bcm2712*.dtb "$PACKAGE_DIR/boot/"

# Copy overlays (hardware configuration fragments)
mkdir -p "$PACKAGE_DIR/boot/overlays"
cp arch/arm64/boot/dts/overlays/*.dtbo "$PACKAGE_DIR/boot/overlays/" 2>/dev/null || true

# Copy config and symbol map for reference
cp .config "$PACKAGE_DIR/kernel-config"
cp System.map "$PACKAGE_DIR/System.map"

# Store version string
echo "$KERNEL_VERSION" > "$PACKAGE_DIR/kernel-version"

# Include the Pi-side scripts in the package.
# Without these the tarball contains only the kernel payload, so the documented
# next step -- extract, then run install-kernel.sh from the extracted directory
# -- had nothing to run, and both scripts had to be copied over separately.
# They come from two different directories after the repo reorganisation:
# install-kernel.sh sits beside this script in kernel/, while 02-post-install.sh
# lives in userspace/. Both are flattened into the package root, so the Pi-side
# layout is unchanged -- install-kernel.sh still resolves its own directory at
# runtime and finds boot/ and modules/ beside it.
PI_SIDE_SCRIPTS=(
    "$SELF_DIR/install-kernel.sh"
    "$REPO_ROOT/userspace/02-post-install.sh"
)

for src in "${PI_SIDE_SCRIPTS[@]}"; do
    if [ ! -f "$src" ]; then
        echo "ERROR: cannot package missing script: $src"
        echo "       The repo layout may have changed without this path being"
        echo "       updated. A tarball without its installer looks fine until"
        echo "       you try to use it on the Pi."
        exit 1
    fi
    cp "$src" "$PACKAGE_DIR/"
    chmod +x "$PACKAGE_DIR/$(basename "$src")"
    echo "       packaged $(basename "$src")"
done

# Create the tarball
cd "$BUILD_DIR"
TARBALL="kosmos-kernel-${KERNEL_VERSION}.tar.gz"
tar czf "$TARBALL" -C "$PACKAGE_DIR" .

echo ""
echo "============================================"
echo "  BUILD COMPLETE"
echo "============================================"
echo "  Kernel version:  $KERNEL_VERSION"
echo "  Package:         $BUILD_DIR/$TARBALL"
echo "  Size:            $(du -h "$BUILD_DIR/$TARBALL" | cut -f1)"
echo ""
echo "  Next steps:"
echo "    1. SCP to your Pi:"
echo "       scp $BUILD_DIR/$TARBALL pi@<PI_IP>:~/"
echo ""
echo "    2. On the Pi, unpack and install:"
echo "       mkdir -p ~/kosmos-kernel"
echo "       tar xzf $TARBALL -C ~/kosmos-kernel"
echo "       sudo bash ~/kosmos-kernel/install-kernel.sh"
echo "       sudo reboot"
echo ""
echo "    3. After reboot, verify and install the SDR tools:"
echo "       ~/kosmos-kernel/02-post-install.sh"
echo ""
echo "============================================"
