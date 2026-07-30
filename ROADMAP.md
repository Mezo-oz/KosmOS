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

- **altai — the permanent production host.** Runs the Amnezia work and the
  `tor-services` Docker stack (an obfs4 bridge + snowflake proxy + watchtower),
  migrated here 2026-07-29. Stable, always-on, not to be disrupted for KosmOS.
  **The production bridge does not return to pi-server** — this is settled, not
  provisional.

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
   opaque golden-image ISO. ⚠️ *This is currently a commitment, not a fact:
   02-post-install.sh clones four projects at unpinned upstream HEAD, so two
   builds a month apart won't match. Pinning is pulled forward from Phase 4a —
   it's load-bearing for this positioning. Every new build script (starting
   with 03-satcom-stack.sh) pins from line one; retrofit pins into
   02-post-install.sh.*

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
   warnings on, all warnings fixed"); CI-gate this in Phase 4.
   **Verified at zero 2026-07-29** (shellcheck 0.9.0 on Linux and 0.11.0
   locally, both agreeing on the same 11 findings before the fix; zero after,
   including at `-S style`)
6. **Smallest scope** — `local` inside functions, globals only when
   deliberate and named LIKE_THIS (rule 6)
7. **Pin every version, checksum every download** — Pillar 3's mechanics

**Custom GNU Radio blocks — the rule.** Write a custom block only when (a) the
catalog has no part — a protocol or format no existing block handles — or
(b) we need a *gauge in the pipe* — instrumentation measuring the stream
itself. Never rewrite existing demodulators as features (fine as private
learning exercises), and never write a Doppler block — gr-satellites already
provides Doppler correction. Prototype blocks in Python; port to C++ only if
they can't keep up at full sample rate. Planned blocks live under `gr-kosmos/`
except where noted (see Phase 2c for the independence rule on IceSickle).

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
- [ ] **Rebuild with `CONFIG_LOCALVERSION="-kosmos"`** — config is set (`281cf0d`)
  but **the rebuild has not happened**, so the installed kernel still reports
  plain `6.12.79-v8-16k+`. Until then the version check in 02-post-install.sh
  reports FAIL on the running kernel; that is expected, not a regression.
  Rebuild + reinstall happens at step 9, and also separates the module
  directories.
- [x] **Install the tooling** — *done, `43d8368`.* `rt-tests` and `stress-ng`
  added behind their own prompt in 02-post-install.sh, deliberately separate
  from the SDR userspace install so Test 1 can run without building a toolchain
  it does not need.

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
C measures config B and the isolation delta reads as zero. Use either:

```bash
taskset -c 1-3 cyclictest -l1000000 -m -S -p90 -i200 -h400 -q
# or cyclictest's own affinity flag:
cyclictest -a 1-3 -l1000000 -m -S -p90 -i200 -h400 -q
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
- [ ] **`gr-kosmos` sample-discontinuity probe** — an inline block that watches
  the sample stream for discontinuities and logs a timestamped record of every
  gap (the "gauge in the pipe")
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
✅ Full dynticks (`CONFIG_NO_HZ_FULL`) — **activated** `43d8368`: `nohz_full` and
   `rcu_nocbs` now on the KosmOS command line (CPUs 1-3 by default). Was
   compiled but inert before that.
⏳ Kernel version string — `CONFIG_LOCALVERSION="-kosmos"` is set in the fragment
   but **the installed kernel predates it**, so `uname -r` still reports plain
   `6.12.79-v8-16k+`. Takes effect on the step-9 rebuild.
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
   (⚠️ TLEs currently land in a directory predict never reads — updater must
   target `~/.predict/predict.tle`)
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
- [ ] **SatDump** — The all-in-one satellite processor
  - Decodes NOAA APT/HRPT, GOES HRIT/EMWIN, Meteor-M LRPT, MetOp, FengYun
  - Handles capture → demodulation → decoding → image generation in one pipeline
  - This is the centerpiece tool for the SATCOM focus
  - Build from source for ARM64 with GUI and CLI modes — **pinned commit**
- [ ] **GNU Radio + gr-osmosdr** — The DSP framework
  - For building custom signal processing flowgraphs
  - Required for advanced demodulation (Iridium, custom protocols)
  - Heavy dependency chain — plan for a dedicated build step, **pinned**
- [ ] **SoapySDR** — Hardware abstraction layer
  - Lets all SDR tools talk to any SDR hardware through one API
  - Critical for HackRF support when you upgrade from RTL-SDR
  - Think of it as a HAL (Hardware Abstraction Layer) — same concept
    as how your kernel talks to different NICs through a common interface

#### 1b. Orbit Prediction & Tracking
- [ ] **TLE auto-updater** — Cron job or systemd timer to refresh orbital elements
  - TLEs go stale within days (orbits decay)
  - Pull from CelesTrak for NOAA, GOES, amateur, weather sats
  - Like an OSPF neighbor table that needs periodic refresh
  - **Must also fix the predict path bug**: write to `~/.predict/predict.tle`
    (the current TLE directory is never read by predict)
- [ ] **Rotator control support** (hamlib / rotctld)
  - For automated antenna pointing during passes
  - Uses serial/USB to talk to antenna rotator hardware
  - Not needed for omnidirectional antennas, but essential for
    directional (dish/yagi) tracking of specific satellites

#### 1c. Spectrum Analysis & Visualization
- [ ] **SDR++** — Modern GUI SDR receiver
  - Waterfall display, multi-VFO, plugin architecture
  - Build from source for ARM64 with RTL-SDR and HackRF support
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
- [x] **Version pinning** — *pulled forward; see Pillar 3. Applies from
  03-satcom-stack.sh onward, plus retrofit of 02-post-install.sh*
- [ ] **Checksum verification** — SHA256 for all downloads

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
- [ ] **Frequency reference guide** — built-in cheatsheet of common
  SATCOM, weather sat, ADS-B, amateur, ISM band frequencies
- [ ] **Antenna guide** — which antenna for which mission
  - Dipole (VHF/UHF general), V-dipole (NOAA APT), QFH (weather sats),
    dish (GOES, Inmarsat), Yagi (directional tracking)

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
v0.25  ......    RT kernel benchmark published (proof of claim — BEFORE the
                 SATCOM stack; Test 1 needs no dongle, runnable this week)
v0.3   ......    SatDump + GNU Radio + SDR++ (first satellite decode, pinned)
                 + gr-kosmos discontinuity probe (first custom block)
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

## Repository Structure (Target)

```
KosmOS/
├── README.md                    # Project overview and quick start
├── ROADMAP.md                   # This document (must be tracked in the repo)
├── .gitattributes               # Keep — prevents CRLF breaking shebangs
├── kernel/
│   ├── 01-build-kernel.sh       # Kernel build script
│   ├── sdr-rt.config            # Kernel config fragment
│   └── install-kernel.sh        # Pi kernel installer
├── benchmarks/
│   ├── BENCHMARKS.md            # RT vs stock kernel results (proof of claim)
│   ├── run-latency-bench.sh     # cyclictest suite (idle / CPU load / IO load)
│   └── run-sdr-bench.sh         # rtl_test dropped-sample sweep
├── gr-kosmos/                   # Custom GNU Radio blocks (OOT module)
│   └── (discontinuity probe; future blocks per the custom-block rule)
├── userspace/
│   ├── 02-post-install.sh       # SDR tools + locale setup
│   ├── 03-satcom-stack.sh       # SatDump, GNU Radio, SDR++ (Phase 1)
│   └── 04-protocol-decoders.sh  # Iridium, AIS, direwolf (Phase 2)
├── automation/
│   ├── sat-pass-scheduler.sh    # Automated satellite capture
│   ├── rtl433-service.conf      # systemd unit for always-on RF monitoring
│   ├── tle-updater.sh           # Cron script for TLE refresh
│   └── adsb-feeder.sh           # dump1090 → FlightAware feed
├── field/
│   ├── wifi-ap-setup.sh         # hostapd + dnsmasq config
│   ├── wireguard-setup.sh       # VPN for remote access
│   ├── tor-bridge-setup.sh      # Optional Tor bridge module (off by default)
│   └── web-dashboard/           # Browser-based status panel
├── config/
│   ├── frequencies.md           # SATCOM frequency reference
│   ├── antennas.md              # Antenna selection guide
│   └── profiles/                # Pre-built SDR++ / SatDump configs
├── image/
│   └── build-image.sh           # Automated .img.gz builder
└── .gitignore

(NOT in this repo: gr-icesickle — lives with the IceSickle project; runs ON
KosmOS, doesn't ship IN it.)
```

**Migration note:** the reorganization splits install-kernel.sh (→ kernel/) and
02-post-install.sh (→ userspace/) — the packaging step copies both from
$REPO_DIR and will break silently if paths aren't updated in the SAME commit
as the `git mv`.

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
9. **v0.25: rebuild, reinstall, run the benchmark.** The rebuild is required
   first: it is what makes `CONFIG_LOCALVERSION` take effect and what puts the
   `os_prefix` layout on the boot partition. Then the three-config matrix above
   (Test 1 needs no dongle; Test 2 the day the RTL-SDR v4 arrives).

   **Bench box = pi-server** (see Hardware Topology). No reboot-window constraint:
   swaps, crashes and reflashes are expected there.

   **Pre-flight on pi-server before rebuilding (run once the bridge is verified on
   altai):**
   - **Check `/boot/firmware/config.txt` for a stale custom-kernel block.** An
     RF-Linux-era block (`# RF-Linux custom kernel` / `kernel=kernel-rflinux.img`)
     was found on **altai** during the earlier investigation; whether pi-server has
     one is **unverified** — check it directly in the pre-flight. If present, the
     new installer greps for `^os_prefix=kosmos/`, will not see the old-named block,
     and would append a second one, leaving two conflicting `kernel=` directives;
     the revert one-liner will not match the old name either. Remove any such block
     by hand first and delete the orphaned image.
   - **Config-A baseline is already right: stock `6.12.62+rpt-rpi-2712`.** Boot
     that for config A, not a newer stock kernel, so the RT patch is the only
     difference — no pinning needed, it is installed.
   - **Set the governor to performance on both kernels** before any run, or record
     that the figures include ondemand ramp latency. Ship this as the
     performance-governor systemd unit (part of the pre-flight).
10. Order the RTL-SDR Blog v4 + dipole antenna kit (if not already)
11. Build `03-satcom-stack.sh` — pinned from line one
12. First NOAA APT capture using SatDump

**Carried forward from the audit, not yet scheduled:**
- ~~shellcheck has never been run~~ ✅ **verified at zero.** 11 findings fixed:
  `$(nproc)` quoted (SC2046 ×3), `read -r` everywhere (SC2162 ×4), `ls` replaced
  with `find` (SC2012 ×3), and the unused `OUTPUT_DIR` deleted rather than wired
  up (SC2034) — it was dead, and adding an `output/` directory would have changed
  the artifact path the README documents. Still needs a CI gate in Phase 4 so it
  stays at zero.
- ~~**File-size headroom is thin.**~~ ✅ **`02-post-install.sh` is split.** It did
  four jobs (verify, benchmark tooling, SDR userspace, locale) in 399 lines, one
  under the cap. Now a 96-line sequencer over `02a-verify-kernel.sh` (187),
  `02b-bench-tools.sh` (47), `02c-sdr-userspace.sh` (148) and
  `02d-locale-ru.sh` (63), each runnable standalone. Behaviour through the
  sequencer is unchanged, including the inherited quirk that declining the SDR
  install also skips the locale step — 02c signals that with exit code 3.
  `install-kernel.sh` (366) and `01-build-kernel.sh` (371) are still the two
  files near the cap; neither does more than one job, so neither is a natural
  split yet.
- **Retrofit version pins into `02-post-install.sh`** — four projects still
  clone unpinned upstream `HEAD`, which is what keeps Pillar 3 a commitment
  rather than a fact.

---

*KosmOS v0.2 — Built from bare metal, aimed at the stars*
*Target: Raspberry Pi 5 (BCM2712, ARM64)*
