#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — verify the A/B update machinery in one slot (Phase 4d)
# ============================================================================
#   ./verify-rauc.sh <slot-root-dir> <A|B> <target-dev>
#
# Prints ONE LINE PER CHECK on stdout, and nothing else:
#
#   PASS<TAB><description>
#   FAIL<TAB><description>
#   NOTE<TAB><description>      context for the FAIL above it, never counted
#
# The caller renders and tallies, so counting lives in exactly one place and
# this stays runnable on its own against a mounted slot.
#
# WHY IT IS A SEPARATE FILE. verify-image.sh sat at exactly 400 lines -- the cap
# -- and the keyring checks took it to 468. That is a CI failure, and it was one
# on origin/main until this split. The extraction rule fired exactly as written:
# the file exceeded 400 lines and had nothing to lose elsewhere.
#
# The split is by CONCERN and not merely to shed lines. verify-image.sh asks
# whether an image matches layout.sh; this asks whether the update mechanism
# inside it is complete. They fail for different reasons and are read by someone
# with a different question in mind.
#
# READ-ONLY, like its caller: it is handed an already-mounted read-only tree and
# opens nothing for writing. Helpers are duplicated from verify-image.sh rather
# than sourced, per the house rule -- a sourced library would need
# `shellcheck -x`, which the standards forbid.
# ============================================================================

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYOUT="${MOLNIYA_LAYOUT:-$SELF_DIR/layout.sh}"
TARGET_DEV=""

die() { echo "verify-rauc.sh: $*" >&2; exit 1; }

# The data contract. Descriptions may contain spaces; the TAB is the delimiter.
pass() { printf 'PASS\t%s\n' "$1"; }
fail() { printf 'FAIL\t%s\n' "$1"; }
note() { printf 'NOTE\t%s\n' "$1"; }

check() {
    local desc="$1"; shift
    if "$@" > /dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

check_eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$desc"
    else
        fail "$desc (want '$want', got '$got')"
    fi
}

sread() { sudo cat "$1"; }
smode() { sudo stat -c '%a' "$1" 2>/dev/null || echo "missing"; }

# ----------------------------------------------------------------------------
# The A/B update machinery (ROADMAP 4d). The backend is checked by reading its
# path OUT OF the system.conf that will be used and testing that path inside
# the mount -- same lesson as the SATCOM binaries: a check that supplies its
# own idea of where the answer lives can pass on an image lacking it.
# ----------------------------------------------------------------------------
# The keyring, and the class of bug it stands for.
#
# WHAT HAPPENED. system.conf named /etc/rauc/molniya.cert.pem from the day the
# A/B work started, and nothing ever installed a file there. The image passed
# 127 of 127 checks and could not have installed a single update: measured on
# rauc 1.13-3+deb13u1, a missing keyring is `rauc info` exiting 1 with
# "failed to load CA file", not a warning. Every check green, artifact
# functionally dead -- the same shape as the trailing-path-on-stdout defect
# that made standard 8 a rule.
#
# WHY THE CHECK IS WRITTEN THIS WAY. The comment above verify_rauc already
# stated the principle -- read the path out of the config and test THAT path --
# and the keyring was still missed, because the principle had only ever been
# applied to the backend. So this is the general form: for every file
# system.conf points at, assert the image actually delivers it. A config
# referencing a path the build never wrote is now a FAIL, whatever the key.
#
# Parsing it as a certificate rather than stopping at "the file is there" is
# the same reasoning one step on. A truncated copy, a DER file with a .pem
# name, or the signing cert where the CA cert belongs are all present, all
# nonzero, and all fatal on the box at the moment an update is being installed.
verify_keyring() {
    local dir="$1" conf="$2" path want got

    path="$(sread "$conf" | sed -n 's/^path=//p' | tail -1)"
    check "system.conf names a keyring" test -n "$path"
    [ -n "$path" ] || return 0

    if ! sudo test -f "$dir$path"; then
        fail "the keyring exists in the image at $path"
        # A note, not a second `bad`. Check counts are how this project talks
        # about an image ("127 of 127"), so an explanatory line that increments
        # the failure total makes one defect read as two.
        note "without it rauc exits 1 on every bundle: 'failed to load CA file'"
        return 0
    fi
    pass "the keyring exists in the image at $path"

    if sudo openssl x509 -in "$dir$path" -noout > /dev/null 2>&1; then
        pass "and openssl parses it as a certificate"
    else
        fail "and openssl parses it as a certificate"
        return 0
    fi

    # Not expired, and not expiring so soon that a box built today stops
    # trusting its own updates inside the release's life. -checkend takes
    # seconds; 365 days is the horizon a yearly rebuild would notice.
    if sudo openssl x509 -in "$dir$path" -noout -checkend 31536000 > /dev/null 2>&1; then
        pass "and it is valid for at least another year"
    else
        fail "and it is valid for at least another year (expired or expiring)"
    fi

    # Pin the identity when the operator says which CA this image is supposed
    # to trust. Presence and parseability cannot tell the right CA from a
    # stale one left in the build cache -- both are certificates.
    want="${MOLNIYA_RAUC_CERT_FINGERPRINT:-}"
    if [ -n "$want" ]; then
        got="$(sudo openssl x509 -in "$dir$path" -noout -fingerprint -sha256 2>/dev/null |
               sed 's/^.*=//')"
        check_eq "and it is the expected CA" "$want" "$got"
    fi
}

verify_rauc() {
    # Handed the mounted slot root directly, rather than deriving it from a
    # mount prefix the caller happens to use. This script does not mount
    # anything and must not hold an opinion about where its caller did.
    local dir="$1" slot="$2"
    local conf handler selp mp opts kver

    conf="$dir/etc/rauc/system.conf"
    check "rauc system.conf present" sudo test -f "$conf"
    check_eq "rauc system.conf matches layout" \
        "$("$LAYOUT" rauc "$TARGET_DEV")" "$(sread "$conf")"

    handler="$(sread "$conf" | sed -n 's/^bootloader-custom-backend=//p')"
    check "system.conf names a boot backend" test -n "$handler"
    check "the backend exists in the image at $handler" sudo test -x "$dir$handler"

    verify_keyring "$dir" "$conf"

    # Both packages. Debian's `rauc` is the CLI only; rauc.service and the
    # D-Bus policy are in `rauc-service`, and missing it fails quietly.
    check "rauc CLI installed" sudo test -x "$dir/usr/bin/rauc"
    check "rauc.service present (the rauc-service package)" \
        sudo test -f "$dir/usr/lib/systemd/system/rauc.service"

    # The health check compares `uname -r` against this file rather than
    # grepping for a name, so a slot missing it critical-fails on every boot and
    # is never marked good -- an update that installs cleanly and then silently
    # reverts. It is cross-checked against the module tree because the two are
    # halves of one fact: a recorded kernel with no modules in the same root is
    # a slot that boots something it cannot load a driver for. ROADMAP 4d.
    kver="$(sread "$dir/etc/molniya/kernel-version" | tr -d '[:space:]')"
    check "kernel-version recorded for the health check" test -n "$kver"
    check "and its modules are in this root" sudo test -d "$dir/lib/modules/$kver"

    check "mark-good script installed" \
        sudo test -x "$dir/usr/local/lib/molniya/molniya-mark-good.sh"
    check_eq "mark-good unit mode" "644" \
        "$(smode "$dir/etc/systemd/system/molniya-mark-good.service")"
    check "mark-good is enabled" sudo test -L \
        "$dir/etc/systemd/system/multi-user.target.wants/molniya-mark-good.service"

    # Three artifacts must agree that p1 is mounted: slots.conf names the
    # selector partition, fstab mounts it, and the mountpoint must exist. A
    # missing directory means the mount silently does not happen -- the state
    # every image before 2026-08-26 shipped in, invisible to every check then.
    selp="$(sread "$dir/etc/molniya/slots.conf" | sed -n 's/^MOLNIYA_SELECTOR_PARTITION=//p')"
    check "slots.conf names the selector partition" test -n "$selp"
    mp="$(sread "$dir/etc/fstab" | awk -v n="p${selp}" '$1 ~ n"$" { print $2 }')"
    check "fstab mounts the selector (p$selp)" test -n "$mp"
    check "and its mountpoint exists in the root" sudo test -d "$dir$mp"
    opts="$(sread "$dir/etc/fstab" | awk -v n="p${selp}" '$1 ~ n"$" { print $4 }')"
    check_eq "and it is mounted read-only" "ro" "${opts%%,*}"
}


main() {
    [ $# -eq 3 ] || die "usage: verify-rauc.sh <slot-root-dir> <A|B> <target-dev>"
    local dir="$1" slot="$2"
    case "$slot" in A | B) ;; *) die "slot must be A or B, got '$slot'" ;; esac
    [ -d "$dir" ] || die "$dir: not a directory"
    [ -x "$LAYOUT" ] || die "$LAYOUT: not executable"
    TARGET_DEV="$3"
    verify_rauc "$dir" "$slot"
}

main "$@"
