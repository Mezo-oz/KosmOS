#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — read or set the CPU scaling governor on every core
# ============================================================================
#   governor.sh read          prints cpu0's governor on stdout
#   governor.sh set <name>    sets it on every core, then verifies
#
# Executable helper, not a sourced library — see the extraction rule in
# ROADMAP.md. Setting a governor changes system state rather than shell state,
# so a subprocess does the job perfectly well.
#
# The benchmark pins `performance` before every run because the kernel's
# CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE does not survive Pi OS boot, and
# ondemand adds frequency-ramp delay on top of scheduling latency.
# `automation/install-governor.sh` makes it permanent; this is the per-run
# belt-and-braces, and the restore on exit.
# ============================================================================

set -uo pipefail

GOV_GLOB=(/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor)
CPU0=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor

case "${1:-read}" in
    read)
        cat "$CPU0" 2>/dev/null || echo unknown
        ;;
    set)
        want="${2:-}"
        [ -n "$want" ] || { echo "usage: $0 set <governor>" >&2; exit 2; }
        for p in "${GOV_GLOB[@]}"; do
            # An unexpanded glob arrives here as a literal on a kernel without
            # cpufreq; skip rather than writing to a path that does not exist.
            [ -e "$p" ] || continue
            echo "$want" | sudo tee "$p" > /dev/null 2>&1 || true
        done
        got=$(cat "$CPU0" 2>/dev/null || echo unknown)
        echo "$got"
        [ "$got" = "$want" ]
        ;;
    *)
        echo "usage: $0 {read|set <governor>}" >&2
        exit 2
        ;;
esac
