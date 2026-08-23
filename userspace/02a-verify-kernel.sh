#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# KosmOS Post-Install 02a — Kernel Verification
# ============================================================================
# Run this ON THE PI after rebooting into the custom kernel.
#
# Read-only. It installs nothing, changes nothing, and prompts for nothing, so
# it is safe to run on any kernel, as often as you like — including on the stock
# kernel, where a "may still be stock kernel" result is the correct answer
# rather than a problem.
#
# The only privileged thing it does is `sudo modprobe ax25`, to answer whether
# the AX.25 stack is present, and it unloads the module again immediately.
#
# Failed checks are informational and never fatal: this script exits 0 whatever
# it finds, because the caller (02-post-install.sh) has more to do afterwards
# and because a failing check is usually a fact about the kernel you booted,
# not an error in the run.
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "============================================"
echo "  KosmOS Post-Install Verification"
echo "============================================"
echo ""

PASS=0
FAIL=0

# --- Kernel Version ---
KVER=$(uname -r)
echo -n "Kernel version:       $KVER "
# Match "kosmos" only. The old pattern also accepted "rt" or "6.12", which a
# stock Raspberry Pi OS 6.12 kernel satisfies -- so this check reported [OK]
# whether or not the custom kernel was actually running. CONFIG_LOCALVERSION
# in sdr-rt.config is what puts "kosmos" in the version string.
if echo "$KVER" | grep -qi "kosmos"; then
    echo -e "${GREEN}[OK]${NC}"
    # BUG FIX: ((PASS++)) exits with code 1 when PASS=0 under set -e,
    # because bash treats ((0)) as a failure. Using arithmetic assignment
    # instead avoids this. Same trap as a C-style for loop returning
    # the value of the expression — 0 is "false" in bash arithmetic.
    PASS=$((PASS + 1))
else
    echo -e "${YELLOW}[CHECK - may still be stock kernel]${NC}"
    FAIL=$((FAIL + 1))
fi

# --- Real-Time ---
#
# Do NOT rely on /sys/kernel/realtime alone. That file came from the out-of-tree
# PREEMPT_RT patchset; since RT was merged into mainline in 6.12 it is not
# created, so a genuinely RT mainline kernel has no such file. Checking only for
# it reports NOT DETECTED on exactly the kernel this project builds -- confirmed
# on hardware 2026-07-29, where uname -v read "SMP PREEMPT_RT" while the file was
# absent.
#
# Authoritative sources, best first:
#   1. /proc/config.gz  — what was actually compiled (needs CONFIG_IKCONFIG_PROC)
#   2. uname -v         — the build banner carries "PREEMPT_RT"
#   3. /sys/kernel/realtime — legacy patchset only; kept for older kernels
echo -n "RT scheduling:        "
RT_EVIDENCE=""
# Process substitution, not `zcat | grep -qx`. Under the `set -o pipefail` at
# the top of this script, grep -q exits on its first match while zcat still has
# ~242 KB to write, zcat dies of SIGPIPE, and the pipeline reports failure even
# though the match succeeded -- so source 1 was unreachable and this check has
# been silently answering from source 2 since it was written. Measured on
# pi-server 2026-08-23. It never produced a wrong answer there, because the
# uname -v banner agrees, but a kernel built without IKCONFIG_PROC in its banner
# would have been reported NOT DETECTED while /proc/config.gz said otherwise.
if [ -f /proc/config.gz ] &&
    grep -qx "CONFIG_PREEMPT_RT=y" <(zcat /proc/config.gz 2>/dev/null); then
    RT_EVIDENCE="CONFIG_PREEMPT_RT=y in /proc/config.gz"
elif uname -v | grep -q "PREEMPT_RT"; then
    RT_EVIDENCE="PREEMPT_RT in uname -v"
elif [ -f /sys/kernel/realtime ] && [ "$(cat /sys/kernel/realtime)" = "1" ]; then
    RT_EVIDENCE="/sys/kernel/realtime=1 (legacy patchset)"
fi

if [ -n "$RT_EVIDENCE" ]; then
    echo -e "${GREEN}ENABLED [OK]${NC} — $RT_EVIDENCE"
    PASS=$((PASS + 1))
else
    echo -e "${RED}NOT DETECTED [FAIL]${NC}"
    echo "  → CONFIG_PREEMPT_RT may not have been set."
    echo "    Checked: /proc/config.gz, uname -v, /sys/kernel/realtime"
    FAIL=$((FAIL + 1))
fi

# --- Timer Frequency ---
echo -n "Timer frequency:      "
# /proc/config.gz is gzip, so it must be decompressed -- the previous first
# attempt grepped the compressed bytes directly, which can never match. Requires
# CONFIG_IKCONFIG_PROC, now set in sdr-rt.config.
if [ -f /proc/config.gz ]; then
    HZ=$(zcat /proc/config.gz 2>/dev/null | grep "^CONFIG_HZ=" | head -1 || echo "unknown")
else
    HZ="unavailable (no /proc/config.gz)"
fi
if echo "$HZ" | grep -q "1000"; then
    echo -e "1000 Hz ${GREEN}[OK]${NC}"
    PASS=$((PASS + 1))
else
    echo -e "$HZ ${YELLOW}[CHECK]${NC}"
fi

# --- CPU Governor ---
echo -n "CPU governor:         "
GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
if [ "$GOV" = "performance" ]; then
    echo -e "performance ${GREEN}[OK]${NC}"
    PASS=$((PASS + 1))
else
    echo -e "$GOV ${YELLOW}[NOT performance]${NC}"
    echo "  → CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE only sets the kernel's"
    echo "    *default*. Raspberry Pi OS / Debian override it at boot, so the"
    echo "    running governor is whatever userspace last wrote -- observed as"
    echo "    'ondemand' on hardware 2026-07-29 despite the kernel default."
    echo "    The kernel config alone does NOT deliver 'always max clock'."
    echo ""
    echo "  → For this session only:"
    echo "      echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor"
    echo "  → To persist it, install the boot-time unit; a kernel rebuild will"
    echo "    not help:"
    echo "      sudo bash automation/install-governor.sh"
    echo ""
    echo "    BENCHMARK NOTE: ondemand adds frequency-ramp latency on top of"
    echo "    scheduling latency. It is applied to both kernels so the A/B stays"
    echo "    fair, but pin it to performance on both before publishing numbers,"
    echo "    or state plainly that the figures include ramp effects."
fi

# --- USB Subsystem ---
echo -n "USB subsystem:        "
if lsusb &>/dev/null; then
    echo -e "${GREEN}[OK]${NC}"
    PASS=$((PASS + 1))
else
    echo -e "${RED}[FAIL - lsusb not working]${NC}"
    FAIL=$((FAIL + 1))
fi

# --- AX.25 Module ---
echo -n "AX.25 module:         "
# Needs sudo: loading a module is privileged, and the rest of this script runs
# unprivileged. Without sudo this always failed and reported "may need to
# rebuild" on kernels where AX.25 was present and fine -- a false negative on
# one of the features the project advertises.
if sudo modprobe ax25 2>/dev/null; then
    echo -e "${GREEN}[OK - loaded]${NC}"
    PASS=$((PASS + 1))
    # Clean up — unload it for now
    sudo rmmod ax25 2>/dev/null || true
else
    echo -e "${YELLOW}[not available - may need to rebuild]${NC}"
fi

# --- Kernel Config Available ---
echo -n "/proc/config.gz:      "
if [ -f /proc/config.gz ]; then
    echo -e "${GREEN}[OK]${NC}"
    PASS=$((PASS + 1))
else
    echo -e "${YELLOW}[not available]${NC}"
    echo "  → Enable CONFIG_IKCONFIG and CONFIG_IKCONFIG_PROC in your kernel"
fi

# --- Russian Locale ---
echo -n "Russian locale:       "
CURRENT_LANG=$(locale 2>/dev/null | grep "^LANG=" | cut -d= -f2)
if echo "$CURRENT_LANG" | grep -qi "ru_RU"; then
    echo -e "${GREEN}$CURRENT_LANG [OK]${NC}"
    PASS=$((PASS + 1))
else
    echo -e "${YELLOW}not set (will configure during install)${NC}"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo -e "${YELLOW}Some checks failed. Review the messages above.${NC}"
    echo "Your stock kernel is still available as a fallback."
    echo ""
fi

# Always successful: what this script reports is the state of the kernel you
# booted, and the caller has work to do regardless of what it found.
exit 0
