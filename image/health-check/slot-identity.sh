#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# KosmOS — which A/B slot am I actually running? (Phase 4d)
# ============================================================================
# Prints facts on stdout as KEY=VALUE. It renders no verdict: the caller decides
# what a mismatch is worth. Same shape as benchmarks/detect-config.sh,
# governor.sh and thermal-state.sh -- an executable subprocess returning data,
# never a sourced library.
#
#   ./slot-identity.sh
#   BOOT_PARTITION=2
#   ROOT_PARTITION=5
#   TRYBOOT=0
#   SLOT=A
#   VERDICT=consistent
#
# VERDICT is one of:
#   consistent   boot partition and root partition are the same slot
#   mismatch     they are different slots -- a cross-slot boot
#   unmapped     the layout is known but this pairing is not in it
#   no-slotmap   /etc/kosmos/slots.conf absent; not an A/B image
#
# Exit 0 whenever the facts could be gathered, whatever they say -- including
# `mismatch`. A non-zero exit means the question could not be ANSWERED (no
# device tree, unreadable root device), which is a different thing from a bad
# answer and the caller must be able to tell them apart.
#
# WHY THIS IS NOT IN kosmos-health-check.sh: that file was at 372 of its 400
# lines, and ROADMAP's extraction rule fires on a file that exceeds the cap and
# cannot lose the lines elsewhere. It was also flagged in the ROADMAP one commit
# before this one as the file whose next addition would have to go beside it.
#
# WHY THIS DOES NOT NEED RAUC: it was recorded in 4d as a check that had to wait
# for RAUC. That was wrong. The Raspberry Pi firmware publishes both facts into
# the device tree at boot, so they are readable on any Pi 5, today, with nothing
# installed.
# ============================================================================

set -euo pipefail

DT_BOOTLOADER="/proc/device-tree/chosen/bootloader"
SLOTMAP="${KOSMOS_SLOTMAP:-/etc/kosmos/slots.conf}"

die() { echo "slot-identity.sh: $*" >&2; exit 1; }

# Device-tree cells are BIG-ENDIAN, and reading them as native integers is a
# trap that returns a plausible number rather than an error: `od -An -tu4` on
# the partition cell yields 16777216 where the answer is 1. Measured on
# pi-server 2026-08-23. This is the read the Raspberry Pi documentation itself
# prescribes -- bytes to hex, hex to decimal, no endianness assumed anywhere.
dt_u32() {
    local path="$1" hex
    [ -r "$path" ] || return 1
    hex=$(od -v -An -tx1 "$path" | tr -d ' \n')
    [ -n "$hex" ] || return 1
    printf '%d' "$((16#$hex))"
}

# The partition number of the filesystem currently mounted at /.
#
# Asked of lsblk rather than parsed off the device name. Stripping trailing
# digits works for /dev/sda2 and breaks on /dev/mmcblk0p2, where the naive
# answer is 2 by luck and /dev/nvme0n1p12 would give 12 from a name whose
# namespace digit is also in the way. PARTN is the kernel's own answer.
root_partition() {
    local src partn
    src=$(findmnt -n -o SOURCE / 2>/dev/null) || return 1
    [ -n "$src" ] || return 1
    partn=$(lsblk -ndo PARTN "$src" 2>/dev/null | tr -d ' ') || return 1
    [ -n "$partn" ] || return 1
    echo "$partn"
}

# Read one key out of the generated slot map without sourcing it. This runs as
# root during boot; sourcing would turn a corrupted or tampered config file
# into arbitrary code. Values are constrained to digits for the same reason.
slotmap_get() {
    local key="$1" line value
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

main() {
    [ $# -eq 0 ] || die "takes no arguments (got: $*)"
    [ -d "$DT_BOOTLOADER" ] ||
        die "no $DT_BOOTLOADER — not a Raspberry Pi firmware boot"

    local boot_partition tryboot root_part
    boot_partition=$(dt_u32 "$DT_BOOTLOADER/partition") ||
        die "cannot read $DT_BOOTLOADER/partition"
    # tryboot is absent on firmware too old to report it; absent is not 1.
    tryboot=$(dt_u32 "$DT_BOOTLOADER/tryboot") || tryboot=0
    root_part=$(root_partition) || die "cannot determine the root partition"

    echo "BOOT_PARTITION=$boot_partition"
    echo "ROOT_PARTITION=$root_part"
    echo "TRYBOOT=$tryboot"

    if [ ! -r "$SLOTMAP" ]; then
        # Not an error. A pre-4d KosmOS install is a single-root image with no
        # slots at all, and saying "mismatch" about a box that has none would
        # be a false alarm in the direction that reverts good updates.
        echo "SLOT=unknown"
        echo "VERDICT=no-slotmap"
        return 0
    fi

    local a_boot a_root b_boot b_root
    a_boot=$(slotmap_get KOSMOS_SLOT_A_BOOT) || die "$SLOTMAP: bad KOSMOS_SLOT_A_BOOT"
    a_root=$(slotmap_get KOSMOS_SLOT_A_ROOT) || die "$SLOTMAP: bad KOSMOS_SLOT_A_ROOT"
    b_boot=$(slotmap_get KOSMOS_SLOT_B_BOOT) || die "$SLOTMAP: bad KOSMOS_SLOT_B_BOOT"
    b_root=$(slotmap_get KOSMOS_SLOT_B_ROOT) || die "$SLOTMAP: bad KOSMOS_SLOT_B_ROOT"

    # Name the slot from the partition the FIRMWARE chose, not from the root.
    # The firmware's choice is the one autoboot.txt made and the one a rollback
    # changes; the root is downstream of it, named by that slot's cmdline.txt.
    # So the boot partition is the identity and the root is what gets checked
    # against it.
    local boot_slot="" root_slot=""
    case "$boot_partition" in
        "$a_boot") boot_slot=A ;;
        "$b_boot") boot_slot=B ;;
    esac
    case "$root_part" in
        "$a_root") root_slot=A ;;
        "$b_root") root_slot=B ;;
    esac

    if [ -z "$boot_slot" ] || [ -z "$root_slot" ]; then
        echo "SLOT=unknown"
        echo "VERDICT=unmapped"
        return 0
    fi

    echo "SLOT=$boot_slot"
    if [ "$boot_slot" = "$root_slot" ]; then
        echo "VERDICT=consistent"
    else
        # bootfs from one slot, root from the other. The box runs, and looks
        # fine, and the next update overwrites the root it is running from.
        echo "ROOT_SLOT=$root_slot"
        echo "VERDICT=mismatch"
    fi
}

main "$@"
