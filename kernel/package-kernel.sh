#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — package a built kernel for transfer to the Pi
# ============================================================================
# Collects everything the Pi needs into one tarball:
#   - Image                    → goes to /boot/firmware/
#   - modules (.ko files)      → go to /lib/modules/<version>/
#   - dtbs and overlays        → go to /boot/firmware/
#   - System.map               → kernel symbol table (for debugging)
#   - the Pi-side scripts      → so the extracted directory is self-sufficient
#
# On the Pi, install-kernel.sh puts each piece in the right place.
#
# 01-build-kernel.sh runs this as its last step, so normally you never invoke it
# directly. It is a separate script for two reasons: the build script reached the
# 400-line cap and this was the one job in it that is not "build a kernel", and
# repackaging without rebuilding is genuinely useful — change a Pi-side script,
# re-run this, get a fresh tarball in seconds instead of 90 minutes.
#
#   ./package-kernel.sh                    # uses ~/molniya/linux
#   ./package-kernel.sh /path/to/linux     # or an explicit source tree
# ============================================================================

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"

BUILD_DIR="${MOLNIYA_BUILD_DIR:-$HOME/molniya}"
KERNEL_DIR="${1:-$BUILD_DIR/linux}"
PACKAGE_DIR="$BUILD_DIR/molniya-kernel-pkg"

if [ ! -d "$KERNEL_DIR" ]; then
    echo "ERROR: no kernel source tree at $KERNEL_DIR" >&2
    echo "       Run 01-build-kernel.sh first, or pass the tree as an argument." >&2
    exit 1
fi

cd "$KERNEL_DIR"

if [ ! -f arch/arm64/boot/Image ]; then
    echo "ERROR: $KERNEL_DIR has no built kernel image." >&2
    echo "       arch/arm64/boot/Image is missing — the build did not finish." >&2
    exit 1
fi

echo ""
echo "Packaging kernel for transfer..."

# -s and tail -1: without them this captures anything else make writes to stdout
# (a syncconfig run, "Entering directory" chatter), which would then poison both
# the tarball name and the kernel-version file the installer depends on.
KERNEL_VERSION=$(make -s kernelrelease | tail -1)

if [ -z "$KERNEL_VERSION" ]; then
    echo "ERROR: could not determine kernel version from 'make kernelrelease'." >&2
    exit 1
fi

# Read the commit from the tree being packaged rather than taking it on trust
# from the caller, so a hand-run of this script records the truth too.
KERNEL_SHA=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

echo "       Kernel version: $KERNEL_VERSION"
echo "       Source commit:  $KERNEL_SHA"

rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR"/{boot,modules}

# Copy kernel image
# The Pi 5 bootloader looks for "kernel_2712.img" by default,
# but we'll use a custom name and point config.txt at it.
cp arch/arm64/boot/Image "$PACKAGE_DIR/boot/kernel-molniya.img"

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

# Store the version string, and the source commit it was built from. The version
# string alone does not identify a kernel: two builds weeks apart off the same
# branch report the same version and are not the same code. A published
# benchmark needs the commit.
echo "$KERNEL_VERSION" > "$PACKAGE_DIR/kernel-version"
echo "$KERNEL_SHA" > "$PACKAGE_DIR/kernel-commit"

# Include the Pi-side scripts in the package.
# Without these the tarball contains only the kernel payload, so the documented
# next step -- extract, then run install-kernel.sh from the extracted directory
# -- has nothing to run, and every script has to be copied over separately.
# They come from two different directories: install-kernel.sh sits beside this
# script in kernel/, while the post-install set lives in userspace/. All are
# flattened into the package root, so the Pi-side layout is unchanged --
# install-kernel.sh still resolves its own directory at runtime and finds boot/
# and modules/ beside it, and 02-post-install.sh finds its job scripts beside it.
#
# 02-post-install.sh is a sequencer: without 02a-02d it exits with a diagnostic
# and installs nothing. Dropping one of them here would ship a tarball that looks
# complete and fails on the Pi, so the loop below hard-fails on any missing entry
# rather than warning.
PI_SIDE_SCRIPTS=(
    "$SELF_DIR/install-kernel.sh"
    "$REPO_ROOT/userspace/02-post-install.sh"
    "$REPO_ROOT/userspace/02a-verify-kernel.sh"
    "$REPO_ROOT/userspace/02b-bench-tools.sh"
    "$REPO_ROOT/userspace/02c-sdr-userspace.sh"
    "$REPO_ROOT/userspace/02d-locale-ru.sh"
)

for src in "${PI_SIDE_SCRIPTS[@]}"; do
    if [ ! -f "$src" ]; then
        echo "ERROR: cannot package missing script: $src" >&2
        echo "       The repo layout may have changed without this path being" >&2
        echo "       updated. A tarball without its installer looks fine until" >&2
        echo "       you try to use it on the Pi." >&2
        exit 1
    fi
    cp "$src" "$PACKAGE_DIR/"
    chmod +x "$PACKAGE_DIR/$(basename "$src")"
    echo "       packaged $(basename "$src")"
done

# Create the tarball
cd "$BUILD_DIR"
TARBALL="molniya-kernel-${KERNEL_VERSION}.tar.gz"
tar czf "$TARBALL" -C "$PACKAGE_DIR" .

echo ""
echo "============================================"
echo "  PACKAGE COMPLETE"
echo "============================================"
echo "  Kernel version:  $KERNEL_VERSION"
echo "  Source commit:   $KERNEL_SHA"
echo "  Package:         $BUILD_DIR/$TARBALL"
echo "  Size:            $(du -h "$BUILD_DIR/$TARBALL" | cut -f1)"
echo ""
echo "  Next steps:"
echo "    1. SCP to your Pi:"
echo "       scp $BUILD_DIR/$TARBALL pi@<PI_IP>:~/"
echo ""
echo "    2. On the Pi, unpack and install:"
echo "       mkdir -p ~/molniya-kernel"
echo "       tar xzf $TARBALL -C ~/molniya-kernel"
echo "       sudo bash ~/molniya-kernel/install-kernel.sh"
echo "       sudo reboot"
echo ""
echo "    3. After reboot, verify and install the SDR tools:"
echo "       ~/molniya-kernel/02-post-install.sh"
echo ""
echo "============================================"
