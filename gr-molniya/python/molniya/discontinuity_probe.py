# SPDX-License-Identifier: GPL-3.0-or-later
"""
Sample-discontinuity probe — the gauge in the pipe.

IMPLEMENTED, with the measurement split out. The clock arithmetic lives in
gap_math.py, imports nothing outside the standard library, and is covered
by test_gap_math.py on any machine with Python — because this shell cannot
run where GNU Radio is not installed, and "written but never run" is a
liability this project rations. What remains here is the thin part: tag
unpacking, the pass-through copy, and the log write.

⚠️ THIS SHELL HAS STILL NEVER RUN UNDER GNU RADIO. The math half is
unit-tested; the glue half meets reality when the Pi builds the stack.

WHAT IT IS FOR
    Test 2 of the RT benchmark runs rtl_test, which streams to nowhere: a
    synthetic measurement of the USB capture path. Test 3 judges a decoded
    image by eye. Neither one measures loss during a real capture.

    Inline in a flowgraph, this block turns every pass into a benchmark
    run, and that is the part with no published equivalent -- RT-versus-
    stock comparisons in the SDR space do not carry in-flowgraph
    instrumentation.

THE NON-OBVIOUS PART
    A sync_block cannot see a gap by looking at its input buffer. The
    buffer is always contiguous -- GNU Radio hands over N samples that sit
    next to each other in memory, whether or not the radio dropped a
    million samples just before them. Comparing adjacent samples finds
    signal features, not dropouts.

    The gap is visible in the stream tags. A hardware source (gr-osmosdr,
    the Soapy source, UHD) emits an "rx_time" tag whenever the stream is
    not continuous with what came before -- at start, and after every
    overflow. The tag carries the hardware timestamp of the sample it is
    attached to. The measurement is a comparison of two clocks -- the
    tag's asserted time against the time predicted from the previous tag
    plus samples consumed since. The arithmetic, and why the timestamp's
    (whole, fractional) PMT encoding must never be collapsed into one
    float, is documented and tested in gap_math.py.

    One encoding wrinkle handled here: UHD-lineage sources emit the
    timestamp as a PMT *tuple*; older notes (and some sources) say
    *pair*. Same two values, different container -- _unpack_rx_time
    accepts both, because a probe that crashes on the very tag it exists
    to read has broken a capture to report on a capture.

WHY PYTHON
    Per the ROADMAP: prototype in Python, port to C++ only if it cannot
    keep up at full sample rate. Per-sample work here is nil -- the block
    copies its input and looks at tags, of which there is one per dropout,
    not one per sample -- so Python is very likely fast enough. Measure
    before porting. If the copy itself ever shows up in a profile, the fix
    is to stop copying (tee the stream into a sink), not a C++ port.
"""

import sys
import time

import numpy as np
import pmt
from gnuradio import gr

from .gap_math import GapTracker, to_json_line


def _unpack_rx_time(value):
    """
    An rx_time value -> (whole_seconds, frac_seconds), tuple or pair.

    Returns None for anything else rather than raising: a malformed tag
    must not take down the flowgraph it is instrumenting.
    """
    if pmt.is_tuple(value) and pmt.length(value) == 2:
        return (pmt.to_uint64(pmt.tuple_ref(value, 0)),
                pmt.to_double(pmt.tuple_ref(value, 1)))
    if pmt.is_pair(value):
        return (pmt.to_uint64(pmt.car(value)),
                pmt.to_double(pmt.cdr(value)))
    return None


class discontinuity_probe(gr.sync_block):
    """
    Pass complex samples through unchanged; log every discontinuity.

    Args:
        sample_rate: samples per second, needed to convert a time gap into
            a sample count. Must match the source, or every gap size is
            wrong by the ratio of the two.
        log_path: where to append records. One JSON object per line, so a
            run can be read with jq and appended to without a parser.
        tolerance_samples: gaps at or below this are treated as timestamp
            quantisation rather than loss.
    """

    def __init__(self,
                 sample_rate=2.4e6,
                 log_path="/var/log/molniya/discontinuity.jsonl",
                 tolerance_samples=2):
        gr.sync_block.__init__(
            self,
            name="discontinuity_probe",
            in_sig=[np.complex64],
            out_sig=[np.complex64],
        )

        self.log_path = str(log_path)
        self._tracker = GapTracker(sample_rate=float(sample_rate),
                                   tolerance_samples=int(tolerance_samples))
        self._rx_time_key = pmt.string_to_symbol("rx_time")

        # Opened lazily on first record: a block constructed by GRC while
        # a flowgraph is merely being edited should not create files, and
        # a probe that fails to construct because /var/log is not writable
        # has broken a capture to report on a capture. False after an open
        # failure: counting continues, logging is given up on, loudly once.
        self._log = None

    @property
    def gap_count(self):
        """Gaps seen so far — poll this instead of parsing a live log."""
        return self._tracker.gap_count

    @property
    def gap_samples_total(self):
        """Net samples lost so far (negative gaps subtract)."""
        return self._tracker.gap_samples_total

    def work(self, input_items, output_items):
        """
        Copy input to output unchanged; compare clocks at every rx_time.

        The pass-through exists so the block can sit anywhere in a chain
        without altering the signal.
        """
        output_items[0][:] = input_items[0]

        window = len(input_items[0])
        tags = self.get_tags_in_window(0, 0, window, self._rx_time_key)
        for tag in tags:
            unpacked = _unpack_rx_time(tag.value)
            if unpacked is None:
                continue
            record = self._tracker.observe_tag(
                tag.offset, unpacked[0], unpacked[1])
            if record is not None:
                self._write_record(record)

        return window

    def _write_record(self, record):
        """Append one JSON line; on the first open failure, count only."""
        if self._log is None:
            try:
                self._log = open(self.log_path, "a", encoding="utf-8")
            except OSError as err:
                self._log = False
                print("discontinuity_probe: cannot open %s (%s); "
                      "gaps will be counted but not logged"
                      % (self.log_path, err), file=sys.stderr)
        if self._log is False:
            return

        record["wall_time"] = time.time()
        self._log.write(to_json_line(record))
        self._log.flush()

    def stop(self):
        """Flush and close the log at flowgraph teardown."""
        if self._log not in (None, False):
            self._log.close()
            self._log = None
        return True
