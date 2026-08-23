#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# KosmOS — boot health check (Phase 4d)
# ============================================================================
# Decides whether the slot we just booted is good. Its EXIT CODE IS THE VERDICT:
#
#   0        healthy — the caller may call `rauc status mark-good`
#   non-zero unhealthy — do NOT mark good, so the next boot returns to the old
#            slot on its own
#
# That is the whole contract, and it is the one thing that makes this script
# different in kind from userspace/02a-verify-kernel.sh, which it was grown
# from. 02a always exits 0 on purpose: it reports facts about whatever kernel
# you happened to boot, and its caller has work to do regardless. Here the
# exit code is not a report, it is a decision that reboots a machine. Every
# check below had to be re-examined in that light rather than copied across.
#
# This script does NOT call rauc itself. Keeping the judgement separate from
# the action is deliberate:
#   - it runs on a box with no RAUC installed, which is the only reason it
#     could be tested at all before the image builder (4a) exists
#   - a human can ask "is this box healthy?" at any time without the answer
#     having side effects
#   - the mark-good wrapper stays small enough to read in one sitting
#
# Read-only. No sudo, no prompts, no writes, no network. It has to run
# unattended as root under systemd early in boot, where there is no tty to
# prompt at and no user to answer; it also has to be runnable by hand as an
# ordinary user. Anything requiring privilege is therefore out, which is why
# 02a's `sudo modprobe ax25` check did not come across.
#
# CRITICAL vs ADVISORY. Only CRITICAL affects the exit code; ADVISORY is
# printed and then deliberately ignored. The dividing line is *who broke it* --
# the image, which reverting fixes, versus the operator (removable hardware,
# site config, the network), which reverting cannot, since the previous slot
# fails identically. Erring toward CRITICAL builds a box that reverts every
# update because a dongle is unplugged, then reverts again: a rollback trigger
# firing on facts the rollback cannot change is worse than none, because it
# spends the only recovery mechanism the design has.
#
# The full reasoning, and why "SDR enumerates" and "TLE timer loaded" each
# split across the two tiers rather than landing in one, is in ROADMAP.md 4d.
# It is not repeated here: that document owns rationale, and this header
# carrying a second copy is how the two drift apart.
# ============================================================================

set -euo pipefail

if [ "$#" -gt 0 ]; then
    echo "kosmos-health-check: takes no arguments (got: $*)" >&2
    echo "  exit 0 = healthy, non-zero = do not mark this slot good" >&2
    exit 2
fi

# Colour only when a human is watching. Under systemd stdout is journald, and
# escape codes there are noise in a file people grep during an incident.
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

CRITICAL_FAILURES=0
ADVISORY_WARNINGS=0

# Arithmetic assignment rather than ((n++)): under `set -e`, ((0)) evaluates to
# a zero status and kills the script on the very first increment. Same trap
# 02a-verify-kernel.sh documents; it is repeated here rather than shared,
# because a helper library is not how this repo builds things.
ok() {
    printf "  ${GREEN}[ ok ]${NC}  %-24s %s\n" "$1" "${2-}"
}

critical_fail() {
    printf "  ${RED}[FAIL]${NC}  %-24s %s\n" "$1" "${2-}"
    CRITICAL_FAILURES=$((CRITICAL_FAILURES + 1))
}

advisory_warn() {
    printf "  ${YELLOW}[warn]${NC}  %-24s %s\n" "$1" "${2-}"
    ADVISORY_WARNINGS=$((ADVISORY_WARNINGS + 1))
}

# --- CRITICAL: this kernel is ours -----------------------------------------
#
# CONFIG_LOCALVERSION="-kosmos" is what puts the string there. Matching only
# "kosmos" is the point: the older pattern also accepted "rt" or "6.12", which
# a stock Raspberry Pi OS kernel satisfies, so it passed whether or not the
# custom kernel was running.
check_kernel_localversion() {
    local kver
    kver=$(uname -r)
    if printf '%s' "$kver" | grep -qi "kosmos"; then
        ok "kernel is KosmOS" "$kver"
    else
        critical_fail "kernel is KosmOS" "$kver — no '-kosmos' in uname -r"
    fi
}

# --- CRITICAL: the RT patchset is actually live -----------------------------
#
# Three-step detection, best evidence first. Do NOT check /sys/kernel/realtime
# alone: that file came from the out-of-tree patchset, and since RT was merged
# into mainline in 6.12 it is not created at all — so the naive check reports
# NOT DETECTED on exactly the kernel this project builds. Confirmed on hardware
# 2026-07-29, where uname -v read "SMP PREEMPT_RT" while the file was absent.
#
# This is the check the whole distro's claim rests on. An update that quietly
# lands a non-RT kernel is the single most important thing to revert, because
# the box keeps working and only the latency guarantee is gone — nothing else
# would ever notice.
check_rt_preempt() {
    local evidence=""
    # Process substitution, NOT `zcat ... | grep -qx`. That pipeline is a lie
    # under `set -o pipefail`: grep -q exits the instant it matches, zcat is
    # still writing (the config decompresses to ~242 KB, well past the 64 KB
    # pipe buffer), so zcat dies of SIGPIPE and pipefail reports the whole
    # pipeline as failed even though the match succeeded. Measured on pi-server
    # 2026-08-23. The effect is silent and always in the same direction: this
    # branch can never be taken, so the check permanently runs on its weaker
    # fallback while claiming to consult the authoritative source.
    if [ -f /proc/config.gz ] &&
        grep -qx "CONFIG_PREEMPT_RT=y" <(zcat /proc/config.gz 2>/dev/null); then
        evidence="CONFIG_PREEMPT_RT=y in /proc/config.gz"
    elif uname -v | grep -q "PREEMPT_RT"; then
        evidence="PREEMPT_RT in uname -v"
    elif [ -f /sys/kernel/realtime ] && [ "$(cat /sys/kernel/realtime)" = "1" ]; then
        evidence="/sys/kernel/realtime=1 (legacy patchset)"
    fi

    if [ -n "$evidence" ]; then
        ok "PREEMPT_RT active" "$evidence"
    else
        critical_fail "PREEMPT_RT active" \
            "checked /proc/config.gz, uname -v, /sys/kernel/realtime"
    fi
}

# --- CRITICAL: the watchdog is bound and armed ------------------------------
#
# 4d's rollback covers "booted but broken". It cannot cover a hang, and the Pi
# firmware's tryboot has no fallback for a slot that never reaches Linux. The
# watchdog is the mitigation for both, so an unarmed one is a genuinely broken
# image even though nothing else on the box would misbehave.
#
# Verified 2026-08-23 on pi-server that this arrives for free: the driver binds
# as bcm2835-wdt, and Raspberry Pi OS arms it via
# /usr/lib/systemd/system.conf.d/40-rpi-enable-watchdog.conf. Free is exactly
# why it is asserted here rather than assumed — an image built from a base
# other than Pi OS drops that drop-in silently, and an unarmed watchdog looks
# identical to an armed one until the day something hangs.
check_watchdog() {
    if [ ! -e /sys/class/watchdog/watchdog0 ]; then
        critical_fail "watchdog bound" "no /sys/class/watchdog/watchdog0"
        return
    fi

    local identity
    identity=$(cat /sys/class/watchdog/watchdog0/identity 2>/dev/null || echo "unknown")
    ok "watchdog bound" "$identity"

    local armed
    armed=$(systemctl show -p RuntimeWatchdogUSec --value 2>/dev/null || echo "")
    case "$armed" in
        "" | 0 | off | infinity)
            critical_fail "watchdog armed" \
                "systemd RuntimeWatchdogUSec=${armed:-unset} — a hang will not reset"
            ;;
        *)
            ok "watchdog armed" "RuntimeWatchdogUSec=$armed"
            ;;
    esac
}

# --- CRITICAL: gr-kosmos is really importable -------------------------------
#
# Import a SUBMODULE, never the bare package, and always with -P. `import
# kosmos` alone PASSES on a box with no gr-kosmos installed: Python invents a
# namespace package from any kosmos/ directory on sys.path, and the cwd is on
# that path. Caught doing exactly that on pi-server 2026-08-23. A submodule
# import has no namespace package to satisfy it, and -P removes the cwd from
# the path entirely, so the answer cannot depend on where the service started.
#
# Two checks, not one: kosmos/__init__.py re-exports the probe, which imports
# gnuradio.gr, so any import drags in the whole stack and a single check would
# blame gr-kosmos for a missing GNU Radio. Full write-up in ROADMAP.md 4d.
check_gnuradio() {
    if ! command -v python3 > /dev/null 2>&1; then
        critical_fail "GNU Radio imports" "no python3 on PATH"
        return
    fi

    if python3 -P -c "from gnuradio import gr" > /dev/null 2>&1; then
        ok "GNU Radio imports" "from gnuradio import gr"
    else
        critical_fail "GNU Radio imports" "'from gnuradio import gr' failed"
    fi
}

check_gr_kosmos() {
    if ! command -v python3 > /dev/null 2>&1; then
        critical_fail "gr-kosmos imports" "no python3 on PATH"
        return
    fi

    if python3 -P -c "from kosmos import gap_math" > /dev/null 2>&1; then
        ok "gr-kosmos imports" "from kosmos import gap_math"
    else
        critical_fail "gr-kosmos imports" \
            "'from kosmos import gap_math' failed under python3 -P"
    fi
}

# --- CRITICAL: the SATCOM binaries the image promises are present -----------
#
# Presence only. Whether they can talk to hardware is the operator's problem
# and is handled below as advisory.
check_satcom_binaries() {
    local missing="" tool
    for tool in rtl_test rtl_sdr predict; do
        if ! command -v "$tool" > /dev/null 2>&1; then
            missing="$missing $tool"
        fi
    done

    if [ -z "$missing" ]; then
        ok "SATCOM binaries" "rtl_test, rtl_sdr, predict"
    else
        critical_fail "SATCOM binaries" "missing:$missing"
    fi
}

# --- CRITICAL: the TLE units ship with the image ----------------------------
#
# The unit FILES, not an enabled instance. kosmos-tle-update@.service is a
# template keyed on username, so which instance exists is a site decision,
# while the template itself is part of the image and its absence means the
# update dropped a component.
check_tle_units() {
    local missing="" unit
    for unit in kosmos-tle-update@.service kosmos-tle-update@.timer; do
        if ! systemctl cat "$unit" > /dev/null 2>&1; then
            missing="$missing $unit"
        fi
    done

    if [ -z "$missing" ]; then
        ok "TLE unit files" "template service + timer installed"
    else
        critical_fail "TLE unit files" "missing:$missing"
    fi
}

# --- CRITICAL: we are running the slot we think we are ----------------------
#
# slot-identity.sh beside this file gathers the facts; this renders the verdict.
# What each verdict means, and why `no-slotmap` is not a failure, is documented
# there -- it owns slot semantics and has the room for them.
check_slot_identity() {
    local helper facts verdict slot tryboot boot_p root_p
    helper="$(dirname -- "${BASH_SOURCE[0]}")/slot-identity.sh"

    if [ ! -x "$helper" ]; then
        critical_fail "slot identity" "slot-identity.sh missing beside this script"
        return
    fi

    if ! facts=$("$helper" 2>&1); then
        # Could not ANSWER the question, which is not the same as a bad answer.
        critical_fail "slot identity" "${facts##*: }"
        return
    fi

    verdict=""; slot=""; tryboot=""; boot_p=""; root_p=""
    while IFS='=' read -r key value; do
        case "$key" in
            VERDICT)        verdict="$value" ;;
            SLOT)           slot="$value" ;;
            TRYBOOT)        tryboot="$value" ;;
            BOOT_PARTITION) boot_p="$value" ;;
            ROOT_PARTITION) root_p="$value" ;;
        esac
    done <<< "$facts"

    case "$verdict" in
        consistent)
            ok "slot identity" "slot $slot (boot p$boot_p, root p$root_p)"
            ;;
        mismatch)
            critical_fail "slot identity" \
                "CROSS-SLOT: boot p$boot_p is slot $slot, root is p$root_p"
            ;;
        no-slotmap)
            advisory_warn "slot identity" \
                "no slot map — single-root image, boot p$boot_p, root p$root_p"
            ;;
        *)
            # unmapped, or a verdict this script does not know. Both mean the
            # box is not the shape the map describes; neither is safe to commit.
            critical_fail "slot identity" \
                "$verdict: boot p$boot_p, root p$root_p"
            ;;
    esac

    # Surfaced separately because it is not a fault, it is a countdown. On a
    # tryboot boot nothing has been committed: if this box reboots for any
    # reason before mark-good runs, it lands back on the other slot.
    if [ "$tryboot" = "1" ]; then
        advisory_warn "tryboot" "PROVISIONAL boot — not committed until marked good"
    fi
}

# --- ADVISORY: a dongle is actually plugged in ------------------------------
#
# rtl_test -t is the repo's existing way of asking, and it beats matching USB
# IDs because it exercises the driver path rather than the bus listing. Never
# critical: reverting the update will not plug in a dongle.
check_sdr_device() {
    if ! command -v rtl_test > /dev/null 2>&1; then
        advisory_warn "SDR device" "rtl_test absent — reported critical above"
        return
    fi

    if rtl_test -t > /dev/null 2>&1; then
        ok "SDR device" "rtl_test opened a device"
    else
        advisory_warn "SDR device" "no device answered rtl_test -t"
    fi
}

# --- ADVISORY: TLE refresh state --------------------------------------------
#
# Both halves are advisory. No enabled instance is a site choice; a failed last
# run is usually no network, and 4d's field story is explicitly a box with no
# network. Reverting an update because the satellite elements are stale would
# be reverting for weather.
check_tle_state() {
    local instances
    instances=$(systemctl list-units --type=timer --all --no-legend --plain \
        "kosmos-tle-update@*.timer" 2>/dev/null | awk '{print $1}' || true)

    if [ -z "$instances" ]; then
        advisory_warn "TLE timer instance" "no kosmos-tle-update@*.timer loaded"
        return
    fi

    local timer state
    for timer in $instances; do
        state=$(systemctl is-active "$timer" 2>/dev/null || true)
        if [ "$state" = "active" ]; then
            ok "TLE timer instance" "$timer active"
        else
            advisory_warn "TLE timer instance" "$timer is $state"
        fi
    done
}

# --- Run ---------------------------------------------------------------------

echo "============================================"
echo "  KosmOS slot health check"
echo "============================================"
echo "  kernel:  $(uname -r)"
echo "  host:    $(uname -n)"
echo ""
echo "CRITICAL — a failure here means do not mark this slot good:"
check_kernel_localversion
check_rt_preempt
check_watchdog
check_gnuradio
check_gr_kosmos
check_satcom_binaries
check_tle_units
check_slot_identity

echo ""
echo "ADVISORY — reported only; never affects the verdict:"
check_sdr_device
check_tle_state

echo ""
if [ "$CRITICAL_FAILURES" -eq 0 ]; then
    printf "${GREEN}HEALTHY${NC} — %d advisory warning(s). Safe to mark this slot good.\n" \
        "$ADVISORY_WARNINGS"
    exit 0
fi

printf "${RED}UNHEALTHY${NC} — %d critical failure(s), %d advisory warning(s).\n" \
    "$CRITICAL_FAILURES" "$ADVISORY_WARNINGS"
echo "Do not mark this slot good. The next boot should return to the other slot."
exit 1
