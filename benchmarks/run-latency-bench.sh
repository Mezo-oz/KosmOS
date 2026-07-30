#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# KosmOS — Test 1: scheduling latency (cyclictest)
# ============================================================================
# Run this ON THE PI, once per boot configuration. Needs no SDR hardware.
#
# It answers one question: does PREEMPT_RT measurably reduce worst-case wakeup
# latency versus the stock Pi kernel on identical hardware? The comparison is
# only worth publishing if the two boots differ in nothing but the kernel, which
# is what the os_prefix install bought — see kernel/install-kernel.sh.
#
# THE THREE CONFIGURATIONS (see BENCHMARKS.md):
#   A  stock Pi kernel
#   B  KosmOS PREEMPT_RT, NOHZ_FULL_CPUS=""
#   C  KosmOS PREEMPT_RT, NOHZ_FULL_CPUS="1-3"
#
# Report B-A as the PREEMPT_RT result and C-B as the core-isolation result.
# Never report C-A: it conflates two independent changes into one number.
#
# The configuration is detected from the running kernel rather than typed in,
# because a mislabelled result set is worse than no result set. Override with
# --config if you know better than the detection.
#
# TWO AFFINITY MODES, RUN IN EVERY CONFIGURATION:
#   whole   cyclictest -S — one thread per CPU, across all four
#   pinned  taskset -c 1-3, threads pinned to CPUs 1-3 only
#
#   Settled 2026-07-30. B-A is read off the whole rows and C-B off the pinned
#   rows, so each delta is between like and like. In config C an unpinned run
#   schedules on CPU 0, which is the housekeeping core and not tickless, so it
#   measures config B and the isolation delta reads as zero — but pinning *only*
#   in C is equally wrong, because then C-B compares two different experiments
#   and the affinity change gets credited to dynticks. Costs about 35 minutes per
#   configuration; if a run must be shortened, drop a load condition, not the
#   affinity matching. Full argument in BENCHMARKS.md.
#
# GOVERNOR: set to performance before every run, in every configuration, and
#   restored on exit. The kernel default does not survive Pi OS boot — ondemand
#   was observed on hardware — and its frequency-ramp delay would otherwise land
#   on whichever kernel happened to be measured cold. Also in BENCHMARKS.md.
#
# SHARED CODE: the governor, config-detection and load-generation blocks below are
#   duplicated in run-sdr-bench.sh. Deliberately not extracted — see the
#   extraction rule in ROADMAP.md for the trigger and the shape it must take.
# ============================================================================

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Tunables ---------------------------------------------------------------

# cyclictest parameters. 200 us interval x 1M loops is ~3m20s of wall clock per
# run; six runs per configuration is a little over half an hour.
LOOPS=1000000
INTERVAL=200
PRIORITY=90
HIST_BUCKETS=400

# CPUs to pin to in "pinned" mode. Must match NOHZ_FULL_CPUS in
# kernel/install-kernel.sh for config C, or the pinned run lands on a ticking
# core and measures nothing.
PINNED_CPUS="1-3"

OUT_DIR="${KOSMOS_BENCH_OUT:-$SELF_DIR/results}"

# --- Argument handling ------------------------------------------------------

CONFIG=""
QUICK=0

usage() {
    cat <<'EOF'
usage: run-latency-bench.sh [--config A|B|C] [--quick]

  --config X   label results as configuration X instead of auto-detecting
  --quick      100k loops instead of 1M -- a two-minute smoke test of the
               harness itself, NOT a publishable result
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
    LOOPS=100000
fi

# --- Preconditions ----------------------------------------------------------

for tool in cyclictest stress-ng taskset; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo "ERROR: $tool is not installed." >&2
        echo "       Run userspace/02b-bench-tools.sh, or:" >&2
        echo "         sudo apt install rt-tests stress-ng util-linux" >&2
        exit 1
    fi
done

# cyclictest needs to mlock and to run at RT priority, so the whole suite runs
# under sudo. Asking for it once up front beats a password prompt landing in the
# middle of a timed run.
if ! sudo -v; then
    echo "ERROR: this suite needs sudo (cyclictest uses mlockall and SCHED_FIFO)." >&2
    exit 1
fi

# --- Configuration detection ------------------------------------------------

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
        # An unexpanded glob lands here as a literal on a kernel without
        # cpufreq; skip it rather than writing to a path that does not exist.
        [ -e "$p" ] || continue
        echo "$want" | sudo tee "$p" > /dev/null 2>&1 || true
    done
}

restore_state() {
    # Kill any load generator still running, then put the governor back. Both
    # are best-effort: this runs from an EXIT trap, including after a Ctrl-C in
    # the middle of a run, and a failure here must not mask the real error.
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
        cpu)
            stress-ng --cpu 4 --timeout "${LOAD_TIMEOUT}s" > /dev/null 2>&1 &
            ;;
        io)
            stress-ng --io 2 --vm 1 --timeout "${LOAD_TIMEOUT}s" > /dev/null 2>&1 &
            ;;
        *)
            echo "ERROR: unknown load kind '$kind'" >&2
            exit 1
            ;;
    esac

    LOAD_PID=$!
    # stress-ng needs a moment to actually saturate; measuring the ramp would
    # understate the load condition.
    sleep 5
}

stop_load() {
    if [ -n "$LOAD_PID" ]; then
        kill "$LOAD_PID" 2>/dev/null || true
        wait "$LOAD_PID" 2>/dev/null || true
        LOAD_PID=""
    fi
    # --timeout gives stress-ng its own bound, so this is belt and braces for
    # the interrupted case.
    pkill -x stress-ng 2>/dev/null || true
}

# --- Result parsing ---------------------------------------------------------

# cyclictest with -h prints per-thread footers:
#   # Max Latencies: 00012 00015 00011 00013
# Take the largest across threads: the claim under test is about the tail, and a
# single bad core is still a bad worst case. Falls back to the "T: ... Max:"
# per-thread lines if the histogram footer is absent.
extract_latency() {
    local file="$1" field="$2"   # field: Min|Avg|Max

    awk -v want="$field" '
        $0 ~ "^# " want " Latencies:" {
            for (i = 4; i <= NF; i++) if ($i + 0 > best) best = $i + 0
            found = 1
        }
        END { if (found) print best }
    ' "$file"

    if ! grep -q "^# $field Latencies:" "$file"; then
        awk -v want="$field:" '
            $1 == "T:" {
                for (i = 1; i <= NF; i++)
                    if ($i == want && ($(i+1) + 0) > best) best = $(i+1) + 0
            }
            END { print best + 0 }
        ' "$file"
    fi
}

# --- The run ----------------------------------------------------------------

# Each cyclictest run takes LOOPS * INTERVAL microseconds; give the load
# generator that plus a margin for setup and teardown.
LOAD_TIMEOUT=$(( (LOOPS * INTERVAL) / 1000000 + 60 ))

run_one() {
    local load="$1" affinity="$2"
    local tag="config${CONFIG}-${load}-${affinity}"
    local raw="$OUT_DIR/$tag.txt"

    local -a cmd=(sudo)
    if [ "$affinity" = "pinned" ]; then
        # taskset constrains cyclictest and anything it spawns; -a/-t make
        # cyclictest's own per-thread pinning agree with that mask. Without
        # them, -S derives one thread per *online* CPU and tries to pin thread 0
        # to CPU 0, which is outside the mask and fails.
        cmd+=(taskset -c "$PINNED_CPUS" cyclictest -a "$PINNED_CPUS" -t 3)
    else
        cmd+=(cyclictest -S)
    fi
    cmd+=(-l "$LOOPS" -m -p "$PRIORITY" -i "$INTERVAL" -h "$HIST_BUCKETS" -q)

    echo ""
    echo "  --- $tag ---"
    echo "      $(printf '%s ' "${cmd[@]}")"

    set_governor performance
    local gov
    gov=$(read_governor)
    if [ "$gov" != "performance" ]; then
        echo "      WARNING: governor is '$gov', not performance. The numbers"
        echo "               from this run include frequency-ramp latency and"
        echo "               must be labelled as such."
    fi

    start_load "$load"

    {
        echo "# KosmOS latency benchmark"
        echo "# config:     $CONFIG ($DETECTED)"
        echo "# load:       $load"
        echo "# affinity:   $affinity"
        echo "# governor:   $gov"
        echo "# kernel:     $(uname -r)"
        echo "# uname -v:   $(uname -v)"
        echo "# cmdline:    $(cat /proc/cmdline)"
        echo "# date:       $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "# command:    $(printf '%s ' "${cmd[@]}")"
        echo "#"
    } > "$raw"

    "${cmd[@]}" >> "$raw" 2>&1

    stop_load

    local mn av mx
    mn=$(extract_latency "$raw" Min)
    av=$(extract_latency "$raw" Avg)
    mx=$(extract_latency "$raw" Max)

    printf '      min %-6s avg %-6s max %-6s us\n' "$mn" "$av" "$mx"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$CONFIG" "$load" "$affinity" "$mn" "$av" "$mx" "$gov" >> "$OUT_DIR/summary.tsv"
}

# --- Main -------------------------------------------------------------------

mkdir -p "$OUT_DIR"

ORIGINAL_GOV=$(read_governor)
trap restore_state EXIT

RUNS=6
EST_MIN=$(( (LOOPS * INTERVAL * RUNS) / 60000000 + 3 ))

echo "============================================"
echo "  KosmOS Latency Benchmark — Test 1"
echo "============================================"
echo ""
echo "  configuration:  $CONFIG ($DETECTED)"
echo "  kernel:         $(uname -r)"
echo "  governor now:   $ORIGINAL_GOV (will be set to performance, then restored)"
echo "  loops:          $LOOPS at ${INTERVAL}us, priority $PRIORITY"
echo "  runs:           $RUNS (3 loads x 2 affinities)"
echo "  estimated:      ~${EST_MIN} minutes"
echo "  output:         $OUT_DIR"
if [ "$QUICK" -eq 1 ]; then
    echo ""
    echo "  QUICK MODE — $LOOPS loops. This exercises the harness. It is not a"
    echo "  publishable result; the tail needs the full run to show up."
fi
echo ""
read -r -p "Start? (y/N): " GO
case "${GO,,}" in
    y|yes) ;;
    *)
        echo "Aborted. Nothing run."
        exit 0
        ;;
esac

if [ ! -f "$OUT_DIR/summary.tsv" ]; then
    printf 'config\tload\taffinity\tmin_us\tavg_us\tmax_us\tgovernor\n' \
        > "$OUT_DIR/summary.tsv"
fi

for load in idle cpu io; do
    for affinity in whole pinned; do
        run_one "$load" "$affinity"
    done
done

echo ""
echo "============================================"
echo "  DONE — configuration $CONFIG"
echo "============================================"
echo ""
column -t -s "$(printf '\t')" "$OUT_DIR/summary.tsv" 2>/dev/null \
    || cat "$OUT_DIR/summary.tsv"
echo ""
echo "  Raw output and run metadata: $OUT_DIR/config${CONFIG}-*.txt"
echo ""
echo "  Next: reboot into another configuration and run this again. Copy the"
echo "  numbers into the tables in benchmarks/BENCHMARKS.md once all three are"
echo "  done. Report B-A and C-B separately; never C-A."
