#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — rtl_power CSV to spectrum heatmap
# ============================================================================
# Turns an rtl_power sweep into a picture of what the band was doing.
#
#   rtl_power -f 137M:138M:2k -i 10 -e 1h scan.csv
#   ./automation/rtl-power-heatmap.py scan.csv -o scan.png
#   ./automation/rtl-power-heatmap.py scan.csv --summary      # no plot, no deps
#
# WHAT rtl_power ACTUALLY WRITES, because the format has two traps in it:
#
#   date, time, Hz low, Hz high, Hz step, samples, dB, dB, dB, ...
#
#   Trap 1 — a row is a *chunk*, not a sweep. A range wider than the dongle's
#   bandwidth is split across several rows, and only the whole set of them is
#   one line of the waterfall. Anything that plots one row per output line gets
#   a picture of the chunking pattern rather than of the band.
#
#   Trap 2 — chunk timestamps are not reliably identical within a sweep, so
#   grouping by timestamp can split one sweep in two. Sweeps are detected here
#   by frequency wrap-around instead: a row whose low frequency did not advance
#   is the start of the next pass. That holds whatever the clock did.
#
# COLOR IS A SEQUENTIAL RAMP, AND DELIBERATELY NOT A RAINBOW. The convention in
# SDR software is `jet`, which is the single most criticised colormap in
# scientific visualisation: its lightness is not monotonic, so it invents banded
# "features" at the cyan and yellow turns that are not in the data, and it is
# close to unreadable with red-green color vision deficiency. The default here
# is viridis — lightness increases monotonically with power, so a brighter pixel
# is a stronger signal with no exceptions, and it survives CVD and greyscale
# printing. --cmap overrides it for anyone who wants the old look.
#
# THE dB FIGURES ARE UNCALIBRATED, and the axis label says so. An RTL-SDR has no
# absolute power reference; the numbers are meaningful compared with each other
# in one capture and meaningless as dBm. Reading them as dBm is how people end
# up reporting a signal strength that is off by tens of dB.
#
# --summary needs nothing but the standard library, on purpose: on a headless
# box the first question is whether the capture is any good, and that should not
# require matplotlib to be installed. The plot path imports numpy and matplotlib
# lazily so that stays true.
#
#   sudo apt-get install -y python3-numpy python3-matplotlib
# ============================================================================

import argparse
import math
import os
import sys
from collections import namedtuple

# One row of the CSV: a contiguous block of bins measured at one instant.
Chunk = namedtuple("Chunk", "stamp f_low f_high f_step samples values")

# Bins whose width disagrees by less than this fraction are treated as the same
# step. rtl_power derives the step from an FFT size and the numbers do not
# always divide evenly, so an exact comparison rejects valid captures.
STEP_TOLERANCE = 1e-6

# Percentiles the color scale clips to when no explicit range is given. A single
# strong carrier otherwise sets vmax on its own and flattens everything else
# into the floor of the ramp.
CLIP_LOW_PCT = 1.0
CLIP_HIGH_PCT = 99.0

# Above this many sweeps the y-axis gets thinned to this many labels rather than
# one per sweep. Bounded so a 12-hour capture cannot try to draw 4000 of them.
MAX_TIME_LABELS = 12

# Bins nothing was written to. A neutral grey rather than matplotlib's default
# white: white is a colour the eye reads as a value, and on a viridis ramp it
# sits just past the bright end, so a coverage gap looks like the strongest
# signal in the capture. Grey belongs to no ramp and reads as absence.
NO_DATA_COLOR = "#d9d9d9"


class ScanError(Exception):
    """A capture that cannot be plotted, with a reason a human can act on."""


def parse_row(fields, lineno):
    """One CSV row to a Chunk. Raises ScanError on anything structural."""
    if len(fields) < 7:
        raise ScanError(
            f"line {lineno}: {len(fields)} fields, need at least 7 "
            "(date, time, low, high, step, samples, and one dB value)"
        )

    stamp = f"{fields[0].strip()} {fields[1].strip()}"
    try:
        f_low = float(fields[2])
        f_high = float(fields[3])
        f_step = float(fields[4])
        samples = int(float(fields[5]))
    except ValueError as exc:
        raise ScanError(f"line {lineno}: unparseable header field: {exc}") from exc

    if f_step <= 0 or f_high <= f_low:
        raise ScanError(
            f"line {lineno}: nonsensical range {f_low}-{f_high} step {f_step}"
        )

    values = [to_db(v) for v in fields[6:] if v.strip() != ""]
    if not values:
        raise ScanError(f"line {lineno}: no dB values")

    return Chunk(stamp, f_low, f_high, f_step, samples, values)


def to_db(text):
    """A dB field as a float, with the non-finite spellings mapped to NaN.

    rtl_power emits -inf for a bin that integrated to zero power, and some
    builds emit platform-specific spellings of nan. All of them mean 'no
    reading', which is a gap in the picture rather than a very quiet bin --
    plotting -inf as a number drags the whole color scale to it.
    """
    try:
        value = float(text)
    except ValueError:
        return math.nan
    return value if math.isfinite(value) else math.nan


def read_scan(path):
    """Parse the file into chunks. Returns (chunks, skipped_line_count)."""
    chunks = []
    skipped = 0

    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for lineno, line in enumerate(handle, start=1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                chunks.append(parse_row(line.split(","), lineno))
            except ScanError as exc:
                skipped += 1
                if skipped <= 5:
                    print(f"  skipping {exc}", file=sys.stderr)

    if skipped > 5:
        print(f"  ... and {skipped - 5} more skipped rows", file=sys.stderr)
    if not chunks:
        raise ScanError(
            f"{path}: no usable rows. rtl_power writes one row per frequency "
            "chunk; an empty file usually means the capture never started."
        )
    return chunks, skipped


def split_sweeps(chunks):
    """Group chunks into sweeps on frequency wrap-around.

    A sweep ends where the low frequency stops advancing. See trap 2 in the
    header: this is why the grouping is not by timestamp.
    """
    sweeps = []
    current = []

    for chunk in chunks:
        if current and chunk.f_low <= current[-1].f_low:
            sweeps.append(current)
            current = []
        current.append(chunk)

    if current:
        sweeps.append(current)
    return sweeps


def scan_geometry(chunks):
    """The common (f_min, f_max, f_step, n_bins) grid every sweep lands on."""
    f_step = chunks[0].f_step
    for chunk in chunks:
        if abs(chunk.f_step - f_step) > f_step * STEP_TOLERANCE:
            raise ScanError(
                f"bin width changes mid-capture ({f_step} then {chunk.f_step}). "
                "That is two captures concatenated, not one; plot them separately."
            )

    f_min = min(c.f_low for c in chunks)
    f_max = max(c.f_high for c in chunks)
    n_bins = int(round((f_max - f_min) / f_step))
    if n_bins < 1:
        raise ScanError("the capture covers less than one bin")
    return f_min, f_max, f_step, n_bins


def build_grid(sweeps, f_min, f_step, n_bins):
    """Sweeps to a (n_sweeps x n_bins) float array, NaN where nothing landed."""
    import numpy as np

    grid = np.full((len(sweeps), n_bins), np.nan, dtype=float)

    for row, sweep in enumerate(sweeps):
        for chunk in sweep:
            start = int(round((chunk.f_low - f_min) / f_step))
            width = min(len(chunk.values), n_bins - start)
            if width > 0:
                grid[row, start:start + width] = chunk.values[:width]

    return grid


def summarise(sweeps, geometry, grid=None):
    """Print what the capture contains. The first question about any scan."""
    f_min, f_max, f_step, n_bins = geometry
    chunk_count = sum(len(s) for s in sweeps)

    print("")
    print(f"  sweeps          {len(sweeps)}")
    print(f"  chunks/sweep    {chunk_count / len(sweeps):.1f}")
    print(f"  range           {f_min / 1e6:.4f} - {f_max / 1e6:.4f} MHz")
    print(f"  bin width       {f_step:.1f} Hz  ({n_bins} bins)")
    print(f"  first sweep     {sweeps[0][0].stamp}")
    print(f"  last sweep      {sweeps[-1][0].stamp}")

    if grid is not None:
        import numpy as np

        filled = int(np.count_nonzero(~np.isnan(grid)))
        total = grid.size
        print(f"  coverage        {100.0 * filled / total:.1f}% of the grid")
        if filled:
            print(f"  power           {np.nanmin(grid):.1f} to "
                  f"{np.nanmax(grid):.1f} dB (uncalibrated)")
    print("")


def color_limits(grid, args):
    """The vmin/vmax the image is stretched between."""
    import numpy as np

    if not np.any(~np.isnan(grid)):
        raise ScanError("every bin is NaN — nothing to plot")

    vmin = args.vmin if args.vmin is not None \
        else float(np.nanpercentile(grid, CLIP_LOW_PCT))
    vmax = args.vmax if args.vmax is not None \
        else float(np.nanpercentile(grid, CLIP_HIGH_PCT))

    if vmax <= vmin:
        vmax = vmin + 1.0
    return vmin, vmax


def time_ticks(sweeps):
    """At most MAX_TIME_LABELS (position, label) pairs down the time axis."""
    count = len(sweeps)
    step = max(1, int(math.ceil(count / MAX_TIME_LABELS)))
    positions = list(range(0, count, step))
    # The stamp is "YYYY-MM-DD HH:MM:SS"; the clock time is the useful half.
    labels = [sweeps[i][0].stamp.split(" ")[-1] for i in positions]
    return positions, labels


def render(grid, sweeps, geometry, args):
    """Write the PNG. One sweep gets a spectrum plot; more gets a heatmap."""
    import matplotlib
    matplotlib.use("Agg")           # headless: no display, no Tk dependency
    import matplotlib.pyplot as plt
    import numpy as np

    f_min, f_max, _, _ = geometry
    vmin, vmax = color_limits(grid, args)
    freqs = np.linspace(f_min / 1e6, f_max / 1e6, grid.shape[1])

    fig, axes = plt.subplots(figsize=(args.width, args.height), dpi=args.dpi)

    if grid.shape[0] == 1:
        axes.plot(freqs, grid[0], linewidth=1.0, color="#3b6ea5")
        axes.set_ylabel("power (dB, uncalibrated)")
        # NOT the percentile clip the heatmap uses. Clipping a color scale hides
        # nothing -- the brightest pixel is still the brightest. Clipping a line
        # plot flattens the peaks against the top of the axes, and on a spectrum
        # the peaks are the entire content. Explicit --vmin/--vmax still win.
        axes.set_ylim(args.vmin if args.vmin is not None else None,
                      args.vmax if args.vmax is not None else None)
        axes.grid(True, linewidth=0.4, alpha=0.4)
        subtitle = f"single sweep at {sweeps[0][0].stamp}"
    else:
        colors = matplotlib.colormaps[args.cmap].with_extremes(bad=NO_DATA_COLOR)
        image = axes.imshow(
            grid, aspect="auto", origin="upper", cmap=colors,
            vmin=vmin, vmax=vmax, interpolation="nearest",
            extent=(freqs[0], freqs[-1], grid.shape[0], 0),
        )
        bar = fig.colorbar(image, ax=axes, pad=0.02)
        bar.set_label("power (dB, uncalibrated)")
        positions, labels = time_ticks(sweeps)
        axes.set_yticks([p + 0.5 for p in positions])
        axes.set_yticklabels(labels, fontsize=8)
        axes.set_ylabel("time")
        subtitle = (f"{grid.shape[0]} sweeps, "
                    f"{sweeps[0][0].stamp} to {sweeps[-1][0].stamp}")

    axes.set_xlabel("frequency (MHz)")
    axes.set_title(args.title or os.path.basename(args.csv), loc="left")
    axes.set_title(subtitle, loc="right", fontsize=8, color="#666666")
    for spine in ("top", "right"):
        axes.spines[spine].set_visible(False)

    fig.tight_layout()
    fig.savefig(args.output)
    plt.close(fig)
    return vmin, vmax


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Plot an rtl_power CSV sweep as a spectrum heatmap.",
    )
    parser.add_argument("csv", help="CSV written by rtl_power")
    parser.add_argument("-o", "--output", help="PNG to write (default: CSV name)")
    parser.add_argument("--summary", action="store_true",
                        help="report what the capture contains and stop; "
                             "needs no numpy or matplotlib")
    parser.add_argument("--vmin", type=float,
                        help="dB at the bottom of the color scale "
                             f"(default: the {CLIP_LOW_PCT:g}th percentile)")
    parser.add_argument("--vmax", type=float,
                        help="dB at the top of the color scale "
                             f"(default: the {CLIP_HIGH_PCT:g}th percentile)")
    parser.add_argument("--cmap", default="viridis",
                        help="matplotlib colormap (default: viridis; see the "
                             "header for why not jet)")
    parser.add_argument("--title", help="plot title (default: the CSV filename)")
    parser.add_argument("--width", type=float, default=12.0, help="inches")
    parser.add_argument("--height", type=float, default=7.0, help="inches")
    parser.add_argument("--dpi", type=int, default=110)

    args = parser.parse_args(argv)
    if not args.output:
        args.output = os.path.splitext(args.csv)[0] + ".png"
    return args


def main(argv=None):
    args = parse_args(argv)

    try:
        chunks, skipped = read_scan(args.csv)
        sweeps = split_sweeps(chunks)
        geometry = scan_geometry(chunks)

        if args.summary:
            summarise(sweeps, geometry)
            return 0

        grid = build_grid(sweeps, geometry[0], geometry[2], geometry[3])
        summarise(sweeps, geometry, grid)
        vmin, vmax = render(grid, sweeps, geometry, args)
    except ScanError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    except FileNotFoundError:
        print(f"ERROR: no such file: {args.csv}", file=sys.stderr)
        return 1
    except ImportError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        print("       sudo apt-get install -y python3-numpy python3-matplotlib",
              file=sys.stderr)
        print("       Or use --summary, which needs neither.", file=sys.stderr)
        return 1

    print(f"  wrote {args.output}  (scale {vmin:.1f} to {vmax:.1f} dB)")
    if skipped:
        print(f"  NOTE: {skipped} row(s) were skipped; the picture is "
              "incomplete where they were.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
