#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# KosmOS — RAUC custom bootloader backend for the Raspberry Pi firmware (4d)
# ============================================================================
# RAUC calls this with one of five verbs. stdout is the answer, exit status is
# whether the question could be answered, and every other word goes to stderr:
#
#   get-primary                    -> bootname of the COMMITTED slot
#   set-primary  <bootname>        -> arm that slot for the next boot
#   get-state    <bootname>        -> good | bad
#   set-state    <bootname> <good|bad>
#   get-current                    -> bootname of the RUNNING slot
#
# Registered from system.conf, which image/layout.sh generates:
#
#   [system]
#   bootloader=custom
#   [handlers]
#   bootloader-custom-backend=/usr/local/lib/kosmos/kosmos-boot-backend.sh
#
# ---------------------------------------------------------------------------
# THERE IS NO STORED STATE. All three answers are derived from three facts:
#
#   autoboot.txt [all] boot_partition      the committed slot   (get-primary)
#   /chosen/bootloader/partition           the booted slot      (get-current)
#   /chosen/bootloader/tryboot             is this boot a try?
#
# The first is a file on p1; the other two the firmware publishes into the
# device tree, and slot-identity.sh already reads them -- so this script has no
# device-tree code of its own and no fdtget dependency. Helper returns data,
# caller judges, same split as the health check uses.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS RATHER THAN rauc/rauc#1599. That PR adds a native Pi firmware
# backend in C and is the right long-term answer -- but it has been open since
# 2025-01-16 and is milestoned v1.17, which is one full minor release behind a
# v1.16 that has not shipped. `bootloader=custom` is stock RAUC (the backend
# predates v1.11; Debian trixie ships v1.13), so this handler is registered by
# CONFIG and patches nothing. When #1599 lands, `bootloader=custom` becomes the
# native backend and this file is deleted -- no fork to unwind, which was the
# whole objection to building anything here.
#
# WHY NOT Rtone/raspberrypi-firmware-rauc-bootloader-backend, which is the same
# author's pre-upstream version of #1599 and was what layout.sh used to name:
# it `source`s both autoboot.txt and system.conf into the shell and reads their
# keys back through `eval`. That is the hazard emit_slotmap already refuses --
# a corrupt config becoming code -- running as root, at boot, deciding which
# slot boots. Its BEHAVIOUR is the reference and is matched verb for verb, so
# that swapping to the native backend later is a config change and not a
# change of semantics. Its implementation is not.
#
# ---------------------------------------------------------------------------
# LIMITATION, stated because it is inherent and not an oversight: there is no
# persistent "bad" marker. A slot that is not running and not being tried
# reports `bad` because its status is genuinely unknown, not because anything
# recorded a failure. #1599 has the same property. The firmware offers nowhere
# to write such a marker that is not itself inside a slot.
# ============================================================================

set -euo pipefail

SELECTOR_MNT="${KOSMOS_SELECTOR_MNT:-/boot/selector}"
AUTOBOOT="${KOSMOS_AUTOBOOT:-$SELECTOR_MNT/autoboot.txt}"
SLOTMAP="${KOSMOS_SLOTMAP:-/etc/kosmos/slots.conf}"
SLOT_IDENTITY="${KOSMOS_SLOT_IDENTITY:-/usr/local/lib/kosmos/slot-identity.sh}"
VCMAILBOX="${KOSMOS_VCMAILBOX:-vcmailbox}"

# Set to 1 to skip the ro/rw remount dance -- for running against a fixture
# directory off-target, where the selector is not a mount at all.
NO_REMOUNT="${KOSMOS_SELECTOR_NO_REMOUNT:-0}"

# Path of the in-progress selector rewrite, global only so commit_swap's EXIT
# trap can name it without a double-quoted trap. Never read outside it.
TMP_SELECTOR=""

die() { echo "kosmos-boot-backend: $*" >&2; exit 1; }
warn() { echo "kosmos-boot-backend: $*" >&2; }

# ---------------------------------------------------------------------------
# Facts
# ---------------------------------------------------------------------------

# Read one key from a generated KEY=VALUE file without sourcing it, and accept
# only digits. Duplicated from slot-identity.sh on purpose: the house rule is
# that scripts repeat a few lines rather than source a shared library, which
# would need shellcheck --external-sources to stay clean.
slotmap_get() {
    local key="$1" line value
    [ -r "$SLOTMAP" ] || return 1
    while IFS= read -r line; do
        case "$line" in
            "$key="*)
                value="${line#*=}"
                case "$value" in
                    '' | *[!0-9]*) return 1 ;;
                    *) echo "$value"; return 0 ;;
                esac
                ;;
        esac
    done < "$SLOTMAP"
    return 1
}

# boot_partition out of one section of autoboot.txt.
#
# Section-aware, because the whole mechanism is that the same key appears twice
# with different values. Digits only, for the same reason slotmap_get insists:
# this value is interpolated into a file the firmware reads to pick a slot.
autoboot_get() {
    local want="$1" file="${2:-$AUTOBOOT}" line section="" value=""
    [ -r "$file" ] || die "$file: not readable (is p1 mounted?)"
    while IFS= read -r line; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in
            '#'* | '') continue ;;
            '['*']') section="${line#[}"; section="${section%]}"; continue ;;
            'boot_partition='*)
                [ "$section" = "$want" ] || continue
                value="${line#*=}"
                value="${value%"${value##*[![:space:]]}"}"
                ;;
        esac
    done < "$file"
    case "$value" in
        '' | *[!0-9]*) return 1 ;;
        *) echo "$value" ;;
    esac
}

IDENTITY_OUT=""

# slot-identity.sh's output, fetched once. It exits non-zero when the question
# cannot be ASKED (no device tree) -- which for us is fatal, since every verb
# below needs to know what is running.
identity_load() {
    if [ -n "$IDENTITY_OUT" ]; then return 0; fi
    [ -x "$SLOT_IDENTITY" ] || die "$SLOT_IDENTITY: not executable"
    IDENTITY_OUT="$("$SLOT_IDENTITY")" ||
        die "slot-identity.sh could not determine the running slot"
    return 0
}

identity_get() {
    local key="$1" line
    identity_load
    while IFS= read -r line; do
        case "$line" in "$key="*) echo "${line#*=}"; return 0 ;; esac
    done <<< "$IDENTITY_OUT"
    return 1
}

# ---------------------------------------------------------------------------
# Slot naming
# ---------------------------------------------------------------------------
#
# Bootnames are A and B because layout.sh's emit_rauc writes `bootname=A` and
# `bootname=B`. The mapping to partition numbers comes from slots.conf, which
# the same layout.sh emits -- so the two cannot disagree about a running image
# without layout.sh having been changed between them.

bootname_partition() {
    local bootname="$1"
    case "$bootname" in
        A) slotmap_get KOSMOS_SLOT_A_BOOT ;;
        B) slotmap_get KOSMOS_SLOT_B_BOOT ;;
        *) return 1 ;;
    esac
}

partition_bootname() {
    local partition="$1" a b
    a=$(slotmap_get KOSMOS_SLOT_A_BOOT) || return 1
    b=$(slotmap_get KOSMOS_SLOT_B_BOOT) || return 1
    case "$partition" in
        "$a") echo A ;;
        "$b") echo B ;;
        *) return 1 ;;
    esac
}

require_bootname() {
    local bootname="${1:-}"
    [ -n "$bootname" ] || die "$2 needs a bootname"
    bootname_partition "$bootname" > /dev/null ||
        die "unknown bootname '$bootname' (expected A or B)"
}

# ---------------------------------------------------------------------------
# Writing the selector
# ---------------------------------------------------------------------------

# The selector partition is mounted read-only (see layout.sh emit_fstab). It is
# the single most load-bearing file on the card and it is on FAT, which has no
# journal -- so it spends all its time ro and is writable only for the instant
# a slot actually changes.
selector_rw()  { [ "$NO_REMOUNT" = 1 ] || mount -o remount,rw "$SELECTOR_MNT"; }
selector_ro()  { [ "$NO_REMOUNT" = 1 ] || mount -o remount,ro "$SELECTOR_MNT"; }

# Swap the two boot_partition values, committing the [tryboot] slot.
#
# Rewritten line by line rather than regenerated from a template, so this holds
# no second copy of autoboot.txt's format -- anything else in the file survives
# untouched. Both values are validated against slots.conf FIRST: a corrupt
# selector must not be able to talk us into writing a partition number that is
# not one of the two boot slots.
#
# Written to a temp file, verified by reading it back, and only then renamed.
# A torn autoboot.txt is a card that does not boot, and FAT gives us no
# journal -- so the check is not optional and neither is the sync.
commit_swap() {
    local all try got_all got_try
    all=$(autoboot_get all) || die "$AUTOBOOT: no boot_partition in [all]"
    try=$(autoboot_get tryboot) || die "$AUTOBOOT: no boot_partition in [tryboot]"
    [ "$all" != "$try" ] ||
        die "$AUTOBOOT: [all] and [tryboot] both name partition $all"
    # Only [tryboot] is validated here, and the asymmetry is deliberate. Every
    # caller resolves get_primary first, which reads [all] and refuses a value
    # that is not a boot slot -- so an [all] check in this function can never
    # fire. It was written, and then removed when a mutation test showed no
    # possible input could tell its presence from its absence. An assertion
    # nothing can falsify is the kind that goes on agreeing with itself after
    # the code around it changes.
    #
    # INVARIANT FOR ANY FUTURE CALLER: resolve get_primary before calling this,
    # or restore that check.
    partition_bootname "$try" > /dev/null ||
        die "$AUTOBOOT: [tryboot] names partition $try, which is not a boot slot"

    # Global, so the EXIT trap can be single-quoted and expand at trap time --
    # the house rule forbids `shellcheck disable=` directives, and a
    # double-quoted trap needs one.
    TMP_SELECTOR="$AUTOBOOT.tmp"
    selector_rw
    trap 'rm -f "$TMP_SELECTOR"; selector_ro' EXIT

    swap_stream "$all" "$try" < "$AUTOBOOT" > "$TMP_SELECTOR"
    sync "$TMP_SELECTOR" 2> /dev/null || sync

    got_all=$(autoboot_get all "$TMP_SELECTOR") ||
        die "refusing to install the new selector: no [all] boot_partition"
    got_try=$(autoboot_get tryboot "$TMP_SELECTOR") ||
        die "refusing to install the new selector: no [tryboot] boot_partition"
    if [ "$got_all" != "$try" ] || [ "$got_try" != "$all" ]; then
        die "refusing to install the new selector: swap produced [all]=$got_all [tryboot]=$got_try"
    fi

    mv -f "$TMP_SELECTOR" "$AUTOBOOT"
    sync
    trap - EXIT
    selector_ro
    warn "committed slot $(partition_bootname "$try") (partition $try)"
}

swap_stream() {
    local all="$1" try="$2" line value
    while IFS= read -r line; do
        case "${line#"${line%%[![:space:]]*}"}" in
            'boot_partition='*)
                value="${line#*=}"
                value="${value%"${value##*[![:space:]]}"}"
                case "$value" in
                    "$all") echo "boot_partition=$try"; continue ;;
                    "$try") echo "boot_partition=$all"; continue ;;
                esac
                ;;
        esac
        echo "$line"
    done
}

# Arm the firmware's one-shot tryboot flag, which is what `reboot "0 tryboot"`
# sets. RAUC never reboots, so it has to be armed ahead of the operator's
# reboot -- and arming it here means a PLAIN `reboot` performs the tryboot,
# which disarms the footgun ROADMAP 4d records as an operational gotcha.
arm_tryboot() {
    command -v "$VCMAILBOX" > /dev/null 2>&1 ||
        die "$VCMAILBOX not found; cannot arm the tryboot flag"
    # 0x00038064 = SET_REBOOT_FLAGS, 4-byte buffer, request 0, value 1.
    "$VCMAILBOX" 0x00038064 4 0 1 > /dev/null ||
        die "vcmailbox refused to set the reboot flags"
    warn "tryboot armed: the next reboot boots the [tryboot] slot, once"
}

# ---------------------------------------------------------------------------
# The five verbs
# ---------------------------------------------------------------------------

get_primary() {
    local partition
    partition=$(autoboot_get all) || die "$AUTOBOOT: no boot_partition in [all]"
    partition_bootname "$partition" ||
        die "$AUTOBOOT: [all] names partition $partition, which is not a boot slot"
}

get_current() {
    local slot
    slot=$(identity_get SLOT) || die "slot-identity.sh reported no SLOT"
    [ "$slot" != unknown ] ||
        die "the running slot is not in $SLOTMAP (verdict: $(identity_get VERDICT))"
    echo "$slot"
}

# good if the slot is the one running, or if a tryboot is in progress -- in
# which case the other slot is the committed one and is known good.
get_state() {
    local bootname="$1" current tryboot
    current=$(get_current)
    if [ "$bootname" = "$current" ]; then echo good; return 0; fi
    tryboot=$(identity_get TRYBOOT) || tryboot=0
    if [ "$tryboot" = 1 ]; then echo good; return 0; fi
    echo bad
}

# "Make this slot the one that boots next."
#
# Not-primary  -> arm tryboot. The [tryboot] section already names it, so one
#                 reboot lands there and a failure returns here by itself.
# Primary, and we are mid-tryboot -> the operator is asking to keep what is
#                 running: commit it.
# Primary, otherwise -> already true, nothing to do.
set_primary() {
    local bootname="$1" primary tryboot
    primary=$(get_primary)
    if [ "$bootname" != "$primary" ]; then arm_tryboot; return 0; fi
    tryboot=$(identity_get TRYBOOT) || tryboot=0
    if [ "$tryboot" = 1 ]; then commit_swap; return 0; fi
    warn "$bootname is already the committed slot; nothing to do"
}

# This is where a tryboot becomes permanent, and it is reached from
# `rauc status mark-good`.
set_state() {
    local bootname="$1" state="$2" primary
    case "$state" in good | bad) ;; *) die "state must be good or bad, got '$state'" ;; esac
    primary=$(get_primary)
    if [ "$bootname" = "$primary" ] && [ "$state" = bad ]; then
        warn "committed slot $bootname marked bad; committing the other slot"
        commit_swap
        return 0
    fi
    if [ "$bootname" != "$primary" ] && [ "$state" = good ]; then
        commit_swap
        return 0
    fi
    warn "$bootname=$state with committed slot $primary: nothing to change"
}

usage() {
    cat >&2 <<-'EOF'
	usage: kosmos-boot-backend.sh <verb> [args]

	  get-primary
	  set-primary <bootname>
	  get-state   <bootname>
	  set-state   <bootname> <good|bad>
	  get-current

	Called by RAUC; see ROADMAP 4d. Bootnames are A and B.
	EOF
    exit 2
}

main() {
    [ $# -ge 1 ] || usage
    local verb="$1"; shift
    case "$verb" in
        get-primary) [ $# -eq 0 ] || die "get-primary takes no arguments"
                     get_primary ;;
        get-current) [ $# -eq 0 ] || die "get-current takes no arguments"
                     get_current ;;
        set-primary) require_bootname "${1:-}" set-primary
                     [ $# -eq 1 ] || die "set-primary takes one argument"
                     set_primary "$1" ;;
        get-state)   require_bootname "${1:-}" get-state
                     [ $# -eq 1 ] || die "get-state takes one argument"
                     get_state "$1" ;;
        set-state)   require_bootname "${1:-}" set-state
                     [ $# -eq 2 ] || die "set-state takes two arguments"
                     set_state "$1" "$2" ;;
        *)           usage ;;
    esac
}

main "$@"
