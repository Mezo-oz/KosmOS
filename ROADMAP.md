<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# MolniyaOS — Project Roadmap & Vision

*Renamed 2026-08-28: it's **MolniyaOS** (Молния, "lightning") — after the Soviet
Molniya communications satellites and the Molniya orbit named for them. The
previous name, KosmOS (settled 2026-07-29), collided with another Linux distro;
collision checks on 2026-08-28 found MolniyaOS clean on GitHub, DistroWatch, and
general search. Artifact names stay lowercase by convention: kernel-molniya.img,
`-molniya` localversion, gr-molniya. GitHub repo renamed (auto-redirects).*

## Hardware Topology (permanent, decided 2026-07-29)

Two Raspberry Pi 5s, with a deliberate and permanent split of roles:

- **pi-server — the dedicated MolniyaOS dev / break-fix box.** All kernel work
  happens here: custom-kernel swaps, `os_prefix` installs, benchmark reboots,
  crashes, and full reflashes are all *expected and welcome* on this machine.
  It runs no production service, so there is **no reboot-window constraint** —
  breaking it is the point. It is the config-A benchmark baseline too: stock
  Pi OS `6.12.62+rpt-rpi-2712` is already installed, so no kernel pinning is
  needed for the A/B.

- **altai — the permanent production host.** Runs the Amnezia work, and will run
  the `tor-services` Docker stack (an obfs4 bridge + snowflake proxy +
  watchtower). Stable, always-on, not to be disrupted for MolniyaOS.
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

**Relationship to the Phase 3c Tor bridge module (below):** MolniyaOS *ships* an
optional bridge module as a distro feature. That is entirely separate from the
production bridge on altai. The module is dogfooded later with a **throwaway
test identity** — never the live bridge's keys. (Repo docs stay generic about
the production bridge: no WAN IP, email, or fingerprint in any committed file.)

## Identity: What MolniyaOS Is (and Isn't)

**MolniyaOS is a ground-up, SATCOM-focused Linux distribution built for the Raspberry Pi 5.**

The existing player in this space is DragonOS — a Lubuntu-based distro that ships as
a pre-built ISO with every SDR tool imaginable pre-installed. DragonOS is the "Kali
Linux of SDR": boot it up, everything works, you don't know how any of it was built.

MolniyaOS takes the opposite philosophy:

| | DragonOS | MolniyaOS |
|---|---------|--------|
| **Base** | Lubuntu (stock kernel) | Custom RT kernel built from source |
| **Architecture** | x86_64 primary, Pi secondary | ARM64/Pi 5 native, built for the edge |
| **Scope** | Kitchen sink (200+ tools) | SATCOM/space focused (curated toolkit) |
| **Philosophy** | "Everything pre-installed" | "Built from ground up, understand every layer" |
| **Target user** | Hobbyist who wants to scan now | Builder who wants to understand *and* do |
| **RT kernel** | No (stock Ubuntu kernel) | Yes (PREEMPT_RT, 1000Hz) |
| **Field deployment** | Desktop/laptop focused | Pi 5 portable kit with battery + WiFi AP |

**The pitch:** MolniyaOS is what you'd build if you were setting up a SATCOM ground
station from bare metal — custom kernel tuned for real-time RF processing, a curated
toolkit focused on satellite communications, and a deployment model designed for
portable field work on ARM64 hardware.

### Positioning: Appliance, Not Toolbox

MolniyaOS is **not** "DragonOS minus tools" — that would be a learning project, not a
product. MolniyaOS is an **autonomous SATCOM ground station appliance for ARM64**.
DragonOS hands you a workshop; MolniyaOS hands you a working instrument: flash the
image, give it your coordinates, and it starts producing satellite imagery and
decoded data on its own.

Three pillars separate this from a toy:

1. **Measured RT performance** — the custom kernel is a *claim* until it's
   benchmarked against the stock kernel on identical hardware. See "Proof of
   Claim" below. If the numbers hold, MolniyaOS has an engineering result nobody
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
   What is built gets recorded to `/usr/local/share/molniya/build-manifest.txt`,
   so a box can be asked which revision a binary came from. Still open: the
   kernel branch itself (`rpi-6.12.y`) is a moving target — see Phase 4a.*

---

## Engineering Standards (adopted 2026-07-29)

**Languages, honestly stated.** The kernel is C — but it's *upstream* C that
MolniyaOS configures, patches, and compiles, not writes. MolniyaOS's own code is
orchestration: **bash** for build/install/automation scripts, **Python** where
a pipeline needs real data handling (rtl_power heatmaps, pass-scheduling
logic, dashboard backend), and **C/C++ only if/when** we write custom GNU
Radio blocks, SatDump plugins, or kernel patches. Distro-building is general
contracting, not brick manufacturing.

**Adapted NASA/JPL discipline.** The famous NASA rules are JPL's "Power of
Ten" for safety-critical flight C — the actual size rule there is *functions
≤ ~60 lines (one printed page)*. A 400-line-per-file cap is not NASA's rule,
but we adopt it as house convention anyway. MolniyaOS rules, adapted for
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
8. **stdout is the product; everything else goes to stderr** — see below

### ⚠️ Standard 3 has a sharp edge: never pipe into `grep -q` (found 2026-08-23)

`set -o pipefail` is required by standard 3 above, and in combination with
`grep -q` it silently inverts a check's result. `grep -q` exits the instant it
matches; if the producer is still writing, it dies of `SIGPIPE`, and `pipefail`
reports the **whole pipeline as failed even though the match succeeded**.

Found while building the 4d health check, then measured on pi-server. Three
scripts had it, all on the same line of code:

```bash
zcat /proc/config.gz | grep -qx "CONFIG_PREEMPT_RT=y"   # always "fails"
```

`/proc/config.gz` decompresses to 242 KB through a 64 KB pipe buffer, so `zcat`
is guaranteed to still be writing — the bug is **deterministic, not a race**.
Affected: `benchmarks/detect-config.sh`, `benchmarks/run-sdr-bench.sh`,
`userspace/02a-verify-kernel.sh`. All three used it as the *first* of three
RT-detection sources, so all three had been silently answering from the weaker
`uname -v` fallback since the day they were written, while their comments
claimed to consult the authoritative one.

**No published result is wrong**, and that was checked rather than assumed: the
fallback agrees on both kernels these scripts have ever run on, and
`detect-config.sh` still prints `C` on pi-server after the fix. What was wrong
was the guarantee — a kernel whose banner lacked the string would have been
reported NOT DETECTED with `/proc/config.gz` sitting there saying otherwise.

**Fix:** process substitution, which is one command with one exit status and no
pipeline to mis-report.

```bash
grep -qx "CONFIG_PREEMPT_RT=y" <(zcat /proc/config.gz 2>/dev/null)
```

**The rule:** under `pipefail`, do not put `grep -q` — or `head`, or anything
else that exits early — on the right of a pipe whose producer emits more than a
pipe buffer. shellcheck does not catch this at any level, including `-S style`;
all three sites were clean before and after.

Not every `| grep -q` in the tree is affected, and they were checked
individually rather than swept: `echo "$x" | grep -q` and `uname -v | grep -q`
are safe, because the output fits in the pipe buffer and the producer finishes
before `grep` can exit.

### ⚠️ Standard 8: stdout is the product (adopted 2026-08-24)

Scripts here already treat stdout as a return channel rather than a place to
talk: `layout.sh` prints an sfdisk script, `fetch-base.sh` prints the `.img`
path, the health-check helpers return data for their caller to judge, and every
`step`/`note`/`die` in the image builders writes to stderr. That was a house
habit. It is now a rule, because stage 4 showed what it costs when it slips.

`build-image.sh --stream` writes a **gzip stream** to stdout. It also printed
the image path there when it finished, the way `fetch-base.sh` does — and that
appended a trailing `/var/tmp/molniya-build/molniya-rpi5.img` and a newline to
the compressed artifact.

What makes it worth a numbered rule rather than a bug fix is the failure mode.
**gzip ignores trailing junk.** The `.gz` still decompressed. It would still
have flashed. Nothing in the build, the transfer or the flasher would have said
a word; only a byte-for-byte comparison catches it, which is why the digest is
taken of the raw image *before* compression and checked after decompression on
the far side. A corrupt artifact that passes every check but one is worse than
one that fails loudly, and this one passed every check but the last.

The rule, stated so it can be applied without re-deriving it:

- If a script's stdout can ever carry bytes a machine consumes — an archive, an
  image, a generated config, a digest — then **every** human-facing line in it
  goes to stderr, including the ones that only appear on success.
- A script that prints a path on stdout as its return value is doing the same
  thing correctly. The two are the same rule, not opposites: stdout carries one
  kind of thing, decided by the script's contract, and nothing else.
- Helpers stay executable subprocesses returning data on stdout (see the
  extraction rule) — which is exactly why this discipline has to hold.

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

**Current headroom** (re-measured 2026-08-24, after stage 4):
`build-rootfs.sh` **399**, `molniya-health-check.sh` **398**, `tle-updater.sh`
**397**, `run-latency-bench.sh` **396**, `assemble-image.sh` **393**,
`install-kernel.sh` 383, `layout.sh` 381, `rtl-power-heatmap.py` **377**,
`run-sdr-bench.sh` 367, `02c-sdr-userspace.sh` 352, `verify-image.sh` 344,
`01-build-kernel.sh` 329, `build-image.sh` 274, `install-tle-timer.sh` 249,
`03a-gnuradio-stack.sh` 227, `thermal-state.sh` 207, `03b-satdump.sh` 206,
`03c-sdrpp.sh` 203, `02a-verify-kernel.sh` 198, `fetch-base.sh` 172,
`slot-identity.sh` 157.

⚠️ **Five files now have under ten lines of room.** The two flagged on
2026-08-23 have been joined by `assemble-image.sh`, which took **97 lines** for
first-boot access provisioning and went 296 to 393 in one commit with nobody
watching the number. That is the more useful of the two warnings: a file does
not approach the cap gradually. It takes one feature and arrives.

The rule is 400, so all five are compliant and none of them can take a feature.
**The next addition to any of them must extract**, and unlike the last time this
came up there is no duplicated prose left to reclaim — the honest fat is cut.

Both new files were written against this. `verify-image.sh` splits its per-slot
checks into three functions (`verify_boot`, `verify_root`, `verify_access`)
rather than one, which is what keeps every function inside the 60-line rule and
leaves room to grow a section when 4b adds one; it has since taken `--release`
and sits at 344.

### ✅ The rule fired again, 2026-08-23 — and this time it was resisted first

Adding the slot identity check took `molniya-health-check.sh` to **437**, and the
warning written into this table one commit earlier — *the next thing you add goes
in its own file* — is exactly what happened. Worth recording how it resolved,
because the first instinct was wrong twice over.

The check had *already* been extracted: `slot-identity.sh` holds the reading and
the slot arithmetic. What overflowed the file was only the 49 lines of wiring
that judge its output. So "extract the check" was not available as an answer —
it was already done.

The rule's trigger is a file that exceeds 400 **and cannot lose the lines
elsewhere**, and that second clause did the work here. Three things came out,
none of them the check:

- **35 lines of the header** restating the CRITICAL vs ADVISORY rationale that
  had been written into 4d one commit earlier. Two copies of one argument, and
  this document owns rationale. Replaced with the contract and a pointer.
- **13 lines** of the namespace-package write-up, same reason, same fix.
- **Five `sed` passes** over the helper's output, replaced by one read loop —
  shorter *and* better, which is the tell that it was fat rather than substance.

That landed it at **398**. Two lines of headroom is not a comfortable place to
stop, and it is stated plainly rather than left to be discovered: **the next
addition to this file has nowhere to go and must extract for real.** The
mark-good wrapper and its unit were always going to be separate files; now they
have to be.

The rule's value here was not the split it forced. It was the duplication it
surfaced — prose drifting out of the ROADMAP and into a script header, which no
line count would have caught on its own.

**The cap now gates Python too.** Standard 1 says "≤400 lines per file" and this
document has named Python a first-class language since the standards were
adopted, but the CI step globbed `*.sh` only — so the rule was unenforced for
exactly the files most likely to grow into it. Fixed 2026-08-05; the glob is now
`'*.sh' '*.py'`. `rtl-power-heatmap.py` enters the table third from the top, so
this was not a hypothetical gap.

Two files now sit within
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
they can't keep up at full sample rate. Planned blocks live under `gr-molniya/`
except where noted (see Phase 2c for the independence rule on IceSickle).

---

## Architecture & Extensibility (adopted 2026-07-30)

*There is no Phase 5 — this is a standing design principle rather than a phase of
work, so it sits with the other rules rather than at the end of the plan.*

### Openness is architectural, not a feature

MolniyaOS is open to new satellites because of what it is built from, not because
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

What MolniyaOS targets is **open or published interfaces**:

- an open-source constellation — published specs, write a profile, done
- any commercial provider that publishes an SDR-accessible interface

A closed constellation's door is theirs to open. MolniyaOS stays *ready* — the
abstraction clean, the extension point documented — not *pre-plumbed*.

### Two different things get called "commercial"

Separated here so they are not conflated later, in either direction.

**Routing MolniyaOS traffic *through* a commercial terminal — already works,
trivially.** A Starlink dish, an LTE modem, a hotel Ethernet port: these are
uplinks. Plug one in and MolniyaOS uses it like any other network interface. That is
Linux networking and there is nothing to build. It is also the genuinely useful
case — a field station backhauling decoded data over whatever link exists.

**Making MolniyaOS's SDR *be* a commercial terminal — not possible, and not
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
  `rcu_nocbs` are appended to the MolniyaOS command line, default CPUs 1-3 with
  CPU 0 left as housekeeping. Configurable via `NOHZ_FULL_CPUS`, which the
  benchmark matrix below relies on.
- [x] **Make verification possible** — *done, `147fa10`.* `CONFIG_IKCONFIG` +
  `CONFIG_IKCONFIG_PROC` added, and the `/proc/config.gz` read fixed (it was
  grepping the compressed bytes, which can never match).
- [x] **Rebuild with `CONFIG_LOCALVERSION="-molniya"`** — *done 2026-07-31 on
  pi-server, installed and booted by 2026-08-02.* The build produced
  **`6.12.98-molniya+`**, the localversion took effect, and the module directories
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
| **B** | MolniyaOS (PREEMPT_RT) | `""` | RT with no core isolation |
| **C** | MolniyaOS (PREEMPT_RT) | `"1-3"` | RT plus full dynticks |

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
and re-running it, or editing `molniya/cmdline.txt` on the boot partition
directly. Switching between A and B/C means commenting the two directives in the
MolniyaOS block of `config.txt`. Nothing else differs between any of the three
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
- [~] **`gr-molniya` sample-discontinuity probe** — an inline block that watches
  the sample stream for discontinuities and logs a timestamped record of every
  gap (the "gauge in the pipe"). *Implemented 2026-08-05, and **split so that
  half of it is actually tested**: the clock arithmetic lives in `gap_math.py`,
  imports nothing outside the standard library, and is covered by 15 unit tests
  that run on any machine with a Python interpreter. **15/15 pass.** What remains
  untested is the thin part — tag unpacking, the pass-through copy, the log
  write — and it has still never run under GNU Radio.*
  - **Why the split, and why it is not a house-rule violation.** "Helpers are
    subprocesses, never sourced libraries" is a *shell* rule; it exists so
    shellcheck stays clean without `-x`. A Python import inside one package is
    ordinary module structure, and a subprocess per `work()` call in a flowgraph
    would be absurd. What the split buys is the thing this project actually
    rations: it moves the measurement out of a file that cannot execute without
    GNU Radio and into one that can.
  - ⚠️ **The precision argument was overstated and is now corrected.** The
    original note said a double's ulp at epoch scale (~1.7e9 s) is "about 4e-7 s
    — LARGER than one sample period at 2.4 MS/s", making a one-sample gap
    unrepresentable. Measured: the ulp is **2.384e-7 s**, which is **0.57** of a
    sample period at 2.4 MS/s, so it is smaller, and `round()` absorbs error
    below 0.5. The conclusion survives on a narrower argument that is true:
    at **3.2 MS/s** — the top of `run-sdr-bench.sh`'s sweep, included precisely
    because it is where the kernels should diverge most — the ulp is **0.76** of
    a sample, past the rounding boundary, and collapsing the pair reports a
    one-sample gap as two. That case is now a regression test that fails if
    anyone "simplifies" `pair_delta`.
  - ⚠️ **The documented way to run the tests did not work** and is corrected.
    `python3 -m unittest <path>` takes a dotted module name, not a path; running
    them as `molniya.test_gap_math` executes `__init__.py`, which imports the
    probe, which imports gnuradio — defeating the point; and discovery from the
    repo root fails because `gr-molniya` is not a valid Python identifier. The one
    working invocation is
    `cd gr-molniya/python/molniya && python3 -m unittest test_gap_math`, and the
    reasons are recorded in the file so it does not get "fixed" back.
  - **The design note worth keeping:** a `sync_block` cannot see a gap by
    inspecting its input buffer — the buffer is always contiguous no matter what
    the radio dropped. The gap is visible only in the `rx_time` stream tags a
    hardware source emits on overflow, and the measurement is a comparison
    between the timestamp in a new tag and the time predicted from the previous
    tag plus samples consumed since. `rx_time` values are PMT pairs of
    (whole seconds, fractional seconds), not floats. All written down in
    `gr-molniya/python/molniya/discontinuity_probe.py`.
  - No `CMakeLists.txt` on purpose: a full OOT module's build system is
    generated by `gr_modtool newmod molniya`, not hand-written. Several hundred
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
   box (pi-server) gets a fresh `-molniya` build at step 9; it is not carried over.*
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
   **`6.12.98-molniya+`**, so `CONFIG_LOCALVERSION` took effect and this kernel's
   modules land in their own directory. Built from the pinned commit
   `f5a99b95`. ✅ **Installed and booted — confirmed on hardware 2026-08-02.**
   pi-server runs `6.12.98-molniya+`; `02a-verify-kernel.sh` reports **7 passed, 0
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
  - ~~Still to do: put it on a timer~~ ✅ **2026-08-05** —
    `molniya-tle-update@.service` + `molniya-tle-update@.timer`, installed by
    `automation/install-tle-timer.sh`. Twice daily at 05:17/17:17 with a 15-minute
    random spread, `Persistent=true` so a box that was powered off through both
    windows catches up instead of staying a day stale.
    - **A template unit, keyed on the username.** The updater writes under
      `$HOME`; run as root it would maintain elements in `/root` that predict
      never opens, which fails silently because predict answers from its shipped
      elements with no sign they are stale. The instance name is the account, so
      systemd's own `%i` supplies it and the repo ships a valid unit rather than
      one the installer rewrites.
    - Chosen over the cron line for exit status: the updater already exits
      non-zero on any fetch or checksum failure, so as a unit `systemctl status`
      becomes a truthful answer to "are my elements current". The cron line stays
      in the script header for anyone without systemd.
    - ⚠️ **Written and linted, never executed** — installing a systemd unit needs
      a systemd box, so this has had no run on pi-server. Argument parsing was
      exercised locally; nothing past the `systemctl` check has been.
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
  - ~~rtl_power → CSV heatmap pipeline (Python/matplotlib)~~ ✅ **2026-08-05**,
    `automation/rtl-power-heatmap.py`. **The one item in this phase that has
    actually been run** — it needs no dongle, because an rtl_power CSV is just a
    file, so it was developed against synthetic captures and verified end to end.
    - **A row is a chunk, not a sweep.** rtl_power splits any range wider than the
      dongle's bandwidth across several rows, so one line of the waterfall is a
      set of them. Plotting one row per output line draws the chunking pattern
      instead of the band, which is the mistake this was written to not make.
      Sweeps are cut on **frequency wrap-around**, not on the timestamp: chunk
      timestamps within a sweep are not reliably identical, and grouping by them
      splits one pass in two.
    - **Not `jet`.** SDR convention is the one colormap scientific visualisation
      has spent twenty years arguing against — non-monotonic lightness invents
      banded features at the cyan and yellow turns, and it fails under red-green
      CVD. Default is viridis, where brighter always means stronger. `--cmap`
      overrides for anyone who wants the old look. Coverage gaps draw in neutral
      grey rather than matplotlib's default white, which on a viridis ramp reads
      as the strongest signal in the capture.
    - **`--summary` imports nothing outside the standard library**, and the plot
      path imports numpy and matplotlib lazily to keep that true. On a headless
      box the first question is whether the capture is any good, and answering it
      should not require a working matplotlib.
    - dB is labelled **uncalibrated** on every axis it appears on. An RTL-SDR has
      no absolute power reference; the figures compare within one capture and are
      not dBm.
    - Verified: 24-sweep and 1-sweep captures, `-inf` bins, a truncated row, a
      changed bin width mid-file, an empty file and a missing file. Single-sweep
      input renders a spectrum line plot rather than a one-pixel-tall heatmap.
      pyflakes and pycodestyle clean; 377 lines.
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
  - **Independence rule (2026-07-29):** MolniyaOS stays independent. This
    decoder is an out-of-tree GNU Radio module (`gr-icesickle`) that *runs
    on* MolniyaOS but doesn't ship *in* it — it likely lives in the IceSickle
    repo. MolniyaOS is the platform; IceSickle support is an app. The distro
    never depends on it, references it at most as a "built on MolniyaOS"
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
- [ ] **Web dashboard** — Browser-based control panel. **This is KosmOS's head,
  and the decision below is what makes it the only one.** *(Decided 2026-08-27.)*

  ##### There is no "headless build" and "GUI build" — there is one image

  The question that produced this section was whether to ship a headless variant
  and a desktop variant. **No**, and the first reason is that the premise is
  wrong: **the GUI applications are already in the image.** `03b-satdump.sh`
  builds SatDump's GUI (`libglfw3-dev`, `zenity`; its own comment notes the GUI
  "costs build time but no runtime"), and SDR++ *is* a GUI application —
  `03c-sdrpp.sh` says it "builds headless, needs a display to run" and can be
  driven over X forwarding or VNC "the day the Pi gets a screen."

  What is missing is a **display server and a session**, not a GUI. That is a
  much smaller thing, and it is emphatically one to install rather than write:
  a compositor and a widget toolkit are years of work with no SATCOM value.

  **The second reason is size, and it is the binding one.** `layout.sh` gives
  each root slot 6144 MiB against a rootfs of ~4.9 GB — roughly **1 GB of
  headroom, doubled, because there are two slots.** A desktop session lands at
  or over that line. Growing the slots means repartitioning, which this document
  already calls the expensive thing to change, and which has been paid for once
  (`60a602b`, "the root slot was too small").

  **The third is that two variants is two of everything**: two build pipelines,
  two verify baselines, two bundle streams, a doubled boot-test matrix — and a
  second `compatible` string, or a bundle that installs the wrong variant over
  the right one. All of it incurred while the *first* image has still never
  booted.

  So: **one image; the head is an optional module**, in the shape 3c already
  uses for the Tor bridge and the *extension point, not scaffolding* rule
  requires. A local desktop, if it is ever wanted, is that same module pattern
  with `labwc` behind it — config, not construction — and it is not on the path.

  ##### Why building this one is not reinventing anything

  A dashboard is the one piece of UI here that cannot be taken off a shelf,
  because everything worth showing is specific to this box: the next pass from
  `predict`'s TLEs, the health check's verdict, **which slot is running and
  whether it is a tryboot**, `rauc status`, dongle presence, thermal and
  throttle state. Grafana can draw a time series; it cannot tell you that you
  are one reboot from slot A.

  It is also the appliance-correct head. Over the WiFi AP above, it is a screen
  in a field from a phone, with no monitor, no keyboard and no display server on
  the box — which is what *Positioning: Appliance, Not Toolbox* actually asks
  for.

  ##### ⚠️ Its state MUST live on the data partition (p7)

  The single hard constraint, and the one that would be discovered late and
  expensively. **Every A/B update replaces the root wholesale**, so a database
  or config under `/var/lib` or `/etc` is destroyed by the next update —
  silently, which is the dangerous part (4d). Anything the dashboard remembers
  — captures index, preferences, logged series — belongs under `/data`, and the
  binding of that boundary is 4b's business, not something to invent here.

  ##### Shape, kept deliberately small

  - **Read-mostly first.** A status page that cannot break anything is worth
    shipping before a control panel that can. Actions (start a capture, arm a
    pass) come after, one at a time, each with a reason.
  - **No new runtime.** Python is already in the image for gr-kosmos, so a small
    Flask/FastAPI app plus static HTML/JS adds an app, not a stack. **No Node
    build chain** — an `npm` dependency tree is not affordable against 1 GB of
    doubled headroom, and it is exactly the kind of thing that grows without
    anyone deciding it should.
  - **Bound to the AP/localhost by default, OFF by default.** It is a network
    service on a box whose whole security story is that it does not offer any;
    same tradeoff the Tor module is required to state, same answer.
  - **It reads; it does not re-derive.** The health check already returns a
    verdict, `slot-identity.sh` already returns the running slot, `rauc status`
    already knows the slot map. The dashboard renders those. A dashboard that
    computes its own opinion of health is a second implementation that will
    disagree with the first at the worst moment — the same rule the boot
    backend follows by not owning device-tree code.

  ##### ⚠️ It collides with 3b, and one of them has to give

  3b proposes **InfluxDB + Grafana**. That pairing is on the order of hundreds
  of MB before any data, against ~1 GB of doubled headroom — so **3b and this
  cannot both ship as written.** The likely resolution is that this dashboard
  subsumes 3b's visualisation role over SQLite, and Grafana becomes something
  you point at the box from a workstation rather than something the box carries.
  Not decided here; flagged so it is decided once, rather than twice in
  opposite directions.
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
    and is never touched by MolniyaOS development. When dogfooding this module,
    generate a **throwaway test identity** — never reuse the production bridge's
    keys or fingerprint. A test bridge and the real one must never share identity.

### Phase 4: "Hardened Platform" — Reliability & Distribution
*Goal: Make MolniyaOS reproducible and distributable*

#### 4a. Image Building

**⏳ Started 2026-08-23. Code-complete 2026-08-24. Artifact rebuilt 2026-08-26
to carry 4d.** The base-image question 4d deferred here is decided, all four
stages are built and have run on hardware, and the release artifact exists.
What is left is a boot test, which needs hardware this box does not have.

##### 📌 PICK UP HERE — updated 2026-08-27

**⚠️ The artifact below cannot install an update, and the fix needs a decision
only you can make.** It ships no RAUC keyring — see *The keyring was never
installed* in 4d — so `rauc install` fails with `failed to load CA file`. The
127/127 pass is real and says nothing about this, because the check that would
have caught it did not exist until 2026-08-27.

It is still the right card to flash for the boot test: that protocol exercises
`rauc status`, not `install`, and every line of it stands. What a green boot
test will no longer let you conclude is that the update path works.

**To make it updateable — two commands, and the first one is yours:**

```sh
# 1. Create the root CA. ON REMOVABLE MEDIA, and never on pi-server or in the
#    repo. This is the crown jewel: it is the trust root every MolniyaOS box will
#    carry, and make-keys.sh refuses a destination inside the work tree.
image/rauc/make-keys.sh ca /media/<offline>/molniya-ca

# 2. Inject its public cert into the existing image, on pi-server, in place.
ssh pi-server 'molniya-img/image/inject-keyring.sh \
    --expect 9fedaa86f1e35226ba60cbf8d159aa6dae096aea369b2dda377b9d219da33fa1 \
    --cert ~/ca.cert.pem'
```

Then re-verify (`verify-image.sh --release`, which now asserts the keyring),
re-stream, and **retire the old digest everywhere it appears — this file
included.** The injector prints the new one on stdout and rewrites
`<image>.sha256`; nothing else updates itself.

**Why an injector and not a rebuild.** A `--force` rebuild is ~2 hours and the
last one came up ~1.5 GB short on disk. `image/inject-keyring.sh` is committed,
takes the input digest as a mandatory argument, and prints the output digest —
so the modified artifact's history is as auditable as a pipeline run, which is
what provenance actually means. Hands on a mounted image is the thing that
would break it. It modifies in place because the image is 11 GB and pi-server
has 3.4 GB free; there is nowhere to put a copy.

**⚠️ Two images' worth of confusion is now possible on the Windows drive.** The
digest below is the *pre-injection* one. Whoever flashes needs to know which
`.img.gz` in `X:\molniya-images\` is current, and the only durable answer is the
`.sha256` beside it.

**Artifact (pre-injection):** `X:\molniya-images\molniya-rpi5.img.gz`, **3.49 GB**,
raw digest `9fedaa86f1e35226ba60cbf8d159aa6dae096aea369b2dda377b9d219da33fa1`,
round trip confirmed by decompressing to `sha256sum` on the receiving end. It
supersedes `b1c4c74c…`, which predated 4d entirely and is gone.

Its provenance says what is actually in it, which is the point of having
rebuilt rather than patched:

```
apt_userspace  rt-tests stress-ng rauc rauc-service
satcom_stack   built from source
kernel         6.12.98-molniya+
base_sha256    acff736ca7945e3b305f07cda4abdb870910e12634991da69783611756e381b3
```

**Everything left in 4a needs hands, not code.** The image has never booted.
The protocol is written down below — *The boot test — protocol* — and it
needs a card reader on another machine and a spare card. **Keep pi-server's
card intact until the new one is proven**; it is the only route back.

**Known-open, in the order they will bite:**
1. ~~The artifact is stale~~ ✅ **closed 2026-08-26 by the rebuild above.**
2. The image has never booted. Everything either script can tell you is
   structural, and both say so in their own passing output.
3. SDR++'s module set is decided by what earlier stages drag in — see the
   ⚠️ under stage 2. Not fixed, and a lock file would not catch it.
4. `root=` is a device path, so the image is card-specific (no NVMe).
5. ~~No build stage installs `rauc`~~ ✅ **closed 2026-08-26** — stage 2's
   `APT_PACKAGES` now carries `rauc rauc-service`, and `verify-image.sh`
   asserts both are in the finished image. See 4d.
6. **The artifact ships no RAUC keyring, so it cannot install a bundle.**
   Fixed in the pipeline for every future build (`provision-rauc.sh`) and
   gated so it cannot recur (`verify-image.sh`); the *existing* artifact needs
   `inject-keyring.sh` run against it, which waits on a CA. See the top of this
   section and 4d.

*(Known-open 4 of the previous list, `rauc/rauc#1599`, is closed: the gate it
named fired on 2026-08-24 and the re-check was done on 2026-08-26. The answer
was to stop waiting — see 4d. Before that, the stock module trees closed the
same way: stage 4 removes them and `verify-image.sh --release` asserts it.)*

##### ✅ Stage 3's product is verified — 96 checks, 2026-08-24

The checklist this section carried overnight — *mount it and check the user,
the keys, the sudoers drop-in, the enabled units, the partition table* — was
written as a script instead of worked through by hand, because it is going to be
run after every build and a checklist run by hand is run once.

`image/verify-image.sh`, 319 lines. Read-only throughout: the loop device is
attached with `-r` and every mount is `ro`, so verifying an image cannot be what
modifies it, and a pass can be taken between building the image and hashing it.

**It derives nothing.** Every expected value comes from `layout.sh` or from the
image itself; the file contains no offset, no size and no partition number of
its own. A check carrying its own copy of the answer is a check that goes on
agreeing with itself after `layout.sh` changes — which is exactly what happened
to the 4096 MiB slot size, and would have happened again here.

**All 96 hold**, in both slots: the seven partitions match `layout.sh` to the
sector; `autoboot.txt` is byte-identical to the emitter and is the only file on
p1; each bootfs holds `kernel-molniya.img` with the stock `kernel_2712.img` and
`kernel8.img` gone and `kernel=kernel-molniya.img` written into `config.txt`;
each root carries its own fstab, an identical `slots.conf`, modules and a
populated `modules.dep` for `6.12.98-molniya+`, the health check and
`slot-identity.sh`, and all five SATCOM binaries; the `molniya` account is uid
1000 with `/bin/bash`, `authorized_keys` is 0600 `1000:1000` with two keys,
the sudoers drop-in is 0440, `ssh.service` is enabled, `userconfig.service` is
not, and the sshd drop-in is key-only. No `pi` user survives in either slot.

**Two things it was written NOT to do**, both of which would have made it the
kind of check this phase keeps producing:

- **It does not look up the SATCOM binaries on `PATH`.** The build host has
  every one of them installed, so `command -v satdump` passes on an image
  containing none — the first draft did exactly this. They are named by
  absolute path inside the mount.
- **It does not diff `cmdline.txt` and `fstab` against `layout.sh` and call
  that a cross-check.** Both files are generated by the same emitter, so
  agreeing with it proves only that it was run twice. What matters is that
  they agree with *each other* and name the partition they were **found on**:
  a slot whose `root=` points at the other slot boots, mounts the wrong
  filesystem over itself, and is then updated in place by an update that
  believes it is writing to the spare. That check reads only the image.

**And it was falsified before being believed**, which is the step that was
missing from every check this phase got wrong. A verifier that cannot fail is
indistinguishable from one that works. Two deliberately wrong runs against the
same good image: `MOLNIYA_TARGET_DEV=/dev/nvme0n1` fails 4 checks (both cmdline
and both fstab), `MOLNIYA_LOGIN_USER=nosuchuser` fails 18 (the whole access
section, in both slots). The assertions bite.

One real defect in the first run, and it was the test's, not the image's: the
expected root device was assembled as `${TARGET_DEV}${part}`, giving
`/dev/mmcblk05` for a partition that is correctly `/dev/mmcblk0p5`. It is worth
recording because it failed in the safe direction — a *false alarm* on a good
image. The same habit of building an expected value by string-splicing, applied
one step further, is how a check ends up passing on a bad one.

##### ✅ Decision: a pinned stock image. Not pi-gen, not debootstrap.

4d left this as "pi-gen vs debootstrap, to be decided in 4a". The answer is
**neither** — the base is the official Raspberry Pi OS Lite image, taken as a
pinned binary and customised. Three things decided it, and the first is the one
that actually settles it:

1. **The official image *is* pi-gen output, and unlike a pi-gen run it can be
   pinned.** Its `.info` file names the pi-gen commit that produced it
   (`ca8aeed0…`, stage2) and the exact version of every package inside, and a
   SHA-256 is published beside it. Running pi-gen ourselves produces a
   *different* image on every run — apt moves underneath it — with no digest to
   check against. So this route gets pi-gen's product *and* a pin, without
   running pi-gen. Under Pillar 3 that is not a close call.
2. **It carries the Pi OS defaults by construction, and those are load-bearing
   now.** Verified inside the fetched image, not inferred from a package list:
   `/usr/lib/systemd/system.conf.d/40-rpi-enable-watchdog.conf` is present with
   `RuntimeWatchdogSec=1m`, and `/usr/bin/vcmailbox` is present. Those are 4d's
   watchdog mitigation and 4d's tryboot flag-setter. **A debootstrap image
   silently has neither** — which is exactly the finding recorded in 4d, now
   confirmed from the other direction.
3. **The build host is already capable.** pi-server is arm64 Debian **trixie**,
   the same release as the image, so the chroot is native and needs no qemu —
   and `losetup`, `sfdisk`, `parted`, `mkfs.vfat`, `mkfs.ext4` and `chroot` are
   all installed already. Nothing to provision. (`debootstrap` is the one tool
   absent, which is mildly funny and entirely irrelevant.)

**This also answers the objection that promoted 4a in the first place** — "a
script that assembles a system by running steps against a live box". A chroot
into a loop-mounted image is not a live box; the artifact *is* the product. And
it means the existing pinned `02*`/`03*` scripts can be reused inside the
chroot rather than rewritten, which is the difference between 4a being a
re-implementation and 4a being an assembly step.

⚠️ **Known cost, stated up front rather than discovered:** those scripts assume
a live box in places — `systemctl`, `modprobe`, reboot advice — and will need a
chroot-safe path. And Pi OS Lite's own first-boot resize (`init=…/firstboot`)
**must** be disabled or it grows the root to fill the card and eats slot B;
`layout.sh`'s cmdline emitter already omits it for that reason.

##### Builder stages

Split by artifact, each independently runnable, sequencer on top — the shape
`02-post-install.sh` already uses.

| Stage | Script | Product | Status |
|---|---|---|---|
| 1 | `image/fetch-base.sh` | verified stock `.img` | ✅ built, run on pi-server |
| 2 | `image/build-rootfs.sh` | MolniyaOS rootfs (chroot: kernel + userspace) | ✅ built, run on pi-server |
| 3 | `image/assemble-image.sh` | A/B `.img` per `layout.sh`, both slots + `slots.conf` | ✅ built, image produced |
| 4 | `image/build-image.sh` | sequencer → `.img.gz` on stdout | ✅ built, 3.6 GB streamed |
| → | `image/verify-image.sh` | structural assertions over a finished `.img` | ✅ **127/127** on the 2026-08-26 rebuild (was 96, then 98) |

- [x] **Stage 1 — fetch and verify the base.** `image/fetch-base.sh`, 172 lines.
  Downloads, verifies, decompresses, prints the `.img` path on stdout; every
  message goes to stderr so the path can be captured directly.

  **The digest is pinned in the script, not fetched from the `.sha256` beside
  the image.** A digest downloaded from the same host as the artifact proves
  only that the two agree, which a server serving both can arrange. Pinning it
  in the repo means changing the image requires a reviewed diff.

  Run on pi-server: 500 MB in 2m25s, SHA-256 matched, decompressed to ~3 GB;
  re-run is 6 s and re-downloads nothing. The image was then loop-mounted and
  its contents checked directly — that is where the watchdog drop-in and
  `vcmailbox` above were confirmed, and it proves the mount path stage 3 needs.
  Disk is checked *before* the download, because running out during
  decompression leaves a truncated file that looks like a bad download.

- [x] **Stage 2 — build the rootfs in a chroot.** `image/build-rootfs.sh`, 352
  lines. Extracts both filesystems out of the pinned base, neutralises Pi OS
  first-boot behaviour, and installs into a native arm64 chroot. Products:
  `$CACHE/rootfs/`, `$CACHE/bootfs/`, `$CACHE/rootfs.manifest`.

  **The kernel package splits across two stages**, which is not obvious and is
  written into the script header so nobody "fixes" it: `modules/` belongs to the
  rootfs and is installed here; `boot/` belongs to each slot's bootfs and is
  placed by stage 3. `install-kernel.sh` does both at once because it targets a
  live box, and it uses `os_prefix` to co-exist with the stock kernel on a
  shared boot partition — **neither applies here.** In the A/B layout a slot's
  bootfs holds only our kernel and the slot *is* the isolation, so `os_prefix`
  is a redundant indirection in the image. Stage 2 deliberately does not call
  `install-kernel.sh`.

  **This is the most dangerous script in the repo** and the header says so: it
  bind-mounts `/dev`, `/proc` and `/sys` into a directory it also deletes, and
  `rm -rf` over a tree with `/dev` still bound walks out of the work directory
  into the host. Three guards, enforced rather than remembered — every mount
  goes through `mount_into()` which records it; teardown runs from an `EXIT`
  trap so it fires on failure and Ctrl-C, not just success; and `safe_rmtree()`
  is the only place `sudo rm -rf` appears, refusing any path that is not
  absolute, not under the build cache, or still carrying mounts.

  **Run on pi-server, twice, and the second run is the one that mattered.**
  `--prep-only` took 2m15s; the full run 7m29s and genuinely installed
  `rt-tests 2.6-1.1` and `stress-ng 0.19.02-1` *inside* the chroot, which is the
  proof the chroot works at all. Fidelity was checked rather than assumed:
  73 669 files and 16 setuid binaries on both sides, and the base has no file
  capabilities so none were lost.

  Three bugs found by running it, all in the same family as the rest of this
  week — code that looks right until something proves otherwise:
  - **`rm -rf` unprivileged against root-owned trees.** Worked on the first run
    because nothing existed yet, failed on the second. It failed *loudly* rather
    than half-deleting, which is the only reason it was cheap. Now `safe_rmtree`.
  - **A manifest that lied.** The apt package list was hardcoded, so a
    `--prep-only` run emitted a manifest claiming packages it had never
    installed. A provenance file that lies is worse than none, because it is the
    thing a later reader trusts *instead of* checking. Every line now records
    what the run actually did.
  - **A comment that lied.** It claimed the base's `resolv.conf` is a symlink
    into systemd-resolved; it is a plain file. The save/restore is still right,
    but for a better reason than the one written down: shipping the build host's
    nameservers inside the image would put pi-server's DNS on every flashed
    card. Verified after a full run that the restored file is byte-identical to
    the pristine base and that the host's `1.1.1.1` did not survive.

  ⚠️ **Two findings from the base image that 4b has to answer.**
  1. **The stock image cannot boot headless into a usable state.** `pi` exists
     as uid 1000 but is **locked — no password hash** — and `userconfig.service`
     is enabled, so a first boot with no `/boot/firmware/userconf.txt` sits on
     the console waiting for a user to be created. MolniyaOS must not paper over
     this by baking in default credentials: an appliance shipping a known
     username and password is a worse failure than one that asks. The safe
     answer is the platform's own — the flasher supplies `userconf.txt`, which
     Raspberry Pi Imager already writes — and it belongs in the stage 4 release
     notes and the 4b wizard, not in the builder.
  2. **The resize token is `resize`, not `init=…/firstboot`.** The note added to
     4a on 2026-08-23 named the older mechanism. The stock `cmdline.txt` ends in
     a bare `resize`; stage 2 strips it and stage 3 writes `cmdline.txt` fresh
     from `layout.sh`, which never had it. Both, deliberately: the cost of one
     being missed is a card that eats slot B on first boot.

  ✅ **`--kernel` exercised after all.** The ROADMAP's claim that no kernel
  tarball survives on pi-server was wrong — `~/molniya/molniya-kernel-6.12.98-molniya+.tar.gz`
  has been sitting there since 2026-07-31 (corrected at its source below). A
  second run with `--kernel` installed the modules for `6.12.98-molniya+` and ran
  `depmod` inside the chroot, and the manifest records the version. So the
  rootfs is now a real MolniyaOS rootfs, not base plus bench tools.

  ⏳ **`--with-satcom` — two blockers found before the first run, 2026-08-23.**
  Both would have wasted hours, and the second would have produced a *wrong
  answer* rather than a failure.

  1. **The sequencer resolves its jobs from `$SELF_DIR`.** `install_satcom()`
     copied only `03-satcom-stack.sh` into the chroot, landing it in a directory
     where `03a`/`03b`/`03c` do not exist. It would have died on the first job.
     The whole `userspace/` directory now goes in.
  2. **Every one of those scripts prompts** — `read -r -p "… (y/N): "` in
     `02c`, `03a`, `03b` and `03c`. In a chroot with no tty `read` gets EOF, the
     variable stays empty, the case falls through to its default and the script
     **exits 3** — which `run_job` treats as a *deliberate decline* and records
     as SKIPPED. The sequencer would then exit 0, `install_satcom()` would
     report success, and the manifest would record `satcom_stack built from
     source` for a chroot in which **nothing had been installed**. Since the
     entire purpose of this run is to measure the root size, that is not a
     failed build — it is a confidently wrong number.

  Fixed with `MOLNIYA_ASSUME_YES`, an **explicit opt-in with no default**: unset
  still prompts, so running any of these by hand is unchanged, and the builder
  sets it deliberately. This is the same shape as the `pipefail`/`grep -q` bug
  and the namespace-package import — a check whose failure mode is silent
  success. It is also, independently, what a manifest-driven builder needs:
  scripts must be drivable non-interactively from declared environment.

  Also confirmed chroot-safe before launching: no `systemctl` or `reboot` in the
  SATCOM path, and `sudo` works inside the chroot (with a harmless
  `unable to resolve host` warning, since the chroot has no entry for the build
  host's name — cosmetic, and deliberately not "fixed" by writing pi-server's
  hostname into an image that ships to other people).

  ✅ **The SATCOM stack has now executed, end to end, for the first time.**
  `02c` complete (librtlsdr, rtl_433, dump1090, predict), `03a` GNU Radio
  3.10.12.0, `03b` SatDump, `03c` SDR++. Every binary present in the rootfs and
  `from gnuradio import gr` works inside it. The project's longest-standing
  liability — "written and linted but never run" — is closed for `userspace/`.

  **Two more never-executed assumptions surfaced, both fixed:**
  - **`predict` ships an interactive ncurses installer**, not a `make install`
    target. It clears the screen and blocks on a licence Y/N, so it can never
    run unattended: the first build died on `Error opening terminal: unknown`.
    Reproduced faithfully instead — read `.version`, write `predict.h`, compile,
    install — with the deliberate difference that the tree goes to
    `/usr/local/share/predict` rather than the installer's habit of symlinking
    into the build directory and baking that path into the binary.
  - **SDR++ failed CMake on a missing `libiio`**, required by its PlutoSDR
    module, which upstream defaults ON and `03c` never declared. Disabled the
    module rather than installing `libiio`/`libad9361` into every image for an
    ADI eval board a ground station will never have — the same remedy the file
    already applies to Soapy.

  ⚠️ **And one defect found but NOT fixed, which is worse than either.** CMake
  reported finding `libairspy`, `libairspyhf` and `libhackrf` — none of which
  `03c` installs. They arrive as transitive dependencies of GNU Radio and
  SatDump, installed by `03a`/`03b` moments earlier. **So which SDR++ modules
  end up in the image is decided by what earlier scripts happened to drag in.**
  Reorder the stages, or let an upstream bump change SatDump's dependencies, and
  SDR++ silently gains or loses hardware support with nothing in the log saying
  so. Note that a lock file recording installed *packages* would not catch this
  either: the variance is in which code paths were **compiled**, not which
  packages were installed. The fix is to name every `OPT_BUILD_*` explicitly ON
  or OFF; it is flagged in `03c-sdrpp.sh` so it cannot be lost.

  **Stage 2 now removes its own residue** (`clean_rootfs`). Measured: 1293 MiB
  of the finished rootfs was build leavings — 803 MiB of downloaded `.deb`s,
  147 MiB of apt lists, and 345 MiB of source trees `clone_pinned` leaves in
  `/tmp`. All of it would have been written into **both** slots by stage 3 and
  into every update bundle. The stock `6.18.34` module trees (64 MiB) are
  deliberately left: they are dead only because stage 3 removes the stock
  kernels, and stage 2 does not get to depend on stage 3's decision.
- [x] **Stage 3 — assemble the A/B image.** `image/assemble-image.sh`, 286
  lines. **The first MolniyaOS image exists**, built on pi-server in 7m54s:
  9760 MiB apparent, 4.7 GB on disk because it stays sparse.

  ⚠️ **Those two figures are the pre-SATCOM build's** and are kept only to
  date them. The image that exists now is **14 GB apparent and 11 GB on disk**,
  measured 2026-08-24 — the stack that did not fit in a 4096 MiB slot does not
  compress into 4.7 GB either. Stage 4 had to be designed around the real
  number, and a stale one sitting in this document is how it would not have
  been.

  **It contains no partition numbers, sizes or offsets of its own.** Every one
  comes from `layout.sh` — `sfdisk`, `autoboot`, `cmdline`, `fstab`, `slotmap`,
  `min-bytes`. This is the consumer that file was written for, and `fstab` was
  added to it here as a **fifth** emitter rather than being hand-written in the
  assembler: an fstab naming the other slot's root gives a box that boots,
  mounts the wrong filesystem over itself, and is then updated in place by an
  update that believes it is writing to the spare.

  **The kernel-arming step is the one that would have made the image a
  convincing fake.** The package ships `kernel-molniya.img`; the base bootfs
  ships `kernel_2712.img` and `kernel8.img`; and the stock `config.txt` has **no
  `kernel=` line at all**, so the Pi 5 firmware auto-selects `kernel_2712.img`.
  Overlay the two naively and the result boots the **stock 6.18.34 kernel** with
  MolniyaOS modules sitting unused beside it — no `PREEMPT_RT`, no latency
  guarantee, and nothing on the box mentioning it. Found by reading the package
  before the first assembly rather than after. Stage 3 now writes
  `kernel=kernel-molniya.img` into each slot's `config.txt` and deletes the stock
  kernels from that slot: inside 4d the *other slot* is the fallback, so a
  second kernel in the same slot buys nothing and leaves an ambiguity that only
  bites when the `kernel=` line goes missing. The health check's "kernel carries
  `-molniya`" assertion is the backstop if this is ever got wrong again.

  **Verified by mounting the finished image, not by trusting the log.**
  (This describes the first assembly, by hand. That image was later deleted
  for its 4096 MiB slots; the findings held on the rebuild, and every one of
  them is now an assertion in `verify-image.sh` rather than a paragraph.)
  Seven partitions matching `layout.sh` exactly; `autoboot.txt` on p1 with slot A
  default and `[tryboot]` naming B; bootfs A holding only `kernel-molniya.img`
  with `root=/dev/mmcblk0p5`, bootfs B the same with `root=…p6`; both roots
  carrying the right per-slot fstab, an identical `slots.conf`, the health check
  and its helper under `/usr/local/lib/molniya/`, and modules for
  `6.12.98-molniya+`; the data partition seeded and shared. **The cross-check
  that matters holds in both slots:** boot p2 → `root=p5` → slot A, boot p3 →
  `root=p6` → slot B, which is precisely the agreement `slot-identity.sh`
  asserts at boot.

  **One bug, found by running it.** `rsync -a` into a FAT filesystem fails every
  file with `chown … Operation not permitted` — `-a` implies `-o -g -p` and FAT
  has no ownership. It failed loudly at exit 23 rather than producing a
  half-populated bootfs, and the teardown trap left no mounts or loop devices
  behind. FAT copies now go through `copy_to_fat()`, which also dereferences
  symlinks since FAT cannot hold those either.

  ⚠️ **Two things stage 4 should deal with, neither a defect:**
  - **The roots still carry the stock `6.18.34+rpt` module trees.** With the
    stock kernels removed from both bootfs they can never be loaded, so that is
    dead weight in every slot. Removing it is image slimming, and it belongs in
    stage 4 next to compression rather than being smuggled into stage 3.
  - **`root=` is a device path, so the image is card-specific.** An image built
    for `mmcblk0` will not boot from an NVMe HAT, where the same partition is
    `nvme0n1p5`. `PARTUUID` would survive that. The decision belongs to
    `layout.sh`, and this is recorded where someone will first hit it — it also
    sharpens the U-Boot/NVMe question in 4d, since the NVMe path needs this
    fixed regardless of which bootloader gets there.

  Not verified, and cannot be from here: **that the image actually boots.** It
  has never been flashed. Everything above is structural.
- [x] **Stage 4 — sequencer, slimming, digest, release artifact.**
  `image/build-image.sh`, 274 lines. Sequences stages 1–3 (skipping any whose
  product exists, because rebuilding a two-hour rootfs to change a compression
  flag is how a sequencer becomes something nobody runs), removes the orphan
  module trees, records a digest, verifies, and hands over the image.

  **The compressed image goes to stdout and is never written on the build
  host.** That is a disk decision before it is a design one: the image is 11 GB
  on disk and pi-server has 2.2 GB free, so there is nowhere to put a `.img.gz`
  beside it. Compressing in place would mean deleting the 5 GB rootfs cache
  first — and that cache is the difference between a failed boot test costing
  minutes and costing two hours, at exactly the moment first boots fail most.

  ```
  ssh pi-server 'molniya-img/build-image.sh --stream' > molniya-rpi5.img.gz
  ```

  The image has to leave the box anyway, since nothing here can flash it. So
  streaming makes the move and the compression one pass rather than compressing
  locally and then transferring the result. **gzip, not xz or zstd**, for a
  reason that outranks ratio: Raspberry Pi Imager reads `.img.gz` directly, so
  flashing stays "select the file" instead of "decompress 11 GB somewhere
  first". `pigz` when present — four cores, and it is minutes.

  **Slimming.** The stock `6.18.34` module trees — flagged under stage 3 as
  dead weight — are gone: **two** trees per slot, not one (`-rpi-v8` and
  `-rpi-2712`), 64 MiB per slot, 128 MiB total. Orphan is defined against the
  manifest's kernel, never against a literal `6.18.34`, which would keep
  matching after a base bump and quietly stop deleting anything.

  **Run 2026-08-24.** `--slim-image` over the existing image, then a stream:
  7m28s wall for 14 GB apparent — **3.57 GB** `.img.gz`. Round trip checked
  rather than assumed: `gzip -dc | sha256sum` on the receiving box returns
  `b1c4c74c…`, the digest recorded on pi-server before compression. Also
  incidentally settles the PowerShell binary-stdout trap for this route: Git
  Bash redirection is byte-exact.

  ✅ **Two defects found by running it, both mine, both caught before shipping.**

  1. **The path was printed on stdout after the gzip stream.** `finish()` now
     sends it to stderr under `--stream`. Worth stating why it survived a read:
     gzip **ignores trailing junk**, so the `.gz` still decompresses and still
     flashes. The corruption is invisible to every check except a byte
     comparison — which is precisely the check the digest exists to be.
  2. **Mounting ext4 read-write changes the image even when no file changes.**
     Two consecutive `--slim-image` runs, the second removing nothing, produced
     two different sha256 digests: the superblock's mount count and last-mount
     time are written at mount, the journal closed at umount. For most build
     scripts a curiosity; here the digest is the artifact's identity and the
     thing the far end checks, so re-running stage 4 would silently invalidate
     a hash already published beside a download. `scan_orphans()` now looks with
     a read-only loop device first and the write pass is skipped entirely when
     there is nothing to remove. Confirmed: a second run now reports *none
     found — leaving the image byte-identical* and re-hashes to the same value.

  **`verify-image.sh --release`** carries the assertion behind the slimming: no
  module tree in a slot whose kernel is not in that slot's bootfs. It is a flag
  and not a plain check because the same state is *correct* in stage 3's output
  — stage 2 leaves those trees deliberately, not being entitled to depend on
  stage 3 removing the stock kernels. A check that prints FAIL against correct
  output is how a team learns to skim past output. Falsified before trusted, as
  ever: it failed 2 of 98 on the unslimmed image, naming both trees, and passes
  98 of 98 now.

##### The boot test — protocol, decided 2026-08-24, extended 2026-08-26 for 4d

Human hands required; nothing here can flash. **Venue: pi-server's own Pi with
its proven card physically removed.** altai is never a test venue (production
Tor bridge, the 2026-08-05 rule). A third Pi 5 is strictly better if one exists
— use it and skip the downtime.

The invariant: **the proven card is never inserted in anything that can write
while the test runs.** Worst case under this protocol is downtime, never data
loss.

**Artifact:** `X:\molniya-images\molniya-rpi5.img.gz`, 3.49 GB, built 2026-08-26.
Raw digest `9fedaa86f1e35226ba60cbf8d159aa6dae096aea369b2dda377b9d219da33fa1`,
round trip confirmed. 127/127 structural + release checks. Never booted.

⚠️ **This artifact carries no RAUC keyring** (4d, 2026-08-27). Every step below
still stands — `rauc status` does not read the keyring — but a pass proves
nothing about `rauc install`, which on this image fails with `failed to load CA
file`. If the card is being flashed after the injector has run, use the new
digest from `molniya-rpi5.img.gz.sha256`, not the one above.

1. **Flash the spare card** from `molniya-rpi5.img.gz` (Imager, "Use custom" —
   it reads `.img.gz` directly, which is why the artifact is gzip). Confirming
   the target device is the one irreversible step — verify it twice.

   ⚠️ **Decline Imager's OS customisation.** It writes `userconf.txt` and SSH
   settings into the FIRST FAT partition, which on this layout is the 16 MB
   selector holding `autoboot.txt` and nothing else — `verify-image.sh` asserts
   p1 holds exactly one file. Customising there edits the partition that
   decides which slot boots. The image already ships a provisioned account.

2. **Clean shutdown of pi-server.** Pull its card; it sits on the desk as the
   rollback state.

3. **Boot the spare, and get in.** The account is **`molniya`**, not `homelab` —
   `homelab` is pi-server's own installed system, not the image. Key-only, and
   the key in `~/.ssh/id_ed25519` is already baked in.

   Same Pi, same MAC, so DHCP will almost certainly return **192.168.1.2**. But
   the image boots as hostname `raspberrypi`, so the name `pi-server` may stop
   resolving — use the address. A fresh image has fresh host keys, so clear the
   old one or ssh refuses to connect:

   ```
   ssh-keygen -R 192.168.1.2
   ssh molniya@192.168.1.2
   ```

4. **Run the acceptance checks.** The first three predate 4d; the rest are new
   on 2026-08-26 and have never run on hardware.

   ```
   uname -r                                              # want 6.12.98-molniya+
   /usr/local/lib/molniya/slot-identity.sh                # want SLOT=A, VERDICT=consistent
   /usr/local/lib/molniya/molniya-health-check.sh; echo $?  # want exit 0
   findmnt /boot/selector -o TARGET,SOURCE,FSTYPE,OPTIONS # want ro
   sudo /usr/local/lib/molniya/molniya-boot-backend.sh get-primary   # want A
   sudo /usr/local/lib/molniya/molniya-boot-backend.sh get-current   # want A
   sudo rauc status
   systemctl status molniya-mark-good.service --no-pager -l
   ```

   **`get-primary` and `get-current` both returning `A` is the finding that
   matters.** Everything the backend has been tested against so far was a
   fixture; this is the first time it reads a real `autoboot.txt` off a real p1
   and a real partition number out of the firmware's device tree. If those two
   disagree, or either errors, stop and read `slot-identity.sh` output before
   touching anything — that is the cross-slot state 4d exists to prevent.

   **Expect advisory warnings** from the health check for the SDR dongle and
   the TLE timer. That is correct, not a failure: only CRITICAL affects the
   exit code, and a box with no dongle must never trigger a rollback.

   **`rauc` has never run on a MolniyaOS box.** If `rauc status` complains,
   capture the exact text rather than working around it; its first words are
   worth reading carefully, and `system.conf` naming a `bootloader=custom`
   handler is the part least likely to be right first time.

5. **Shut down, restore the original card, confirm pi-server is back —
   regardless of pass or fail.** Results get acted on from a healthy box, not a
   broken one.

**What a pass does and does not prove.** It proves the image boots, the kernel
is ours, the two halves of a slot agree, and the update machinery is wired up
correctly. It does **not** exercise an actual A/B update: nothing has installed
a bundle, flipped a slot, or rolled back. That needs `4d`'s bundle work and a
second image to update *to*, and it is the next thing after this test passes.

⚠️ **Disk on the build host is the tight constraint, and the estimates above
were wrong.** ✅ **Measured on the 2026-08-26 rebuild**, replacing the guessed
~18 GB / ~3.5 GB / ~9.5 GB:

| | MiB |
|---|---|
| Base image, decompressed | 2840 |
| Rootfs, cleaned, with the SATCOM stack | 4991 |
| Assembled image, **apparent** | 13856 |
| Assembled image, **allocated** (it stays sparse) | **10504** |
| Free on a 29 GB card with all of the above resident | 3433 |

**The image being sparse is the fact that makes this fit at all** — 13856 MiB
apparent against 10504 MiB actually written. `create_image`'s precheck already
reasons in written bytes rather than apparent size, which is why it passes on a
host that a naive `13856 > free` check would refuse.

The rebuild needed **~1.5 GB more than the disk had**, and it was found by
deleting `~/molniya/linux` (3075 MiB, a clean checkout at the pinned commit
`f5a99b95…`, so `git clone` restores it and the image build never touches it —
it consumes the 32 MB tarball). Recorded because the next `--force` rebuild
will need the same room, and the cheapest place to find it is the same place.

⚠️ **Do not clear the rootfs cache in a tidying mood.** It is 4991 MiB and it
is the difference between a failed boot test costing minutes and costing two
hours.

##### ✅ Root slot size — measured 2026-08-23, and 4096 MiB was wrong

The number was guessed when the layout was written and the guess did not
survive contact with a real build.

| | MiB |
|---|---|
| Full SATCOM rootfs, as built | 6347 |
| Same, after removing build residue | **5054** |
| Old slot size | 4096 → **over by 958** |
| New slot size | 6144 → fits, 1090 MiB spare, 82% full |

`layout.sh` now carries `SIZE_ROOT_MIB=6144`. That figure is not a round number
picked for comfort: **it is the largest value that still fits a nominal 16 GB
card.** Two 6 GiB roots put the minimum image at 13856 MiB against roughly
15258 MiB usable; 7 GiB roots need 15904 MiB and break 16 GB outright. So 6 GiB
is the last size before a whole class of card stops working, which is a better
reason to stop there than "it looked like enough."

Consequence worth stating plainly: **a 16 GB card now leaves only ~1.4 GiB for
captures.** It is the floor, not a recommendation, and `layout.sh summary` says
so rather than implying 16 GB is fine. 32 GB is the release-note number.

⚠️ **This invalidates the image assembled earlier the same day.** It was built
with 4096 MiB slots and without the SATCOM stack — it only "fit" because the
thing that does not fit was missing. It has been deleted rather than left
lying around looking like a MolniyaOS image.

- [ ] **Original bullets, kept for the record**
  - Takes a fresh Pi OS Lite image → applies kernel → installs all tools
  - Produces a flashable `.img.gz` file
  - Anyone can download and flash to SD card
  - ⚠️ *Promoted from "distribution convenience" to load-bearing prerequisite
    (2026-08-20): 4d (A/B updates) cannot be built on top of an in-place
    imperative install. The three sub-bullets above describe exactly that — a
    script that assembles a system by running steps against a live box. You
    cannot A/B such a system: there is no artifact to write into the other
    slot. The builder has to emit a root filesystem **image** as its product,
    not a configured machine. It is now the gate for the whole update story,
    not just for "here's a file you can flash."*
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
- [ ] **Man pages or built-in help** for MolniyaOS-specific scripts
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

#### 4d. Atomic A/B Updates & Rollback

*Adopted 2026-08-20. Target: v0.9, after the image builder (4a) exists and not
before. This is the difference between "a distro you reflash" and an appliance
you can update in the field with no network and no way to brick it.*

**The shape, in one sentence.** Two complete root filesystems live on the card at
all times; you run A, the update writes into B, you reboot into B, and if B is bad
you are one reboot from A — because A was never touched.

Rollback therefore needs **no internet**. It is not a restore from a backup; the
old version is physically still sitting there. It is a light switch, not a
rebuild. This is how ChromeOS, Android, your router, Tesla and Home Assistant OS
all do it.

**Framework: RAUC.** The two serious open-source options are RAUC and SWUpdate;
both take a signed bundle and write it to the inactive slot. Mender is a third,
but its value is a hosted fleet server — irrelevant for one box. RAUC is the pick.

**Slot decision: Pi firmware `tryboot`, not U-Boot.** Most embedded A/B setups let
U-Boot choose the slot. ~~That is a dead end here: U-Boot has no PCIe support for
the BCM2712, which breaks the moment MolniyaOS moves to an NVMe HAT.~~ ⚠️ **That
reason expired — see the re-verification below. The decision stands, the
justification does not.** U-Boot v2026.07 enables BCM2712 PCIe; what it still
cannot do is boot from NVMe. Since the Pi 4,
the second-stage bootloader lives in on-board EEPROM and is driven by text files
(`autoboot.txt`, `config.txt`, `cmdline.txt`); `tryboot` is a firmware flag that
loads an alternate config **exactly once**. Boot with the flag, and if nothing
confirms the boot, the next boot returns to the old slot on its own. RAUC ships no
official Pi firmware backend — Rtone has published one, and Home Assistant OS is a
readable working reference (tryboot with `slot-A` / `slot-B` directories on the
boot partition).

- [ ] **Partition layout — decide this first; it is the expensive thing to change**

  ✅ *Verified 2026-08-20 against the Pi firmware `autoboot.txt` documentation.
  This supersedes the two-boot-partition sketch 4d was adopted with, which was
  wrong in a way that would have cost a reflash to discover.*

  | # | Type | Contents | Size |
  |---|---|---|---|
  | p1 | FAT16 primary | `autoboot.txt` **only** — the slot selector | 16 MB |
  | p2 | FAT32 primary | bootfs A — kernel, DTBs, overlays, `cmdline.txt`, `config.txt` | 512 MB |
  | p3 | FAT32 primary | bootfs B — same contents, other slot | 512 MB |
  | p4 | extended | container for the logicals below | — |
  | p5 | ext4 logical | root A — replaced wholesale on every update | 4 GB |
  | p6 | ext4 logical | root B — same | 4 GB |
  | p7 | ext4 logical | **data (persistent)** — everything that must survive an update | remainder |

  **Three FAT partitions, not two, and the reason is structural.** The firmware
  reads `autoboot.txt` from the first FAT partition and uses its `boot_partition`
  directive to choose a slot; a `[tryboot]` section names the other one, and
  `tryboot_a_b=1` makes the switch at partition level so neither slot needs its
  own `tryboot.txt` / `tryboot.img` variants. That selector **cannot live inside
  either slot** — an update rewriting bootfs A would be rewriting the file that
  decides whether A boots at all. p1 exists so the selector sits outside both
  slots. It is the same rule as "keep the EEPROM out of the update path", one
  level up, and it is the file the Rtone backend rewrites to flip slots.

  **Why an extended partition.** `boot_partition` can only name MBR primaries,
  1–4, and three of those are spoken for by FAT. That leaves exactly one, so the
  three ext4 filesystems live in an extended partition as logicals. The firmware
  never names them — only `cmdline.txt` does — so nothing is given up.

  **Minimum card size falls out of this table** and is computed, not typed:
  `image/layout.sh summary` reports 9248 MiB consumed before the data partition
  gets anything, 9760 MiB with a token 512 MiB of it. 16 GB is the floor, 32 GB
  the number for the release notes. The script is authoritative; if this
  paragraph and `layout.sh min-bytes` ever disagree, the script is right.

  Every A/B swap replaces the root wholesale. Anything left on root is silently
  wiped on update — silently, which is the dangerous part. MolniyaOS state that must
  live on the data partition, named explicitly because each one already exists
  somewhere in this roadmap:
  - TLE elements (`~/.predict/predict.tle`) and the updater's cache — note that
    `molniya-tle-update@.service` is a template keyed on the username (`User=%i`)
    and systemd derives `$HOME` from the account database, so the script writes
    under `$HOME`. `$HOME` itself is therefore part of this boundary, not an
    afterthought (Phase 1b)
  - First-boot wizard output: hostname, callsign, lat/lon, WiFi, SSH keys (4b) —
    this is precisely the state whose loss turns an appliance back into a kit
  - Captures, decoded output, `benchmarks/` results
  - Tuned profiles: `.gnuradio/`, SatDump, SDR++ (4b)
  - Any generated cache that is expensive to rebuild. Nothing in the tree
    produces one today, but this is the category that gets forgotten precisely
    because it regenerates "for free" — and on ARM an FFT wisdom plan or similar
    is a 30–60 s first-run stall, so losing it every update would be a
    self-inflicted bug. Add entries here as the Phase 2 decoders land.

- ⏳ **Health check as the rollback trigger.** After booting the new slot, a
  systemd service runs checks and only then calls `rauc status mark-good`. Never
  marks good → next boot reverts.

  ✅ **The checker exists and has been run on hardware, 2026-08-23** —
  `image/health-check/molniya-health-check.sh`, 372 lines. Its **exit code is the
  verdict**: 0 healthy, non-zero do-not-mark-good. That is what separates it in
  kind from its seed `02a-verify-kernel.sh`, which always exits 0 on purpose;
  every check had to be re-judged as a decision that reboots a machine rather
  than a fact to print. Read-only, no sudo, no prompts, no network, no writes —
  it has to run unattended as root early in boot and by hand as an ordinary user,
  which is why 02a's `sudo modprobe ax25` did not come across.

  It deliberately does **not** call `rauc`. Keeping judgement separate from
  action is what let it be tested at all before 4a exists, and lets a human ask
  "is this box healthy?" without side effects.

  **CRITICAL vs ADVISORY is the design decision the script turns on, and it is
  not the split the bullet above implied.** Only CRITICAL affects the exit code.
  The line is *who broke it*: the image (revert fixes it) versus the operator —
  removable hardware, site config, the network (revert cannot fix it, because the
  old slot fails identically). Erring toward CRITICAL builds a box that reverts
  every update because a dongle is unplugged, then reverts again, burning the one
  recovery mechanism the design has on a fact the rollback cannot change.

  So two of the checks named above split rather than transfer:
  - *SDR enumerates on USB* → `rtl_test` **installed** is CRITICAL; a **device
    answering** is ADVISORY. Test 2 has been hardware-blocked for weeks: that is
    a healthy box with no dongle in it, and it must not revert.
  - *TLE timer loaded and not failed* → the **unit files shipping** is CRITICAL;
    an instance being enabled, or its last run having failed, is ADVISORY. 4d's
    field story is explicitly a box with **no network**, so a failed TLE refresh
    is the expected steady state out there, not a symptom.

  Checks now: kernel carries `-molniya` · PREEMPT_RT active (three-step) ·
  watchdog bound · watchdog armed · GNU Radio imports · `gr-molniya` imports ·
  SATCOM binaries present — all CRITICAL; SDR device answering · TLE timer
  instance state — ADVISORY.

  **Two checks the ROADMAP asked for were wrong as specified, and hardware said
  so.** Both were false *passes*, which is the direction that marks a broken slot
  good:

  1. **`gr-molniya` imports.** `python3 -c "import molniya"` proves nothing.
     Python invents an implicit namespace package from any directory named
     `molniya/` on `sys.path` — and the current working directory is on that path.
     Demonstrated on pi-server, where the import **succeeded** with
     `__file__ = None`, off an unrelated `~/molniya` directory, on a box with no
     gr-molniya installed. Fixed by importing a **submodule** (a namespace package
     has no code to import from) under **`python3 -P`**, so the answer cannot
     depend on where the service was started. Both were verified side by side:
     from that same directory the naive form passes and the real check fails.
  2. **One check, two subjects.** `molniya/__init__.py` re-exports the probe,
     which imports numpy, pmt and `gnuradio.gr` — so *any* import from the
     package drags in the whole GNU Radio stack, and a single check would report
     "gr-molniya is broken" when GNU Radio is what is missing, sending whoever
     reads the journal to the wrong place. Now asked separately. The dependency
     itself is correct and stays: an OOT module without its framework is not
     installed in any sense worth passing.

  **Run on pi-server, both paths:** as it stands the box reports UNHEALTHY, exit
  1 — kernel, RT, watchdog bound and armed all pass; GNU Radio, gr-molniya, SATCOM
  binaries and TLE units fail, which is correct, since pi-server has the kernel
  but no SATCOM userspace. Against a throwaway harness supplying the missing
  pieces it reports **HEALTHY, exit 0, with two advisory warnings outstanding** —
  no dongle and no TLE instance. That second run is the one that matters: it
  proves the advisory tier does not trigger a rollback, which is the whole point
  of the split. The harness was removed afterwards and the box left as found.

  ✅ **`molniya-mark-good.sh` and its unit — built 2026-08-26.**
  `image/rauc/molniya-mark-good.sh` runs the checker and calls
  `rauc status mark-good` **only on exit 0**; `molniya-mark-good.service` is a
  `Type=oneshot` enabled by symlink at image-assembly time.

  Two decisions in it are worth more than the code. **Its ordering is not
  `After=local-fs.target`**, which is what the upstream Pi backend's own
  `rauc-mark-good.service` ships: that fires while the system is still coming
  up, so the health check would be asked whether services are running before
  they had been started, and would answer "no" about a slot that is fine —
  reverting good updates. And it deliberately does **not** order after
  `network-online.target`: 4d's field story is a box with no network, so
  waiting for one would stall the commit until systemd's timeout on exactly the
  deployment this mechanism exists for.

  **There is no `Restart=`.** A boot that failed the health check must stay
  failed; retrying until it passes is a slow way of marking every slot good.

  Exit 2 (cannot decide — no checker, no rauc, no slot table) does **not** mark
  good either. That is the safe direction: it costs a rollback to a slot that
  worked, where the other direction commits a slot nobody vouched for.

##### ✅ The boot backend — built 2026-08-26, and the wait was reopened first

  ⏸️→▶️ **The 2026-08-23 decision was to wait for `rauc/rauc#1599`, re-checking
  "at the point 4a produces its first image". 4a produced it 2026-08-24, so the
  gate fired. The re-check says stop waiting.**

  | | 2026-08-23, when it was parked | 2026-08-26 |
  |---|---|---|
  | #1599 | open, milestoned v1.17 | still open — **19 months** (opened 2025-01-16), last comment 2026-08-14, `mergeable_state: clean` |
  | v1.17 milestone | a label | **1 of 10 issues closed** |
  | v1.16 | — | **not released**, 5 of 70 open |
  | Latest release | — | v1.15.2, 2026-03-27 |

  Minor releases run 5–7 months apart and v1.17 is a full release behind a
  v1.16 that has not shipped, so the honest estimate is **mid-2027**. That is
  the "actual date to reason about" the parking note asked for, and it is not a
  bounded wait.

  **The objection that justified waiting does not apply to what was built.** It
  was about carrying a *patched RAUC* that would diverge from the merged
  version — "not a merge conflict but a box that boots the wrong slot". But
  `bootloader=custom` is **stock RAUC**: a handler registered by config,
  implementing five verbs, patching nothing. It predates v1.11 (`get-current`
  was added there) and **Debian trixie ships v1.13**, so the base image can
  `apt install rauc` with no backport, no PPA and no fork. When #1599 lands,
  `bootloader=` names the native backend and `image/rauc/molniya-boot-backend.sh`
  is deleted. There is nothing to unwind.

  ⚠️ **The tree had already made this decision and the prose had not.**
  `layout.sh`'s `emit_rauc` has emitted `bootloader=custom` since it was
  written, pointing at `/usr/lib/rauc/rpi-firmware-backend` — a path that
  exists in no package, marked "⚠️ unverified against current upstream". So the
  shipped config named a backend that was never going to be there, while this
  document said the question was still open. Worth recording as a class: the
  parked decision was in prose, the live decision was in an emitter, and
  nothing made them meet.

  **`image/rauc/molniya-boot-backend.sh`, 386 lines.** It holds no state. All
  three answers derive from three facts: `autoboot.txt`'s `[all] boot_partition`
  (the committed slot), and `/chosen/bootloader/{partition,tryboot}` from the
  device tree (the booted slot, and whether this boot is a try). It has **no
  device-tree code of its own** — `slot-identity.sh` already reads those,
  endianness and all, so the backend runs it as a subprocess. Helper returns
  data, caller judges, and no `fdtget` dependency.

  **Why not vendor the Rtone backend**, which is the same author's pre-upstream
  form of #1599 and is what `layout.sh` used to name: it `source`s both
  `autoboot.txt` and `system.conf` into the shell and reads keys back through
  `eval`. That is precisely the hazard `emit_slotmap` refuses — a corrupt config
  becoming code — running as root, at boot, deciding which slot boots. It is
  also 500 lines against a 400-line cap. Its **behaviour** is the reference and
  is matched verb for verb, so the eventual swap to the native backend is a
  config change and not a change of semantics; its implementation is not.

  Its layout independently corroborates ours, which is worth something: p1
  selector, p2/p3 FAT, p5/p6 ext4, `tryboot_a_b=1` with `[tryboot]` naming the
  other slot. Two projects arriving at the same table from the same firmware
  docs.

  **The selector write is the dangerous operation and is treated as one.**
  p1 is mounted `ro` and remounted `rw` only for the instant of a write; the
  new file is written to a temp path, **read back and re-parsed**, and only
  renamed if the swap produced exactly the expected two values. FAT has no
  journal and this is the file that decides whether the box boots at all.

  **Falsified before believed — 38 assertions, all passing.** An off-target
  fixture harness drives every verb through all four states (booted-A steady,
  tryboot-into-B, post-commit, and the marked-bad rollback) and 16 refusals:
  unknown bootnames, a non-numeric `boot_partition`, `[all]` and `[tryboot]`
  naming the same partition, a shell-injection payload in `slots.conf` (rejected,
  nothing executed), a missing selector, a write that cannot succeed, and a
  `slot-identity.sh` that cannot answer. After every refusal the live selector
  is asserted unchanged.

  **And the harness was itself falsified**, by mutation: five deliberate breaks
  of the backend, four caught. The two that were not are the finding worth
  keeping:

  1. **A validation that could not fail, and was deleted.** `commit_swap`
     validated `[all]` against the slot map — and no input could tell its
     presence from its absence, because every caller resolves `get_primary`
     first, which already refuses a bad `[all]`. It was dead code of exactly
     the kind `verify-image.sh` was written to avoid: an assertion that goes on
     agreeing with itself after the code around it changes. Removed, with the
     invariant written down for the next caller. The `[tryboot]` check beside it
     **is** reachable — `get_primary` never reads that key — and is tested.
  2. **The read-back before rename looked like decoration and is not.** The
     ordinary harness cannot reach it, because `swap_stream` is correct so the
     read-back always agrees. Settled with a paired mutation instead: break
     `swap_stream`, then compare the backend with and without the check.
     **With it, the write is refused and the original selector survives
     (`[all]=2 [tryboot]=3`). Without it, a corrupt selector naming partition 2
     in both sections is installed.** It stays, on evidence.

##### ⚠️ Three defects the backend found by being written

  None of these were in the backend. They were in the image it has to run on,
  and they surfaced only because something finally had to *use* the mechanism
  rather than assemble it.

  1. **The slot selector was never mounted.** `emit_fstab` mounted p2, the root
     and p7 — and not p1. `autoboot.txt` was written at *build* time and
     verified at *build* time, so nothing noticed that the running system had
     no path to the one file it exists to rewrite. Every check of it so far had
     run against an image on the build host, never against a booted one. Now
     mounted at `/boot/selector`, `ro,nofail` — `ro` because of the journal-less
     FAT argument above, `nofail` so a pre-4d single-root card still boots.
  2. **RAUC's `data-directory` was `/mnt/data/rauc`, and nothing mounts
     `/mnt/data`.** The data partition mounts at `/data`. So RAUC's record of
     which slot is good would have landed on the root filesystem — the one
     replaced wholesale by the update it was tracking. This is the "silently
     wiped on update" hazard in this very section, applied to the bookkeeping
     of the mechanism itself. Now `/data/rauc`, created by `seed_data`.
  3. **`assemble-image.sh` hit the 400-line cap** at 393 + ~35, so the
     extraction rule fired as written. `image/rauc/provision-rauc.sh` (68
     lines) came out — split by concern, not by line count: the assembler
     builds an image, the helper installs the update mechanism into it.

  **`verify-image.sh` gained assertions for all of it**, built the way the
  SATCOM-binary check had to be rebuilt: it reads the handler path *out of the
  `system.conf` that will be used* and tests that path inside the mount, rather
  than looking for a name it remembers. The selector check is a three-way
  agreement — `slots.conf` names the selector partition, `fstab` mounts that
  partition, and the mountpoint must exist in the root — because any two of
  those agreeing is what shipped the defect above.

  ✅ **Run against a real image the same day: 127 of 127, no failures.** The
  note here previously said the additions were unexercised and the count not
  re-measured; the `--force` rebuild of 2026-08-26 settled both. All 29 new
  assertions passed in both slots on the first real artifact — including the
  one that reads the backend's path out of the `system.conf` that will actually
  be used and tests *that* path inside the mount, and the three-way selector
  agreement. Reproduced on a second independent verify pass.

  Still true, and the part that matters: **none of it has BOOTED.** 127
  structural checks say the image is built correctly, not that it runs.

##### ⚠️ The keyring was never installed — 127 of 127 on an image that could not update (found 2026-08-27)

**`system.conf` has named a keyring since the day 4d started, and nothing ever
wrote the file.** `layout.sh` emits `[keyring] path=/etc/rauc/molniya.cert.pem`;
a repo-wide search for `cert|keyring|pem|openssl` returned those two lines and
nothing else. No build stage created it, and no check looked for it.

Measured on rauc 1.13-3+deb13u1, the version in the image, this is not cosmetic:

| keyring | `rauc info <bundle>` |
|---|---|
| missing | **rc=1** — `failed to load CA file '/etc/rauc/molniya.cert.pem'` |
| present | rc=0 — `Verified inline signature by 'O = MolniyaOS…'` |

So the 3.49 GB artifact of 2026-08-26 passes **127 of 127** structural and
release checks and **would have refused every bundle it was ever offered.** The
boot test is unaffected — that exercises `rauc status`, not `install` — so this
would have survived a green boot test and surfaced at the first real update.

**This is the standard-8 shape again, and that is why it gets a section rather
than a line in a commit message.** Every check green, artifact functionally
dead, and only a check nobody had written yet could see it. The trailing path
on stdout was invisible because gzip ignores trailing junk; this was invisible
because a config key pointing at a missing file reads exactly like one pointing
at a present file until something tries to open it.

**The sharpest part: the principle was already written down and had already been
applied — just not here.** The comment above `verify_rauc` says to read the path
*out of* the config and test *that* path, and it says so because the boot
backend had taught that lesson. The keyring sat three lines below the backend in
the same generated file, and was missed anyway. A principle recorded next to one
of its instances does not generalise itself.

**So the fix is three things, and only the third one closes the class:**

1. **`image/rauc/make-keys.sh`** — the PKI. A root CA and a signing cert issued
   by it, which is the split that lets the signing key rotate: devices carry
   only the CA cert, so a reissued signing cert needs no reflash. Signing with
   the CA key directly would make the key you must never lose the same key you
   use every release.

   It **refuses to write key material inside the work tree**, resolved with
   `realpath -m` so `..` cannot walk back in. A `.gitignore` is a request; a
   private key pushed to a public repo is compromised the moment it lands and
   rewriting history does not un-publish it.

   **The CA cert is deliberately not committed either.** Shipping ours would
   make it the default trust root for every image anyone builds from this tree
   — a stranger's box installing bundles we signed. Whoever builds MolniyaOS
   generates their own, which is why `provision-rauc.sh` fails loudly rather
   than falling back to a default.

2. **`provision-rauc.sh` installs it**, at whatever path that slot's own
   `system.conf` names, from `MOLNIYA_RAUC_CERT`, parsing it with `openssl x509`
   before it goes in. Every future build carries a keyring or does not build.

3. **`verify-image.sh` asserts it — the general form.** For every file
   `system.conf` points at, the image must actually deliver it. Present is not
   enough: the file is parsed as a certificate, checked to be valid for at least
   another year, and matched against `MOLNIYA_RAUC_CERT_FINGERPRINT` when the
   operator sets one — because a truncated copy, a DER file with a `.pem` name,
   and the *wrong CA's* cert are all present, all nonzero, and all fatal at the
   moment an update is being installed.

   Verified both ways against a fixture on 2026-08-27: **FAIL on both slots**
   without the cert, ok with it, FAIL on a fingerprint mismatch, and FAIL on a
   file that is present but is not a certificate. Adds 8 checks (10 with
   fingerprint pinning), so a passing release image should now report **135**
   where it reported 127.

##### ⚠️ `local a=1 b=$a` does not work, and it bit twice the same day

`local` creates **every** name it declares as an unset local *before* assigning
any of them, so a later initializer that references an earlier name in the same
statement reads the shadowed empty local — not the value just written:

```bash
f() { local a="$1" b="$2" c="/x/root$b"; }   # c is "/x/root", or under
f 5 A                                        # set -u: "b: unbound variable"
```

Found by running `inject-keyring.sh` against a fixture — it had never run — and
then found again in `provision-rauc.sh`, written the same hour, where it would
have failed on the first real build. Under `set -u` it is a hard error, which is
the merciful case; with nounset off it is a silent empty string in a path.

A ten-line detector was run over every `*.sh` in the tree. Those two were the
only occurrences, and `verify-image.sh`'s superficially identical
`local dir="$MNT/root$slot"` is fine because `slot` is assigned on a previous
line. Worth re-running after any batch of new shell.

##### ✅ rauc is installed by stage 2 — 2026-08-26, and it is TWO packages

  `image/build-rootfs.sh`'s `APT_PACKAGES` now reads
  `rt-tests stress-ng rauc rauc-service`. Stage 2 is the right home and the
  only possible one: apt needs a chroot, stage 3 provisions a plain directory,
  and stage 2 builds the single rootfs that stage 3 copies into both slots.

  Nothing is pinned beyond what apt already guarantees, which is this project's
  standing position on apt sources — verified against the archive's signed
  Release file rather than a hand-carried digest. Confirmed available
  2026-08-26: **`rauc 1.13-3+deb13u1`, arm64, trixie main**, so the base image
  needs no backport, no PPA and no third-party archive.

  ⚠️ **The split is the part worth writing down, because it fails silently.**
  Debian's `rauc` package ships **only** `/usr/bin/rauc` and a journal catalog.
  The systemd unit and the D-Bus plumbing —
  `/usr/lib/systemd/system/rauc.service`,
  `/usr/share/dbus-1/system-services/de.pengutronix.rauc.service` and its
  policy file — are in a **separate `rauc-service` package**.

  Install only the first and two things break at once, both quietly:
  `rauc status mark-good` has no service to reach over D-Bus, and
  `molniya-mark-good.service`'s `Wants=rauc.service` names a unit that does not
  exist — which systemd logs and then carries on from. Neither shows up until
  the moment an update needs committing, which is the worst time to find out.
  `verify-image.sh` asserts **both** paths in the finished image for exactly
  that reason.

  The split is reported at two different strengths on purpose.
  `provision-rauc.sh` **warns** if the rootfs it is handed lacks either — a
  `--prep-only` rootfs, or a stale one in the build cache, is a legitimate
  intermediate state and policing stage 2 is not stage 3's job. The finished
  **artifact** is where it becomes an assertion, because an image is not an
  intermediate.

  ⚠️ **Both `image/build-rootfs.sh` and `image/verify-image.sh` now sit at
  exactly 400 lines.** The next addition to either fires the extraction rule.
  Recorded here so that lands as a decision rather than a surprise mid-change.

  ✅ **Slot identity check — built and tested on hardware, 2026-08-23.** It had
  been recorded here as needing RAUC. It does not: the firmware publishes both
  facts into the device tree, so it works on any Pi 5 with nothing installed.

  `image/health-check/slot-identity.sh` (157 lines) gathers the facts and prints
  them as `KEY=VALUE`; `molniya-health-check.sh` renders the verdict. Helper
  returns data, caller judges — the same split `detect-config.sh`,
  `governor.sh` and `thermal-state.sh` already use.

  **The question it answers is not "which slot am I", it is "do my two halves
  agree".** A cross-slot boot — bootfs A with root B — is the nastiest state in
  4d, because the box runs and looks perfect: the next update writes into what
  it believes is the inactive slot and overwrites the root it is running from.
  Naming the slot from the *boot* partition is the deliberate half of that. The
  firmware's choice is what `autoboot.txt` made and what a rollback changes; the
  root is downstream, named by that slot's own `cmdline.txt`. So boot is the
  identity and root is what gets checked against it.

  Four verdicts, each exercised on pi-server: `consistent`, `mismatch`,
  `unmapped`, `no-slotmap`. The last is **advisory, not critical** — a pre-4d
  MolniyaOS install is a single-root image with no slots, and condemning it would
  revert good updates on every box older than the A/B layout. Exit code
  separates *bad answer* from *no answer*: `mismatch` exits 0 and reports, while
  a missing device tree exits non-zero, because the caller must be able to tell
  "the slot is wrong" from "the question could not be asked".

  **The numbers come from `layout.sh`, not from the checker.** It gained a
  `slotmap` command emitting `/etc/molniya/slots.conf`, which the image build
  writes to the target. A health check carrying its own copy of p2/p3/p5/p6
  would be the two-places-one-fact hazard `layout.sh` exists to abolish — and
  the worst instance of it yet, since the consumer that drifts is the one
  deciding whether to roll an update back. The map is parsed, never sourced:
  it is read by root at boot, and values are constrained to digits. Tested with
  a shell-injection payload in a value — rejected, nothing executed.

  **Proof it can veto.** With the throwaway harness making every other check
  pass, a *consistent* map gives HEALTHY exit 0, and a *cross-slot* map with
  everything else byte-identical gives UNHEALTHY exit 1 on that one check alone.
  A box with no map at all stays HEALTHY, exit 0, warning only.

- [ ] **Bundle build + offline install.** Build the `.raucb`, sign it, put it on
  a USB stick, `rauc install /media/usb/molniya-1.4.raucb`. No network in either
  direction: not to update, not to roll back. This is the field story.

  ⏳ **The build half is done and proven off-target, 2026-08-27. The install
  half has never run, because nothing has ever booted this image.**

  ~~Build the `.raucb` on the VM~~ — **there is no VM.** That word survived from
  the sketch 4d was adopted with; the Hardware Topology has two Pi 5s and
  nothing else. The build host is **WSL Debian trixie on the Windows box**, and
  the reason is not convenience:

  | | pi-server | WSL trixie |
  |---|---|---|
  | rauc | **not installed** | 1.13-3+deb13u1 — *identical to the image's* |
  | free disk | 3.4 GB | 908 GB |
  | loop devices | yes | yes |

  A bundle carrying slot A is ~1.8 GB and the intermediate tars are another
  ~1.8 GB, so pi-server cannot hold one and the image at the same time. The
  version match is the more interesting half: bundles are built by the same
  rauc that has to read them, so a format or handler difference cannot hide
  between build host and target.

  **`image/build-bundle.sh`**, 250 lines. Mounts slot A of a finished image
  read-only, tars its rootfs and bootfs, writes the manifest, signs, and then
  verifies the result **against the CA cert rather than the signing cert** —
  because "this was signed here" and "a device will accept this" are different
  questions and only the second one matters in the field.

  ##### The payload is tars, and that is what makes a bundle fit at all

  Read out of the shipped rauc binary rather than assumed — the extensions it
  matches are `*.tar*`, `*.ext4`, `*.img`, `*.vfat`, `*.squashfs`, `*.ubifs`,
  and the handler strings `tar-extract`, `mkfs.ext4` and `mkfs.vfat` are all
  present. So for a `*.tar*` image RAUC formats the target slot and extracts
  into it.

  A raw-image bundle would carry a 4 GB ext4 and a 512 MB vfat verbatim,
  ~4.5 GB. The tars are ~1.8 GB and the uncompressed form never has to exist.
  That is the difference between a bundle that can be built on the hardware
  this project owns and one that cannot.

  Tars are taken `--numeric-owner --acls --xattrs`. Without the first, a rootfs
  extracted on the target is owned by whoever holds uid 1000 there; without the
  others, file capabilities are dropped and `ping` stops working for non-root
  after an update — both of which look like a successful install.

  ##### Format is `verity`, stated explicitly

  Left unset, rauc 1.13 defaults to `plain` and warns. verity signs a dm-verity
  root hash rather than the whole file, so the payload is checked as it is read
  instead of only up front.

  ##### The signing key cannot be encrypted at the moment of use

  Measured, not assumed: `rauc bundle --key=<encrypted.pem>` with stdin closed
  exits 1 with `PEM_def_callback: problems getting password`, and on a terminal
  it prompts. There is no `--key-passphrase`.

  **The first non-interactive run of `build-bundle.sh` hung**, and that is the
  defect worth recording rather than the fix. openssl reads passphrases from
  `/dev/tty`, not stdin, so piping one in does nothing at all — the process
  waits forever while holding a loop device and a decrypted key. A release
  build that hangs is worse than one that fails: nothing is reported, and the
  window during which a plaintext key exists is unbounded. It now refuses up
  front when the key is encrypted and there is no terminal, and takes
  `MOLNIYA_SIGN_PASS` (via openssl `env:`, never `pass:`, which would put the
  secret in `argv` where `ps` can read it) for unattended builds.

  The key is decrypted to a 0600 file under `MOLNIYA_BUNDLE_TMP` — `/dev/shm` by
  default, so the plaintext need never touch a disk — removed by an EXIT trap
  installed before the file is written.

  ##### Proven end to end on 2026-08-27, off-target, against a fixture

  The fixture is a sparse image partitioned by **the real `layout.sh`** with all
  six filesystems and both slots populated from `layout.sh` output, so nothing
  in the test carries its own idea of the layout. Against it:

  - encrypted key + no terminal → fails in under a second, does not hang
  - build → 'verity' bundle, signed by the signing cert
  - `rauc info --keyring=<CA cert>` → **verified via the chain**, which is the
    device's question answered with the device's information
  - an unrelated CA → **rejected**
  - plaintext key → gone, zero residue in the temp directory

  What this does **not** prove: that `rauc install` writes a slot correctly,
  that the backend flips `autoboot.txt` on real hardware, or that a rollback
  happens. All three need a booted box, and this image has never booted.

- [x] **Hardware watchdog** — ✅ **verified present and already armed,
  2026-08-23. Nothing to implement; the work here is to not lose it.**

  The driver binds (`watchdog0`, `bcm2835-wdt`, identity `Broadcom BCM2835
  Watchdog timer`, `state=active`, `timeout=60`), and systemd is already holding
  it: `RuntimeWatchdogUSec=1min`, `RebootWatchdogUSec=2min`, with PID 1 owning
  `/dev/watchdog0`. A hang on this box already forces a reset today.

  **The important part is where that came from.** Not `/etc/systemd/system.conf`
  — every watchdog line there is still commented out — and not from MolniyaOS. It
  is `/usr/lib/systemd/system.conf.d/40-rpi-enable-watchdog.conf`, shipped by
  Raspberry Pi OS. The kernel command line agrees, carrying `reboot=w`.

  So this item was never a task; it was an inherited default that the roadmap
  had written down as work. Two consequences, and the second is the one that
  costs money if missed:

  1. **The health check must assert it rather than assume it** — the armed
     watchdog is a property of the base image, and 4d's whole design leans on it
     as the mitigation for the unbootable-slot hole below. Something that arrives
     for free can leave for free.
  2. **This is now a live input to 4a's deferred pi-gen vs debootstrap choice.**
     A debootstrap image is not Pi OS and does not carry
     `40-rpi-enable-watchdog.conf`, so it would silently drop the one mitigation
     standing between 4d and a brick — silently, again, because an unarmed
     watchdog looks exactly like an armed one until the day something hangs. Not
     an argument that settles the choice; an item that has to be paid for
     explicitly if debootstrap wins.

- [ ] **Keep the EEPROM bootloader out of the update path entirely.** Bricking
  there is the one failure mode that requires a physical card pull, and no
  software rollback can reach it.

**What this protects against, and what it does not — state it in the docs, don't
discover it in the field.** ✅ **Table corrected 2026-08-23** against the official
firmware documentation; the version below it was right about the outcome and
wrong about the mechanism, in both rows.

| Failure | Covered? |
|---|---|
| New slot boots, but MolniyaOS is broken (bad build, missing driver, dead service) | ✅ health check never marks good → automatic revert |
| New slot never reaches Linux, **and resets or crashes** (bad kernel, corrupt initramfs, wrong DTB) | ✅ **covered, and this was previously recorded as uncovered.** The tryboot flag is cleared *before* the firmware starts, so any reset lands back on the old slot with no counter needed |
| New slot never reaches Linux and **hangs without resetting** | ❌ the real hole. Nothing forces the reset: systemd arms the watchdog, and systemd never ran |
| Committed slot becomes unbootable *after* mark-good | ❌ no tryboot involved any more; `autoboot.txt` points at it permanently |

**The mitigation story changes with it.** The watchdog is not a mitigation for
row 3 — it cannot be, since it is armed by the userspace that failed to start.
What *is* available and unused is `boot_count`: an 8-bit firmware counter,
incremented every boot, that a slot's own `config.txt` can test with
`[boot_count>N]` to select a recovery kernel or cmdline. It cannot switch
partitions (`autoboot.txt` takes no such filter), so it cannot fix row 4 either.

"Unbrickable" is still not a claim this project gets to make. "One reboot from
the last known-good userspace, and one power-cycle from the last known-good
slot **provided the box resets**" is — and the last clause is the part that was
missing.

**Operational gotcha:** on Pi 5 tryboot, plain `reboot` does **not** switch slots.
Use `systemctl reboot`, or `reboot '0 tryboot'` explicitly. Any script or health
check that reboots must use the right one or the A/B mechanism silently no-ops.

**Storage cost:** two roots plus a data partition. Size the image accordingly and
state the minimum card size in the release notes — this is also an argument for
the NVMe HAT path, which is why the U-Boot PCIe limitation above is disqualifying
rather than academic.

### ✅ The four carried-in claims, re-verified 2026-08-23

They were adopted on 2026-08-20 from a drafting session and flagged as unchecked.
All four are now closed against current upstream sources and, where the box could
answer, against pi-server itself. **Two held, one expired, one was wrong in a way
that hands 4d a mechanism it had written off.** Sources are named so the next
re-check knows what to re-read rather than re-researching from scratch.

**1. "RAUC ships no official Pi firmware backend." ✅ Holds — but it is in
flight, and that changes the build-or-wait question.** Latest release is
**v1.15.2 (2026-03-27)**, with no RPi backend. `rauc/rauc#1599` — *bootchooser:
add Raspberry Pi firmware initial support* — is **open, unmerged**, last touched
**2026-08-14**, and now carries the **Release v1.17** milestone with the
maintainer engaged and a rework branch proposed. Rtone's backend remains the
available option and says so itself: *"The native bootchooser implementation in
the RAUC tree is ongoing."*
→ **Consequence:** a hand-written backend is likely throwaway work, but v1.17 has
no date. Re-check #1599 before writing one line of custom backend.

**2. "`tryboot` is one attempt, with no boot-attempts counter and no
firmware-level fallback." ❌ Wrong on the counter. The Pi 5 has one.**
- *One-shot:* ✅ confirmed verbatim — *"The bootloader/firmware provide a one-shot
  flag which, if set, is cleared... Since the flag is cleared before starting the
  firmware, a crash or reset will cause the original `config.txt` file to be
  loaded on the next reboot."*
- *No boot-attempts counter:* ❌ **false on Pi 5 and newer.** `boot_count` is an
  8-bit reset-safe register **incremented at every boot**, wrapping at 256 and
  cleared only on power loss. **Verified live on pi-server**, two independent
  ways agreeing: `/proc/device-tree/chosen/bootloader/count` = 8, and
  `vcmailbox 0x0003008d 4 4 0` = 8. It is readable *and settable* by vcmailbox,
  and `/usr/bin/vcmailbox` is already installed on the box.
- *But it cannot pick a slot.* `autoboot.txt` is the only file that selects a
  partition and it accepts **only `[all]`, `[none]` and `[tryboot]`** — the
  expression filters that can test `boot_count` are a `config.txt` feature. So
  the conclusion "no automatic slot-level fallback" survives; the stated reason
  for it did not.
- *And "no fallback" was too broad.* A tryboot attempt that **crashes or resets**
  *does* return to the old slot by itself, because the flag is cleared before the
  firmware starts. The genuinely uncovered case is narrower and nastier: a
  **hang that never resets**. The watchdog cannot cover it either — systemd arms
  the watchdog, and in this failure mode systemd never ran.

  → **Unclaimed mitigation, new as of this check:** `[boot_count>N]` inside a
  slot's own `config.txt` can select a recovery `cmdline`/kernel/`os_prefix`
  without Linux having to run. That does not rescue an unbootable slot, but it
  converts "hangs identically forever" into "third attempt boots something
  different." Worth designing in; not designed in yet.

**3. "U-Boot lacks BCM2712 PCIe support." ❌ Expired.** Checked against the
source, not a blog: `configs/rpi_arm64_defconfig` at tag **v2026.07** sets
`CONFIG_PCI=y`, `CONFIG_PCI_BRCMSTB=y`, `CONFIG_RESET_BRCMSTB=y`,
`CONFIG_RESET_BRCMSTB_RESCAL=y`, `CONFIG_USB_XHCI_PCI=y`. PCIe enumerates.
What is still missing is **NVMe**: `CONFIG_NVME_PCI` is absent from that
defconfig, and U-Boot's NVMe driver lacks the PCIe inbound DMA address
translation the Pi 5 needs. A July 2026 series proposes both; neither is in
v2026.07.
→ **The tryboot decision stands on outcome — U-Boot still cannot boot from NVMe
— but the disqualifier is eroding and the ROADMAP's stated reason was simply out
of date.** This is the claim most likely to expire again; re-read the defconfig,
not commentary about it.

**4. "`/dev/vcio` exists only in the Pi kernel tree." ✅ Holds, both halves now
closed.** Raspberry Pi's own Upstreaming wiki lists `drivers/char/broadcom/vcio.c`
as downstream-only, alongside `vc_mem` and `dwc_otg`; the mailbox *interface* was
upstreamed back in 4.2, but the `/dev/vcio` character device was not. Bootlin
agrees independently. Item 13a already closed the half that matters locally —
`CONFIG_BCM_VCIO=y` and the device node present on the MolniyaOS kernel.
→ Building off the RPi fork is therefore load-bearing, not incidental.

**Implementation trap found while checking, worth more than the claims:**
device-tree values are **big-endian**. Reading
`/proc/device-tree/chosen/bootloader/partition` with a naive `od -An -tu4` yields
**16777216** where the answer is **1** — a wrong number that looks like a real
one. The Pi documentation gives the canonical read, and it is the form to copy:

```bash
printf "%d" "0x$(od -v -An -tx1 /proc/device-tree/chosen/bootloader/partition | tr -d ' ')"
```

**This also corrects something written in 4d's health-check note.** A slot
identity check — *am I running the slot I think I am?* — was recorded there as
needing RAUC. It does not. The firmware publishes both facts directly:
`/proc/device-tree/chosen/bootloader/partition` and `.../tryboot`. On pi-server
these read **partition 1, tryboot 0**, which is correct for a box that has never
been through an A/B install. That check can be written and tested now.

**Explicitly still not decided:** pi-gen vs debootstrap for the artifact build.
That belongs to 4a — now with the watchdog drop-in finding as a live input.

---

## Career Alignment: SATCOM Job Skills Map

Based on actual SATCOM job postings, here's how MolniyaOS maps to career skills.
CCNA is explicitly listed as valued in SATCOM roles — your networking background
is a direct asset.

| Job Requirement | Where You Learn It in MolniyaOS |
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

### Certifications That Stack Well with MolniyaOS Experience

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
                 BUILT and pinned (6.12.98-molniya+, f5a99b95) 07-31, INSTALLED
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
                 + gr-molniya discontinuity probe (first custom block)
                 Install scripts written and pinned; no build has run.
                 Probe implemented; its math is unit-tested, its GNU
                 Radio shell has never run.
v0.4   ......    Automated capture pipeline (scheduled sat passes)
v0.5   ......    Protocol decoders (Iridium, AIS, APRS/direwolf)
                 + gr-satellites upstream PR; revisit IceSickle decoder
v0.6   ......    Field deployment kit (WiFi AP, WireGuard, web dashboard,
                 optional Tor bridge module)
v0.7   ......    Monitoring stack (logging, Grafana, RF baseline)
v0.8   ⏳ ACTIVE  Image builder (reproducible, distributable .img.gz) —
                 artifact-based build, A/B-ready partition layout laid down
                 from the very first image
                 CODE-COMPLETE 2026-08-24, artifact rebuilt 08-26 to carry 4d.
                 All four stages built and run on hardware. Artifact exists —
                 3.49 GB, 9fedaa86…, 127 of 127 structural + release checks —
                 and HAS NEVER BOOTED. What remains needs a card reader and a
                 spare card, not code.
                 ⚠️ That 127/127 is against the checks that existed when it was
                 built. The keyring gate added 08-27 fails it: the image ships
                 no /etc/rauc/kosmos.cert.pem, so rauc refuses every bundle.
                 inject-keyring.sh fixes the artifact; provision-rauc.sh fixes
                 every future build. See 4a PICK UP HERE.
v0.9   ⏳ ACTIVE  Atomic A/B updates (RAUC + tryboot), health-check gate,
                 offline USB bundle install, automatic rollback
                 BUILT: partition layout (three FAT partitions, p1 the selector
                 outside both slots); boot backend, stock RAUC via
                 bootloader=custom, no fork; rauc + rauc-service installed by
                 stage 2; health check, exit code as the verdict, run on
                 hardware; watchdog verified already armed by the base image.
                 Signing PKI and bundle builder done 08-27 and proven
                 off-target against a fixture — CA plus rotatable signing cert,
                 verity bundles carrying tars, verified against the CA and
                 rejected under an unrelated one.
                 NOT DONE, and every item needs a booted box: rauc install has
                 never written a slot, the backend has never flipped a real
                 autoboot.txt, no rollback has ever happened, and the offline
                 USB install has never been performed. A second image to update
                 TO does not exist yet either.
v1.0   ......    Full release — documented, tested, flashable image
```

---

## Repository Structure

`✅` exists as of the 2026-07-30 overnight branch, `·` still to build.

```
MolniyaOS/
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
├── gr-molniya/                   # Custom GNU Radio blocks (OOT module)
│   ├── ✅ README.md             # Includes why there is no CMakeLists.txt
│   ├── ✅ install.sh            # Development install (.pth + GRC yml)
│   ├── ✅ grc/                  # GRC block definitions
│   └── ✅ python/molniya/        # discontinuity probe + gap_math.py & its tests
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
│   ├── ✅ molniya-tle-update@.service # The refresh as a unit; instance = username
│   ├── ✅ molniya-tle-update@.timer   # Twice daily, spread, persistent
│   ├── ✅ install-tle-timer.sh  # Installs the timer for one account
│   ├── ✅ rtl-power-heatmap.py  # rtl_power CSV → spectrum heatmap PNG
│   ├── ✅ molniya-governor.service  # Pins the CPU governor at boot
│   ├── ✅ molniya-set-governor.sh   # The governor write itself
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
│   ├── ✅ layout.sh             # A/B layout: THE single source of truth
│   ├── ✅ fetch-base.sh         # Stage 1: pinned stock Pi OS Lite, verified
│   ├── ✅ build-rootfs.sh       # Stage 2: chroot install of kernel + userspace
│   ├── ✅ assemble-image.sh     # Stage 3: A/B image per layout.sh
│   ├── ✅ build-image.sh        # Stage 4: sequencer → .img.gz
│   ├── ✅ verify-image.sh       # Assertions over a finished .img; read-only
│   ├── ✅ build-bundle.sh       # Signed .raucb from a built image (tars, verity)
│   ├── ✅ inject-keyring.sh     # One-shot: keyring into an image built without one
│   ├── rauc/                    # The A/B update machinery (4d)
│   │   ├── ✅ molniya-boot-backend.sh   # RAUC custom backend: the five verbs
│   │   ├── ✅ molniya-mark-good.sh      # Runs the checker, marks good on exit 0 only
│   │   ├── ✅ molniya-mark-good.service # Ordered late; no Restart=
│   │   ├── ✅ provision-rauc.sh        # Installs the above into one slot root
│   │   └── ✅ make-keys.sh             # The CA + signing cert. NO key material,
│   │                                   # AND NO CERT, is ever committed here —
│   │                                   # a shipped CA cert would make this repo
│   │                                   # the trust root for other people's boxes.
│   │                                   # Build yours; point MOLNIYA_RAUC_CERT at it.
│   └── health-check/            # The verdict the mark-good gate consumes
│       ├── ✅ molniya-health-check.sh # The verdict: exit 0 = safe to mark good
│       └── ✅ slot-identity.sh       # Which slot booted, and do boot+root agree (helper)
└── ✅ .gitignore

(NOT in this repo: gr-icesickle — lives with the IceSickle project; runs ON
MolniyaOS, doesn't ship IN it.)
```

**Packaging note:** `package-kernel.sh` copies the Pi-side scripts into the kernel
tarball from two different directories, and hard-fails on any that are missing.
That list has to be updated in the same commit as any rename or split under
`userspace/` — a tarball missing one of them looks complete and fails on the Pi.
It currently carries `install-kernel.sh` and the whole `02` set. The `03` set,
`benchmarks/`, `automation/` and `gr-molniya/` are deliberately **not** packaged:
none of them are needed to get the kernel running, and they are run from a clone
of the repo on the Pi.

---

## Immediate Next Steps (ordering per 2026-07-29 audit)

**Do first — cheap, everything downstream depends on them:**
1. ~~Settle C vs K~~ ✅ **K** — MolniyaOS
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

   1. **B — ran from the MolniyaOS boot already in place.** No reboot needed.
   2. **C — reached by editing `/boot/firmware/molniya/cmdline.txt` directly**,
      appending `nohz_full=1-3 rcu_nocbs=1-3`, then rebooting. **Not** by re-running
      the installer: `install-kernel.sh` resolves its package directory from its own
      location and needs `boot/`, `kernel-version` and `modules/` beside it — that
      is the extracted tarball, not the repo clone. Back up the file first; it
      must stay a single line.

      ✅ **Corrected 2026-08-23: a tarball *does* survive on pi-server** —
      `~/molniya/molniya-kernel-6.12.98-molniya+.tar.gz`, 32 MB, dated 2026-07-31,
      alongside the staged `molniya-kernel-pkg/` and the 3.1 GB `linux` build
      tree at the pinned commit `f5a99b95…`. The claim above was written when
      nobody had looked. Finding it is what let 4a stages 2 and 3 produce a real
      MolniyaOS image rather than a base-plus-bench-tools one, so the correction is
      worth more than the disk it occupies.
   3. **A — already banked**, so no third boot. To redo it: comment the two
      directives in the MolniyaOS block of `config.txt` and reboot.

   Confirm the configuration after every reboot before running anything —
   `detect-config.sh` must print the expected letter. For C that check is not a
   formality: it was the only available evidence that the firmware reads
   `molniya/cmdline.txt` at all, since without the dynticks append that file is
   byte-identical to the stock one and B is indistinguishable from a fallback.
   ✅ **It passed 2026-08-02** — `detect-config.sh` prints C and
   `/sys/devices/system/cpu/nohz_full` reads `1-3`, so `os_prefix` command-line
   isolation is proven end to end.

   ⚠️ **`summary.tsv` is append-only; raw files are not.** A re-run overwrites
   `config<X>-<load>-<affinity>.txt` but appends six more rows, so a repeated pass
   leaves duplicate rows whose raw evidence has been destroyed. This happened: B
   ran twice, and the earlier pass's rows had to be removed because nothing backed
   them. Check the row count before transcribing.

   ~~Fill `uname -v` into `BENCHMARKS.md`~~ ✅ **already done; this instruction
   was stale.** `BENCHMARKS.md:89` carries `#1 SMP PREEMPT_RT Fri Jul 31
   02:36:12 BST 2026`, and it was re-read off pi-server on 2026-08-23 and matches
   the running kernel byte for byte. No `(fill after first boot)` marker survives
   anywhere in the tree.

   ⚠️ **`--quick` rows are indistinguishable from real ones.**
   `run-latency-bench.sh` appends to `results/summary.tsv` with no loop-count or
   quick-mode column, so a 100k-loop smoke run leaves six rows that look
   publishable. Always smoke-test with `MOLNIYA_BENCH_OUT=/tmp/bench-smoke`.

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
     installer's `^os_prefix=molniya/` grep will behave as designed.
   - [x] **`/lib/modules` inventoried** — four sets already present:
     `6.12.47+rpt-rpi-2712`, `6.12.47+rpt-rpi-v8`, `6.12.62+rpt-rpi-2712`,
     `6.12.62+rpt-rpi-v8`. MolniyaOS adds a fifth in its own versioned directory.
   - [x] **Config-A baseline confirmed**: running `6.12.62+rpt-rpi-2712`,
     `#1 SMP PREEMPT Debian 1:6.12.62-1+rpt1`. Exactly the ROADMAP's expectation,
     so no pinning is needed for the baseline.
   - [x] **Governor unit installed, and verified across a reboot 2026-07-31.**
     Rebooted from 34 days' uptime; 16 seconds into the new boot the journal shows
     `molniya-set-governor: 'performance' set on 4 core(s)`, all four cores read
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
   - [x] **MolniyaOS cloned** to `~/MolniyaOS` on pi-server.
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
   user compiling a kernel is not a case MolniyaOS is designed for.
   The temperature is recorded here for one reason only: it establishes that **this
   hardware saturates its cooling under sustained all-core load**, and the
   benchmark is exactly that kind of load. It is evidence about the *benchmark's*
   validity, not a build requirement, and it should never be quoted as one.

   - **Disk.** The `CONFIG_DEBUG_INFO_NONE=y` reasoning held: debug info is what
     makes kernel object trees enormous, and without it the tree stayed at ~4 GB.
     **The README's 40 GB figure was confirmed far too conservative.** ✅ **Revised
     2026-08-05** to 10 GB, with both the disk and RAM figures stated as measured
     and the `CONFIG_DEBUG_INFO_NONE=y` reason recorded beside them.
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
13. ~~**A/B pre-checks (no purchase, no reboot required)** — on pi-server~~
    ✅ **both run 2026-08-23**, against the running MolniyaOS kernel
    (`6.12.98-molniya+`, `#1 SMP PREEMPT_RT Fri Jul 31 02:36:12 BST 2026`).
    Full findings in 4d; the short version is that **the mechanism is available
    and the pin protecting it was broken.**

    a. **`/dev/vcio` is present** — `crw-rw---- root video 10, 257` — and
       `CONFIG_BCM_VCIO=y` is in `/proc/config.gz`. tryboot's kernel dependency
       is real on this hardware, so 4d's slot mechanism stands as designed and
       RAUC config work is unblocked.

       **But the pinned symbol name was wrong.** `sdr-rt.config` pinned
       `CONFIG_BCM2835_VCIO`, which does not exist in the Pi tree. This is the
       failure this check was written to catch, and it is worth stating exactly
       why it was invisible: `merge_config.sh` does not fail — or even warn — on
       a symbol it has never heard of, and the Pi defconfig sets the real symbol
       anyway. So the kernel came out correct, the pin contributed nothing, and
       *nothing anywhere would have said so.* A pin whose only evidence of
       working is that the default already agrees with it is not a pin.

       **Sharper still: the running kernel is not evidence about the fragment at
       all.** It was built 2026-07-31; the 4d block was added to
       `sdr-rt.config` on 2026-08-20 (`ccdc5e9`). The fragment has therefore
       never been through a build. `CONFIG_BCM_VCIO=y` on this box comes from
       the Pi defconfig and nothing else, and the corrected pin remains untested
       until the next kernel build runs — at which point the new gate is what
       will actually exercise it.

       Fixed to `CONFIG_BCM_VCIO=y`, and both 4d symbols were added to
       `verify_critical_config()` in `01-build-kernel.sh` — reading the merged
       `.config` back is the only check that can catch a name the merge silently
       discards. Note this was **luck, not a near miss**: had the guess been
       wrong on a symbol the defconfig does *not* supply, the mechanism would
       have been absent and discovered only when tryboot failed on a box in the
       field.

    b. **The watchdog driver binds** — `/sys/class/watchdog/watchdog0` →
       `107d200000.watchdog/bcm2835-wdt`, identity `Broadcom BCM2835 Watchdog
       timer`, `state=active`, `timeout=60`, `bootstatus=0`. Not merely set in
       config: bound, on BCM2712, on this kernel.

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

*MolniyaOS v0.2 — Built from bare metal, aimed at the stars*
*Target: Raspberry Pi 5 (BCM2712, ARM64)*
