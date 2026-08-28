#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — SoC thermal and throttle state
# ============================================================================
# An executable helper, not a sourced library: it returns data on stdout and
# status via its exit code, so the harnesses that call it stay clean under plain
# `shellcheck -S style` with no --external-sources. See the extraction rule in
# ROADMAP.md.
#
#   thermal-state.sh read              one line of state, always exit 0
#   thermal-state.sh flags <hex>       decode a throttle bitmask to words
#   thermal-state.sh wait <C> <secs>   cool to <C>, bounded by <secs>
#
# WHY THE BENCHMARK NEEDS THIS
#   Measured on a stock Pi 5 with the official active cooler, mid kernel build:
#   82.3 C, fan at state 4/4, `throttled=0x80008` — the soft temperature limit
#   engaged, with no cooling headroom left.
#
#   Test 1 runs cyclictest under `stress-ng --cpu 4`, which is the same thermal
#   load. So the benchmark's own workload pushes a stock Pi into throttling, and
#   throttling changes CPU frequency — the exact variable the performance
#   governor was pinned to eliminate. Left unmeasured it would re-enter through
#   the back door, vary between configurations measured at different times, and
#   be silently attributed to the kernel.
#
#   The project targets off-the-shelf hardware, so the answer cannot be "fit a
#   better cooler". It has to be: start every run from the same thermal state,
#   record what that state was, and mark any run the SoC throttled during.
# ============================================================================

set -uo pipefail

# Pi-specific. On anything else this degrades to "unknown" rather than failing,
# so the harnesses stay portable.
read_temp_c() {
    local t
    if [ -r /sys/class/thermal/thermal_zone0/temp ]; then
        t=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
        awk -v v="$t" 'BEGIN { printf "%.1f", v / 1000 }'
    else
        printf 'unknown'
    fi
}

read_throttled() {
    if command -v vcgencmd > /dev/null 2>&1; then
        vcgencmd get_throttled 2>/dev/null | sed 's/^throttled=//' || printf 'unknown'
    else
        printf 'unknown'
    fi
}

# Bit meanings per the Raspberry Pi firmware documentation. The low nibble is
# "right now", the high bits are "has happened since boot" — both matter: a run
# that ends clean may still have throttled in the middle of itself.
decode_flags() {
    local hex="$1" v out=""
    case "$hex" in
        unknown|"") printf 'unknown'; return 0 ;;
    esac
    v=$((hex)) 2>/dev/null || { printf 'unparseable'; return 0; }

    [ $((v & 0x1))     -ne 0 ] && out="$out,undervolt-now"
    [ $((v & 0x2))     -ne 0 ] && out="$out,freq-capped-now"
    [ $((v & 0x4))     -ne 0 ] && out="$out,throttled-now"
    [ $((v & 0x8))     -ne 0 ] && out="$out,softtemp-now"
    [ $((v & 0x10000)) -ne 0 ] && out="$out,undervolt-since-boot"
    [ $((v & 0x20000)) -ne 0 ] && out="$out,freq-capped-since-boot"
    [ $((v & 0x40000)) -ne 0 ] && out="$out,throttled-since-boot"
    [ $((v & 0x80000)) -ne 0 ] && out="$out,softtemp-since-boot"

    [ -z "$out" ] && out=",clean"
    printf '%s' "${out#,}"
}

# True when any "right now" bit is set.
throttling_now() {
    local hex="$1" v
    case "$hex" in unknown|"") return 1 ;; esac
    v=$((hex)) 2>/dev/null || return 1
    [ $((v & 0xF)) -ne 0 ]
}

# True when a throttle event happened BETWEEN two readings.
#
# Checking only the "now" bits at the end of a run misses the common case:
# throttling that occurs mid-run and has cleared by the time the run finishes.
# The firmware's since-boot bits are sticky until reboot, so a bit that is set in
# `after` but not in `before` means it happened during the interval — which is
# exactly the question a benchmark needs answered.
#
#   occurred <before_hex> <after_hex>   exit 0 if throttling occurred between
throttling_occurred() {
    local a="$1" b="$2" va vb newbits
    case "$a$b" in *unknown*|"") return 1 ;; esac
    va=$((a)) 2>/dev/null || return 1
    vb=$((b)) 2>/dev/null || return 1

    # Sticky since-boot bits that are newly set, plus anything active right now.
    newbits=$(( (vb & 0xF0000) & ~(va & 0xF0000) ))
    [ "$newbits" -ne 0 ] || [ $((vb & 0xF)) -ne 0 ]
}

# Sample continuously into a file until killed.
#
# Why this exists: the firmware's since-boot bits are sticky, so once a session
# has thrown all four, `occurred` can only fall back to the instantaneous reading
# at the end of a run. A run that throttles in the middle and recovers before it
# finishes would then go unflagged. Sampling throughout removes that blind spot
# and yields the peak temperature, which a published benchmark should report
# anyway.
#
#   watch <outfile>    samples every 5s; kill it to stop
#   peak  <outfile>    prints "max_temp=NN.N any_throttle=yes|no"
cmd_watch() {
    local out="${1:?usage: watch <outfile>}"
    : > "$out"
    while true; do
        echo "$(read_temp_c) $(read_throttled)" >> "$out"
        sleep 5
    done
}

cmd_peak() {
    local out="${1:?usage: peak <outfile>}" mx=0 thr=no t m

    if [ ! -s "$out" ]; then
        printf 'max_temp=unknown any_throttle=unknown\n'
        return 0
    fi

    # Deliberately no awk bit-twiddling here. strtonum() and and() are gawk
    # extensions and Debian ships mawk, so an awk-based version parses on a
    # developer box and fails on every Pi. Bash handles 0x literals in $(( ))
    # natively, and awk is used only for the float comparison, which is POSIX.
    while read -r t m; do
        case "$t" in ''|unknown) continue ;; esac
        if awk -v a="$t" -v b="$mx" 'BEGIN { exit !(a > b) }'; then
            mx="$t"
        fi
        case "$m" in
            0x*) [ $(( m & 0xF )) -ne 0 ] && thr=yes ;;
        esac
    done < "$out"

    printf 'max_temp=%s any_throttle=%s\n' "$mx" "$thr"
}

cmd_read() {
    local t th
    t=$(read_temp_c)
    th=$(read_throttled)
    printf 'temp_c=%s throttled=%s flags=%s\n' "$t" "$th" "$(decode_flags "$th")"
}

# Cool to a target, bounded. Never blocks forever: a warm room may simply not
# permit the target, and a benchmark that hangs waiting for a temperature is
# worse than one that records the temperature it actually started at.
cmd_wait() {
    local target="${1:-65}" max="${2:-600}"
    local waited=0 t

    t=$(read_temp_c)
    if [ "$t" = "unknown" ]; then
        printf 'no thermal sensor; not waiting\n'
        cmd_read
        return 0
    fi

    if awk -v a="$t" -v b="$target" 'BEGIN { exit !(a <= b) }'; then
        printf 'already at or below %s C after %ss\n' "$target" "$waited"
        cmd_read
        return 0
    fi

    printf 'cooling to %s C (max %ss)...\n' "$target" "$max"
    while [ "$waited" -lt "$max" ]; do
        sleep 10
        waited=$((waited + 10))
        t=$(read_temp_c)
        if awk -v a="$t" -v b="$target" 'BEGIN { exit !(a <= b) }'; then
            printf 'reached %s C after %ss\n' "$t" "$waited"
            cmd_read
            return 0
        fi
    done

    printf 'TIMEOUT after %ss, still at %s C — starting anyway, state recorded\n' \
        "$waited" "$t"
    cmd_read
    return 1
}

case "${1:-read}" in
    read)  cmd_read ;;
    flags) decode_flags "${2:-unknown}"; printf '\n' ;;
    wait)  cmd_wait "${2:-65}" "${3:-600}" ;;
    now)      throttling_now "${2:-unknown}" ;;
    occurred) throttling_occurred "${2:-unknown}" "${3:-unknown}" ;;
    watch)    cmd_watch "${2:-}" ;;
    peak)     cmd_peak "${2:-}" ;;
    *)
        echo "usage: $0 {read|flags <hex>|wait <t> <s>|now <hex>|occurred <a> <b>}" >&2
        exit 2
        ;;
esac
