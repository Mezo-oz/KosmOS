#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# KosmOS — Test 2: dropped SDR samples (rtl_test sweep)
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
# NOT YET RUN: no dongle on hand at the time of writing, so this harness has been
# linted and reviewed but never executed against hardware. The rtl_test output
# parsing in particular is written against its documented output format and
# should be checked on the first real run — use --quick first.
#
# SHARED CODE: the governor, config-detection and load-generation blocks below are
# duplicated in run-latency-bench.sh. Deliberately not extracted — see the
# extraction rule in ROADMAP.md for the trigger and the shape it must take.
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

OUT_DIR="${KOSMOS_BENCH_OUT:-$SELF_DIR/results}"

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

# --- Configuration detection (identical to run-latency-bench.sh) ------------

detect_config() {
    local rt=0 nohz=0

    if [ -f /proc/config.gz ] && zcat /proc/config.gz 2>/dev/null \
        | grep -qx "CONFIG_PREEMPT_RT=y"; then
        rt=1
    elif uname -v | grep -q "PREEMPT_RT"; then
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
}

if [ -z "$CONFIG" ]; then
    CONFIG=$(detect_config)
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

GOV_PATHS=(/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor)
ORIGINAL_GOV=""

read_governor() {
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown
}

set_governor() {
    local want="$1" p
    for p in "${GOV_PATHS[@]}"; do
        [ -e "$p" ] || continue
        echo "$want" | sudo tee "$p" > /dev/null 2>&1 || true
    done
}

restore_state() {
    stop_load
    if [ -n "$ORIGINAL_GOV" ] && [ "$ORIGINAL_GOV" != "unknown" ]; then
        set_governor "$ORIGINAL_GOV"
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

    set_governor performance
    local gov
    gov=$(read_governor)
    if [ "$gov" != "performance" ]; then
        echo "      WARNING: governor is '$gov', not performance."
    fi

    start_load "$load"

    {
        echo "# KosmOS SDR sample-loss benchmark"
        echo "# config:     $CONFIG ($DETECTED)"
        echo "# rate:       $rate S/s"
        echo "# load:       $load"
        echo "# duration:   ${DURATION}s"
        echo "# governor:   $gov"
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

    local bytes samples
    bytes=$(sum_lost_bytes "$raw")
    samples=$(( bytes / 2 ))

    printf '      lost %s bytes = %s samples\n' "$bytes" "$samples"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$CONFIG" "$rate" "$load" "$DURATION" "$bytes" "$samples" "$gov" \
        >> "$OUT_DIR/sdr-summary.tsv"
}

# --- Main -------------------------------------------------------------------

mkdir -p "$OUT_DIR"

ORIGINAL_GOV=$(read_governor)
trap restore_state EXIT

RUN_COUNT=$(( ${#RATES[@]} * 2 ))
EST_MIN=$(( (RUN_COUNT * (DURATION + 10)) / 60 + 1 ))

echo "============================================"
echo "  KosmOS SDR Sample-Loss Benchmark — Test 2"
echo "============================================"
echo ""
echo "  configuration:  $CONFIG ($DETECTED)"
echo "  kernel:         $(uname -r)"
echo "  governor now:   $ORIGINAL_GOV (will be set to performance, then restored)"
echo "  rates:          ${RATES[*]}"
echo "  per run:        ${DURATION}s"
echo "  runs:           $RUN_COUNT (${#RATES[@]} rates x idle/load)"
echo "  estimated:      ~${EST_MIN} minutes"
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
    printf 'config\trate\tload\tseconds\tlost_bytes\tlost_samples\tgovernor\n' \
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
