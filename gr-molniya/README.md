<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# gr-molniya

Out-of-tree GNU Radio blocks for MolniyaOS.

**Status: implemented, half-verified — deliberately.** The probe's clock
arithmetic lives in `gap_math.py` (standard library only) and is covered by
`test_gap_math.py`, which runs on any machine with Python. The GNU Radio block
shell is thin glue around it and **has never run under GNU Radio** — see
"Verified, and not" below for exactly where that line sits.

## The custom-block rule

From `ROADMAP.md`, because it is easy to talk yourself into writing a demodulator
that already exists:

> Write a custom block only when (a) the catalog has no part — a protocol or
> format no existing block handles — or (b) we need a *gauge in the pipe* —
> instrumentation measuring the stream itself.

Never reimplement an existing demodulator as a project feature. Never write a
Doppler block: `gr-satellites` already does Doppler correction and hundreds of
satellites, and the right move there is a pull request, not a parallel
implementation.

## Blocks

### `discontinuity_probe` — the gauge in the pipe

Watches a sample stream and logs every gap, with a timestamp and a size.

This is case (b), and it exists to fix a specific hole in the benchmark. Test 2 of
the RT benchmark runs `rtl_test`, which streams to nowhere: it measures the USB
capture path under synthetic conditions. Test 3 judges a decoded image by eye.
Neither measures loss during a *real* capture.

With this block inline, every pass becomes a benchmark run. That is the part with
no published equivalent — RT-versus-stock comparisons in the SDR space do not
carry in-flowgraph instrumentation.

Scope is deliberately tiny: watch, count, log. No filtering, no correction, no
DSP. See `python/molniya/discontinuity_probe.py` for the design notes, including
the one non-obvious part — a `sync_block` cannot see a gap by looking at its
input buffer, because the buffer is always contiguous. The gap is visible only in
the `rx_time` stream tags the hardware source emits.

The measurement itself is split into `gap_math.py` so it can be unit-tested
without GNU Radio installed. The split is load-bearing for correctness, not just
testability: an `rx_time` timestamp is a PMT `(whole seconds, fractional
seconds)` pair, and collapsing it into one double loses ~4e-7 s of resolution at
epoch scale — *more than one sample period at 2.4 MS/s*, i.e. exactly the gaps
the probe exists to catch. `gap_math.py` documents this and
`test_gap_math.py::test_one_sample_gap_at_epoch_scale_with_zero_tolerance`
proves the pair arithmetic keeps the sample. Run the tests with:

```bash
cd gr-molniya/python/molniya && python3 -m unittest test_gap_math
```

## Layout

```
gr-molniya/
├── README.md
├── install.sh                                  install for development use
├── grc/
│   └── molniya_discontinuity_probe.block.yml    GRC block definition
└── python/
    └── molniya/
        ├── __init__.py
        ├── discontinuity_probe.py              GNU Radio shell (thin glue)
        ├── gap_math.py                         the measurement — stdlib only
        └── test_gap_math.py                    runs anywhere Python runs
```

## Why there is no CMakeLists.txt

A full OOT module is generated, not written:

```bash
gr_modtool newmod molniya
```

That produces the top-level `CMakeLists.txt`, the `cmake/Modules/` support files,
the pybind11 binding scaffolding and the test harness — a few hundred lines of
boilerplate that is version-specific to the GNU Radio it was generated against.
Hand-writing that from memory would produce build files nobody has ever run, which
is worse than having none: they would look authoritative and fail on the Pi.

So this directory holds only the parts that are actually MolniyaOS's — the block, its
GRC definition, and a script that installs them for development use. When the
block outgrows Python and needs a C++ port, run `gr_modtool newmod molniya` on the
Pi and graft these files into the generated tree. `gr_modtool` will also generate
correct bindings, which is the part you genuinely do not want to hand-write.

## Installing for development

```bash
./gr-molniya/install.sh            # install
./gr-molniya/install.sh --uninstall
```

It does two things: makes `import molniya` work for your user via a `.pth` file in
your Python user site directory, and copies the GRC block definition into the
directory GNU Radio already scans for installed blocks.

Requires the GNU Radio stack — run `userspace/03a-gnuradio-stack.sh` first.

### Naming note for later

This installs a top-level `molniya` Python package, and the GRC definition imports
`from molniya import discontinuity_probe` to match. `gr_modtool` on GNU Radio 3.10
generates modules under the `gnuradio` namespace instead, so a generated module
would be `from gnuradio import molniya`. Switching to that convention is part of
graduating to a full module — the import in `grc/*.block.yml` has to change with
it.

## Verified, and not

- `gap_math.py` is **unit-tested and green** (14 tests: gap sizes, tolerance
  boundary, fractional-second borrow, negative gaps, rebaseline-after-gap,
  one-sample gap at epoch-scale time with zero tolerance).
- All Python files byte-compile, and the GRC YAML parses.
- **The block shell has never been run under GNU Radio.** There is no GNU Radio
  on the machine this was written on, and the Pi has not built the stack yet.
  What first run must confirm is exactly the glue: that `rx_time` tags arrive,
  that `_unpack_rx_time` matches the source's actual PMT encoding (tuple vs
  pair — it accepts both), and that the log write behaves. The arithmetic
  behind them is already proven.
