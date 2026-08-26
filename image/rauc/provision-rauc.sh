#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# KosmOS — install the A/B update machinery into one slot's root (Phase 4d)
# ============================================================================
#   ./provision-rauc.sh <slot-root-dir> <A|B> <target-dev>
#
# Called by image/assemble-image.sh once per slot. An executable subprocess,
# never sourced -- the same shape as the helpers the extraction rule produced
# for run-latency-bench.sh.
#
# WHY IT IS A SEPARATE FILE. assemble-image.sh was at 393 of its 400 lines and
# this work is ~35, so the extraction rule fired exactly as written: the file
# could not hold the new logic and had nothing to lose elsewhere. Splitting by
# CONCERN rather than by line count is what makes that a real boundary -- the
# assembler builds an image, this installs the update mechanism into it, and
# neither needs to know how the other works.
#
# It writes only inside the slot root it is handed. Nothing here touches the
# build host, the loop device, or the partition table.
# ============================================================================

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYOUT="$SELF_DIR/../layout.sh"

die()  { echo "provision-rauc.sh: $*" >&2; exit 1; }
note() { echo "  $*" >&2; }

main() {
    [ $# -eq 3 ] || die "usage: provision-rauc.sh <slot-root-dir> <A|B> <target-dev>"
    local root="$1" slot="$2" dev="$3"

    [ -d "$root" ] || die "$root: not a directory"
    case "$slot" in A | B) ;; *) die "slot must be A or B, got '$slot'" ;; esac
    [ -x "$LAYOUT" ] || die "layout.sh not found at $LAYOUT"

    # The mountpoint for p1, the slot selector. layout.sh's fstab names it, and
    # without the directory the mount silently does not happen -- leaving the
    # backend unable to reach the one file it exists to rewrite. That was the
    # state of the image until 2026-08-26.
    sudo mkdir -p "$root/boot/selector"

    sudo mkdir -p "$root/usr/local/lib/kosmos"
    sudo install -m 0755 \
        "$SELF_DIR/kosmos-boot-backend.sh" \
        "$SELF_DIR/kosmos-mark-good.sh" \
        "$root/usr/local/lib/kosmos/"

    sudo mkdir -p "$root/etc/rauc"
    "$LAYOUT" rauc "$dev" | sudo tee "$root/etc/rauc/system.conf" > /dev/null

    sudo install -m 0644 "$SELF_DIR/kosmos-mark-good.service" \
        "$root/etc/systemd/system/kosmos-mark-good.service"

    # Enabled by symlink rather than `systemctl enable`: there is no running
    # systemd inside a loop-mounted image, and the result is visible in the
    # artifact instead of deferred to first boot. Same reasoning the assembler
    # uses for ssh.service.
    sudo mkdir -p "$root/etc/systemd/system/multi-user.target.wants"
    sudo ln -sf /etc/systemd/system/kosmos-mark-good.service \
        "$root/etc/systemd/system/multi-user.target.wants/kosmos-mark-good.service"

    note "slot $slot: rauc system.conf, backend, selector mountpoint, mark-good enabled"
}

main "$@"
