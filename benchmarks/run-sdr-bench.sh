#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — Test 2: dropped SDR samples (rtl_test sweep)
# ============================================================================
# Run this ON THE PI, once per boot configuration. REQUIRES the RTL-SDR dongle.
#
# Test 1 measures scheduling latency, which is the mechanism. This measures the
# consequence: how many samples the USB capture path actually loses, at the rates
# a real capture uses. It is the number that matters to a decoded image, and the
# one a reader will care about more than microseconds of wakeup latency.
#
# METHOD:
#   rtl_test -s <rate> streams from the dongle and reports every gap it sees as
#   "lost at least N bytes". It has no duration flag, so each run is bounded by
#   timeout(1) sending SIGINT, which rtl_test handles by cancelling the async
#   read and exiting cleanly. Lost bytes are summed per run.
#
#   Samples, not bytes, are the reportable figure: the dongle delivers 8-bit I
#   and 8-bit Q, so one complex sample is two bytes.
#
# CONFIGURATIONS: the same A/B/C matrix as Test 1, detected the same way. Report
# B-A as the PREEMPT_RT result and C-B as the isolation result, never C-A.
#
# GOVERNOR: set to performance before every run and restored on exit, for the
# same reason as Test 1 — ondemand ramp latency would otherwise be folded into
# whichever kernel happened to be measured cold.
#
# NOT YET RUN: this harness has been linted and reviewed but never executed
# against hardware. The rtl_test output parsing in particular is written against
# its documented output format and should be checked on the first real run.
# Smoke-test with --quick AND a scratch directory, never the real results dir:
#   MOLNIYA_BENCH_OUT=/tmp/sdr-smoke ./run-sdr-bench.sh --quick
# Raw files overwrite while sdr-summary.tsv appends, so a --quick pass into the
# real directory destroys the raw evidence for 2.4 MS/s and leaves rows that
# outlive it. The `seconds` column is what tells a 30 s row from a 600 s one.
#
# SHARED CODE: governor control, config detection and thermal state are executable
# helpers, called as subprocesses and never sourced — the shape the extraction rule
# in ROADMAP.md settled on when thermal gating tripped the 400-line trigger in
# run-latency-bench.sh. This file held the last inline copies; it no longer does.
# ============================================================================

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Tunables ---------------------------------------------------------------

# Sample rates to sweep, in samples/second. 2.4 MS/s is the usual NOAA APT rate;
# 3.2 MS/s is above what the USB path reliably sustains on most dongles, and is
# included precisely because that is where the kernels should diverge most.
RATES=(1024000 2048000 2400000 3200000)

# Seconds per run. Ten minutes per rate per load per configuration is a long
# afternoon; that is the point — sample loss is bursty and a 30-second run tells
# you almost nothing.
DURATION=600

# Thermal gate. It matters more for Test 2 than for Test 1, not less: the sweep
# runs `stress-ng --cpu 4 --io 2` for ten minutes per rate — the load that took a
# stock Pi 5 to its soft limit with the fan already at 4/4, and every cpu-load row
# in Test 1 throttled. A throttle drops the clock, which is exactly what makes the
# USB path miss its service deadlines, so here it inflates the published number.
#
# The sharper reason is the sweep's own shape: RATES ascends, and ungated so does
# accumulated heat, so the highest rate is always measured hottest. "Loss rises
# with rate" is both the headline result and what thermal drift alone would
# produce. Starting every run from one temperature is what separates them.
THERMAL_TARGET_C=65
THERMAL_WAIT_S=600
THERMAL="$SELF_DIR/thermal-state.sh"

OUT_DIR="${MOLNIYA_BENCH_OUT:-$SELF_DIR/results}"

# --- Argument handling ------------------------------------------------------

CONFIG=""
QUICK=0

usage() {
    cat <<'EOF'
usage: run-sdr-bench.sh [--config A|B|C] [--quick]

  --config X   label results as configuration X instead of auto-detecting
  --quick      30 seconds per run instead of 600, and only 2.4 MS/s -- checks
               that the harness and the parsing work. Not a result.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --config)
            if [ -z "${2:-}" ]; then
                echo "--config needs a value (A, B or C)" >&2
                exit 1
            fi
            CONFIG="$2"
            shift 2
            ;;
        --quick)
            QUICK=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [ "$QUICK" -eq 1 ]; then
    DURATION=30
    RATES=(2400000)
fi

# --- Preconditions ----------------------------------------------------------

for tool in rtl_test stress-ng timeout; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo "ERROR: $tool is not installed." >&2
        echo "       rtl_test comes from userspace/02c-sdr-userspace.sh;" >&2
        echo "       stress-ng from 02b-bench-tools.sh." >&2
        exit 1
    fi
done

# A dongle that is not there, or is claimed by the DVB-T driver, produces a run
# of zeros that looks like a perfect result. Check before measuring anything.
if ! rtl_test -t > /dev/null 2>&1; then
    echo "ERROR: rtl_test cannot open a device." >&2
    echo "" >&2
    echo "       Either no dongle is connected, or the kernel DVB-T driver has" >&2
    echo "       claimed it. 02c-sdr-userspace.sh installs the blacklist that" >&2
    echo "       prevents the latter; it needs a reboot or a replug to take" >&2
    echo "       effect. Check with:  lsmod | grep dvb" >&2
    echo "" >&2
    echo "       This matters more than a normal missing-dependency error: with" >&2
    echo "       no device, every run below would report zero lost samples and" >&2
    echo "       look like a flawless result." >&2
    exit 1
fi

if ! sudo -v; then
    echo "ERROR: this suite needs sudo to set the CPU governor." >&2
    exit 1
fi

# --- Configuration detection ------------------------------------------------

if [ -z "$CONFIG" ]; then
    CONFIG=$("$SELF_DIR/detect-config.sh")
    DETECTED="auto-detected"
else
    DETECTED="forced by --config"
fi

case "$CONFIG" in
    A|B|C) ;;
    *)
        echo "ERROR: config must be A, B or C (got '$CONFIG')" >&2
        exit 1
        ;;
esac

# --- Governor ---------------------------------------------------------------

ORIGINAL_GOV=""

# The thermal sampler is an unbounded `while true` by design — it runs until
# killed. If this script dies mid-run the trap is the only thing that stops it,
# so the PID is global rather than local to run_one.
THERM_PID=""

restore_state() {
    stop_load
    if [ -n "$THERM_PID" ]; then
        kill "$THERM_PID" 2>/dev/null || true
        THERM_PID=""
    fi
    if [ -n "$ORIGINAL_GOV" ] && [ "$ORIGINAL_GOV" != "unknown" ]; then
        "$SELF_DIR/governor.sh" set "$ORIGINAL_GOV" > /dev/null || true
    fi
}

# --- Load generation --------------------------------------------------------

LOAD_PID=""

start_load() {
    local kind="$1"

    case "$kind" in
        idle)
            LOAD_PID=""
            return
            ;;
        load)
            # Stands in for a decode job running during a live capture, which is
            # the realistic worst case for an appliance that decodes on landing.
            stress-ng --cpu 4 --io 2 --timeout "$(( DURATION + 60 ))s" \
                > /dev/null 2>&1 &
            ;;
        *)
            echo "ERROR: unknown load kind '$kind'" >&2
            exit 1
            ;;
    esac

    LOAD_PID=$!
    sleep 5
}

stop_load() {
    if [ -n "$LOAD_PID" ]; then
        kill "$LOAD_PID" 2>/dev/null || true
        wait "$LOAD_PID" 2>/dev/null || true
        LOAD_PID=""
    fi
    pkill -x stress-ng 2>/dev/null || true
}

# --- Result parsing ---------------------------------------------------------

# rtl_test reports each gap as a line containing "lost at least N bytes". Sum
# them. A run with no such line lost nothing, which awk reports as 0 rather than
# as empty -- an empty cell in a results table is ambiguous in a way that zero
# is not.
sum_lost_bytes() {
    awk '
        /lost at least/ {
            for (i = 1; i <= NF; i++)
                if ($i == "least") { total += $(i+1) + 0; break }
        }
        END { print total + 0 }
    ' "$1"
}

# --- The run ----------------------------------------------------------------

run_one() {
    local rate="$1" load="$2"
    local tag="config${CONFIG}-sdr-${rate}-${load}"
    local raw="$OUT_DIR/$tag.txt"

    echo ""
    echo "  --- ${rate} S/s, ${load}, ${DURATION}s ---"

    "$SELF_DIR/governor.sh" set performance > /dev/null || true
    local gov
    gov=$("$SELF_DIR/governor.sh" read)
    if [ "$gov" != "performance" ]; then
        echo "      WARNING: governor is '$gov', not performance."
    fi

    # Cool to a common starting point, then record what we actually got. The
    # gate is bounded, so a warm room yields a hot start that is written down
    # rather than a suite that hangs waiting for a temperature it cannot reach.
    echo "      $("$THERMAL" wait "$THERMAL_TARGET_C" "$THERMAL_WAIT_S" | tail -2 | head -1)"
    local therm_before thr_before
    therm_before=$("$THERMAL" read)
    thr_before=${therm_before#*throttled=}; thr_before=${thr_before%% *}
    echo "      before: $therm_before"

    "$THERMAL" watch "$raw.thermal" &
    THERM_PID=$!

    start_load "$load"

    {
        echo "# MolniyaOS SDR sample-loss benchmark"
        echo "# config:     $CONFIG ($DETECTED)"
        echo "# rate:       $rate S/s"
        echo "# load:       $load"
        echo "# duration:   ${DURATION}s"
        echo "# governor:   $gov"
        echo "# thermal before: $therm_before"
        echo "# kernel:     $(uname -r)"
        echo "# cmdline:    $(cat /proc/cmdline)"
        echo "# date:       $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "#"
    } > "$raw"

    # timeout's SIGINT is what rtl_test installs a handler for; SIGTERM would
    # also stop it but SIGINT is the documented path. The `|| true` is load-
    # bearing: timeout exits 124 when it does the interrupting, which is the
    # normal outcome of every run here, not a failure.
    timeout --signal=INT "$DURATION" rtl_test -s "$rate" >> "$raw" 2>&1 || true

    stop_load

    kill "$THERM_PID" 2>/dev/null || true
    THERM_PID=""
    local therm_after thr_hex thermal_ok peak temp_after
    peak=$("$THERMAL" peak "$raw.thermal")
    echo "# thermal peak:   $peak" >> "$raw"
    therm_after=$("$THERMAL" read)
    thr_hex=${therm_after#*throttled=}; thr_hex=${thr_hex%% *}
    echo "# thermal after:  $therm_after" >> "$raw"

    # Trimmed to the bare number: this lands in a TSV column that gets
    # transcribed into a table, and the untrimmed line carries the mask too.
    temp_after=${therm_after#*temp_c=}; temp_after=${temp_after%% *}

    # Flagged, not discarded — the reader decides. A throttled row is not
    # comparable: the clock was not constant, which is what pinning removes.
    if "$THERMAL" occurred "$thr_before" "$thr_hex" || [ "${peak#*any_throttle=}" = "yes" ]; then
        thermal_ok=THROTTLED
        echo "      *** THROTTLED during this run — $therm_after"
        echo "      *** treat this row as contaminated, not comparable"
    else
        thermal_ok=clean
    fi
    echo "      peak:   $peak"

    local bytes samples
    bytes=$(sum_lost_bytes "$raw")
    samples=$(( bytes / 2 ))

    printf '      lost %s bytes = %s samples\n' "$bytes" "$samples"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$CONFIG" "$rate" "$load" "$DURATION" "$bytes" "$samples" "$gov" \
        "$temp_after" "$thermal_ok" \
        >> "$OUT_DIR/sdr-summary.tsv"
}

# --- Main -------------------------------------------------------------------

mkdir -p "$OUT_DIR"

ORIGINAL_GOV=$("$SELF_DIR/governor.sh" read)
trap restore_state EXIT

RUN_COUNT=$(( ${#RATES[@]} * 2 ))

# Two figures, because cool-down dominates the spread. The floor assumes every
# run starts already cool; the ceiling assumes every gate runs to its bound.
EST_MIN=$(( (RUN_COUNT * (DURATION + 10)) / 60 + 1 ))
EST_MAX=$(( (RUN_COUNT * (DURATION + 10 + THERMAL_WAIT_S)) / 60 + 1 ))

echo "============================================"
echo "  MolniyaOS SDR Sample-Loss Benchmark — Test 2"
echo "============================================"
echo ""
echo "  configuration:  $CONFIG ($DETECTED)"
echo "  kernel:         $(uname -r)"
echo "  governor now:   $ORIGINAL_GOV (will be set to performance, then restored)"
echo "  rates:          ${RATES[*]}"
echo "  per run:        ${DURATION}s"
echo "  runs:           $RUN_COUNT (${#RATES[@]} rates x idle/load)"
echo "  estimated:      ${EST_MIN}-${EST_MAX} minutes, incl. cool-down"
echo "  thermal gate:   start each run at <= ${THERMAL_TARGET_C} C (max ${THERMAL_WAIT_S}s wait)"
echo "  output:         $OUT_DIR"
if [ "$QUICK" -eq 1 ]; then
    echo ""
    echo "  QUICK MODE — 30s at one rate. Run this first: it is how you find out"
    echo "  whether the output parsing matches your rtl_test build before"
    echo "  committing to a multi-hour sweep."
fi
echo ""
echo "  Leave the dongle physically undisturbed for the whole sweep. Antenna,"
echo "  cable and position are variables too, and a bumped connector will read"
echo "  as a kernel regression."
echo ""
read -r -p "Start? (y/N): " GO
case "${GO,,}" in
    y|yes) ;;
    *)
        echo "Aborted. Nothing run."
        exit 0
        ;;
esac

if [ ! -f "$OUT_DIR/sdr-summary.tsv" ]; then
    printf 'config\trate\tload\tseconds\tlost_bytes\tlost_samples\tgovernor\tthermal_c\tverdict\n' \
        > "$OUT_DIR/sdr-summary.tsv"
fi

for rate in "${RATES[@]}"; do
    for load in idle load; do
        run_one "$rate" "$load"
    done
done

echo ""
echo "============================================"
echo "  DONE — configuration $CONFIG"
echo "============================================"
echo ""
column -t -s "$(printf '\t')" "$OUT_DIR/sdr-summary.tsv" 2>/dev/null \
    || cat "$OUT_DIR/sdr-summary.tsv"
echo ""
echo "  Copy these into the Test 2 tables in benchmarks/BENCHMARKS.md."
