#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS 03c — SDR++
# ============================================================================
# Run this ON THE PI. Builds SDR++ from source at a pinned commit.
#
# SDR++ is the interactive receiver: waterfall, multi-VFO, plugin architecture.
# It is the tool you reach for to find out what is actually on a band before
# pointing a decoder at it — live capture with a visible spectrum, rather than a
# pipeline you have to configure blind.
#
# EXIT CODES: 0 built and installed, 3 declined by the user.
#
# NOT YET RUN ON HARDWARE — written from upstream's build instructions at the
# pinned commit, linted and reviewed, but no build executed. It needs the Pi.
#
# HEADLESS NOTE: SDR++ is a GUI application and needs a display to run. It still
# builds fine on a headless box, and it can be driven over X forwarding or VNC,
# or built now and used the day the Pi gets a screen. If you want a headless
# receiver instead, that is `sdrpp --server` territory, or SatDump's CLI.
# ============================================================================

set -euo pipefail

# === PINNED VERSION =========================================================
# Pinned to a dated master commit rather than a tag, deliberately:
#
#   Upstream's only release tag is literally named "nightly" and it moves, so
#   pinning it would pin nothing. The newest numbered tag, 1.0.4, is from
#   2021-10-17 — years behind, predating most of the current source modules, and
#   not a sensible target on a 2026 system.
#
#   So the pin is master at 8c9f5ee (2026-07-05). Reproducible, verified after
#   checkout, and honest about being a snapshot of a rolling project rather than
#   a release. Re-pin by bumping both values together after reading the log.
SDRPP_URL="https://github.com/AlexandreRouma/SDRPlusPlus"
SDRPP_TAG=""
SDRPP_SHA="8c9f5ee8fe405775bfcd62c8c8f8c0fc928a64af"

SRC_ROOT="/tmp"
MANIFEST="/usr/local/share/molniya/build-manifest.txt"

# Clone at an exact commit and verify. Condensed from 02c-sdr-userspace.sh,
# where the reasoning is written out in full.
clone_pinned() {
    local name="$1" url="$2" sha="$3" tag="${4:-}"
    local dir="$SRC_ROOT/$name"

    if [ -z "$name" ] || [ -z "$url" ] || [ -z "$sha" ]; then
        echo "ERROR: clone_pinned requires name, url and sha" >&2
        exit 1
    fi

    rm -rf "$dir"
    mkdir -p "$dir"
    cd "$dir"

    git -c init.defaultBranch=main init -q
    git remote add origin "$url"

    if ! git fetch -q --depth 1 origin "$sha" 2>/dev/null; then
        if [ -z "$tag" ]; then
            echo "ERROR: $name — server refused a fetch of $sha, no tag fallback" >&2
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
        exit 1
    fi

    echo "       $name @ ${sha:0:12}${tag:+ ($tag)} [verified]"
}

record_pin() {
    local name="$1" sha="$2" tag="$3" url="$4"
    sudo mkdir -p "$(dirname "$MANIFEST")"
    printf '%s  %-14s %s  %-8s %s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$name" "$sha" "${tag:--}" "$url" \
        | sudo tee -a "$MANIFEST" > /dev/null
}

# Same requirement, and the same reason, as 03b: the RTL-SDR source module links
# librtlsdr, and only the RTL-SDR Blog fork that 02c puts in /usr/local drives a
# v4 dongle. Debian's librtlsdr-dev is deliberately not installed.
require_local_librtlsdr() {
    if [ -f /usr/local/include/rtl-sdr.h ]; then
        return 0
    fi

    echo "ERROR: /usr/local/include/rtl-sdr.h is missing." >&2
    echo "       It comes from the RTL-SDR Blog fork of librtlsdr, installed by" >&2
    echo "       02c-sdr-userspace.sh, and it is the only build that supports the" >&2
    echo "       v4 dongle. Run ./02c-sdr-userspace.sh first." >&2
    exit 1
}

echo ""
echo "============================================"
echo "  SDR++"
echo "============================================"
echo ""
echo "  Pinned at master ${SDRPP_SHA:0:12} (2026-07-05)"
echo "  GUI application — builds headless, needs a display to run."
echo ""
# MOLNIYA_ASSUME_YES exists for the image builder, which runs this in a chroot
# with no tty. Without it `read` gets EOF, INSTALL_SDRPP stays empty, the case below
# falls to its default and the script exits 3 -- which the sequencer treats as a
# deliberate decline and reports as SKIPPED, so the build completes "successfully"
# having installed nothing. Explicit opt-in, and no default: an unset variable
# still prompts, so running this by hand is unchanged.
if [ "${MOLNIYA_ASSUME_YES:-0}" = "1" ]; then
    INSTALL_SDRPP=y
    echo "  MOLNIYA_ASSUME_YES=1 — proceeding without prompting."
else
    read -r -p "Build and install SDR++? (y/N): " INSTALL_SDRPP
fi
case "${INSTALL_SDRPP,,}" in
    y|yes) ;;
    *)
        echo "       Skipped. Nothing built."
        exit 3
        ;;
esac

require_local_librtlsdr

echo ""
echo "[1/4] Installing build dependencies..."
# Upstream lists cmake, fftw3, glfw, libvolk and zstd as the core set, plus a
# per-module dependency for each source and sink you build. librtaudio-dev
# covers the default audio sink; librtlsdr comes from /usr/local, not apt.
sudo apt-get update
sudo apt-get install -y \
    git build-essential cmake g++ pkgconf \
    libfftw3-dev libglfw3-dev libvolk-dev libzstd-dev \
    librtaudio-dev

echo ""
echo "[2/4] Fetching SDR++ at its pinned commit..."
clone_pinned sdrpp "$SDRPP_URL" "$SDRPP_SHA" "$SDRPP_TAG"

echo ""
echo "[3/4] Building..."
mkdir -p build && cd build
# OPT_BUILD_SOAPY_SOURCE=OFF: upstream marks the Soapy source deprecated and
# ships it off by default on every platform. Leaving it off also avoids the
# multiple-Soapy-module conflict upstream's own FAQ warns about — RTL-SDR
# reaches SDR++ through its native rtl_sdr_source and librtlsdr instead.
#
# OPT_BUILD_PLUTOSDR_SOURCE=OFF: upstream defaults it ON and it needs libiio,
# which is not in the dependency list above. That is what broke the first image
# build (2026-08-23) — CMake configure failed with "Package 'libiio', required
# by 'virtual:world', not found". The PlutoSDR is an Analog Devices eval board;
# MolniyaOS is an RTL-SDR ground station, so the fix is to stop building a driver
# for hardware the project does not support, not to install libiio and
# libad9361 into every image for a device nobody has. Same reasoning, and the
# same remedy, as the Soapy line above.
#
# ⚠️ The real finding underneath this is worse than one missing package, and is
# NOT fixed here. CMake reported finding libairspy, libairspyhf and libhackrf —
# none of which this script installs. They arrive as transitive dependencies of
# GNU Radio and SatDump, installed by 03a and 03b just before this runs. So
# WHICH SDR++ modules end up in the image is decided by what earlier scripts
# happened to drag in: reorder the stages, or let an upstream bump change
# SatDump's dependencies, and SDR++ silently gains or loses hardware support
# with nothing in the build log flagging it. Making the module set explicit —
# every OPT_BUILD_* named ON or OFF here — is the actual fix. See ROADMAP 4a.
cmake -DCMAKE_BUILD_TYPE=Release \
    -DOPT_BUILD_SOAPY_SOURCE=OFF \
    -DOPT_BUILD_PLUTOSDR_SOURCE=OFF ..
make -j"$(nproc)"

echo ""
echo "[4/4] Installing..."
sudo make install
sudo ldconfig
record_pin sdrpp "$SDRPP_SHA" "$SDRPP_TAG" "$SDRPP_URL"

echo ""
if command -v sdrpp > /dev/null 2>&1; then
    echo "       sdrpp on PATH: $(command -v sdrpp)"
else
    echo "       WARNING: sdrpp is not on PATH after install."
fi
echo ""
echo "       On a machine with a display:  sdrpp"
echo "       Over SSH with X forwarding:   ssh -X, then sdrpp"
echo ""
echo "       If the module list is empty at startup, SDR++ is reading a config"
echo "       whose module paths point at a build tree that no longer exists —"
echo "       delete ~/.config/sdrpp/config.json and let it regenerate."
