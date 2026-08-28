#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — install the TLE refresh timer
# ============================================================================
# Run this ON THE PI as root:
#
#   sudo bash automation/install-tle-timer.sh
#   sudo bash automation/install-tle-timer.sh --user homelab
#   sudo bash automation/install-tle-timer.sh --no-run
#   sudo bash automation/install-tle-timer.sh --uninstall
#
# WHAT IT CHANGES, exhaustively:
#   installs  /usr/local/bin/molniya-tle-update           (tle-updater.sh)
#   installs  /etc/systemd/system/molniya-tle-update@.service
#   installs  /etc/systemd/system/molniya-tle-update@.timer
#   enables   molniya-tle-update@<user>.timer
#   runs      one update immediately, unless --no-run
#
# Nothing else. --uninstall reverses all of it.
#
# WHICH USER, AND WHY IT IS NOT ROOT:
#   The updater writes ~/.predict/predict.tle and ~/.config/satellite-tle/.
#   Installed as root, it would faithfully maintain elements in /root, where
#   predict — run by a human — would never look at them, and the failure is
#   silent: predict answers from its shipped elements with no indication they
#   are years old. So the timer is enabled on a template instance named for the
#   account that will actually run predict. Default is $SUDO_USER, i.e. whoever
#   typed sudo. --user overrides it.
#
# WHY IT RUNS ONE UPDATE AT INSTALL TIME:
#   Enabling a timer starts the timer, not the service, so without this the
#   first evidence the unit works at all would arrive up to twelve hours later
#   — and a ground station that discovers its element source is broken during a
#   pass has discovered it too late. --no-run skips it for an offline install.
# ============================================================================

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCRIPT_SRC="$SELF_DIR/tle-updater.sh"
SCRIPT_DST="/usr/local/bin/molniya-tle-update"
SERVICE_SRC="$SELF_DIR/molniya-tle-update@.service"
SERVICE_DST="/etc/systemd/system/molniya-tle-update@.service"
TIMER_SRC="$SELF_DIR/molniya-tle-update@.timer"
TIMER_DST="/etc/systemd/system/molniya-tle-update@.timer"
UNIT_BASE="molniya-tle-update"

TARGET_USER=""
RUN_NOW=1
UNINSTALL=0

# --- Arguments --------------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        --user)
            if [ $# -lt 2 ]; then
                echo "ERROR: --user needs a username" >&2
                exit 1
            fi
            TARGET_USER="$2"
            shift 2
            ;;
        --no-run)    RUN_NOW=0;    shift ;;
        --uninstall) UNINSTALL=1;  shift ;;
        -h|--help)
            echo "usage: $0 [--user NAME] [--no-run] [--uninstall]"
            exit 0
            ;;
        *)
            echo "usage: $0 [--user NAME] [--no-run] [--uninstall]" >&2
            exit 1
            ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run this as root: sudo bash $0" >&2
    exit 1
fi

if ! command -v systemctl > /dev/null 2>&1; then
    echo "ERROR: no systemctl — this installs systemd units." >&2
    echo "       Without systemd, use the cron line in tle-updater.sh's header." >&2
    exit 1
fi

# --- Resolving the account the elements belong to ---------------------------

# Deliberately refuses to guess. Installing this for the wrong user produces a
# timer that runs, succeeds, and maintains elements nobody reads — the one
# outcome that looks like success and is not.
resolve_user() {
    if [ -z "$TARGET_USER" ]; then
        TARGET_USER="${SUDO_USER:-}"
    fi

    if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
        echo "ERROR: no target user." >&2
        echo "       \$SUDO_USER is unset or root, which means this was run from" >&2
        echo "       a root shell rather than through sudo. Name the account that" >&2
        echo "       runs predict:" >&2
        echo "" >&2
        echo "         sudo bash $0 --user <name>" >&2
        exit 1
    fi

    if ! id -u "$TARGET_USER" > /dev/null 2>&1; then
        echo "ERROR: no such user: $TARGET_USER" >&2
        exit 1
    fi
}

# systemd derives $HOME from the account database, so this is a report on where
# the elements will land, not a value passed to anything.
report_home() {
    local home
    home="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

    if [ -z "$home" ] || [ ! -d "$home" ]; then
        echo "  WARNING: $TARGET_USER has no home directory at '${home:-none}'."
        echo "           The updater writes under \$HOME; it will fail until that"
        echo "           directory exists."
        return 0
    fi

    echo "  Elements will land in:"
    echo "    $home/.predict/predict.tle"
    echo "    $home/.config/satellite-tle/"
}

# --- Uninstall --------------------------------------------------------------

# Every instance, not just the one this invocation would have picked: the point
# of an uninstall is that nothing is left running afterwards, and an earlier
# install may have used a different account.
#
# Enabled instances are read from the wants directory rather than from
# `systemctl list-units`, which only reports units currently loaded — an enabled
# timer on a boot where it has not fired yet can be absent from that listing,
# and the symlink is what `enable` actually created.
uninstall() {
    local link instance
    echo "Removing the MolniyaOS TLE timer..."

    for link in "/etc/systemd/system/timers.target.wants/${UNIT_BASE}@"*.timer; do
        [ -e "$link" ] || continue
        instance="$(basename "$link")"
        echo "  disabling $instance"
        systemctl disable --now "$instance" 2>/dev/null || true
    done

    rm -f "$TIMER_DST" "$SERVICE_DST" "$SCRIPT_DST"
    systemctl daemon-reload

    echo ""
    echo "  Done. The elements already downloaded are left alone — they are"
    echo "  data, not part of the install. Remove them by hand if you want them"
    echo "  gone: ~/.predict/ and ~/.config/satellite-tle/"
    exit 0
}

if [ "$UNINSTALL" -eq 1 ]; then
    uninstall
fi

# --- Install ----------------------------------------------------------------

resolve_user
TIMER_INSTANCE="${UNIT_BASE}@${TARGET_USER}.timer"
SERVICE_INSTANCE="${UNIT_BASE}@${TARGET_USER}.service"

for f in "$SCRIPT_SRC" "$SERVICE_SRC" "$TIMER_SRC"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: missing $f" >&2
        echo "       Run this from a clone of the repo; it installs the three" >&2
        echo "       files that sit beside it." >&2
        exit 1
    fi
done

if ! command -v curl > /dev/null 2>&1 && ! command -v wget > /dev/null 2>&1; then
    echo "ERROR: neither curl nor wget is installed — the updater needs one." >&2
    echo "       sudo apt-get install -y curl" >&2
    exit 1
fi

echo "============================================"
echo "  MolniyaOS TLE Refresh Timer"
echo "============================================"
echo ""
echo "  Target user: $TARGET_USER"
report_home
echo ""

echo "[1/4] Installing $SCRIPT_DST"
install -m 0755 -o root -g root "$SCRIPT_SRC" "$SCRIPT_DST"

echo "[2/4] Installing the units"
install -m 0644 -o root -g root "$SERVICE_SRC" "$SERVICE_DST"
install -m 0644 -o root -g root "$TIMER_SRC" "$TIMER_DST"

echo "[3/4] Enabling $TIMER_INSTANCE"
systemctl daemon-reload
systemctl enable --now "$TIMER_INSTANCE"

echo "[4/4] First update"
if [ "$RUN_NOW" -eq 0 ]; then
    echo "       skipped (--no-run). Nothing has proven the unit works yet;"
    echo "       run it by hand when the box is online:"
    echo "         sudo systemctl start $SERVICE_INSTANCE"
    FIRST_RUN_OK=-1
elif systemctl start "$SERVICE_INSTANCE"; then
    echo "       OK — elements fetched and validated."
    FIRST_RUN_OK=1
else
    echo "       FAILED."
    FIRST_RUN_OK=0
fi

echo ""
echo "  Schedule:"
systemctl list-timers --no-pager --no-legend "$TIMER_INSTANCE" || true
echo ""

if [ "$FIRST_RUN_OK" -eq 0 ]; then
    echo "  The timer is installed and will keep trying on schedule, but the"
    echo "  first run did not succeed. Nothing stale was overwritten — the"
    echo "  updater installs only what it can validate. Read why:"
    echo ""
    echo "    journalctl -u $SERVICE_INSTANCE -n 40 --no-pager"
    echo ""
    echo "  A rejected source is far more often a renamed CelesTrak group than"
    echo "  a network fault. See tle-updater.sh's header for the two group names"
    echo "  that were already found to be wrong."
else
    echo "  Installed. A failed refresh shows up as a failed unit, so this is"
    echo "  the honest answer to 'are my elements current':"
    echo ""
    echo "    systemctl status $SERVICE_INSTANCE"
    echo "    predict -p 'NOAA 19'"
    echo ""
    echo "  The epoch in the elements should be within a day or two of now."
fi

echo ""
echo "  To remove: sudo bash $0 --uninstall"
