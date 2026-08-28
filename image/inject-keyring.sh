#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — install the RAUC keyring into an image that shipped without one
# ============================================================================
#   ./inject-keyring.sh --expect <sha256> [image.img]
#   ./inject-keyring.sh --expect <sha256> --cert <ca.cert.pem> [image.img]
#
# Prints the NEW sha256 on stdout. Everything else goes to stderr (standard 8).
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS. Images built before 2026-08-27 name a RAUC keyring in
# system.conf that no build stage ever wrote. On rauc 1.13-3+deb13u1 that is
# fatal rather than cosmetic -- `rauc info` exits 1 with "failed to load CA
# file" -- so the 3.49 GB artifact of 2026-08-26 passes all 127 structural
# checks and can never install an update. provision-rauc.sh fixes every FUTURE
# build. This is for the image that already exists.
#
# WHY A SCRIPT AND NOT A HAND SESSION, which is the obvious way to install one
# file into a mounted image. Provenance is not "one unbroken machine run"; it
# is a chain of custody. A committed script that STATES the digest it expects,
# does one narrow thing, and PRINTS the digest it produced leaves a record
# anyone can read and re-run. Hands on a mounted image leave nothing -- the
# artifact would differ from the pipeline's output with no account of how.
# So --expect is mandatory: the operator declares which artifact is being
# modified, and a mismatch stops before anything is mounted.
#
# THE OLD DIGEST DIES HERE. Bytes are identity in this project, so an injected
# image is a NEW artifact, not a patched old one. The sin is not modifying an
# image; it is letting the superseded digest keep circulating. This rewrites
# <image>.sha256, appends the before/after pair to the manifest, and prints the
# new digest -- and every place naming the old one has to be updated with it,
# ROADMAP 4a and 4d included.
#
# IT MODIFIES IN PLACE, and that is forced, not chosen. The image is 11 GB and
# the build host has ~3.4 GB free, so there is nowhere to put a copy. The
# window is as small as it can be made: two files installed, then a re-verify.
# If it dies mid-write, rebuild rather than guess -- which is why the expected
# digest is recorded before anything is touched.
#
# WHAT IT DOES NOT DO: re-verify the result. Run verify-image.sh --release
# afterwards; it now asserts the keyring, so a successful injection and a
# passing verify are two independent statements rather than one script's
# opinion of its own work.
# ============================================================================

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYOUT="$SELF_DIR/layout.sh"
CACHE="${MOLNIYA_BUILD_CACHE:-/var/tmp/molniya-build}"
RAUC_CERT="${MOLNIYA_RAUC_CERT:-}"

MNT="$CACHE/mnt-inject"
MOUNTED=()
LOOPDEV=""
EXPECT=""

die()  { echo "inject-keyring.sh: $*" >&2; exit 1; }
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

slotmap_get() {
    local key="$1"
    "$LAYOUT" slotmap | sed -n "s/^${key}=//p"
}

digest_of() {
    sha256sum "$1" | cut -d' ' -f1
}

# One slot. The keyring path comes out of that slot's own system.conf -- the
# same rule provision-rauc.sh and verify-image.sh follow, so all three agree
# without any of them holding a second copy of the path.
inject_slot() {
    local part="$1" slot="$2"
    # `dir` is declared separately, and that is not style. `local` creates all
    # of its names as unset locals BEFORE it assigns any of them, so a later
    # initializer referring to an earlier one in the SAME statement reads the
    # shadowed local, not the value just written -- which under `set -u` is
    # "unbound variable" and under nounset-off would be a silent empty string.
    # Caught by running this against a fixture image; it had never run.
    local dir="$MNT/root$slot"
    local conf path

    sudo mkdir -p "$dir"
    sudo mount "${LOOPDEV}p${part}" "$dir"
    MOUNTED+=("$dir")

    conf="$dir/etc/rauc/system.conf"
    sudo test -f "$conf" || die "slot $slot (p$part): no /etc/rauc/system.conf"

    path="$(sudo sed -n 's/^path=//p' "$conf" | tail -1)"
    [ -n "$path" ] || die "slot $slot: system.conf names no [keyring] path"

    if sudo test -f "$dir$path"; then
        note "slot $slot: $path already present — replacing it"
    fi

    sudo mkdir -p "$dir$(dirname "$path")"
    sudo install -m 0644 "$RAUC_CERT" "$dir$path"
    sudo test -f "$dir$path" || die "slot $slot: install produced no file at $path"
    note "slot $slot (p$part): keyring installed at $path"
}

usage() {
    cat >&2 <<'USAGE'
usage: inject-keyring.sh --expect <sha256> [--cert <ca.cert.pem>] [image.img]

  --expect <sha256>   digest the image MUST have before anything is touched
  --cert <path>       CA certificate to install (or set MOLNIYA_RAUC_CERT)

Prints the new sha256 on stdout. Rewrites <image>.sha256 and appends the
before/after pair to <image>.manifest. Run verify-image.sh --release after.
USAGE
    exit 2
}

main() {
    local img=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --expect) [ $# -ge 2 ] || usage; EXPECT="$2"; shift 2 ;;
            --cert)   [ $# -ge 2 ] || usage; RAUC_CERT="$2"; shift 2 ;;
            -h|--help) usage ;;
            -*)       die "unknown option '$1'" ;;
            *)        [ -z "$img" ] || die "one image, got a second: $1"
                      img="$1"; shift ;;
        esac
    done
    img="${img:-$CACHE/molniya-rpi5.img}"

    [ -n "$EXPECT" ] || die "--expect <sha256> is required.
  It is what makes this auditable: state which artifact is being modified, and
  a mismatch stops before anything is mounted. Read it from <image>.sha256."
    [ -f "$img" ] || die "$img: no such image"
    [ -n "$RAUC_CERT" ] || die "no certificate: pass --cert or set MOLNIYA_RAUC_CERT"
    [ -f "$RAUC_CERT" ] || die "$RAUC_CERT: not a file"
    openssl x509 -in "$RAUC_CERT" -noout > /dev/null 2>&1 ||
        die "$RAUC_CERT: openssl does not parse this as a certificate"

    # Chain of custody, link one: the artifact on disk is the one named.
    step "identify — $img"
    local before
    before="$(digest_of "$img")"
    note "sha256 before  $before"
    [ "$before" = "$EXPECT" ] ||
        die "digest mismatch. Nothing has been touched.
  expected  $EXPECT
  on disk   $before"
    note "matches --expect"

    local subject fingerprint
    subject="$(openssl x509 -in "$RAUC_CERT" -noout -subject | sed 's/^subject=//')"
    fingerprint="$(openssl x509 -in "$RAUC_CERT" -noout -fingerprint -sha256 | sed 's/^.*=//')"
    note "certificate    $subject"
    note "fingerprint    $fingerprint"

    step "attach — loop device"
    LOOPDEV="$(sudo losetup --show -fP "$img")"
    note "$LOOPDEV"

    step "inject — the keyring, into both slots"
    inject_slot "$(slotmap_get MOLNIYA_SLOT_A_ROOT)" A
    inject_slot "$(slotmap_get MOLNIYA_SLOT_B_ROOT)" B

    # Unmount before hashing. A dirty page cache means the digest describes
    # something the file does not yet contain, which is the one number here
    # that has to be right.
    step "settle — unmount and sync before hashing"
    teardown
    trap - EXIT
    sync

    step "digest — sha256 of the modified image"
    local after
    after="$(digest_of "$img")"
    note "sha256 after   $after"
    [ "$after" != "$before" ] ||
        die "the image is byte-identical after injection, which cannot be right"

    ( cd "$(dirname "$img")" && sha256sum "$(basename "$img")" ) > "$img.sha256"
    note "rewrote $img.sha256"

    # Provenance, appended rather than rewritten: the manifest is the artifact's
    # history, and history that gets edited is not history.
    local manifest="$img.manifest"
    if [ -f "$manifest" ]; then
        {
            printf 'keyring_cert   %s\n' "$subject"
            printf 'keyring_sha256 %s\n' "$fingerprint"
            printf 'sha256_before  %s\n' "$before"
            printf 'sha256_after   %s\n' "$after"
        } >> "$manifest"
        note "appended provenance to $manifest"
    else
        note "WARNING no manifest at $manifest; provenance recorded only here"
    fi

    note ""
    note "NEXT, and neither is optional:"
    note "  1. $SELF_DIR/verify-image.sh --release $img"
    note "  2. every place naming $before is now stale — ROADMAP included"

    echo "$after"
}

main "$@"
