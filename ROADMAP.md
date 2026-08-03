<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# KosmOS — Project Roadmap & Vision

*Naming settled 2026-07-29: it's **KosmOS** with a K — matches the existing repo
(Mezo-oz/KosmOS), the committed artifacts (kernel-kosmos.img, `-kosmos`
localversion), and the Cyrillic-flavoured "Kosmos" fits the SATCOM angle.*

## Hardware Topology (permanent, decided 2026-07-29)

Two Raspberry Pi 5s, with a deliberate and permanent split of roles:

- **pi-server — the dedicated KosmOS dev / break-fix box.** All kernel work
  happens here: custom-kernel swaps, `os_prefix` installs, benchmark reboots,
  crashes, and full reflashes are all *expected and welcome* on this machine.
  It runs no production service, so there is **no reboot-window constraint** —
  breaking it is the point. It is the config-A benchmark baseline too: stock
  Pi OS `6.12.62+rpt-rpi-2712` is already installed, so no kernel pinning is
  needed for the A/B.

- **altai — the permanent production host.** Runs the Amnezia work, and will run
  the `tor-services` Docker stack (an obfs4 bridge + snowflake proxy +
  watchtower). Stable, always-on, not to be disrupted for KosmOS.
  **The production bridge does not return to pi-server** — this is settled, not
  provisional.

  ✅ **Migrated 2026-07-30**, by Path B — pi-server freed by moving the bridge off
  it, not by swapping SD cards, since there is no spare card. The identity was
  preserved: same fingerprint and same obfs4 `cert=`, verified byte-for-byte
  against a pre-move capture, so previously distributed bridge lines keep working.
  Watchtower was dropped in the move; altai runs the bridge and snowflake only.

  *(This section previously recorded the migration as done on 2026-07-29. It was
  decided that day, not executed — corrected earlier on 2026-07-30, and now
  genuinely true. Procedure and the post-mortem live in the migration runbook
  beside the compose file in the `tor-services` project directory, deliberately
  outside this repo.)*

Why the split matters for this project: the RT kernel benchmark needs a box you
can reboot between kernels at will and reflash if an install goes wrong. A host
also running a live Tor bridge is the opposite of that. Separating them removes
the only scheduling constraint the benchmark had.

**Relationship to the Phase 3c Tor bridge module (below):** KosmOS *ships* an
optional bridge module as a distro feature. That is entirely separate from the
production bridge on altai. The module is dogfooded later with a **throwaway
test identity** — never the live bridge's keys. (Repo docs stay generic about
the production bridge: no WAN IP, email, or fingerprint in any committed file.)

## Identity: What KosmOS Is (and Isn't)

**KosmOS is a ground-up, SATCOM-focused Linux distribution built for the Raspberry Pi 5.**

The existing player in this space is DragonOS — a Lubuntu-based distro that ships as
a pre-built ISO with every SDR tool imaginable pre-installed. DragonOS is the "Kali
Linux of SDR": boot it up, everything works, you don't know how any of it was built.

KosmOS takes the opposite philosophy:

| | DragonOS | KosmOS |
|---|---------|--------|
| **Base** | Lubuntu (stock kernel) | Custom RT kernel built from source |
| **Architecture** | x86_64 primary, Pi secondary | ARM64/Pi 5 native, built for the edge |
| **Scope** | Kitchen sink (200+ tools) | SATCOM/space focused (curated toolkit) |
| **Philosophy** | "Everything pre-installed" | "Built from ground up, understand every layer" |
| **Target user** | Hobbyist who wants to scan now | Builder who wants to understand *and* do |
| **RT kernel** | No (stock Ubuntu kernel) | Yes (PREEMPT_RT, 1000Hz) |
| **Field deployment** | Desktop/laptop focused | Pi 5 portable kit with battery + WiFi AP |

**The pitch:** KosmOS is what you'd build if you were setting up a SATCOM ground
station from bare metal — custom kernel tuned for real-time RF processing, a curated
toolkit focused on satellite communications, and a deployment model designed for
portable field work on ARM64 hardware.

### Positioning: Appliance, Not Toolbox

KosmOS is **not** "DragonOS minus tools" — that would be a learning project, not a
product. KosmOS is an **autonomous SATCOM ground station appliance for ARM64**.
DragonOS hands you a workshop; KosmOS hands you a working instrument: flash the
image, give it your coordinates, and it starts producing satellite imagery and
decoded data on its own.

Three pillars separate this from a toy:

1. **Measured RT performance** — the custom kernel is a *claim* until it's
   benchmarked against the stock kernel on identical hardware. See "Proof of
   Claim" below. If the numbers hold, KosmOS has an engineering result nobody
   else in this space has published. If they don't, we find out early and
   reposition honestly.
2. **Appliance-grade automation** — Phase 3 (auto-updating TLEs, scheduled pass
   capture, decode-on-landing, web dashboard) is the *soul* of the project, not
   a later add-on. Phases 1–2 build the parts; Phase 3 is what makes it a
   product. Target users — researchers, weather-imagery hobbyists, off-grid
   expeditions needing current satellite weather with zero internet — want the
   *output* of the tools, not 200 tools.
3. **Reproducible, auditable build** — scripts and pinned versions, not an
   opaque golden-image ISO. ✅ *Now a fact for the userspace stack:
   `02c-sdr-userspace.sh` pins all four projects to exact commits and verifies
   the checkout against the pin, hard-failing on a mismatch rather than building
   whatever a moved tag points at. Every new build script pins from line one.
   What is built gets recorded to `/usr/local/share/kosmos/build-manifest.txt`,
   so a box can be asked which revision a binary came from. Still open: the
   kernel branch itself (`rpi-6.12.y`) is a moving target — see Phase 4a.*

---

## Engineering Standards (adopted 2026-07-29)

**Languages, honestly stated.** The kernel is C — but it's *upstream* C that
KosmOS configures, patches, and compiles, not writes. KosmOS's own code is
orchestration: **bash** for build/install/automation scripts, **Python** where
a pipeline needs real data handling (rtl_power heatmaps, pass-scheduling
logic, dashboard backend), and **C/C++ only if/when** we write custom GNU
Radio blocks, SatDump plugins, or kernel patches. Distro-building is general
contracting, not brick manufacturing.

**Adapted NASA/JPL discipline.** The famous NASA rules are JPL's "Power of
Ten" for safety-critical flight C — the actual size rule there is *functions
≤ ~60 lines (one printed page)*. A 400-line-per-file cap is not NASA's rule,
but we adopt it as house convention anyway. KosmOS rules, adapted for
shell/Python:

1. **≤400 lines per file** — a script that outgrows this gets split
2. **Functions ≤60 lines**, one job each (the real Power-of-Ten rule 4)
3. **Check every return value** — `set -euo pipefail` in every script;
   explicit handling wherever a failure is expected (rule 7)
4. **No unbounded loops** — every retry/wait loop has a timeout or max
   iteration count (rule 2)
5. **shellcheck clean at zero warnings** — the analog of rule 10 ("all
   warnings on, all warnings fixed").
   **Verified at zero 2026-07-29** (shellcheck 0.9.0 on Linux and 0.11.0
   locally, both agreeing on the same 11 findings before the fix; zero after,
   including at `-S style`)
   ✅ **CI-gated** — `.github/workflows/shellcheck.yml` runs `shellcheck -S style`
   over every tracked `*.sh` on push and pull request, at a **pinned** shellcheck
   version verified by SHA-256. Pinning matters: a runner-provided shellcheck
   drifts with the image, so a new release adding a check would fail an unchanged
   tree for no reason visible in the diff. Rules 1 and the `.gitattributes` CRLF
   invariant are gated in the same workflow.
   No `-x` and no `disable=` directives anywhere in the tree — that is why the
   scripts duplicate a small amount of helper code rather than sourcing a shared
   library, which would need `--external-sources` to stay clean.
6. **Smallest scope** — `local` inside functions, globals only when
   deliberate and named LIKE_THIS (rule 6)
7. **Pin every version, checksum every download** — Pillar 3's mechanics

### Extraction rule (decided 2026-07-30)

Several scripts duplicate helper code on purpose. **Do not extract it on sight.**

Known duplication, all deliberate:

| Duplicated | Copies in | Size |
|---|---|---|
| governor handling, config detection, load generation | ~~`run-latency-bench.sh`~~, `run-sdr-bench.sh` | ~80 lines |
| `clone_pinned` | `02c-sdr-userspace.sh`, `03b-satdump.sh`, `03c-sdrpp.sh` | ~40 lines |

### ✅ The rule fired, 2026-07-30 — and it worked as written

Adding thermal gating to `run-latency-bench.sh` was what tripped the 400-line trigger, exactly
the way the rule anticipated: the file could not hold the new logic and had nothing to lose
elsewhere. Three **executable helpers** came out of it, invoked as subprocesses, never sourced:

| Helper | Lines | Interface |
|---|---|---|
| `benchmarks/detect-config.sh` | 47 | prints `A`/`B`/`C` on stdout, non-zero if unsure |
| `benchmarks/governor.sh` | 46 | `read` prints the governor; `set <gov>` sets it |
| `benchmarks/thermal-state.sh` | 207 | gates on starting temperature, samples, flags throttling |

Two things worth recording because they validate the rule rather than merely following it:

- **The shape held up.** All three are called as commands
  (`CONFIG=$("$SELF_DIR/detect-config.sh")`, `"$SELF_DIR/governor.sh" set performance`), so each
  is analysed by shellcheck as its own file and the caller stays clean with no `source=`
  directive, no `--external-sources`, and no `disable=`. The CI gate still runs plain
  `shellcheck -S style`.
- **`run-latency-bench.sh` came out at 392 lines — the same as before.** Extraction bought back
  exactly the room the thermal work needed. That is the trigger doing its job: the file grew in
  capability without growing past the cap.

**The asymmetry this created is now the live one.** `run-latency-bench.sh` uses the helpers;
`run-sdr-bench.sh` still carries its own `read_governor`/`set_governor` and `detect_config`
copies (see its own note at line 34). **Do not "finish the job" by converting it on sight** —
that is the tidiness argument the rule exists to refuse. It converts when *it* must grow past
the cap; it is at 363 with the helpers already written and tested, so that conversion will be
cheap whenever the trigger actually fires.

**Trigger — the only one.** Extract when a file must grow past the 400-line cap
and cannot lose the lines elsewhere. Nothing else counts: not tidiness, not the
copy count, not "it'll be needed later". That is the same trigger that split
`package-kernel.sh` out of `01-build-kernel.sh`, where it produced a genuine
second benefit — repackaging without rebuilding — because the split followed a
real seam rather than a wish to deduplicate.

Duplication that is under the cap and has not caused a bug is cheaper than the
coupling that removes it. Two harnesses that each read as one file beat two that
each need a third file open to follow.

**Shape, when the trigger fires.** An **executable helper** the callers invoke as
a subprocess. **Never a sourced library.** Sourcing needs a
`# shellcheck source=` directive *and* `--external-sources` to stay clean; the CI
gate runs plain `shellcheck -S style` with no flags and no `disable=` directives
anywhere in the tree, and it stays that way. A helper invoked as a command is
analysed as its own file, and the callers stay clean without a single flag.

**Interface.** A helper returns data on **stdout** and status via its exit code.
It must not try to set variables in its caller — as a subprocess it cannot, and
that constraint is the point rather than a limitation to work around. Config
detection returns the configuration letter on stdout:

```bash
CONFIG=$(./bench-detect-config.sh)      # prints A, B or C; non-zero if unsure
```

**Current headroom** (measured 2026-08-03): `tle-updater.sh` **397**,
`run-latency-bench.sh` **396**, `install-kernel.sh` 383, `run-sdr-bench.sh` 363,
`01-build-kernel.sh` 319, `02c-sdr-userspace.sh` 298. Two files now sit within
four lines of the cap, so the next change to either is what fires the trigger —
and for `run-latency-bench.sh` the helpers are already written, so that conversion
is cheap. `tle-updater.sh` is now the
closest to the cap at 3 lines of headroom, and it is the awkward one: it shares
nothing with the harnesses, so the helpers above do it no good and it would
extract something else entirely. Whatever is added to it next is what decides the
seam.

**This table is the only place in this document that carries live line counts.**
Other sections record sizes *as of the change they describe* and say so. Two
sections tracking the same moving number is how this drifted: the split note in
"Carried forward from the audit" had `02c-sdr-userspace.sh` at 148 while it was
actually 298 — an error large enough to hide a fired trigger, in the one table
the trigger is read from.

**Custom GNU Radio blocks — the rule.** Write a custom block only when (a) the
catalog has no part — a protocol or format no existing block handles — or
(b) we need a *gauge in the pipe* — instrumentation measuring the stream
itself. Never rewrite existing demodulators as features (fine as private
learning exercises), and never write a Doppler block — gr-satellites already
provides Doppler correction. Prototype blocks in Python; port to C++ only if
they can't keep up at full sample rate. Planned blocks live under `gr-kosmos/`
except where noted (see Phase 2c for the independence rule on IceSickle).

---

## Architecture & Extensibility (adopted 2026-07-30)

*There is no Phase 5 — this is a standing design principle rather than a phase of
work, so it sits with the other rules rather than at the end of the plan.*

### Openness is architectural, not a feature

KosmOS is open to new satellites because of what it is built from, not because
anyone added an "extensibility" feature to it:

- **SoapySDR** is a hardware abstraction layer — the radio is swappable
- **GNU Radio** is a software-defined modem — the waveform is code, not silicon
- **Linux networking** carries whatever comes out of the other end

Nothing in that chain is specific to any one spacecraft. A new bird is new
*parameters*, not new plumbing. The openness is emergent; the job is to avoid
designing it away.

### Satellite profiles — the extension point

The link layer is structured as modular **satellite profiles**: driver-like
descriptors, one per satellite or constellation.

| Field | What it carries |
|---|---|
| Frequency | downlink centre, bandwidth |
| Modulation | APT (analogue FM), LRPT (QPSK), HRPT, … |
| Protocol | framing, FEC, CRC |
| Flowgraph | the GNU Radio graph or SatDump pipeline that decodes it |

**Adding a satellite means writing a profile. The core is untouched.** That is
the whole claim, and it is the thing that has to keep being true: the day adding
a bird requires editing the capture path, the abstraction has failed, and the fix
is the abstraction — not a special case bolted beside it.

Profiles belong in `config/profiles/`, alongside the SDR++ and SatDump configs.
**Document the extension point when the first profile is written**, so "add a
satellite" is a known operation rather than tribal knowledge.

**What a profile describes today is reception.** The RTL-SDR is a receiver, so
the current shape is downlink-only. Transmit is not a software change: it needs
different hardware (HackRF, PlutoSDR) and, on essentially every band worth using,
a licence. The profile shape has room for an uplink section — and per the rule
below, nothing gets written into it until there is hardware to test it against.

### Design rule: extension point, not scaffolding

**Future-proof with a clean abstraction and a documented extension point. Build
nothing for systems that do not exist.**

No empty "commercial provider" modules. No stub hooks awaiting a partnership. No
abstract base class with exactly one implementation. This is the same discipline
that *deleted* `OUTPUT_DIR` from the kernel build script rather than wiring it up
(see the comment still standing at `kernel/01-build-kernel.sh:60`): dead code
that looks like readiness is worse than nothing there at all, because it implies
a capability nobody has tested.

What KosmOS targets is **open or published interfaces**:

- an open-source constellation — published specs, write a profile, done
- any commercial provider that publishes an SDR-accessible interface

A closed constellation's door is theirs to open. KosmOS stays *ready* — the
abstraction clean, the extension point documented — not *pre-plumbed*.

### Two different things get called "commercial"

Separated here so they are not conflated later, in either direction.

**Routing KosmOS traffic *through* a commercial terminal — already works,
trivially.** A Starlink dish, an LTE modem, a hotel Ethernet port: these are
uplinks. Plug one in and KosmOS uses it like any other network interface. That is
Linux networking and there is nothing to build. It is also the genuinely useful
case — a field station backhauling decoded data over whatever link exists.

**Making KosmOS's SDR *be* a commercial terminal — not possible, and not
future-proofable.** A Starlink user terminal is proprietary phased-array hardware
running a closed waveform in licensed spectrum. The obstacles are hardware,
cryptography and law, in that order, and none of them is the kind of thing a
software abstraction bridges. There is no key that turns an RTL-SDR or a HackRF
into a Starlink modem, and no amount of architectural readiness changes it.

Writing that down plainly costs nothing now and saves walking it back from a
README that implied otherwise.

---

## Proof of Claim: RT Kernel Benchmark (v0.25 — Before the SATCOM Stack)

**The question:** does PREEMPT_RT measurably reduce scheduling latency and dropped
SDR samples versus the stock Pi kernel on identical hardware?

The dual-boot setup makes this an A/B test — but the A/B must be genuinely
isolated before any published number is generated.

### Benchmark Integrity Prerequisites (do these FIRST)

- [x] **Isolate the kernels with `os_prefix=`** — *done, `43d8368`.* Kernel, DTBs,
  overlays and cmdline.txt now live in their own boot-partition directory;
  `config.txt` is the only stock file modified, and it is written last, after
  every required file is confirmed present. Revert is a verified byte-identical
  restore.
- [x] **Settle the tickless claim** — *done, `43d8368`.* `nohz_full` and
  `rcu_nocbs` are appended to the KosmOS command line, default CPUs 1-3 with
  CPU 0 left as housekeeping. Configurable via `NOHZ_FULL_CPUS`, which the
  benchmark matrix below relies on.
- [x] **Make verification possible** — *done, `147fa10`.* `CONFIG_IKCONFIG` +
  `CONFIG_IKCONFIG_PROC` added, and the `/proc/config.gz` read fixed (it was
  grepping the compressed bytes, which can never match).
- [x] **Rebuild with `CONFIG_LOCALVERSION="-kosmos"`** — *done 2026-07-31 on
  pi-server, installed and booted by 2026-08-02.* The build produced
  **`6.12.98-kosmos+`**, the localversion took effect, and the module directories
  are separated. `02a-verify-kernel.sh` now reports **7 passed, 0 failed** on the
  running kernel — the FAIL this entry used to predict was against the stock
  kernel and is gone.
- [x] **Install the tooling** — *done, `43d8368`.* `rt-tests` and `stress-ng`
  added behind their own prompt in 02-post-install.sh, deliberately separate
  from the SDR userspace install so Test 1 can run without building a toolchain
  it does not need.
- [x] **Control for thermal throttling** — *added `5b44fe6`.* **This is about the
  benchmark's validity, not about build cost or about anything a user of a flashed
  image would ever encounter.** A 35-minute `cyclictest` run under `stress-ng` is
  sustained all-core load, and on this hardware that saturates the cooling — the
  kernel build reached 84.2 °C with the fan already at 4/4, which is the evidence
  that it does.
  Why it corrupts the result rather than merely slowing it: a throttled run does
  not fail loudly, it **inflates the tail latency** — and worst-case tail under
  load is *the* number this benchmark exists to publish. Two configurations run at
  different temperatures produce a delta that is partly thermal and gets attributed
  entirely to the kernel. `benchmarks/thermal-state.sh` therefore gates each run on
  a starting temperature (≤65 °C, bounded by a 600 s wait so a warm room cannot
  hang the suite), samples throughout, and flags any throttling into the results.
  **Consequence for running the matrix: do not chain the three configurations back
  to back** — the gate will refuse a hot start, and cool-down is part of the
  schedule.

### Configuration Matrix (decided 2026-07-29)

Three boot configurations, so each change is attributable to exactly one cause:

| Config | Kernel | `NOHZ_FULL_CPUS` | What it isolates |
|---|---|---|---|
| **A** | stock Pi kernel | n/a | baseline |
| **B** | KosmOS (PREEMPT_RT) | `""` | RT with no core isolation |
| **C** | KosmOS (PREEMPT_RT) | `"1-3"` | RT plus full dynticks |

**Report `B − A` as the PREEMPT_RT result. Report `C − B` as the isolation
result. Never report `C − A`** — that conflates two independent changes into one
number and attributes the combined effect to whichever is being argued for.

**In config C, `cyclictest` must be pinned to the isolated cores.** Unpinned it
will schedule on CPU 0, the housekeeping core, which is not tickless — so config
C measures config B and the isolation delta reads as zero.

**Decided 2026-07-30: pin in *every* configuration, and run unpinned in every
configuration too.** Pinning only in C is necessary but not sufficient — a pinned
run in C compared against an unpinned run in B is two different experiments, and
the affinity change gets credited to dynticks. `B − A` comes from the unpinned
rows, `C − B` from the pinned rows. Costs about 35 minutes per configuration
rather than 18; that is the price of an attributable delta, and it is not to be
traded away for runtime. `benchmarks/run-latency-bench.sh` implements this.

```bash
# unpinned — whole machine
cyclictest -S -l1000000 -m -p90 -i200 -h400 -q

# pinned — CPUs 1-3. The -a/-t are not redundant with taskset: -S derives one
# thread per *online* CPU and pins thread 0 to CPU 0, outside the mask, and fails.
taskset -c 1-3 cyclictest -a 1-3 -t 3 -l1000000 -m -p90 -i200 -h400 -q
```

Switching between B and C means editing `NOHZ_FULL_CPUS` in `install-kernel.sh`
and re-running it, or editing `kosmos/cmdline.txt` on the boot partition
directly. Switching between A and B/C means commenting the two directives in the
KosmOS block of `config.txt`. Nothing else differs between any of the three
boots — that is what `os_prefix` bought.

### Methodology

**Test 1 — Scheduling latency (no SDR hardware needed):**
- Tool: `cyclictest` from the `rt-tests` package — the standard RT kernel benchmark
- Measure avg and **max** wakeup latency over ≥1M iterations, at RT priority
- Run three conditions per kernel: idle, CPU-loaded (`stress-ng --cpu 4`),
  and IO-loaded (`stress-ng --io 2 --vm 1`)
- The number that matters is **max latency under load** — worst case, not average.
  RT kernels win on the tail, not the mean.

**Test 2 — Dropped SDR samples (needs the RTL-SDR dongle):**
- Tool: `rtl_test -s <rate>` reports lost samples/bytes over a fixed duration
- Sweep sample rates: 1.024, 2.048, 2.4, 3.2 MS/s × fixed 10-minute runs
- Repeat idle and under `stress-ng` load (simulates a decode job running
  during a live capture — the realistic worst case)
- Metric: lost samples per 10-minute run, per rate, per kernel

**Test 3 — Real-world decode quality (needs dongle + antenna):**
- Live NOAA APT captures via SatDump with background load running
- Compare dropout lines / decode quality across passes on each kernel
- Weakest test (passes aren't identical) but the most convincing demo

**Instrumentation upgrade — the first custom GNU Radio block:**
- [~] **`gr-kosmos` sample-discontinuity probe** — an inline block that watches
  the sample stream for discontinuities and logs a timestamped record of every
  gap (the "gauge in the pipe"). *Scaffolded: block skeleton, GRC definition and
  a development installer exist and are consistent with each other. No detection
  logic, and nothing has run under GNU Radio.*
  - **The design note worth keeping:** a `sync_block` cannot see a gap by
    inspecting its input buffer — the buffer is always contiguous no matter what
    the radio dropped. The gap is visible only in the `rx_time` stream tags a
    hardware source emits on overflow, and the measurement is a comparison
    between the timestamp in a new tag and the time predicted from the previous
    tag plus samples consumed since. `rx_time` values are PMT pairs of
    (whole seconds, fractional seconds), not floats. All written down in
    `gr-kosmos/python/kosmos/discontinuity_probe.py`.
  - No `CMakeLists.txt` on purpose: a full OOT module's build system is
    generated by `gr_modtool newmod kosmos`, not hand-written. Several hundred
    lines of version-specific CMake that nobody has run would look authoritative
    and fail on the Pi.
  - Upgrades Tests 2–3 from synthetic (`rtl_test` streaming to nowhere) to
    **measured-in-production**: every real capture becomes a benchmark run
  - No published RT-vs-stock comparison in the SDR space has in-flowgraph
    instrumentation — this is part of what makes the result novel
  - Tiny scope: watch, count, log — no DSP math; ~150 lines, well inside the
    400/60 rules. Prototype in Python (low per-sample work, may be fast
    enough); port to C++ if it can't keep pace
  - Does NOT jump the queue: build alongside the benchmark or right after
    v0.3 when GNU Radio lands

**Deliverable:** `benchmarks/BENCHMARKS.md` — methodology, raw numbers, tables,
and a plain-language conclusion. Publishable either way: a confirmed win is the
project's headline claim; a null result gets documented honestly and the
positioning leans harder on pillars 2 and 3.

---

## What Exists Today (v0.1–v0.2, audited 2026-07-29)

✅ Custom kernel `6.12.79-v8-16k+` with `PREEMPT_RT` — **confirmed on hardware
   2026-07-29** via `uname -v` = `#1 SMP PREEMPT_RT Thu Apr  2 14:11:03 CDT 2026`.
   Note **`/sys/kernel/realtime` does not exist** on this kernel: that file came
   from the out-of-tree RT patchset, and since RT merged into mainline in 6.12 it
   is no longer created. The old check tested only for that file, so it reported
   NOT DETECTED on a genuinely RT kernel — a false negative on the project's
   central claim. Fixed to check `/proc/config.gz`, then `uname -v`, then the
   legacy file.
   *This build is the April RF-Linux-era kernel, and it lives on altai (now the
   production host). It proved PREEMPT_RT works — a v0.1 result — but the bench
   box (pi-server) gets a fresh `-kosmos` build at step 9; it is not carried over.*
✅ Real-time scheduling (1000Hz tick, high-res timers)
✅ Full dynticks (`CONFIG_NO_HZ_FULL`) — **active and confirmed on hardware
   2026-08-02.** `/sys/devices/system/cpu/nohz_full` reads `1-3` on the running
   kernel, which is the kernel itself reporting the isolated set rather than an
   inference from the command line.
   *Was briefly marked ⚠️ earlier the same day, and the reason is worth keeping.
   It had been ✅ since `43d8368` on the strength of that commit adding the
   `nohz_full`/`rcu_nocbs` append to `install-kernel.sh` — but the install that
   actually ran used `NOHZ_FULL_CPUS=""`, so the directives were absent from the
   booted command line for days while this document called the feature activated.
   The code existed; the activation did not. It survived four commits and a
   hardware pre-flight, which is exactly why "verified, not written" is the rule.*
✅ Kernel version string — the step-9 rebuild happened 2026-07-31 and produced
   **`6.12.98-kosmos+`**, so `CONFIG_LOCALVERSION` took effect and this kernel's
   modules land in their own directory. Built from the pinned commit
   `f5a99b95`. ✅ **Installed and booted — confirmed on hardware 2026-08-02.**
   pi-server runs `6.12.98-kosmos+`; `02a-verify-kernel.sh` reports **7 passed, 0
   failed** (PREEMPT_RT in `uname -v`, 1000 Hz, governor `performance`, USB, AX.25,
   `/proc/config.gz`). The RT kernel boots on real hardware and the localversion
   separated the module directories as intended.
   *(This entry read "not yet installed or booted" until 2026-08-02. The install
   had in fact already happened; step 9 flagged it as unverifiable from off-box and
   it went unchecked. Nothing was lost — but the plan built on top of it was wrong
   for several days, which is the cost of carrying an assumption as a status.)*
⚠️ Performance CPU governor — **kernel default only; NOT what runs.** Observed on
   hardware 2026-07-29: the running governor is `ondemand` despite
   `CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y`, because Pi OS / Debian override it
   at boot from userspace. "Always max clock" is currently false. Fixing it needs
   a boot-time unit, not a kernel rebuild. Matters for the benchmark: ondemand
   adds frequency-ramp latency on top of scheduling latency, so pin it to
   performance on **both** kernels before publishing, or say the numbers include
   ramp effects.
✅ AX.25 / amateur radio / packet radio stack compiled as modules
   (verify check fixed `147fa10` — it ran `modprobe` without `sudo` and reported
   a false negative on kernels where AX.25 was fine)
✅ RTL-SDR driver stack (RTL2832 SDR + R820T tuner)
✅ USB subsystem optimized for SDR hardware
✅ Stripped unnecessary subsystems (GPU drivers, NFC, BT, ISDN, etc.)
✅ librtlsdr (RTL-SDR Blog fork, v4 compatible)
✅ rtl_433 (multi-protocol RF decoder)
✅ dump1090 (ADS-B aircraft tracking)
✅ predict (satellite pass prediction)
   (✅ fixed — `automation/tle-updater.sh` writes `~/.predict/predict.tle`, the
   file predict actually reads. It also stopped fetching a CelesTrak group that
   does not exist; see Phase 1b.)
✅ Russian locale (ru_RU.UTF-8) — **optional/skippable personal config**, not a
   core feature (README has it right; this doc previously overclaimed it)
✅ Dual-boot, now genuinely isolated — `os_prefix=` landed `43d8368`. Stock
   kernel, DTBs, overlays and cmdline.txt are all left byte-identical; only
   `config.txt` is touched, and revert is a verified exact restore
✅ Build kit on GitHub (kernel build script, config fragment, installer, post-install)

---

## Roadmap: What Needs to Be Built

### Phase 1: "Ground Station" — Core SATCOM Capability
*Goal: Receive and decode real satellite signals*

#### 1a. Satellite Reception Stack

*Scripts written and linted (`03-satcom-stack.sh` sequencing `03a`/`03b`/`03c`),
pinned from line one. **No build has been executed** — that needs the Pi, so the
first run on pi-server is the test.*

- [x] **SatDump** — The all-in-one satellite processor — *`03b-satdump.sh`,
  pinned to release 1.2.2 (`7aef0fe8441b`), built from source, prefix
  `/usr/local`. Written, not yet built.*
  - Decodes NOAA APT/HRPT, GOES HRIT/EMWIN, Meteor-M LRPT, MetOp, FengYun
  - Handles capture → demodulation → decoding → image generation in one pipeline
  - This is the centerpiece tool for the SATCOM focus
- [x] **GNU Radio + gr-osmosdr** — The DSP framework — *`03a-gnuradio-stack.sh`,
  from apt at pinned versions rather than source. The dependency chain is a
  multi-hour build on four A76 cores, Debian ships the current 3.10.x series,
  and apt authenticates against a signed InRelease file. Reconsider only when a
  decoder needs something Debian's build lacks.*
  - For building custom signal processing flowgraphs
  - Required for advanced demodulation (Iridium, custom protocols)
- [x] **SoapySDR** — Hardware abstraction layer — *apt, pinned, in `03a`. The
  RTL-SDR Soapy module is deliberately **not** installed: RTL-SDR reaches every
  tool through the Blog fork of librtlsdr in `/usr/local`, and stacking Soapy
  modules is a documented conflict source.*
  - Lets all SDR tools talk to any SDR hardware through one API
  - Critical for HackRF support when you upgrade from RTL-SDR
  - Think of it as a HAL (Hardware Abstraction Layer) — same concept
    as how your kernel talks to different NICs through a common interface

#### 1b. Orbit Prediction & Tracking
- [x] **TLE auto-updater** — *`automation/tle-updater.sh`. Written and tested
  against the live CelesTrak API; not yet installed on a timer.*
  - Predict path bug fixed: it writes `~/.predict/predict.tle`, the only file
    predict reads. The old download target was never read by anything.
  - **Two CelesTrak facts found while writing it, both verified 2026-07-29:**
    `GROUP=noaa` is not a valid group — it returns HTTP 200 with
    `Invalid query: ... (GROUP=noaa not found)`, which `wget` happily writes to
    disk as 61 bytes of prose. And `GROUP=weather`, which *is* valid, does not
    contain NOAA 15/18/19 at all, only NOAA 20/21. The APT satellites are
    reachable only by catalogue number. Both the README one-liner and
    02c's seed download were fetching the invalid group; both fixed.
  - Every download is validated against the mod-10 checksum in column 69 of each
    TLE line before it is installed. That is the only integrity check this data
    admits — there is no digest to pin on something that changes hourly — and it
    catches the HTTP-200-error-page case, truncated transfers and flipped digits.
  - predict tracks at most 24 satellites from that one file, so the predict set
    is an explicit catalogue-number list and the bulk groups go to
    `~/.config/satellite-tle/` for gpredict and SatDump instead.
  - Still to do: put it on a timer (cron line is in the script header).
- [ ] **Rotator control support** (hamlib / rotctld)
  - For automated antenna pointing during passes
  - Uses serial/USB to talk to antenna rotator hardware
  - Not needed for omnidirectional antennas, but essential for
    directional (dish/yagi) tracking of specific satellites

#### 1c. Spectrum Analysis & Visualization
- [x] **SDR++** — Modern GUI SDR receiver — *`03c-sdrpp.sh`, pinned to master
  `8c9f5ee8fe40` (2026-07-05). Pinned to a commit rather than a tag on purpose:
  upstream's only release tag is `nightly`, which moves, and the newest numbered
  tag (1.0.4) is from 2021. Written, not yet built.*
  - Waterfall display, multi-VFO, plugin architecture
  - This is your "Wireshark with live capture" equivalent for RF
- [ ] **inspectrum** — Lightweight spectrogram viewer for recorded files
  - Post-capture analysis of I/Q recordings
  - Like opening a pcap in Wireshark after the capture
- [ ] **Terminal spectrum tools**
  - rtl_power → CSV heatmap pipeline (Python/matplotlib)
  - Custom script to generate live terminal waterfall
  - Useful for headless/SSH field work where GUI isn't available

### Phase 2: "Signal Intelligence" — Protocol Decoding & Analysis
*Goal: Decode specific satellite and RF protocols*

#### 2a. Satellite Protocol Decoders
- [ ] **Iridium toolkit** (gr-iridium + iridium-toolkit)
  - Decode Iridium satellite bursts (1616-1626.5 MHz)
  - Requires GNU Radio
  - Career-relevant: Iridium is used in maritime, aviation, military SATCOM
- [ ] **GOES/GRB decoder pipeline**
  - GOES-16/17/18 geostationary weather satellites
  - Higher resolution than NOAA polar orbiters
  - Requires a dish antenna and filtered LNA (L-band, 1694 MHz)
- [ ] **Inmarsat decoder** (for STD-C messages)
  - Maritime distress and safety communication
  - L-band (1525-1559 MHz)
  - Career-relevant: core SATCOM infrastructure

#### 2b. Terrestrial Protocol Decoders
- [ ] **multimon-ng** — Multi-mode digital decoder
  - POCSAG pagers, FLEX, EAS (Emergency Alert System), DTMF
  - Like running multiple protocol parsers on a single capture
- [ ] **direwolf** — Software TNC for AX.25 / APRS
  - Decodes and generates packet radio
  - Integrates with the kernel AX.25 stack you already compiled
  - Creates a real network interface — `ax0` appears in `ip a`
- [ ] **gr-ais** — Automatic Identification System decoder
  - Ship tracking (162 MHz) — the maritime version of ADS-B
  - Career-relevant: maritime domain awareness

#### 2c. RF Reverse Engineering & Custom Blocks
- [ ] **Universal Radio Hacker (URH)** — Signal reverse engineering
  - Visual protocol analysis for unknown RF signals
  - Like Wireshark's "decode as" feature for RF
- [ ] **gr-lora** — LoRa demodulator for GNU Radio
  - Generic LoRa PHY demodulation from the Linux side
  - Prerequisite for the IceSickle decoder below
- [ ] **IceSickle frame decoder** (custom block — but see independence rule)
  - Parses the ESP32-S3 IceSickle device's own LoRa framing/payload format —
    no catalog part will ever exist for a homegrown protocol
  - Closes an independent-verification loop: the embedded device transmits,
    the ground station verifies from outside the firmware — RF unit tests
  - **Independence rule (2026-07-29):** KosmOS stays independent. This
    decoder is an out-of-tree GNU Radio module (`gr-icesickle`) that *runs
    on* KosmOS but doesn't ship *in* it — it likely lives in the IceSickle
    repo. KosmOS is the platform; IceSickle support is an app. The distro
    never depends on it, references it at most as a "built on KosmOS"
    example. Revisit when Phase 2 starts.
- [ ] **Upstream contribution to gr-satellites** (custom decoder, community PR)
  - Pick a newly-launched cubesat that's transmitting but not yet covered,
    write the decoder, submit the PR
  - Teaches real telemetry formats (frame sync, FEC, CRC) — core SATCOM
    job knowledge — and a merged PR in the standard satellite-decoding
    project is a public, verifiable credential
  - Note: gr-satellites already handles Doppler correction and hundreds of
    satellites — never duplicate what it has; contribute to it instead

### Phase 3: "Operations Center" — Automation & Integration
*Goal: Continuous monitoring, logging, and remote access*

*This phase is the soul of the project — it's what turns a box of tools into an
appliance. Phases 1–2 build the parts; Phase 3 makes them run themselves.*

#### 3a. Automated Capture Pipeline
- [ ] **Systemd service for rtl_433** — Always-on RF monitoring
  - JSON output → log file and/or database
  - Like running tcpdump as a daemon with rotation
- [ ] **Automated satellite pass capture**
  - Script: check TLEs → calculate next pass → start recording at AOS
    (Acquisition of Signal) → stop at LOS (Loss of Signal) → decode
  - Cron-triggered or systemd timer
  - This is the "set it and forget it" pipeline
- [ ] **ADS-B feed to FlightAware/FlightRadar24**
  - Run dump1090 as a service, feed data to tracking networks
  - Get a free FlightAware Enterprise account in exchange for data
  - Real operational experience with persistent data feeds

#### 3b. Data Logging & Visualization
- [ ] **InfluxDB + Grafana** (lightweight, or SQLite + custom dashboard)
  - Store decoded RF data (weather sensor readings, aircraft positions)
  - Visualize trends, signal strength over time, RF environment mapping
  - Career-relevant: monitoring dashboards are standard in SATCOM ops
- [ ] **RF environment baseline script**
  - Periodic rtl_power scans to map your local spectrum
  - Detect new emitters, track interference sources
  - Like running a continuous network scan to baseline normal traffic

#### 3c. Remote Access & Field Operations
- [ ] **WireGuard VPN** — Encrypted remote access
  - Already compiled as kernel module
  - Configure for remote Pi access over cellular/WiFi
  - Career-relevant: secure remote SATCOM terminal management
- [ ] **WiFi AP mode** — Pi broadcasts its own network
  - hostapd + dnsmasq configuration
  - Connect from MacBook in the field without existing infrastructure
- [ ] **Web dashboard** — Browser-based control panel
  - Status page showing: kernel info, SDR device status, active captures,
    next satellite passes, system health
  - Accessible from any device on the local network
  - Could be a simple Flask/FastAPI app or static HTML + JS
- [ ] **Tor bridge (optional module, OFF by default)** — `field/tor-bridge-setup.sh`
  - tor + obfs4/lyrebird pluggable transport — pure userspace, apt-installable,
    coexists fine with the RT kernel (no kernel work needed)
  - Home-base role, not field-kit role: a bridge wants an always-on unmetered
    uplink and a reachable port — not cellular, not battery
  - Turns the box from passive receiver into a public-facing network service:
    wider attack surface. Ship disabled, firewall it away from the capture
    pipeline, document the tradeoff.
  - **Decoupled from the production bridge (see Hardware Topology).** This module
    is a distro feature to build and test; the live obfs4 bridge lives on altai
    and is never touched by KosmOS development. When dogfooding this module,
    generate a **throwaway test identity** — never reuse the production bridge's
    keys or fingerprint. A test bridge and the real one must never share identity.

### Phase 4: "Hardened Platform" — Reliability & Distribution
*Goal: Make KosmOS reproducible and distributable*

#### 4a. Image Building
- [ ] **Automated image builder script**
  - Takes a fresh Pi OS Lite image → applies kernel → installs all tools
  - Produces a flashable `.img.gz` file
  - Anyone can download and flash to SD card
  - Like building a Docker image but for the whole OS
- [x] **Version pinning** — *pulled forward; see Pillar 3. `02c-sdr-userspace.sh`
  and `03-satcom-stack.sh` both pin every source they build.*
- [x] **Checksum verification** — every git source is verified against its pinned
  commit after checkout, which is a content check over the whole tree. apt
  packages are verified by apt against the archive's signed Release file. No
  script fetches a loose file, so there is no artifact left needing a standalone
  SHA-256 digest; if one is ever added, the digest goes in beside its URL.
- [x] **Pin the kernel source too** — ✅ **done at the step-9 rebuild, as planned.**
  `KERNEL_COMMIT="f5a99b95354d38db209003a7d00560e5091ba94a"` in
  `01-build-kernel.sh:58`, and the same SHA is recorded in
  `benchmarks/BENCHMARKS.md` — a published benchmark has to name the kernel it
  measured.
  **The pin was set *before* the build, not captured after it**, which is the
  stronger of the two orderings: the tree that compiled is provably the tree named
  in the doc, because `kernel-commit` inside the package matches the pin and the
  build aborts if the checkout lands anywhere else. Capturing afterwards would
  have recorded a SHA that merely *claimed* to describe the build.
  Waiting until step 9 was also correct — pinning earlier would have changed which
  kernel the v0.25 A/B measures.
  Meanwhile every build now *records* what it built: the SHA is printed, written
  into the package as `kernel-commit`, and an unpinned build prints the exact
  `KERNEL_COMMIT="..."` line to paste back. Without that there would be nothing
  to pin *to* after the fact — a version string does not identify a kernel, since
  two builds weeks apart off one branch report the same one.

#### 4b. Configuration Management
- [ ] **First-boot setup wizard** (CLI-based)
  - Set hostname, callsign, location (lat/lon for satellite predictions)
  - Configure WiFi, set locale
  - Generate SSH keys
- [ ] **Dotfiles / config templates**
  - Pre-configured `.gnuradio/`, SatDump profiles, SDR++ configs
  - Tuned for common SATCOM frequencies and satellite protocols
  - Like shipping a switch with a sane default config

#### 4c. Documentation
- [ ] **Man pages or built-in help** for KosmOS-specific scripts
- [x] **Frequency reference guide** — *`config/frequencies.md`.* Weather sats,
  SATCOM (Iridium/Inmarsat), ADS-B/AIS, amateur, ISM, plus the wavelength table
  the antenna guide's element lengths come from. Rows likeliest to have drifted
  are marked ⚠️ rather than presented as settled — a cheatsheet that looks
  authoritative and is six months stale is worse than one that says so.
- [x] **Antenna guide** — *`config/antennas.md`.* V-dipole (with the geometry and
  why 120° horizontal), QFH/turnstile, dish + L-band LNA, Yagi + rotator, λ/4
  ground plane, discone, HF, and a field-kit section. Leads with the two things
  that matter more than antenna choice — polarisation and siting — and with the
  point that receive-only setups need no SWR matching, which is where money
  otherwise goes.

---

## Career Alignment: SATCOM Job Skills Map

Based on actual SATCOM job postings, here's how KosmOS maps to career skills.
CCNA is explicitly listed as valued in SATCOM roles — your networking background
is a direct asset.

| Job Requirement | Where You Learn It in KosmOS |
|----------------|------------------------------|
| RF engineering / spectrum analysis | SDR++, rtl_power, GNU Radio flowgraphs |
| Signal processing & modulation | GNU Radio DSP blocks, SatDump demod chains |
| Satellite systems & orbital mechanics | predict, TLE management, pass scheduling |
| Network protocols | AX.25 stack, IP-over-radio, your CCNA knowledge |
| Troubleshooting signal issues | Spectrum analysis, SNR measurement, Doppler correction |
| Linux/VM environments | Building the entire OS from kernel up |
| Satellite modems & link budgets | GNU Radio modem implementations, GOES/Inmarsat reception |
| Spectrum analyzers | rtl_power, SDR++ waterfall, inspectrum |
| Equipment configuration | Kernel config, SDR gain/frequency tuning, antenna selection |
| Security protocols | WireGuard VPN, encrypted remote sessions |
| Monitoring & logging | Grafana dashboards, automated capture pipelines |
| TDMA/FDMA concepts | Iridium (TDMA) and Inmarsat (FDMA) decoding |
| Documentation | This entire project is self-documenting |
| Performance engineering & benchmarking | RT kernel A/B benchmark (cyclictest, dropped-sample analysis, custom probe block) |
| DSP development | Custom GNU Radio blocks (probe, decoders), gr-satellites contribution |

### Certifications That Stack Well with KosmOS Experience

1. **CCNA** (already studying) — Network fundamentals, directly relevant
2. **CompTIA Security+** — Required for most DoD SATCOM positions
3. **Amateur Radio License** (Technician → General → Extra)
   - Legal requirement for transmitting, but the study material teaches
     RF theory that's directly applicable to SATCOM
   - Technician license is easy to earn and opens up packet radio, APRS,
     satellite uplinks
4. **CompTIA Network+** — Another commonly listed SATCOM cert
5. **Certified Wireless Network Professional (CWNP)** — RF planning skills

---

## Project Milestones

```
v0.1   ✅ DONE    Custom RT kernel boots on Pi 5
v0.2   ✅ DONE    SDR userspace tools installed (rtl_433, dump1090, predict)
v0.25  ⏳ ACTIVE  RT kernel benchmark published (proof of claim — BEFORE the
                 SATCOM stack; Test 1 needs no dongle)
                 Harnesses + methodology written, thermal control added, kernel
                 BUILT and pinned (6.12.98-kosmos+, f5a99b95) 07-31, INSTALLED
                 and BOOTED 08-02 — 02a verification 7/0 on real hardware.
                 TEST 1 COMPLETE: all 18 rows measured across A/B/C.
                 Headline — worst-case latency under IO load 6262 us (stock)
                 to 175 us (RT), a 35.8x reduction; averages identical, so the
                 whole win is in the tail. Core isolation is a trade, not a
                 free upgrade: 8.1x better on isolated cores under IO load,
                 slightly worse at idle, and it puts a stock-sized tail back
                 on the housekeeping core. Remaining for v0.25: capture
                 `uname -v`, and Test 2 (dropped samples), which waits on the
                 RTL-SDR v4 dongle.
v0.3   ......    SatDump + GNU Radio + SDR++ (first satellite decode, pinned)
                 + gr-kosmos discontinuity probe (first custom block)
                 Install scripts written and pinned; no build has run.
                 Probe is a skeleton with no detection logic.
v0.4   ......    Automated capture pipeline (scheduled sat passes)
v0.5   ......    Protocol decoders (Iridium, AIS, APRS/direwolf)
                 + gr-satellites upstream PR; revisit IceSickle decoder
v0.6   ......    Field deployment kit (WiFi AP, WireGuard, web dashboard,
                 optional Tor bridge module)
v0.7   ......    Monitoring stack (logging, Grafana, RF baseline)
v0.8   ......    Image builder (reproducible, distributable .img.gz)
v1.0   ......    Full release — documented, tested, flashable image
```

---

## Repository Structure

`✅` exists as of the 2026-07-30 overnight branch, `·` still to build.

```
KosmOS/
├── ✅ README.md                 # Project overview and quick start
├── ✅ ROADMAP.md                # This document (must be tracked in the repo)
├── ✅ LICENSE                   # GPLv3 — the kernel stays GPL-2.0 upstream
├── ✅ .gitattributes            # Keep — prevents CRLF breaking shebangs
├── .github/workflows/
│   └── ✅ shellcheck.yml        # CI gate: shellcheck at zero, pinned version
├── kernel/
│   ├── ✅ 01-build-kernel.sh    # Kernel build script
│   ├── ✅ package-kernel.sh     # Stages the tarball; re-runnable without a rebuild
│   ├── ✅ sdr-rt.config         # Kernel config fragment (GPL-2.0-only, see LICENSE)
│   └── ✅ install-kernel.sh     # Pi kernel installer
├── benchmarks/
│   ├── ✅ BENCHMARKS.md         # RT vs stock — methodology + build data; result tables empty
│   ├── ✅ run-latency-bench.sh  # cyclictest: A/B/C x idle/CPU/IO x whole/pinned
│   ├── ✅ run-sdr-bench.sh      # rtl_test dropped-sample sweep
│   ├── ✅ detect-config.sh      # prints A/B/C from the running kernel (helper)
│   ├── ✅ governor.sh           # read/set the CPU governor (helper)
│   └── ✅ thermal-state.sh      # temperature gate + throttle detection (helper)
├── gr-kosmos/                   # Custom GNU Radio blocks (OOT module)
│   ├── ✅ README.md             # Includes why there is no CMakeLists.txt
│   ├── ✅ install.sh            # Development install (.pth + GRC yml)
│   ├── ✅ grc/                  # GRC block definitions
│   └── ✅ python/kosmos/        # discontinuity probe — skeleton, no logic yet
├── userspace/
│   ├── ✅ 02-post-install.sh    # Sequencer over 02a-02d
│   ├── ✅ 02a-verify-kernel.sh  # Kernel verification, read-only
│   ├── ✅ 02b-bench-tools.sh    # rt-tests + stress-ng
│   ├── ✅ 02c-sdr-userspace.sh  # librtlsdr, rtl_433, dump1090, predict — pinned
│   ├── ✅ 02d-locale-ru.sh      # Optional Russian locale
│   ├── ✅ 03-satcom-stack.sh    # Sequencer over 03a-03c
│   ├── ✅ 03a-gnuradio-stack.sh # GNU Radio + gr-osmosdr + SoapySDR (apt, pinned)
│   ├── ✅ 03b-satdump.sh        # SatDump (source, pinned)
│   ├── ✅ 03c-sdrpp.sh          # SDR++ (source, pinned)
│   └── ·  04-protocol-decoders.sh  # Iridium, AIS, direwolf (Phase 2)
├── automation/
│   ├── ✅ tle-updater.sh        # TLE refresh; writes ~/.predict/predict.tle
│   ├── ✅ kosmos-governor.service  # Pins the CPU governor at boot
│   ├── ✅ kosmos-set-governor.sh   # The governor write itself
│   ├── ✅ install-governor.sh   # Installs the unit; masks ondemand.service
│   ├── ·  sat-pass-scheduler.sh # Automated satellite capture
│   ├── ·  rtl433-service.conf   # systemd unit for always-on RF monitoring
│   └── ·  adsb-feeder.sh        # dump1090 → FlightAware feed
├── field/                       # Phase 3c — nothing built yet
│   ├── ·  wifi-ap-setup.sh      # hostapd + dnsmasq config
│   ├── ·  wireguard-setup.sh    # VPN for remote access
│   ├── ·  tor-bridge-setup.sh   # Optional Tor bridge module (off by default)
│   └── ·  web-dashboard/        # Browser-based status panel
├── config/
│   ├── ✅ frequencies.md        # SATCOM frequency reference
│   ├── ✅ antennas.md           # Antenna selection guide
│   └── ·  profiles/             # Satellite profiles + SDR++ / SatDump configs
├── image/
│   └── ·  build-image.sh        # Automated .img.gz builder
└── ✅ .gitignore

(NOT in this repo: gr-icesickle — lives with the IceSickle project; runs ON
KosmOS, doesn't ship IN it.)
```

**Packaging note:** `package-kernel.sh` copies the Pi-side scripts into the kernel
tarball from two different directories, and hard-fails on any that are missing.
That list has to be updated in the same commit as any rename or split under
`userspace/` — a tarball missing one of them looks complete and fails on the Pi.
It currently carries `install-kernel.sh` and the whole `02` set. The `03` set,
`benchmarks/`, `automation/` and `gr-kosmos/` are deliberately **not** packaged:
none of them are needed to get the kernel running, and they are run from a clone
of the repo on the Pi.

---

## Immediate Next Steps (ordering per 2026-07-29 audit)

**Do first — cheap, everything downstream depends on them:**
1. ~~Settle C vs K~~ ✅ **K** — KosmOS
2. ~~Commit this ROADMAP.md into the repo~~ ✅ `0aa90fc`, updated `9280900`
3. ~~Fix the verification layer~~ ✅ `147fa10` — `CONFIG_IKCONFIG` +
   `IKCONFIG_PROC`, `sudo modprobe ax25`, and a `verify_critical_config()` gate
   that runs both after `merge_config.sh` and after `menuconfig`, so the state
   compiled is the state verified. Uses `grep -qx`, so `CONFIG_PREEMPT_RT_FULL`
   does not satisfy `CONFIG_PREEMPT_RT`.
4. ~~Fix `depmod unknown`, drop `libncurses5-dev`~~ ✅ `147fa10`. Also
   `make -s kernelrelease | tail -1`, so stray make output cannot poison the
   tarball name or the version file the installer reads.

**Before generating any benchmark numbers:**
5. ~~`os_prefix=` for genuinely isolated kernel+DTB sets~~ ✅ `43d8368`
6. ~~Add `nohz_full=` to cmdline.txt~~ ✅ `43d8368` — plus `rcu_nocbs`
7. ~~Add `rt-tests` + `stress-ng`~~ ✅ `43d8368`

**Then:**
8. ~~Reorganize repo into target structure~~ ✅ — single commit, `git mv` with the
   packaging paths updated alongside
9. **v0.25: rebuild, reinstall, run the benchmark.** ⏳ **Rebuild ✅ 2026-07-31.
   Install and first boot ✅ 2026-08-02. The benchmark matrix remains** — and it is
   the part that needs a human at the hardware.

   **Order is B → C → A, revised 2026-08-02.** The previous plan opened with
   config A on the grounds that pi-server was still booted on stock and A was
   therefore free. It was not still booted on stock: the install had already run,
   and `detect-config.sh` reports **B**. A now costs a reboot like the others, and
   the box is sitting on B, so running B from where it stands wastes nothing.
   Two reboots total, the same as the old plan needed.

   **Superseded 2026-08-02 by what the box turned out to have already done.**
   Config A was run on 2026-07-31 *before* the kernel was installed — six rows,
   full 1M loops, `configA-*.txt` raws intact. So the real order was A → B → C
   with a single reboot, and by the time this was worked out only C remained.
   Kept here because the reasoning still applies to a re-run:

   1. **B — ran from the KosmOS boot already in place.** No reboot needed.
   2. **C — reached by editing `/boot/firmware/kosmos/cmdline.txt` directly**,
      appending `nohz_full=1-3 rcu_nocbs=1-3`, then rebooting. **Not** by re-running
      the installer: `install-kernel.sh` resolves its package directory from its own
      location and needs `boot/`, `kernel-version` and `modules/` beside it — that
      is the extracted tarball, not the repo clone, and no tarball survives on
      pi-server. Back up the file first; it must stay a single line.
   3. **A — already banked**, so no third boot. To redo it: comment the two
      directives in the KosmOS block of `config.txt` and reboot.

   Confirm the configuration after every reboot before running anything —
   `detect-config.sh` must print the expected letter. For C that check is not a
   formality: it was the only available evidence that the firmware reads
   `kosmos/cmdline.txt` at all, since without the dynticks append that file is
   byte-identical to the stock one and B is indistinguishable from a fallback.
   ✅ **It passed 2026-08-02** — `detect-config.sh` prints C and
   `/sys/devices/system/cpu/nohz_full` reads `1-3`, so `os_prefix` command-line
   isolation is proven end to end.

   ⚠️ **`summary.tsv` is append-only; raw files are not.** A re-run overwrites
   `config<X>-<load>-<affinity>.txt` but appends six more rows, so a repeated pass
   leaves duplicate rows whose raw evidence has been destroyed. This happened: B
   ran twice, and the earlier pass's rows had to be removed because nothing backed
   them. Check the row count before transcribing.

   Fill `uname -v` into `BENCHMARKS.md`, which is still marked *(fill after first
   boot)*. Take the exact string from the box — `02a-verify-kernel.sh` confirms
   `PREEMPT_RT` is in it, but the build banner has not been captured here.

   ⚠️ **`--quick` rows are indistinguishable from real ones.**
   `run-latency-bench.sh` appends to `results/summary.tsv` with no loop-count or
   quick-mode column, so a 100k-loop smoke run leaves six rows that look
   publishable. Always smoke-test with `KOSMOS_BENCH_OUT=/tmp/bench-smoke`.

   ⚠️ **`summary.tsv` header is two columns short** — 7 headers written against 9
   data fields, so the temperature and throttle-status columns land unlabelled in
   the file the published tables get transcribed from. Fix before transcribing.

   **Budget it as a half-day, not an evening.** ~35 min per configuration is the
   harness's own figure, so ~105 min of runtime, plus two reboots and thermal
   cool-down between runs, which the gate will enforce whether or not it is planned
   for. Test 1 needs no dongle; Test 2 waits on the RTL-SDR v4.

   **Bench box = pi-server** (see Hardware Topology). No reboot-window constraint:
   swaps, crashes and reflashes are expected there — *once gate 0 below is met.*

   ### Gate 0 — the bridge must be off pi-server first (decided 2026-07-30)

   **Do not begin the kernel rebuild while the Tor bridge is still on that box.**
   This is a hard ordering constraint, not a preference: step 9 involves kernel
   swaps, failed boots and possibly a reflash, and a bridge losing its identity
   keys or dropping off the network mid-rebuild is a real cost to real users, not
   just an inconvenience. A bridge that vanishes and returns also loses accrued
   reputation.

   In order, all by hand, following the migration runbook in the `tor-services`
   project directory:

   1. **Confirm nothing bridge-related is left running on pi-server** — no `tor`
      process, no `tor-services` containers, no enabled units, and nothing that
      can re-`up` the stack at boot. The identity volume
      (`tor-services_tor-data`) is deliberately *kept* as the rollback until
      gate 0.2 has held for a few days; keeping it is not the same as running it.

      ⚠️ **Not only Docker.** Checked 2026-07-30: pi-server also has an
      apt-installed tor — `tor.service` enabled, `tor@default.service` active —
      entirely separate from the container. Stopping the compose stack and
      disabling `docker.service` leaves it enabled and it starts on the next boot,
      which is precisely what this gate exists to prevent. `tor.service` and
      `tor@default.service` must be disabled too.

      *Investigated the same day: it is Debian's default tor **client** — listening
      on `127.0.0.1:9050` only, no `ORPort`, no `BridgeRelay`, and no
      `/var/lib/tor/fingerprint` on the host. So there is no second identity and
      no key material to dispose of before a reflash. It still gets disabled; an
      enabled tor at boot fails this gate whatever it is configured as.*
   2. **Confirm the bridge is up and published from altai**, by checking the
      **same hashed fingerprint** on Tor Metrics — not merely that the container
      is running locally. A container can be up while the bridge is unreachable
      from outside, and it can be reachable under a *new* identity, which is a
      failure dressed as a success.
   3. **Only then** run the pre-flight below, and only after that, step 9.

   The migration is the gate. It is not preparation for the gate — moving the
   bridge is what satisfies 0.1 and 0.2, because pi-server cannot be freed any
   other way (no spare SD card, so no media swap).

   Steps 1 and 2 need the bridge's fingerprint, which is exactly why they are
   done by hand and stay out of this repo: **no fingerprint, WAN IP or email in
   any committed file**, including logs pasted into it. Record only "verified,
   date" here.

   - [x] **gate 0.1 — met 2026-07-30.** `tor.service` and `tor@default.service`
     disabled and inactive, no `tor` process, no stack containers, 443/9001
     unbound. The identity volume and a 43 KB backup are deliberately *kept* as
     the rollback until the migration has held for a few days.
   - [x] **gate 0.2 — met 2026-07-30.** The bridge runs on altai under its
     original identity: `fingerprint` and `pt_state/obfs4_bridgeline.txt` are
     byte-identical to the pre-move capture, so the `cert=` in every distributed
     bridge line still works. Tor's ORPort self-test — an external check, a
     remote relay connecting back — passed, and the server descriptor is
     publishing.

     ✅ **Externally confirmed 2026-07-31.** BridgeDB's own tester reports
     `obfs4 IPv4: functional`, tested *after* the migration — which also closes
     the one gap tor's self-test cannot cover, since tor only ever tests the
     ORPort and never the obfs4 port. Onionoo reports `running: true`, flags
     `Running / V2Dir / Valid`, transport `obfs4`, and a recommended Tor version.

     **The decisive field is `first_seen: 2026-03-05`** — unchanged across the
     move. Had the identity been lost, it would read the migration date and the
     bridge would be new, with no accrued reputation. Five months of history
     carried over intact.
   - [x] **gate 0.3 — met 2026-07-31.** Every pre-flight check below is complete;
     see the results inline. Gate 0 is closed in full.

   **Pre-flight on pi-server, after gate 0** — add to the checks below:
   **inventory `/lib/modules`** (`ls -la /lib/modules/ && uname -r`) before a
   second kernel's modules land beside the stock set, and note that
   `sudo systemctl enable --now docker` may need undoing if the migration
   disabled it on this box.
   **Run 2026-07-30. Results below.**

   - [x] **`config.txt` is clean.** No RF-Linux-era block, no `kernel=`, no
     `os_prefix` — 51 lines, sections `[cm4]`, `[cm5]`, `[all]` only. The stale
     block was **altai's**, and pi-server does not have one, so the
     two-conflicting-`kernel=`-directives hazard does not apply here. The
     installer's `^os_prefix=kosmos/` grep will behave as designed.
   - [x] **`/lib/modules` inventoried** — four sets already present:
     `6.12.47+rpt-rpi-2712`, `6.12.47+rpt-rpi-v8`, `6.12.62+rpt-rpi-2712`,
     `6.12.62+rpt-rpi-v8`. KosmOS adds a fifth in its own versioned directory.
   - [x] **Config-A baseline confirmed**: running `6.12.62+rpt-rpi-2712`,
     `#1 SMP PREEMPT Debian 1:6.12.62-1+rpt1`. Exactly the ROADMAP's expectation,
     so no pinning is needed for the baseline.
   - [x] **Governor unit installed, and verified across a reboot 2026-07-31.**
     Rebooted from 34 days' uptime; 16 seconds into the new boot the journal shows
     `kosmos-set-governor: 'performance' set on 4 core(s)`, all four cores read
     `performance`, and `scaling_cur_freq` equals `scaling_max_freq` at
     2 400 000 kHz — pinned at max with no ramp. That is the ondemand
     frequency-ramp latency removed from the benchmark, which is the only reason
     the unit exists.
     - **Refinement to the earlier finding:** `ondemand.service` **does not exist**
       on pi-server, so the installer's masking step was a no-op. The `ondemand`
       governor here comes from the stock kernel's own default, not from a Debian
       service overriding it at boot. The ROADMAP previously generalised altai's
       cause to both boxes; on this one there is nothing to mask, only a default
       to override.
   - [x] **KosmOS cloned** to `~/KosmOS` on pi-server.
   - [x] **`/boot/firmware`: 445 MB free of 510 MB** — ample for a second kernel,
     its DTBs and overlays.

   ✅ **Two risks were flagged for the build itself. The build has now run, and
   both were measured — neither was real. A third took their place.**

   | Risk as predicted | Measured on the real build (`JOBS=3`) |
   |---|---|
   | Disk: 22 GB free vs README's 40 GB | **~4 GB consumed**, source tree plus objects |
   | RAM: 4 GB, OOM at `JOBS=4` | **2903 MB lowest free, 4 MB peak swap** — nowhere near |
   | *(not predicted)* | 84.2 °C peak SoC, fan 4/4 — **the build was not limited by it** |

   **The build hit no limit at all.** It completed at 84.2 °C without throttling
   to failure, without needing `JOBS` reduced, and without any intervention. Build
   thermals are also a fact about *this* box and irrelevant to anyone who flashes a
   finished image, which is the entire distribution model from Phase 4a onward — a
   user compiling a kernel is not a case KosmOS is designed for.
   The temperature is recorded here for one reason only: it establishes that **this
   hardware saturates its cooling under sustained all-core load**, and the
   benchmark is exactly that kind of load. It is evidence about the *benchmark's*
   validity, not a build requirement, and it should never be quoted as one.

   - **Disk.** The `CONFIG_DEBUG_INFO_NONE=y` reasoning held: debug info is what
     makes kernel object trees enormous, and without it the tree stayed at ~4 GB.
     **The README's 40 GB figure is confirmed far too conservative and should be
     revisited** — it is now measured rather than inferred.
   - **RAM.** `JOBS=3` never came close to pressure, and the ~1.5 GB-per-job
     warning proved pessimistic for this configuration. `JOBS=4` is plausibly fine
     too, though untested; there is no reason to find out, since the build is not
     the slow part.
   - **Thermal is the constraint that actually bites**, and it matters far more for
     the *benchmark* than for the build — a hot box inflates tail latency, which is
     the published number. Handled by `thermal-state.sh`; see the prerequisite
     added above.

   - **Build dependencies are mostly absent** (`bc`, `bison`, `flex`,
     `libssl-dev`, `libncurses-dev`, `libelf-dev`, `dwarves`). Not a blocker —
     `01-build-kernel.sh` installs them in its step 1 — but the build starts with
     an apt run rather than compiling immediately.
10. Order the RTL-SDR Blog v4 + dipole antenna kit (if not already)
11. ~~Build `03-satcom-stack.sh` — pinned from line one~~ ✅ **written and
    linted**, pinned from line one. Still needs its first run on pi-server;
    nothing in it has been executed.
12. First NOAA APT capture using SatDump

**Carried forward from the audit, not yet scheduled:**
- ~~shellcheck has never been run~~ ✅ **verified at zero.** 11 findings fixed:
  `$(nproc)` quoted (SC2046 ×3), `read -r` everywhere (SC2162 ×4), `ls` replaced
  with `find` (SC2012 ×3), and the unused `OUTPUT_DIR` deleted rather than wired
  up (SC2034) — it was dead, and adding an `output/` directory would have changed
  the artifact path the README documents. ✅ **Now CI-gated** so it stays at zero.
- ~~**File-size headroom is thin.**~~ ✅ **`02-post-install.sh` is split.** It did
  four jobs (verify, benchmark tooling, SDR userspace, locale) in 399 lines, one
  under the cap. Now a sequencer over `02a-verify-kernel.sh`,
  `02b-bench-tools.sh`, `02c-sdr-userspace.sh` and `02d-locale-ru.sh`, each
  runnable standalone. Behaviour through the sequencer is unchanged, including
  the inherited quirk that declining the SDR install also skips the locale step —
  02c signals that with exit code 3.
  *(Sizes at the split, 2026-07-29: 96 / 187 / 47 / 148 / 63. They have moved
  since — 02c in particular nearly doubled taking the version pins. See the
  headroom table under the extraction rule for current figures; it is canonical.)*
- ~~**Retrofit version pins into `02-post-install.sh`**~~ ✅ **done.** All four
  projects in `02c-sdr-userspace.sh` are pinned to exact commits, verified after
  checkout, and recorded to a build manifest. Pins captured 2026-07-29:
  rtl-sdr-blog `v1.3.6`, rtl_433 `25.12`, dump1090 `v11.1`, predict at its 2018
  tip (upstream has never tagged). Each pin was fetch-tested against the live
  upstream, and the mismatch path was tested with a bad SHA.

---

*KosmOS v0.2 — Built from bare metal, aimed at the stars*
*Target: Raspberry Pi 5 (BCM2712, ARM64)*
