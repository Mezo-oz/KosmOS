# KosmOs — Project Roadmap & Vision

*Naming settled 2026-07-29: it's **KosmOs** with a K — matches the existing repo
(Mezo-oz/KosmOs), the committed artifacts (kernel-kosmos.img, `-kosmos`
localversion), and the Cyrillic-flavoured "Kosmos" fits the SATCOM angle.*

## Identity: What KosmOs Is (and Isn't)

**KosmOs is a ground-up, SATCOM-focused Linux distribution built for the Raspberry Pi 5.**

The existing player in this space is DragonOS — a Lubuntu-based distro that ships as
a pre-built ISO with every SDR tool imaginable pre-installed. DragonOS is the "Kali
Linux of SDR": boot it up, everything works, you don't know how any of it was built.

KosmOs takes the opposite philosophy:

| | DragonOS | KosmOs |
|---|---------|--------|
| **Base** | Lubuntu (stock kernel) | Custom RT kernel built from source |
| **Architecture** | x86_64 primary, Pi secondary | ARM64/Pi 5 native, built for the edge |
| **Scope** | Kitchen sink (200+ tools) | SATCOM/space focused (curated toolkit) |
| **Philosophy** | "Everything pre-installed" | "Built from ground up, understand every layer" |
| **Target user** | Hobbyist who wants to scan now | Builder who wants to understand *and* do |
| **RT kernel** | No (stock Ubuntu kernel) | Yes (PREEMPT_RT, 1000Hz) |
| **Field deployment** | Desktop/laptop focused | Pi 5 portable kit with battery + WiFi AP |

**The pitch:** KosmOs is what you'd build if you were setting up a SATCOM ground
station from bare metal — custom kernel tuned for real-time RF processing, a curated
toolkit focused on satellite communications, and a deployment model designed for
portable field work on ARM64 hardware.

### Positioning: Appliance, Not Toolbox

KosmOs is **not** "DragonOS minus tools" — that would be a learning project, not a
product. KosmOs is an **autonomous SATCOM ground station appliance for ARM64**.
DragonOS hands you a workshop; KosmOs hands you a working instrument: flash the
image, give it your coordinates, and it starts producing satellite imagery and
decoded data on its own.

Three pillars separate this from a toy:

1. **Measured RT performance** — the custom kernel is a *claim* until it's
   benchmarked against the stock kernel on identical hardware. See "Proof of
   Claim" below. If the numbers hold, KosmOs has an engineering result nobody
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
KosmOs configures, patches, and compiles, not writes. KosmOs's own code is
orchestration: **bash** for build/install/automation scripts, **Python** where
a pipeline needs real data handling (rtl_power heatmaps, pass-scheduling
logic, dashboard backend), and **C/C++ only if/when** we write custom GNU
Radio blocks, SatDump plugins, or kernel patches. Distro-building is general
contracting, not brick manufacturing.

**Adapted NASA/JPL discipline.** The famous NASA rules are JPL's "Power of
Ten" for safety-critical flight C — the actual size rule there is *functions
≤ ~60 lines (one printed page)*. A 400-line-per-file cap is not NASA's rule,
but we adopt it as house convention anyway. KosmOs rules, adapted for
shell/Python:

1. **≤400 lines per file** — a script that outgrows this gets split
2. **Functions ≤60 lines**, one job each (the real Power-of-Ten rule 4)
3. **Check every return value** — `set -euo pipefail` in every script;
   explicit handling wherever a failure is expected (rule 7)
4. **No unbounded loops** — every retry/wait loop has a timeout or max
   iteration count (rule 2)
5. **shellcheck clean at zero warnings** — the analog of rule 10 ("all
   warnings on, all warnings fixed"); CI-gate this in Phase 4
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

- [ ] **Isolate the kernels with `os_prefix=`** — install-kernel.sh currently
  overwrites the shared DTBs/overlays in the boot partition, so the "stock"
  kernel boots against KosmOs device trees. That contaminates the A/B and
  weakens the rollback story. Fix before numbers, not after.
- [ ] **Settle the tickless claim** — `CONFIG_NO_HZ_FULL=y` is compiled but inert
  without `nohz_full=<cpulist>` in cmdline.txt. Either enable it (and dedicate
  isolated CPUs for the SDR process) or drop "tickless" from the claims table.
  No overclaims in a published benchmark.
- [ ] **Make verification possible** — add `CONFIG_IKCONFIG` +
  `CONFIG_IKCONFIG_PROC` so `/proc/config.gz` exists and the two kernels'
  configs can be *proven* to differ in exactly the claimed ways.
- [ ] **Rebuild with `CONFIG_LOCALVERSION="-kosmos"`** — current installed kernel
  reports plain `6.12.79-v8-16k+`, indistinguishable from stock by `uname -r`.
  Rebuild also separates the module directories.
- [ ] **Install the tooling** — `rt-tests` (cyclictest) and `stress-ng` are
  installed by no script yet; add to a deps step.

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

✅ Custom kernel `6.12.79-v8-16k+` with `PREEMPT_RT`
✅ Real-time scheduling (1000Hz tick, high-res timers)
⚠️ Tickless idle (`CONFIG_NO_HZ_FULL`) — compiled but **inert**: needs
   `nohz_full=` in cmdline.txt (see benchmark prerequisites)
⚠️ Kernel version string carries no project marker — `CONFIG_LOCALVERSION`
   wasn't set on the installed build; fixed going forward (`-kosmos`), needs
   a rebuild to take effect
✅ Performance CPU governor (always max clock)
✅ AX.25 / amateur radio / packet radio stack compiled as modules
   (⚠️ verify check needs `sudo modprobe` — currently a false negative)
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
⚠️ Dual-boot (stock kernel preserved) — but installer overwrites shared
   DTBs/overlays, so isolation isn't complete until `os_prefix=` lands
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
  - **Independence rule (2026-07-29):** KosmOs stays independent. This
    decoder is an out-of-tree GNU Radio module (`gr-icesickle`) that *runs
    on* KosmOs but doesn't ship *in* it — it likely lives in the IceSickle
    repo. KosmOs is the platform; IceSickle support is an app. The distro
    never depends on it, references it at most as a "built on KosmOs"
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

### Phase 4: "Hardened Platform" — Reliability & Distribution
*Goal: Make KosmOs reproducible and distributable*

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
- [ ] **Man pages or built-in help** for KosmOs-specific scripts
- [ ] **Frequency reference guide** — built-in cheatsheet of common
  SATCOM, weather sat, ADS-B, amateur, ISM band frequencies
- [ ] **Antenna guide** — which antenna for which mission
  - Dipole (VHF/UHF general), V-dipole (NOAA APT), QFH (weather sats),
    dish (GOES, Inmarsat), Yagi (directional tracking)

---

## Career Alignment: SATCOM Job Skills Map

Based on actual SATCOM job postings, here's how KosmOs maps to career skills.
CCNA is explicitly listed as valued in SATCOM roles — your networking background
is a direct asset.

| Job Requirement | Where You Learn It in KosmOs |
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

### Certifications That Stack Well with KosmOs Experience

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
KosmOs/
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
KosmOs, doesn't ship IN it.)
```

**Migration note:** the reorganization splits install-kernel.sh (→ kernel/) and
02-post-install.sh (→ userspace/) — the packaging step copies both from
$REPO_DIR and will break silently if paths aren't updated in the SAME commit
as the `git mv`.

---

## Immediate Next Steps (ordering per 2026-07-29 audit)

**Do first — cheap, everything downstream depends on them:**
1. ~~Settle C vs K~~ ✅ **K** — KosmOs
2. Commit this ROADMAP.md into the repo (it's referenced by the target
   structure but isn't tracked)
3. Fix the verification layer: `CONFIG_IKCONFIG` + `IKCONFIG_PROC`,
   `sudo modprobe ax25`, post-merge `grep -q '^CONFIG_PREEMPT_RT=y'` gate
4. Fix `depmod unknown`, drop `libncurses5-dev` (both abort a fresh run)

**Before generating any benchmark numbers:**
5. `os_prefix=` for genuinely isolated kernel+DTB sets (protects the A/B,
   makes rollback true)
6. Add `nohz_full=` to cmdline.txt, or drop "tickless" from claims
7. Add `rt-tests` + `stress-ng` to a deps step

**Then:**
8. Reorganize repo into target structure — single commit, `git mv`, update
   $REPO_DIR paths in the packaging step in the same commit
9. **v0.25: run the benchmark** (Test 1 this week — no dongle needed;
   Test 2 the day the RTL-SDR v4 arrives)
10. Order the RTL-SDR Blog v4 + dipole antenna kit (if not already)
11. Build `03-satcom-stack.sh` — pinned from line one
12. First NOAA APT capture using SatDump

---

*KosmOs v0.2 — Built from bare metal, aimed at the stars*
*Target: Raspberry Pi 5 (BCM2712, ARM64)*
