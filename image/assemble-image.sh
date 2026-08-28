#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — assemble the A/B image (Phase 4a, stage 3)
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
CACHE="${MOLNIYA_BUILD_CACHE:-/var/tmp/molniya-build}"

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
TARGET_DEV="${MOLNIYA_TARGET_DEV:-/dev/mmcblk0}"

# First-boot login. Empty means the image ships unloginable, which is the base
# image's own behaviour and is announced loudly rather than silently shipped.
AUTHORIZED_KEYS=""
LOGIN_USER="${MOLNIYA_LOGIN_USER:-molniya}"

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
    local img="$1" bytes bytes_mib
    bytes=$(layout min-bytes)
    bytes_mib=$(( bytes / 1024 / 1024 ))
    step "creating ${bytes_mib} MiB image at $img"

    # Check against what will actually be WRITTEN, not the apparent size.
    #
    # The image is sparse: `truncate` allocates nothing, and only the bytes the
    # filesystems occupy ever hit the disk. Comparing free space to the apparent
    # size therefore refuses builds that would comfortably succeed — with 6 GiB
    # slots the apparent size is 13856 MiB while the real cost is about
    # 2x rootfs + 2x bootfs, and the first 6 GiB build had 12.8 GiB free and was
    # blocked by a check that was wrong rather than careful.
    #
    # A precheck that fires on builds that would work is not a safety feature;
    # it just teaches people to delete it.
    local avail_mb rootfs_mb bootfs_mb need_mb
    avail_mb=$(df -Pm "$(dirname "$img")" | awk 'NR==2 {print $4}')
    rootfs_mb=$(sudo du -sxm "$ROOTFS" 2>/dev/null | cut -f1 || echo 0)
    bootfs_mb=$(sudo du -sxm "$BOOTFS" 2>/dev/null | cut -f1 || echo 0)
    # Both slots, plus a GiB for the data partition, filesystem overhead and
    # the metadata mkfs writes into otherwise-empty partitions.
    need_mb=$(( 2 * rootfs_mb + 2 * bootfs_mb + 1024 ))
    note "will write ~${need_mb} MiB into a ${bytes_mib} MiB sparse image; ${avail_mb} MiB free"
    [ "${avail_mb:-0}" -ge "$need_mb" ] ||
        die "need ~${need_mb} MB free, have ${avail_mb} MB"

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
    sudo mkfs.ext4 -q -F -L MOLNIYADATA "${LOOPDEV}p7"
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
# a convincing fake. The package ships kernel-molniya.img; the base bootfs ships
# kernel_2712.img and kernel8.img; and the stock config.txt carries no `kernel=`
# line at all, so the firmware auto-selects kernel_2712.img on a Pi 5. Overlay
# the two and you get an image that boots the STOCK kernel with MolniyaOS modules
# sitting unused beside it -- no PREEMPT_RT, no latency guarantee, and nothing
# on the box saying so. Caught before the first assembly rather than after.
#
# The stock kernels are then removed rather than left as a fallback. Inside 4d
# the other slot IS the fallback, so a second kernel in this slot buys nothing
# and leaves an ambiguity that only bites when `kernel=` goes missing. The
# health check asserts the running kernel carries -molniya, which is the backstop
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
# MolniyaOS kernel if one was given.
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
    step "populating root $slot (p$part) — $(sudo du -sxm "$ROOTFS" 2>/dev/null | cut -f1 || echo "?") MiB"
    mount_into "${LOOPDEV}p${part}" "$MNT/root$slot"
    sudo rsync -aHAX --numeric-ids "$ROOTFS/" "$MNT/root$slot/"

    layout fstab "$slot" "$TARGET_DEV" | sudo tee "$MNT/root$slot/etc/fstab" > /dev/null

    sudo mkdir -p "$MNT/root$slot/etc/molniya" "$MNT/root$slot/data"
    layout slotmap | sudo tee "$MNT/root$slot/etc/molniya/slots.conf" > /dev/null

    # The health check and its helper ship inside the image; without them the
    # slot cannot report itself healthy and no update could ever be committed.
    if [ -n "$AUTHORIZED_KEYS" ]; then
        provision_access "$MNT/root$slot" "$LOGIN_USER" "$AUTHORIZED_KEYS"
    fi

    sudo mkdir -p "$MNT/root$slot/usr/local/lib/molniya"
    sudo install -m 0755 "$SELF_DIR/health-check/molniya-health-check.sh" \
        "$SELF_DIR/health-check/slot-identity.sh" \
        "$MNT/root$slot/usr/local/lib/molniya/"

    # The A/B update machinery, extracted at 393/400. See rauc/provision-rauc.sh.
    "$SELF_DIR/rauc/provision-rauc.sh" "$MNT/root$slot" "$slot" "$TARGET_DEV"
}

# Turn the base image's placeholder account into a usable, key-only login.
#
# WITHOUT THIS THE IMAGE BOOTS TO A PROMPT NOBODY CAN ANSWER. Verified in the
# base: `pi` exists at uid 1000 but its password is LOCKED and its shell is
# /usr/sbin/nologin. It is a placeholder that userconfig.service is meant to
# rename at first boot after reading /boot/firmware/userconf.txt. A headless
# appliance shipped without that file therefore has no way in at all -- not by
# console, not by SSH.
#
# Done at build time rather than through userconf.txt because the first-boot
# path depends on service ordering and on files that sshswitch and userconf
# DELETE as they consume them. Provisioning here is deterministic and can be
# inspected in the finished image instead of hoped for on first boot.
#
# Three things that had to be checked rather than assumed, each of which would
# have produced a broken account:
#   - the shell is nologin, so a key alone would not get a session;
#     `usermod -s /bin/bash` is what userconf does and is required here too
#   - the base ships NO /etc/sudoers.d/010_pi-nopasswd, so userconf's sed that
#     patches it is a no-op on Lite. `pi` IS in the sudo group, but the password
#     is locked, so sudo would prompt for a credential that cannot exist. An
#     explicit NOPASSWD drop-in is therefore mandatory, not a convenience.
#   - renaming must be idempotent: stage 3 runs this once per slot, and a second
#     pass finds no `pi` to rename.
provision_access() {
    local root="$1" user="$2" keyfile="$3"

    if sudo chroot "$root" getent passwd pi > /dev/null 2>&1; then
        sudo chroot "$root" usermod -l "$user" pi
        sudo chroot "$root" usermod -m -d "/home/$user" "$user"
        sudo chroot "$root" groupmod -n "$user" pi
    fi
    sudo chroot "$root" usermod -s /bin/bash "$user"

    sudo install -d -m 0700 -o 1000 -g 1000 "$root/home/$user/.ssh"
    sudo install -m 0600 -o 1000 -g 1000 "$keyfile" \
        "$root/home/$user/.ssh/authorized_keys"

    printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$user" |
        sudo tee "$root/etc/sudoers.d/010-molniya-nopasswd" > /dev/null
    sudo chmod 0440 "$root/etc/sudoers.d/010-molniya-nopasswd"

    # The account is provisioned, so the first-boot renamer has nothing to do
    # and would only sit waiting on a console for a userconf.txt that is not
    # coming. Remove the enable symlink directly: no systemctl, no dbus, and
    # the result is visible in the image rather than deferred to boot.
    sudo rm -f "$root/etc/systemd/system/multi-user.target.wants/userconfig.service"

    # Enable sshd outright rather than leaving it to sshswitch's /boot marker.
    # The marker works, but it is opt-in and self-deleting; an appliance whose
    # only access path is SSH should not ship with SSH off by default.
    sudo ln -sf /lib/systemd/system/ssh.service \
        "$root/etc/systemd/system/multi-user.target.wants/ssh.service"

    # Key-only, stated explicitly rather than relying on the locked password to
    # make password auth fail in practice.
    sudo mkdir -p "$root/etc/ssh/sshd_config.d"
    printf 'PasswordAuthentication no\nPermitRootLogin no\n' |
        sudo tee "$root/etc/ssh/sshd_config.d/10-molniya.conf" > /dev/null
}

# The data partition is shared by both slots and survives every update. Seeded
# with the directories, not with content: what lives here is 4b's decision, and
# creating the mount points now means the first boot does not have to.
seed_data() {
    step "seeding the data partition (p7)"
    mount_into "${LOOPDEV}p7" "$MNT/data"
    sudo mkdir -p "$MNT/data/captures" "$MNT/data/tle" "$MNT/data/profiles" "$MNT/data/home"
    # RAUC's data-directory (system.conf names /data/rauc). It holds the record
    # of which slot is good, so it has to be the one thing an update cannot
    # reach -- anywhere under / is inside a slot and gets replaced wholesale.
    sudo mkdir -p "$MNT/data/rauc"
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
        note "WARNING: rootfs has no MolniyaOS modules; this kernel will have none"
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
            --authorized-keys)
                      [ $# -ge 2 ] || die "--authorized-keys needs a path"
                      AUTHORIZED_KEYS="$2"; shift 2 ;;
            -h|--help) sed -n '7,11p' "$SELF_DIR/assemble-image.sh" | sed 's/^# \{0,2\}//'; return 0 ;;
            *) die "unknown argument '$1' (try --help)" ;;
        esac
    done
    [ -z "$kernel_tarball" ] || [ -f "$kernel_tarball" ] ||
        die "no such kernel package: $kernel_tarball"
    [ -z "$AUTHORIZED_KEYS" ] || [ -s "$AUTHORIZED_KEYS" ] ||
        die "authorized_keys file is missing or empty: $AUTHORIZED_KEYS"

    preflight

    local kernel_boot=""
    [ -z "$kernel_tarball" ] || kernel_boot=$(extract_kernel_boot "$kernel_tarball")

    local img="${out:-$CACHE/molniya-rpi5.img}"
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
    [ -n "$kernel_boot" ] || note "WARNING: no kernel placed — this image will not boot MolniyaOS"
    if [ -n "$AUTHORIZED_KEYS" ]; then
        note "login: $LOGIN_USER, key-only, sshd enabled"
    else
        note "WARNING: no --authorized-keys — this image has NO way to log in"
    fi
    echo "$img"
}

main "$@"
