#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — the update-signing PKI (Phase 4d)
# ============================================================================
#   ./make-keys.sh ca   <ca-dir>              create the root CA
#   ./make-keys.sh sign <ca-dir> <out-dir>    issue a signing key + cert
#   ./make-keys.sh show <dir>                 print what is in a key directory
#
# TWO KEYS, NOT ONE, AND THE SPLIT IS THE WHOLE POINT. The CA cert is baked
# into every image as RAUC's keyring; the signing cert is what actually signs a
# bundle. Because RAUC verifies the chain, a bundle signed by any cert the CA
# issued is accepted by a device that has only ever seen the CA cert.
#
# That is what makes the signing key ROTATABLE. Lose it, or retire it on a
# schedule, and you issue another from the same CA -- every deployed box keeps
# working, untouched. Sign with the CA key directly and the key you must never
# lose is also the key you use every release, which is the arrangement that
# ends with a reflash of every device in the field.
#
#   CA key      -> offline, encrypted, on removable media. Used ~once a year.
#   signing key -> encrypted, on the build host. Used every release.
#   CA cert     -> public. Goes in the image. Not secret, and not in this repo.
#
# ---------------------------------------------------------------------------
# NO KEY MATERIAL IN THE REPO, EVER -- and this script enforces it rather than
# asking. Both subcommands refuse a destination inside the work tree, because
# the failure is silent and permanent: a private key committed to a public repo
# is compromised the moment it is pushed, and rewriting history does not
# un-publish it. A .gitignore is a request; this is a gate.
#
# THE CA CERT IS DELIBERATELY NOT SHIPPED IN THIS REPO EITHER, and that is a
# supply-chain decision, not an oversight. Committing ours would make it the
# default trust root for every image anyone builds from this tree -- so a
# box that is not ours would install bundles WE signed. Whoever builds MolniyaOS
# generates their own CA. That is why provision-rauc.sh fails loudly with no
# cert rather than falling back to one.
#
# ---------------------------------------------------------------------------
# WHY THE KEYS ARE ENCRYPTED AT REST BUT HANDED TO RAUC DECRYPTED. Measured
# against rauc 1.13-3+deb13u1, the version the image ships:
#
#   rauc bundle --key=<encrypted.pem>  with stdin closed
#     -> rc=1, PEM_def_callback: problems getting password
#
# RAUC has no --key-passphrase and no passphrase channel short of a real
# PKCS#11 token, so an encrypted key cannot sign non-interactively at all: on a
# terminal it prompts, and unattended it fails as above. build-bundle.sh
# therefore decrypts to a 0600 temp file it removes on EXIT. Encryption at rest
# is what protects the key on the disk; it was never going to protect it from
# the process that has to use it.
# ============================================================================

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Days. The CA outlives the hardware on purpose -- replacing it means reflashing
# every device, so it is sized to never be the reason for one.
CA_DAYS="${MOLNIYA_CA_DAYS:-7300}"       # 20 years
SIGN_DAYS="${MOLNIYA_SIGN_DAYS:-1825}"   # 5 years
BITS="${MOLNIYA_KEY_BITS:-4096}"

ORG="${MOLNIYA_PKI_ORG:-MolniyaOS}"

# Passphrases. Unset means openssl prompts on the terminal, which is the right
# default for a key a human is creating. Set MOLNIYA_CA_PASS / MOLNIYA_SIGN_PASS
# and openssl reads them from the environment instead -- which is what makes
# this script testable, and what lets a password manager drive it.
#
# `env:` and not `pass:`: with `pass:` the passphrase is an argv element and is
# readable by any user via `ps` for as long as openssl runs.
CA_PASS_VAR="MOLNIYA_CA_PASS"
SIGN_PASS_VAR="MOLNIYA_SIGN_PASS"

die()  { echo "make-keys.sh: $*" >&2; exit 1; }
note() { echo "  $*" >&2; }
step() { echo "==> $*" >&2; }

# Emit openssl passphrase arguments for a variable, or nothing when it is
# unset. Written into an array by the caller so an empty result contributes no
# argument at all -- an unquoted expansion here would pass an empty string,
# which openssl reads as an empty passphrase rather than as "ask me".
pass_args() {
    local direction="$1" var="$2"
    [ -n "${!var:-}" ] || return 0
    printf '%s\n' "-pass${direction}" "env:$var"
}

# The work tree, so a destination inside it can be refused. git is asked first
# because a clone may live anywhere; the relative walk is the fallback for a
# tarball export with no .git.
repo_root() {
    git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null && return 0
    (cd "$SELF_DIR/../.." && pwd)
}

# Refuse any path inside the repo. Resolved with `realpath -m` so it works on a
# directory that does not exist yet, and so a `..` component cannot walk back in
# after the check.
refuse_in_repo() {
    local dir="$1" root resolved
    root="$(realpath -m "$(repo_root)")"
    resolved="$(realpath -m "$dir")"
    case "$resolved/" in
        "$root"/*)
            die "refusing to write key material inside the repository.
    $resolved
  is under the work tree at
    $root
  A private key committed to a public repo is compromised the moment it is
  pushed, and rewriting history does not un-publish it. Put this on removable
  media (the CA) or outside the tree (the signing key)." ;;
    esac
}

# openssl writes the key before we get a chance to chmod it, so the window is
# closed by creating the directory 0700 first and letting the file be born
# unreadable to anyone else.
prepare_dir() {
    local dir="$1"
    refuse_in_repo "$dir"
    mkdir -p "$dir"
    chmod 700 "$dir"
}

make_ca() {
    local dir="$1"
    prepare_dir "$dir"
    [ ! -f "$dir/ca.key.pem" ] ||
        die "$dir/ca.key.pem exists. Refusing to overwrite a CA: every image
  carrying the old cert would stop accepting bundles signed under the new one."

    step "root CA -> $dir  (${BITS}-bit, ${CA_DAYS} days)"

    local -a pout=()
    mapfile -t pout < <(pass_args out "$CA_PASS_VAR")
    [ "${#pout[@]}" -gt 0 ] ||
        note "you will be asked for a passphrase; it protects the key at rest"

    openssl req -x509 -newkey "rsa:$BITS" -sha256 \
        -keyout "$dir/ca.key.pem" -out "$dir/ca.cert.pem" \
        -days "$CA_DAYS" "${pout[@]}" \
        -subj "/O=$ORG/CN=$ORG Update CA" >&2

    chmod 600 "$dir/ca.key.pem"
    chmod 644 "$dir/ca.cert.pem"

    note ""
    note "ca.key.pem   SECRET. Offline media, not pi-server, not the repo."
    note "ca.cert.pem  public. This is what goes into the image:"
    note "               export MOLNIYA_RAUC_CERT=$dir/ca.cert.pem"
    echo "$dir/ca.cert.pem"
}

make_sign() {
    local ca="$1" dir="$2"
    [ -f "$ca/ca.key.pem" ]  || die "$ca/ca.key.pem: no CA there. Run: make-keys.sh ca <dir>"
    [ -f "$ca/ca.cert.pem" ] || die "$ca/ca.cert.pem: missing"
    prepare_dir "$dir"

    local name="${MOLNIYA_SIGN_CN:-$ORG Release Signing}"
    step "signing cert -> $dir  (${BITS}-bit, ${SIGN_DAYS} days, CN=$name)"

    local csr="$dir/sign.csr"
    local -a sout=() sin=() cain=()
    mapfile -t sout < <(pass_args out "$SIGN_PASS_VAR")
    mapfile -t sin  < <(pass_args in  "$SIGN_PASS_VAR")
    mapfile -t cain < <(pass_args in  "$CA_PASS_VAR")

    [ "${#sout[@]}" -gt 0 ] || note "passphrase for the NEW signing key:"
    openssl genrsa -aes256 -out "$dir/sign.key.pem" "${sout[@]}" "$BITS" >&2
    chmod 600 "$dir/sign.key.pem"

    [ "${#sin[@]}" -gt 0 ] || note "the same passphrase again, to read the key just written:"
    openssl req -new -key "$dir/sign.key.pem" "${sin[@]}" \
        -out "$csr" -subj "/O=$ORG/CN=$name" >&2

    [ "${#cain[@]}" -gt 0 ] || note "passphrase for the CA key:"
    openssl x509 -req -in "$csr" -sha256 \
        -CA "$ca/ca.cert.pem" -CAkey "$ca/ca.key.pem" "${cain[@]}" -CAcreateserial \
        -out "$dir/sign.cert.pem" -days "$SIGN_DAYS" >&2
    rm -f "$csr"
    chmod 644 "$dir/sign.cert.pem"

    # Prove the chain here rather than discovering it at install time on a box
    # that is mid-update. A signing cert the CA cannot vouch for produces a
    # bundle every device rejects, and the only symptom is a failed install.
    openssl verify -CAfile "$ca/ca.cert.pem" "$dir/sign.cert.pem" >&2 ||
        die "the new signing cert does not verify against the CA"

    note ""
    note "sign.key.pem   SECRET, but rotatable -- reissue from the CA any time."
    note "               export MOLNIYA_SIGN_KEY=$dir/sign.key.pem"
    note "               export MOLNIYA_SIGN_CERT=$dir/sign.cert.pem"
    echo "$dir/sign.cert.pem"
}

show() {
    local dir="$1" f
    for f in "$dir"/*.cert.pem; do
        [ -f "$f" ] || continue
        echo "== $f" >&2
        openssl x509 -in "$f" -noout -subject -issuer -dates -fingerprint -sha256 >&2
    done
    for f in "$dir"/*.key.pem; do
        [ -f "$f" ] || continue
        # head -1 rather than asking openssl, which would want the passphrase.
        printf '== %s  %s  mode %s\n' "$f" "$(head -1 "$f")" "$(stat -c '%a' "$f")" >&2
    done
}

usage() {
    cat >&2 <<'USAGE'
usage: make-keys.sh <command> [args]

  ca   <ca-dir>             create the root CA        (offline media)
  sign <ca-dir> <out-dir>   issue a signing key+cert  (build host)
  show <dir>                print subjects, dates, fingerprints

Prints the created certificate path on stdout. Everything else is stderr.
Refuses to write inside the repository. See ROADMAP 4d.
USAGE
    exit 2
}

main() {
    [ $# -ge 1 ] || usage
    local cmd="$1"; shift
    case "$cmd" in
        ca)   [ $# -eq 1 ] || usage; make_ca "$1" ;;
        sign) [ $# -eq 2 ] || usage; make_sign "$1" "$2" ;;
        show) [ $# -eq 1 ] || usage; show "$1" ;;
        *)    usage ;;
    esac
}

main "$@"
