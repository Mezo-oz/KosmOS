#!/usr/bin/env bash
# 10-kosmos — KosmOS dynamic MOTD (login banner + appliance status)
#
# The star field above the wordmark is NOT decoration: it is derived
# deterministically from the SHA-256 of the flashed image (same idea as
# OpenSSH's randomart for key fingerprints). Two boxes flashed from the same
# release show the same constellation; a different image shows a different
# sky. A human won't diff 64 hex chars, but will notice a different sky.
#
# Digest source, in order of precedence:
#   1. $KOSMOS_IMAGE_DIGEST            (env override — testing/preview)
#   2. /etc/kosmos/image-digest        (stamped by the build; see NOTE)
#   3. none → the default sky, sha256("KosmOS"), and status shows "unstamped"
#
# NOTE (build side): an artifact cannot contain its own hash — embedding it
# changes the hash. Stamp the digest of the assembled rootfs at a defined
# point BEFORE final packaging; the published .img.gz digest maps to it via
# SHA256SUMS. Slots installed via RAUC can instead be stamped with the bundle
# digest RAUC verified at install time.
#
# Install:  sudo install -m 0755 10-kosmos /etc/update-motd.d/10-kosmos
# Preview:  ./10-kosmos [--small] [--plain]
#           KOSMOS_IMAGE_DIGEST=$(sha256sum some.img | cut -d' ' -f1) ./10-kosmos
#
# Contract (standard 8): the banner IS this script's product → stdout.
# Every status probe degrades to "unavailable"; a broken probe must never
# break login (standard 3: expected failures handled explicitly).

set -euo pipefail

readonly KOSMOS_LIB="/usr/local/lib/kosmos"
readonly DIGEST_FILE="/etc/kosmos/image-digest"

# Sky geometry: 4 rows of stars, columns 0..38, Saturn fixed to the right.
readonly SKY_ROWS=4
readonly SKY_COLS=39
readonly STAR_COUNT=14   # 14 stars × 2 digest bytes = 28 of the 32 bytes

# --- color -------------------------------------------------------------------

C_SAT=""; C_WORD=""; C_TAG=""; C_LABEL=""; C_VALUE=""; C_RESET=""

enable_color() {
  C_SAT=$'\033[2;36m'      # dim cyan  — stars + satellite
  C_WORD=$'\033[1;36m'     # bold cyan — wordmark
  C_TAG=$'\033[2m'         # dim       — tagline
  C_LABEL=$'\033[2m'       # dim       — status labels
  C_VALUE=$'\033[0m'       # normal    — status values
  C_RESET=$'\033[0m'
}

# --- image digest ------------------------------------------------------------

IMAGE_DIGEST=""          # 64 lowercase hex chars when stamped, else empty

load_digest() {
  local candidate=""
  if [[ -n "${KOSMOS_IMAGE_DIGEST:-}" ]]; then
    candidate="$KOSMOS_IMAGE_DIGEST"
  elif [[ -r "$DIGEST_FILE" ]]; then
    candidate="$(head -n 1 "$DIGEST_FILE" 2>/dev/null)" || candidate=""
  fi
  candidate="$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  if [[ "$candidate" =~ ^[0-9a-f]{64}$ ]]; then
    IMAGE_DIGEST="$candidate"
  fi
}

sky_seed() {
  # The digest that positions the stars: the image's when stamped,
  # otherwise sha256("KosmOS") so an unstamped box still gets a stable sky.
  if [[ -n "$IMAGE_DIGEST" ]]; then
    printf '%s' "$IMAGE_DIGEST"
  else
    printf 'KosmOS' | sha256sum | cut -d' ' -f1
  fi
}

# --- art ---------------------------------------------------------------------

print_sky_and_planet() {
  # Star constellation (left, digest-derived) + fixed Saturn, with Titan
  # in transit across the disk (right).
  local seed="$1"
  local -A field=()
  local i b1 b2 row col pick glyph line

  for (( i = 0; i < STAR_COUNT; i++ )); do          # bounded: STAR_COUNT
    b1=$(( 16#${seed:i*4:2} ))
    b2=$(( 16#${seed:i*4+2:2} ))
    row=$(( b2 % SKY_ROWS ))
    col=$(( b1 % SKY_COLS ))
    pick=$(( (b1 ^ b2) % 5 ))
    case "$pick" in
      0|1|2) glyph='·' ;;
      3)     glyph='✦' ;;
      *)     glyph='✧' ;;
    esac
    field["$row,$col"]="$glyph"                      # collisions overwrite
  done

  local planet=(
    '       .--.'
    '   ──═( ●  )═──'
    '       `--´'
    ''
  )

  printf '%s' "$C_SAT"
  for (( row = 0; row < SKY_ROWS; row++ )); do       # bounded: SKY_ROWS
    line=""
    for (( col = 0; col < SKY_COLS; col++ )); do     # bounded: SKY_COLS
      line+="${field["$row,$col"]:- }"
    done
    printf '%s%s\n' "$line" "${planet[$row]}"
  done
}

print_wordmark() {
  printf '%s' "$C_WORD"
  cat <<'EOF'
██╗  ██╗ ██████╗ ███████╗███╗   ███╗ ██████╗ ███████╗
██║ ██╔╝██╔═══██╗██╔════╝████╗ ████║██╔═══██╗██╔════╝
█████╔╝ ██║   ██║███████╗██╔████╔██║██║   ██║███████╗
██╔═██╗ ██║   ██║╚════██║██║╚██╔╝██║██║   ██║╚════██║
██║  ██╗╚██████╔╝███████║██║ ╚═╝ ██║╚██████╔╝███████║
╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝     ╚═╝ ╚═════╝ ╚══════╝
EOF
  printf '%s' "$C_TAG"
  cat <<'EOF'
      ── built from bare metal · aimed at the stars ──
EOF
  printf '%s' "$C_RESET"
}

print_banner_small() {
  printf '%s' "$C_WORD"
  cat <<'EOF'
   __ __               ____  ____
  / //_/__  ___ __ _  / __ \/ __/
 / ,< / _ \(_-</  ' \/ /_/ /\ \
/_/|_|\___/___/_/_/_/\____/___/
EOF
  printf '%s── bare metal → stars ──%s\n' "$C_TAG" "$C_RESET"
}

# --- status probes (each prints one value; never fails the script) ----------

probe_kernel() {
  local rel
  rel="$(uname -r 2>/dev/null)" || { printf 'unavailable'; return 0; }
  if uname -v 2>/dev/null | grep -q 'PREEMPT_RT'; then
    printf '%s · PREEMPT_RT' "$rel"
  else
    printf '%s' "$rel"
  fi
}

probe_slot() {
  local out slot verdict
  [[ -x "$KOSMOS_LIB/slot-identity.sh" ]] || { printf 'unavailable'; return 0; }
  out="$("$KOSMOS_LIB/slot-identity.sh" 2>/dev/null)" || { printf 'unavailable'; return 0; }
  slot="$(grep -oE 'SLOT=[AB]' <<<"$out" | head -n 1 | cut -d= -f2)" || true
  verdict="$(grep -oE 'VERDICT=[a-z]+' <<<"$out" | head -n 1 | cut -d= -f2)" || true
  printf '%s (%s)' "${slot:-?}" "${verdict:-unknown}"
}

probe_markgood() {
  local result
  result="$(systemctl show kosmos-mark-good.service -p Result --value 2>/dev/null)" || result=""
  case "$result" in
    success) printf 'committed' ;;
    "")      printf 'unavailable' ;;
    *)       printf '%s' "$result" ;;
  esac
}

probe_image() {
  if [[ -n "$IMAGE_DIGEST" ]]; then
    printf '%s…' "${IMAGE_DIGEST:0:12}"
  else
    printf 'unstamped'
  fi
}

probe_uptime() {
  uptime -p 2>/dev/null || printf 'unavailable'
}

print_row() {
  printf '  %s%-8s%s%s\n' "$C_LABEL" "$1" "$C_VALUE" "$2"
}

print_status() {
  print_row "kernel" "$(probe_kernel)"
  print_row "slot"   "$(probe_slot)"
  print_row "update" "$(probe_markgood)"
  print_row "image"  "$(probe_image)"
  print_row "uptime" "$(probe_uptime)"
  printf '%s' "$C_RESET"
}

# --- main --------------------------------------------------------------------

main() {
  local small=0 want_color=1 arg

  for arg in "$@"; do
    case "$arg" in
      --small)      small=1 ;;
      --plain|-p)   want_color=0 ;;
      -h|--help)    printf 'usage: %s [--small] [--plain]\n' "${0##*/}" >&2; return 0 ;;
      *)            printf 'unknown option: %s\n' "$arg" >&2; return 2 ;;
    esac
  done

  [[ -n "${NO_COLOR:-}" ]] && want_color=0
  [[ "${KOSMOS_MOTD_COLOR:-}" == "never" ]] && want_color=0
  (( want_color )) && enable_color

  load_digest

  printf '\n'
  if (( small )); then
    print_banner_small
  else
    print_sky_and_planet "$(sky_seed)"
    print_wordmark
  fi
  printf '\n'
  print_status
  printf '\n'
}

main "$@"
