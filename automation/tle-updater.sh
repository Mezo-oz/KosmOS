#!/usr/bin/env bash
# ============================================================================
# KosmOS — TLE updater
# ============================================================================
# Refreshes orbital elements from CelesTrak. Run it before any session, and on a
# timer for an unattended box.
#
# TLEs decay: a set a week old will point an antenna at empty sky. This is the
# closest thing a ground station has to a clock that needs winding.
#
# THE PATH BUG THIS FIXES:
#   02c-sdr-userspace.sh downloads elements to ~/.config/satellite-tle/, which
#   predict never reads. predict reads exactly one file, ~/.predict/predict.tle,
#   so every "predict -p" answer came from whatever elements the curses installer
#   shipped with — silently stale, with nothing to indicate it. This writes the
#   file predict actually opens.
#
# TWO DESTINATIONS, ON PURPOSE:
#   ~/.predict/predict.tle          a small curated set, for predict
#   ~/.config/satellite-tle/*.tle   whole groups, for gpredict / SatDump / scripts
#
#   They are separate because predict tracks a bounded number of satellites (its
#   documentation says 24) and reads them from that one file. Pointing it at the
#   93-satellite amateur group would not give you 93 satellites; it would give
#   you an unpredictable subset. So predict gets an explicit list, by catalogue
#   number, and everything else gets the groups.
#
# WHY CATALOGUE NUMBERS FOR THE PREDICT SET:
#   Because the obvious group query does not work. GROUP=noaa is not a valid
#   CelesTrak group — it answers HTTP 200 with the body
#   'Invalid query: "GROUP=noaa&FORMAT=tle" (GROUP=noaa not found)', which is 61
#   bytes that a plain download writes to disk as noaa.tle and reports as
#   success. And GROUP=weather, which is valid, does not contain NOAA 15, 18 or
#   19 at all — only the JPSS birds, NOAA 20 and 21. The APT satellites this
#   project targets first are reachable only by catalogue number. Verified
#   against the live API 2026-07-29.
#
#   That is also why every download here is validated before it is installed:
#   the failure mode is a 200 with prose in it, not an error code.
#
# USAGE:
#   ./tle-updater.sh                 update both destinations
#   ./tle-updater.sh --predict-only  skip the group downloads
#   ./tle-updater.sh --dry-run       fetch and validate, install nothing
#
# ON A TIMER — CelesTrak asks not to be polled hard; twice a day is plenty for
# elements that are published daily:
#
#   crontab -e
#   17 5,17 * * *  /home/pi/KosmOS/automation/tle-updater.sh >> /var/log/kosmos-tle.log 2>&1
#
# Exits non-zero if any source failed to fetch or failed validation, so a cron
# job or systemd timer reports it rather than leaving stale elements in place.
# ============================================================================

set -euo pipefail

# --- What to track ----------------------------------------------------------

# The predict set: NORAD catalogue number, then a label for the log. Keep this
# under 24 entries. These three are the NOAA APT satellites — a strong 137 MHz
# downlink, simple modulation, and the easiest first capture.
PREDICT_SATS=(
    "25338:NOAA 15"
    "28654:NOAA 18"
    "33591:NOAA 19"
    "44387:METEOR-M2 2"
    "25544:ISS (ZARYA)"
)

# Whole groups, for the tools that can hold more than 24 satellites. All three
# names verified against the live API.
#
# NOT named GROUPS: bash defines GROUPS itself as an array of the current user's
# group IDs, and per the manual "assignments to GROUPS have no effect" — so the
# loop below silently iterated over a GID and tried to fetch GROUP=197121. It
# failed safely, because every download is validated, but it failed silently
# until the whole thing was run end to end.
TLE_GROUPS=(weather goes amateur)

# --- Where it goes ----------------------------------------------------------

PREDICT_DIR="$HOME/.predict"
PREDICT_TLE="$PREDICT_DIR/predict.tle"
GROUP_DIR="$HOME/.config/satellite-tle"

BASE_URL="https://celestrak.org/NORAD/elements/gp.php"

# predict's documented ceiling on simultaneously tracked satellites. Enforced
# below rather than trusted, because exceeding it fails quietly.
PREDICT_MAX_SATS=24

# How many previous predict.tle files to keep. Bounded, so a twice-daily timer
# cannot fill a partition with backups over a year.
BACKUPS_TO_KEEP=5

# Retries per download, and the pause between them. Bounded on purpose: a cron
# job that retries forever is a cron job that is still running when the next one
# starts.
MAX_TRIES=3
RETRY_SLEEP=5

# --- Options ----------------------------------------------------------------

DRY_RUN=0
PREDICT_ONLY=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)      DRY_RUN=1; shift ;;
        --predict-only) PREDICT_ONLY=1; shift ;;
        -h|--help)
            sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# --- Fetch ------------------------------------------------------------------

# curl if it is there, wget otherwise. Pi OS ships wget in the base image and
# curl in most; requiring both would be gratuitous.
fetch() {
    local url="$1" dest="$2" try=1

    while [ "$try" -le "$MAX_TRIES" ]; do
        if command -v curl > /dev/null 2>&1; then
            if curl -fsS --max-time 30 -o "$dest" "$url"; then
                return 0
            fi
        elif command -v wget > /dev/null 2>&1; then
            if wget -q --timeout=30 --tries=1 -O "$dest" "$url"; then
                return 0
            fi
        else
            echo "ERROR: neither curl nor wget is installed." >&2
            return 1
        fi

        echo "         attempt $try/$MAX_TRIES failed"
        try=$((try + 1))
        [ "$try" -le "$MAX_TRIES" ] && sleep "$RETRY_SLEEP"
    done

    return 1
}

# --- Validation -------------------------------------------------------------

# Every TLE data line carries a mod-10 checksum in column 69: digits contribute
# their value, minus signs contribute 1, everything else contributes nothing.
#
# This is the only integrity check available for this data. Elements change every
# few hours by design, so there is no digest to pin and no version to fix — but a
# truncated transfer, a mangled line, or CelesTrak's HTTP-200 error prose all
# fail the checksum, and that is exactly the class of failure that otherwise gets
# written to disk and trusted.
#
# Prints "<good_lines> <bad_lines>".
tle_line_counts() {
    awk '
        function csum(line,   i, c, s) {
            s = 0
            for (i = 1; i <= 68; i++) {
                c = substr(line, i, 1)
                if (c ~ /^[0-9]$/)  s += c + 0
                else if (c == "-")  s += 1
            }
            return s % 10
        }
        { sub(/\r$/, "") }
        /^[12] / {
            if (length($0) < 69)                        { bad++; next }
            if (csum($0) != substr($0, 69, 1) + 0)      { bad++; next }
            good++
        }
        END { printf "%d %d\n", good + 0, bad + 0 }
    ' "$1"
}

# A CATNR query returns whatever CelesTrak holds for that number, and a typo in
# PREDICT_SATS fetches a real, checksum-clean TLE for the wrong satellite --
# which validate_tle cannot see, because there is nothing wrong with it. The
# catalogue number is columns 3-7 of both element lines, so check it against what
# was asked for.
#
# Tracking the wrong satellite is a failure mode with no symptom: predict answers
# confidently, the antenna points somewhere, and nothing arrives.
validate_catnr() {
    local file="$1" want="$2" label="$3"
    local mismatched

    mismatched=$(awk -v want="$want" '
        function strip(s) { gsub(/^[ 0]+/, "", s); return s }
        { sub(/\r$/, "") }
        /^[12] / {
            if (strip(substr($0, 3, 5)) != strip(want)) bad++
        }
        END { print bad + 0 }
    ' "$file")

    if [ "$mismatched" -ne 0 ]; then
        echo "         REJECTED $label: element lines do not carry catalogue"
        echo "                  number $want — this is a different satellite"
        return 1
    fi

    return 0
}

# Returns 0 if the file holds at least one complete, checksum-clean TLE record.
validate_tle() {
    local file="$1" label="$2"
    local counts good bad

    counts=$(tle_line_counts "$file")
    good=${counts% *}
    bad=${counts#* }

    if [ "$good" -eq 0 ]; then
        echo "         REJECTED $label: no valid TLE lines"
        echo "         first line: $(head -c 120 "$file" | tr -d '\r\n')"
        return 1
    fi
    if [ "$bad" -ne 0 ]; then
        echo "         REJECTED $label: $bad line(s) failed checksum"
        return 1
    fi
    if [ $((good % 2)) -ne 0 ]; then
        echo "         REJECTED $label: odd number of data lines ($good) — truncated"
        return 1
    fi

    echo "         $label: $((good / 2)) satellite(s), checksums clean"
    return 0
}

# --- Main -------------------------------------------------------------------

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

FAILURES=0

echo "============================================"
echo "  KosmOS TLE Update"
echo "============================================"
echo ""
if [ "$DRY_RUN" -eq 1 ]; then
    echo "  DRY RUN — fetching and validating, installing nothing"
    echo ""
fi

# --- The predict set ---

if [ "${#PREDICT_SATS[@]}" -gt "$PREDICT_MAX_SATS" ]; then
    echo "ERROR: PREDICT_SATS has ${#PREDICT_SATS[@]} entries; predict tracks at" >&2
    echo "       most $PREDICT_MAX_SATS. Trim the list — going over does not fail" >&2
    echo "       loudly in predict, it just quietly ignores the excess." >&2
    exit 1
fi

echo "[1/2] Fetching the predict set by catalogue number..."
PREDICT_STAGE="$STAGING/predict.tle"
: > "$PREDICT_STAGE"

for entry in "${PREDICT_SATS[@]}"; do
    catnr="${entry%%:*}"
    label="${entry#*:}"
    one="$STAGING/$catnr.tle"

    echo "       $label (NORAD $catnr)"
    if ! fetch "$BASE_URL?CATNR=$catnr&FORMAT=tle" "$one"; then
        echo "         FETCH FAILED"
        FAILURES=$((FAILURES + 1))
        continue
    fi

    if ! validate_tle "$one" "$label"; then
        FAILURES=$((FAILURES + 1))
        continue
    fi

    if ! validate_catnr "$one" "$catnr" "$label"; then
        FAILURES=$((FAILURES + 1))
        continue
    fi

    # Normalise line endings on the way in: CelesTrak serves CRLF, and predict
    # reads the file with fixed-width column offsets.
    tr -d '\r' < "$one" >> "$PREDICT_STAGE"

    # CelesTrak asks not to be polled hard. One request per second is polite and
    # costs nothing on a five-satellite list.
    sleep 1
done

if [ ! -s "$PREDICT_STAGE" ]; then
    echo ""
    echo "ERROR: nothing valid was fetched — leaving the existing elements alone." >&2
    echo "       Stale elements beat no elements: predict will still run, and the" >&2
    echo "       next scheduled update may succeed." >&2
    exit 1
fi

if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$PREDICT_DIR"

    if [ -f "$PREDICT_TLE" ]; then
        backup="$PREDICT_TLE.$(date -u '+%Y%m%dT%H%M%SZ').bak"
        cp "$PREDICT_TLE" "$backup"
        echo "       backed up previous elements to $(basename "$backup")"

        # Keep the newest BACKUPS_TO_KEEP and delete the rest. find+sort rather
        # than ls, and -print0 so a space in $HOME cannot split a filename.
        find "$PREDICT_DIR" -maxdepth 1 -name 'predict.tle.*.bak' -print0 \
            | sort -zr \
            | tail -z -n "+$((BACKUPS_TO_KEEP + 1))" \
            | xargs -0 -r rm -f
    fi

    install -m 0644 "$PREDICT_STAGE" "$PREDICT_TLE"
    echo "       installed $PREDICT_TLE"
else
    echo "       (dry run — would install $PREDICT_TLE)"
fi

# --- The groups ---

if [ "$PREDICT_ONLY" -eq 1 ]; then
    echo ""
    echo "[2/2] Skipped (--predict-only)."
else
    echo ""
    echo "[2/2] Fetching groups for the tools that can hold more than $PREDICT_MAX_SATS..."

    for group in "${TLE_GROUPS[@]}"; do
        staged="$STAGING/group-$group.tle"

        echo "       GROUP=$group"
        if ! fetch "$BASE_URL?GROUP=$group&FORMAT=tle" "$staged"; then
            echo "         FETCH FAILED"
            FAILURES=$((FAILURES + 1))
            continue
        fi

        if ! validate_tle "$staged" "$group"; then
            FAILURES=$((FAILURES + 1))
            continue
        fi

        if [ "$DRY_RUN" -eq 0 ]; then
            mkdir -p "$GROUP_DIR"
            tr -d '\r' < "$staged" > "$GROUP_DIR/$group.tle"
            echo "         installed $GROUP_DIR/$group.tle"
        fi

        sleep 1
    done
fi

# --- Result ---

echo ""
echo "============================================"
if [ "$FAILURES" -eq 0 ]; then
    echo "  TLE UPDATE OK"
    echo "============================================"
    echo ""
    echo "  predict:  $PREDICT_TLE"
    echo "  groups:   $GROUP_DIR/"
    echo ""
    echo "  Check it took:  predict -p 'NOAA 19'"
    echo "  The epoch in the elements should be within a day or two of now."
    exit 0
fi

echo "  TLE UPDATE FINISHED WITH $FAILURES FAILURE(S)"
echo "============================================"
echo ""
echo "  Whatever validated was installed; whatever did not was left alone, so"
echo "  nothing was overwritten with a bad download. A rejected source is far"
echo "  more likely to be a renamed CelesTrak group than a network problem —"
echo "  check the query by hand before changing this script:"
echo ""
echo "    curl -s '$BASE_URL?GROUP=weather&FORMAT=tle' | head -3"
echo ""
exit 1
