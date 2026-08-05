# SPDX-License-Identifier: GPL-3.0-or-later
"""
Clock arithmetic for the discontinuity probe — no GNU Radio required.

WHY THIS IS A SEPARATE FILE
    The probe's block shell cannot execute on a machine without GNU Radio,
    and this project treats "written but never run" as a liability. So the
    measurement itself — the comparison of two clocks described in
    discontinuity_probe.py — lives here, imports nothing outside the
    standard library, and is exercised by test_gap_math.py on any machine
    with a Python interpreter. The shell that remains untested until the
    Pi has GNU Radio is reduced to tag unpacking and a log write.

    (The "helpers are subprocesses, not sourced libraries" house rule is a
    shell rule — it exists so shellcheck stays clean without -x. A Python
    import inside one package is ordinary module structure, and a
    subprocess per work() call would be absurd in a flowgraph.)

THE ARITHMETIC, and why the (whole, fractional) pair survives to this layer
    An rx_time tag carries absolute time as a pair of (whole seconds,
    fractional seconds) rather than one float, and collapsing the pair
    costs real precision. Absolute times are epoch-scale (~1.7e9 s), where
    a double's ulp is 2.384e-7 s. Measured against a sample period:

        1.024 MS/s   ulp = 0.24 samples
        2.048 MS/s   ulp = 0.49 samples
        2.400 MS/s   ulp = 0.57 samples
        3.200 MS/s   ulp = 0.76 samples

    gap_samples is a round(), which absorbs error below 0.5 samples. So
    collapsing the pair is survivable at the bottom of that list and not
    at the top — and 1.024 through 3.2 MS/s is exactly the sweep
    benchmarks/run-sdr-bench.sh runs, with 3.2 included precisely because
    it is where the kernels should diverge most. At 3.2 MS/s a swept
    fractional offset produces measured error up to 0.71 samples and
    reports a one-sample gap as two. Rates above that are worse: at
    10 MS/s the ulp is 2.4 samples.

    (An earlier revision of this note claimed the ulp was ~4e-7 s and
    therefore LARGER than one sample period at 2.4 MS/s, making a
    one-sample gap unrepresentable. Both halves were wrong — the figure is
    2.384e-7 s, which is 0.57 of a sample. The conclusion survives on the
    rounding-boundary argument above, which is weaker but true, and it is
    the one test_precision_at_epoch_scale actually asserts.)

    Subtracting pairs component-wise never meets that problem: the whole
    seconds difference is exact integer arithmetic, and the fractional
    difference is a subtraction of two small floats. Between two tags a
    few seconds apart, the combined delta is a small number with
    full double precision.

        expected_elapsed = (tag_offset - last_offset) / sample_rate
        actual_elapsed   = pair_delta(last_time, tag_time)
        gap_seconds      = actual_elapsed - expected_elapsed
        gap_samples      = round(gap_seconds * sample_rate)

    |gap_samples| at or below the tolerance is timestamp quantisation,
    not loss, and is not recorded. A negative gap (time ran backward,
    e.g. a retune or a source restart) is recorded with its sign — it is
    an anomaly worth a line in the log, just not a dropout.

    Every tag resets the baseline whether or not it revealed a gap: the
    hardware has asserted "this sample is at this time", and that
    assertion is better than anything extrapolated across it.
"""

import json


def pair_delta(t0, t1):
    """
    Seconds from time t0 to time t1, each a (whole_seconds, frac) pair.

    Whole seconds subtract as exact ints; fractions as small floats.
    Never add whole to fraction before subtracting — see module docstring.
    """
    return float(t1[0] - t0[0]) + (float(t1[1]) - float(t0[1]))


class GapTracker:
    """
    Feed it every rx_time tag; it returns a record for every real gap.

    Pure state machine: no clock reads, no file writes, no GNU Radio.
    The caller supplies absolute sample offsets and (whole, frac) times.

    Args:
        sample_rate: samples per second; converts a time gap into samples.
        tolerance_samples: |gap| at or below this is treated as timestamp
            quantisation rather than loss, and not recorded.
    """

    def __init__(self, sample_rate, tolerance_samples=2):
        self.sample_rate = float(sample_rate)
        self.tolerance_samples = int(tolerance_samples)

        # Running totals, cheap to poll from a dashboard.
        self.gap_count = 0
        self.gap_samples_total = 0

        # Baseline: the last tag's absolute time and the absolute sample
        # offset it was attached to. None until the first tag arrives.
        self._last_time = None
        self._last_offset = None

    def observe_tag(self, offset, whole_seconds, frac_seconds):
        """
        Compare one rx_time tag against the time predicted from the last.

        Args:
            offset: absolute sample offset the tag is attached to.
            whole_seconds: integer part of the tag's hardware timestamp.
            frac_seconds: fractional part, in [0, 1).

        Returns:
            A dict describing the gap, or None if there is no previous
            tag to compare against or the difference is within tolerance.
        """
        tag_time = (int(whole_seconds), float(frac_seconds))
        record = None

        if self._last_time is not None:
            record = self._measure(offset, tag_time)

        # The tag's assertion beats extrapolation across it — rebaseline
        # on every tag, gap or not.
        self._last_time = tag_time
        self._last_offset = int(offset)
        return record

    def _measure(self, offset, tag_time):
        """The two-clock comparison. Returns a record dict or None."""
        expected = (int(offset) - self._last_offset) / self.sample_rate
        actual = pair_delta(self._last_time, tag_time)
        gap_seconds = actual - expected
        gap_samples = round(gap_seconds * self.sample_rate)

        if abs(gap_samples) <= self.tolerance_samples:
            return None

        self.gap_count += 1
        self.gap_samples_total += gap_samples
        return {
            "tag_offset": int(offset),
            "gap_samples": gap_samples,
            "gap_seconds": gap_seconds,
            "since_last_tag_samples": int(offset) - self._last_offset,
        }


def to_json_line(record):
    """
    One record as one JSON line, newline-terminated.

    Keys are sorted so the log is diffable; one object per line so a run
    reads with jq and appends without a parser.
    """
    return json.dumps(record, sort_keys=True) + "\n"
