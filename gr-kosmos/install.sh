#!/usr/bin/env bash
# ============================================================================
# gr-kosmos — install for development use
# ============================================================================
# Run this ON THE PI, after userspace/03a-gnuradio-stack.sh:
#
#   ./gr-kosmos/install.sh
#   ./gr-kosmos/install.sh --uninstall
#
# WHAT IT CHANGES, exhaustively:
#   writes  <python user site>/gr-kosmos.pth        makes `import kosmos` work
#   copies  <gnuradio prefix>/share/gnuradio/grc/blocks/kosmos_*.block.yml
#
# The .pth file points at this directory rather than copying the package, so
# editing python/kosmos/*.py takes effect on the next flowgraph run with no
# reinstall step. That is the whole reason this is not a package install: the
# block is being developed, not shipped.
#
# The GRC definition has to be copied rather than linked from, because GRC scans
# fixed directories. Re-run this after changing the .block.yml.
#
# WHY NOT `gr_modtool`: see README.md. Short version — a full OOT module's build
# system is generated, not written, and hand-writing several hundred lines of
# version-specific CMake that nobody has ever run would be worse than not
# shipping it.
# ============================================================================

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PTH_NAME="gr-kosmos.pth"
PACKAGE_DIR="$SELF_DIR/python"
GRC_SRC_DIR="$SELF_DIR/grc"

# --- Where things go --------------------------------------------------------

# The user site directory, which Python adds to sys.path automatically and which
# needs no root. site.getusersitepackages() is the documented way to ask.
user_site() {
    python3 -c 'import site; print(site.getusersitepackages())'
}

# GNU Radio's own prefix, asked of GNU Radio rather than guessed. The GRC blocks
# directory under it is where installed OOT modules put their .block.yml, so it
# is a path GRC already scans.
grc_blocks_dir() {
    local prefix
    prefix=$(gnuradio-config-info --prefix 2>/dev/null || true)
    if [ -z "$prefix" ]; then
        return 1
    fi
    printf '%s/share/gnuradio/grc/blocks\n' "$prefix"
}

# --- Uninstall --------------------------------------------------------------

uninstall() {
    local site pth blocks removed=0

    site=$(user_site)
    pth="$site/$PTH_NAME"
    if [ -f "$pth" ]; then
        rm -f "$pth"
        echo "  removed $pth"
        removed=$((removed + 1))
    fi

    if blocks=$(grc_blocks_dir); then
        local f target
        for f in "$GRC_SRC_DIR"/*.block.yml; do
            [ -e "$f" ] || continue
            target="$blocks/$(basename "$f")"
            if [ -f "$target" ]; then
                sudo rm -f "$target"
                echo "  removed $target"
                removed=$((removed + 1))
            fi
        done
    fi

    echo ""
    if [ "$removed" -eq 0 ]; then
        echo "  Nothing was installed."
    else
        echo "  Done. Restart GRC to drop the blocks from its palette."
    fi
    exit 0
}

if [ "${1:-}" = "--uninstall" ]; then
    uninstall
fi

if [ "${1:-}" != "" ]; then
    echo "usage: $0 [--uninstall]" >&2
    exit 1
fi

# --- Preconditions ----------------------------------------------------------

if ! command -v python3 > /dev/null 2>&1; then
    echo "ERROR: python3 is not installed." >&2
    exit 1
fi

if ! python3 -c 'import gnuradio' > /dev/null 2>&1; then
    echo "ERROR: the gnuradio Python module is not importable." >&2
    echo "       Run userspace/03a-gnuradio-stack.sh first. Without GNU Radio" >&2
    echo "       this block has nothing to load into." >&2
    exit 1
fi

echo "============================================"
echo "  gr-kosmos (development install)"
echo "============================================"
echo ""

# --- 1. Python path --------------------------------------------------------

SITE_DIR=$(user_site)
mkdir -p "$SITE_DIR"
printf '%s\n' "$PACKAGE_DIR" > "$SITE_DIR/$PTH_NAME"
echo "[1/3] $SITE_DIR/$PTH_NAME -> $PACKAGE_DIR"

# --- 2. GRC block definitions ----------------------------------------------

if BLOCKS_DIR=$(grc_blocks_dir); then
    sudo mkdir -p "$BLOCKS_DIR"
    for src in "$GRC_SRC_DIR"/*.block.yml; do
        [ -e "$src" ] || continue
        sudo install -m 0644 "$src" "$BLOCKS_DIR/"
        echo "[2/3] $BLOCKS_DIR/$(basename "$src")"
    done
else
    echo "[2/3] SKIPPED — gnuradio-config-info did not report a prefix."
    echo "      The Python side is installed and usable from a script; only the"
    echo "      GRC palette entry is missing. To place it by hand, find the path"
    echo "      GRC scans and copy grc/*.block.yml there:"
    echo "        gnuradio-config-info --prefix"
    echo "      or set local_blocks_path under [grc] in ~/.gnuradio/config.conf"
fi

# --- 3. Verify -------------------------------------------------------------

echo "[3/3] Verifying the import..."
if python3 -c 'import kosmos; print("      kosmos", kosmos.__file__)'; then
    echo ""
    echo "  Installed."
    echo ""
    echo "  The block is a SKELETON: it passes samples through and detects"
    echo "  nothing. It is safe to put in a flowgraph and it will not tell you"
    echo "  anything yet."
    echo ""
    echo "  Restart GRC to see it under the KosmOS category."
    echo "  To remove: $0 --uninstall"
else
    echo ""
    echo "ERROR: 'import kosmos' still fails." >&2
    echo "       The .pth file was written to the user site directory, which" >&2
    echo "       python3 only reads if user site is enabled. Check with:" >&2
    echo "         python3 -c 'import site; print(site.ENABLE_USER_SITE)'" >&2
    echo "       If that prints False, set PYTHONPATH=$PACKAGE_DIR instead." >&2
    exit 1
fi
