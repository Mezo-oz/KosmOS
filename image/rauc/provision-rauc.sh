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
#
# ---------------------------------------------------------------------------
# THE PACKAGES ARE INSTALLED BY STAGE 2, NOT HERE. apt needs a chroot and this
# runs against a plain directory, so `rauc rauc-service` lives in
# build-rootfs.sh's APT_PACKAGES. Stage 2 builds ONE rootfs that stage 3 copies
# into both slots, which is the right place for it anyway.
#
# ⚠️ IT IS TWO PACKAGES, AND THE SPLIT IS NOT OBVIOUS. Debian's `rauc` ships
# only /usr/bin/rauc and a journal catalog. The systemd unit and the D-Bus
# plumbing -- /usr/lib/systemd/system/rauc.service,
# /usr/share/dbus-1/system-services/de.pengutronix.rauc.service and its policy
# file -- are in a SEPARATE `rauc-service` package (arch: all).
#
# Install only the first and two things break quietly at once: `rauc status
# mark-good` has no service to reach over D-Bus, and kosmos-mark-good.service's
# `Wants=rauc.service` names a unit that does not exist -- which systemd logs
# and then carries on from. Both surface at the moment an update needs
# committing, which is the worst possible time to discover them.
#
# Verified against trixie 2026-08-26: rauc 1.13-3+deb13u1, arm64, in main.
#
# ---------------------------------------------------------------------------
# THE KEYRING. system.conf has always named one -- /etc/rauc/kosmos.cert.pem --
# and until 2026-08-27 nothing in this repo ever put a file there. Measured on
# rauc 1.13-3+deb13u1, that is not a warning:
#
#   rauc info <bundle>  -> rc=1
#   failed to load CA file '/etc/rauc/kosmos.cert.pem' and/or directory '(null)'
#
# So every image built before that date passes all 127 structural checks and
# then refuses every bundle it is ever offered. The cert is installed HERE, and
# asserted by verify-image.sh, so the two cannot drift apart again.
#
# KOSMOS_RAUC_CERT names the CA certificate -- public, safe to copy anywhere,
# and NOT shipped in this repo on purpose: committing one would make it the
# trust root for every image anyone builds from this tree. Generate your own
# with image/rauc/make-keys.sh. There is deliberately no default and no
# fallback: an image that silently trusts nobody is the bug being fixed.
# ============================================================================

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYOUT="$SELF_DIR/../layout.sh"
RAUC_CERT="${KOSMOS_RAUC_CERT:-}"

die()  { echo "provision-rauc.sh: $*" >&2; exit 1; }
note() { echo "  $*" >&2; }

# Install the CA certificate at whatever path system.conf's [keyring] names.
#
# The path is READ OUT OF the config that was just generated rather than
# written here as a constant. layout.sh owns that path; a second copy of it in
# this file is a copy that goes on being right until the day layout.sh changes,
# and then installs a cert where nothing looks for it -- which is the same
# shape as the bug this function exists to fix, one level along.
install_keyring() {
    local root="$1" slot="$2"
    # Separate statement: `local` creates every name it declares as an unset
    # local BEFORE assigning any of them, so `conf="$root/..."` in the line
    # above would read the shadowed empty `root`, not the argument. Under
    # `set -u` that is a hard "unbound variable" -- which is how it was found.
    local conf="$root/etc/rauc/system.conf"
    local path dir

    path="$(sudo sed -n 's/^path=//p' "$conf" | tail -1)"
    [ -n "$path" ] || die "slot $slot: system.conf names no [keyring] path"

    [ -n "$RAUC_CERT" ] || die "KOSMOS_RAUC_CERT is not set.
  system.conf points RAUC at '$path', and an image without a certificate there
  refuses every bundle -- rauc exits 1 with 'failed to load CA file'. Generate
  a CA and point this at its public cert:
      image/rauc/make-keys.sh ca /media/<offline>/kosmos-ca
      export KOSMOS_RAUC_CERT=/media/<offline>/kosmos-ca/ca.cert.pem"
    [ -f "$RAUC_CERT" ] || die "KOSMOS_RAUC_CERT=$RAUC_CERT: not a file"

    # Parse it before it goes in. A truncated or wrong-format file installs
    # just as happily as a good one and fails on the box, mid-update.
    openssl x509 -in "$RAUC_CERT" -noout > /dev/null 2>&1 ||
        die "$RAUC_CERT: openssl does not parse this as a certificate"

    dir="$(dirname "$path")"
    sudo mkdir -p "$root$dir"
    sudo install -m 0644 "$RAUC_CERT" "$root$path"
    note "slot $slot: keyring installed at $path ($(cert_subject "$RAUC_CERT"))"
}

cert_subject() {
    openssl x509 -in "$1" -noout -subject 2>/dev/null | sed 's/^subject=//'
}

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

    install_keyring "$root" "$slot"

    sudo install -m 0644 "$SELF_DIR/kosmos-mark-good.service" \
        "$root/etc/systemd/system/kosmos-mark-good.service"

    # Enabled by symlink rather than `systemctl enable`: there is no running
    # systemd inside a loop-mounted image, and the result is visible in the
    # artifact instead of deferred to first boot. Same reasoning the assembler
    # uses for ssh.service.
    sudo mkdir -p "$root/etc/systemd/system/multi-user.target.wants"
    sudo ln -sf /etc/systemd/system/kosmos-mark-good.service \
        "$root/etc/systemd/system/multi-user.target.wants/kosmos-mark-good.service"

    # Stage 2 installs the packages, so this only reports. It does NOT die: a
    # rootfs built with --prep-only, or an older one still in the build cache,
    # is a legitimate intermediate state and policing stage 2 is not stage 3's
    # job. The finished ARTIFACT is where this becomes an assertion --
    # verify-image.sh fails on it, because an image is not an intermediate.
    local missing=""
    [ -x "$root/usr/bin/rauc" ] || missing="rauc"
    [ -f "$root/usr/lib/systemd/system/rauc.service" ] ||
        missing="${missing:+$missing }rauc-service"
    [ -z "$missing" ] ||
        note "WARNING slot $slot: not installed in this rootfs: $missing"

    note "slot $slot: rauc system.conf, backend, selector mountpoint, mark-good enabled"
}

main "$@"
