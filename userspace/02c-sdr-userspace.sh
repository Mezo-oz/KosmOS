#!/usr/bin/env bash
# ============================================================================
# KosmOS Post-Install 02c — SDR Userspace
# ============================================================================
# Run this ON THE PI. Builds and installs the SDR userspace stack:
#
#   librtlsdr (RTL-SDR Blog fork) → the driver library, v4-capable
#   rtl_433                       → multi-protocol ISM-band decoder
#   dump1090                      → ADS-B aircraft tracking
#   predict                       → satellite pass prediction
#
# and configures the two things that make the hardware usable without root:
# a DVB-T blacklist so the kernel does not claim the dongle as a TV tuner, and
# udev rules for group access to the USB device.
#
# EXIT CODES:
#   0  installed (or the install ran to completion)
#   3  the user answered "n" at the prompt — nothing was installed
#
#   Code 3 exists because 02-post-install.sh has to know the difference. In the
#   script this was split out of, answering "n" here also skipped the locale
#   step, since the locale block sat inside the same gated section; the
#   sequencer reproduces that by stopping when it sees 3.
# ============================================================================

set -euo pipefail

echo ""
echo "============================================"
echo "  SDR Userspace Tool Installation"
echo "============================================"
echo ""
read -r -p "Install SDR userspace tools now? (y/N): " INSTALL_TOOLS
if [ "$INSTALL_TOOLS" != "y" ]; then
    echo "Skipping userspace install. Run this script again when ready."
    exit 3
fi

echo ""
echo "[1/6] Installing system dependencies..."
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
echo "[2/6] Building librtlsdr (RTL-SDR Blog fork for v4 support)..."
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
echo "[3/6] Blacklisting DVB-T driver..."
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
echo "[4/6] Installing rtl_433..."
cd /tmp
if [ -d rtl_433 ]; then rm -rf rtl_433; fi
git clone https://github.com/merbanan/rtl_433
cd rtl_433 && mkdir -p build && cd build
cmake .. && make -j"$(nproc)" && sudo make install
echo "       Done."

echo ""
echo "[5/6] Installing dump1090 (ADS-B decoder)..."
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
echo "[6/6] Installing satellite tools..."
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
