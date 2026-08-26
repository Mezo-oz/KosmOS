#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# KosmOS — mark the running slot good, but only if it deserves it (Phase 4d)
# ============================================================================
# This is the script that decides whether an update sticks. It runs the health
# check and calls `rauc status mark-good` ONLY on exit 0. Never marking good is
# the rollback: the tryboot flag was already cleared by the firmware before
# Linux started, so the next boot returns to the committed slot by itself.
#
# THE ENTIRE MECHANISM DEPENDS ON THIS SCRIPT NOT BEING A FORMALITY.
#
#   ExecStart=/usr/bin/rauc status mark-good
#
# is what the obvious implementation looks like -- it is what the upstream Pi
# backend's own rauc-mark-good.service ships -- and it marks every boot good,
# including the boot where nothing works. An A/B system whose mark-good is
# unconditional has the storage cost of rollback and none of the protection.
# The health check is the whole point; running it is not optional and neither
# is honouring its exit code.
#
# The split of labour is deliberate and predates this file: the checker renders
# a verdict and takes no action (so it can be run by hand, by anyone, at any
# time, without side effects), and this script takes the action and renders no
# verdict. Neither half can be tested by exercising the other.
#
# Exit codes are for the journal and for a human, not for RAUC:
#   0  healthy, marked good
#   1  unhealthy -- deliberately NOT marked; this boot will be rolled back
#   2  could not decide (checker missing, rauc missing, not an A/B system)
#
# NOTE ON 2: a box that cannot ask the question does not get marked good
# either. That is the safe direction -- it costs a rollback to a slot that
# worked, where the other direction commits a slot nobody vouched for.
# ============================================================================

set -euo pipefail

HEALTH_CHECK="${KOSMOS_HEALTH_CHECK:-/usr/local/lib/kosmos/kosmos-health-check.sh}"
RAUC="${KOSMOS_RAUC:-rauc}"

log()  { echo "kosmos-mark-good: $*" >&2; }
die2() { log "$*"; exit 2; }

main() {
    [ $# -eq 0 ] || die2 "takes no arguments (got: $*)"
    [ -x "$HEALTH_CHECK" ] || die2 "$HEALTH_CHECK: not executable"
    command -v "$RAUC" > /dev/null 2>&1 || die2 "$RAUC: not found"

    # `rauc status` failing means there is no A/B system to mark -- a single-root
    # pre-4d image, or a broken system.conf. Not something to mark good, and not
    # something to call a health failure either.
    "$RAUC" status > /dev/null 2>&1 ||
        die2 "rauc cannot read the slot status; not an A/B system?"

    log "running the health check"
    local rc=0
    "$HEALTH_CHECK" || rc=$?

    if [ "$rc" -ne 0 ]; then
        # Say what happens next, in the journal, in words. Whoever reads this
        # is looking at a box that is about to revert and needs to know that
        # was a decision rather than a crash.
        log "health check FAILED (exit $rc) -- NOT marking good"
        log "this slot will be rolled back on the next reboot"
        return 1
    fi

    log "health check passed; marking the running slot good"
    "$RAUC" status mark-good || die2 "rauc status mark-good failed"
    log "slot committed"
}

main "$@"
