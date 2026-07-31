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
if [ -f /proc/config.gz ] && zcat /proc/config.gz 2>/dev/null \
    | grep -qx "CONFIG_PREEMPT_RT=y"; then
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
