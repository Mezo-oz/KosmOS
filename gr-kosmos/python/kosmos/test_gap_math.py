# SPDX-License-Identifier: GPL-3.0-or-later
"""
Unit tests for gap_math — runnable anywhere Python runs.

    cd gr-kosmos/python/kosmos && python3 -m unittest test_gap_math

That is the only invocation that works, and it is worth knowing why before
someone "fixes" it. `python3 -m unittest <path>` does not take a path, it
takes a dotted module name. Nor can this run as part of the package: the
import here is `from gap_math import ...`, flat and deliberate, because
importing it as `kosmos.test_gap_math` executes __init__.py, which imports
the probe, which imports gnuradio — and the entire point of this file is to
be runnable where gnuradio is not installed. Discovery from the repo root
fails for a third reason: `gr-kosmos` is not a valid Python identifier.

No GNU Radio, no numpy, no hardware. That is the point: this is the half
of the probe that CAN be verified off the Pi, so it is.
"""

import json
import unittest

from gap_math import GapTracker, pair_delta, to_json_line

RATE = 2.4e6

# The top of the sweep run-sdr-bench.sh performs. It is where collapsing
# (whole, frac) into one double first reliably changes a rounded gap — see
# test_collapsing_the_pair_misreports_a_gap.
RATE_TOP = 3.2e6

# Epoch-scale whole seconds, where a double's ulp is 2.384e-7 s — a
# fraction of a sample period, not more than one. See gap_math docstring.
EPOCH = 1_700_000_000


class TestPairDelta(unittest.TestCase):

    def test_simple(self):
        self.assertAlmostEqual(pair_delta((10, 0.25), (12, 0.75)), 2.5)

    def test_fraction_borrow_across_whole_second(self):
        # 100.9 -> 103.1: fractional part goes DOWN while time goes up.
        d = pair_delta((100, 0.9), (103, 0.1))
        self.assertAlmostEqual(d, 2.2, places=12)

    def test_negative(self):
        self.assertAlmostEqual(pair_delta((50, 0.5), (49, 0.5)), -1.0)

    def test_precision_at_epoch_scale(self):
        # Pair arithmetic is exact regardless of how large the whole
        # seconds are: the fraction never meets the epoch.
        one_sample = 1.0 / RATE
        d = pair_delta((EPOCH, 0.0), (EPOCH, one_sample))
        self.assertAlmostEqual(d, one_sample, places=15)

    def test_collapsing_the_pair_misreports_a_gap(self):
        """The regression test for the whole design of pair_delta.

        This fails if anyone simplifies the (whole, frac) pair into one
        float before subtracting. It is not a hypothetical: at 3.2 MS/s,
        the top of run-sdr-bench.sh's sweep, a double's ulp at epoch scale
        is 0.76 of a sample period, so the error crosses the 0.5 boundary
        that round() would otherwise absorb -- and a single dropped sample
        gets reported as two.
        """
        frac, gap = 0.0105, 1
        after = frac + gap / RATE_TOP
        t0 = (EPOCH, frac)
        t1 = (EPOCH + int(after), after - int(after))

        exact = pair_delta(t0, t1)
        collapsed = (float(t1[0]) + t1[1]) - (float(t0[0]) + t0[1])

        self.assertEqual(round(exact * RATE_TOP), gap)
        self.assertEqual(round(collapsed * RATE_TOP), 2)


class TestGapTracker(unittest.TestCase):

    def track(self, tolerance=2):
        return GapTracker(sample_rate=RATE, tolerance_samples=tolerance)

    def feed(self, tracker, offset, gap_samples=0):
        """
        Feed a tag at `offset` introducing a gap of N samples SINCE THE
        PREVIOUS TAG. Gaps accumulate on the hardware timeline, exactly
        as real dropouts do, so the helper carries a running total.
        """
        total = getattr(tracker, "_test_err_samples", 0) + gap_samples
        tracker._test_err_samples = total
        t = (offset + total) / RATE
        whole = EPOCH + int(t)
        frac = t - int(t)
        return tracker.observe_tag(offset, whole, frac)

    def test_first_tag_yields_no_record(self):
        tracker = self.track()
        self.assertIsNone(tracker.observe_tag(0, EPOCH, 0.0))
        self.assertEqual(tracker.gap_count, 0)

    def test_consistent_stream_is_silent(self):
        tracker = self.track()
        for offset in (0, 1_000_000, 2_400_000, 7_654_321):
            self.assertIsNone(self.feed(tracker, offset))
        self.assertEqual(tracker.gap_count, 0)
        self.assertEqual(tracker.gap_samples_total, 0)

    def test_single_gap_detected_with_size(self):
        tracker = self.track()
        self.feed(tracker, 0)
        record = self.feed(tracker, 5_000_000, gap_samples=1200)
        self.assertIsNotNone(record)
        self.assertEqual(record["gap_samples"], 1200)
        self.assertEqual(record["tag_offset"], 5_000_000)
        self.assertEqual(record["since_last_tag_samples"], 5_000_000)
        self.assertAlmostEqual(
            record["gap_seconds"], 1200 / RATE, places=9)
        self.assertEqual(tracker.gap_count, 1)
        self.assertEqual(tracker.gap_samples_total, 1200)

    def test_multiple_gaps_accumulate(self):
        tracker = self.track()
        self.feed(tracker, 0)
        self.feed(tracker, 1_000_000, gap_samples=100)
        self.feed(tracker, 2_000_000, gap_samples=250)
        self.assertEqual(tracker.gap_count, 2)
        self.assertEqual(tracker.gap_samples_total, 350)

    def test_tolerance_boundary(self):
        # At the tolerance: quantisation, not loss. One past it: loss.
        tracker = self.track(tolerance=2)
        self.feed(tracker, 0)
        self.assertIsNone(
            self.feed(tracker, 1_000_000, gap_samples=2))
        record = self.feed(tracker, 2_000_000, gap_samples=3)
        self.assertEqual(record["gap_samples"], 3)

    def test_negative_gap_recorded_with_sign(self):
        # Time ran backward (retune / restart) — an anomaly, logged as is.
        tracker = self.track()
        self.feed(tracker, 0)
        record = self.feed(tracker, 1_000_000, gap_samples=-500)
        self.assertEqual(record["gap_samples"], -500)
        self.assertEqual(tracker.gap_samples_total, -500)

    def test_rebaseline_after_gap(self):
        # A gap must not echo: the tag that revealed it becomes the new
        # baseline, so a following consistent tag is silent.
        tracker = self.track()
        self.feed(tracker, 0)
        self.feed(tracker, 1_000_000, gap_samples=1200)
        # Consistent with the *erroneous* time line from here on.
        t = 1_000_000 / RATE + 1200 / RATE + 1_400_000 / RATE
        whole, frac = EPOCH + int(t), t - int(t)
        self.assertIsNone(tracker.observe_tag(2_400_000, whole, frac))
        self.assertEqual(tracker.gap_count, 1)

    def test_one_sample_gap_at_epoch_scale_with_zero_tolerance(self):
        # The reason the pair survives to this layer: a single dropped
        # sample at epoch-scale absolute time is still detectable.
        tracker = self.track(tolerance=0)
        self.feed(tracker, 0)
        record = self.feed(tracker, 240_000, gap_samples=1)
        self.assertIsNotNone(record)
        self.assertEqual(record["gap_samples"], 1)


class TestJsonLine(unittest.TestCase):

    def test_round_trips_and_terminates(self):
        record = {"tag_offset": 42, "gap_samples": 7,
                  "gap_seconds": 7 / RATE, "since_last_tag_samples": 99}
        line = to_json_line(record)
        self.assertTrue(line.endswith("\n"))
        self.assertNotIn("\n", line[:-1])
        self.assertEqual(json.loads(line), record)

    def test_keys_sorted_for_diffable_logs(self):
        line = to_json_line({"b": 1, "a": 2})
        self.assertLess(line.index('"a"'), line.index('"b"'))


if __name__ == "__main__":
    unittest.main()
