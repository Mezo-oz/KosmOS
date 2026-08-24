#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# KosmOS — build the root filesystem in a chroot (Phase 4a, stage 2)
# ============================================================================
# Takes the pinned base image from stage 1 and turns it into a KosmOS rootfs.
# Products, both directories under the build cache, both consumed by stage 3:
#
#   $CACHE/rootfs/          the root filesystem, written into BOTH slots
#   $CACHE/bootfs/          the base boot partition contents
#   $CACHE/rootfs.manifest  what went in: base image, kernel, scripts that ran
#
#   ./build-rootfs.sh                     prep + apt-based userspace
#   ./build-rootfs.sh --kernel <tarball>  also install KosmOS kernel modules
#   ./build-rootfs.sh --with-satcom       also run the source-building scripts
#   ./build-rootfs.sh --prep-only         extract and neutralise, install nothing
#   ./build-rootfs.sh --shell             prep, then an interactive chroot shell
#
# THE KERNEL PACKAGE SPLITS ACROSS TWO STAGES, which is not obvious and is worth
# stating before someone "fixes" it: modules/ belongs to the rootfs and is
# installed here; boot/ (kernel, DTBs, overlays) belongs to each slot's bootfs
# and is placed by stage 3. install-kernel.sh does both at once because it
# targets a live box, and it also uses os_prefix to co-exist with the stock
# kernel on a shared boot partition. Neither applies here: in the A/B layout a
# slot's bootfs holds only our kernel, and the slot IS the isolation. So this
# stage deliberately does not call install-kernel.sh.
#
# ----------------------------------------------------------------------------
# SAFETY — read this before editing
# ----------------------------------------------------------------------------
# This script bind-mounts /dev, /proc and /sys into a directory it also deletes
# and rewrites. Those two facts together are why it is the most dangerous
# script in this repo, and the failure is not subtle: `rm -rf` over a tree with
# /dev still bound under it walks straight out of the work directory and into
# the host.
#
# Three rules, all enforced below rather than remembered:
#   1. every mount goes through mount_into(), which records it
#   2. teardown runs from an EXIT trap, unmounting in reverse order, so it
#      happens on failure and on Ctrl-C, not only on the success path
#   3. nothing is deleted until findmnt confirms the tree carries no mounts
# ============================================================================

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"
CACHE="${KOSMOS_BUILD_CACHE:-/var/tmp/kosmos-build}"

ROOTFS="$CACHE/rootfs"
BOOTFS="$CACHE/bootfs"
MANIFEST="$CACHE/rootfs.manifest"

MOUNTED=()
LOOPDEV=""

die() { echo "build-rootfs.sh: $*" >&2; exit 1; }
note() { echo "  $*" >&2; }
step() { echo "==> $*" >&2; }

# --- Mount bookkeeping ------------------------------------------------------

mount_into() {
    local what="$1" where="$2"
    shift 2
    mkdir -p "$where"
    sudo mount "$@" "$what" "$where" || die "mount $what -> $where failed"
    MOUNTED+=("$where")
}

teardown() {
    local rc=$?
    local i
    for (( i=${#MOUNTED[@]}-1 ; i>=0 ; i-- )); do
        sudo umount -l "${MOUNTED[i]}" 2>/dev/null || true
    done
    MOUNTED=()
    [ -z "$LOOPDEV" ] || { sudo losetup -d "$LOOPDEV" 2>/dev/null || true; LOOPDEV=""; }
    return "$rc"
}
trap teardown EXIT

# Refuse to delete a tree that still has something mounted under it. This is
# the guard that turns the dangerous failure into a stopped build.
assert_unmounted() {
    local dir="$1"
    [ -e "$dir" ] || return 0
    if findmnt --raw --noheadings --output TARGET | grep -q "^${dir}/"; then
        findmnt --raw --noheadings --output TARGET | grep "^${dir}/" >&2
        die "refusing to touch $dir — mounts are still live under it"
    fi
}

# The one privileged delete in this script, and the only place `sudo rm -rf`
# appears. It needs sudo because the trees were written by `sudo rsync` and are
# owned by root -- a plain rm fails on the second run, which is how this was
# found. Every deletion goes through here so the guards cannot be skipped by
# someone adding a cleanup somewhere else.
safe_rmtree() {
    local dir="$1"
    case "$dir" in
        "" | "/" | "/*") die "safe_rmtree refused: '$dir'" ;;
        /*) ;;
        *) die "safe_rmtree needs an absolute path, got '$dir'" ;;
    esac
    # Must live under the build cache. Belt and braces against a future edit
    # that passes something derived from user input or a stale variable.
    case "$dir" in
        "$CACHE"/*) ;;
        *) die "safe_rmtree refused '$dir': not under $CACHE" ;;
    esac
    assert_unmounted "$dir"
    [ ! -e "$dir" ] || sudo rm -rf -- "$dir"
}

# --- Preconditions ----------------------------------------------------------

preflight() {
    [ "$(id -u)" -ne 0 ] || die "run as an ordinary user; it calls sudo where needed"
    sudo -n true 2>/dev/null || die "needs passwordless sudo for mount/chroot"

    local arch
    arch=$(dpkg --print-architecture)
    [ "$arch" = "arm64" ] ||
        die "host is $arch; this builds an arm64 rootfs natively and has no qemu path"

    local t
    for t in losetup chroot rsync findmnt; do
        sudo sh -c "command -v $t" > /dev/null 2>&1 || die "$t not found"
    done
}

# --- Stage 1 output ---------------------------------------------------------

base_image() {
    local img
    img=$("$SELF_DIR/fetch-base.sh") || die "fetch-base.sh failed"
    [ -f "$img" ] || die "fetch-base.sh printed a path that is not a file: $img"
    echo "$img"
}

# Copy both filesystems out of the base image. rsync with -aHAX because a root
# filesystem is not an ordinary directory tree: it has hardlinks, xattrs and
# capabilities (setcap on ping, for one), and losing them produces a rootfs
# that boots and then misbehaves in ways nothing points at.
extract_base() {
    local img="$1" mnt="$CACHE/mnt-base"

    safe_rmtree "$ROOTFS"
    safe_rmtree "$BOOTFS"
    mkdir -p "$ROOTFS" "$BOOTFS"

    LOOPDEV=$(sudo losetup --show -fP "$img") || die "losetup failed"
    note "loop: $LOOPDEV"

    mount_into "${LOOPDEV}p2" "$mnt/root" -o ro
    mount_into "${LOOPDEV}p1" "$mnt/boot" -o ro

    step "copying base root filesystem (about 2.3 GB)"
    sudo rsync -aHAX --numeric-ids "$mnt/root/" "$ROOTFS/"
    step "copying base boot filesystem"
    sudo rsync -aHAX --numeric-ids "$mnt/boot/" "$BOOTFS/"

    teardown
    trap teardown EXIT
}

# --- Neutralise Pi OS first-boot behaviour ---------------------------------

# The resize is the one that matters: the stock cmdline.txt ends in `resize`,
# which grows the root partition to fill the card on first boot. On this layout
# that means root A eating slot B, the data partition, and the update mechanism
# in one go. Stage 3 writes cmdline.txt fresh from layout.sh, which omits the
# token, so this is belt and braces -- and it is worth having both, because the
# cost of one of them being missed is a card that destroys itself on first boot.
neutralise_firstboot() {
    step "neutralising Pi OS first-boot behaviour"

    if [ -f "$BOOTFS/cmdline.txt" ]; then
        sudo sed -i 's/[[:space:]]*\bresize\b//g' "$BOOTFS/cmdline.txt"
        note "removed 'resize' from the base cmdline.txt"
    fi

    # sshswitch enables SSH when /boot/firmware/ssh exists. Left alone
    # deliberately: it is opt-in, it is how every Pi user expects to turn SSH
    # on, and disabling it would be KosmOS overriding a platform convention for
    # no gain.
    note "left sshswitch.service alone (opt-in, platform convention)"
}

# --- chroot -----------------------------------------------------------------

chroot_prepare() {
    mount_into /dev "$ROOTFS/dev" --bind
    mount_into /dev/pts "$ROOTFS/dev/pts" --bind
    mount_into proc "$ROOTFS/proc" -t proc
    mount_into sysfs "$ROOTFS/sys" -t sysfs

    # apt needs working DNS inside the chroot, so the host's resolv.conf goes in
    # for the duration and the image's own is put back by chroot_finish. It is
    # saved rather than regenerated because shipping the BUILD HOST's nameservers
    # inside the image would be a real leak: every flashed card would carry
    # whatever DNS this machine happened to use. Verified after a full run that
    # the restored file is byte-identical to the pristine base image's, and that
    # pi-server's own (1.1.1.1, NetworkManager-generated) did not survive.
    sudo cp -a "$ROOTFS/etc/resolv.conf" "$ROOTFS/etc/resolv.conf.kosmos-bak" 2>/dev/null || true
    sudo cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

    # Stop packages starting daemons during installation. Inside a chroot a
    # service start either fails noisily or, worse, succeeds and leaves a
    # process running against the host's PID 1.
    printf '#!/bin/sh\nexit 101\n' | sudo tee "$ROOTFS/usr/sbin/policy-rc.d" > /dev/null
    sudo chmod +x "$ROOTFS/usr/sbin/policy-rc.d"
}

chroot_finish() {
    sudo rm -f "$ROOTFS/usr/sbin/policy-rc.d"
    if [ -e "$ROOTFS/etc/resolv.conf.kosmos-bak" ]; then
        sudo mv "$ROOTFS/etc/resolv.conf.kosmos-bak" "$ROOTFS/etc/resolv.conf"
    fi
}

in_chroot() {
    sudo chroot "$ROOTFS" /usr/bin/env \
        DEBIAN_FRONTEND=noninteractive \
        LC_ALL=C \
        /bin/bash -c "$1"
}

# --- Install steps ----------------------------------------------------------

install_kernel_modules() {
    local tarball="$1" tmp="$CACHE/kernel-pkg"
    step "installing KosmOS kernel modules from $(basename "$tarball")"
    safe_rmtree "$tmp"; mkdir -p "$tmp"
    tar -xzf "$tarball" -C "$tmp" || die "cannot unpack $tarball"

    local pkg
    pkg=$(find "$tmp" -maxdepth 2 -name kernel-version -printf '%h\n' | head -1)
    [ -n "$pkg" ] || die "$tarball has no kernel-version file"

    local kver
    kver=$(tr -d '[:space:]' < "$pkg/kernel-version")
    [ -n "$kver" ] || die "kernel-version is empty"

    sudo cp -a "$pkg/modules/lib/modules/$kver" "$ROOTFS/lib/modules/" ||
        die "copying modules failed"
    in_chroot "depmod -a $kver" || die "depmod failed for $kver"

    # Stage 3 needs boot/ from the same package. Recorded rather than copied:
    # this stage owns the rootfs and must not reach into the bootfs.
    echo "$kver" > "$CACHE/kernel-version"
    note "modules installed for $kver; boot files stay in $tmp for stage 3"
}

readonly APT_PACKAGES="rt-tests stress-ng"

install_apt_userspace() {
    step "installing apt-based userspace: $APT_PACKAGES"
    in_chroot "apt-get update -qq" || die "apt-get update failed in chroot"
    in_chroot "apt-get install -y -qq $APT_PACKAGES" ||
        die "apt-get install failed in chroot"
}

# The WHOLE userspace directory goes in, not just the two entry points.
# 03-satcom-stack.sh is a sequencer that resolves 03a/03b/03c from its own
# $SELF_DIR, so copying it alone puts it in a directory where its jobs do not
# exist and it dies on the first one.
#
# KOSMOS_ASSUME_YES=1 is mandatory here, not a convenience. Each of these
# scripts prompts, and in a chroot with no tty `read` gets EOF, the answer
# defaults to no, and the script exits 3 -- which the sequencer treats as a
# deliberate decline and reports as SKIPPED. Without the flag this function
# would return success having installed nothing at all.
install_satcom() {
    step "building the SATCOM stack from source (hours, not minutes)"
    local dst="$ROOTFS/tmp/kosmos-userspace"
    sudo rm -rf "$dst"
    sudo mkdir -p "$dst"
    sudo cp "$REPO_ROOT"/userspace/*.sh "$dst/"
    sudo chmod +x "$dst"/*.sh

    local s
    for s in 02c-sdr-userspace.sh 03-satcom-stack.sh; do
        step "chroot: $s"
        in_chroot "KOSMOS_ASSUME_YES=1 bash /tmp/kosmos-userspace/$s" ||
            die "$s failed in chroot"
    done
    sudo rm -rf "$dst"
}

# Every line records what this run ACTUALLY did. The first draft hardcoded the
# apt package list, so a --prep-only run produced a manifest claiming packages
# it had never installed -- a provenance file that lies is worse than none,
# because it is the thing a later reader trusts instead of checking.
# Remove this stage's own mess before the rootfs is handed to stage 3.
#
# Measured on the first full --with-satcom build, 2026-08-23: the finished
# rootfs was 6347 MiB, of which 1295 MiB was residue that no running system
# needs -- 803 MiB of downloaded .debs, 147 MiB of apt package lists, and
# 345 MiB of source trees left in /tmp by clone_pinned. Every one of those
# would have been written into BOTH slots by stage 3, so the cost is doubled
# in the image and doubled again in every update bundle.
#
# Deliberately NOT removed here: the stock 6.18.34 module trees (64 MiB).
# They are dead only because stage 3 removes the stock kernels from each
# bootfs, and that is stage 3's decision to make. Stage 2 does not get to
# depend on it.
clean_rootfs() {
    step "removing build residue"
    local before after
    before=$(sudo du -sm "$ROOTFS" | cut -f1)

    in_chroot "apt-get clean" || die "apt-get clean failed"
    sudo rm -rf "$ROOTFS/var/lib/apt/lists"
    sudo mkdir -p "$ROOTFS/var/lib/apt/lists/partial"

    # clone_pinned leaves each source tree in /tmp. /tmp is a scratch directory
    # on a running system, so emptying it is what the first boot would do
    # anyway -- just without shipping it to the user first.
    sudo find "$ROOTFS/tmp" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

    after=$(sudo du -sm "$ROOTFS" | cut -f1)
    note "rootfs $before MiB -> $after MiB (reclaimed $((before - after)) MiB)"
}

write_manifest() {
    local img="$1" kernel="$2" apt="$3" satcom="$4"
    {
        echo "# KosmOS rootfs manifest — generated by image/build-rootfs.sh"
        echo "base_image     $(basename "$img")"
        echo "base_sha256    $("$SELF_DIR/fetch-base.sh" --print-pin | awk '/^sha256/{print $2}')"
        echo "kernel         ${kernel:-NONE — rootfs has no KosmOS kernel modules}"
        echo "apt_userspace  $apt"
        echo "satcom_stack   $satcom"
        echo "host           $(uname -n) $(uname -r) $(dpkg --print-architecture)"
    } > "$MANIFEST"
    note "manifest: $MANIFEST"
}

usage() {
    sed -n '8,16p' "$SELF_DIR/build-rootfs.sh" | sed 's/^# \{0,2\}//'
}

main() {
    local kernel_tarball="" prep_only=0 with_satcom=0 want_shell=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --kernel)      [ $# -ge 2 ] || die "--kernel needs a path"; kernel_tarball="$2"; shift 2 ;;
            --prep-only)   prep_only=1; shift ;;
            --with-satcom) with_satcom=1; shift ;;
            --shell)       want_shell=1; shift ;;
            -h|--help)     usage; return 0 ;;
            *)             die "unknown argument '$1' (try --help)" ;;
        esac
    done
    [ -z "$kernel_tarball" ] || [ -f "$kernel_tarball" ] ||
        die "no such kernel package: $kernel_tarball"

    preflight
    local img; img=$(base_image)
    note "base: $img"

    extract_base "$img"
    neutralise_firstboot

    if [ "$prep_only" -eq 1 ]; then
        step "prep only — rootfs at $ROOTFS, nothing installed"
        write_manifest "$img" "" "not run (--prep-only)" "not run (--prep-only)"
        return 0
    fi

    chroot_prepare
    if [ "$want_shell" -eq 1 ]; then
        step "chroot shell — exit when done"
        sudo chroot "$ROOTFS" /bin/bash || true
        chroot_finish
        return 0
    fi

    local kver=""
    if [ -n "$kernel_tarball" ]; then
        install_kernel_modules "$kernel_tarball"
        kver=$(cat "$CACHE/kernel-version")
    fi
    install_apt_userspace
    [ "$with_satcom" -eq 0 ] || install_satcom
    clean_rootfs
    chroot_finish

    local satcom_state="not run (--with-satcom omitted)"
    [ "$with_satcom" -eq 0 ] || satcom_state="built from source"
    write_manifest "$img" "$kver" "$APT_PACKAGES" "$satcom_state"

    step "rootfs ready: $ROOTFS"
    [ -n "$kver" ] || note "WARNING: no KosmOS kernel — this is not yet a KosmOS image"
    [ "$with_satcom" -eq 1 ] || note "WARNING: no SATCOM stack — pass --with-satcom"
}

main "$@"
