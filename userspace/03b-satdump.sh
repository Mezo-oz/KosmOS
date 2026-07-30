#!/usr/bin/env bash
# ============================================================================
# KosmOS 03b — SatDump
# ============================================================================
# Run this ON THE PI. Builds SatDump from source at a pinned release.
#
# SatDump is the centrepiece of the SATCOM focus: it takes a capture from
# antenna to finished image in one pipeline, and it covers the formats this
# project cares about — NOAA APT and HRPT, Meteor-M LRPT, MetOp, GOES HRIT and
# EMWIN, FengYun. Nothing else in the SDR ecosystem replaces it.
#
# EXIT CODES: 0 built and installed, 3 declined by the user.
#
# TIME: a substantial C++ build. Budget an hour on four Cortex-A76 cores and do
# not run it over a flaky SSH session — use tmux or screen.
#
# NOT YET RUN ON HARDWARE. This script is written from upstream's own Debian
# instructions at the pinned commit; it has been linted and reviewed but no
# build has been executed, because that needs the Pi. Treat the first run as the
# test.
# ============================================================================

set -euo pipefail

# === PINNED VERSION =========================================================
# SatDump 1.2.2, the latest tagged release (2024-11-29), read from upstream
# 2026-07-29. Master is far newer, and upstream's "nightly" tag moves — which is
# exactly why it is not what gets pinned. See 02c-sdr-userspace.sh for the full
# rationale on pinning commits rather than tags or tarball checksums.
SATDUMP_URL="https://github.com/SatDump/SatDump"
SATDUMP_TAG="1.2.2"
SATDUMP_SHA="7aef0fe8441bc3eb440b1b6ba053556da5e40991"

SRC_ROOT="/tmp"
MANIFEST="/usr/local/share/kosmos/build-manifest.txt"

# Install prefix. Upstream documents -DCMAKE_INSTALL_PREFIX=/usr; this uses
# /usr/local instead, which is where locally built software belongs and keeps
# dpkg's tree free of files it does not own. If SatDump cannot find its
# pipelines or resources after install, this is the first flag to change back.
INSTALL_PREFIX="/usr/local"

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
        echo "       A moved tag or a force-push upstream is the usual cause." >&2
        exit 1
    fi

    # No submodule init on purpose. SatDump declares exactly one submodule at
    # this commit, android/deps, and it is only used for Android builds — a
    # recursive init would download it for nothing.

    echo "       $name @ ${sha:0:12}${tag:+ ($tag)} [verified]"
}

record_pin() {
    local name="$1" sha="$2" tag="$3" url="$4"
    sudo mkdir -p "$(dirname "$MANIFEST")"
    printf '%s  %-14s %s  %-8s %s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$name" "$sha" "${tag:--}" "$url" \
        | sudo tee -a "$MANIFEST" > /dev/null
}

# 02c installs the RTL-SDR Blog fork of librtlsdr into /usr/local, and that fork
# is what supports the v4 dongle. Building SatDump without it produces a binary
# that either has no RTL-SDR support at all or links Debian's osmocom librtlsdr,
# which cannot drive a v4 — and you would not find out until a pass was already
# overhead.
require_local_librtlsdr() {
    if [ -f /usr/local/include/rtl-sdr.h ]; then
        return 0
    fi

    echo "ERROR: /usr/local/include/rtl-sdr.h is missing." >&2
    echo "" >&2
    echo "       That header comes from the RTL-SDR Blog fork of librtlsdr, which" >&2
    echo "       02c-sdr-userspace.sh installs and which is the only build that" >&2
    echo "       supports the RTL-SDR Blog v4 dongle. Debian's librtlsdr-dev is" >&2
    echo "       the osmocom original and is deliberately NOT installed here:" >&2
    echo "       two librtlsdr builds sharing one SONAME is how you end up with" >&2
    echo "       'no supported devices found' and a working dongle plugged in." >&2
    echo "" >&2
    echo "       Run ./02c-sdr-userspace.sh first." >&2
    exit 1
}

echo ""
echo "============================================"
echo "  SatDump"
echo "============================================"
echo ""
echo "  Pinned at $SATDUMP_TAG (${SATDUMP_SHA:0:12})"
echo "  Prefix:   $INSTALL_PREFIX"
echo "  This is a long build. Run it under tmux or screen."
echo ""
read -r -p "Build and install SatDump? (y/N): " INSTALL_SATDUMP
case "${INSTALL_SATDUMP,,}" in
    y|yes) ;;
    *)
        echo "       Skipped. Nothing built."
        exit 3
        ;;
esac

require_local_librtlsdr

echo ""
echo "[1/4] Installing build dependencies..."
# From upstream's Debian dependency list at the pinned commit, minus two groups:
#
#   librtlsdr-dev  — deliberately omitted, see require_local_librtlsdr above.
#   Analog/BladeRF/OpenCL-vendor packages — omitted because no such hardware is
#     in this build's scope and each drags in dependencies. SatDump's cmake
#     detects what is present, so adding a radio later means installing its
#     -dev package and rebuilding, nothing more.
#
# libairspy/libairspyhf/libhackrf ARE included: they are small, and the ROADMAP
# expects a HackRF upgrade.
sudo apt-get update
sudo apt-get install -y \
    git build-essential cmake g++ pkgconf \
    libfftw3-dev libpng-dev libtiff-dev libjemalloc-dev libcurl4-openssl-dev \
    libvolk-dev libnng-dev \
    libglfw3-dev zenity \
    portaudio19-dev libzstd-dev libhdf5-dev libomp-dev ocl-icd-opencl-dev \
    libhackrf-dev libairspy-dev libairspyhf-dev

echo ""
echo "[2/4] Fetching SatDump at its pinned commit..."
clone_pinned satdump "$SATDUMP_URL" "$SATDUMP_SHA" "$SATDUMP_TAG"

echo ""
echo "[3/4] Building (this is the long part)..."
mkdir -p build && cd build
# The GUI is built even on a headless box: it costs build time but no runtime,
# and it is what you want the day the Pi gets a display or an X forward. Add
# -DBUILD_GUI=OFF here to skip it.
cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" ..
make -j"$(nproc)"

echo ""
echo "[4/4] Installing..."
sudo make install
sudo ldconfig
record_pin satdump "$SATDUMP_SHA" "$SATDUMP_TAG" "$SATDUMP_URL"

echo ""
if command -v satdump > /dev/null 2>&1; then
    echo "       satdump on PATH: $(command -v satdump)"
else
    echo "       WARNING: satdump is not on PATH. With prefix $INSTALL_PREFIX the"
    echo "                binary should be at $INSTALL_PREFIX/bin/satdump."
fi
echo ""
echo "       Try:  satdump --help"
echo "             satdump live --help     # pipeline names and source options"
echo ""
echo "       If SatDump starts but reports missing pipelines or resources, the"
echo "       install prefix is the cause — see INSTALL_PREFIX at the top of this"
echo "       script."
