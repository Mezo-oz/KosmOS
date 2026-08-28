#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS Post-Install — sequencer
# ============================================================================
# Run this ON THE PI after rebooting into the custom kernel.
#
# This script does no work of its own. It sequences four job scripts that sit
# beside it, each of which is runnable on its own:
#
#   02a-verify-kernel.sh   verify the running kernel (read-only, installs nothing)
#   02b-bench-tools.sh     rt-tests + stress-ng, behind its own prompt
#   02c-sdr-userspace.sh   librtlsdr / rtl_433 / dump1090 / predict, own prompt
#   02d-locale-ru.sh       optional Russian locale (personal preference)
#
# WHY IT WAS SPLIT:
#   The single script this replaces did those four unrelated jobs in 399 lines
#   — one line under the project's 400-line cap — so nothing could be added to
#   any of the four without splitting first. Running this script does what
#   running the old one did, in the same order, with the same prompts.
#
#   Splitting also makes the useful subsets reachable directly. Verification is
#   the one you run most often and the only one that is safe on any kernel:
#
#     ./02a-verify-kernel.sh          # checks only, installs nothing
#     ./02b-bench-tools.sh            # benchmark tooling without the SDR stack
#
# INHERITED BEHAVIOUR, PRESERVED DELIBERATELY:
#   Answering "n" to the SDR prompt also skips the locale step, because in the
#   original the locale block sat inside the same gated section. 02c signals
#   that decline with exit code 3 and this script stops there. To make the two
#   independent, give 02d its own prompt and delete the EXIT_DECLINED branch.
# ============================================================================

set -euo pipefail

# Resolved from this script's own path so both layouts work: the repo, where
# these live in userspace/, and the kernel tarball, which flattens all of them
# into the package root. Either way the job scripts sit beside this one.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 02c's "the user declined the install" exit code. Any other non-zero exit from
# a job script is a real failure and propagates unchanged.
EXIT_DECLINED=3

# Run one job script. Missing scripts are fatal and diagnosed here rather than
# surfacing as a bare "No such file or directory" from bash.
run_job() {
    local script="$SELF_DIR/$1"

    if [ ! -f "$script" ]; then
        echo "ERROR: missing job script: $script" >&2
        echo "       02-post-install.sh only sequences — the work lives in the" >&2
        echo "       02a-02d scripts, which must sit beside it. If you copied" >&2
        echo "       one script over by hand, copy the rest too." >&2
        exit 1
    fi

    # Invoked through bash rather than executed directly. The tarball extracts
    # with whatever modes tar was handed, and a lost +x bit should not be the
    # difference between a working install and a broken one.
    bash "$script"
}

run_job 02a-verify-kernel.sh
run_job 02b-bench-tools.sh

# 02c owns its own prompt, so its exit code is the only way to know whether the
# user wanted the install at all.
SDR_RC=0
run_job 02c-sdr-userspace.sh || SDR_RC=$?

if [ "$SDR_RC" -eq "$EXIT_DECLINED" ]; then
    exit 0
elif [ "$SDR_RC" -ne 0 ]; then
    exit "$SDR_RC"
fi

run_job 02d-locale-ru.sh

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
