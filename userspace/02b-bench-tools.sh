#!/usr/bin/env bash
# ============================================================================
# KosmOS Post-Install 02b — RT Benchmark Tooling
# ============================================================================
# Run this ON THE PI. Installs the two packages the kernel latency benchmark
# needs, behind a prompt, and prints nothing else.
#
# Deliberately separate from, and ordered before, the SDR userspace install.
# Test 1 of the RT benchmark (cyclictest under load) needs no SDR hardware and
# no SDR tools, and it runs before the SATCOM stack is built. Bundling these
# into the SDR dependency list would mean you could not benchmark the kernel
# without first installing a toolchain you do not need yet.
#
#   rt-tests  → cyclictest, the standard RT wakeup-latency benchmark
#   stress-ng → generates the CPU and IO load the benchmark measures under
#
# Both come from the Pi OS archive rather than source, so there is nothing to
# pin here beyond the distribution's own versioning.
# ============================================================================

set -euo pipefail

echo "============================================"
echo "  RT Benchmark Tooling"
echo "============================================"
echo ""
read -r -p "Install RT benchmark tools (rt-tests, stress-ng)? (y/N): " INSTALL_BENCH
case "${INSTALL_BENCH,,}" in
    y|yes)
        sudo apt-get update
        sudo apt-get install -y rt-tests stress-ng
        echo ""
        echo "       Installed. Verify on each kernel with:"
        echo "         sudo cyclictest --version"
        echo "         stress-ng --version"
        echo ""
        echo "       Baseline run (idle, 1M iterations, RT priority):"
        echo "         sudo cyclictest -l1000000 -m -S -p90 -i200 -h400 -q"
        echo ""
        echo "       The figure that matters is Max latency under load, not Avg."
        echo "       Run the same command on the stock kernel and compare."
        ;;
    *)
        echo "       Skipped. Install later with: sudo apt install rt-tests stress-ng"
        ;;
esac
echo ""
