#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — install the performance-governor unit
# ============================================================================
# Run this ON THE PI as root:
#
#   sudo bash automation/install-governor.sh
#   sudo bash automation/install-governor.sh --uninstall
#
# WHAT IT CHANGES, exhaustively:
#   installs  /usr/local/sbin/molniya-set-governor
#   installs  /etc/systemd/system/molniya-governor.service
#   enables   molniya-governor.service
#   masks     ondemand.service, only if that unit exists
#
# Nothing else. --uninstall reverses all four, including unmasking
# ondemand.service, so the box goes back to exactly the behaviour it had.
#
# WHY MASKING ondemand.service IS PART OF THIS:
#   Debian ships a unit whose whole job is to set the ondemand governor after
#   boot. Where it is present, it is what puts the CPU back on ondemand after the
#   kernel's own default said performance, and simply ordering our unit later is
#   a race, not a fix. Masking is reversible and affects nothing else — the unit
#   sets a governor and does no other work.
#
# BENCHMARK NOTE: with this installed, both kernels run at a pinned clock, which
# is what makes the A/B fair. Reverting to ondemand for a comparison is
# `sudo molniya-set-governor ondemand` for the session, or --uninstall to persist.
# ============================================================================

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HELPER_SRC="$SELF_DIR/molniya-set-governor.sh"
HELPER_DST="/usr/local/sbin/molniya-set-governor"
UNIT_SRC="$SELF_DIR/molniya-governor.service"
UNIT_DST="/etc/systemd/system/molniya-governor.service"
UNIT_NAME="molniya-governor.service"
CONFLICTING_UNIT="ondemand.service"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run this as root: sudo bash $0" >&2
    exit 1
fi

if ! command -v systemctl > /dev/null 2>&1; then
    echo "ERROR: no systemctl — this installs a systemd unit." >&2
    exit 1
fi

read_governor() {
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null \
        || echo unknown
}

uninstall() {
    echo "Removing the MolniyaOS governor unit..."

    if systemctl list-unit-files "$UNIT_NAME" > /dev/null 2>&1; then
        systemctl disable --now "$UNIT_NAME" 2>/dev/null || true
    fi
    rm -f "$UNIT_DST" "$HELPER_DST"
    systemctl daemon-reload

    # Only unmask what we would have masked. Unmasking a unit the user masked
    # themselves for their own reasons would be a surprise.
    if systemctl is-enabled "$CONFLICTING_UNIT" 2>/dev/null | grep -q masked; then
        echo "  unmasking $CONFLICTING_UNIT"
        systemctl unmask "$CONFLICTING_UNIT" || true
    fi

    echo ""
    echo "  Done. Governor now: $(read_governor)"
    echo "  It stays where it is until the next boot, when whatever set it"
    echo "  before takes over again."
    exit 0
}

if [ "${1:-}" = "--uninstall" ]; then
    uninstall
fi

if [ "${1:-}" != "" ]; then
    echo "usage: $0 [--uninstall]" >&2
    exit 1
fi

for f in "$HELPER_SRC" "$UNIT_SRC"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: missing $f" >&2
        echo "       Run this from a clone of the repo; it installs the two" >&2
        echo "       files that sit beside it." >&2
        exit 1
    fi
done

echo "============================================"
echo "  MolniyaOS Performance Governor"
echo "============================================"
echo ""
echo "  Governor before: $(read_governor)"
echo ""

echo "[1/4] Installing $HELPER_DST"
install -m 0755 -o root -g root "$HELPER_SRC" "$HELPER_DST"

echo "[2/4] Installing $UNIT_DST"
install -m 0644 -o root -g root "$UNIT_SRC" "$UNIT_DST"

echo "[3/4] Handling $CONFLICTING_UNIT"
if systemctl list-unit-files "$CONFLICTING_UNIT" > /dev/null 2>&1 \
    && systemctl list-unit-files "$CONFLICTING_UNIT" | grep -q "$CONFLICTING_UNIT"; then
    echo "       found — masking it (reversible: systemctl unmask $CONFLICTING_UNIT)"
    systemctl mask "$CONFLICTING_UNIT"
else
    echo "       not present on this system — nothing to do"
fi

echo "[4/4] Enabling $UNIT_NAME"
systemctl daemon-reload
systemctl enable --now "$UNIT_NAME"

echo ""
GOV_NOW=$(read_governor)
echo "  Governor now: $GOV_NOW"
echo ""

if [ "$GOV_NOW" = "performance" ]; then
    echo "  Installed. Verify it survives a reboot before trusting it for a"
    echo "  benchmark run — that is the whole point of the unit, and the boot"
    echo "  path is the part that could not be tested here:"
    echo ""
    echo "    sudo reboot"
    echo "    systemctl status $UNIT_NAME"
    echo "    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
else
    echo "  WARNING: the governor is '$GOV_NOW', not performance."
    echo ""
    echo "  Something else is setting it. Look for the culprit with:"
    echo "    systemctl status $UNIT_NAME"
    echo "    grep -rl scaling_governor /etc/systemd /etc/init.d /etc/rc.local 2>/dev/null"
    echo "    grep -r GOVERNOR /etc/default 2>/dev/null"
    echo ""
    echo "  Until it reads 'performance' on both kernels, any benchmark number"
    echo "  includes frequency-ramp latency and has to be labelled as such."
fi

echo ""
echo "  To remove: sudo bash $0 --uninstall"
