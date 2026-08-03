<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# KosmOS RT Kernel Benchmark

**Status: no results yet.** The harnesses are written; nothing has been measured.
Every table below is empty on purpose — they are the forms to fill in, and an
empty cell is honest where an estimate would not be.

---

## The claim under test

KosmOS builds a `PREEMPT_RT` kernel and asserts that it reduces dropped SDR
samples. Until it is measured against the stock Raspberry Pi kernel on the same
hardware, that is a claim about a config option, not a result.

The question, stated so it can come back "no":

> Does `PREEMPT_RT` measurably reduce worst-case scheduling latency and dropped
> SDR samples versus the stock Pi kernel on identical hardware?

Both outcomes are publishable. A confirmed win is the project's headline. A null
result gets written up as one, and the positioning leans on the other two pillars
— appliance-grade automation and a reproducible build — instead of quietly
dropping the subject.

---

## Why this is an A/B and not a demo

The `os_prefix=` install (`kernel/install-kernel.sh`) puts the KosmOS kernel, its
device trees, its overlays and its command line in their own boot-partition
directory. Every stock boot file stays byte-identical. Switching kernels is
commenting two lines in `config.txt`.

That is what makes the comparison worth anything: between a config-A boot and a
config-B boot, nothing differs except the kernel.

### Configuration matrix

| Config | Kernel | `NOHZ_FULL_CPUS` | What it isolates |
|---|---|---|---|
| **A** | stock Pi kernel | n/a | baseline |
| **B** | KosmOS (`PREEMPT_RT`) | `""` | RT with no core isolation |
| **C** | KosmOS (`PREEMPT_RT`) | `"1-3"` | RT plus full dynticks |

**Report `B − A` as the `PREEMPT_RT` result. Report `C − B` as the core-isolation
result. Never report `C − A`** — it conflates two independent changes and credits
the total to whichever one is being argued for.

Switching A ↔ B/C: comment or uncomment the two directives in the KosmOS block of
`/boot/firmware/config.txt`. Switching B ↔ C: change `NOHZ_FULL_CPUS` in
`kernel/install-kernel.sh` and re-run it, or edit `kosmos/cmdline.txt` on the boot
partition directly.

### Bench box

**pi-server.** It runs no production service, so reboots, crashes and reflashes
are expected there. Its stock kernel is `6.12.62+rpt-rpi-2712`, which is
config A as installed — no kernel pinning needed for the baseline.

**Before any of this runs, gate 0 in `ROADMAP.md` must be met:** the Tor bridge
has to be confirmed off pi-server and confirmed live from altai on Tor Metrics.
The rebuild that precedes these measurements involves failed boots and possibly a
reflash, and that is not something to do underneath a running bridge.

### Kernel provenance — fill this in before publishing

A version string does not identify a kernel. Two builds a fortnight apart off
`rpi-6.12.y` report the same `uname -r` and are not the same code, so a benchmark
that names only a version names nothing reproducible.

`01-build-kernel.sh` prints the source commit it built from, writes it into the
package as `kernel-commit`, and — when the build was not pinned — prints the exact
`KERNEL_COMMIT="..."` line to paste back into the script. **At the step-9 rebuild,
set that pin and record the same SHA here.** Both, not one: the script makes it
reproducible, this table makes it citable.

| | Config A (stock) | Configs B and C (KosmOS) |
|---|---|---|
| `uname -r` | `6.12.62+rpt-rpi-2712` | `6.12.98-kosmos+` |
| `uname -v` | `#1 SMP PREEMPT Debian 1:6.12.62-1+rpt1` | *(fill after first boot)* |
| Source | Pi OS archive | `raspberrypi/linux`, branch `rpi-6.12.y` |
| Commit | n/a — distribution package | **`f5a99b95354d38db209003a7d00560e5091ba94a`** |
| `KERNEL_COMMIT` set in `01-build-kernel.sh` | n/a | ☑ yes — pinned *before* the build |
| Config fragment | n/a | `kernel/sdr-rt.config` |
| Built | n/a | 2026-07-31 on pi-server |

The pin was set before building rather than captured afterwards, so the tree that
compiled is provably the tree named here: `kernel-commit` inside the package
matches the pin in the script, and the build would have aborted had the checkout
landed anywhere else.

**Build cost, measured** (pi-server: Pi 5, 4 GB, 4 cores, `JOBS=3`):

| | |
|---|---|
| Disk consumed | ~4 GB total, source tree plus objects |
| Lowest free memory | 2903 MB |
| Peak swap used | 4 MB — effectively none |
| Peak SoC temperature | 84.2 °C, fan at 4/4 |

Disk and memory were never constraints; `CONFIG_DEBUG_INFO_NONE=y` keeps the
object tree small. **Thermal headroom is the only real limit on this hardware** —
see the thermal control above.

On the Pi, the commit that was installed can be read back from the extracted
package:

```bash
cat ~/kosmos-kernel/kernel-commit
```

---

## Three integrity rules the harnesses enforce

### 1. The governor is pinned in every configuration

`CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y` sets the kernel's *default* governor
and nothing more. Raspberry Pi OS overwrites it from userspace at boot; the
running governor was observed as `ondemand` on hardware on 2026-07-29, on a
kernel built with that option.

This matters because `ondemand` adds a frequency-ramp delay on top of scheduling
latency. Whichever kernel happens to be measured while the CPU is cold looks
worse, for a reason that has nothing to do with the kernel.

So both harnesses set `performance` on every core before every run, in all three
configurations, record the governor they actually observed into each raw output
file, and restore the previous governor on exit. To make it permanent instead:

```bash
sudo bash automation/install-governor.sh
```

Any run whose recorded governor is not `performance` must be labelled as
including ramp effects, or discarded.

### 2. Thermal state is gated, sampled and reported

**Measured on the bench box, mid kernel build, 2026-07-30:** 84.2 °C, fan at
state **4/4**, `throttled=0xe0008` — soft temperature limit active, and both
`throttled-since-boot` and `freq-capped-since-boot` set. A stock Pi 5 running the
official active cooler **does throttle** under sustained all-core load.

Test 1 runs `cyclictest` under `stress-ng --cpu 4`. That is the same thermal load
as a kernel compile, so the benchmark's own workload will throttle a stock Pi.
Throttling changes CPU frequency — precisely the variable the performance
governor was pinned to remove. Left unmeasured it re-enters through the back
door, differs between configurations measured at different times, and lands in
the kernel's column.

**KosmOS targets off-the-shelf hardware, so "fit a better cooler" is not an
available answer.** The method has to be valid inside stock thermal limits:

| Control | What it does |
|---|---|
| **Gate** | Each run waits for ≤ 65 °C before starting, bounded at 10 min so a warm room cannot hang the suite. Every run therefore starts from the same thermal condition. |
| **Sample** | Temperature and the throttle mask are sampled every 5 s *for the duration of the run*, not just at the ends. |
| **Flag** | A run is marked `THROTTLED` if any throttle bit is active at the end, if a sticky since-boot bit newly appeared, or if any mid-run sample caught it. |
| **Report** | Start state, end state and **peak temperature** go into each raw file; end temp and the clean/THROTTLED verdict go into `summary.tsv`. |

Sampling throughout matters because the firmware's since-boot bits are *sticky*.
Once a session has thrown all four, a before/after comparison can only fall back
on the instantaneous reading at the end — so a run that throttles in the middle
and recovers would go unflagged. That case is now caught.

**A `THROTTLED` row is not comparable with a clean one and must not be averaged
in with it.** Flagged rather than discarded: the reader decides, and the evidence
is in the file.

Implemented by `benchmarks/thermal-state.sh`.

#### Reporting rule for a `THROTTLED` row

**Do not re-run a throttled row to obtain a clean one and then publish only the
clean one.** That is selecting on the outcome. The gate exists to make throttling
*rare and visible*, not to license discarding the runs where it happens — and a
configuration that throttles more readily than another has told you something
about itself.

The rule, in order:

1. **Publish the row, with its thermal state beside it.** Peak temperature and the
   `THROTTLED` verdict are already in `summary.tsv` and the raw file. Put them in
   the published table too, in their own column — not in a footnote.
2. **Never average a throttled row with a clean one**, and never compute a delta
   across a throttled/clean pair. Such a delta contains a frequency change the
   pinned governor was there to eliminate, and it will be read as a kernel effect.
3. **Re-running is allowed, but additively.** Keep both rows. A clean re-run beside
   the throttled original is more informative than either alone, because the pair
   brackets the effect.
4. **Discard only for a harness fault** — a wrong `--config` label, a crashed run,
   a governor that failed to pin. Those are broken measurements. A throttled run is
   a *valid measurement of a throttled machine*, which is a different thing.

**Why a throttled row may be the more representative one.** The bench box sits on a
desk with the official active cooler at 4/4. The Phase 3c field kit is a Pi 5 on
battery in a sealed weatherproof enclosure, possibly in direct sun — **thermally
worse than anything measured here.** So a throttled row is not a spoiled reading of
the product; it may be the closest thing in this data set to how the appliance
actually runs. Reporting the clean rows alone would overstate what a deployed
KosmOS box delivers.

If enough throttled rows accumulate to support it, `B_hot − B_cool` becomes a
second reportable delta and the honest headline changes shape — from "PREEMPT_RT
reduces worst-case latency" to "PREEMPT_RT reduces worst-case latency *given
thermal headroom*", with a cooling requirement attached. That is a stronger and
more useful claim than the unqualified one, and no published RT-vs-stock
comparison in this space states it. **Do not chase it before the base A/B/C matrix
is in hand** — if `B − A` turns out small, there is nothing for temperature to
modulate and the extra runs answer nothing.

### 3. Affinity is matched across configurations

In config C, CPUs 1–3 are tickless and CPU 0 is the housekeeping core, which is
not. An unpinned `cyclictest` will schedule threads on CPU 0 — so config C
measures config B, and the isolation delta reads as zero.

The fix is not simply "pin in config C". Comparing a pinned run in C against an
unpinned run in B compares two different experiments, and the affinity change
gets attributed to dynticks.

**Decided 2026-07-30: run both affinity modes in every configuration.** This
supersedes the earlier method note that pinned only in config C. It roughly
doubles Test 1's runtime — about 35 minutes per configuration instead of 18 — and
that cost buys the only thing that makes `C − B` mean anything. It is not
negotiable down to save time; if time is short, cut the number of load conditions,
not the affinity matching.

So `run-latency-bench.sh` runs **both** modes in **every** configuration:

| Mode | Command shape |
|---|---|
| `whole` | `cyclictest -S` — one thread per CPU, all four cores |
| `pinned` | `taskset -c 1-3 cyclictest -a 1-3 -t 3` |

`B − A` comes from the `whole` rows. `C − B` comes from the `pinned` rows. Each
delta is between like and like.

The `-a 1-3 -t 3` alongside `taskset` is not redundant. `-S` derives one thread
per *online* CPU and pins thread 0 to CPU 0, which is outside the taskset mask
and fails; the explicit flags make cyclictest's own pinning agree with the mask.

---

## Test 1 — Scheduling latency

**Needs no SDR hardware.** Runnable the moment the kernel boots.

```bash
# on each configuration, after rebooting into it
./benchmarks/run-latency-bench.sh --quick    # 2 min: does the harness work?
./benchmarks/run-latency-bench.sh            # ~35 min: the real run
```

- Tool: `cyclictest` from `rt-tests`
- 1,000,000 loops at 200 µs, `SCHED_FIFO` priority 90, `mlockall`, 400 histogram
  buckets
- Three load conditions: idle, CPU (`stress-ng --cpu 4`), IO
  (`stress-ng --io 2 --vm 1`)
- Two affinity modes, as above → 6 runs per configuration
- Reported figure is **max latency**, taken as the largest across threads. RT
  kernels win on the tail, not the mean; a single bad core is still a bad worst
  case.

The configuration label is detected from `/proc/config.gz`, `uname -v` and
`/proc/cmdline` rather than typed in, because a mislabelled result set is worse
than no result set. `--config` overrides it.

Raw output and per-run metadata land in `benchmarks/results/`, one file per run,
each carrying the kernel version, command line, governor and timestamp. Those
files are the evidence; the tables below are the summary.

### Test 1 results — `whole` (all four cores)

Latencies in microseconds.

*Run 2026-07-31 (A) and 2026-08-02 (B, C). 1M loops at 200 µs, priority 90,
governor `performance` on every row.*

| Config | Load | Min | Avg | **Max** | Thermal |
|---|---|---|---|---|---|
| A — stock | idle | 1 | 1 | **3257** | clean |
| A — stock | cpu | 1 | 1 | 74 | ⚠️ THROTTLED |
| A — stock | io | 1 | 3 | **6262** | clean |
| B — RT | idle | 1 | 1 | **13** | clean |
| B — RT | cpu | 1 | 2 | 18 | ⚠️ THROTTLED |
| B — RT | io | 1 | 2 | **175** | clean |
| C — RT + dynticks | idle | 1 | 2 | **4844** | clean |
| C — RT + dynticks | cpu | 2 | 3 | 28 | ⚠️ THROTTLED |
| C — RT + dynticks | io | 2 | 4 | 346 | clean |

### Test 1 results — `pinned` (CPUs 1–3)

| Config | Load | Min | Avg | **Max** | Thermal |
|---|---|---|---|---|---|
| A — stock | idle | 1 | 1 | 62 | clean |
| A — stock | cpu | 1 | 2 | 140 | ⚠️ THROTTLED |
| A — stock | io | 1 | 3 | **6161** | clean |
| B — RT | idle | 1 | 1 | 12 | clean |
| B — RT | cpu | 1 | 2 | 13 | ⚠️ THROTTLED |
| B — RT | io | 1 | 2 | **293** | clean |
| C — RT + dynticks | idle | 1 | 2 | 17 | clean |
| C — RT + dynticks | cpu | 2 | 3 | 20 | ⚠️ THROTTLED |
| C — RT + dynticks | io | 1 | 3 | **36** | clean |

⚠️ **Every `cpu`-load row throttled, in all three configurations.** Sustained
all-core `stress-ng --cpu 4` saturates this hardware's cooling with the fan
already at maximum. Per the standing decision, a throttled row is published with
the flag rather than re-rolled — but the CPU-load comparison is the weakest of
the three and should not be leaned on. The `idle` and `io` rows are `clean`
throughout, and they carry the result.

### Test 1 deltas

Negative is better. `B − A` from the `whole` table, `C − B` from the `pinned`
table.

| Delta | Load | Δ Avg | **Δ Max** | What it means |
|---|---|---|---|---|
| B − A | idle | 0 | **−3244 µs** (250× better) | `PREEMPT_RT`, unloaded |
| B − A | cpu | +1 | −56 µs (4.1× better) ⚠️ | `PREEMPT_RT` under CPU load |
| B − A | io | −1 | **−6087 µs** (35.8× better) | `PREEMPT_RT` under IO load |
| C − B | idle | +1 | +5 µs (worse) | core isolation, unloaded |
| C − B | cpu | +1 | +7 µs (worse) ⚠️ | core isolation under CPU load |
| C − B | io | +1 | **−257 µs** (8.1× better) | core isolation under IO load |

⚠️ = both rows throttled; treat as indicative only.

### What the numbers say

**PREEMPT_RT is a large win, and the win is entirely in the tail.** Average
latency is 1–4 µs in every configuration under every load — the kernels are
indistinguishable on the mean. Worst case under IO load goes from **6.3 ms to
175 µs**, which is the number this benchmark existed to produce. For SDR capture
that is the difference between a dropped buffer and a clean one.

**Core isolation is not a free upgrade — it is a trade.** On the isolated cores
it is a clear win under IO load (293 → 36 µs, 8.1×), and a small loss at idle
(12 → 17 µs) where there is no interference to remove and only the extra
bookkeeping shows. Config C is worth it for pinned RT work and not otherwise.

**The unpinned idle tail is a CPU 0 effect, and it appears in A and C but not
B.** Stock reads 3257 µs unpinned against 62 µs pinned; config C reads 4844 µs
against 17 µs. Config B shows no such split (13 vs 12 µs). The mechanism differs
between the two — in A it is the ordinary non-preemptible kernel, in C it is the
housekeeping core absorbing the timer and RCU-callback work offloaded from CPUs
1–3 by `nohz_full`/`rcu_nocbs` — but the practical consequence is the same:

> **`nohz_full` reintroduces a stock-kernel-sized latency tail on the
> housekeeping core.** Work that is not pinned to the isolated cores is worse off
> under config C than under plain PREEMPT_RT. Isolation is a promise about where
> the work runs, not about the machine as a whole.

That is the single most useful operational finding here, and it is only visible
because both affinity modes were run in every configuration. The decision to pay
~35 minutes per config instead of ~18 bought exactly this: without the pinned
rows, C's isolation win would be invisible, and without the unpinned rows, its
housekeeping-core cost would be.

**Caveat on the two big unpinned idle numbers.** 3257 µs and 4844 µs are single
samples. The mechanism is understood and the A/C-versus-B split is consistent
with it, but neither has been reproduced. Treat the *pattern* as established and
the *magnitudes* as provisional until a repeat run.

### Repeatability

Config B was run twice in the same boot, unintentionally. The two passes agree
closely, which is a free check on harness stability:

| Load / affinity | Pass 1 max | Pass 2 max |
|---|---|---|
| idle / whole | 13 | 13 |
| idle / pinned | 12 | 12 |
| cpu / whole | 17 | 18 |
| cpu / pinned | 15 | 13 |
| io / whole | 146 | 175 |
| io / pinned | 200 | 293 |

Pass 2 is the one in the tables above, chosen because its raw files survive —
`summary.tsv` appends while raw files are overwritten per run, so pass 1's
evidence was destroyed by pass 2. The IO rows show the most spread, which is
expected: they are the runs with the most competing work and the longest tail.

---

## Test 2 — Dropped SDR samples

**Needs the RTL-SDR dongle. Not yet run — no dongle on hand.**

Test 1 measures the mechanism; this measures the consequence, and it is the
number a reader will care about more than microseconds of wakeup latency.

```bash
./benchmarks/run-sdr-bench.sh --quick    # 30s, one rate: check the parsing
./benchmarks/run-sdr-bench.sh            # ~1.5 h per configuration
```

- Tool: `rtl_test -s <rate>`, bounded by `timeout --signal=INT`
- Rates: 1.024, 2.048, 2.4, 3.2 MS/s. 2.4 is the usual NOAA APT rate; 3.2 is
  above what most dongles sustain, and is included because that is where the
  kernels should diverge most
- 600 s per run, idle and under `stress-ng --cpu 4 --io 2` — the load stands in
  for a decode job running during a live capture, which is the realistic worst
  case for an appliance that decodes on landing
- Metric: samples lost per run. `rtl_test` reports gaps in bytes; the dongle
  delivers 8-bit I and 8-bit Q, so one complex sample is two bytes

The harness refuses to start if `rtl_test -t` cannot open a device. With no
dongle present every run would report zero lost samples and look like a flawless
result.

**Confounder to control:** antenna, cable and dongle position are variables too.
Leave the hardware physically undisturbed across the whole sweep, or a bumped
connector reads as a kernel regression.

### Test 2 results

Samples lost per 600 s run.

| Rate (MS/s) | Load | A — stock | B — RT | C — RT + dynticks |
|---|---|---|---|---|
| 1.024 | idle | | | |
| 1.024 | load | | | |
| 2.048 | idle | | | |
| 2.048 | load | | | |
| 2.4 | idle | | | |
| 2.4 | load | | | |
| 3.2 | idle | | | |
| 3.2 | load | | | |

### Test 2 deltas

| Rate (MS/s) | Load | B − A | C − B |
|---|---|---|---|
| 1.024 | idle | | |
| 1.024 | load | | |
| 2.048 | idle | | |
| 2.048 | load | | |
| 2.4 | idle | | |
| 2.4 | load | | |
| 3.2 | idle | | |
| 3.2 | load | | |

---

## Test 3 — Real-world decode quality

**Needs dongle plus antenna. No harness — this one is judged, not measured.**

Live NOAA APT captures through SatDump with background load, comparing dropout
lines and decode quality across passes on each kernel.

It is the weakest test: two passes are never identical, so the comparison is not
controlled. It is also the most convincing demonstration, because a torn image
next to a clean one needs no explanation. Report it as illustration, never as the
result.

| Config | Satellite | Max elevation | Pass time (UTC) | Load | Dropout lines | Notes |
|---|---|---|---|---|---|---|
| | | | | | | |

---

## Instrumentation upgrade — the `gr-kosmos` discontinuity probe

Tests 2 and 3 measure different things badly: `rtl_test` streams to nowhere, and
a decoded image is a subjective read. The gap between them is a capture that is
*real* and *measured*.

`gr-kosmos/` holds the scaffold for an inline GNU Radio block that watches the
sample stream and logs every discontinuity with a timestamp — the gauge in the
pipe. Once it works, every real capture becomes a benchmark run, and Test 2 stops
being synthetic.

No published RT-versus-stock comparison in the SDR space has in-flowgraph
instrumentation. That is part of what would make this result worth reading.

Status: scaffold and Python skeleton only, no DSP logic. See
`gr-kosmos/README.md`.

---

## Reading the results honestly

- **Max, not avg.** An RT kernel that improves the mean and not the tail has not
  done the thing it exists to do.
- **Under load, not idle.** Idle latency on a four-core Pi 5 is unremarkable on
  any kernel. The interesting column is `io`.
- **Sample loss is the outcome that matters.** If Test 1 improves and Test 2 does
  not, the honest conclusion is that scheduling latency was not the bottleneck
  for USB SDR capture on this hardware — which is a real finding, and more
  interesting than a confirmation.
- **One box, one dongle, one location.** Nothing here generalises past a Pi 5 with
  an RTL-SDR. Say so in the write-up.
- **A throttled row gets published, not re-rolled.** Re-running until the number is
  clean and reporting only that is selection on the outcome. See the reporting rule
  under integrity rule 2 — and note the field kit is thermally *worse* than this
  bench box, so the throttled rows may describe the deployed appliance better than
  the clean ones do.
