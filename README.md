# RF-Linux: Custom SDR/SATCOM Distribution for Raspberry Pi 5

## Table of Contents

1. [What You're Building & Why](#1-what-youre-building--why)
2. [The RF ↔ Networking Mental Model](#2-the-rf--networking-mental-model)
3. [Files In This Kit](#3-files-in-this-kit)
4. [Build Workflow Overview](#4-build-workflow-overview)
5. [Phase 1: Building the Kernel (In Your VM)](#5-phase-1-building-the-kernel-in-your-vm)
6. [Kernel Config Deep Dive](#6-kernel-config-deep-dive)
7. [Phase 2: Transfer & Install (On the Pi)](#7-phase-2-transfer--install-on-the-pi)
8. [Phase 3: Post-Install Verification & Userspace](#8-phase-3-post-install-verification--userspace)
9. [Russian Language / Locale Configuration](#9-russian-language--locale-configuration)
10. [SDR Userspace Toolkit Reference](#10-sdr-userspace-toolkit-reference)
11. [First Project: NOAA APT Satellite Image](#11-first-project-noaa-apt-satellite-image)
12. [Stretch Goals: ADS-B, Iridium, LoRa](#12-stretch-goals-ads-b-iridium-lora)
13. [Portable Field Deployment](#13-portable-field-deployment)
14. [Rollback & Recovery](#14-rollback--recovery)
15. [Learning Resources](#15-learning-resources)

---

## 1. What You're Building & Why

Think of this like building a custom race car. A stock Raspberry Pi OS install is a
minivan — it does everything, but nothing fast. You're stripping it to a tube-frame
chassis (minimal kernel), bolting on a race-tuned engine (real-time scheduling), and
only installing the instruments you need (SDR userspace tools). The result is a system
where every CPU cycle is available for processing radio signals instead of running
desktop widgets.

**Target hardware:** Raspberry Pi 5 (BCM2712, Cortex-A76 quad-core)
**SDR hardware:** RTL-SDR v4 now, HackRF One later
**Build host:** Debian ARM64 VM in UTM on M1 MacBook Air

Since both your VM and the Pi 5 are ARM64, this is a **native compilation** — no
cross-compiler needed. The binary you build in the VM runs directly on the Pi.
Same instruction set, zero translation. It's like compiling code on one identical
switch and copying the image to another of the same model.

### Why Not Just Use Stock Raspberry Pi OS?

Stock Pi OS ships with a general-purpose kernel: ~3000+ modules compiled,
a non-RT scheduler, and the CPU frequency governor set to power-saving mode. For
SDR work, this means:

- **Missed samples:** Without real-time scheduling, the kernel can delay your SDR
  processing thread by milliseconds. At 2.4 million samples/second, a 1ms delay
  loses 2,400 samples — a gap in your satellite image.
- **Wasted memory:** Thousands of loaded modules consume RAM that could buffer
  SDR samples.
- **Missing subsystems:** The amateur radio / AX.25 stack isn't compiled in stock
  Pi kernels. You need it for packet radio.

---

## 2. The RF ↔ Networking Mental Model

Your CCNA studies gave you the OSI model. RF has an almost identical stack:

```
NETWORKING                          RF / SDR
─────────────────────────────────────────────────────
Layer 7  Application    HTTP        Decoded data (weather image, ADS-B position)
Layer 6  Presentation   TLS/JSON    Encoding (APT line format, Mode S)
Layer 5  Session        TCP session Pass / orbit tracking window
Layer 4  Transport      TCP/UDP     Protocol framing (AX.25, HDLC)
Layer 3  Network        IP          Frequency allocation / channelization
Layer 2  Data Link      Ethernet    Modulation (AM, FM, PSK, FSK)
Layer 1  Physical       Cable/PHY   Electromagnetic wave → antenna → ADC samples
```

An RTL-SDR is a **network tap for RF** — it captures raw Layer 1 samples the same
way tcpdump captures raw Ethernet frames. GNU Radio is your Wireshark: it dissects
raw samples up through the layers. rtl_433 is a protocol-specific decoder (like an
HTTP parser that only understands weather station packets).

This analogy holds throughout the entire project. When you see a new SDR concept,
ask "what's the networking equivalent?" and it usually maps cleanly.

---

## 3. Files In This Kit

| File | Run where | Purpose |
|------|-----------|---------|
| `README.md` | — | This document (the complete reference) |
| `01-build-kernel.sh` | Debian ARM64 VM | Clones Pi kernel, merges SDR config, builds, packages |
| `sdr-rt.config` | (used by build script) | Kernel config fragment with SDR/RT customizations |
| `install-kernel.sh` | Raspberry Pi 5 | Installs custom kernel alongside stock kernel |
| `02-post-install.sh` | Raspberry Pi 5 | Verifies kernel, installs SDR tools + Russian locale |

---

## 4. Build Workflow Overview

```
┌─────────────────────────┐        SCP tarball        ┌────────────────────────┐
│   Debian ARM64 VM       │ ────────────────────────→  │    Raspberry Pi 5      │
│   (UTM on M1 Mac)       │  kernel + modules +       │                        │
│                         │  device tree blobs         │                        │
│  1. ./01-build-kernel.sh│                           │  3. install-kernel.sh  │
│  2. review menuconfig   │                           │  4. sudo reboot        │
│     → save → build      │                           │  5. ./02-post-install  │
└─────────────────────────┘                           └────────────────────────┘
```

This is the same pattern as your IceSickle ESP32 workflow: compile on a dev machine,
transfer the binary to the target, flash, verify. Just at OS-kernel scale instead
of firmware scale.

---

## 5. Phase 1: Building the Kernel (In Your VM)

### Prerequisites

Your Debian ARM64 VM needs at least 4GB RAM and 40GB disk. The build uses ~2GB
of disk for artifacts and peaks at ~1.5GB RAM per compile job.

### Running the Build

```bash
# Make the build script executable
chmod +x 01-build-kernel.sh

# Run it — fully automated except for the menuconfig review step
./01-build-kernel.sh
```

### What the Build Script Does (Step by Step)

**Step 1 — Install dependencies:** The compiler toolchain, header libraries, and
utilities the kernel build system needs. Same idea as installing a cross-compiler
toolchain for your ESP32.

**Step 2 — Clone the Pi kernel fork:** We use `github.com/raspberrypi/linux`
(the Pi Foundation's fork), not mainline kernel.org. The Pi fork includes patches
for the BCM2712 SoC, the RP1 I/O chip, and the VideoCore GPU — hardware that
mainline hasn't fully upstreamed yet. It's like how Cisco IOS is based on BSD but
with vendor-specific drivers on top. You *can* run mainline, but half your hardware
won't have drivers.

We clone branch `rpi-6.12.y` — the latest long-term stable branch. The `--depth 1`
flag does a shallow clone (latest commit only, no history), saving ~3GB of download.
Like doing a partial database sync instead of full replication.

**Step 3 — Load bcm2712_defconfig:** The Pi Foundation's blessed default config for
the Pi 5. Sets ~4000 kernel options to known-good values for your hardware. Starting
here instead of a blank config means everything the Pi needs is already enabled.

**Step 4 — Merge our SDR config fragment:** The `sdr-rt.config` file contains ONLY
the options we're changing. The kernel's `merge_config.sh` script overlays our
changes onto the base config and automatically resolves dependency chains. For
example, enabling AX25 pulls in HAMRADIO because AX25 depends on it. Think of it
like a YAML override file — base config has everything, fragment says "change these
specific knobs."

**Step 5 — menuconfig review:** The interactive menu opens with our changes already
applied. Key sections to verify:

- `General setup → Preemption Model` → should say "Fully Preemptible (RT)"
- `Networking → Amateur Radio → AX.25` → should be `<M>`
- `Device Drivers → Multimedia → RTL2832 SDR` → should be `<M>`
- **Search shortcut:** Hit `/` and type any CONFIG name to find it instantly

**Step 6 — Build:** Compiles three things:

- **Image** — The kernel binary itself (~30MB). What the Pi bootloader loads
  into RAM and jumps to.
- **modules** — Loadable `.ko` files. Plugins the kernel loads on demand with
  `modprobe`. Hundreds of files.
- **dtbs** — Device Tree Blobs. Hardware description files that tell the kernel
  "here's what hardware exists on this board and where it's mapped in memory."
  Without the matching DTB, the kernel boots but can't find USB controllers,
  GPIO pins, or the GPU. Think of DTBs as an **ARP table for hardware** — they
  map logical names to physical addresses.

Build time: ~45-90 minutes on a 4-core VM. If you get OOM kills, edit the script
and set `JOBS=2` instead of `$(nproc)`.

**Step 7 — Package:** Collects everything into a tarball ready to SCP.

---

## 6. Kernel Config Deep Dive

The `sdr-rt.config` fragment contains every customization with inline comments.
Here are the most important sections with first-principles reasoning.

### Real-Time Preemption (The Most Important Change)

```
CONFIG_PREEMPT_RT=y
```

Normal Linux scheduling is **cooperative at the kernel level.** If the kernel is
executing a system call (flushing a disk buffer, processing a network packet) and
your SDR delivers samples, those samples wait until the kernel finishes. This is
"store-and-forward" switching — receive the entire frame before forwarding.

Real-time preemption makes the kernel **fully preemptible.** Your SDR processing
thread interrupts *any* kernel operation mid-execution if it has higher priority.
This is "cut-through" switching — urgent traffic goes through immediately.

Without RT: 2.4M samples/sec, 1ms kernel delay = 2,400 lost samples = gap in your
satellite image. Same problem as dropped packets in a VoIP call causing audio glitches.
With RT: guaranteed microsecond-level response, like QoS guarantees for voice traffic.

### Timer Configuration

```
CONFIG_HZ_1000=y       # Kernel tick rate: 1000/sec (1ms granularity)
CONFIG_NO_HZ_FULL=y    # Tickless mode when only one task runs
CONFIG_HIGH_RES_TIMERS=y  # Nanosecond-precision timers
```

**HZ_1000:** The kernel's metronome ticks 1000x/second (every 1ms). Default is 250 Hz
(4ms). At 250 Hz, minimum scheduling delay = 4ms = 9,600 missed samples. At 1000 Hz,
worst case = 2,400. Combined with RT preemption, actual latency → microseconds.

**NO_HZ_FULL:** When only one task is running (your SDR thread), the kernel stops
generating timer interrupts entirely. Zero overhead. Like disabling keepalive probes
on a known-good connection — why interrupt data flow to ask "still there?"

**HIGH_RES_TIMERS:** Nanosecond precision instead of millisecond. Needed for Doppler
correction and burst synchronization in SDR.

### CPU Performance Governor

```
CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y
```

Forces Pi 5's Cortex-A76 to always run at max clock (2.4 GHz). Default "ondemand"
lounges at 1.5 GHz and ramps up on load — but the ramp takes milliseconds, during
which your SDR buffer overflows. Like QoS with a slow policer: by the time traffic
is classified as priority, you've dropped the first burst.

**Tradeoff:** More power and heat. Fine on a desk. For battery field work, swap to
"ondemand" and accept occasional drops.

### USB Subsystem

```
CONFIG_USB=y            # Built-in (=y), not module (=m)
CONFIG_USB_XHCI_HCD=y  # USB 3.0
CONFIG_USB_EHCI_HCD=y  # USB 2.0
```

Built-in because USB must work before any modules load from the filesystem. If USB
were a module, you'd have a chicken-and-egg problem on USB-boot systems. The Pi 5
has the RP1 chip (USB 2.0) and a PCIe xHCI controller (USB 3.0). We need both.

### SDR Hardware Drivers

```
CONFIG_DVB_RTL2832_SDR=m    # RTL-SDR raw I/Q mode
CONFIG_DVB_USB_RTL28XXU=m   # DVB-T mode (compiled but blacklisted)
CONFIG_MEDIA_TUNER_R820T=m  # Frequency tuner chip
```

**The driver stack** (bottom to top, like a protocol stack):

```
Physical chip:   RTL2832U (USB interface + analog-to-digital converter)
       ↓
Tuner chip:      R820T2 (frequency selection — like tuning a radio dial)
       ↓
Kernel driver:   dvb_usb_rtl28xxu → presents device to kernel
       ↓
SDR driver:      rtl2832_sdr → enables raw I/Q sample mode
       ↓
Userspace:       librtlsdr talks to /dev/swradio0
```

**Why =m:** SDR dongle is plugged in after boot. Module loads only when hardware
is present. Same as "start service on-demand" vs "start at boot" in systemd.

**Why compile DVB-T but blacklist it:** The kernel auto-claims RTL2832 as a TV tuner.
DVB-T mode only gives decoded TV packets at specific frequencies. Raw I/Q mode gives
the actual electromagnetic waveform as numbers — every sample across your entire
tuning range. Difference between parsed HTTP responses vs raw Ethernet frames. We
compile for flexibility but blacklist so it doesn't steal the device from SDR mode.

### Amateur Radio / AX.25 Stack

```
CONFIG_HAMRADIO=y    CONFIG_AX25=m
CONFIG_NETROM=m      CONFIG_ROSE=m     CONFIG_MKISS=m
```

**AX.25 is the ham radio equivalent of Ethernet + IP combined:**

- **Layer 2 addressing** using callsigns (like MAC addresses, but human-readable)
- **Connected mode** = TCP (reliable, ordered, ACK'd delivery over radio)
- **UI frames** = UDP (fire-and-forget, used for APRS position beacons)
- **NET/ROM** = OSPF-like routing between AX.25 nodes
- **ROSE** = X.25 WAN routing for longer distances

Once loaded, the kernel treats radio links as network interfaces:

```bash
$ sudo kissattach /dev/ttyUSB0 ax0
$ ifconfig ax0
ax0: flags=67<UP,BROADCAST,RUNNING>  mtu 256
      ax25 N0CALL-0
```

You can run IP over AX.25 and `ping` another ham station over RF. Same sockets API,
same routing table, different physical medium.

**KISS / 6PACK** are serial protocols for TNCs (Terminal Node Controller — a hardware
radio modem, like an external DSL modem). Software TNCs like direwolf replace the
hardware but use the same kernel interface.

### What Gets Stripped

Disabling unused drivers saves build time, runtime memory, and attack surface. Same
principle as disabling unused services on a firewall — less code = fewer potential
vulnerabilities.

Disabled: non-VideoCore GPU drivers, InfiniBand, ISDN, NFC, Bluetooth, joysticks,
touchscreens, accessibility. Re-enable as modules later if needed.

---

## 7. Phase 2: Transfer & Install (On the Pi)

### How Pi 5 Boot Differs From Standard Linux

Your VM boots with GRUB — a smart bootloader that auto-discovers kernels, builds
menus, and chainloads. The Pi 5 uses the Broadcom bootloader baked into the SoC,
which reads `config.txt` from the SD card's FAT32 boot partition. GRUB is a smart
managed switch that auto-discovers config; the Pi bootloader is a dumb switch
reading a static config file. Installing a kernel = copying files + editing one line.

### Transfer

```bash
# From your VM:
scp ~/rf-linux/rf-linux-kernel-*.tar.gz pi@<PI_IP>:~/
```

### Install

```bash
# On the Pi:
mkdir -p ~/rf-kernel
tar xzf ~/rf-linux-kernel-*.tar.gz -C ~/rf-kernel
sudo bash ~/rf-kernel/install-kernel.sh
```

### What the Install Script Does

**Critical: we never overwrite the stock kernel.** Ours installs alongside it.
The script adds `kernel=kernel-rflinux.img` to `config.txt`. If anything goes
wrong, deleting that one line reverts to stock. Same as keeping a rollback config
on a network device.

The script:
1. **Backs up** config.txt and current kernel to a timestamped directory
2. **Copies** `kernel-rflinux.img` to `/boot/firmware/`
3. **Copies** device tree blobs and overlays
4. **Installs** modules to `/lib/modules/<version>/`
5. **Runs** `depmod` to build the module dependency graph (like building apt's
   package dependency tree — kernel needs to know "loading A requires B and C")
6. **Updates** `config.txt` with `[pi5]` conditional pointing to our kernel

Then: `sudo reboot`

---

## 8. Phase 3: Post-Install Verification & Userspace

SSH back in after reboot:

```bash
chmod +x ~/rf-kernel/02-post-install.sh
~/rf-kernel/02-post-install.sh
```

### What Gets Verified

- **Kernel version** — confirms custom kernel, not stock
- **RT scheduling** — `/sys/kernel/realtime` should be `1`
- **Timer frequency** — 1000 Hz from `/proc/config.gz`
- **CPU governor** — "performance" mode active
- **USB subsystem** — `lsusb` works
- **AX.25 module** — `modprobe ax25` succeeds
- **Russian locale** — `date` outputs Cyrillic day/month names

---

## 9. Russian Language / Locale Configuration

### What Changes (and What Doesn't)

**In Russian:** System status messages, GUI labels, date/time formatting
(e.g., "четверг, 2 апреля 2026"), number formatting (space as thousands separator,
comma as decimal), error messages from tools that ship Russian translations, man
pages where Russian translations exist.

**Always English:** All commands (`ls`, `rtl_433`, `make`), file paths, config
file syntax, command-line flags, and output from any tool without Russian
translations (most SDR tools are English-only — they silently fall back).

This is standard Linux locale behavior. Setting `LANG=ru_RU.UTF-8` tells programs
"if you have a Russian translation for this string, use it." No commands change —
`ls` is still `ls`, not `список`.

### How It's Configured

The post-install script handles this automatically. Here's what it does:

```bash
# Generate the Russian locale
sudo locale-gen ru_RU.UTF-8

# Set as system default
sudo localectl set-locale LANG=ru_RU.UTF-8

# Install Russian fonts and translations
sudo apt-get install -y \
    fonts-dejavu-core         # Latin + Cyrillic font coverage
    fonts-liberation2         # Good Cyrillic terminal rendering
    locales                   # Locale generation tools
    manpages-ru               # Russian man page translations
    console-cyrillic          # Cyrillic in framebuffer console (HDMI)
```

### Locale Variables Explained

Linux locales are per-category language settings, like how a network device has
separate configs for management plane vs data plane:

| Variable | Controls | Example Output |
|----------|----------|----------------|
| `LANG` | Master default (sets all categories) | — |
| `LC_MESSAGES` | Status/error messages | "Нет такого файла или каталога" |
| `LC_TIME` | Date/time formatting | "четверг, 2 апреля 2026 г." |
| `LC_NUMERIC` | Number formatting | "1 000 000,50" (not "1,000,000.50") |
| `LC_COLLATE` | Sort order | Russian alphabetical (А, Б, В...) |

We set `LANG=ru_RU.UTF-8` as the master, which cascades to all categories.
If you ever want a specific category in English (e.g., English error messages
for easier Googling):

```bash
export LC_MESSAGES=en_US.UTF-8
# Everything else stays Russian, just error messages switch to English
```

### Terminal Cyrillic Rendering

**SSH from Mac:** Terminal.app and iTerm2 handle UTF-8/Cyrillic natively. No
extra config needed.

**Pi framebuffer console (HDMI):** The `console-cyrillic` package enables
Cyrillic rendering on the raw console.

### Verification

```bash
locale                    # Show all locale settings
date                      # Should show: четверг,  2 апреля 2026 г. ...
ls --help | head -5       # Still English — commands don't change
```

---

## 10. SDR Userspace Toolkit Reference

Every tool mapped to its networking equivalent.

### Tier 1: Core SDR (Installed by post-install script)

| Package | What It Does | Networking Equivalent |
|---------|-------------|----------------------|
| **librtlsdr** | Hardware abstraction for RTL-SDR. Talks USB to the chip. | libpcap |
| **rtl-sdr tools** | Basic capture/test (`rtl_test`, `rtl_fm`, `rtl_power`) | tcpdump |
| **rtl_433** | Decodes 200+ RF protocols (weather, TPMS, doorbells, LoRa) | zeek / snort |
| **dump1090** | ADS-B aircraft tracking decoder (1090 MHz) | ARP table viewer |
| **sox** | Audio/signal format converter (raw I/Q ↔ WAV) | format transcoder |
| **predict** | CLI satellite orbit predictor | route calculator |

**Why the RTL-SDR Blog fork of librtlsdr:** The v4 dongle has hardware changes
(improved LNA, HF direct sampling) needing patches not in the original osmocom
repo. Like using vendor-updated firmware vs community version.

### Tier 2: Enhanced (Install manually)

| Package | What It Does | Networking Equivalent |
|---------|-------------|----------------------|
| **GNU Radio** | Full DSP framework with visual flowgraphs | Wireshark |
| **SDR++** | Modern GUI SDR receiver with waterfall | Wireshark GUI |
| **SatDump** | All-in-one satellite decoder (NOAA, GOES, Meteor-M) | Protocol decoder |
| **gpredict** | GUI satellite tracker with rotator control | Route predictor |
| **inspectrum** | Spectrogram viewer for recorded files | Hex/packet viewer |
| **direwolf** | Software TNC / AX.25 modem | Software router |

### Tier 3: Stretch Goals

| Package | What It Does | Networking Equivalent |
|---------|-------------|----------------------|
| **iridium-toolkit** | Iridium burst decoder | Proprietary protocol RE |
| **gr-lora** | LoRa demodulation in GNU Radio | Custom dissector |
| **kalibrate-rtl** | Frequency offset calibration | NTP for your SDR |
| **urh** | Signal reverse engineering | Protocol fuzzer |

### Key Dependencies

```
libusb-1.0-0-dev      USB device communication
libfftw3-dev           Fast Fourier Transform — converts time-domain samples
                       to frequency spectrum (like converting a packet capture
                       timeline into a "top talkers" chart)
libvolk2-dev           SIMD math (uses ARM NEON to process multiple samples
                       per CPU instruction)
libboost-all-dev       C++ libraries for GNU Radio
python3-numpy/scipy    Numerical computing for DSP
python3-matplotlib     Plotting (spectrum heatmaps from rtl_power)
```

### The DVB-T Blacklist (Critical)

When you plug in the RTL-SDR, the kernel auto-loads a DVB-T driver that locks the
device into "decoded TV" mode. SDR tools need raw I/Q samples. Blacklisting is like
telling NetworkManager "hands off this interface." Without it, every SDR tool fails
with "device busy."

Post-install creates `/etc/modprobe.d/blacklist-rtlsdr.conf`:

```
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2838
blacklist dvb_usb_v2
blacklist dvb_core
```

---

## 11. First Project: NOAA APT Satellite Image

### Why NOAA APT First

NOAA APT is the `ping` of satellite reception: strong signal (~5W from orbit),
simple modulation, 10-15 minute pass windows, and you get a weather photo of
your region as proof it works.

### Signal Path

```
Antenna  →  RTL-SDR  →  Raw I/Q  →  FM demod  →  APT decode  →  PNG image
  ↕            ↕           ↕            ↕            ↕              ↕
(antenna)  (NIC/tap)  (raw pcap)  (TCP reassembly)  (HTTP parse)  (web page)
```

### Frequencies

| Satellite | Frequency |
|-----------|-----------|
| NOAA 15 | 137.620 MHz |
| NOAA 18 | 137.9125 MHz |
| NOAA 19 | 137.100 MHz |

### Capture Workflow

```bash
# 1. Find next pass (need >30° elevation for good signal)
predict -p "NOAA 19"

# 2. Record during the pass
rtl_fm -f 137.1M -s 48000 -g 48 -E dc -A fast noaa19.raw

# 3. Convert to WAV
sox -r 48000 -es -b 16 -c 1 -t raw noaa19.raw noaa19.wav

# 4. Or use SatDump for an all-in-one pipeline:
satdump live noaa_apt --source rtl_sdr --frequency 137.1e6 \
  --samplerate 1e6 --gain 40 --output_folder ./noaa_output/
```

### What You'll See

Grayscale image ~2080px wide, two channels: visible/mid-IR and thermal infrared.
Cloud patterns, coastlines, temperature gradients — received directly from 850km
above you. No internet required.

### Troubleshooting

| Symptom | Networking Equivalent | Likely Cause | Fix |
|---------|----------------------|-------------|-----|
| No signal | Interface down | Wrong freq, SDR disconnected | `rtl_test` |
| Weak/noisy | High packet loss | Bad antenna, low gain | Better antenna |
| Diagonal lines | Frame alignment | Sample rate mismatch | Verify 48000 Hz |
| Black image | Data but no parse | Wrong decode mode | Confirm APT not LRPT |
| Doppler drift | Routing flap | Sat moving | Enable Doppler correction |

### TLE Data (Satellite Ephemeris)

TLEs (Two-Line Elements) are orbital parameters — "routing entries" that predict
where a satellite will be. They drift as orbits decay, so update them like you'd
refresh OSPF neighbor tables. Stale TLEs = pointing your antenna at empty sky.

```bash
# Update TLEs (post-install script downloads initial set)
wget -O ~/.config/satellite-tle/noaa.tle \
  "https://celestrak.org/NORAD/elements/gp.php?GROUP=noaa&FORMAT=tle"
```

---

## 12. Stretch Goals: ADS-B, Iridium, LoRa

### ADS-B Aircraft Tracking (1090 MHz)

```bash
dump1090 --interactive --net --net-http-port 8080
```

ADS-B is **UDP broadcast for aircraft.** Every Mode S transponder broadcasts
position, altitude, speed, callsign on 1090 MHz — unencrypted, unauthenticated.
dump1090 decodes these into tracks. The web UI is a real-time routing table of
everything flying above you.

### Iridium Burst Decoding (1616-1626.5 MHz)

L-band reception requiring filtered LNA and more gain. Think of this as decoding
a proprietary protocol — like reverse-engineering a vendor's SNMP MIB. Uses
`gr-iridium` and `iridium-toolkit`.

### LoRa Sniffing (IceSickle Integration)

```bash
rtl_433 -f 915M -R 0 -X "name=lora,modulation=FSK"
```

If your ESP32-S3 IceSickle project uses LoRa, you can monitor its transmissions
from the Linux side — a packet sniffer on the same network as your embedded device.
Verify what it's actually transmitting vs what firmware thinks it's sending.

---

## 13. Portable Field Deployment

### Architecture

```
┌──────────────────────────────────────────────────┐
│                  Field Kit                        │
│                                                   │
│  ┌───────────┐   USB    ┌──────────────┐         │
│  │ RTL-SDR   │ ───────→ │  Pi 5        │         │
│  │ + Antenna  │          │  RF-Linux    │→ WiFi AP│
│  └───────────┘          └──────────────┘  (Mac   │
│  ┌───────────┐   USB    ↑                access) │
│  │ HackRF    │ ─────────┘                        │
│  └───────────┘                                   │
│  Power: USB-C PD battery bank (45W+)             │
└──────────────────────────────────────────────────┘
```

Pi runs headless, broadcasting WiFi AP. SSH from MacBook to control everything.
Same concept as managing pfSense via web UI while it handles the traffic.

### Docker Option

```dockerfile
FROM debian:trixie-slim
RUN apt-get update && apt-get install -y \
    librtlsdr-dev rtl-433 gnuradio sox \
    && rm -rf /var/lib/apt/lists/*
CMD ["rtl_433", "-F", "json"]
```

```bash
docker run --privileged -v /dev/bus/usb:/dev/bus/usb rf-toolkit
```

---

## 14. Rollback & Recovery

### From SSH (Pi Still Boots)

```bash
sudo sed -i '/kernel=kernel-rflinux.img/d' /boot/firmware/config.txt
sudo reboot
```

### From Another Computer (Pi Won't Boot)

1. Pull SD card, mount boot partition (FAT32, auto-mounts on Mac)
2. Edit `config.txt`, delete: `kernel=kernel-rflinux.img`
3. Re-insert, power on — stock kernel loads automatically

Stock `kernel_2712.img` is never modified. Removing our line makes the bootloader
fall back to it.

---

## 15. Learning Resources

### References

- **"The Hobbyist's Guide to the RTL-SDR"** — Carl Laufer
- **GNU Radio Tutorials** — wiki.gnuradio.org ("Guided Tutorials")
- **sigidwiki.com** — Signal identification wiki (protocol reference for RF)
- **ARRL Handbook** — The "RFC collection" of amateur radio
- **websdr.org** — Use remote SDRs to practice before your hardware arrives

### Suggested Timeline

```
Week 1-2:   VM kernel build → SCP → boot on Pi → verify
Week 3-4:   Install SDR tools → rtl_test → rtl_433 (local RF)
Week 5-6:   rtl_power spectrum scans → map your local RF environment
Week 7-8:   First NOAA satellite capture and decode
Week 9-10:  ADS-B tracking with dump1090
Week 11+:   GNU Radio flowgraphs → custom signal analysis
Week 13+:   Field deployment with battery + WiFi AP
```

### Kernel .config Quick Reference

```kconfig
# Real-time & performance
CONFIG_PREEMPT_RT=y
CONFIG_HZ_1000=y
CONFIG_NO_HZ_FULL=y
CONFIG_HIGH_RES_TIMERS=y
CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y

# USB
CONFIG_USB=y
CONFIG_USB_XHCI_HCD=y
CONFIG_USB_EHCI_HCD=y

# SDR / DVB-T
CONFIG_MEDIA_SUPPORT=m
CONFIG_DVB_RTL2832_SDR=m
CONFIG_DVB_USB_RTL28XXU=m
CONFIG_MEDIA_TUNER_R820T=m

# Amateur radio
CONFIG_HAMRADIO=y
CONFIG_AX25=m
CONFIG_NETROM=m
CONFIG_MKISS=m

# Networking
CONFIG_TUN=m
CONFIG_WIREGUARD=m
```

---

*RF-Linux Build Kit v1.0 — Target: Raspberry Pi 5 (BCM2712, ARM64)*
*Build host: Debian ARM64 VM (UTM on Apple M1)*
