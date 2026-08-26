#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# KosmOS — build the SATCOM stack from source, inside a rootfs (stage 2b)
# ============================================================================
#   ./build-satcom.sh <rootfs-dir>
#
# Called by image/build-rootfs.sh when --with-satcom is given. An executable
# subprocess, never sourced. Hours, not minutes: it compiles GNU Radio,
# SatDump and SDR++ inside the chroot.
#
# WHY IT IS A SEPARATE FILE. build-rootfs.sh reached 400 lines and could not
# hold the manifest fix of 2026-08-26; the extraction rule fired. The split is
# by concern and not merely by line count -- build-rootfs.sh assembles a root
# filesystem, and this compiles a software stack into one.
#
# ---------------------------------------------------------------------------
# ⚠️ THIS IS THE FILE THAT NEEDS THE REPO, NOT JUST image/. It copies
# ../userspace/*.sh into the rootfs, so a deployment of image/ ALONE cannot run
# it. That is not hypothetical: on 2026-08-26 image/ was deployed to
# /var/tmp/kosmos-img/ without a sibling userspace/, and the build ran for 18
# minutes -- through the base copy, the kernel modules and the whole apt step
# -- before dying on `cp: cannot stat '/var/tmp/userspace/*.sh'`.
#
# So the check for it is the FIRST thing here, before a single expensive step.
# The cost of a missing directory should be one second, not eighteen minutes.
# ============================================================================

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"
USERSPACE="${KOSMOS_USERSPACE_DIR:-$REPO_ROOT/userspace}"

# The scripts run in the chroot, in this order. 03-satcom-stack.sh resolves
# 03a/03b/03c from its own $SELF_DIR, which is why the WHOLE directory goes in
# rather than these two files.
readonly STAGE_SCRIPTS="02c-sdr-userspace.sh 03-satcom-stack.sh"

die()  { echo "build-satcom.sh: $*" >&2; exit 1; }
note() { echo "  $*" >&2; }
step() { echo "==> $*" >&2; }

# Duplicated from build-rootfs.sh rather than sourced, per the house rule that
# helpers are executable subprocesses and scripts repeat a few lines instead of
# sharing a library that would need shellcheck --external-sources.
in_chroot() {
    sudo chroot "$ROOTFS" /usr/bin/env \
        DEBIAN_FRONTEND=noninteractive \
        LC_ALL=C \
        /bin/bash -c "$1"
}

# Everything that can be known before the expensive part starts.
preflight() {
    [ -d "$ROOTFS" ] || die "$ROOTFS: not a directory"
    [ -d "$ROOTFS/usr" ] || die "$ROOTFS: does not look like a root filesystem"
    [ -d "$USERSPACE" ] ||
        die "no userspace directory at $USERSPACE — deploy the repo's userspace/ beside image/, or set KOSMOS_USERSPACE_DIR"

    local s
    for s in $STAGE_SCRIPTS; do
        [ -f "$USERSPACE/$s" ] || die "$USERSPACE/$s: missing"
    done
    note "userspace: $USERSPACE"
}

# KOSMOS_ASSUME_YES=1 is mandatory, not a convenience -- without it every
# script's prompt reads EOF, exits 3, and the sequencer reports SKIPPED, so
# this would succeed having installed nothing. ROADMAP 4a.
main() {
    [ $# -eq 1 ] || die "usage: build-satcom.sh <rootfs-dir>"
    ROOTFS="$1"
    preflight

    step "building the SATCOM stack from source (hours, not minutes)"
    local dst="$ROOTFS/tmp/kosmos-userspace"
    sudo rm -rf "$dst"
    sudo mkdir -p "$dst"
    sudo cp "$USERSPACE"/*.sh "$dst/"
    sudo chmod +x "$dst"/*.sh

    local s
    for s in $STAGE_SCRIPTS; do
        step "chroot: $s"
        in_chroot "KOSMOS_ASSUME_YES=1 bash /tmp/kosmos-userspace/$s" ||
            die "$s failed in chroot"
    done
    sudo rm -rf "$dst"
}

main "$@"
