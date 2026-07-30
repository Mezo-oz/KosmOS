#!/usr/bin/env bash
# ============================================================================
# KosmOS Post-Install Verification & Userspace Setup
# ============================================================================
# Run this ON THE PI after rebooting into your custom kernel.
# It verifies the kernel is correct, then installs SDR userspace tools.
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "============================================"
echo "  KosmOS Post-Install Verification"
echo "============================================"
echo ""

PASS=0
FAIL=0

# --- Kernel Version ---
KVER=$(uname -r)
echo -n "Kernel version:       $KVER "
# Match "kosmos" only. The old pattern also accepted "rt" or "6.12", which a
# stock Raspberry Pi OS 6.12 kernel satisfies -- so this check reported [OK]
# whether or not the custom kernel was actually running. CONFIG_LOCALVERSION
# in sdr-rt.config is what puts "kosmos" in the version string.
if echo "$KVER" | grep -qi "kosmos"; then
    echo -e "${GREEN}[OK]${NC}"
    # BUG FIX: ((PASS++)) exits with code 1 when PASS=0 under set -e,
    # because bash treats ((0)) as a failure. Using arithmetic assignment
    # instead avoids this. Same trap as a C-style for loop returning
    # the value of the expression — 0 is "false" in bash arithmetic.
    PASS=$((PASS + 1))
else
    echo -e "${YELLOW}[CHECK - may still be stock kernel]${NC}"
    FAIL=$((FAIL + 1))
fi

# --- Real-Time ---
#
# Do NOT rely on /sys/kernel/realtime alone. That file came from the out-of-tree
# PREEMPT_RT patchset; since RT was merged into mainline in 6.12 it is not
# created, so a genuinely RT mainline kernel has no such file. Checking only for
# it reports NOT DETECTED on exactly the kernel this project builds -- confirmed
# on hardware 2026-07-29, where uname -v read "SMP PREEMPT_RT" while the file was
# absent.
#
# Authoritative sources, best first:
#   1. /proc/config.gz  — what was actually compiled (needs CONFIG_IKCONFIG_PROC)
#   2. uname -v         — the build banner carries "PREEMPT_RT"
#   3. /sys/kernel/realtime — legacy patchset only; kept for older kernels
echo -n "RT scheduling:        "
RT_EVIDENCE=""
if [ -f /proc/config.gz ] && zcat /proc/config.gz 2>/dev/null | grep -qx "CONFIG_PREEMPT_RT=y"; then
    RT_EVIDENCE="CONFIG_PREEMPT_RT=y in /proc/config.gz"
elif uname -v | grep -q "PREEMPT_RT"; then
    RT_EVIDENCE="PREEMPT_RT in uname -v"
elif [ -f /sys/kernel/realtime ] && [ "$(cat /sys/kernel/realtime)" = "1" ]; then
    RT_EVIDENCE="/sys/kernel/realtime=1 (legacy patchset)"
fi

if [ -n "$RT_EVIDENCE" ]; then
    echo -e "${GREEN}ENABLED [OK]${NC} — $RT_EVIDENCE"
    PASS=$((PASS + 1))
else
    echo -e "${RED}NOT DETECTED [FAIL]${NC}"
    echo "  → CONFIG_PREEMPT_RT may not have been set."
    echo "    Checked: /proc/config.gz, uname -v, /sys/kernel/realtime"
    FAIL=$((FAIL + 1))
fi

# --- Timer Frequency ---
echo -n "Timer frequency:      "
# /proc/config.gz is gzip, so it must be decompressed -- the previous first
# attempt grepped the compressed bytes directly, which can never match. Requires
# CONFIG_IKCONFIG_PROC, now set in sdr-rt.config.
if [ -f /proc/config.gz ]; then
    HZ=$(zcat /proc/config.gz 2>/dev/null | grep "^CONFIG_HZ=" | head -1 || echo "unknown")
else
    HZ="unavailable (no /proc/config.gz)"
fi
if echo "$HZ" | grep -q "1000"; then
    echo -e "1000 Hz ${GREEN}[OK]${NC}"
    PASS=$((PASS + 1))
else
    echo -e "$HZ ${YELLOW}[CHECK]${NC}"
fi

# --- CPU Governor ---
echo -n "CPU governor:         "
GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
if [ "$GOV" = "performance" ]; then
    echo -e "performance ${GREEN}[OK]${NC}"
    PASS=$((PASS + 1))
else
    echo -e "$GOV ${YELLOW}[NOT performance]${NC}"
    echo "  → CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE only sets the kernel's"
    echo "    *default*. Raspberry Pi OS / Debian override it at boot, so the"
    echo "    running governor is whatever userspace last wrote -- observed as"
    echo "    'ondemand' on hardware 2026-07-29 despite the kernel default."
    echo "    The kernel config alone does NOT deliver 'always max clock'."
    echo ""
    echo "  → For this session only:"
    echo "      echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor"
    echo "  → To persist it, install a unit that sets it at boot; a kernel"
    echo "    rebuild will not help."
    echo ""
    echo "    BENCHMARK NOTE: ondemand adds frequency-ramp latency on top of"
    echo "    scheduling latency. It is applied to both kernels so the A/B stays"
    echo "    fair, but pin it to performance on both before publishing numbers,"
    echo "    or state plainly that the figures include ramp effects."
fi

# --- USB Subsystem ---
echo -n "USB subsystem:        "
if lsusb &>/dev/null; then
    echo -e "${GREEN}[OK]${NC}"
    PASS=$((PASS + 1))
else
    echo -e "${RED}[FAIL - lsusb not working]${NC}"
    FAIL=$((FAIL + 1))
fi

# --- AX.25 Module ---
echo -n "AX.25 module:         "
# Needs sudo: loading a module is privileged, and the rest of this script runs
# unprivileged. Without sudo this always failed and reported "may need to
# rebuild" on kernels where AX.25 was present and fine -- a false negative on
# one of the features the project advertises.
if sudo modprobe ax25 2>/dev/null; then
    echo -e "${GREEN}[OK - loaded]${NC}"
    PASS=$((PASS + 1))
    # Clean up — unload it for now
    sudo rmmod ax25 2>/dev/null || true
else
    echo -e "${YELLOW}[not available - may need to rebuild]${NC}"
fi

# --- Kernel Config Available ---
echo -n "/proc/config.gz:      "
if [ -f /proc/config.gz ]; then
    echo -e "${GREEN}[OK]${NC}"
    PASS=$((PASS + 1))
else
    echo -e "${YELLOW}[not available]${NC}"
    echo "  → Enable CONFIG_IKCONFIG and CONFIG_IKCONFIG_PROC in your kernel"
fi

# --- Russian Locale ---
echo -n "Russian locale:       "
CURRENT_LANG=$(locale 2>/dev/null | grep "^LANG=" | cut -d= -f2)
if echo "$CURRENT_LANG" | grep -qi "ru_RU"; then
    echo -e "${GREEN}$CURRENT_LANG [OK]${NC}"
    PASS=$((PASS + 1))
else
    echo -e "${YELLOW}not set (will configure during install)${NC}"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo -e "${YELLOW}Some checks failed. Review the messages above.${NC}"
    echo "Your stock kernel is still available as a fallback."
    echo ""
fi

# === RT Benchmark Tooling ===
#
# Deliberately offered separately from, and before, the SDR userspace install.
# Test 1 of the RT benchmark (cyclictest under load) needs no SDR hardware and no
# SDR tools, and it runs before the SATCOM stack is built. Bundling these into
# the SDR dependency list would mean you could not benchmark the kernel without
# first installing a toolchain you do not need yet.
#
#   rt-tests  → cyclictest, the standard RT wakeup-latency benchmark
#   stress-ng → generates the CPU and IO load the benchmark measures under
echo "============================================"
echo "  RT Benchmark Tooling"
echo "============================================"
echo ""
read -r -p "Install RT benchmark tools (rt-tests, stress-ng)? (y/N): " INSTALL_BENCH
case "${INSTALL_BENCH,,}" in
    y|yes)
        sudo apt-get update
        sudo apt-get install -y rt-tests stress-ng
        echo ""
        echo "       Installed. Verify on each kernel with:"
        echo "         sudo cyclictest --version"
        echo "         stress-ng --version"
        echo ""
        echo "       Baseline run (idle, 1M iterations, RT priority):"
        echo "         sudo cyclictest -l1000000 -m -S -p90 -i200 -h400 -q"
        echo ""
        echo "       The figure that matters is Max latency under load, not Avg."
        echo "       Run the same command on the stock kernel and compare."
        ;;
    *)
        echo "       Skipped. Install later with: sudo apt install rt-tests stress-ng"
        ;;
esac
echo ""

# === Userspace SDR Tools ===
echo ""
echo "============================================"
echo "  SDR Userspace Tool Installation"
echo "============================================"
echo ""
read -r -p "Install SDR userspace tools now? (y/N): " INSTALL_TOOLS
if [ "$INSTALL_TOOLS" != "y" ]; then
    echo "Skipping userspace install. Run this script again when ready."
    exit 0
fi

echo ""
echo "[1/7] Installing system dependencies..."
sudo apt-get update
sudo apt-get install -y \
    cmake build-essential pkg-config git \
    libusb-1.0-0-dev \
    libfftw3-dev \
    libboost-all-dev \
    libsndfile1-dev \
    libpulse-dev \
    libncurses-dev \
    sox \
    python3-dev python3-pip python3-numpy python3-scipy python3-matplotlib

echo ""
echo "[2/7] Building librtlsdr (RTL-SDR Blog fork for v4 support)..."
# WHY the blog fork and not osmocom's original:
# The RTL-SDR Blog v4 dongle has hardware changes (improved LNA, HF
# direct sampling mode) that require driver patches not yet in the
# original osmocom repo. The blog fork includes these. It's like using
# a vendor's updated firmware vs the community version — same base
# code but with hardware-specific fixes.
cd /tmp
if [ -d rtl-sdr-blog ]; then rm -rf rtl-sdr-blog; fi
git clone https://github.com/rtlsdrblog/rtl-sdr-blog
cd rtl-sdr-blog && mkdir -p build && cd build
cmake ../ -DINSTALL_UDEV_RULES=ON -DDETACH_KERNEL_DRIVER=ON
make -j"$(nproc)" && sudo make install
sudo ldconfig
echo "       Done."

echo ""
echo "[3/7] Blacklisting DVB-T driver..."
# The kernel's DVB-T driver will auto-claim the RTL2832 chip for digital
# TV reception. We need the chip in raw SDR mode instead.
# This is like shutting down a conflicting service before starting yours —
# two things can't own the same USB device simultaneously.
sudo tee /etc/modprobe.d/blacklist-rtlsdr.conf > /dev/null <<EOF
# Prevent kernel DVB-T driver from claiming RTL-SDR devices
# The SDR userspace library (librtlsdr) needs raw USB access
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2838
blacklist dvb_usb_v2
blacklist dvb_core
EOF
echo "       DVB-T drivers blacklisted."

# Also create udev rules so non-root users can access the SDR
sudo tee /etc/udev/rules.d/99-rtlsdr.rules > /dev/null <<EOF
# RTL-SDR USB device permissions
# Without this, only root can open the USB device.
# This is like setting file permissions — we're granting the 'plugdev'
# group access to the raw USB device node.
SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="2838", GROUP="plugdev", MODE="0666"
SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="2832", GROUP="plugdev", MODE="0666"
EOF
sudo udevadm control --reload-rules
echo "       udev rules installed."

echo ""
echo "[4/7] Installing rtl_433..."
cd /tmp
if [ -d rtl_433 ]; then rm -rf rtl_433; fi
git clone https://github.com/merbanan/rtl_433
cd rtl_433 && mkdir -p build && cd build
cmake .. && make -j"$(nproc)" && sudo make install
echo "       Done."

echo ""
echo "[5/7] Installing dump1090 (ADS-B decoder)..."
# NOTE: dump1090 requires libncurses-dev (included in step 1 deps).
# Without it, the build fails with "curses.h: No such file or directory."
cd /tmp
if [ -d dump1090 ]; then rm -rf dump1090; fi
git clone https://github.com/flightaware/dump1090
cd dump1090
make -j"$(nproc)" BLADERF=no HACKRF=no
sudo cp dump1090 /usr/local/bin/
echo "       Done."

echo ""
echo "[6/7] Installing satellite tools..."
# NOTE: 'predict' is not in Pi OS repos — must be built from source.
# The project uses a curses-based installer (installer.c), not a standard
# Makefile install target. We compile the installer with ncurses linked,
# then run it as root.
cd /tmp
if [ -d predict ]; then rm -rf predict; fi
git clone https://github.com/kd2bd/predict
cd predict
cc -o installer installer.c -lncurses -lm
sudo ./installer

# gpredict needs a desktop environment — skip if headless
if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    sudo apt-get install -y gpredict
    echo "       gpredict installed (GUI available)."
else
    echo "       Skipping gpredict (no display detected). Install later with: sudo apt install gpredict"
fi

# Download initial TLE data for satellite tracking
mkdir -p "$HOME/.config/satellite-tle"
echo "       Downloading TLE data..."
wget -q -O "$HOME/.config/satellite-tle/noaa.tle" \
    "https://celestrak.org/NORAD/elements/gp.php?GROUP=noaa&FORMAT=tle" 2>/dev/null || \
    echo "       (TLE download failed — update manually later)"
wget -q -O "$HOME/.config/satellite-tle/amateur.tle" \
    "https://celestrak.org/NORAD/elements/gp.php?GROUP=amateur&FORMAT=tle" 2>/dev/null || true

# === Russian Locale Configuration ===
echo ""
echo "[7/7] Configuring Russian locale..."
# WHAT THIS DOES:
#   Sets the system language to Russian for all non-input-dependent output.
#   Menu text, status messages, date/time formatting → Russian.
#   Commands, file paths, config syntax → always English (they're binary names).
#
#   Setting LANG=ru_RU.UTF-8 tells programs: "if you have a Russian translation
#   for this output string, use it." Programs without translations (most SDR
#   tools) silently fall back to English. No commands change.

# Install locale packages and Russian fonts
sudo apt-get install -y \
    locales \
    fonts-dejavu-core \
    fonts-liberation2 \
    console-cyrillic

# Install Russian man pages (translations of standard Linux man pages)
sudo apt-get install -y manpages-ru 2>/dev/null || \
    echo "       (manpages-ru not available in repo — skipping)"

# Generate the ru_RU.UTF-8 locale
# This is like adding a language pack — it creates the translation database
# the system references when LANG is set to Russian.
sudo sed -i 's/# ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || true
echo "ru_RU.UTF-8 UTF-8" | sudo tee -a /etc/locale.gen > /dev/null 2>/dev/null
sudo locale-gen

# Set Russian as the system default
# localectl writes to /etc/default/locale which is read at login time.
# This persists across reboots.
sudo localectl set-locale LANG=ru_RU.UTF-8

# Also set it for the current session so verification works immediately
export LANG=ru_RU.UTF-8

echo "       Russian locale configured."
echo "       Date test: $(date '+%A, %d %B %Y г.')"
echo ""
echo "       NOTE on HDMI console Cyrillic:"
echo "         If Cyrillic shows as squares on the HDMI console, run:"
echo "         sudo dpkg-reconfigure console-setup"
echo "         Select: UTF-8 → Guess optimal → Terminus → 8x16"
echo "         SSH terminals handle Cyrillic natively — no config needed."
echo ""
echo "       NOTE: If you need English error messages for Googling errors:"
echo "         export LC_MESSAGES=en_US.UTF-8"
echo "       This overrides just messages while keeping everything else Russian."

echo ""
echo "============================================"
echo "  SETUP COMPLETE"
echo "============================================"
echo ""
echo "  Quick test commands (plug in RTL-SDR first):"
echo ""
echo "    rtl_test -t              # Verify SDR is detected"
echo "    rtl_433                  # Listen for wireless sensors"
echo "    rtl_power -f 88M:108M:125k -i 10 -1 fm_band.csv"
echo "                             # Scan the FM broadcast band"
echo ""
echo "  First satellite capture:"
echo "    predict -p 'NOAA 19'    # Find next pass time"
echo "    rtl_fm -f 137.1M -s 48k -g 40 noaa19.raw"
echo "                             # Record during the pass"
echo ""
