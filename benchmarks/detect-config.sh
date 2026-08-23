#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# KosmOS — which benchmark configuration is this boot?
# ============================================================================
# Prints one of A, B or C on stdout. Exit 0 when detected, 1 when it had to
# guess. Executable helper, not a sourced library — see the extraction rule in
# ROADMAP.md.
#
#   A  stock Pi kernel
#   B  KosmOS PREEMPT_RT, no core isolation
#   C  KosmOS PREEMPT_RT + nohz_full
#
# Detected rather than typed in because a mislabelled result set is worse than
# no result set: it looks like data.
# ============================================================================

set -uo pipefail

rt=0
nohz=0

# /proc/config.gz is what was actually compiled and is the strongest evidence.
# uname -v carries the build banner and covers kernels without IKCONFIG_PROC.
# /sys/kernel/realtime is the legacy out-of-tree patchset marker and does not
# exist on mainline RT since 6.12 — checking only for it reports NOT DETECTED on
# exactly the kernel this project builds.
#
# Process substitution rather than `zcat ... | grep -qx`: with pipefail set,
# grep -q exits on the first match while zcat is still writing (~242 KB through
# a 64 KB pipe buffer), zcat takes SIGPIPE, and the pipeline reports failure
# despite the match. This branch could therefore never be taken. Found and
# measured 2026-08-23. No published result is affected — the uname -v fallback
# agrees on both kernels this script has ever run on, and detect-config.sh was
# re-run on pi-server after the fix and still prints C — but "strongest evidence
# first" was not true until now.
if [ -f /proc/config.gz ] &&
    grep -qx "CONFIG_PREEMPT_RT=y" <(zcat /proc/config.gz 2>/dev/null); then
    rt=1
elif uname -v | grep -q "PREEMPT_RT"; then
    rt=1
elif [ -f /sys/kernel/realtime ] && [ "$(cat /sys/kernel/realtime)" = "1" ]; then
    rt=1
fi

if grep -q "nohz_full=" /proc/cmdline; then
    nohz=1
fi

if [ "$rt" -eq 0 ]; then
    echo "A"
elif [ "$nohz" -eq 0 ]; then
    echo "B"
else
    echo "C"
fi
