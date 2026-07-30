<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# gr-kosmos

Out-of-tree GNU Radio blocks for KosmOS.

**Status: scaffold.** One block exists as a skeleton with no detection logic. It
loads, it passes samples through unchanged, and it does not measure anything yet.

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
DSP. See `python/kosmos/discontinuity_probe.py` for the design notes, including
the one non-obvious part — a `sync_block` cannot see a gap by looking at its
input buffer, because the buffer is always contiguous. The gap is visible only in
the `rx_time` stream tags the hardware source emits.

## Layout

```
gr-kosmos/
├── README.md
├── install.sh                                  install for development use
├── grc/
│   └── kosmos_discontinuity_probe.block.yml    GRC block definition
└── python/
    └── kosmos/
        ├── __init__.py
        └── discontinuity_probe.py
```

## Why there is no CMakeLists.txt

A full OOT module is generated, not written:

```bash
gr_modtool newmod kosmos
```

That produces the top-level `CMakeLists.txt`, the `cmake/Modules/` support files,
the pybind11 binding scaffolding and the test harness — a few hundred lines of
boilerplate that is version-specific to the GNU Radio it was generated against.
Hand-writing that from memory would produce build files nobody has ever run, which
is worse than having none: they would look authoritative and fail on the Pi.

So this directory holds only the parts that are actually KosmOS's — the block, its
GRC definition, and a script that installs them for development use. When the
block outgrows Python and needs a C++ port, run `gr_modtool newmod kosmos` on the
Pi and graft these files into the generated tree. `gr_modtool` will also generate
correct bindings, which is the part you genuinely do not want to hand-write.

## Installing for development

```bash
./gr-kosmos/install.sh            # install
./gr-kosmos/install.sh --uninstall
```

It does two things: makes `import kosmos` work for your user via a `.pth` file in
your Python user site directory, and copies the GRC block definition into the
directory GNU Radio already scans for installed blocks.

Requires the GNU Radio stack — run `userspace/03a-gnuradio-stack.sh` first.

### Naming note for later

This installs a top-level `kosmos` Python package, and the GRC definition imports
`from kosmos import discontinuity_probe` to match. `gr_modtool` on GNU Radio 3.10
generates modules under the `gnuradio` namespace instead, so a generated module
would be `from gnuradio import kosmos`. Switching to that convention is part of
graduating to a full module — the import in `grc/*.block.yml` has to change with
it.

## Verified, and not

- Both Python files byte-compile, and the GRC YAML parses.
- **Nothing here has been run under GNU Radio.** There is no GNU Radio on the
  machine this was written on, and the Pi has not built the stack yet. First run
  is the test.
