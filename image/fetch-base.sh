#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# KosmOS — fetch and verify the base OS image (Phase 4a, stage 1)
# ============================================================================
# Downloads one pinned Raspberry Pi OS Lite image, verifies it, decompresses
# it, and prints the path of the verified .img on stdout. Everything else in
# 4a builds on top of what this produces.
#
#   ./fetch-base.sh              # fetch, verify, decompress; print the .img path
#   ./fetch-base.sh --print-pin  # print what is pinned, download nothing
#
# Cache directory is $KOSMOS_BUILD_CACHE, default /var/tmp/kosmos-build.
# NOT /tmp: on Raspberry Pi OS that is a 2 GB tmpfs, and this writes ~3 GB.
# Failing that way costs a 500 MB download to discover.
#
# ----------------------------------------------------------------------------
# WHY A STOCK IMAGE, rather than pi-gen or debootstrap
# ----------------------------------------------------------------------------
# ROADMAP 4d deferred "pi-gen vs debootstrap" to 4a. The answer is neither: the
# base is the official Raspberry Pi OS Lite image, taken as a pinned binary.
# Reasoning is in ROADMAP 4a; the short form is that the official image IS
# pi-gen output, and it is the only one of the three that can be pinned. Its
# .info file names the pi-gen commit that produced it and the exact version of
# every package in it, and a SHA-256 is published beside it. Running pi-gen
# ourselves would produce a DIFFERENT image every time -- apt moves underneath
# it -- with no digest to check against. So this route gets pi-gen's product
# and a pin, without running pi-gen.
#
# THE DIGEST IS PINNED HERE, IN THE SOURCE, and deliberately not fetched from
# the .sha256 file beside the image. A digest downloaded from the same host as
# the artifact it describes proves only that the two agree, which a server
# serving both can arrange. Pinning it in the repo means changing the image
# requires changing this file, in a diff someone reviews.
# ============================================================================

set -euo pipefail

# --- The pin ----------------------------------------------------------------
# Raspberry Pi OS Lite arm64, Debian 13 trixie. Same Debian release pi-server
# runs, so a native arm64 chroot needs no qemu.
#
# Two dates, and they are genuinely different: the directory is named for the
# release date, the file for the build date. Getting them confused yields a
# 404, so both are spelled out rather than derived from one another.
readonly BASE_RELEASE="2026-06-19"          # directory
readonly BASE_BUILD="2026-06-18"            # file
readonly BASE_NAME="${BASE_BUILD}-raspios-trixie-arm64-lite"
readonly BASE_URL_DIR="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-${BASE_RELEASE}"
readonly BASE_SHA256="acff736ca7945e3b305f07cda4abdb870910e12634991da69783611756e381b3"

# Verified present in this image's published manifest, and both are load-bearing
# for Phase 4d rather than nice to have:
#   raspberrypi-sys-mods 1:20260612  ships 40-rpi-enable-watchdog.conf, which is
#                                    what arms the watchdog. A debootstrap image
#                                    has no such file and nothing says so.
#   raspi-utils          20260601-1  ships vcmailbox, which is how the tryboot
#                                    flag gets set at all.
readonly REQUIRED_PACKAGES="raspberrypi-sys-mods raspi-utils"

CACHE="${KOSMOS_BUILD_CACHE:-/var/tmp/kosmos-build}"

die() { echo "fetch-base.sh: $*" >&2; exit 1; }
note() { echo "  $*" >&2; }

print_pin() {
    echo "release_dir  ${BASE_RELEASE}"
    echo "image        ${BASE_NAME}.img.xz"
    echo "url          ${BASE_URL_DIR}/${BASE_NAME}.img.xz"
    echo "sha256       ${BASE_SHA256}"
    echo "requires     ${REQUIRED_PACKAGES}"
}

# sha256sum --check against the pinned digest. Written as an explicit compare
# rather than piping into --check so the failure message can name both values;
# "WARNING: 1 computed checksum did NOT match" does not tell you which pin the
# file missed when two images are in the cache.
verify_sha256() {
    local file="$1" actual
    actual=$(sha256sum "$file" | cut -d' ' -f1)
    if [ "$actual" != "$BASE_SHA256" ]; then
        note "expected $BASE_SHA256"
        note "actual   $actual"
        return 1
    fi
    return 0
}

# Download only if the cached copy is missing or fails the pin. A partial file
# from an interrupted run fails verification and is re-fetched rather than
# resumed: resuming assumes the bytes already on disk came from the same image,
# which is the assumption the digest exists to avoid making.
fetch_xz() {
    local xz="$1"
    if [ -f "$xz" ] && verify_sha256 "$xz" 2>/dev/null; then
        note "cached and verified: $xz"
        return 0
    fi

    [ ! -f "$xz" ] || { note "cached copy failed the pin, refetching"; rm -f "$xz"; }

    note "downloading ${BASE_NAME}.img.xz (about 500 MB)"
    # A bar for a human, nothing for a log. curl's default progress table
    # writes a line per update to stderr, which in a captured build log is a
    # few hundred lines of carriage-return soup around the two messages that
    # matter.
    # An array, not a string: an unquoted string would need a shellcheck
    # disable= directive to pass SC2086, and this tree has none anywhere.
    local -a progress
    if [ -t 2 ]; then
        progress=(--progress-bar)
    else
        progress=(--silent --show-error)
    fi

    curl -fL --retry 3 --retry-delay 5 "${progress[@]}" \
        -o "$xz.part" "${BASE_URL_DIR}/${BASE_NAME}.img.xz" ||
        die "download failed"
    mv "$xz.part" "$xz"

    verify_sha256 "$xz" || die "SHA-256 mismatch — refusing to use this image"
    note "sha256 ok"
}

# Decompress to .img. unxz is given the whole file rather than streamed from
# curl on purpose: the digest covers the .xz, so it has to exist on disk in one
# piece to be checked before anything unpacks it.
decompress() {
    local xz="$1" img="$2"
    if [ -f "$img" ]; then
        note "already decompressed: $img"
        return 0
    fi
    note "decompressing (about 3 GB uncompressed)"
    unxz --keep --stdout "$xz" > "$img.part" || { rm -f "$img.part"; die "unxz failed"; }
    mv "$img.part" "$img"
}

main() {
    case "${1-}" in
        --print-pin) print_pin; return 0 ;;
        "") ;;
        *) die "unknown argument '$1' (try --print-pin)" ;;
    esac

    command -v curl > /dev/null 2>&1 || die "curl not found"
    command -v unxz > /dev/null 2>&1 || die "unxz not found (apt install xz-utils)"
    command -v sha256sum > /dev/null 2>&1 || die "sha256sum not found"

    mkdir -p "$CACHE" || die "cannot create cache directory $CACHE"

    local xz="$CACHE/${BASE_NAME}.img.xz"
    local img="$CACHE/${BASE_NAME}.img"

    # ~3.5 GB for both files. Checked before the download rather than after,
    # because running out of disk halfway through decompression leaves a
    # truncated .img.part that looks like an interrupted download.
    local avail_mb
    avail_mb=$(df -Pm "$CACHE" | awk 'NR==2 {print $4}')
    if [ "${avail_mb:-0}" -lt 4096 ]; then
        die "need ~4 GB free in $CACHE, have ${avail_mb} MB"
    fi

    fetch_xz "$xz"
    decompress "$xz" "$img"

    # The consumer wants the path and nothing else; every message above went to
    # stderr so this line can be captured directly.
    echo "$img"
}

main "$@"
