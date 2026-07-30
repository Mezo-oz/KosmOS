#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# KosmOS 03a — GNU Radio + gr-osmosdr + SoapySDR
# ============================================================================
# Run this ON THE PI. Installs the DSP framework and the hardware abstraction
# layer from the distribution archive, at pinned versions.
#
# WHY APT AND NOT A SOURCE BUILD:
#   Every other build in KosmOS is from source, deliberately. GNU Radio is the
#   exception, for three reasons:
#
#     1. Cost. GNU Radio's dependency chain (Boost, volk, gmp, thrift, Qt,
#        gr-blocks codegen) dwarfs everything else in this repo. On four
#        Cortex-A76 cores a full source build is a multi-hour job that has to be
#        redone on every version bump, and it buys nothing measurable here.
#     2. There is no version argument for it. Debian ships 3.10.x, which is the
#        current stable series — this is not a case where the distro package is
#        years behind.
#     3. It is still pinned and still verified. apt authenticates every package
#        against the archive's signed InRelease file, which is a stronger supply
#        chain than a git clone over HTTPS, and the exact version installed is
#        recorded to the build manifest.
#
#   If a future decoder needs a GNU Radio feature Debian's build lacks, that is
#   the moment to reconsider — not before.
#
# WHAT IS DELIBERATELY *NOT* INSTALLED — soapysdr-module-rtlsdr:
#   SoapySDR loads every module it finds, and multiple modules claiming the same
#   hardware is a known crash and double-enumeration source (SDR++'s own FAQ
#   names it). RTL-SDR already reaches every tool here through librtlsdr
#   directly — specifically the RTL-SDR Blog fork that 02c installs into
#   /usr/local, which is the build that supports the v4 dongle. Debian's
#   librtlsdr is the osmocom original and does not. Adding a Soapy module linked
#   against the wrong librtlsdr is how you get "no supported devices found" with
#   a working dongle plugged in.
#
#   SoapySDR itself is installed because it is the HAL the ROADMAP wants for the
#   eventual HackRF, and because SatDump can use it for other radios.
#
# EXIT CODES: 0 installed, 3 declined by the user.
# ============================================================================

set -euo pipefail

# === PINNED VERSIONS ========================================================
#
# Captured from the Debian archive 2026-07-29. Both suites are listed because
# Raspberry Pi OS trails Debian: a bookworm-era image and a trixie-era image are
# both plausible on a Pi 5, and the correct pin is different for each.
#
# THE binNMU CAVEAT, worth understanding before the first run:
#   Debian rebuilds packages per-architecture without touching the source, and
#   those rebuilds get a "+b1"-style suffix — so arm64 may legitimately carry
#   3.10.12.0-1+b1 where the source version is 3.10.12.0-1. That is the same
#   source, so apt_install_pinned() accepts "<pin>" and "<pin>+bN" as a match
#   and rejects anything else. These pins were read from the archive rather than
#   from the Pi, so a first run may still find a revision that is neither; the
#   default is then a loud warning and the candidate version, recorded in the
#   manifest. Set KOSMOS_STRICT_PINS=1 to make that an error instead.
KOSMOS_STRICT_PINS="${KOSMOS_STRICT_PINS:-0}"

MANIFEST="/usr/local/share/kosmos/build-manifest.txt"

# Resolve the pin set for the running suite. Parsed rather than sourced: reading
# a value out of /etc/os-release does not require executing it in this shell.
SUITE=""
if [ -r /etc/os-release ]; then
    SUITE=$(awk -F= '/^VERSION_CODENAME=/ { gsub(/"/, "", $2); print $2 }' \
        /etc/os-release)
fi

case "$SUITE" in
    bookworm)
        PIN_GNURADIO="3.10.5.1-3"
        PIN_GROSMOSDR="0.2.4-1"
        PIN_SOAPYSDR="0.8.1-3"
        ;;
    trixie)
        PIN_GNURADIO="3.10.12.0-1"
        PIN_GROSMOSDR="0.2.6-4"
        PIN_SOAPYSDR="0.8.1-5"
        ;;
    *)
        PIN_GNURADIO=""
        PIN_GROSMOSDR=""
        PIN_SOAPYSDR=""
        ;;
esac

# Install one package, checking the archive's candidate against the pin first.
#
#   apt_install_pinned <package> <pinned-version-or-empty>
#
# An empty pin means "this suite has no pin recorded" — install the candidate
# and say so, rather than refusing to work on a distribution nobody has pinned
# yet.
apt_install_pinned() {
    local pkg="$1" want="$2" cand

    cand=$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2}')

    if [ -z "$cand" ] || [ "$cand" = "(none)" ]; then
        echo "ERROR: $pkg is not available from any configured archive." >&2
        exit 1
    fi

    if [ -z "$want" ]; then
        echo "       $pkg: no pin for suite '${SUITE:-unknown}', taking $cand"
        sudo apt-get install -y "$pkg"
        return
    fi

    case "$cand" in
        "$want")
            echo "       $pkg: $cand [pinned]"
            sudo apt-get install -y "$pkg=$want"
            ;;
        "$want"+b*)
            # Architecture rebuild of the pinned source version. Same source,
            # different build; accepted, and the exact version is recorded.
            echo "       $pkg: $cand [pinned $want, arch rebuild]"
            sudo apt-get install -y "$pkg=$cand"
            ;;
        *)
            if [ "$KOSMOS_STRICT_PINS" = "1" ]; then
                echo "ERROR: $pkg pin mismatch — pinned $want, archive offers $cand" >&2
                echo "       Either update the pin in this script after reading the" >&2
                echo "       changelog, or re-run with KOSMOS_STRICT_PINS=0 to take" >&2
                echo "       the archive's version and have it recorded instead." >&2
                exit 1
            fi
            echo ""
            echo "       WARNING: $pkg pin mismatch."
            echo "                pinned:  $want (suite ${SUITE:-unknown})"
            echo "                archive: $cand"
            echo "                Taking $cand and recording it. Update the pin in"
            echo "                this script to make the next build reproducible."
            echo ""
            sudo apt-get install -y "$pkg"
            ;;
    esac
}

# Record what apt actually installed, which is the only version that matters
# afterwards.
record_apt() {
    local pkg="$1" ver
    ver=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo "unknown")
    sudo mkdir -p "$(dirname "$MANIFEST")"
    printf '%s  %-14s %-24s apt      %s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$pkg" "$ver" "${SUITE:-unknown}" \
        | sudo tee -a "$MANIFEST" > /dev/null
}

echo ""
echo "============================================"
echo "  GNU Radio + SoapySDR"
echo "============================================"
echo ""
echo "  Suite detected: ${SUITE:-unknown}"
if [ -z "$PIN_GNURADIO" ]; then
    echo "  No pin set recorded for this suite — versions will be taken from the"
    echo "  archive and recorded to the manifest. See the header for how to add a"
    echo "  pin set."
fi
echo ""
read -r -p "Install GNU Radio, gr-osmosdr and SoapySDR? (y/N): " INSTALL_GR
case "${INSTALL_GR,,}" in
    y|yes) ;;
    *)
        echo "       Skipped. Nothing installed."
        exit 3
        ;;
esac

echo ""
echo "[1/3] Updating package lists..."
sudo apt-get update

echo ""
echo "[2/3] Installing pinned packages..."
apt_install_pinned gnuradio        "$PIN_GNURADIO"
apt_install_pinned gr-osmosdr      "$PIN_GROSMOSDR"
apt_install_pinned libsoapysdr-dev "$PIN_SOAPYSDR"
apt_install_pinned soapysdr-tools  "$PIN_SOAPYSDR"
apt_install_pinned python3-soapysdr "$PIN_SOAPYSDR"

for pkg in gnuradio gr-osmosdr libsoapysdr-dev soapysdr-tools python3-soapysdr; do
    record_apt "$pkg"
done

echo ""
echo "[3/3] Verifying..."

# gnuradio-config-info is GNU Radio's own version reporter. Failing to run it is
# not fatal here -- the package is installed either way, and a headless box
# missing a Qt dependency would still have a working gr-python.
if command -v gnuradio-config-info > /dev/null 2>&1; then
    echo "       GNU Radio:  $(gnuradio-config-info --version 2>/dev/null || echo '(version query failed)')"
else
    echo "       WARNING: gnuradio-config-info not on PATH after install."
fi

if command -v SoapySDRUtil > /dev/null 2>&1; then
    echo "       SoapySDR:   $(SoapySDRUtil --info 2>/dev/null | awk '/API Version/ {print $NF; exit}' || echo unknown)"
    # Modules found, not devices: with no Soapy module installed by design, an
    # empty list here is the expected and correct result.
    echo "       Soapy modules present:"
    SoapySDRUtil --info 2>/dev/null | sed -n 's/^Module found: /         /p' || true
else
    echo "       WARNING: SoapySDRUtil not on PATH after install."
fi

echo ""
echo "       Done. Versions recorded in $MANIFEST"
