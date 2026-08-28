#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — build a signed RAUC update bundle (Phase 4d)
# ============================================================================
#   ./build-bundle.sh --image <img> --version <v> --out <bundle.raucb>
#
#   --image <path>     image to take slot A's filesystems from
#   --version <v>      bundle version, e.g. 0.9.0
#   --out <path>       where to write the .raucb
#   --cert <path>      signing certificate  (or MOLNIYA_SIGN_CERT)
#   --key <path>       signing private key  (or MOLNIYA_SIGN_KEY)
#   --keyring <path>   CA cert to verify the result (or MOLNIYA_RAUC_CERT)
#   --description <s>  free text recorded in the manifest
#
# Prints the bundle path on stdout. Everything else is stderr (standard 8).
#
# ---------------------------------------------------------------------------
# THE PAYLOAD IS TARS, NOT FILESYSTEM IMAGES, AND THAT IS A DISK DECISION.
# RAUC 1.13 picks an update handler by file extension; the set compiled into
# the binary is *.tar*, *.ext4, *.img, *.vfat, *.squashfs, *.ubifs. For a
# *.tar* it runs mkfs on the target slot and extracts into it (`tar-extract`,
# `mkfs.ext4`, `mkfs.vfat` are all in the binary).
#
# A raw-image bundle would carry a 4 GB ext4 and a 512 MB vfat verbatim --
# ~4.5 GB, against a build host with ~3.4 GB free. The tars compress to roughly
# 1.8 GB and never need the uncompressed form to exist anywhere. That is the
# difference between a bundle that can be built and one that cannot.
#
# WHY SLOT A. The two slots are copies of one rootfs, so either would do; A is
# named so the bundle's contents are decided rather than incidental.
#
# ---------------------------------------------------------------------------
# THE SIGNING KEY IS DECRYPTED TO A TEMPORARY FILE. Measured on rauc
# 1.13-3+deb13u1: `rauc bundle --key=<encrypted.pem>` with stdin closed exits 1
# with "PEM_def_callback: problems getting password", and on a terminal it
# prompts. There is no --key-passphrase. So the key is decrypted to a 0600 file
# under a directory this script creates and removes on EXIT -- including on
# failure, which is why the trap is installed before the file is written.
#
# Point MOLNIYA_BUNDLE_TMP at a tmpfs to keep the plaintext key off disk
# entirely; /dev/shm is the usual answer and is the default when it exists.
#
# ---------------------------------------------------------------------------
# IT VERIFIES WHAT IT BUILT, against the CA cert the images trust rather than
# against the signing cert it just used. Those are different questions: signing
# proves the bundle was made here, verifying against the CA proves a DEVICE
# will accept it. Only the second one matters in the field, and it is the one
# a build can silently get wrong -- an expired signing cert, or one issued by
# a CA that is not the CA in the image, produces a bundle that is perfectly
# well-formed and rejected by every box.
# ============================================================================

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYOUT="$SELF_DIR/layout.sh"
CACHE="${MOLNIYA_BUILD_CACHE:-/var/tmp/molniya-build}"

SIGN_CERT="${MOLNIYA_SIGN_CERT:-}"
SIGN_KEY="${MOLNIYA_SIGN_KEY:-}"
KEYRING="${MOLNIYA_RAUC_CERT:-}"

IMG=""
VERSION=""
OUT=""
DESCRIPTION=""

WORK=""
MOUNTED=()
LOOPDEV=""

die()  { echo "build-bundle.sh: $*" >&2; exit 1; }
note() { echo "  $*" >&2; }
step() { echo "==> $*" >&2; }

teardown() {
    local rc=$? i
    for (( i=${#MOUNTED[@]} - 1; i >= 0; i-- )); do
        sudo umount "${MOUNTED[i]}" 2>/dev/null || sudo umount -l "${MOUNTED[i]}" 2>/dev/null || true
    done
    MOUNTED=()
    [ -z "$LOOPDEV" ] || { sudo losetup -d "$LOOPDEV" 2>/dev/null || true; LOOPDEV=""; }
    # The decrypted signing key lives in here. Removing it is the whole reason
    # this trap exists, so it is not conditional on success.
    [ -z "$WORK" ] || sudo rm -rf "$WORK"
    return "$rc"
}
trap teardown EXIT

slotmap_get() {
    local key="$1"
    "$LAYOUT" slotmap | sed -n "s/^${key}=//p"
}

# Tar one mounted filesystem. --numeric-owner because the build host's
# /etc/passwd is not the target's: resolving to names here and back to ids on
# the box is how a rootfs arrives owned by whoever happens to hold uid 1000.
# --acls/--xattrs so capabilities on binaries survive; ping loses its
# cap_net_raw otherwise and starts failing for non-root after an update.
tar_filesystem() {
    local src="$1" dest="$2"
    sudo tar --numeric-owner --acls --xattrs --xattrs-include='*' \
        --warning=no-file-ignored --warning=no-file-changed \
        -C "$src" -czf "$dest" . ||
        die "tar of $src failed"
    sudo chown "$(id -u):$(id -g)" "$dest"
}

usage() {
    sed -n '4,16p' "${BASH_SOURCE[0]}" | sed 's/^# \?//' >&2
    exit 2
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --image)       [ $# -ge 2 ] || usage; IMG="$2"; shift 2 ;;
            --version)     [ $# -ge 2 ] || usage; VERSION="$2"; shift 2 ;;
            --out)         [ $# -ge 2 ] || usage; OUT="$2"; shift 2 ;;
            --cert)        [ $# -ge 2 ] || usage; SIGN_CERT="$2"; shift 2 ;;
            --key)         [ $# -ge 2 ] || usage; SIGN_KEY="$2"; shift 2 ;;
            --keyring)     [ $# -ge 2 ] || usage; KEYRING="$2"; shift 2 ;;
            --description) [ $# -ge 2 ] || usage; DESCRIPTION="$2"; shift 2 ;;
            -h|--help)     usage ;;
            *)             die "unknown argument '$1'" ;;
        esac
    done

    IMG="${IMG:-$CACHE/molniya-rpi5.img}"
    [ -f "$IMG" ] || die "$IMG: no such image"
    [ -n "$VERSION" ] || die "--version is required (it is what rauc status reports)"
    [ -n "$OUT" ] || die "--out is required"
    [ -n "$SIGN_CERT" ] || die "no signing certificate: --cert or MOLNIYA_SIGN_CERT.
  Create one with: image/rauc/make-keys.sh sign <ca-dir> <out-dir>"
    [ -n "$SIGN_KEY" ] || die "no signing key: --key or MOLNIYA_SIGN_KEY"
    [ -f "$SIGN_CERT" ] || die "$SIGN_CERT: not a file"
    [ -f "$SIGN_KEY" ] || die "$SIGN_KEY: not a file"
    [ ! -e "$OUT" ] || die "$OUT exists; refusing to overwrite a bundle"
    command -v rauc > /dev/null 2>&1 ||
        die "rauc is not installed on this host. It is the build tool here, not
  just a runtime: apt-get install rauc  (trixie ships 1.13, matching the image)"

    local compatible
    compatible="$(slotmap_get MOLNIYA_COMPATIBLE)"
    [ -n "$compatible" ] || die "layout.sh slotmap reports no MOLNIYA_COMPATIBLE"

    # 0700 before anything is written into it, so the decrypted key is never
    # briefly world-readable.
    local tmpbase="${MOLNIYA_BUNDLE_TMP:-}"
    if [ -z "$tmpbase" ]; then
        if [ -d /dev/shm ]; then tmpbase=/dev/shm; else tmpbase="${TMPDIR:-/tmp}"; fi
    fi
    WORK="$(mktemp -d "$tmpbase/molniya-bundle.XXXXXX")"
    chmod 700 "$WORK"
    mkdir -p "$WORK/in" "$WORK/mnt"

    step "identity — what this bundle is"
    note "image        $IMG"
    note "compatible   $compatible"
    note "version      $VERSION"
    note "signed by    $(openssl x509 -in "$SIGN_CERT" -noout -subject | sed 's/^subject=//')"

    step "key — decrypting the signing key into $WORK"
    # `openssl pkey` prompts if the key is encrypted and is a no-op copy if it
    # is not, so one path covers both and neither needs a flag from the caller.
    #
    # The passphrase comes from MOLNIYA_SIGN_PASS when it is set, via `env:` and
    # not `pass:` -- `pass:` puts the secret in argv where `ps` can read it.
    #
    # WITHOUT IT, AND WITH NO TERMINAL, THIS IS CHECKED RATHER THAN ATTEMPTED.
    # openssl reads a passphrase from /dev/tty, not stdin, so piping one in
    # does nothing and the process blocks forever -- which is what happened the
    # first time this script was run non-interactively. A release build that
    # hangs is worse than one that fails: it holds a loop device and a
    # plaintext key while it waits, and CI reports nothing at all.
    local -a passin=()
    if [ -n "${MOLNIYA_SIGN_PASS:-}" ]; then
        passin=(-passin env:MOLNIYA_SIGN_PASS)
    elif ! [ -t 0 ]; then
        # An unencrypted key needs no passphrase, so only refuse if it is one.
        case "$(head -1 "$SIGN_KEY")" in
            *ENCRYPTED*)
                die "the signing key is encrypted and there is no terminal to
  ask on. openssl reads passphrases from /dev/tty, so piping one to this
  script's stdin will hang rather than work. Set MOLNIYA_SIGN_PASS instead." ;;
        esac
    fi
    ( umask 077; openssl pkey -in "$SIGN_KEY" "${passin[@]}" -out "$WORK/sign.key.pem" ) ||
        die "could not read the signing key (wrong passphrase?)"
    chmod 600 "$WORK/sign.key.pem"
    note "plaintext key is under $WORK and is removed on exit"

    step "attach — $IMG read-only"
    LOOPDEV="$(sudo losetup --show -rfP "$IMG")"
    note "$LOOPDEV"

    local proot pboot
    proot="$(slotmap_get MOLNIYA_SLOT_A_ROOT)"
    pboot="$(slotmap_get MOLNIYA_SLOT_A_BOOT)"

    step "payload — slot A rootfs (p$proot) and bootfs (p$pboot) as tars"
    sudo mkdir -p "$WORK/mnt/root" "$WORK/mnt/boot"
    sudo mount -o ro "${LOOPDEV}p${proot}" "$WORK/mnt/root"; MOUNTED+=("$WORK/mnt/root")
    sudo mount -o ro "${LOOPDEV}p${pboot}" "$WORK/mnt/boot"; MOUNTED+=("$WORK/mnt/boot")

    tar_filesystem "$WORK/mnt/root" "$WORK/in/rootfs.tar.gz"
    note "rootfs.tar.gz  $(du -h "$WORK/in/rootfs.tar.gz" | cut -f1)"
    tar_filesystem "$WORK/mnt/boot" "$WORK/in/bootfs.tar.gz"
    note "bootfs.tar.gz  $(du -h "$WORK/in/bootfs.tar.gz" | cut -f1)"

    # Unmount before bundling: mksquashfs reads $WORK/in, and leaving the image
    # attached for that has no purpose beyond widening the window in which a
    # loop device is held.
    step "detach — the image is no longer needed"
    local i
    for (( i=${#MOUNTED[@]} - 1; i >= 0; i-- )); do sudo umount "${MOUNTED[i]}"; done
    MOUNTED=()
    sudo losetup -d "$LOOPDEV"; LOOPDEV=""

    step "manifest"
    # format=verity, explicitly. Left unset, rauc 1.13 defaults to `plain` and
    # says so in a warning nobody reads twice. verity signs a dm-verity root
    # hash rather than the whole file, which is what makes a bundle streamable
    # and lets the device detect tampering as it reads rather than only up
    # front.
    {
        printf '[update]\n'
        printf 'compatible=%s\n' "$compatible"
        printf 'version=%s\n' "$VERSION"
        [ -z "$DESCRIPTION" ] || printf 'description=%s\n' "$DESCRIPTION"
        printf '\n[bundle]\nformat=verity\n'
        printf '\n[image.rootfs]\nfilename=rootfs.tar.gz\n'
        printf '\n[image.bootfs]\nfilename=bootfs.tar.gz\n'
    } > "$WORK/in/manifest.raucm"
    sed 's/^/    /' "$WORK/in/manifest.raucm" >&2

    step "bundle — signing"
    mkdir -p "$(dirname "$OUT")"
    rauc bundle --cert="$SIGN_CERT" --key="$WORK/sign.key.pem" \
        "$WORK/in" "$OUT" >&2 || die "rauc bundle failed"
    note "$(du -h "$OUT" | cut -f1)  $OUT"

    step "verify — will a device actually accept this?"
    if [ -n "$KEYRING" ]; then
        [ -f "$KEYRING" ] || die "$KEYRING: not a file"
        rauc info --keyring="$KEYRING" "$OUT" >&2 ||
            die "the bundle does not verify against $KEYRING.
  It is signed, but no box carrying that CA will install it. Check that the
  signing cert was issued by this CA and has not expired."
        note "verified against $(openssl x509 -in "$KEYRING" -noout -subject | sed 's/^subject=//')"
    else
        note "WARNING no keyring given, so nothing checked that a DEVICE will"
        note "        accept this bundle. Pass --keyring <ca.cert.pem>."
    fi

    step "digest"
    sha256sum "$OUT" | sed 's/^/    /' >&2
    ( cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" ) > "$OUT.sha256"

    note ""
    note "install it offline with:  rauc install $(basename "$OUT")"
    echo "$OUT"
}

main "$@"
