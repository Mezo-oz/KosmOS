<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# KosmOS

A real-time Linux kernel build for the Raspberry Pi 5, tuned for software-defined
radio and satellite reception.

KosmOS is not a full distribution image. It is a set of scripts that build a custom
`PREEMPT_RT` kernel from the Raspberry Pi kernel source, install it **alongside** the
stock Raspberry Pi OS kernel, and set up an SDR userspace toolchain on top. Your
existing install stays bootable: every stock boot file is left byte-identical, and
reverting means deleting one marked block from `config.txt`.

## Why

Stock Raspberry Pi OS runs a general-purpose kernel: a non-real-time scheduler, a
250 Hz timer, and an on-demand CPU governor. For SDR capture that combination drops
samples. At 2.4 MS/s, a 1 ms scheduling delay loses roughly 2,400 samples, which
shows up as tearing in a decoded satellite image or a corrupt frame in a packet
decoder.

KosmOS changes three things that matter:

- **`PREEMPT_RT`** — the kernel becomes fully preemptible, so a capture thread can
  interrupt kernel work instead of waiting behind it.
- **1000 Hz tick with high-resolution timers** — reduces worst-case scheduling
  latency and provides the timer precision needed for Doppler correction.
- **Performance CPU governor** — pins the Cortex-A76 at full clock, so there is no
  ramp-up delay during which a buffer overflows.

It also compiles in hardware and protocol support that stock Pi kernels omit: the
RTL-SDR raw I/Q driver path and the full AX.25 amateur radio stack.

## Requirements

**Target**

- Raspberry Pi 5 (BCM2712) running Raspberry Pi OS, 64-bit
- An SD card you are willing to modify (the install is reversible, but it does edit
  the boot partition)
- RTL-SDR dongle — the userspace setup targets the RTL-SDR Blog v4

**Build host**

- Any **ARM64 (aarch64)** Linux machine with `sudo`, at least 4 GB RAM and 10 GB free
  disk. A Debian ARM64 VM works; so does another Pi.
  - **Both figures are measured, not estimated.** The 2026-07-31 build on a 4 GB Pi 5
    at `JOBS=3` consumed **~4 GB of disk** — shallow clone plus object tree — and
    never dropped below **2903 MB free RAM**, with a 4 MB peak on swap. 10 GB leaves
    room for the packaged tarball and a second build without a clean-out. An earlier
    revision of this line said 40 GB, which was inferred from kernel builds that keep
    debug info; `sdr-rt.config` sets `CONFIG_DEBUG_INFO_NONE=y`, and that is the
    difference.
- No cross-compiler is used. The build is native, which is why the host must be
  ARM64. Building on an x86_64 machine will not work with these scripts as written.

Expect 45–90 minutes for a full kernel build on four cores.

## Contents

| File | Runs on | Purpose |
|---|---|---|
| `kernel/01-build-kernel.sh` | build host | Clones the Pi kernel, merges the config fragment, builds, packages a tarball |
| `kernel/package-kernel.sh` | build host | Stages the built kernel and the Pi-side scripts into a tarball. Re-runnable without rebuilding |
| `kernel/sdr-rt.config` | — | Kernel config fragment: the options KosmOS changes from `bcm2712_defconfig` |
| `kernel/install-kernel.sh` | Pi | Installs the kernel, DTBs, overlays and cmdline into their own boot directory |
| `userspace/02-post-install.sh` | Pi | Sequencer — runs the four scripts below in order |
| `userspace/02a-verify-kernel.sh` | Pi | Verifies the running kernel. Read-only; installs nothing |
| `userspace/02b-bench-tools.sh` | Pi | `rt-tests` + `stress-ng` for the latency benchmark |
| `userspace/02c-sdr-userspace.sh` | Pi | Builds librtlsdr, rtl_433, dump1090, predict |
| `userspace/02d-locale-ru.sh` | Pi | Optional Russian locale (personal preference) |

The `02` set is copied into the kernel tarball by the build, so it arrives on the
Pi alongside the kernel payload — you do not transfer it separately.

`02a`–`02d` each run standalone. `02-post-install.sh` exists so that one command
still does the whole sequence, and because that is the name the build packages and
the docs have always pointed at.

Everything below is run from a clone of this repository on the Pi. None of it is
in the kernel tarball, because none of it is needed to get the kernel running.

| File | Runs on | Purpose |
|---|---|---|
| `userspace/03-satcom-stack.sh` | Pi | Sequencer for the three SATCOM jobs below |
| `userspace/03a-gnuradio-stack.sh` | Pi | GNU Radio, gr-osmosdr, SoapySDR — apt, pinned |
| `userspace/03b-satdump.sh` | Pi | SatDump from source, pinned to a release |
| `userspace/03c-sdrpp.sh` | Pi | SDR++ from source, pinned to a commit |
| `benchmarks/run-latency-bench.sh` | Pi | Test 1 — `cyclictest` A/B/C. No SDR hardware needed |
| `benchmarks/run-sdr-bench.sh` | Pi | Test 2 — `rtl_test` sample-loss sweep. Needs the dongle |
| `benchmarks/BENCHMARKS.md` | — | Methodology and results for the RT proof of claim |
| `automation/tle-updater.sh` | Pi | Refreshes orbital elements; writes the file `predict` reads |
| `automation/install-tle-timer.sh` | Pi | Installs the twice-daily TLE refresh timer for one user |
| `automation/kosmos-tle-update@.service` | Pi | The refresh itself. Template unit — the instance name is the username |
| `automation/kosmos-tle-update@.timer` | Pi | The schedule: 05:17 and 17:17, spread, and persistent across downtime |
| `automation/rtl-power-heatmap.py` | Pi | Plots an `rtl_power` CSV sweep as a spectrum heatmap PNG |
| `automation/install-governor.sh` | Pi | Installs the boot-time performance-governor unit |
| `automation/kosmos-governor.service` | Pi | The unit itself |
| `automation/kosmos-set-governor.sh` | Pi | The governor write, installed to `/usr/local/sbin` |
| `gr-kosmos/` | Pi | Out-of-tree GNU Radio blocks. Scaffold — see its README |
| `config/frequencies.md` | — | Frequency cheatsheet |
| `config/antennas.md` | — | Which antenna for which mission |

`ROADMAP.md` holds the project vision, phase plan and target layout.
`.github/workflows/shellcheck.yml` gates every shell script at zero shellcheck
findings on push and pull request.

## Usage

### 1. Build the kernel

On the ARM64 build host:

```bash
git clone https://github.com/Mezo-oz/KosmOS
cd KosmOS
./kernel/01-build-kernel.sh
```

It can be run from anywhere — it resolves its own location, so `cd kernel && ./01-build-kernel.sh`
works identically.

The script installs build dependencies, shallow-clones `raspberrypi/linux` at branch
`rpi-6.12.y`, loads `bcm2712_defconfig`, merges `sdr-rt.config` over it, and then
**hard-fails if `CONFIG_PREEMPT_RT`, `CONFIG_HZ_1000` or `CONFIG_IKCONFIG_PROC` did
not survive the merge** — `merge_config.sh` drops options with unmet dependencies
silently, and without that gate you would only find out after a 45–90 minute build,
an install and a reboot.

It then opens `menuconfig` so you can review the result, and re-runs the same check
afterwards so the state compiled is the state verified. Worth confirming there:

- `General setup → Preemption Model` → *Fully Preemptible Kernel (Real-Time)*
- `Networking support → Amateur Radio support → AX.25` → `M`
- `Device Drivers → Multimedia support → Realtek RTL2832 SDR` → `M`

Save and exit to start the build. The kernel source and all artifacts land in
`~/kosmos/`, separate from the repo, so you can clone this anywhere.

Output: `~/kosmos/kosmos-kernel-<version>.tar.gz`, containing the kernel image,
modules, device tree blobs, and both Pi-side scripts.

### 2. Install on the Pi

```bash
# from the build host
scp ~/kosmos/kosmos-kernel-*.tar.gz pi@<PI_IP>:~/

# on the Pi
mkdir -p ~/kosmos-kernel
tar xzf ~/kosmos-kernel-*.tar.gz -C ~/kosmos-kernel
sudo bash ~/kosmos-kernel/install-kernel.sh
sudo reboot
```

Everything KosmOS boots is installed into its own directory, `kosmos/`, on the boot
partition — kernel image, device tree blobs, overlays and command line. Modules go to
their own versioned directory under `/lib/modules/`. The installer then adds a `[pi5]`
block to `config.txt` setting `os_prefix=kosmos/`, which is the firmware mechanism for
loading a completely separate set of boot files.

**`config.txt` is the only stock file modified.** The stock kernel, its device trees,
its overlays and `cmdline.txt` are all left byte-identical, so the stock kernel keeps
booting against its own device trees rather than KosmOS's. That matters for reverting,
and it matters for the RT benchmark, where the entire comparison rests on nothing
differing between the two boots except the kernel.

`config.txt` is written **last**, only after every required file is confirmed present.
Until that moment the Pi still boots exactly as it did before, so an interrupted or
failed install cannot leave you unable to boot.

The KosmOS kernel command line is derived from the stock `cmdline.txt` — so `root=`
and friends carry over unchanged — with `nohz_full` and `rcu_nocbs` appended to
activate full dynticks on CPUs 1–3, leaving CPU 0 as the housekeeping core. Set
`NOHZ_FULL_CPUS=""` at the top of `kernel/install-kernel.sh` to disable that.

### 3. Verify and install SDR tools

```bash
~/kosmos-kernel/02-post-install.sh
```

It first checks the running kernel — version string, `/sys/kernel/realtime`, timer
frequency, CPU governor, USB, whether `ax25` loads — and prints a pass/fail summary.
Nothing is installed before that, so it is safe to run just for the checks. That
stage is `02a-verify-kernel.sh` and can be run on its own, on any kernel, as often
as you like:

```bash
~/kosmos-kernel/02a-verify-kernel.sh
```

It then offers two installs independently, each with its own prompt:

- **RT benchmark tools** (`rt-tests`, `stress-ng`) — `cyclictest` and the load
  generators for the kernel latency benchmark. Offered separately because that
  benchmark needs no SDR hardware and no SDR tools, so it can be run before any of
  the userspace stack exists.
- **SDR userspace** — builds from source: `librtlsdr` (RTL-SDR Blog fork, for v4
  support), `rtl_433`, `dump1090` and `predict`. Also blacklists the DVB-T driver so
  it cannot claim the dongle, and installs udev rules for non-root access.

Answer `n` to both if you only want the verification output.

Confirm the hardware works:

```bash
rtl_test -t
```

## Verifying the kernel

```bash
uname -r                    # should contain "kosmos"
cat /sys/kernel/realtime    # should print 1
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor   # performance
```

`uname -r` is the reliable check: `kernel/sdr-rt.config` sets
`CONFIG_LOCALVERSION="-kosmos"`, so the version string is unambiguous. If it does not
contain `kosmos`, you booted the stock kernel.

## Reverting

If the Pi boots and you can SSH in:

```bash
sudo sed -i '/--- KosmOS custom kernel/,/--- end KosmOS/d' /boot/firmware/config.txt
sudo reboot
```

If it does not boot: pull the SD card, mount the boot partition on another machine (it
is FAT32), and delete the block between the `--- KosmOS custom kernel` and
`--- end KosmOS` markers in `config.txt`. The firmware falls back to the untouched
stock kernel. A copy of the original `config.txt` is also saved in the timestamped
`backup-*` directory alongside it.

Either way this restores `config.txt` byte-for-byte, and repeated
install/revert cycles leave no residue. Nothing else needs undoing, because nothing
else was changed — the `kosmos/` directory can be left in place or deleted.

To switch kernels for the RT benchmark, comment out the two directives inside that
block to boot stock, and uncomment them to boot KosmOS.

## What the config fragment changes

`kernel/sdr-rt.config` is a fragment, not a full config — it lists only what differs from
`bcm2712_defconfig`, and `merge_config.sh` resolves the dependencies. Each option is
commented inline in the file.

**Real-time and latency**

```kconfig
CONFIG_PREEMPT_RT=y
CONFIG_HZ_1000=y
CONFIG_NO_HZ_FULL=y
CONFIG_HIGH_RES_TIMERS=y
CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y
```

**SDR hardware** — the RTL-SDR driver stack, built as modules since the dongle is
hot-plugged:

```kconfig
CONFIG_MEDIA_SDR_SUPPORT=y
CONFIG_DVB_RTL2832_SDR=m      # raw I/Q mode
CONFIG_DVB_USB_RTL28XXU=m     # DVB-T mode (compiled, then blacklisted)
CONFIG_MEDIA_TUNER_R820T=m
```

DVB-T is compiled but blacklisted at runtime. The kernel would otherwise auto-claim
the RTL2832 as a TV tuner, which exposes only decoded transport streams; SDR work
needs the raw sample path. Leaving it compiled keeps the option available.

**Amateur radio** — AX.25 and friends, absent from stock Pi kernels:

```kconfig
CONFIG_HAMRADIO=y
CONFIG_AX25=m
CONFIG_NETROM=m
CONFIG_ROSE=m
CONFIG_MKISS=m
CONFIG_6PACK=m
```

Once loaded, radio links appear as ordinary network interfaces, so the normal sockets
API and routing table apply.

**Stripped** — non-VideoCore GPU drivers, InfiniBand, ISDN, NFC, Bluetooth,
joysticks, touchscreens and accessibility support are disabled to cut build time and
runtime footprint. Re-enable any of them as modules if you need them.

## Optional: Russian locale

`userspace/02d-locale-ru.sh` sets the system locale to `ru_RU.UTF-8` and installs
Cyrillic fonts and Russian man pages. This is a personal preference of the author's
rather than anything SDR-related, and it is safe to remove — delete the script and
its line in `02-post-install.sh`, or undo it afterwards:

```bash
sudo localectl set-locale LANG=en_US.UTF-8
```

It affects only translated output: messages, date and number formatting. Commands,
paths and flags are unchanged, and most SDR tools ship no Russian translation and
stay in English regardless.

## Status and caveats

- The kernel build, install and rollback paths are the mature part of this repo.
- `userspace/02c-sdr-userspace.sh` pins every project it builds to an exact commit
  and verifies the checkout against that commit, so an upstream change cannot alter
  what gets built. If a pin ever fails to verify, that is a moved tag or a
  force-push upstream — read the history and bump the tag and SHA together rather
  than removing the check. Revisions installed are appended to
  `/usr/local/share/kosmos/build-manifest.txt`.
- `kernel/01-build-kernel.sh` is *not* pinned: it clones `raspberrypi/linux` at
  branch `rpi-6.12.y`, whose tip moves. Two kernel builds weeks apart are not the
  same kernel.
- `predict` is compiled via its own curses installer rather than a standard `make
  install`, so it needs `libncurses-dev` present.
- `gpredict` is skipped automatically on a headless system.
- Tested only on a Raspberry Pi 5. Nothing here is expected to work on a Pi 4 or
  earlier without changing the defconfig and the DTB paths.

## Suggested first target: NOAA APT

NOAA weather satellites are the easiest first capture — a strong downlink, simple
modulation, and 10–15 minute passes that produce a visible image as proof the chain
works end to end.

| Satellite | Downlink |
|---|---|
| NOAA 15 | 137.620 MHz |
| NOAA 18 | 137.9125 MHz |
| NOAA 19 | 137.100 MHz |

```bash
predict -p "NOAA 19"        # next pass; aim for >30 degrees elevation
rtl_fm -f 137.1M -s 48000 -g 48 -E dc -A fast noaa19.raw
sox -r 48000 -es -b 16 -c 1 -t raw noaa19.raw noaa19.wav
```

Decoding the WAV to an image needs a decoder that KosmOS does not install — 
[SatDump](https://github.com/SatDump/SatDump) is the usual choice, and can also run
the whole capture in one step.

Orbital elements go stale as orbits decay, so refresh them before a session:

```bash
./automation/tle-updater.sh
```

**Fetch by catalogue number, not by group.** Two things make this less obvious
than it looks, both verified against the live API on 2026-07-30:

- **There is no CelesTrak `noaa` group.** `GROUP=noaa` answers **HTTP 200** with
  the body `Invalid query: ... (GROUP=noaa not found)`, so `wget` reports success
  and writes 61 bytes of prose into `noaa.tle`. Nothing downstream notices.
- **`GROUP=weather` does not contain NOAA 15, 18 or 19** — only the JPSS birds,
  NOAA 20 and 21. The APT satellites are reachable *only* by catalogue number.

| Satellite | NORAD |
|---|---|
| NOAA 15 | 25338 |
| NOAA 18 | 28654 |
| NOAA 19 | 33591 |

If you want to do it by hand, do it by `CATNR` and keep the guard — the failure
mode here is a successful-looking download of an error page:

```bash
for id in 25338 28654 33591; do
  curl -fsS "https://celestrak.org/NORAD/elements/gp.php?CATNR=$id&FORMAT=tle" \
    | tr -d '\r' > "$id.tle"
  # An error page is HTTP 200, so check the content, not the exit status.
  grep -q "^1 " "$id.tle" || { echo "bad response for $id:"; cat "$id.tle"; }
done
```

`tle-updater.sh` does that and three things more: it verifies the mod-10 checksum
each TLE line carries, it confirms the returned elements actually carry the
catalogue number that was asked for — a typo otherwise fetches a valid TLE for the
wrong satellite, which has no symptom other than an antenna pointing at nothing —
and it writes `~/.predict/predict.tle`, the only file `predict` reads.

### Seeing what the band is doing

`rtl_power` sweeps a range and writes a CSV; `rtl-power-heatmap.py` turns that
into a picture. No dongle is needed to run the plotter — the CSV is just a file —
so this is the one piece of the SDR chain you can work on away from the hardware.

```bash
rtl_power -f 137M:138M:2k -i 10 -e 1h scan.csv    # sweep the APT band for an hour
./automation/rtl-power-heatmap.py scan.csv -o scan.png
./automation/rtl-power-heatmap.py scan.csv --summary   # is the capture any good?
```

`--summary` imports nothing outside the standard library, deliberately: on a
headless box the first question is whether the sweep worked, and answering it
should not depend on matplotlib being installed. The plot needs it:

```bash
sudo apt-get install -y python3-numpy python3-matplotlib
```

**One row of an rtl_power CSV is a chunk, not a sweep.** Any range wider than the
dongle's bandwidth is split across several rows, and only the whole set is one
line of the waterfall — the common mistake is plotting one row per output line,
which draws the chunking pattern rather than the band. Sweeps here are cut on
frequency wrap-around rather than on the timestamp, because chunk timestamps
within a sweep are not reliably identical.

**The default colormap is viridis, not `jet`.** `jet` is the SDR convention and
also the most criticised colormap in scientific visualisation: its lightness is
not monotonic, so it invents banded "features" at the cyan and yellow turns that
are not in your data, and it is close to unreadable with red-green color vision
deficiency. With viridis, brighter is stronger with no exceptions. `--cmap jet`
if you want the old look anyway.

The dB figures are **uncalibrated** and every axis says so. An RTL-SDR has no
absolute power reference — the numbers compare within one capture and are not
dBm.

### Keeping them fresh without remembering to

An unattended box should not depend on someone running that command. Install the
timer instead — twice daily, spread by up to 15 minutes so every KosmOS install
does not hit CelesTrak on the same minute, and persistent so a box that was off
through both windows updates when it comes back rather than staying a day stale:

```bash
sudo bash automation/install-tle-timer.sh          # for whoever ran sudo
sudo bash automation/install-tle-timer.sh --user homelab
```

It installs a **template unit keyed on the username**, because the elements land
under that user's `$HOME` and a root-owned copy in `/root` is one `predict` will
never open. Enabling it for the wrong account is the failure this shape prevents:
the timer would run, succeed, and maintain elements nobody reads.

The install runs one update immediately (`--no-run` to skip), so you find out
then rather than during a pass. After that, the unit's exit status is the answer:

```bash
systemctl status kosmos-tle-update@homelab.service
systemctl list-timers kosmos-tle-update@homelab.timer
```

`tle-updater.sh` exits non-zero if any source failed to fetch or validate, and it
installs only what it could validate — so a failed refresh is a failed unit *and*
leaves the previous good elements untouched. `sudo bash automation/install-tle-timer.sh
--uninstall` removes all of it. Without systemd, the cron line in the script's
header does the same job with less reporting.

## License

KosmOS's own code — every script in this repository and the documentation — is
licensed under the **GNU General Public License, version 3 or later**. The full
text is in [`LICENSE`](LICENSE).

**One deliberate exception: `kernel/sdr-rt.config` is GPL-2.0-only**, matching the
kernel it configures. It is merged into a GPL-2.0-only kernel's `.config` by
`merge_config.sh`, so licensing it the same way removes any question about using
it alongside kernel sources. Every file carries an `SPDX-License-Identifier` line
saying which of the two applies to it, so the answer is always in the file rather
than inferred from this section.

```
Copyright (C) 2026 the KosmOS authors

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE.  See the GNU General Public License for more details.
```

### The kernel is not covered by this

**`raspberrypi/linux` is GPL-2.0-only, and stays that way.** Nothing here changes
that, and nothing here could.

KosmOS ships no kernel source. What it ships is a build recipe: `01-build-kernel.sh`
clones the Raspberry Pi kernel from upstream, merges `sdr-rt.config` over
`bcm2712_defconfig`, and compiles it. The kernel you end up with is upstream's
code under upstream's licence — GPL-2.0-only, plus the syscall exception — and if
you redistribute that binary, the kernel's terms are the ones that apply to it,
including the obligation to offer the corresponding source.

So there are two licences in play and they cover different things:

| What | Licence | Whose code |
|---|---|---|
| Scripts, docs, `gr-kosmos/` | GPL-3.0-or-later | KosmOS |
| `kernel/sdr-rt.config` | GPL-2.0-only | KosmOS |
| The kernel that gets built | GPL-2.0-only (upstream) | Raspberry Pi / Linux |
| Everything `02c`/`03` install | each project's own terms | upstream |

GPL-2.0-only and GPL-3.0 are not compatible with each other, which matters if you
ever combine code rather than just invoke it. Nothing in this repository does:
these scripts drive the kernel build as a separate program, and the config
fragment is an *input* to that build, not part of the resulting work. Licensing
the fragment GPL-2.0-only closes the question rather than relying on that
argument.

The tools the userspace scripts install keep their own licences. `02c` and `03`
build from upstream sources and change none of them; the pinned revision of each
is recorded in `/usr/local/share/kosmos/build-manifest.txt`, which is also where
to look when you need to know exactly whose code is on the box.
