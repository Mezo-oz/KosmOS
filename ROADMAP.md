# KosmOs — Project Roadmap & Vision

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
| **RT kernel** | No (stock Ubuntu kernel) | Yes (PREEMPT_RT, 1000Hz, tickless) |
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
   opaque golden-image ISO. "Here's exactly how every byte got here" is a trust
   feature DragonOS structurally can't retrofit, and one that matters to
   security-conscious SATCOM/defense-adjacent users.
   > **Not yet true.** `02-post-install.sh` clones four projects at unpinned
   > upstream `HEAD`, so two builds a month apart will not match. Version
   > pinning is filed under Phase 4a but is load-bearing for a claim being made
   > now — pull it forward, and build `03-satcom-stack.sh` pinned from line one
   > rather than inheriting the unpinned pattern.

---

## Proof of Claim: RT Kernel Benchmark (Near-Term Priority)

**The question:** does PREEMPT_RT measurably reduce scheduling latency and dropped
SDR samples versus the stock Pi kernel on identical hardware?

The dual-boot setup (stock kernel preserved as fallback) makes this a clean A/B
test: same Pi 5, same SD card, same dongle — only the kernel changes between boots.

> **Precondition:** that sentence is only true once step 5 of Immediate Next Steps
> is done. The original installer copied its DTBs and overlays *over* the stock
> ones in the shared boot directory, so the stock kernel booted against the custom
> kernel's device trees. Probably harmless within one kernel series, but this is the
> project's headline published result and "only the kernel changed" has to be
> literally true. `os_prefix` fixes it by giving each kernel its own directory.

### Methodology

**Test 1 — Scheduling latency (no SDR hardware needed, can run today):**
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

**Deliverable:** `benchmarks/BENCHMARKS.md` — methodology, raw numbers, tables,
and a plain-language conclusion. Publishable either way: a confirmed win is the
project's headline claim; a null result gets documented honestly and the
positioning leans harder on pillars 2 and 3.

---

## What Exists Today (v0.2)

✅ Custom kernel with `PREEMPT_RT`
  - The installed build reports `6.12.79-v8-16k+` — a string indistinguishable
    from a stock 6.12 kernel, because `CONFIG_LOCALVERSION` was never set.
    Now set to `-kosmos`, so the *next* build is identifiable by `uname -r`.
    Until that rebuild, the version check in `02-post-install.sh` will report
    FAIL on the currently installed kernel. That is expected, not a regression.
✅ Real-time scheduling — 1000 Hz tick, high-resolution timers
  - `CONFIG_NO_HZ_FULL=y` is set but **inert**: full dynticks does nothing
    without `nohz_full=` on the kernel command line. Step 6 addresses this.
    Until then, "tickless" should not appear in published claims.
✅ Performance CPU governor (always max clock)
✅ AX.25 / amateur radio / packet radio stack compiled as modules
  - Compiled, but not yet *confirmed* loading: the post-install check ran
    `modprobe` without `sudo` and reported a false negative. Fixed in step 3.
✅ RTL-SDR driver stack (RTL2832 SDR + R820T tuner)
✅ USB subsystem optimized for SDR hardware
✅ Stripped unnecessary subsystems (GPU drivers, NFC, BT, ISDN, etc.)
✅ librtlsdr (RTL-SDR Blog fork, v4 compatible)
✅ rtl_433 (multi-protocol RF decoder)
✅ dump1090 (ADS-B aircraft tracking)
✅ predict (satellite pass prediction)
  - Note: the TLE downloader writes to `~/.config/satellite-tle/`, which
    `predict` does not read — it uses `~/.predict/predict.tle`. The Phase 1b
    TLE auto-updater has to fix the path, not just add a timer.
◻ Russian locale (ru_RU.UTF-8) — **optional, not a project feature.**
  Author preference; documented in the README as skippable.
✅ Non-destructive dual-boot (stock kernel preserved as fallback)
  - The kernel *image* is preserved. DTBs and overlays were being overwritten
    (overlays without backup), so rollback was not fully clean. Step 5 fixes this.
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
  - Build from source for ARM64 with GUI and CLI modes
- [ ] **GNU Radio + gr-osmosdr** — The DSP framework
  - For building custom signal processing flowgraphs
  - Required for advanced demodulation (Iridium, custom protocols)
  - Heavy dependency chain — plan for a dedicated build step
- [ ] **SoapySDR** — Hardware abstraction layer
  - Lets all SDR tools talk to any SDR hardware through one API
  - Critical for HackRF support when you upgrade from RTL-SDR
  - Think of it as a HAL (Hardware Abstraction Layer) — same concept
    as how your kernel talks to different NICs through a common interface

#### 1b. Orbit Prediction & Tracking
- [ ] **TLE auto-updater** — Cron job or systemd timer to refresh orbital elements
  - TLEs go stale within days (orbits decay)
  - Pull from CelesTrak for NOAA, GOES, amateur, weather sats
  - **Must also correct the download path** to `~/.predict/predict.tle`
- [ ] **Rotator control support** (hamlib / rotctld)
  - For automated antenna pointing during passes
  - Uses serial/USB to talk to antenna rotator hardware
  - Not needed for omnidirectional antennas, but essential for
    directional (dish/yagi) tracking of specific satellites

#### 1c. Spectrum Analysis & Visualization
- [ ] **SDR++** — Modern GUI SDR receiver
  - Waterfall display, multi-VFO, plugin architecture
  - Build from source for ARM64 with RTL-SDR and HackRF support
- [ ] **inspectrum** — Lightweight spectrogram viewer for recorded files
  - Post-capture analysis of I/Q recordings
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
- [ ] **direwolf** — Software TNC for AX.25 / APRS
  - Decodes and generates packet radio
  - Integrates with the kernel AX.25 stack already compiled
  - Creates a real network interface — `ax0` appears in `ip a`
- [ ] **gr-ais** — Automatic Identification System decoder
  - Ship tracking (162 MHz) — the maritime version of ADS-B
  - Career-relevant: maritime domain awareness

#### 2c. RF Reverse Engineering
- [ ] **Universal Radio Hacker (URH)** — Signal reverse engineering
  - Visual protocol analysis for unknown RF signals
- [ ] **gr-lora** — LoRa demodulator for GNU Radio
  - Ties into the IceSickle ESP32-S3 project
  - Monitor LoRa transmissions from the Linux side
  - Verify what the embedded device actually transmits

### Phase 3: "Operations Center" — Automation & Integration
*Goal: Continuous monitoring, logging, and remote access*

*This phase is the soul of the project — it's what turns a box of tools into an
appliance. Phases 1–2 build the parts; Phase 3 makes them run themselves.*

#### 3a. Automated Capture Pipeline
- [ ] **Systemd service for rtl_433** — Always-on RF monitoring
  - JSON output → log file and/or database
- [ ] **Automated satellite pass capture**
  - Script: check TLEs → calculate next pass → start recording at AOS
    (Acquisition of Signal) → stop at LOS (Loss of Signal) → decode
  - Cron-triggered or systemd timer
  - This is the "set it and forget it" pipeline
- [ ] **ADS-B feed to FlightAware/FlightRadar24**
  - Run dump1090 as a service, feed data to tracking networks
  - Note: the FlightAware fork has no built-in HTTP server — the web UI
    needs a separate web server, unlike the original dump1090

#### 3b. Data Logging & Visualization
- [ ] **InfluxDB + Grafana** (lightweight, or SQLite + custom dashboard)
  - Store decoded RF data (weather sensor readings, aircraft positions)
  - Visualize trends, signal strength over time, RF environment mapping
- [ ] **RF environment baseline script**
  - Periodic rtl_power scans to map the local spectrum
  - Detect new emitters, track interference sources

#### 3c. Remote Access & Field Operations
- [ ] **WireGuard VPN** — Encrypted remote access
  - Already compiled as kernel module
  - Configure for remote Pi access over cellular/WiFi
- [ ] **WiFi AP mode** — Pi broadcasts its own network
  - hostapd + dnsmasq configuration
  - Connect from a laptop in the field without existing infrastructure
- [ ] **Web dashboard** — Browser-based control panel
  - Status page showing: kernel info, SDR device status, active captures,
    next satellite passes, system health
  - Accessible from any device on the local network

### Phase 4: "Hardened Platform" — Reliability & Distribution
*Goal: Make KosmOs reproducible and distributable*

#### 4a. Image Building
- [ ] **Automated image builder script**
  - Takes a fresh Pi OS Lite image → applies kernel → installs all tools
  - Produces a flashable `.img.gz` file
- [ ] **Version pinning** — Lock tool versions for reproducibility
  - Record exact git commits for every source-built tool
  - **Pull this forward** — pillar 3 already claims it (see note above)
- [ ] **Checksum verification** — SHA256 for all downloads

#### 4b. Configuration Management
- [ ] **First-boot setup wizard** (CLI-based)
  - Set hostname, callsign, location (lat/lon for satellite predictions)
  - Configure WiFi, set locale
  - Generate SSH keys
- [ ] **Dotfiles / config templates**
  - Pre-configured `.gnuradio/`, SatDump profiles, SDR++ configs
  - Tuned for common SATCOM frequencies and satellite protocols

#### 4c. Documentation
- [ ] **Man pages or built-in help** for KosmOs-specific scripts
- [ ] **Frequency reference guide** — built-in cheatsheet of common
  SATCOM, weather sat, ADS-B, amateur, ISM band frequencies
- [ ] **Antenna guide** — which antenna for which mission
  - Dipole (VHF/UHF general), V-dipole (NOAA APT), QFH (weather sats),
    dish (GOES, Inmarsat), Yagi (directional tracking)
- [ ] **License** — none is declared, so the code is currently not reusable

---

## Career Alignment: SATCOM Job Skills Map

Based on actual SATCOM job postings, here's how KosmOs maps to career skills.
CCNA is explicitly listed as valued in SATCOM roles — a networking background
is a direct asset.

| Job Requirement | Where You Learn It in KosmOs |
|----------------|------------------------------|
| RF engineering / spectrum analysis | SDR++, rtl_power, GNU Radio flowgraphs |
| Signal processing & modulation | GNU Radio DSP blocks, SatDump demod chains |
| Satellite systems & orbital mechanics | predict, TLE management, pass scheduling |
| Network protocols | AX.25 stack, IP-over-radio, CCNA knowledge |
| Troubleshooting signal issues | Spectrum analysis, SNR measurement, Doppler correction |
| Linux/VM environments | Building the entire OS from kernel up |
| Satellite modems & link budgets | GNU Radio modem implementations, GOES/Inmarsat reception |
| Spectrum analyzers | rtl_power, SDR++ waterfall, inspectrum |
| Equipment configuration | Kernel config, SDR gain/frequency tuning, antenna selection |
| Security protocols | WireGuard VPN, encrypted remote sessions |
| Monitoring & logging | Grafana dashboards, automated capture pipelines |
| TDMA/FDMA concepts | Iridium (TDMA) and Inmarsat (FDMA) decoding |
| Documentation | This entire project is self-documenting |
| Performance engineering & benchmarking | RT kernel A/B benchmark (cyclictest, dropped-sample analysis) |

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
v0.25  ......    RT kernel benchmark published (proof of claim — latency now, SDR tests when dongle arrives)
v0.3   ......    SatDump + GNU Radio + SDR++ (first satellite decode)
v0.4   ......    Automated capture pipeline (scheduled sat passes)
v0.5   ......    Protocol decoders (Iridium, AIS, APRS/direwolf)
v0.6   ......    Field deployment kit (WiFi AP, WireGuard, web dashboard)
v0.7   ......    Monitoring stack (logging, Grafana, RF baseline)
v0.8   ......    Image builder (reproducible, distributable .img.gz)
v1.0   ......    Full release — documented, tested, flashable image
```

---

## Repository Structure (Target)

```
KosmOs/
├── README.md                    # Project overview and quick start
├── ROADMAP.md                   # This document
├── .gitignore
├── .gitattributes               # Forces LF — a CRLF here breaks shebangs
├── kernel/
│   ├── 01-build-kernel.sh       # Kernel build script
│   ├── sdr-rt.config            # Kernel config fragment
│   └── install-kernel.sh        # Pi kernel installer
├── benchmarks/
│   ├── BENCHMARKS.md            # RT vs stock kernel results (proof of claim)
│   ├── run-latency-bench.sh     # cyclictest suite (idle / CPU load / IO load)
│   └── run-sdr-bench.sh         # rtl_test dropped-sample sweep
├── userspace/
│   ├── 02-post-install.sh       # SDR tools + optional locale setup
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
│   └── web-dashboard/           # Browser-based status panel
├── config/
│   ├── frequencies.md           # SATCOM frequency reference
│   ├── antennas.md              # Antenna selection guide
│   └── profiles/                # Pre-built SDR++ / SatDump configs
└── image/
    └── build-image.sh           # Automated .img.gz builder
```

**Migration note:** `01-build-kernel.sh` resolves its siblings via `$REPO_DIR` to
package `sdr-rt.config`, `install-kernel.sh` and `02-post-install.sh`. The target
layout splits those across `kernel/` and `userspace/`, so the packaging paths must
be updated *in the same commit* as the move, or the tarball silently loses its
installer again.

---

## Immediate Next Steps

Dependency-ordered. Derived from the 2026-07-29 repo audit; supersedes the earlier
unordered list.

**Do first — cheap, and everything downstream depends on them**

1. ✅ Settle the name: **KosmOs** (K), matching the repo and remote. Applied.
2. Commit this ROADMAP.md into the repo.
3. Fix the verification layer so it can actually verify:
   - add `CONFIG_IKCONFIG` + `CONFIG_IKCONFIG_PROC` (nothing can read
     `/proc/config.gz` today, so the HZ check always reports unknown)
   - `sudo modprobe ax25` (currently a false negative)
   - hard-fail the build if `CONFIG_PREEMPT_RT` did not survive `merge_config.sh`
4. Fix the two aborts on a fresh Pi: `depmod unknown` leaving a half-install, and
   the transitional `libncurses5-dev` dependency.

**Do before generating any benchmark numbers**

5. `os_prefix` so the custom kernel, DTBs, overlays and cmdline live in their own
   directory. Makes rollback truly non-destructive and the A/B honest.
6. `nohz_full=` on the kernel command line, or drop "tickless" from the claims.
7. Add `rt-tests` and `stress-ng` — Test 1's tooling is installed by nothing today.

**Then**

8. Reorganize into the target structure above (single commit; see migration note).
9. **v0.25 — RT benchmark Test 1.** cyclictest on both kernels. Needs no dongle,
   so it is runnable now, and it is the one result nobody else has published.
10. `03-satcom-stack.sh` — SatDump, GNU Radio, SDR++, **pinned from line one.**
11. Order the RTL-SDR Blog v4 + dipole antenna kit.
12. Test 2 dropped-sample sweep, same day the dongle arrives.
13. First NOAA APT capture via SatDump.

Rationale for holding `03-satcom-stack.sh` until after the benchmark: it adds three
more source builds (GNU Radio's dependency chain especially) on top of a kernel
whose central claim is still unverified. Verify the foundation, then build on it.

---

*KosmOs v0.2 — Built from bare metal, aimed at the stars*
*Target: Raspberry Pi 5 (BCM2712, ARM64)*
