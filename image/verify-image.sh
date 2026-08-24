#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# KosmOS — verify an assembled image (Phase 4a)
# ============================================================================
# Mounts a finished .img read-only and asserts, against layout.sh, that what
# was actually written matches what was meant to be written.
#
#   ./verify-image.sh                  verify the image in the build cache
#   ./verify-image.sh <path.img>       verify a specific image
#   ./verify-image.sh --release <img>  also assert what only a RELEASE must hold
#
# --release exists because one assertion is a defect in a release artifact and
# a correct state in stage 3's output: the stock module trees. Stage 2 leaves
# them because it does not get to depend on stage 3 deleting the stock kernels,
# and stage 4 removes them. Making that a plain check would print FAIL against
# a good stage-3 image, and a check that cries wolf on correct output is how a
# team learns to skim past output.
#
# WHY THIS IS A SCRIPT AND NOT A CHECKLIST. Stage 3 prints a log full of
# reassuring "==> populating root B" lines and exits 0. Every defect this phase
# has produced so far had that shape: a step that ran, reported success, and
# proved nothing -- a kernel the firmware would never load, a manifest naming
# packages it had not installed, an installer reporting SKIPPED as success. The
# log is the build's own account of itself. This reads the artifact instead.
#
# IT DERIVES NOTHING. Every expected value comes from layout.sh or from the
# image itself; this file hardcodes no offset, no size and no partition number.
# A check that carries its own copy of the answer is a check that agrees with
# itself when layout.sh changes underneath it.
#
# READ-ONLY THROUGHOUT. The loop device is attached with -r and every mount is
# `ro`, so a verification pass cannot be what modifies the thing it is
# verifying -- and it can be run against an image that is about to be flashed
# without invalidating the digest taken beforehand.
#
# WHAT IT CANNOT TELL YOU: whether the image BOOTS. Every assertion here is
# structural. A card that passes this can still fail at the firmware, in the
# initramfs, or at the first service. That test needs hardware.
# ============================================================================

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYOUT="$SELF_DIR/layout.sh"
CACHE="${KOSMOS_BUILD_CACHE:-/var/tmp/kosmos-build}"
RELEASE=0
if [ "${1:-}" = "--release" ]; then RELEASE=1; shift; fi
IMG="${1:-$CACHE/kosmos-rpi5.img}"
TARGET_DEV="${KOSMOS_TARGET_DEV:-/dev/mmcblk0}"
LOGIN_USER="${KOSMOS_LOGIN_USER:-kosmos}"

MNT="$CACHE/mnt-verify"
MOUNTED=()
LOOPDEV=""
PASS=0
FAIL=0

die() { echo "verify-image.sh: $*" >&2; exit 1; }
step() { echo "==> $*" >&2; }

# ----------------------------------------------------------------------------
# Assertions. Every failure is recorded and the run continues: a verification
# pass that stops at the first problem turns one round trip into five.
# ----------------------------------------------------------------------------
ok() { printf '  ok    %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

check() {
    local desc="$1"; shift
    if "$@" > /dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

check_not() {
    local desc="$1"; shift
    if "$@" > /dev/null 2>&1; then bad "$desc"; else ok "$desc"; fi
}

check_eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then ok "$desc"
    else bad "$desc (want '$want', got '$got')"; fi
}

# Root-owned trees under a fresh mount are not readable as the build user, so
# every read of image content goes through sudo rather than hoping.
sread() { sudo cat "$1"; }
smode() { sudo stat -c '%a' "$1" 2>/dev/null || echo "missing"; }
sowner() { sudo stat -c '%u:%g' "$1" 2>/dev/null || echo "missing"; }

mount_ro() {
    local what="$1" where="$2"
    mkdir -p "$where"
    sudo mount -o ro "$what" "$where" || die "mount $what -> $where failed"
    MOUNTED+=("$where")
}

teardown() {
    local rc=$? i
    for (( i=${#MOUNTED[@]} - 1; i >= 0; i-- )); do
        sudo umount "${MOUNTED[i]}" 2>/dev/null || sudo umount -l "${MOUNTED[i]}" 2>/dev/null || true
    done
    MOUNTED=()
    [ -z "$LOOPDEV" ] || { sudo losetup -d "$LOOPDEV" 2>/dev/null || true; LOOPDEV=""; }
    return "$rc"
}
trap teardown EXIT

# ----------------------------------------------------------------------------
# The partition table. Both sides are reduced to "start size type" in sectors
# so an sfdisk script and an sfdisk dump can be compared at all: the script
# speaks MiB and writes type=0e, the dump speaks sectors and writes type=e.
# ----------------------------------------------------------------------------
norm_table() {
    sed -e 's#^[^:]*:[[:space:]]*##' -e 's/[[:space:]]//g' |
        awk -F'[,=]' '
        function cv(v) { if (v ~ /MiB$/) { sub(/MiB$/, "", v); return v * 2048 } return v + 0 }
        /^start=/ {
            start = ""; size = "*"; type = ""
            for (i = 1; i < NF; i++) {
                if ($i == "start") { start = cv($(i + 1)) }
                else if ($i == "size") { size = cv($(i + 1)) }
                else if ($i == "type") { type = $(i + 1) }
            }
            sub(/^0/, "", type)
            print start, size, type
        }'
}

verify_table() {
    step "partition table"
    local want got
    mapfile -t want < <("$LAYOUT" sfdisk | norm_table)
    mapfile -t got < <(sudo sfdisk --dump "$LOOPDEV" | norm_table)

    check_eq "partition count" "${#want[@]}" "${#got[@]}"
    [ "${#want[@]}" = "${#got[@]}" ] || return 0

    local i n w g
    for i in "${!want[@]}"; do
        n=$((i + 1))
        # An unsized entry in the layout (the extended container, and the data
        # partition that takes whatever the card has left) has no size to check.
        read -r -a w <<< "${want[i]}"
        read -r -a g <<< "${got[i]}"
        check_eq "p$n start" "${w[0]}" "${g[0]}"
        [ "${w[1]}" = "*" ] || check_eq "p$n size" "${w[1]}" "${g[1]}"
        check_eq "p$n type" "${w[2]}" "${g[2]}"
    done
}

# ----------------------------------------------------------------------------
# p1 — the slot selector. It sits outside both slots precisely so that an
# update rewriting a slot cannot rewrite the file that chooses slots, so what
# matters here is as much what is ABSENT as what is present.
# ----------------------------------------------------------------------------
verify_autoboot() {
    step "p1 — slot selector"
    local dir="$MNT/autoboot"
    mount_ro "${LOOPDEV}p1" "$dir"

    check "autoboot.txt present" sudo test -f "$dir/autoboot.txt"
    check_eq "autoboot.txt matches layout" \
        "$("$LAYOUT" autoboot A)" "$(sread "$dir/autoboot.txt")"

    local extra
    extra="$(sudo find "$dir" -mindepth 1 -not -name autoboot.txt -not -name 'System Volume Information*' | wc -l)"
    check_eq "p1 holds nothing else" "0" "$extra"
}

# ----------------------------------------------------------------------------
# A slot's bootfs. The kernel-arming check is the one that matters: the package
# ships kernel-kosmos.img, the base ships kernel_2712.img, and stock config.txt
# names neither -- so a naive overlay boots the stock kernel with KosmOS
# modules sitting unused beside it, and nothing anywhere says so.
# ----------------------------------------------------------------------------
verify_boot() {
    local slot="$1" part="$2"
    local dir="$MNT/boot$slot"
    step "bootfs $slot (p$part)"
    mount_ro "${LOOPDEV}p${part}" "$dir"

    check "kernel-kosmos.img present" sudo test -f "$dir/kernel-kosmos.img"
    check_not "stock kernel_2712.img removed" sudo test -e "$dir/kernel_2712.img"
    check_not "stock kernel8.img removed" sudo test -e "$dir/kernel8.img"
    check "Pi 5 device tree present" sudo test -f "$dir/bcm2712-rpi-5-b.dtb"
    check "overlays present" sudo test -d "$dir/overlays"

    check "config.txt arms our kernel" \
        sudo grep -qx 'kernel=kernel-kosmos.img' "$dir/config.txt"
    check_eq "cmdline.txt matches layout" \
        "$("$LAYOUT" cmdline "$slot" "$TARGET_DEV")" "$(sread "$dir/cmdline.txt")"

    # Pi OS Lite's own first-boot resize grows the root to fill the card, which
    # eats the other slot. layout.sh never emits it; this is the backstop.
    check_not "no first-boot resize token" \
        sudo grep -Eq '(^| )resize( |$)|init=' "$dir/cmdline.txt"
}

# ----------------------------------------------------------------------------
# A slot's root. The cross-check that matters is that this slot's bootfs points
# at THIS slot's root: an fstab or a root= naming the other slot gives a box
# that boots, mounts the wrong filesystem over itself, and is then updated in
# place by an update that believes it is writing to the spare.
# ----------------------------------------------------------------------------
verify_root() {
    local slot="$1" part="$2" kver="$3"
    local dir="$MNT/root$slot"
    step "root $slot (p$part)"
    mount_ro "${LOOPDEV}p${part}" "$dir"

    check_eq "fstab matches layout" \
        "$("$LAYOUT" fstab "$slot" "$TARGET_DEV")" "$(sread "$dir/etc/fstab")"
    check_eq "slots.conf matches layout" \
        "$("$LAYOUT" slotmap)" "$(sread "$dir/etc/kosmos/slots.conf")"
    # The cross-check that matters, and the reason it does not simply re-diff
    # both files against layout.sh: cmdline.txt and fstab are two independent
    # statements of which filesystem is this slot's root, written by different
    # emitters. If they disagree the box still boots -- it mounts the other
    # slot over itself, and the next update writes into the running system
    # while believing it is writing to the spare. So they are compared against
    # each other and against the partition they were found on, not against the
    # file that generated them both.
    local root_dev fstab_dev
    root_dev="$(sread "$MNT/boot$slot/cmdline.txt" | tr ' ' '\n' | sed -n 's/^root=//p')"
    fstab_dev="$(sread "$dir/etc/fstab" | awk '$2 == "/" { print $1 }')"
    check_eq "cmdline root= and fstab / agree" "$root_dev" "$fstab_dev"
    check_eq "and both name p$part, the slot they were found on" \
        "$part" "${root_dev##*[!0-9]}"

    check "modules for $kver" sudo test -d "$dir/lib/modules/$kver"
    check "depmod ran in $kver" sudo test -s "$dir/lib/modules/$kver/modules.dep"
    check "health check installed" sudo test -x "$dir/usr/local/lib/kosmos/kosmos-health-check.sh"
    check "slot-identity installed" sudo test -x "$dir/usr/local/lib/kosmos/slot-identity.sh"

    # RELEASE ONLY. A module tree whose kernel is not in this slot's bootfs can
    # never be loaded by anything -- stage 3 deleted the stock kernels, so the
    # stock modules became 64 MiB of cargo in every slot and every future update
    # bundle. Counted against the manifest rather than against a literal
    # "6.18.34", which would stop matching the day the base image is bumped and
    # silently start passing.
    if [ "$RELEASE" -eq 1 ]; then
        local orphans
        orphans="$(sudo find "$dir/lib/modules" -mindepth 1 -maxdepth 1 -type d \
            -not -name "$kver" -printf '%f ' 2>/dev/null || true)"
        check_eq "no orphan module trees" "" "$orphans"
    fi

    # Named by absolute path inside the mount, never through command -v: the
    # build host has every one of these installed, so a PATH lookup here would
    # pass on an image containing none of them.
    local bin
    for bin in rtl_433 dump1090 predict satdump sdrpp; do
        check "satcom: $bin" sudo sh -c \
            "test -x '$dir/usr/local/bin/$bin' || test -x '$dir/usr/bin/$bin'"
    done
}

# ----------------------------------------------------------------------------
# First-boot access. The base image cannot boot headless into a usable state --
# `pi` exists at uid 1000 but is locked with a nologin shell, and
# userconfig.service waits on a console for a userconf.txt that a headless
# flash never supplies. Everything below is what stage 3 does about that, and
# each line of it is a way the image can ship unloginable.
# ----------------------------------------------------------------------------
verify_access() {
    local slot="$1"
    local dir="$MNT/root$slot"
    step "access $slot"
    local wants="$dir/etc/systemd/system/multi-user.target.wants"

    local pw
    pw="$(sread "$dir/etc/passwd" | grep "^$LOGIN_USER:" || true)"
    check_eq "$LOGIN_USER uid" "1000" "$(echo "$pw" | cut -d: -f3)"
    check_eq "$LOGIN_USER shell" "/bin/bash" "$(echo "$pw" | cut -d: -f7)"
    check_eq "$LOGIN_USER home" "/home/$LOGIN_USER" "$(echo "$pw" | cut -d: -f6)"
    check_not "placeholder pi renamed" sudo grep -q '^pi:' "$dir/etc/passwd"

    local keys="$dir/home/$LOGIN_USER/.ssh/authorized_keys"
    check "authorized_keys present" sudo test -s "$keys"
    check_eq "authorized_keys mode" "600" "$(smode "$keys")"
    check_eq "authorized_keys owner" "1000:1000" "$(sowner "$keys")"
    check_eq "authorized_keys count" "2" "$(sread "$keys" | grep -c '^[^#[:space:]]' || true)"
    check_eq ".ssh mode" "700" "$(smode "$dir/home/$LOGIN_USER/.ssh")"

    check_eq "sudoers drop-in mode" "440" "$(smode "$dir/etc/sudoers.d/010-kosmos-nopasswd")"
    check "sudoers drop-in grants $LOGIN_USER" \
        sudo grep -q "^$LOGIN_USER ALL=(ALL) NOPASSWD: ALL$" "$dir/etc/sudoers.d/010-kosmos-nopasswd"

    check "ssh.service enabled" sudo test -L "$wants/ssh.service"
    check_not "userconfig.service disabled" sudo test -e "$wants/userconfig.service"
    check "sshd drop-in present" sudo test -f "$dir/etc/ssh/sshd_config.d/10-kosmos.conf"
    check "sshd drop-in is key-only" \
        sudo grep -qx 'PasswordAuthentication no' "$dir/etc/ssh/sshd_config.d/10-kosmos.conf"
}

# ----------------------------------------------------------------------------
# p7 — shared by both slots and survives every update, so it is seeded with
# mount points rather than content.
# ----------------------------------------------------------------------------
verify_data() {
    step "p7 — data"
    local dir="$MNT/data" n
    mount_ro "${LOOPDEV}p7" "$dir"
    n="$(sudo find "$dir" -mindepth 1 -maxdepth 1 -type d -not -name 'lost+found' | wc -l)"
    check "data partition seeded" test "$n" -gt 0
}

# ----------------------------------------------------------------------------

main() {
    [ -f "$IMG" ] || die "no image at $IMG"
    [ -x "$LAYOUT" ] || die "layout.sh not found beside this script"

    local kver
    kver="$(awk '$1 == "kernel" { print $2 }' "$IMG.manifest" 2>/dev/null || true)"
    [ -n "$kver" ] || die "no kernel version in $IMG.manifest — was this image built by stage 3?"

    step "verifying $IMG"
    echo "  kernel from manifest: $kver" >&2
    LOOPDEV="$(sudo losetup -r -P -f --show "$IMG")" || die "losetup failed"

    verify_table
    verify_autoboot
    verify_boot A 2
    verify_root A 5 "$kver"
    verify_access A
    verify_boot B 3
    verify_root B 6 "$kver"
    verify_access B
    verify_data

    echo
    if [ "$FAIL" -eq 0 ]; then
        local mode="structural"
        [ "$RELEASE" -eq 0 ] || mode="structural + release"
        echo "PASS — $PASS $mode checks, no failures. This image has not been booted."
        return 0
    fi
    echo "FAIL — $FAIL of $((PASS + FAIL)) checks failed."
    return 1
}

main "$@"
