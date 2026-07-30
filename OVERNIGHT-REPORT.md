# Overnight session report — 2026-07-29 → 2026-07-30

> **Follow-up 2026-07-30: all six review decisions are applied.** See
> [Decisions applied](#decisions-applied) at the end. The "Blocked on you" and
> "Decisions I made that you may want to reverse" sections below are the
> *original* overnight state, kept as written; where a decision has since settled
> one of them, it is marked ✅ there and detailed at the end.

Branch: **`overnight-20260729`**, 18 commits, not merged.
`main` untouched. Nothing was run on pi-server or altai. No hardware, no secrets,
no router, no kernel build, no Tor bridge migration, no step 9.

Review it with:

```bash
git log --oneline main..overnight-20260729
git diff main...overnight-20260729
```

Every commit message says what was verified and what was not. If you read nothing
else here, read **"Three real bugs found"** and **"Blocked on you"**.

---

## What landed

| | Commit | |
|---|---|---|
| 1 | `fd59ea0` | Split `02-post-install.sh` into four standalone job scripts |
| 2 | `abf743c` | Pin and verify every source `02c` builds |
| 3 | `f9dba73` | SATCOM stack installer, pinned from line one |
| 4 | `e18ab89` | Benchmark harnesses and the results template |
| 5 | `85640c3` | Performance-governor unit and installer |
| 6 | `8b5c0f4` | TLE updater; predict path fix and a bad CelesTrak query |
| 7 | `df7e3a0` | GPLv3 `LICENSE` and a licensing section |
| 8 | `416fe7f` | CI: shellcheck gated at zero |
| 9 | `471d9bd` | `gr-kosmos` scaffold and the probe skeleton |
| 10 | `a1902de` | `config/frequencies.md` and `config/antennas.md` |
| 11 | `33cb463` | README contents table and ROADMAP layout brought in line with the tree |
| 12 | `c856e69` | This report |
| 13 | `a04dc57` | Record the CI result once it had actually run |

Then, applying the 2026-07-30 review decisions:

| | Commit | |
|---|---|---|
| 14 | `cab1755` | Verify a `CATNR` response is the satellite that was asked for |
| 15 | `878f9c8` | Split packaging out of the build; record the source commit |
| 16 | `18dfe62` | Record three decisions from the review |
| 17 | `4baa55a` | SPDX headers throughout; `sdr-rt.config` as GPL-2.0-only |
| 18 | *(this)* | Report follow-up |

All ten original items are done, and all six review decisions are applied.
**shellcheck 0.10.0 clean at zero across all 18 scripts, including `-S style`.**
Longest script is 393 lines, under the 400 cap.

---

## Three real bugs found

These were not on the task list. They came out of verifying things rather than
writing them, and two of them were breaking behaviour today.

### 1. `GROUP=noaa` is not a valid CelesTrak query

`02c` and the README both fetched
`gp.php?GROUP=noaa&FORMAT=tle`. That query returns **HTTP 200** with the body:

```
Invalid query: "GROUP=noaa&FORMAT=tle" (GROUP=noaa not found)
```

`wget` reports success, writes 61 bytes of prose into `noaa.tle`, and the `||`
fallback never fires. Anything reading that file has been reading an error
message.

Worse: `GROUP=weather`, which *is* valid, **does not contain NOAA 15, 18 or 19** —
only NOAA 20 and 21, the JPSS birds. The APT satellites this project targets first
are reachable only by catalogue number (25338, 28654, 33591). All verified against
the live API.

Fixed in `02c` and the README; `tle-updater.sh` fetches by catalogue number and
validates every download.

### 2. TLEs were landing where predict never looks

Known and recorded in the ROADMAP, now actually fixed: `~/.predict/predict.tle` is
the only file predict reads, and nothing was writing it. Every `predict -p` answer
came from whatever elements the curses installer shipped with — silently stale,
with nothing on screen to say so.

### 3. `GROUPS` is a bash built-in

My own bug, found by running the TLE updater end to end rather than reading it.
`GROUPS=(weather goes amateur)` looks fine and does nothing: bash defines `GROUPS`
as an array of the current user's group IDs, and per the manual *"assignments to
GROUPS have no effect"*. The loop iterated over a GID and fetched
`GROUP=197121`.

It failed safely, because every download is validated — but it failed *silently*,
and neither `shellcheck` nor `bash -n` saw it. Renamed `TLE_GROUPS`, with the
reason recorded at the declaration. Worth remembering the class of bug: a bash
special-variable collision is invisible to static analysis.

---

## What was actually verified, and how

I could not touch the Pi, so I verified everything that does not need it. This is
the honest list.

**Ran against live upstreams:**

- All six pinned commits fetch and verify: rtl-sdr-blog `v1.3.6`, rtl_433 `25.12`,
  dump1090 `v11.1`, predict (2018 tip), SatDump `1.2.2`, SDR++ master `8c9f5ee`.
  None of these SHAs is invented; each was read from the upstream repository and
  then fetch-tested.
- The pin-mismatch path rejects a wrong SHA and an empty SHA.
- `tle-updater.sh` end to end: 5 satellites by catalogue number and 3 groups
  (74 + 6 + 93 satellites) all validate; the installed `predict.tle` is 15 lines in
  predict's expected layout; backup rotation holds at five across eight runs.
- Every Debian package name in `03a`/`03b`/`03c` exists in both bookworm and
  trixie. Version pins were read from the Debian archive.
- SatDump's and SDR++'s dependency lists and build commands were read from their
  own docs **at the pinned commit**, not from memory.

**Tested with fixtures:**

- The `02` sequencer's four exit paths — install, user declined, real failure,
  missing job script — against stubs.
- `cyclictest` output parsing, including the fallback when the histogram footer is
  absent, and `rtl_test` parsing including a clean run reporting 0 rather than
  empty.
- The TLE checksum validator against the real CelesTrak error page, a flipped
  digit, a truncated record, a short line, an empty file, and CRLF endings.
- All four CI gates, each against a fixture that should trip it and one that
  should not (a `fish` script must not trip the shell-shebang gate).
- The `gr-kosmos` GRC definition cross-checked programmatically against the Python
  block — make template, `__init__` signature, class name, dtype. A mismatch there
  is the classic silent failure in a hand-written `.block.yml`.

**Not verified — first run is the test:**

- **No build in `02c` or `03` has been executed.** Not one. They need the Pi.
- The governor unit has never been installed; whether it survives a reboot is the
  entire point of it and is exactly what I could not check.
- Neither benchmark harness has run. `rtl_test` output parsing in particular is
  written against its documented format — **use `--quick` first**, both harnesses
  have it, before committing to a multi-hour sweep.
- Nothing in `gr-kosmos` has run under GNU Radio.

**Verified after the push:** the CI workflow ran on this branch and passed. Run
[30517497558](https://github.com/Mezo-oz/KosmOS/actions/runs/30517497558) — pinned
shellcheck 0.10.0 installed against its SHA-256, 17 scripts checked, zero
findings, and all three side gates green.

---

## Blocked on you

Nothing here was attempted. Each is behind one of the prohibitions, or is a
decision that is yours.

0. **Gate 0 — get the bridge off pi-server and confirm it live from altai on Tor
   Metrics.** Ahead of everything else on this list; see
   [Decisions applied](#decisions-applied). Needs the fingerprint, so it is yours
   by definition.
1. **Step 9 — the kernel rebuild, reinstall and benchmark.** Off limits, and it is
   the critical path for v0.25. Gate 0 first, then the ROADMAP pre-flight, plus
   one addition: `sudo bash automation/install-governor.sh` and confirm
   `performance` survives a reboot *before* generating any numbers. Set
   `KERNEL_COMMIT` at that rebuild and copy the SHA into `BENCHMARKS.md`.
2. **First run of `03a`/`03b`/`03c` on pi-server.** Long builds, untested.
   `03a` first — the other two check for its output.
3. **Installing the governor unit.** It masks `ondemand.service`, which is
   service-affecting. Reversible with `--uninstall`.
4. **Putting `tle-updater.sh` on a timer.** Cron line is in its header.
5. **The RTL-SDR v4 order**, which gates Test 2 and Test 3 entirely.
6. ✅ **Two licensing decisions I deliberately did not make for you** — both
   settled, see [Decisions applied](#decisions-applied).

---

## Decisions I made that you may want to reverse

Each of these was a judgement call with a real alternative. I picked one and
documented why in the relevant file; here is the short list so you can find them.

**GNU Radio comes from apt, not source.** The one deliberate exception to
building from source. Its dependency chain is a multi-hour build on four A76 cores,
redone on every bump; Debian ships the current 3.10.x series; and apt authenticates
against a signed `InRelease`, which is a stronger supply chain than a git clone.
Reverse it if a decoder ever needs something Debian's build lacks.

**`03` splits into `03a`/`03b`/`03c` with a sequencer,** mirroring what the `02`
split turned into. One file would have blown the 400-line cap, and these are
hour-scale builds you will want to run one at a time.

✅ **The benchmark runs pinned *and* unpinned affinity in every configuration.**
Kept, and now recorded as settled in the ROADMAP, `BENCHMARKS.md` and the script
header — explicitly not to be traded away for runtime. See
[Decisions applied](#decisions-applied).

**`taskset` is paired with `-a 1-3 -t 3`, not `-S`.** Not redundant: `-S` derives
one thread per *online* CPU and pins thread 0 to CPU 0, which is outside the
taskset mask, and fails.

**Declining the SDR install still skips the locale step.** That is the old script's
behaviour, inherited on purpose rather than quietly fixed. `02c` exits 3 to mean
"user declined" and the sequencer stops. Two-line change to decouple, documented in
the sequencer header.

**The `02c` step labels renumbered** from `[1/7]..[6/7]` to `[1/6]..[6/6]`. The only
intentional output change in the split. A script that prints `[6/7]` and exits
successfully reads as a bug.

**`librtlsdr-dev` is left out of both `03` dependency lists,** even though
SatDump's own docs include it. Debian's is the osmocom original and cannot drive a
v4; `02c` installs the Blog fork into `/usr/local`. Two builds sharing one SONAME
is how you get "no supported devices found" with a working dongle plugged in. `03b`
and `03c` refuse to build without `/usr/local/include/rtl-sdr.h`. Same reason
`soapysdr-module-rtlsdr` is not installed and SDR++'s Soapy source is built OFF
(which is also upstream's default).

**SatDump installs to `/usr/local`, not `/usr` as upstream documents.** Keeps dpkg's
tree clean. `INSTALL_PREFIX` at the top of `03b` if it cannot find its resources.

**No `CMakeLists.txt` in `gr-kosmos`.** A full OOT module's build system is
generated by `gr_modtool newmod kosmos`, not written. Hand-writing several hundred
lines of version-specific CMake that nobody has run would look authoritative and
fail on the Pi. `install.sh` does a development install instead.

**apt pins warn rather than fail by default.** Debian rebuilds packages
per-architecture with a `+b1`-style suffix, which the installer accepts as the same
source. But these versions were read from the Debian archive, not off the Pi, so a
first run could find a third value. Default is a loud warning plus the actual
version recorded; `KOSMOS_STRICT_PINS=1` makes it an error.

**The CI workflow carries three gates beyond shellcheck** — shell scripts must be
named `*.sh`, no CR bytes where a CR breaks something, no script over 400 lines.
Each enforces a rule the project already states, and each is a separate step you
can delete alone. Only the shellcheck one was asked for.

---

## Things I was unsure about

- **`predict` tracks at most 24 satellites.** That is from predict's own
  documentation and I could not check it against the binary. `tle-updater.sh`
  enforces it as a cap because exceeding it fails quietly in predict rather than
  loudly. If the real limit is different, the cap is still safe.
- **GRC's block search path.** `gr-kosmos/install.sh` puts the `.block.yml` under
  the prefix `gnuradio-config-info` reports, which is where installed modules put
  theirs. If GRC does not show the block, that is the first thing to check;
  `local_blocks_path` under `[grc]` in `~/.gnuradio/config.conf` is the sudo-free
  alternative and is mentioned in the script's output.
- **Frequencies in `config/frequencies.md`** marked ⚠️ are the ones I am least
  confident are current, mostly Meteor-M downlinks and per-satellite HRPT. I chose
  to mark them rather than drop them; a cheatsheet that reads as authoritative and
  is six months stale is worse than one that says which rows to re-check.
- **`dump1090 v11.1` is not on `master`'s tip.** The tag is newer than the default
  branch head, which is unusual. `clone_pinned` fetches the commit directly so it
  works either way, but it is worth a glance at upstream's branching before
  trusting `v11.1` as *the* release.
- **File-size headroom, still the standing pressure.** `tle-updater.sh` is at 393
  and `run-latency-bench.sh` at 392 — the SPDX pass cost every script a line, and
  the build script already had to be split to stay legal. The two benchmark
  harnesses duplicate ~80 lines of governor handling, config detection and load
  generation; that is the obvious extraction when either next grows. It has to be
  an *executable helper*, not a sourced library, or shellcheck needs
  `--external-sources` and the tree stops being clean at zero without flags. Same
  reason `clone_pinned` is duplicated across `02c`, `03b` and `03c`.

---

## Recommended order when you pick this up

1. Skim `git diff main...overnight-20260729`. The doc files and the licensing
   section are the least mechanical changes; the SPDX commit is 32 files of one
   line each and can be read in a minute.
2. Merge or cherry-pick. Four commits change existing behaviour — the `02` split,
   the pins, the packaging split, and the licensing headers. The rest is additive.
3. **Gate 0**: bridge off pi-server, verified live from altai on Tor Metrics.
4. On pi-server: `install-governor.sh`, reboot, confirm `performance` sticks.
5. `run-latency-bench.sh --quick` to prove the harness, then the step-9 rebuild
   — setting `KERNEL_COMMIT` and copying the SHA into `BENCHMARKS.md` — then the
   real A/B/C.
6. `03a` → `03b` → `03c` when there is an evening to spare.

---

## One thing I would flag unprompted

✅ **Settled — pin at step 9, not before.** `kernel/01-build-kernel.sh` still
clones `raspberrypi/linux` at `--branch rpi-6.12.y`, whose tip moves, so two
builds weeks apart are not the same kernel. The mechanism is now in place and
inert; see [Decisions applied](#decisions-applied).

---

## Decisions applied

Six decisions came back on 2026-07-30. All are applied; this is what changed.

### 1. NOAA TLEs — fetch by `CATNR`, validated live ✅ `cab1755`

Re-validated all three catalogue numbers against the live API before committing.
Each returns a real three-line element set, both element lines checksum-clean,
epoch day 211 of 2026:

| Satellite | NORAD | Result |
|---|---|---|
| NOAA 15 | 25338 | name, checksums, catalogue number all verified |
| NOAA 18 | 28654 | as above |
| NOAA 19 | 33591 | as above |

Validating them turned up a gap worth closing. A `CATNR` query returns whatever
CelesTrak holds for that number, so a typo in the list fetches a real,
checksum-clean TLE **for the wrong satellite** — and `validate_tle` cannot see
that, because there is nothing wrong with the data. It is a failure with no
symptom: predict answers confidently, the antenna points somewhere, nothing
arrives. `validate_catnr()` now checks the catalogue number in columns 3–7 of both
element lines against what was requested.

The README one-liner is fixed the same way and keeps the error-page guard — it
checks the *content*, not `curl`'s exit status, because an invalid group query
answers HTTP 200 with prose.

### 2. Affinity matrix — kept ✅ `18dfe62`

Recorded as settled in three places, with the explicit note that it is not to be
traded down for runtime: if a run must be shortened, drop a load condition, not
the affinity matching. The ROADMAP's one-liner is replaced with both commands,
including why `-a 1-3 -t 3` is not redundant with `taskset`.

### 3. Kernel pin — at step 9, mechanism ready now ✅ `878f9c8`

Nothing about which kernel gets built changes today: `KERNEL_COMMIT` is empty,
which keeps the existing behaviour exactly. Setting it switches to an init+fetch
of that exact commit and verifies `HEAD` against it — a one-line edit at the
rebuild.

What is new is that every build now **records** what it built: the SHA is
printed, written into the package as `kernel-commit`, and an unpinned build prints
the exact `KERNEL_COMMIT="..."` line to paste back. Without that there would be
nothing to pin *to* after the fact. `BENCHMARKS.md` has a kernel-provenance table
to fill in at the rebuild.

**Side effect worth knowing about:** that addition took `01-build-kernel.sh` to
417 lines, over the 400 cap. The rule says a script that outgrows the cap gets
split, not that its comments get trimmed to fit — so packaging moved to
`kernel/package-kernel.sh` (build 316 lines, package 160). That also means
repackaging no longer requires rebuilding: edit a Pi-side script, re-run the
packager, get a tarball in seconds instead of ninety minutes. Verified against a
fake kernel tree — 21 checks covering tarball contents, the recorded commit, and
both abort paths.

### 4. Licensing ✅ `4baa55a`

`kernel/sdr-rt.config` is GPL-2.0-only; everything else GPL-3.0-or-later. SPDX
headers on all 33 tracked files except `LICENSE` itself — line 2 in shell scripts
so the shebang stays first, HTML comments in Markdown so nothing renders.

One line per file rather than a full REUSE block, matching the kernel's own
convention, and **no copyright line was added to any file** — attribution stays
"the KosmOS authors" in the README, and your name appears nowhere in the repo.

### 5. Do not merge ✅

Not merged. `main` is still `2fc18b1`, byte-identical to where you left it.

### 6. Sequencing — gate 0 before step 9 ✅ `18dfe62`

Added to the ROADMAP ahead of the existing pre-flight, with three checkboxes:
nothing bridge-related left running on pi-server; the bridge verified live from
altai **on Tor Metrics**, not merely "the container is up"; then the pre-flight.
`BENCHMARKS.md` points at the gate too, since that is where someone starting a
benchmark run will be reading.

The reasoning is written down because it is not obvious from a task list: step 9
means kernel swaps, failed boots and possibly a reflash, and a bridge losing
identity keys or dropping off the network underneath that costs real users — plus
the accrued reputation a bridge loses when it vanishes and returns.

Both checks need the fingerprint, which is why they are done by hand and stay out
of the repo. The gate says to record only "verified, date". I scanned the tracked
tree for 40-hex fingerprints, IP literals and email addresses: the only matches
are git commit SHAs used as pins, the shellcheck tarball's SHA-256, and Debian
version numbers.
