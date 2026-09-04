<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# MolniyaOS (Molniya) — Study Guide

*A first-principles, line-by-line companion to the repo at `X:\MolniyaOS`. Read it with the code open. By the end you should be able to open any `.sh`, `.py`, or `.config` file here, point at a line, and know what it does and **why**.*

*(Self-contained: it re-teaches the Linux, the boot process, the radio, and the shell from scratch. This repo is almost all Bash — so unlike the others, the "language" you need is the operating system itself: kernels, partitions, boot firmware, systemd. All of it is built up below, assuming you know Python's basic style and nothing about systems administration.)*

---

## Part 0 — How to use this document

Built to print and study like an exam. Order:

1. **The one-sentence idea.**
2. **The analogy.**
3. **What the project is and why** — the SATCOM appliance vision.
4. **The concepts** — kernels and real-time; the Pi boot process; partitions and A/B updates; systemd; radio/SDR; the Bash idioms this repo leans on.
5. **The repo map.**
6. **Deep walkthroughs** — the kernel build, the A/B update machinery (the crown jewel), the health check, the signal-processing math, the TLE updater — file by file.
7. **Self-test.**

Jargon is **bolded and defined** on first use; glossary at the end.

> **Names.** The folder is `X:\MolniyaOS`; the project is **MolniyaOS**, sometimes just **Molniya**. It was earlier called **KosmOS**. *Molniya* (молния) is Russian for "lightning," and also the name of a family of Soviet/Russian satellites in famously elongated orbits — a fitting name for a satellite ground station.

---

## Part 1 — The one-sentence idea

> **MolniyaOS turns a Raspberry Pi 5 into a dedicated, reliable satellite-and-radio receiving station — by building a special real-time Linux kernel tuned so it never drops radio samples, wrapping it in an appliance-grade operating system that can update itself in the field and automatically roll back if an update breaks, and bundling the software toolchain for actually capturing and decoding signals from space.**

Two things are happening at once, and it helps to keep them separate:
1. **A real-time kernel + SDR toolchain** — the mature part. Documented in the README, lives in `kernel/` and `userspace/`.
2. **An appliance image with self-healing A/B updates** — the newer, ambitious part. Lives in `image/` and its `rauc/` subfolder. This is the "not a toolbox, an appliance" direction.

---

## Part 2 — The analogy (read this twice)

Think about the difference between **a laptop** and **the flight computer on a spacecraft.**

A laptop is a *toolbox.* It runs a general-purpose operating system that's pretty good at everything and perfect at nothing. If it stutters for a tenth of a second because it decided to check for updates, you don't even notice. If an update breaks it, you sit down, troubleshoot, maybe reinstall. There's a human right there.

A spacecraft flight computer is an *appliance.* It does one job, and it must do it *without stuttering* (a hiccup at the wrong moment loses irreplaceable data), and it must survive a bad update *with no human present* (there's nobody up there to reinstall it). So it's engineered for two properties a laptop doesn't bother with:
- **Determinism** — it responds within a guaranteed time, every time. No "usually fast."
- **Recoverability** — if a new version of its software fails, it *automatically* reverts to the last version that worked, on its own, without anyone touching it.

**MolniyaOS is trying to turn a $60 Raspberry Pi from the first thing into the second thing.**

- The **real-time kernel** buys *determinism*: a radio capture thread is guaranteed to get the CPU the instant it needs it, so samples streaming off the dongle at millions per second never pile up and overflow. (A stutter here = a torn satellite image.)
- The **A/B update system** buys *recoverability*: there are two complete copies of the OS on the SD card ("slot A" and "slot B"). An update installs into the *idle* copy, then the Pi *tries* to boot it. If the new copy proves itself healthy, it becomes permanent. If it doesn't — if it's broken, or even just hangs — **the Pi falls back to the old copy on the very next reboot, all by itself.** No human, no network, no reinstall.

The vocabulary:

| Analogy | MolniyaOS term | What it is |
|---|---|---|
| "Responds on time, every time" | **PREEMPT_RT / real-time kernel** | A kernel that can always interrupt itself for urgent work |
| The radio firehose | **SDR sample stream** | Millions of I/Q samples per second off the dongle |
| A torn image from a stutter | **sample drop / discontinuity** | Lost samples when the CPU was too busy |
| Two copies of the OS | **A/B slots** | Two full, independent system partitions |
| "Try the new one" | **tryboot** | Boot the idle slot once, provisionally |
| "Keep it, it's good" | **mark-good / commit** | Make the tried slot permanent |
| "It broke — go back" | **rollback** | Fall back to the committed slot automatically |
| The health exam before committing | **health check** | A script whose exit code decides commit-or-rollback |

---

## Part 3 — What the project is, and why (the appliance vision)

Two design choices from your own notes explain the whole shape of this repo:

- **"Appliance, not a toolbox."** The goal isn't "a Pi with radio software installed" — you can `apt install` that. The goal is a *sealed appliance* you could deploy somewhere remote, that keeps itself running and recovers from bad updates unattended.
- **A/B image updates over an apt repo.** For updates, MolniyaOS deliberately chose the *A/B whole-image* approach (two copies, atomic swap, automatic rollback) rather than a package repository (`apt upgrade`). Why? The priorities were: eliminate the risk of a half-finished update bricking the box, make rollback trivial, and — critically — **make rollback work with no internet**, in the field. A package manager can leave you half-upgraded and needs the network to fix itself; an A/B image swap is atomic and self-healing offline. That's the appliance mindset.

The **ROADMAP.md** (213 KB — the project's vision and phase plan; skim it, don't read it cover to cover) organizes the work into phases. The A/B machinery is "Phase 4d," and you'll see `4d` referenced in comments throughout `image/rauc/`. The README documents the *mature* kernel-overlay path (install a custom kernel alongside stock Pi OS); the `image/` tree is the *newer* full-appliance path. Both coexist in the repo.

A recurring theme you'll notice in every file, and it's worth naming up front because it's the repo's real personality: **the comments obsessively document failure modes that produce a wrong answer *silently*.** A download that "succeeds" but returns an error page. A config option that's misspelled so the merge tool ignores it entirely. A health check that passes because it was accidentally checking the wrong thing. A kernel that boots fine but quietly isn't real-time. Over and over, the code is built to catch the failure that *looks like success* — because on an unattended appliance, that's the failure that actually hurts. If you internalize one thing from this repo, make it that instinct.

---

## Part 4 — The concepts you need, from scratch

### 4.1 What a kernel is, and what "real-time" means

The **kernel** is the core of an operating system — the program that talks directly to the hardware and decides which of your programs gets to run on the CPU at any given moment. That decision is made by the **scheduler.**

A normal ("general-purpose") kernel optimizes for *throughput and fairness* — getting the most total work done, keeping everyone reasonably happy. What it does *not* guarantee is *when* any particular program runs. If your radio-capture program needs the CPU **right now** but the kernel is in the middle of some other work, your program **waits.** That waiting is called **scheduling latency.**

Here's why that's fatal for SDR (the README's own example): a radio dongle streams samples at, say, 2.4 million per second. If your capture thread is delayed by just **1 millisecond**, that's `2.4M × 0.001 = 2,400 samples` lost — a gap that shows up as tearing in a decoded satellite image or a corrupt frame.

**PREEMPT_RT** ("preempt real-time") is a set of kernel changes that make the kernel *fully preemptible* — meaning your urgent capture thread can **interrupt the kernel itself**, cutting in line ahead of almost any other kernel work, instead of waiting behind it. That's the "responds on time, every time" property. It trades a little raw throughput for a *guaranteed low worst-case latency.* (Good news the health check notes: PREEMPT_RT was merged into mainline Linux in version 6.12, so it's no longer an exotic out-of-tree patch.)

Two supporting knobs, both in the config:
- **1000 Hz timer tick** (`CONFIG_HZ_1000`) — the kernel "wakes up to make decisions" 1000 times a second instead of the default 250. Finer-grained timing = lower worst-case latency, and enough precision for **Doppler correction** (see §4.5).
- **Performance CPU governor** — the **governor** decides the CPU's clock speed. The default ("ondemand") ramps the clock *up* only when it sees load — but that ramp-up takes a moment, and during it a buffer can overflow. "Performance" pins the CPU at full clock always, so there's no ramp-up delay. (That's what `molniya-set-governor.sh` sets.)

### 4.2 The Raspberry Pi boot process (you need this for the A/B system)

When a Pi 5 powers on, before Linux exists, the Pi's **firmware** (baked into the board) runs and has to answer: *"which kernel do I load, from where?"* It answers by reading text files from the **first FAT partition** on the SD card (FAT = a simple, ancient filesystem the firmware can read without any OS). The key files:

- **`config.txt`** — firmware settings.
- **`cmdline.txt`** — the "kernel command line": options passed to the kernel as it starts, most importantly `root=` (which partition holds the actual operating system).
- **`autoboot.txt`** — the special file that enables **A/B slot selection** (below).

The Pi 5 firmware has a built-in feature called **`tryboot`**: you can tell it "on the next boot *only*, boot the alternate slot instead of the normal one, then go back." That one-shot, self-reverting behavior is the hardware foundation the whole A/B system is built on. Understand `tryboot` and you understand MolniyaOS's update magic: it's not a clever daemon, it's *the firmware's own one-shot flag* plus a script that decides whether to make the trial permanent.

### 4.3 Partitions, and the A/B layout

An SD card is divided into **partitions** — labeled regions, each holding a filesystem. MolniyaOS's layout (defined entirely in `image/layout.sh`) has **seven**:

- **p1** — a tiny FAT partition holding *only* `autoboot.txt`, the slot selector. It lives *outside* both slots on purpose — because the file that decides which slot boots must not live *inside* a slot that an update might overwrite. (Analogy: the referee can't be one of the players.)
- **p2 / p3** — the two boot partitions, "bootfs A" and "bootfs B" (kernel + firmware files for each slot).
- **p5 / p6** — the two root partitions, "root A" and "root B" (the actual operating systems).
- **p7** — a shared **data** partition, the *same* in both slots, so your captures and config survive an update or rollback.
- (p4 is an "extended container" — a technical necessity because MBR partition tables allow only four "primary" partitions and we need more; don't worry about it.)

So "slot A" = bootfs A (p2) + root A (p5); "slot B" = bootfs B (p3) + root B (p6). An update writes into the *idle* slot; the running slot is never touched. That's what makes it safe.

### 4.4 RAUC and systemd

**RAUC** ("Robust Auto-Update Controller") is an open-source framework for exactly this A/B update pattern. It knows how to install an update **bundle** into the idle slot, verify its cryptographic signature, and coordinate the slot swap. But RAUC needs to be told *how this specific board switches slots* — and there's no official Raspberry Pi backend yet (it's an open pull request, `rauc#1599`). So MolniyaOS provides its own small **custom backend** script (`molniya-boot-backend.sh`) that translates RAUC's requests into edits of `autoboot.txt`. (When the official backend lands, that script gets deleted and nothing else changes — a deliberately reversible bet.)

**systemd** is the standard Linux "init system" — the first thing Linux starts, which then starts and supervises everything else as **services** (`.service` files) and runs things on schedules (`.timer` files). MolniyaOS uses:
- a `.service` that runs the health-check-and-mark-good after boot,
- a `.service` + `.timer` pair that refreshes satellite orbital data twice a day,
- a `.service` that sets the performance governor at boot,
- and the systemd **watchdog** — a hardware safety net that reboots the Pi if the OS stops responding entirely (a *hang*, which A/B rollback alone can't catch).

### 4.5 The radio concepts (SDR, I/Q, TLE, Doppler)

- **SDR (Software-Defined Radio)** — instead of dedicated radio hardware for each signal type, a cheap **RTL-SDR** dongle digitizes a chunk of radio spectrum into raw numbers and hands them to software, which does the demodulation. MolniyaOS targets the "RTL-SDR Blog v4."
- **I/Q samples** — the dongle's output. Each sample is a pair of numbers (In-phase and Quadrature) that together capture a moment of the radio wave's amplitude and phase. Millions per second. In the code, these are `numpy.complex64` (a complex number: I is the real part, Q the imaginary).
- **TLE (Two-Line Element set)** — a compact, standardized text description of a satellite's orbit, published by CelesTrak. A ground station needs current TLEs to predict *when* a satellite will pass overhead and *where* to point. TLEs go **stale** — orbits decay — so they must be refreshed (that's `tle-updater.sh`). Each TLE line carries a **mod-10 checksum** you can verify.
- **Doppler shift** — because a satellite is moving fast relative to you, its transmitted frequency appears shifted (higher approaching, lower receding), just like a passing siren's pitch. Decoding requires continuously **correcting** for this, which needs precise timing — one reason for the 1000 Hz timer.
- **NOAA APT** — the "hello world" of the hobby: NOAA weather satellites transmit a simple analog image on 137 MHz that you can capture in a 10-minute pass. The README uses it as the first target.

### 4.6 The Bash idioms this repo leans on

Every script starts with:
```bash
set -euo pipefail
```
Memorize it: `-e` exit on any error, `-u` error on an unset variable, `-o pipefail` a pipeline fails if any stage fails. Turns silent Bash sloppiness into loud early failure.

Other patterns you'll see constantly, with their reasons (the repo documents them):
- **`local` variables** inside functions (scoped, like a normal function-local).
- **`"${VAR:-default}"`** — "use `$VAR`, or `default` if unset." Everywhere, for configurable-with-a-fallback.
- **Reading a file with a `while ... read` loop and `case`** instead of `source`-ing it — because `source` executes the file, and a corrupted config file must never become *executed code* on a root process at boot. This is a hard house rule here.
- **Heredocs** (`<<EOF ... EOF`) — to print a multi-line block (a generated config file).
- **"Helpers are subprocesses, not sourced libraries"** — a house rule so the shell linter (`shellcheck`) stays clean; scripts *repeat* a few lines rather than share a library. You'll see the same little function duplicated across files *on purpose*, with a comment saying so.
- **`n=$((n + 1))` instead of `((n++))`** — because under `set -e`, `((n++))` when `n` is 0 evaluates to a "false" status and *kills the script*. A genuinely nasty footgun, documented where it bites.

---

## Part 5 — The repo map

```
MolniyaOS/
├── README.md              the kernel-overlay path, fully documented; the entry point
├── ROADMAP.md             213 KB — the vision, phase plan, and rationale (skim, don't read whole)
├── LICENSE                GPL-3 for MolniyaOS's code; the kernel stays GPL-2 upstream
│
├── kernel/                          BUILD THE REAL-TIME KERNEL (runs on an ARM64 build host)
│   ├── 01-build-kernel.sh           clone Pi kernel, merge the RT/SDR config, verify, build, package
│   ├── sdr-rt.config                the config FRAGMENT: only what differs from the Pi default
│   ├── install-kernel.sh            (runs on the Pi) install alongside stock, edit only config.txt
│   └── package-kernel.sh            stage the built kernel + Pi-side scripts into a tarball
│
├── userspace/                       INSTALL THE SDR TOOLCHAIN (runs on the Pi)
│   ├── 02-post-install.sh           sequencer: verify kernel, then offer the installs
│   ├── 02a-verify-kernel.sh         read-only kernel verification (always exits 0 — a report)
│   ├── 02c-sdr-userspace.sh         build librtlsdr, rtl_433, dump1090, predict — pinned to commits
│   ├── 03a-gnuradio-stack.sh        GNU Radio + SoapySDR
│   └── ...                          (03b satdump, 03c sdr++, 02d Russian locale, etc.)
│
├── image/                           THE APPLIANCE IMAGE + A/B UPDATES (Phase 4d)
│   ├── layout.sh                    ★ THE SINGLE SOURCE OF TRUTH for the partition layout
│   ├── build-image.sh / build-rootfs.sh / assemble-image.sh / fetch-base.sh   the image builder
│   ├── verify-image.sh / verify-rauc.sh   check a built image before flashing
│   ├── build-bundle.sh              package an update as a signed RAUC bundle
│   ├── inject-keyring.sh            put the signing certificate into the image
│   └── rauc/                        THE A/B MACHINERY — the crown jewel
│       ├── molniya-boot-backend.sh  ★ translates RAUC's verbs into autoboot.txt edits (stateless)
│       ├── molniya-mark-good.sh     ★ run the health check; commit ONLY if it passes
│       ├── molniya-mark-good.service the systemd unit that runs it after boot
│       ├── make-keys.sh / provision-rauc.sh   signing keys + on-target RAUC setup
│       └── health-check/
│           ├── molniya-health-check.sh  ★ the exam whose EXIT CODE decides commit-or-rollback
│           └── slot-identity.sh         "which slot am I actually running?" (facts, no verdict)
│
├── automation/                      UNATTENDED OPERATION
│   ├── tle-updater.sh               ★ refresh orbital elements, with paranoid validation
│   ├── molniya-tle-update@.service/.timer   the twice-daily refresh (template unit, per-user)
│   ├── molniya-set-governor.sh + .service   pin the performance governor at boot
│   └── rtl-power-heatmap.py         plot an rtl_power spectrum sweep as a PNG
│
├── gr-molniya/                      CUSTOM GNU RADIO BLOCK
│   ├── python/molniya/gap_math.py           ★ the sample-loss measurement (stdlib only, tested)
│   ├── python/molniya/discontinuity_probe.py the GNU Radio block shell around it
│   └── python/molniya/test_gap_math.py      unit tests (run anywhere)
│
├── benchmarks/            prove the RT claim: cyclictest A/B/C, rtl_test sample-loss sweep
└── config/               frequencies.md + antennas.md — the operator cheatsheets
```

The two update mental models, side by side:

```
KERNEL-OVERLAY PATH (README, mature)          APPLIANCE A/B PATH (image/, newer)
─────────────────────────────────────        ──────────────────────────────────
build custom kernel on an ARM64 host    │     build a whole signed image
scp a tarball to the Pi                  │     two full copies on the card: slot A, slot B
install alongside stock Pi OS kernel     │     update installs into the IDLE slot
only config.txt is touched (reversible)  │     tryboot the new slot ONCE
boot it; verify by hand                  │     health check passes? → mark-good (permanent)
                                         │     health check fails / hang? → auto-rollback next boot
```

---

## Part 6 — Deep walkthrough: building the real-time kernel (`kernel/01-build-kernel.sh`)

This script runs on an ARM64 Linux build host and produces the kernel tarball. Read it as seven numbered steps (the script literally labels them `[1/7]`…`[7/7]`).

The header comments are unusually good teaching material — they explain *why the Pi kernel fork and not mainline* (the Pi Foundation's fork has drivers for Pi-specific hardware — the GPU, the RP1 I/O chip — that mainline lacks; "like how Cisco IOS is based on BSD but with Cisco drivers bolted on") and *why `bcm2712_defconfig`* (the Pi's known-good starting config for the Pi 5's chip — "a vendor's default switch template").

The three steps worth understanding deeply:

**Pinning the kernel (Step 2).** A **config fragment** and a pinned commit both serve *reproducibility*:
```bash
KERNEL_COMMIT="f5a99b95354d38db209003a7d00560e5091ba94a"
```
When a commit is pinned, the script does `git init` + `git fetch <that exact commit>` rather than `git clone <branch>` — because cloning a branch gets *today's tip*, "which is exactly what a pin exists to prevent." Two kernel builds weeks apart must be *the same kernel* if a benchmark is going to name one. The script then checks the checked-out SHA actually equals the pin and hard-fails if not.

**Merging the config fragment (Step 4).** `sdr-rt.config` isn't a full kernel config — it's a *fragment* listing only what MolniyaOS changes from the Pi default (PREEMPT_RT, 1000 Hz, the SDR drivers, the amateur-radio stack; and it *strips* things like Bluetooth and touchscreens to cut build time). `merge_config.sh` (a kernel tool) layers it over the default and resolves dependencies:
```bash
./scripts/kconfig/merge_config.sh -m .config "$FRAGMENT_PATH"
```

**The verification gate (`verify_critical_config`) — this is the star.** This function is a perfect example of the repo's personality. `merge_config.sh` has *two silent failure modes*:
1. It **drops options whose dependencies aren't met, silently** — so PREEMPT_RT could just... not be there, with only a warning you'd miss.
2. It **does nothing at all for a *misspelled* option** — a typo'd config symbol isn't an error, it's *nothing*, so a pin that "protects" something might be protecting nothing.

So after the merge, the script reads the resulting `.config` *back* and hard-fails if `CONFIG_PREEMPT_RT`, `CONFIG_HZ_1000`, `CONFIG_IKCONFIG_PROC`, `CONFIG_BCM_VCIO`, or `CONFIG_BCM2835_WDT` aren't literally present:
```bash
for opt in CONFIG_PREEMPT_RT=y CONFIG_HZ_1000=y ...; do
    if grep -qx -- "$opt" .config; then echo "$opt"; else echo "MISSING: $opt"; failed=1; fi
done
```
And it runs this check **twice** — once right after the merge (so a dependency problem is caught immediately) and once *after* `menuconfig` (the interactive review), so "the state actually compiled is the state verified." The comment spells out the stakes: without this gate, you'd spend 45–90 minutes building, install, reboot, and *only then* discover PREEMPT_RT never made it in — "at which point the entire point of the kernel is gone." That's the failure-that-looks-like-success instinct, applied to a kernel build.

The comment on the two Phase-4d symbols (`VCIO`, `WDT`) is the sharpest version of the lesson: a VCIO pin *had been misspelled since it was written*, and nothing noticed — because the Pi's default already enabled that symbol, so "a pin whose only evidence of working is that the default already agrees with it is not protecting anything." Reading the merged config back is the only check the merge itself cannot perform.

`install-kernel.sh` (on the Pi) is the reversibility story: it installs the whole MolniyaOS kernel into its *own* directory and adds one marked block to `config.txt` (`os_prefix=molniya/`) — the firmware's mechanism for loading a completely separate set of boot files. **`config.txt` is the only stock file touched, and it's written *last*, only after every other file is confirmed present** — so an interrupted install can never leave the Pi unbootable, and reverting is deleting one marked block.

---

## Part 7 — Deep walkthrough: the A/B update machinery (the crown jewel)

This is the most sophisticated part of the repo, and it's worth real time. Three scripts do the work: `layout.sh` (defines the geography), `molniya-boot-backend.sh` (executes slot switches), and `molniya-mark-good.sh` + `health-check/` (decide whether a switch sticks).

### 7.1 `image/layout.sh` — one fact, five consumers

The problem this file solves is stated in its header perfectly: the *same* partition layout has to be expressed in **five different languages that never see each other** — the partition table (`sfdisk`), the firmware slot selector (`autoboot.txt`, which refers to slots by *number*), RAUC's config (`system.conf`, by *device path*), each slot's `cmdline.txt` and `/etc/fstab`, and an on-target slot map. If *any two disagree*, you don't get a build error — you get "a box that flashes fine, boots fine, updates fine, and then reverts to the wrong slot or writes an update over its own data partition." A silent, catastrophic, data-eating bug.

So `layout.sh` states the layout **once** (the block of `readonly` constants at the top — partition sizes, numbers, labels) and *generates* all five consumers from it. It touches no disk; it only prints, and callers redirect the output. `./layout.sh sfdisk` prints the partition table; `./layout.sh autoboot A` prints an `autoboot.txt` with A as default; `./layout.sh rauc /dev/mmcblk0` prints RAUC's config; and so on.

Two comments in it are the whole A/B concept in miniature:

- On `SIZE_ROOT_MIB=6144`: the value is **measured, not guessed.** "4096 was a guess and it was wrong" — the first full SATCOM build produced a 5054 MiB rootfs, which would overrun a 4 GiB slot. 6144 is chosen as "the LARGEST value that still fits a nominal 16 GB card" with two copies — "not a round number chosen for comfort — it is the last one before a whole class of card stops working." That's engineering, shown.
- On `emit_autoboot`: `tryboot_a_b=1` is "the load-bearing line," and the `[tryboot]` section names the *other* slot. **"That is the entire A/B mechanism: a normal boot takes `boot_partition`, a `reboot "0 tryboot"` takes the `[tryboot]` one exactly once, and if nothing marks the boot good the next boot falls back to `boot_partition` on its own. No counter, no daemon."** Read that twice — it's the key to everything.

The `emit_cmdline`/`emit_fstab` comments hammer the danger: point slot B's `cmdline.txt` or `fstab` at slot A's root and "the box boots a kernel from B onto a filesystem from A, which mostly works, which is worse than failing." *Mostly works* is the enemy.

### 7.2 `molniya-boot-backend.sh` — RAUC's hands, and it's stateless

RAUC calls this script with one of five **verbs** — `get-primary`, `set-primary`, `get-state`, `set-state`, `get-current` — and the script answers by reading/writing `autoboot.txt`. The design decision that makes it trustworthy is in the header:

> **THERE IS NO STORED STATE.** All three answers are derived from three facts: `autoboot.txt`'s committed slot, the firmware-published *running* slot, and whether this boot is a `tryboot`.

Statelessness matters because *stored* state can get out of sync with reality; *derived* state can't. The script reads the committed slot from `autoboot.txt` (a file on p1) and gets the running-slot facts from `slot-identity.sh` (which reads what the firmware published into the device tree). "Helper returns data, caller judges" — the same split the health check uses.

The load-bearing function is `commit_swap`, and it's a masterclass in "don't brick the card":
- It swaps the two `boot_partition` values in `autoboot.txt`, but **validates both against the slot map first** — "a corrupt selector must not be able to talk us into writing a partition number that is not one of the two boot slots."
- It rewrites the file **line by line** (via `swap_stream`) rather than regenerating from a template, so anything else in the file survives untouched.
- It writes to a **temp file, reads it back to verify the swap actually happened, and only then `mv`s it into place** — because "a torn `autoboot.txt` is a card that does not boot, and FAT gives us no journal, so the check is not optional and neither is the `sync`."
- The selector partition is normally mounted **read-only**; the script remounts it read-write for *only the instant it writes*, then back to read-only — minimizing the window in which a power cut could corrupt "the single most load-bearing file on the card."

There's even a comment about an assertion that was *removed* because a **mutation test** proved no input could tell its presence from its absence — "an assertion nothing can falsify is the kind that goes on agreeing with itself after the code around it changes." That's a level of rigor most production code never reaches.

### 7.3 `molniya-mark-good.sh` + the health check — the decision

Here's the heart of self-healing, and the header states the stakes bluntly:

> **THE ENTIRE MECHANISM DEPENDS ON THIS SCRIPT NOT BEING A FORMALITY.** `ExecStart=/usr/bin/rauc status mark-good` is what the obvious implementation looks like — and it marks *every* boot good, including the boot where nothing works. **An A/B system whose mark-good is unconditional has the storage cost of rollback and none of the protection.**

So `molniya-mark-good.sh` runs the health check and calls `rauc status mark-good` **only on exit 0.** And *not* marking good *is* the rollback — because the firmware already cleared the tryboot flag before Linux even started, so doing nothing means the next boot returns to the old slot automatically. The rollback is the *default*; committing is the thing you have to earn.

The **split of labor** is deliberate: the health check *renders a verdict and takes no action* (so it can be run by hand, by anyone, anytime, safely); the mark-good wrapper *takes the action and renders no verdict.* "Neither half can be tested by exercising the other."

**`molniya-health-check.sh`** is where the appliance decides if it's healthy, and its single most important design idea is the **CRITICAL vs ADVISORY** split:

- **CRITICAL** failures set the exit code (→ rollback). These are things *the image broke* and *reverting can fix*: wrong kernel version, PREEMPT_RT not actually active, watchdog not armed, GNU Radio won't import, SATCOM binaries missing, slot identity inconsistent.
- **ADVISORY** warnings are printed and *deliberately ignored*. These are things *the operator* controls, that *reverting cannot fix*: no SDR dongle plugged in, stale orbital elements, no network.

The reasoning (header) is the whole philosophy of unattended recovery: "Erring toward CRITICAL builds a box that reverts every update because a dongle is unplugged, then reverts again: a rollback trigger firing on facts the rollback cannot change is worse than none, because it spends the only recovery mechanism the design has." The rollback is a *finite, precious* resource; spend it only on faults it can actually cure.

Every individual check is a "failure that looks like success" caught in the wild — read these, they're a security-mindset seminar:
- `check_rt_preempt`: **do not** rely on `/sys/kernel/realtime` alone — that file came from the *old* out-of-tree patchset and *doesn't exist* since RT was merged into mainline 6.12, so the naive check would report "NOT REAL-TIME" on *exactly the kernel this project builds*. It checks three sources, best evidence first. And there's a beautiful sub-comment about why it uses process substitution `<(zcat ...)` and *not* `zcat | grep -q`: under `pipefail`, `grep -q` exits on first match, `zcat` is still writing, gets `SIGPIPE`, and the *whole pipeline reports failure even though the match succeeded* — a silent bug that would make the check "permanently run on its weaker fallback while claiming to consult the authoritative source."
- `check_gr_molniya`: imports a *submodule* (`from molniya import gap_math`) with `python3 -P`, never the bare package — because `import molniya` alone *passes on a box with no gr-molniya installed* (Python invents a namespace package from any `molniya/` directory on the path, including the current directory). Caught doing exactly that on `pi-server`.
- `check_watchdog`: the watchdog is CRITICAL because A/B rollback covers "booted but broken" — it *cannot* cover a *hang* (a slot that boots and then freezes). The watchdog is the only thing that catches that, so an unarmed one is a genuinely broken image "even though nothing else on the box would misbehave."

The verdict is the exit code: `0` healthy (mark good), `1` unhealthy (roll back), `2` couldn't decide (also don't mark good — "a box that cannot ask the question does not get marked good either... it costs a rollback to a slot that worked, where the other direction commits a slot nobody vouched for").

---

## Part 8 — Deep walkthrough: the signal-processing math (`gr-molniya/`)

This is the one place the repo does real DSP (digital signal processing), and the split between `gap_math.py` and `discontinuity_probe.py` teaches a genuinely important idea about numerical precision.

### 8.1 What the block is *for*

`discontinuity_probe` is a **"gauge in the pipe"** — a GNU Radio block you insert into a signal-processing chain that watches the sample stream go by and **logs every gap** (every time the radio dropped samples), passing the samples through unchanged. The point (from its README): the standard RT benchmarks measure the *capture path under synthetic load* or *judge a decoded image by eye* — neither measures *loss during a real capture.* Inline, this block "turns every pass into a benchmark run," which has no published equivalent.

### 8.2 The non-obvious part (worth internalizing)

You cannot detect a dropped sample by *looking at the samples.* The comment nails it: a GNU Radio block's input buffer is *always contiguous* — it hands you N samples that sit next to each other in memory, *whether or not the radio dropped a million samples just before them.* Comparing adjacent samples finds *signal features*, not *dropouts.*

The gap is only visible in the **stream tags** — metadata the hardware source attaches. Specifically, an `rx_time` tag is emitted whenever the stream is *not continuous* with what came before (at start, and after every overflow), carrying the hardware timestamp of the sample it's attached to. So the measurement is **a comparison of two clocks**: the tag's *asserted* time vs. the time you'd *predict* from the previous tag plus the number of samples consumed since. If those disagree, the difference *is* the gap.

### 8.3 Why the math is a separate, stdlib-only file — and the precision trap

`gap_math.py` imports *nothing* outside Python's standard library and is unit-tested by `test_gap_math.py` on any machine — because "this project treats 'written but never run' as a liability," and the GNU Radio block shell *can't* run without GNU Radio installed. So the *measurement* lives in a testable file, and the *glue* (tag unpacking, log writing) stays thin.

But the split is also **load-bearing for correctness**, and here's the beautiful part. An `rx_time` timestamp is a **pair**: `(whole_seconds, fractional_seconds)` — *not* one number. Why does that matter? Because these are epoch-scale times (~1.7 billion seconds), and a 64-bit float (a `double`) only has so many significant digits. At that magnitude, the smallest difference a double can represent (its **ulp**, "unit in the last place") is about `2.384e-7` seconds. Measured against a sample period at 2.4 MS/s, that's `0.57` of a sample — *comparable to the one-sample gaps the probe exists to catch.* So if you naively *collapsed* the pair into one float, you'd throw away exactly the precision you need.

`pair_delta` does the subtraction **component-wise** and never collapses:
```python
def pair_delta(t0, t1):
    return float(t1[0] - t0[0]) + (float(t1[1]) - float(t0[1]))
```
The whole-seconds subtract as *exact integers*; the fractions subtract as two *small* floats. The result — a delta of a few seconds — is a small number carried at full precision. That's the entire reason the file exists as its own thing, and `test_gap_math.py::test_one_sample_gap_at_epoch_scale_with_zero_tolerance` proves the pair arithmetic keeps the sample a collapsed float would lose. (There's even an honest note correcting an *earlier* version of the comment that got the ulp figure wrong — the code documents its own mistakes.)

The `GapTracker` class is a **pure state machine** — no clock reads, no file writes, no GNU Radio — so it's fully testable. It takes each tag, compares against the last, and returns a record dict *only* for a real gap (anything within `tolerance_samples` is treated as timestamp quantization, not loss). A *negative* gap (time ran backward — a retune or source restart) is recorded *with its sign* as an anomaly, but not counted as a dropout. And "every tag resets the baseline whether or not it revealed a gap" — because "the hardware has asserted 'this sample is at this time,' and that assertion is better than anything extrapolated across it."

The block shell `discontinuity_probe.py` is the thin glue: `work()` copies input to output unchanged, pulls the `rx_time` tags in the window, unpacks each (handling *both* the tuple and pair encodings different hardware sources use — "a probe that crashes on the very tag it exists to read has broken a capture to report on a capture"), feeds them to the tracker, and writes any returned record as one JSON line. Even the log file is opened *lazily* on first record, and an open failure downgrades to "count but don't log" rather than crashing the capture.

---

## Part 9 — Deep walkthrough: `automation/tle-updater.sh` (paranoid data fetching)

This refreshes the satellite orbital elements, and it's the repo's clearest lesson in *not trusting a download.* The core problem (header): **CelesTrak returns HTTP 200 (success) with an error message in the body** for a bad query. So `wget` reports success and writes 61 bytes of prose into your `.tle` file, and *nothing downstream notices* — until an antenna points at empty sky.

So the script validates **three** things, in layers:
1. `validate_tle` checks every element line's **mod-10 checksum** (the `awk` `csum` function: digits add their value, minus signs add 1, mod 10, compare to column 69). A truncated transfer, a mangled line, or CelesTrak's error prose *all fail the checksum.* It also rejects an *odd* number of data lines (a TLE is two lines per satellite; an odd count means truncation).
2. `validate_catnr` confirms the returned elements actually carry the **catalogue number that was asked for** — because "a typo in `PREDICT_SATS` fetches a real, checksum-clean TLE for the *wrong* satellite," which `validate_tle` can't catch because "there is nothing wrong with it." Tracking the wrong satellite is "a failure mode with no symptom."
3. Only validated data is installed; a failed source leaves the previous good elements *untouched* ("stale elements beat no elements"), and the script exits non-zero so a timer *reports* the failure.

The two-destination design (a small curated set for `predict`, which reads exactly one file and tracks at most 24 satellites; whole groups for the tools that can hold more) and the `PREDICT_MAX_SATS` guard (predict "quietly ignores the excess" over 24 — another silent failure) round it out. And the comment on why the array *isn't* named `GROUPS`: **Bash defines `GROUPS` itself** as the user's group IDs, so `TLE_GROUPS` avoids silently iterating over a numeric GID. Every one of these is a real bug someone hit.

The systemd timer (`molniya-tle-update@.timer`, installed by `install-tle-timer.sh`) fires twice daily, **spread by up to 15 minutes** so every MolniyaOS box in the world doesn't hammer CelesTrak on the same minute, and **persistent** so a box that was off through both windows updates when it returns. It's a **template unit keyed on the username** (the `@` in the name) because the elements land under a specific user's `$HOME`, and "a root-owned copy in `/root` is one `predict` will never open" — enabling it for the wrong account would "run, succeed, and maintain elements nobody reads."

`molniya-set-governor.sh` (§4.1) shows the same read-back discipline: it writes "performance" to every core, then *reads cpu0 back* and fails if it doesn't stick — "a governor can be accepted by sysfs and then overridden by a driver or a thermal policy, and a unit that reports success in that case is worse than one that reports nothing."

---

## Part 10 — The config docs and benchmarks, briefly

- **`config/frequencies.md`** — a working cheatsheet of what to receive (NOAA APT at 137 MHz as the first target; Iridium/Inmarsat as the "career-relevant SATCOM" band; ADS-B at 1090 MHz as the best sanity check) with a clear **receive-only, legal** framing and even a wavelength-math table for cutting antenna elements. Note the ⚠️ marks on rows most likely to have moved — the doc knows it's a snapshot, not an authority.
- **`benchmarks/`** — the scripts that *prove* the RT claim rather than assert it: `cyclictest` (measures worst-case scheduling latency) run A/B/C across kernel/governor configurations, and an `rtl_test` sample-loss sweep across sample rates (1.024 → 3.2 MS/s — 3.2 included "precisely because it is where the kernels should diverge most," which ties directly back to the precision discussion in `gap_math.py`).

---

## Part 11 — Self-test (cover the answers)

1. **Why does a general-purpose kernel drop SDR samples, and how does PREEMPT_RT fix it?** — It doesn't guarantee *when* a thread runs; a scheduling delay of 1 ms at 2.4 MS/s loses 2,400 samples. PREEMPT_RT makes the kernel fully preemptible so the capture thread can interrupt kernel work instead of waiting behind it.
2. **What is the entire A/B mechanism, in one sentence?** — A normal boot takes `boot_partition`; a `tryboot` reboot takes the other slot *once*; if nothing marks the boot good, the next boot falls back on its own — no counter, no daemon.
3. **Why must `autoboot.txt` live on its own partition (p1), outside both slots?** — The file that decides which slot boots must not live inside a slot an update might overwrite. The referee can't be a player.
4. **Why is "not marking good" the rollback, rather than an active revert?** — The firmware already cleared the one-shot tryboot flag before Linux started, so doing nothing means the next boot returns to the committed slot automatically. Committing is the thing you must earn.
5. **What is the CRITICAL-vs-ADVISORY distinction, and what decides which tier a check lands in?** — CRITICAL affects the exit code (→ rollback); ADVISORY is printed and ignored. The line is *who broke it and can reverting fix it*: the image (revertible) is CRITICAL; the operator/hardware/network (not revertible) is ADVISORY. A rollback firing on a fault it can't cure spends the only recovery mechanism for nothing.
6. **Why does the kernel build read `.config` back after merging, instead of trusting `merge_config.sh`?** — The merge tool silently drops options with unmet dependencies *and* silently ignores misspelled options. Reading the config back is the only check the merge itself cannot perform.
7. **Why is the sample-loss measurement split into `gap_math.py`, and why is that split about correctness, not just testability?** — It's stdlib-only so it can be unit-tested without GNU Radio. And an `rx_time` timestamp is a `(whole, fractional)` pair; collapsing it into one double loses ~0.57 of a sample of precision at epoch scale — comparable to the gaps being measured — so the pair must be subtracted component-wise.
8. **Why can't you detect a dropped sample by comparing adjacent samples?** — The input buffer is always contiguous regardless of what the radio dropped before it. The gap is only visible in the `rx_time` stream tags, as a disagreement between the tag's asserted time and the time predicted from the previous tag.
9. **What silent failure does `tle-updater.sh`'s checksum-and-catalogue validation catch that an HTTP status check misses?** — CelesTrak returns HTTP 200 with error prose in the body for a bad query, and a catalogue typo fetches a valid TLE for the *wrong* satellite. The checksum catches the first; the catalogue-number check catches the second. Both are failures with no downstream symptom.
10. **Why is `molniya-boot-backend.sh` stateless, and why does `commit_swap` write to a temp file and read it back?** — Derived state can't drift out of sync with reality the way stored state can. And a torn `autoboot.txt` on a journal-less FAT partition is an unbootable card, so the swap is verified before it's installed and `sync`ed.
11. **Why does `layout.sh` generate five files from one block of constants?** — The same layout must be stated in five languages that never see each other; any two disagreeing produces a box that boots and updates fine and then reverts to the wrong slot or overwrites its own data — a silent, data-eating bug.
12. **What's the difference between the README's kernel-overlay path and the `image/` appliance path?** — The overlay installs a custom kernel alongside stock Pi OS (reversible, touches only `config.txt`); the appliance path builds a whole signed image with two full A/B slots and unattended self-healing rollback.

---

## Glossary

- **A/B slots** — two complete, independent copies of the OS (partitions); updates install into the idle one.
- **autoboot.txt** — the Pi firmware file that selects which slot boots; the heart of A/B on the Pi.
- **CPU governor** — the policy setting the CPU clock speed; "performance" pins it at maximum.
- **cyclictest** — a tool that measures worst-case scheduling latency, used to prove the RT claim.
- **Doppler shift** — the apparent frequency change from a moving satellite; must be corrected to decode.
- **Health check** — the script whose exit code decides whether an A/B update is committed or rolled back.
- **I/Q samples** — the paired (in-phase, quadrature) numbers an SDR produces; complex numbers.
- **Kernel** — the OS core that talks to hardware and schedules programs onto the CPU.
- **mark-good / commit** — making a tried slot permanent (only if the health check passes).
- **PREEMPT_RT** — the real-time patchset making the kernel fully preemptible for guaranteed low latency.
- **RAUC** — the A/B update framework; needs a board-specific backend to switch slots.
- **rollback** — automatic return to the committed slot when an update isn't marked good.
- **SDR (RTL-SDR)** — software-defined radio; a cheap dongle that digitizes spectrum for software to decode.
- **Scheduling latency** — the delay between when a thread is ready to run and when it actually runs.
- **Stream tag (rx_time)** — GNU Radio metadata marking a discontinuity; the only way to see a dropped sample.
- **systemd (.service/.timer)** — Linux's init system and scheduler; runs services and timed jobs.
- **TLE (Two-Line Element set)** — a satellite's orbit description; goes stale; carries a checksum.
- **tryboot** — the Pi firmware's one-shot "boot the other slot once, then revert" flag.
- **ulp (unit in the last place)** — the smallest gap a float can represent at a given magnitude; the precision limit that forces pair arithmetic in `gap_math.py`.
- **Watchdog** — hardware that reboots the Pi if the OS hangs; catches the failure A/B rollback can't.

---

*End of MolniyaOS study guide. Companion docs: `README.md` (the kernel-overlay path in full) and `ROADMAP.md` (the appliance vision and the Phase 4d rationale the `image/rauc/` comments refer to). The `config/` cheatsheets (`frequencies.md`, `antennas.md`) are the operator's field references once the box is built.*
