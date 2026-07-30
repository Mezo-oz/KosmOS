"""
Sample-discontinuity probe — the gauge in the pipe.

SKELETON. It loads, it passes samples through untouched, and it detects nothing.
The detection logic is the next commit; this file exists to fix the shape of the
block and to record the design, including the part that is not obvious.

WHAT IT IS FOR
    Test 2 of the RT benchmark runs rtl_test, which streams to nowhere: a
    synthetic measurement of the USB capture path. Test 3 judges a decoded image
    by eye. Neither one measures loss during a real capture.

    Inline in a flowgraph, this block turns every pass into a benchmark run, and
    that is the part with no published equivalent -- RT-versus-stock comparisons
    in the SDR space do not carry in-flowgraph instrumentation.

THE NON-OBVIOUS PART, and the reason this file has design notes instead of a
first draft of the arithmetic:

    A sync_block cannot see a gap by looking at its input buffer. The buffer is
    always contiguous -- GNU Radio hands over N samples that sit next to each
    other in memory, whether or not the radio dropped a million samples just
    before them. Comparing adjacent samples finds signal features, not dropouts.

    The gap is visible in the stream tags. A hardware source (gr-osmosdr, the
    Soapy source, UHD) emits an "rx_time" tag whenever the stream is not
    continuous with what came before -- at start, and after every overflow. The
    tag carries the hardware timestamp of the sample it is attached to.

    So the measurement is a comparison of two clocks:

        expected_time = time_of_last_rx_time_tag
                      + (samples_since_that_tag / sample_rate)
        actual_time   = timestamp in the new rx_time tag
        gap_seconds   = actual_time - expected_time
        gap_samples   = round(gap_seconds * sample_rate)

    Anything above a tolerance of a few samples is a real dropout. The tolerance
    matters: hardware timestamps have finite resolution, and a strict inequality
    would log a gap of zero samples on every tag.

    The tags are read with:

        tags = self.get_tags_in_window(0, 0, len(input_items[0]),
                                       pmt.string_to_symbol("rx_time"))

    and an rx_time tag's value is a PMT pair of (whole seconds, fractional
    seconds), not a float -- which is a detail that will bite whoever writes the
    arithmetic if it is not written down here first.

WHY PYTHON
    Per the ROADMAP: prototype in Python, port to C++ only if it cannot keep up
    at full sample rate. Per-sample work here is nil -- the block copies its
    input and looks at tags, of which there is one per dropout, not one per
    sample -- so Python is very likely fast enough. Measure before porting.

    The one thing to watch is that the copy itself is not free at 2.4 MS/s. If
    profiling says it is the bottleneck, the answer is not a C++ port: it is to
    stop copying. See the note on the pass-through below.
"""

import numpy as np
from gnuradio import gr


class discontinuity_probe(gr.sync_block):
    """
    Pass complex samples through unchanged; log every discontinuity.

    Args:
        sample_rate: samples per second, needed to convert a time gap into a
            sample count. Must match the source, or every gap size is wrong by
            the ratio of the two.
        log_path: where to append records. One JSON object per line, so a run can
            be read with jq and appended to without a parser.
        tolerance_samples: gaps at or below this are treated as timestamp
            quantisation rather than loss.
    """

    def __init__(self,
                 sample_rate=2.4e6,
                 log_path="/var/log/kosmos/discontinuity.jsonl",
                 tolerance_samples=2):
        gr.sync_block.__init__(
            self,
            name="discontinuity_probe",
            in_sig=[np.complex64],
            out_sig=[np.complex64],
        )

        self.sample_rate = float(sample_rate)
        self.log_path = str(log_path)
        self.tolerance_samples = int(tolerance_samples)

        # Running totals, exposed for a flowgraph or a dashboard to poll rather
        # than having to parse the log while it is being written.
        self.gap_count = 0
        self.gap_samples_total = 0

        # TODO: state for the timestamp comparison described in the module
        # docstring -- the last rx_time tag's absolute time, and the absolute
        # sample offset it was attached to.
        self._last_tag_time = None
        self._last_tag_offset = None

        # TODO: open the log lazily on first write, not here. A block
        # constructed by GRC while a flowgraph is merely being edited should not
        # create files, and a probe that fails to construct because /var/log is
        # not writable has broken a capture to report on a capture.
        self._log = None

    def work(self, input_items, output_items):
        """
        Copy input to output, unchanged.

        The pass-through exists so the block can sit anywhere in a chain without
        altering the signal. It is also the only per-sample cost in here, and if
        it ever shows up in a profile the fix is to make this a sink with the
        stream tee'd to it, or to hand the buffer through without copying --
        not to rewrite the block in C++.
        """
        output_items[0][:] = input_items[0]

        # TODO: detection. Read rx_time tags over this window, compare each
        # against the time predicted from the previous tag plus the samples
        # consumed since, and log any difference above tolerance_samples. The
        # arithmetic and the PMT unpacking are both spelled out in the module
        # docstring.
        #
        # Deliberately not stubbed with a placeholder that "sort of" detects
        # something: a probe that reports plausible wrong numbers is worse than
        # one that reports none, because the numbers end up in a table.

        return len(output_items[0])

    def stop(self):
        """Flush and close the log. Called by the runtime at flowgraph teardown."""
        # TODO: close self._log once it exists.
        return True
