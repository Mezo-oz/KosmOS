#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# KosmOS — assemble the A/B image (Phase 4a, stage 3)
# ============================================================================
# Takes stage 2's rootfs and bootfs and writes them into a partitioned image
# built from image/layout.sh. Prints the image path on stdout.
#
#   ./assemble-image.sh                       assemble from the build cache
#   ./assemble-image.sh --kernel <tarball>    also place kernel/DTBs in each bootfs
#   ./assemble-image.sh --out <path>          write somewhere other than the cache
#
# EVERY NUMBER COMES FROM layout.sh. This script contains no partition numbers,
# no sizes and no offsets of its own; it calls `layout.sh sfdisk`, `autoboot`,
# `cmdline`, `fstab`, `slotmap` and `min-bytes` and does as it is told. That is
# the whole reason layout.sh exists, and this is the consumer it was written
# for.
#
# BOTH SLOTS GET THE SAME ROOTFS. A fresh card therefore has a working fallback
# from its very first boot, before any update has ever run. The alternative --
# ship slot B empty and fill it on first update -- means the rollback everyone
# is relying on does not exist until after the first successful update, which
# is exactly the moment it is most likely to be needed.
#
# SAFETY: this writes filesystems, and it does it through a loop device. It
# never takes a block device as a target -- only a file it creates itself -- so
# there is no argument that can point it at a real disk. Mount bookkeeping and
# teardown follow build-rootfs.sh: mount_into() records, an EXIT trap unmounts
# in reverse, and the loop device is always detached.
# ============================================================================

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYOUT="$SELF_DIR/layout.sh"
CACHE="${KOSMOS_BUILD_CACHE:-/var/tmp/kosmos-build}"

ROOTFS="$CACHE/rootfs"
BOOTFS="$CACHE/bootfs"
MANIFEST="$CACHE/rootfs.manifest"

# The device path the IMAGE will be flashed to. It is baked into cmdline.txt and
# fstab, so it is a property of the image, not of this build host.
#
# It is also the one real limitation of the current layout: root= is a device
# path, so an image built for mmcblk0 will not boot from an NVMe HAT, where the
# same partition is nvme0n1p5. PARTUUID would survive that. Changing it means
# changing layout.sh, which owns the decision -- recorded here because this is
# where someone will first notice.
TARGET_DEV="${KOSMOS_TARGET_DEV:-/dev/mmcblk0}"

MOUNTED=()
LOOPDEV=""
MNT="$CACHE/mnt-image"

die() { echo "assemble-image.sh: $*" >&2; exit 1; }
note() { echo "  $*" >&2; }
step() { echo "==> $*" >&2; }

mount_into() {
    local what="$1" where="$2"
    mkdir -p "$where"
    sudo mount "$what" "$where" || die "mount $what -> $where failed"
    MOUNTED+=("$where")
}

teardown() {
    local rc=$? i
    sync
    for (( i=${#MOUNTED[@]}-1 ; i>=0 ; i-- )); do
        sudo umount "${MOUNTED[i]}" 2>/dev/null || sudo umount -l "${MOUNTED[i]}" 2>/dev/null || true
    done
    MOUNTED=()
    [ -z "$LOOPDEV" ] || { sudo losetup -d "$LOOPDEV" 2>/dev/null || true; LOOPDEV=""; }
    return "$rc"
}
trap teardown EXIT

layout() { "$LAYOUT" "$@"; }

# Copy into a FAT filesystem. NOT `rsync -a`: -a implies -o -g -p, and FAT has
# no ownership or Unix permissions to set, so rsync fails every file with
# "chown ... Operation not permitted" and exits 23. -L rather than -l for the
# same reason -- FAT cannot hold a symlink either, so any that appear must be
# dereferenced instead of failing at the end of a long copy.
copy_to_fat() {
    local src="$1" dst="$2"
    sudo rsync -rLt --no-perms --no-owner --no-group "$src/" "$dst/"
}

preflight() {
    [ "$(id -u)" -ne 0 ] || die "run as an ordinary user; it calls sudo where needed"
    sudo -n true 2>/dev/null || die "needs passwordless sudo"
    [ -x "$LAYOUT" ] || die "layout.sh not found beside this script"
    [ -d "$ROOTFS" ] || die "no rootfs at $ROOTFS — run build-rootfs.sh first"
    [ -d "$BOOTFS" ] || die "no bootfs at $BOOTFS — run build-rootfs.sh first"

    local t
    for t in losetup sfdisk mkfs.vfat mkfs.ext4 rsync; do
        sudo sh -c "command -v $t" > /dev/null 2>&1 || die "$t not found"
    done
}

# Create the file and partition it. truncate makes it sparse, so this costs
# nothing until filesystems are written into it.
create_image() {
    local img="$1" bytes
    bytes=$(layout min-bytes)
    step "creating $((bytes / 1024 / 1024)) MiB image at $img"

    local avail_mb
    avail_mb=$(df -Pm "$(dirname "$img")" | awk 'NR==2 {print $4}')
    local need_mb=$(( bytes / 1024 / 1024 + 256 ))
    [ "${avail_mb:-0}" -ge "$need_mb" ] ||
        die "need ${need_mb} MB free, have ${avail_mb} MB"

    rm -f "$img"
    truncate -s "$bytes" "$img"
    layout sfdisk | sudo sfdisk --quiet "$img" || die "sfdisk failed"

    LOOPDEV=$(sudo losetup --show -fP "$img") || die "losetup failed"
    note "loop: $LOOPDEV"
    # The kernel creates the partition nodes asynchronously; p7 in particular
    # is the last to appear and mkfs races it on a busy box.
    sudo partprobe "$LOOPDEV" 2>/dev/null || true
    local tries=0
    while [ ! -e "${LOOPDEV}p7" ] && [ "$tries" -lt 50 ]; do
        tries=$((tries + 1)); sleep 0.1
    done
    [ -e "${LOOPDEV}p7" ] || die "partition nodes never appeared for $LOOPDEV"
}

make_filesystems() {
    step "making filesystems"
    sudo mkfs.vfat -F 16 -n RPIBOOT    "${LOOPDEV}p1" > /dev/null
    sudo mkfs.vfat -F 32 -n BOOT_A     "${LOOPDEV}p2" > /dev/null
    sudo mkfs.vfat -F 32 -n BOOT_B     "${LOOPDEV}p3" > /dev/null
    sudo mkfs.ext4 -q -F -L ROOT_A     "${LOOPDEV}p5"
    sudo mkfs.ext4 -q -F -L ROOT_B     "${LOOPDEV}p6"
    sudo mkfs.ext4 -q -F -L KOSMOSDATA "${LOOPDEV}p7"
}

# p1 holds autoboot.txt and nothing else. Slot A is the default for a fresh
# image; the [tryboot] section already names B, so the first update has
# somewhere to go without this file being touched.
write_selector() {
    step "writing the slot selector (p1)"
    mount_into "${LOOPDEV}p1" "$MNT/selector"
    layout autoboot A | sudo tee "$MNT/selector/autoboot.txt" > /dev/null
}

# Point config.txt at our kernel, and take the stock one out of the slot.
#
# THIS IS THE STEP THAT DECIDES WHICH KERNEL RUNS, and without it the image is
# a convincing fake. The package ships kernel-kosmos.img; the base bootfs ships
# kernel_2712.img and kernel8.img; and the stock config.txt carries no `kernel=`
# line at all, so the firmware auto-selects kernel_2712.img on a Pi 5. Overlay
# the two and you get an image that boots the STOCK kernel with KosmOS modules
# sitting unused beside it -- no PREEMPT_RT, no latency guarantee, and nothing
# on the box saying so. Caught before the first assembly rather than after.
#
# The stock kernels are then removed rather than left as a fallback. Inside 4d
# the other slot IS the fallback, so a second kernel in this slot buys nothing
# and leaves an ambiguity that only bites when `kernel=` goes missing. The
# health check asserts the running kernel carries -kosmos, which is the backstop
# if this is ever got wrong again.
arm_kernel() {
    local bootdir="$1" kernel_boot="$2" kimg
    kimg=$(find "$kernel_boot" -maxdepth 1 -name 'kernel*.img' -printf '%f\n' | head -1)
    [ -n "$kimg" ] || die "kernel package has no kernel*.img in boot/"

    local f
    for f in "$bootdir"/kernel*.img; do
        [ -e "$f" ] || continue
        [ "$(basename "$f")" = "$kimg" ] || sudo rm -f "$f"
    done

    sudo sed -i '/^[[:space:]]*kernel=/d' "$bootdir/config.txt"
    printf '\n[all]\nkernel=%s\n' "$kimg" | sudo tee -a "$bootdir/config.txt" > /dev/null
    note "armed: kernel=$kimg (stock kernels removed from this slot)"
}

# One slot's bootfs: the base boot files, this slot's cmdline.txt, and the
# KosmOS kernel if one was given.
populate_bootfs() {
    local slot="$1" part="$2" kernel_boot="$3"
    step "populating bootfs $slot (p$part)"
    mount_into "${LOOPDEV}p${part}" "$MNT/boot$slot"
    copy_to_fat "$BOOTFS" "$MNT/boot$slot"

    if [ -n "$kernel_boot" ]; then
        copy_to_fat "$kernel_boot" "$MNT/boot$slot"
        arm_kernel "$MNT/boot$slot" "$kernel_boot"
    fi

    layout cmdline "$slot" "$TARGET_DEV" | sudo tee "$MNT/boot$slot/cmdline.txt" > /dev/null
}

# One slot's root: the rootfs, this slot's fstab, and the slot map the health
# check reads. Written twice, once per slot, deliberately.
populate_root() {
    local slot="$1" part="$2"
    step "populating root $slot (p$part) — about 2.2 GB"
    mount_into "${LOOPDEV}p${part}" "$MNT/root$slot"
    sudo rsync -aHAX --numeric-ids "$ROOTFS/" "$MNT/root$slot/"

    layout fstab "$slot" "$TARGET_DEV" | sudo tee "$MNT/root$slot/etc/fstab" > /dev/null

    sudo mkdir -p "$MNT/root$slot/etc/kosmos" "$MNT/root$slot/data"
    layout slotmap | sudo tee "$MNT/root$slot/etc/kosmos/slots.conf" > /dev/null

    # The health check and its helper ship inside the image; without them the
    # slot cannot report itself healthy and no update could ever be committed.
    sudo mkdir -p "$MNT/root$slot/usr/local/lib/kosmos"
    sudo install -m 0755 "$SELF_DIR/health-check/kosmos-health-check.sh" \
        "$SELF_DIR/health-check/slot-identity.sh" \
        "$MNT/root$slot/usr/local/lib/kosmos/"
}

# The data partition is shared by both slots and survives every update. Seeded
# with the directories, not with content: what lives here is 4b's decision, and
# creating the mount points now means the first boot does not have to.
seed_data() {
    step "seeding the data partition (p7)"
    mount_into "${LOOPDEV}p7" "$MNT/data"
    sudo mkdir -p "$MNT/data/captures" "$MNT/data/tle" "$MNT/data/profiles" "$MNT/data/home"
    layout slotmap | sudo tee "$MNT/data/slots.conf" > /dev/null
}

# Unpack the kernel package and hand back the directory holding its boot files.
# Stage 2 installed this package's modules into the rootfs; this places the
# other half. If the two ever come from different packages the box boots a
# kernel whose modules it does not have, so the version is checked against what
# stage 2 recorded.
extract_kernel_boot() {
    local tarball="$1" tmp="$CACHE/kernel-boot"
    sudo rm -rf "$tmp"; mkdir -p "$tmp"
    tar -xzf "$tarball" -C "$tmp" || die "cannot unpack $tarball"

    local pkg
    pkg=$(find "$tmp" -maxdepth 2 -name kernel-version -printf '%h\n' | head -1)
    [ -n "$pkg" ] || die "$tarball has no kernel-version file"

    local kver
    kver=$(tr -d '[:space:]' < "$pkg/kernel-version")
    if [ -f "$CACHE/kernel-version" ]; then
        local staged
        staged=$(tr -d '[:space:]' < "$CACHE/kernel-version")
        [ "$staged" = "$kver" ] ||
            die "kernel mismatch: rootfs has modules for $staged, this package is $kver"
    else
        note "WARNING: rootfs has no KosmOS modules; this kernel will have none"
    fi

    [ -d "$pkg/boot" ] || die "$tarball has no boot/ directory"
    echo "$pkg/boot"
}

main() {
    local kernel_tarball="" out=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --kernel) [ $# -ge 2 ] || die "--kernel needs a path"; kernel_tarball="$2"; shift 2 ;;
            --out)    [ $# -ge 2 ] || die "--out needs a path"; out="$2"; shift 2 ;;
            -h|--help) sed -n '7,11p' "$SELF_DIR/assemble-image.sh" | sed 's/^# \{0,2\}//'; return 0 ;;
            *) die "unknown argument '$1' (try --help)" ;;
        esac
    done
    [ -z "$kernel_tarball" ] || [ -f "$kernel_tarball" ] ||
        die "no such kernel package: $kernel_tarball"

    preflight

    local kernel_boot=""
    [ -z "$kernel_tarball" ] || kernel_boot=$(extract_kernel_boot "$kernel_tarball")

    local img="${out:-$CACHE/kosmos-rpi5.img}"
    create_image "$img"
    make_filesystems
    write_selector
    populate_bootfs A 2 "$kernel_boot"
    populate_bootfs B 3 "$kernel_boot"
    populate_root A 5
    populate_root B 6
    seed_data

    teardown
    trap teardown EXIT

    [ ! -f "$MANIFEST" ] || sudo cp "$MANIFEST" "${img}.manifest"
    step "image ready: $img"
    [ -n "$kernel_boot" ] || note "WARNING: no kernel placed — this image will not boot KosmOS"
    echo "$img"
}

main "$@"
