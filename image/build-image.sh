#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — the release artifact (Phase 4a, stage 4)
# ============================================================================
# Sequences stages 1-3, slims the result, records what was built, verifies it,
# and hands over a compressed image.
#
#   ./build-image.sh                  build (resuming what exists); print .img path
#   ./build-image.sh --stream         ... and write the .img.gz to STDOUT
#   ./build-image.sh --slim-image <p> drop orphan module trees from an existing .img
#   ./build-image.sh --force          rebuild stages whose product already exists
#
# THE COMPRESSED IMAGE GOES TO STDOUT AND IS NEVER WRITTEN HERE. That is the
# whole point of --stream, and it is a disk decision before it is a design one:
# the assembled image is 11 GB on disk and the build host has 2.2 GB free, so
# there is nowhere to put a .img.gz beside it. Compressing in place would need
# the 5 GB rootfs cache deleted first -- and that cache is the difference
# between a failed boot test costing minutes and costing two hours, at exactly
# the moment first boots are most likely to fail.
#
#   ssh pi-server 'molniya-img/build-image.sh --stream' > molniya-rpi5.img.gz
#
# The image has to leave this box anyway: nothing here can flash it (one block
# device, the card it runs from), so the card is written from another machine.
# Streaming makes the move and the compression one pass instead of compressing
# locally and then transferring the result.
#
# THE DIGEST IS OF THE RAW IMAGE, taken before compression, and written to
# <image>.sha256 on this host. It is what the receiving end checks after
# decompressing, so a truncated transfer or a shell that "helpfully" re-encodes
# binary stdout is caught rather than flashed. That is not hypothetical: a
# PowerShell 5.x redirect corrupts binary stdout silently.
#
# WHAT IT DOES NOT DO: boot the image. See verify-image.sh -- everything either
# script can tell you is structural.
# ============================================================================

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE="${MOLNIYA_BUILD_CACHE:-/var/tmp/molniya-build}"
IMG="$CACHE/molniya-rpi5.img"
KERNEL_TARBALL="${MOLNIYA_KERNEL_TARBALL:-}"   # empty -> resolved before stage 1
AUTHORIZED_KEYS="${MOLNIYA_AUTHORIZED_KEYS:-$CACHE/authorized_keys}"

MOUNTED=()
LOOPDEV=""
FORCE=0
STREAM=0

die() { echo "build-image.sh: $*" >&2; exit 1; }
note() { echo "  $*" >&2; }
step() { echo "==> $*" >&2; }

teardown() {
    local rc=$? i
    sync
    for (( i=${#MOUNTED[@]} - 1; i >= 0; i-- )); do
        sudo umount "${MOUNTED[i]}" 2>/dev/null || sudo umount -l "${MOUNTED[i]}" 2>/dev/null || true
    done
    MOUNTED=()
    [ -z "$LOOPDEV" ] || { sudo losetup -d "$LOOPDEV" 2>/dev/null || true; LOOPDEV=""; }
    return "$rc"
}
trap teardown EXIT

manifest_kernel() {
    local m="$1"
    [ -f "$m" ] || return 1
    awk '$1 == "kernel" { print $2 }' "$m"
}

# The kernel package is a build product with a version in its name, so a
# hardcoded default here goes stale for two independent reasons -- and both have
# already happened. The version moves on every kernel rebuild; and the 2026-08-28
# rename rewrote this path to a file that does not exist, because the tarball on
# disk is still kosmos-named. That is not an oversight to correct by renaming the
# file: the kernel BINARY inside it is 6.12.98-kosmos+, and a molniya-named
# package carrying a kosmos kernel is a name disagreeing with its bytes.
#
# So the directory is named and the file is discovered. EXACTLY ONE match is
# required. Picking the newest of several would silently build an image against a
# kernel nobody chose, and the mismatch would not surface until the box booted a
# kernel whose modules it does not have.
resolve_kernel_tarball() {
    if [ -n "$KERNEL_TARBALL" ]; then
        [ -f "$KERNEL_TARBALL" ] || die "no kernel tarball at $KERNEL_TARBALL"
        return 0
    fi

    local dir="${MOLNIYA_KERNEL_DIR:-$HOME/molniya}"
    local found=()
    [ -d "$dir" ] || die "no kernel package directory at $dir"

    while IFS= read -r f; do
        found+=("$f")
    done < <(find "$dir" -maxdepth 1 -type f -name '*-kernel-*.tar.gz' | sort)

    case "${#found[@]}" in
        1) KERNEL_TARBALL="${found[0]}"
           note "kernel package: $KERNEL_TARBALL" ;;
        0) die "no *-kernel-*.tar.gz in $dir (set MOLNIYA_KERNEL_TARBALL)" ;;
        *) printf '  %s\n' "${found[@]}" >&2
           die "${#found[@]} kernel packages in $dir — set MOLNIYA_KERNEL_TARBALL" ;;
    esac
}

# ----------------------------------------------------------------------------
# Stages 1-3. Each already knows how to be re-run, so the sequencer's only job
# is to decide whether re-running is wanted -- and by default it is not: a full
# SATCOM rootfs is roughly two hours, and rebuilding it to change a compression
# flag is how a sequencer becomes something nobody runs.
# ----------------------------------------------------------------------------
stage_fetch() {
    step "stage 1 — base image"
    "$SELF_DIR/fetch-base.sh" > /dev/null || die "fetch-base.sh failed"
}

stage_rootfs() {
    local m="$CACHE/rootfs.manifest"
    if [ "$FORCE" -eq 0 ] && [ -f "$m" ] && [ -d "$CACHE/rootfs/usr" ]; then
        note "stage 2 — rootfs present ($(manifest_kernel "$m")), keeping it"
        return 0
    fi
    step "stage 2 — rootfs (this is the two-hour one)"
    [ -f "$KERNEL_TARBALL" ] || die "no kernel tarball at $KERNEL_TARBALL"
    "$SELF_DIR/build-rootfs.sh" --kernel "$KERNEL_TARBALL" --with-satcom \
        || die "build-rootfs.sh failed"
}

stage_assemble() {
    if [ "$FORCE" -eq 0 ] && [ -f "$IMG" ] && [ -f "$IMG.manifest" ]; then
        note "stage 3 — image present, keeping it"
        return 0
    fi
    step "stage 3 — assemble"
    [ -s "$AUTHORIZED_KEYS" ] || die "no authorized_keys at $AUTHORIZED_KEYS"
    "$SELF_DIR/assemble-image.sh" --kernel "$KERNEL_TARBALL" \
        --authorized-keys "$AUTHORIZED_KEYS" > /dev/null || die "assemble-image.sh failed"
}

# ----------------------------------------------------------------------------
# Slimming. Stage 3 deletes the stock kernels from each slot's bootfs, which
# makes the stock module trees in each root unloadable by anything -- 64 MiB of
# modules for a kernel image that is not in the slot. Stage 2 leaves them
# deliberately: it does not get to depend on a later stage's decision. Stage 4
# is where that decision is already made, so this is where they go.
#
# ORPHAN IS DEFINED AGAINST THE MANIFEST, not against a hardcoded "6.18.34".
# A version written into this file would keep matching after the base image is
# bumped, and quietly stop deleting anything.
# ----------------------------------------------------------------------------
prune_module_trees() {
    local moddir="$1" keep="$2" scope="$3"
    local tree ver freed=0
    [ -d "$moddir" ] || return 0
    for tree in "$moddir"/*; do
        [ -d "$tree" ] || continue
        ver="$(basename "$tree")"
        [ "$ver" != "$keep" ] || continue
        freed=$(( freed + $(sudo du -sxm "$tree" | cut -f1) ))
        sudo rm -rf -- "$tree"
        note "$scope: removed modules for $ver"
    done
    [ "$freed" -eq 0 ] || note "$scope: freed $freed MiB"
}

slim_rootfs() {
    local m="$CACHE/rootfs.manifest" keep
    keep="$(manifest_kernel "$m")" || die "no kernel in $m"
    step "slim — orphan module trees in the rootfs cache (keeping $keep)"
    prune_module_trees "$CACHE/rootfs/lib/modules" "$keep" "rootfs"
}

# LOOK BEFORE WRITING. This scan exists because mounting an ext4 filesystem
# read-write CHANGES IT even when not one file is touched: the superblock's
# mount count and last-mount time are updated at mount, and the journal is
# replayed and closed at umount. Measured, not assumed -- two consecutive
# --slim-image runs over the same image, the second removing nothing, produced
# two different sha256 digests.
#
# For a build script that would be a curiosity. For this one it is a defect:
# the digest is the artifact's identity, it is what the far end checks after
# flashing, and re-running stage 4 would silently invalidate a hash that had
# already been published beside a download. So a run with nothing to remove
# must not touch the image at all, and that can only be known by looking first.
scan_orphans() {
    local img="$1" keep="$2"
    local part dir orphans=""
    LOOPDEV="$(sudo losetup -r -P -f --show "$img")" || die "losetup failed"
    for part in 5 6; do
        dir="$CACHE/mnt-slim/p$part"
        mkdir -p "$dir"
        sudo mount -o ro "${LOOPDEV}p${part}" "$dir" || die "mount p$part failed"
        MOUNTED+=("$dir")
        orphans+="$(sudo find "$dir/lib/modules" -mindepth 1 -maxdepth 1 \
            -type d -not -name "$keep" -printf 'x' 2>/dev/null || true)"
    done
    teardown
    [ -n "$orphans" ]
}

# Slimming an image that is ALREADY assembled, which is the case whenever the
# image predates this stage. This is the only place in the 4a scripts that
# writes to a finished image, so it re-hashes afterwards and the caller
# re-verifies.
slim_image() {
    local img="$1" keep part dir
    keep="$(manifest_kernel "$img.manifest")" || die "no manifest beside $img"
    step "slim — orphan module trees in $img (keeping $keep)"
    if ! scan_orphans "$img" "$keep"; then
        note "none found — leaving the image byte-identical"
        return 0
    fi
    LOOPDEV="$(sudo losetup -P -f --show "$img")" || die "losetup failed"
    for part in 5 6; do
        dir="$CACHE/mnt-slim/p$part"
        mkdir -p "$dir"
        sudo mount "${LOOPDEV}p${part}" "$dir" || die "mount p$part failed"
        MOUNTED+=("$dir")
        prune_module_trees "$dir/lib/modules" "$keep" "p$part"
    done
    teardown
}

# ----------------------------------------------------------------------------
# Provenance. Both files sit beside the image and both describe the RAW image,
# because that is what the far end has after decompressing.
# ----------------------------------------------------------------------------
record_hash() {
    local img="$1"
    step "digest — sha256 of the raw image"
    ( cd "$(dirname "$img")" && sha256sum "$(basename "$img")" ) > "$img.sha256"
    note "$(cut -d' ' -f1 < "$img.sha256")"
    note "written to $img.sha256"
}

run_verify() {
    local img="$1"
    step "verify — structural checks against layout.sh"
    "$SELF_DIR/verify-image.sh" --release "$img" >&2 \
        || die "verification failed — not shipping this image"
}

# Compression is gzip and not xz or zstd for one reason that outranks ratio:
# Raspberry Pi Imager reads .img.gz directly, so the flashing step stays
# "select the file" instead of "decompress 11 GB somewhere first". pigz is used
# when present because this is four cores and the difference is minutes.
emit_stream() {
    local img="$1"
    local -a gz=(gzip -c)
    # Not `command -v pigz && gz=(...)`: under set -e a missing pigz makes that
    # list the failing statement and kills the script at the last step.
    if command -v pigz > /dev/null 2>&1; then
        gz=(pigz -c -p "$(nproc)")
    fi
    step "stream — ${gz[0]} to stdout ($(du -h --apparent-size "$img" | cut -f1) apparent)"
    note "the receiving end must check the digest in $img.sha256"
    "${gz[@]}" -- "$img"
}

usage() { sed -n '7,11p' "$SELF_DIR/build-image.sh" | sed 's/^# \{0,2\}//'; }

# The path is this script's normal stdout, in the same style as fetch-base.sh --
# but under --stream stdout is the image itself, and one more line on it appends
# "/var/tmp/.../molniya-rpi5.img\n" to the gzip stream. gzip ignores trailing
# junk, so the .gz still decompresses; the corruption is invisible until a
# byte-for-byte comparison or a checksum. Which is exactly why the digest is
# taken of the raw image and checked on the far side.
finish() {
    local img="$1"
    if [ "$STREAM" -eq 1 ]; then note "streamed: $img"; else echo "$img"; fi
}

main() {
    local slim_target=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --stream)     STREAM=1; shift ;;
            --force)      FORCE=1; shift ;;
            --slim-image) [ $# -ge 2 ] || die "--slim-image needs a path"
                          slim_target="$2"; shift 2 ;;
            -h|--help)    usage; return 0 ;;
            *)            die "unknown argument '$1' (try --help)" ;;
        esac
    done

    if [ -n "$slim_target" ]; then
        [ -f "$slim_target" ] || die "no image at $slim_target"
        slim_image "$slim_target"
        record_hash "$slim_target"
        run_verify "$slim_target"
        [ "$STREAM" -eq 0 ] || emit_stream "$slim_target"
        finish "$slim_target"
        return 0
    fi

    # Sending a finished image needs no base image, no rootfs and no assembly.
    # Without this, --stream on a host that already had the artifact still ran
    # stage 1 -- which on 2026-08-26 failed its disk precheck and blocked the
    # transfer on the very box whose tight disk is the reason --stream exists.
    #
    # The integrity steps are deliberately NOT skipped: the digest is recomputed
    # and the image re-verified below before a single byte goes out. What is
    # skipped is only the work that would REBUILD an artifact that already
    # exists. --force still forces the full path.
    if [ "$STREAM" -eq 1 ] && [ "$FORCE" -eq 0 ] &&
       [ -f "$IMG" ] && [ -f "$IMG.manifest" ]; then
        note "image present — verifying and streaming it, no build stages"
    else
        # Resolved once, here, rather than inside the two stages that consume it.
        # stage_rootfs guarded it and stage_assemble did not, so on a resume --
        # rootfs cached, image not, which is the common case -- a bad path got
        # past the guard and died inside assemble-image.sh after the loop device
        # and the mounts were already up.
        resolve_kernel_tarball
        stage_fetch
        stage_rootfs
        slim_rootfs
        stage_assemble
    fi
    record_hash "$IMG"
    run_verify "$IMG"
    [ "$STREAM" -eq 0 ] || emit_stream "$IMG"
    finish "$IMG"
}

main "$@"
