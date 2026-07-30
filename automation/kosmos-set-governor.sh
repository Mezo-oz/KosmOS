#!/usr/bin/env bash
# ============================================================================
# KosmOS — set the CPU scaling governor on every core
# ============================================================================
# Installed as /usr/local/sbin/kosmos-set-governor by install-governor.sh, and
# called by kosmos-governor.service at boot. Also usable by hand:
#
#   sudo kosmos-set-governor performance
#   sudo kosmos-set-governor ondemand      # to put it back for a comparison
#
# Exits non-zero if the requested governor could not be set on any core, so the
# systemd unit fails visibly instead of reporting success while the CPU is still
# ramping.
# ============================================================================

set -euo pipefail

WANT="${1:-performance}"

GOV_GLOB=(/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor)
AVAIL_FILE="/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors"

if [ ! -e "${GOV_GLOB[0]}" ]; then
    echo "kosmos-set-governor: no cpufreq interface on this system" >&2
    exit 1
fi

# Writing an unsupported name gives a bare EINVAL from the sysfs write, which is
# an unhelpful way to find out the governor is not compiled in.
if [ -r "$AVAIL_FILE" ] && ! grep -qw -- "$WANT" "$AVAIL_FILE"; then
    echo "kosmos-set-governor: '$WANT' is not an available governor" >&2
    echo "  available: $(cat "$AVAIL_FILE")" >&2
    exit 1
fi

written=0
for path in "${GOV_GLOB[@]}"; do
    [ -e "$path" ] || continue
    if echo "$WANT" > "$path" 2>/dev/null; then
        written=$((written + 1))
    else
        echo "kosmos-set-governor: could not write $path" >&2
    fi
done

if [ "$written" -eq 0 ]; then
    echo "kosmos-set-governor: failed to set '$WANT' on any core" >&2
    exit 1
fi

# Read back rather than trusting the write. A governor can be accepted by sysfs
# and then overridden by a driver or a thermal policy, and a unit that reports
# success in that case is worse than one that reports nothing.
actual=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)
if [ "$actual" != "$WANT" ]; then
    echo "kosmos-set-governor: wrote '$WANT' but cpu0 reads '$actual'" >&2
    exit 1
fi

echo "kosmos-set-governor: '$WANT' set on $written core(s)"
