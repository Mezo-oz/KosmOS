#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# KosmOS Kernel Build Script for Raspberry Pi 5
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

# kernel/ — this script, sdr-rt.config, install-kernel.sh and package-kernel.sh.
# Resolved from the script's own path so the repo can be cloned anywhere.
#
# Deliberately not named KERNEL_DIR: that is already the kernel *source* tree
# ($BUILD_DIR/linux) further down, and confusing the two would be easy.
# package-kernel.sh resolves the repo root for itself — it is the one that needs
# to reach userspace/.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# === CONFIGURATION ===
# Change these if you want a different kernel branch or build directory
KERNEL_URL="https://github.com/raspberrypi/linux.git"
KERNEL_BRANCH="rpi-6.12.y"       # Latest Pi LTS branch with RT support
BUILD_DIR="$HOME/kosmos"         # scratch workspace: kernel source + artifacts
KERNEL_DIR="$BUILD_DIR/linux"        # kernel *source* tree (cloned here)
# The staging directory and the tarball are package-kernel.sh's business; it
# derives both from BUILD_DIR, which is passed to it as KOSMOS_BUILD_DIR.

# Exact commit to build. Empty means "tip of $KERNEL_BRANCH", which is the
# long-standing behaviour and which means two builds weeks apart are not the same
# kernel. Set it at the v0.25 rebuild and put the same SHA in
# benchmarks/BENCHMARKS.md: a published benchmark has to name the kernel it
# measured. Either way the SHA actually built is captured below, printed, and
# shipped in the package as kernel-commit.
KERNEL_COMMIT="f5a99b95354d38db209003a7d00560e5091ba94a"

# There was an OUTPUT_DIR="$BUILD_DIR/output" here. It was never referenced --
# staged files go to PACKAGE_DIR and the finished tarball is written to
# BUILD_DIR, which is what the README documents. Removed rather than wired up:
# introducing an output/ directory now would change the documented artifact path
# for no benefit.

# Number of parallel build jobs — defaults to all cores, override with JOBS=N.
# This is like setting worker threads on a build server.
# More cores = faster build, but also more RAM usage (~1.5GB per job).
# On 4GB RAM use $(nproc); if you get OOM kills or thermal throttling on a
# small box, export JOBS=3 (or 2) before running instead of editing this file,
# so the tree stays clean and pulls don't conflict.
JOBS="${JOBS:-$(nproc)}"

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
#
# The two Phase 4d symbols are here for a third failure mode, found on
# 2026-08-23: merge_config.sh does not fail on a symbol that does not exist, so
# a misspelled pin in the fragment is not a warning, it is nothing at all. The
# VCIO pin had been misspelled since it was written and the resulting kernel was
# fine anyway, because the Pi defconfig supplies that symbol. A pin whose only
# evidence of working is that the default already agrees with it is not
# protecting anything. Reading the merged .config back is the check the merge
# itself cannot perform.
verify_critical_config() {
    local when="$1"
    local failed=0

    echo ""
    echo "       Verifying critical options ($when)..."

    for opt in CONFIG_PREEMPT_RT=y CONFIG_HZ_1000=y CONFIG_IKCONFIG_PROC=y \
               CONFIG_BCM_VCIO=y CONFIG_BCM2835_WDT=y; do
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
        echo "       KosmOS claims, and nothing would tell you until after the"
        echo "       install and reboot."
        echo ""
        echo "       Inspect with:  grep -E 'PREEMPT|CONFIG_HZ|IKCONFIG|VCIO|WDT' .config"
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
        echo "                KosmOS and 02-post-install.sh will report a failed"
        echo "                version check."
    fi
}

echo "============================================"
echo "  KosmOS Kernel Build for Raspberry Pi 5"
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

# When pinned, init+fetch rather than clone: cloning a branch gets today's tip,
# which is exactly what a pin exists to prevent.
EXISTING_SOURCE=0
[ -d "$KERNEL_DIR" ] && EXISTING_SOURCE=1

if [ "$EXISTING_SOURCE" -eq 0 ]; then
    if [ -n "$KERNEL_COMMIT" ]; then
        git -c init.defaultBranch=main init -q "$KERNEL_DIR"
        git -C "$KERNEL_DIR" remote add origin "$KERNEL_URL"
    else
        git clone --depth 1 --branch "$KERNEL_BRANCH" "$KERNEL_URL" "$KERNEL_DIR"
    fi
fi
cd "$KERNEL_DIR"

if [ -n "$KERNEL_COMMIT" ]; then
    echo "       Fetching pinned commit $KERNEL_COMMIT..."
    git fetch -q --depth 1 origin "$KERNEL_COMMIT"
    git checkout -q FETCH_HEAD
elif [ "$EXISTING_SOURCE" -eq 1 ]; then
    echo "       Kernel source already exists, pulling latest..."
    git pull
fi

KERNEL_SHA=$(git rev-parse HEAD)

if [ -n "$KERNEL_COMMIT" ] && [ "$KERNEL_SHA" != "$KERNEL_COMMIT" ]; then
    echo "ERROR: source tree is at $KERNEL_SHA, not the pinned $KERNEL_COMMIT" >&2
    exit 1
fi

echo "       Kernel source commit: $KERNEL_SHA"
if [ -z "$KERNEL_COMMIT" ]; then
    echo "       (unpinned — this is the tip of $KERNEL_BRANCH as of right now)"
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
read -r -p "       Press Enter to open menuconfig..."

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
# Handed to package-kernel.sh, which sits beside this script. It is separate so
# that a repackage -- after editing a Pi-side script, say -- does not mean
# another 90-minute build, and because packaging is not "build a kernel".
echo ""
echo "[7/7] Packaging..."

if [ ! -f "$SELF_DIR/package-kernel.sh" ]; then
    echo "ERROR: $SELF_DIR/package-kernel.sh is missing." >&2
    echo "       The build succeeded but there is nothing to package it with." >&2
    echo "       Everything is still in $KERNEL_DIR; restore the script and" >&2
    echo "       run it directly rather than rebuilding." >&2
    exit 1
fi

KOSMOS_BUILD_DIR="$BUILD_DIR" bash "$SELF_DIR/package-kernel.sh" "$KERNEL_DIR"

if [ -z "$KERNEL_COMMIT" ]; then
    echo ""
    echo "  This build was NOT pinned. If it is the one being benchmarked, set"
    echo "  KERNEL_COMMIT at the top of this script and record the same SHA in"
    echo "  benchmarks/BENCHMARKS.md, or the numbers name no kernel:"
    echo ""
    echo "    KERNEL_COMMIT=\"$KERNEL_SHA\""
    echo ""
fi
