#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# KosmOS 03 — SATCOM Stack (Phase 1a/1c) — sequencer
# ============================================================================
# Run this ON THE PI, from a clone of this repository. Unlike the 02 set, these
# scripts are NOT packaged into the kernel tarball: they are not part of getting
# the kernel running, and bundling a Phase-1 userspace build into the kernel
# payload would muddle what that tarball is for. On the Pi:
#
#   git clone https://github.com/Mezo-oz/KosmOS
#   ./KosmOS/userspace/03-satcom-stack.sh
#
# It sequences three jobs, each with its own prompt and each runnable alone:
#
#   03a-gnuradio-stack.sh   GNU Radio + gr-osmosdr + SoapySDR   (apt, pinned)
#   03b-satdump.sh          SatDump                             (source, pinned)
#   03c-sdrpp.sh            SDR++                               (source, pinned)
#
# Declining one does not stop the others — they are independent, and each is a
# long build you may well want to run on separate evenings. A job that exits 3
# means "the user said no"; anything else non-zero is a real failure and stops
# the run, because a half-built stack is worth knowing about immediately.
#
# PREREQUISITE: 02c-sdr-userspace.sh must have run first. It installs the
# RTL-SDR Blog fork of librtlsdr into /usr/local, which is what makes an RTL-SDR
# Blog v4 dongle work. 03b and 03c check for it and refuse to build without it,
# rather than producing binaries that cannot see the hardware.
#
# TIME: budget hours, not minutes. SatDump and SDR++ are both substantial C++
# builds on four Cortex-A76 cores. Neither has been run on hardware yet — see
# BENCHMARKS.md for what is verified and what is not.
# ============================================================================

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# "The user declined this job." Shared with the 02 set for consistency.
EXIT_DECLINED=3

# Jobs that ran, and jobs that were skipped, for the summary at the end.
INSTALLED=()
SKIPPED=()

run_job() {
    local script="$SELF_DIR/$1"
    local label="$2"
    local rc=0

    if [ ! -f "$script" ]; then
        echo "ERROR: missing job script: $script" >&2
        exit 1
    fi

    bash "$script" || rc=$?

    if [ "$rc" -eq 0 ]; then
        INSTALLED+=("$label")
    elif [ "$rc" -eq "$EXIT_DECLINED" ]; then
        SKIPPED+=("$label")
    else
        echo "" >&2
        echo "ERROR: $label failed (exit $rc). Stopping here." >&2
        echo "       Nothing after this point has run. Fix the failure and" >&2
        echo "       re-run either this script or $1 on its own — each job is" >&2
        echo "       idempotent, so a repeat run is safe." >&2
        exit "$rc"
    fi
}

echo "============================================"
echo "  KosmOS SATCOM Stack"
echo "============================================"
echo ""

run_job 03a-gnuradio-stack.sh "GNU Radio + SoapySDR"
run_job 03b-satdump.sh        "SatDump"
run_job 03c-sdrpp.sh          "SDR++"

echo ""
echo "============================================"
echo "  SATCOM STACK SUMMARY"
echo "============================================"
echo ""
if [ "${#INSTALLED[@]}" -gt 0 ]; then
    echo "  installed: ${INSTALLED[*]}"
fi
if [ "${#SKIPPED[@]}" -gt 0 ]; then
    echo "  skipped:   ${SKIPPED[*]}"
fi
echo ""
echo "  Revisions installed are recorded in:"
echo "    /usr/local/share/kosmos/build-manifest.txt"
echo ""
echo "  Next: refresh orbital elements, then take a pass."
echo "    automation/tle-updater.sh     # TLEs go stale in days"
echo "    predict -p 'NOAA 19'          # find a pass above 30 degrees"
echo "    satdump live --help           # pipeline names and source options"
echo ""
echo "  Frequencies and antenna choice: config/frequencies.md, config/antennas.md"
echo ""
