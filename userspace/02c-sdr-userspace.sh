#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
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

# === PINNED VERSIONS ========================================================
#
# Pillar 3 of this project is a reproducible, auditable build. All four projects
# below were cloned at unpinned upstream HEAD, which meant two installs a month
# apart did not produce the same system, and a bad upstream commit landed
# straight on the Pi with nothing in between. Each is now pinned to an exact
# commit and the checkout is verified against it.
#
# WHY A COMMIT NAME RATHER THAN A SHA-256 OF A TARBALL:
#   A git commit name is a hash over the commit, its tree and its parents, so
#   confirming it after checkout is a content check on the entire source tree --
#   the same guarantee a checksum on a release tarball gives, without depending
#   on GitHub's auto-generated tarballs, which are not byte-stable over time and
#   so cannot be checksummed reliably in the first place. It is also strictly
#   stronger than pinning a tag, because a tag can be moved and a commit name
#   cannot. (Git object names are SHA-1; against the threat this defends -- an
#   upstream force-push, a retagged release, a hijacked branch -- that is
#   sufficient, and GitHub is the trust anchor either way.) Nothing here fetches
#   a loose file, so there is no artifact left for a SHA-256 digest to cover;
#   the apt packages in step 1 are verified by apt against the archive's signed
#   Release file.
#
# TO UPDATE A PIN: bump the tag and the SHA together, after reading the upstream
# changelog. Bumping only the tag makes the verification fail, which is the
# mechanism working, not a bug.
#
# Every pin below was read from the upstream repository on 2026-07-29.

# RTL-SDR Blog fork of librtlsdr — latest release, v1.3.6 (2024-06-17).
RTLSDR_URL="https://github.com/rtlsdrblog/rtl-sdr-blog"
RTLSDR_TAG="v1.3.6"
RTLSDR_SHA="240bd0e1e6d9f64361b6949047468958cd08aa31"

# rtl_433 — upstream tags calendar releases; 25.12 is the latest (2025-12-12).
RTL433_URL="https://github.com/merbanan/rtl_433"
RTL433_TAG="25.12"
RTL433_SHA="ea7d504877df751a202432d47dbb0c425ab0a93c"

# dump1090 (FlightAware fork) — v11.1 (2026-07-01).
# Note this tag is not an ancestor of master's tip, so it has to be fetched by
# commit or by tag rather than by branch. clone_pinned does both.
DUMP1090_URL="https://github.com/flightaware/dump1090"
DUMP1090_TAG="v11.1"
DUMP1090_SHA="0339a57b89cd6e61856cbb13ae342c31ae7be5ac"

# predict — upstream has never cut a tag and the last commit is 2018-05-07, so
# the pin is a bare commit with no tag to fall back to. A dormant upstream is
# the easy case for reproducibility: this SHA will not move.
PREDICT_URL="https://github.com/kd2bd/predict"
PREDICT_TAG=""
PREDICT_SHA="517fccf421909b4974151b6ca30810586ca658a3"

# Where sources are built. /tmp as before; nothing here is kept after install.
SRC_ROOT="/tmp"

# Append-only record of what was actually built on this machine, so the box can
# answer "which revision is this binary from" months later without guessing.
MANIFEST="/usr/local/share/kosmos/build-manifest.txt"

# Clone one project at an exact commit and refuse to continue if what landed is
# anything else.
#
#   clone_pinned <name> <url> <sha> [<tag-for-fallback>]
#
# Leaves the shell inside the checked-out source directory.
clone_pinned() {
    local name="$1" url="$2" sha="$3" tag="${4:-}"
    local dir="$SRC_ROOT/$name"

    # Guarding an rm -rf on an interpolated path. All four call sites pass
    # literals, so this can only fire after an edit -- which is exactly when you
    # want it to.
    if [ -z "$name" ] || [ -z "$url" ] || [ -z "$sha" ]; then
        echo "ERROR: clone_pinned requires name, url and sha" >&2
        exit 1
    fi

    rm -rf "$dir"
    mkdir -p "$dir"
    cd "$dir"

    # init + fetch rather than clone: it is the only way to ask for one specific
    # commit. A shallow clone of a branch gets whatever the tip is today, which
    # is the problem being fixed.
    git -c init.defaultBranch=main init -q
    git remote add origin "$url"

    # Fetching the commit directly is cheapest and cannot be redirected by a
    # moved tag. GitHub permits it (uploadpack.allowAnySHA1InWant); a mirror
    # might not, so fall back to the tag and let the check below catch a
    # mismatch rather than silently building something else.
    if ! git fetch -q --depth 1 origin "$sha" 2>/dev/null; then
        if [ -z "$tag" ]; then
            echo "ERROR: $name — the server refused a fetch of commit $sha and" >&2
            echo "       this project has no tag to fall back to." >&2
            exit 1
        fi
        echo "       (server refused a direct commit fetch; trying tag $tag)"
        git fetch -q --depth 1 origin "refs/tags/$tag"
    fi

    git checkout -q FETCH_HEAD

    local got
    got=$(git rev-parse HEAD)
    if [ "$got" != "$sha" ]; then
        echo "" >&2
        echo "ERROR: $name is not at its pinned commit." >&2
        echo "       expected: $sha" >&2
        echo "       got:      $got" >&2
        echo "" >&2
        echo "       A moved tag or a force-pushed branch is the usual cause." >&2
        echo "       Do not work around this by deleting the check: read the" >&2
        echo "       upstream history, then update both the tag and the SHA in" >&2
        echo "       this script together." >&2
        exit 1
    fi

    echo "       $name @ ${sha:0:12}${tag:+ ($tag)} [verified]"
}

# Append one line to the build manifest. Called after a successful install, not
# at checkout time: a manifest that lists a revision whose build then failed
# would answer "which revision is this binary from" with a lie.
#
#   record_pin <name> <sha> <tag> <url>
record_pin() {
    local name="$1" sha="$2" tag="$3" url="$4"

    sudo mkdir -p "$(dirname "$MANIFEST")"
    printf '%s  %-14s %s  %-8s %s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$name" "$sha" "${tag:--}" "$url" \
        | sudo tee -a "$MANIFEST" > /dev/null
}

echo ""
echo "============================================"
echo "  SDR Userspace Tool Installation"
echo "============================================"
echo ""
# KOSMOS_ASSUME_YES exists for the image builder, which runs this in a chroot
# with no tty. Without it `read` gets EOF, INSTALL_TOOLS stays empty, the case below
# falls to its default and the script exits 3 -- which the sequencer treats as a
# deliberate decline and reports as SKIPPED, so the build completes "successfully"
# having installed nothing. Explicit opt-in, and no default: an unset variable
# still prompts, so running this by hand is unchanged.
if [ "${KOSMOS_ASSUME_YES:-0}" = "1" ]; then
    INSTALL_TOOLS=y
    echo "  KOSMOS_ASSUME_YES=1 — proceeding without prompting."
else
    read -r -p "Install SDR userspace tools now? (y/N): " INSTALL_TOOLS
fi
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
clone_pinned rtl-sdr-blog "$RTLSDR_URL" "$RTLSDR_SHA" "$RTLSDR_TAG"
mkdir -p build && cd build
cmake ../ -DINSTALL_UDEV_RULES=ON -DDETACH_KERNEL_DRIVER=ON
make -j"$(nproc)" && sudo make install
sudo ldconfig
record_pin rtl-sdr-blog "$RTLSDR_SHA" "$RTLSDR_TAG" "$RTLSDR_URL"
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
clone_pinned rtl_433 "$RTL433_URL" "$RTL433_SHA" "$RTL433_TAG"
mkdir -p build && cd build
cmake .. && make -j"$(nproc)" && sudo make install
record_pin rtl_433 "$RTL433_SHA" "$RTL433_TAG" "$RTL433_URL"
echo "       Done."

echo ""
echo "[5/6] Installing dump1090 (ADS-B decoder)..."
# NOTE: dump1090 requires libncurses-dev (included in step 1 deps).
# Without it, the build fails with "curses.h: No such file or directory."
clone_pinned dump1090 "$DUMP1090_URL" "$DUMP1090_SHA" "$DUMP1090_TAG"
make -j"$(nproc)" BLADERF=no HACKRF=no
sudo cp dump1090 /usr/local/bin/
record_pin dump1090 "$DUMP1090_SHA" "$DUMP1090_TAG" "$DUMP1090_URL"
echo "       Done."

echo ""
echo "[6/6] Installing satellite tools..."
# NOTE: 'predict' is not in Pi OS repos — must be built from source, and it
# ships a curses installer (installer.c) rather than a `make install` target.
#
# That installer CANNOT run unattended. It clears the screen and blocks on a
# licence Y/N, so in a chroot with no tty it dies with
# "Error opening terminal: unknown". That is exactly how the first image build
# found this, on 2026-08-23 — the step had been written and linted for weeks
# and had never once been executed.
#
# Reproduced faithfully here rather than driven with fake keystrokes, which
# would break the moment the prompt text changed. Everything installer.c
# actually does is: read .version, write predict.h, compile predict.c, and put
# the binary on the PATH. Its two interactive flourishes are a licence prompt
# and an audio probe, and the probe only decides whether to build the optional
# vocalizer — it needs /dev/dsp, which no modern system has, so the installer
# would have skipped it too. Hence soundcard=0, which is the same value it
# would have written.
#
# ONE DELIBERATE DIFFERENCE: the installer symlinks /usr/local/bin/predict back
# into the source tree and bakes that path into predict.h. Fine on a
# workstation; wrong in an image, where the build tree is scratch that does not
# ship. The tree is installed to a stable location and the binary copied, so
# nothing on the running system points at a temporary directory.
clone_pinned predict "$PREDICT_URL" "$PREDICT_SHA" "$PREDICT_TAG"

PREDICT_DIR="/usr/local/share/predict"
if [ ! -f .version ]; then
    echo "ERROR: predict source has no .version file — installer.c reads it," >&2
    echo "       so its absence means the pin points at an unexpected tree." >&2
    exit 1
fi
PREDICT_VERSION=$(tr -d '[:space:]' < .version)

sudo rm -rf "$PREDICT_DIR"
sudo mkdir -p "$PREDICT_DIR"
sudo cp -a . "$PREDICT_DIR/"
sudo rm -rf "$PREDICT_DIR/.git"

sudo tee "$PREDICT_DIR/predict.h" > /dev/null <<EOF
/* Generated by KosmOS 02c-sdr-userspace.sh, replacing predict's curses installer */

char *predictpath={"$PREDICT_DIR/"}, soundcard=0, *version={"$PREDICT_VERSION"};
EOF

sudo sh -c "cd '$PREDICT_DIR' && cc -Wall -O3 -s -fomit-frame-pointer \
    predict.c -lm -lncurses -pthread -o predict" ||
    { echo "ERROR: predict failed to compile." >&2; exit 1; }

sudo install -m 0755 "$PREDICT_DIR/predict" /usr/local/bin/predict
echo "       predict $PREDICT_VERSION installed to /usr/local/bin/predict"
record_pin predict "$PREDICT_SHA" "$PREDICT_TAG" "$PREDICT_URL"

# gpredict needs a desktop environment — skip if headless
if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    sudo apt-get install -y gpredict
    echo "       gpredict installed (GUI available)."
else
    echo "       Skipping gpredict (no display detected). Install later with: sudo apt install gpredict"
fi

# Seed TLE data, for the tools that read this directory (gpredict, SatDump).
#
# Deliberately not checksummed: elements change every few hours by design, so a
# pinned digest would be wrong by the next pass. Freshness is the property that
# matters, not immutability.
#
# GROUP=weather, not GROUP=noaa. There is no "noaa" group: that query returns
# HTTP 200 with the body 'Invalid query: ... (GROUP=noaa not found)', so wget
# succeeds, writes 61 bytes of prose into noaa.tle, and the || branch below never
# fires. Verified against the live API 2026-07-29.
#
# This is a seed, not the mechanism. Two things it does not do:
#   - it does not write ~/.predict/predict.tle, the only file predict reads
#   - GROUP=weather does not contain NOAA 15, 18 or 19 — only the JPSS birds.
#     The APT satellites are reachable only by catalogue number.
# automation/tle-updater.sh handles both, and validates every download against
# the TLE line checksums so an error page cannot be installed as elements.
mkdir -p "$HOME/.config/satellite-tle"
echo "       Downloading seed TLE data..."
wget -q -O "$HOME/.config/satellite-tle/weather.tle" \
    "https://celestrak.org/NORAD/elements/gp.php?GROUP=weather&FORMAT=tle" 2>/dev/null || \
    echo "       (TLE download failed — run automation/tle-updater.sh later)"
wget -q -O "$HOME/.config/satellite-tle/amateur.tle" \
    "https://celestrak.org/NORAD/elements/gp.php?GROUP=amateur&FORMAT=tle" 2>/dev/null || true
echo "       For predict, and for NOAA 15/18/19, run: automation/tle-updater.sh"

echo ""
echo "       Pinned revisions recorded in $MANIFEST"
