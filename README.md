# KosmOs

A real-time Linux kernel build for the Raspberry Pi 5, tuned for software-defined
radio and satellite reception.

KosmOs is not a full distribution image. It is a set of scripts that build a custom
`PREEMPT_RT` kernel from the Raspberry Pi kernel source, install it **alongside** the
stock Raspberry Pi OS kernel, and set up an SDR userspace toolchain on top. Your
existing install stays bootable; reverting means deleting one line from `config.txt`.

## Why

Stock Raspberry Pi OS runs a general-purpose kernel: a non-real-time scheduler, a
250 Hz timer, and an on-demand CPU governor. For SDR capture that combination drops
samples. At 2.4 MS/s, a 1 ms scheduling delay loses roughly 2,400 samples, which
shows up as tearing in a decoded satellite image or a corrupt frame in a packet
decoder.

KosmOs changes three things that matter:

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

- Any **ARM64 (aarch64)** Linux machine with `sudo`, at least 4 GB RAM and 40 GB free
  disk. A Debian ARM64 VM works; so does another Pi.
- No cross-compiler is used. The build is native, which is why the host must be
  ARM64. Building on an x86_64 machine will not work with these scripts as written.

Expect 45–90 minutes for a full kernel build on four cores.

## Contents

| File | Runs on | Purpose |
|---|---|---|
| `01-build-kernel.sh` | build host | Clones the Pi kernel, merges the config fragment, builds, packages a tarball |
| `sdr-rt.config` | — | Kernel config fragment: the options KosmOs changes from `bcm2712_defconfig` |
| `install-kernel.sh` | Pi | Installs the kernel, DTBs and modules alongside the stock kernel |
| `02-post-install.sh` | Pi | Verifies the running kernel, then builds the SDR userspace tools |

## Usage

### 1. Build the kernel

On the ARM64 build host:

```bash
git clone https://github.com/Mezo-oz/KosmOs
cd KosmOs
./01-build-kernel.sh
```

The script installs build dependencies, shallow-clones `raspberrypi/linux` at branch
`rpi-6.12.y`, loads `bcm2712_defconfig`, merges `sdr-rt.config` over it, then opens
`menuconfig` so you can review the result before building. Worth confirming there:

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

Everything KosmOs boots is installed into its own directory, `kosmos/`, on the boot
partition — kernel image, device tree blobs, overlays and command line. Modules go to
their own versioned directory under `/lib/modules/`. The installer then adds a `[pi5]`
block to `config.txt` setting `os_prefix=kosmos/`, which is the firmware mechanism for
loading a completely separate set of boot files.

**`config.txt` is the only stock file modified.** The stock kernel, its device trees,
its overlays and `cmdline.txt` are all left byte-identical, so the stock kernel keeps
booting against its own device trees rather than KosmOs's. That matters for reverting,
and it matters for the RT benchmark, where the entire comparison rests on nothing
differing between the two boots except the kernel.

`config.txt` is written **last**, only after every required file is confirmed present.
Until that moment the Pi still boots exactly as it did before, so an interrupted or
failed install cannot leave you unable to boot.

The KosmOs kernel command line is derived from the stock `cmdline.txt` — so `root=`
and friends carry over unchanged — with `nohz_full` and `rcu_nocbs` appended to
activate full dynticks on CPUs 1–3, leaving CPU 0 as the housekeeping core. Set
`NOHZ_FULL_CPUS=""` at the top of `install-kernel.sh` to disable that.

### 3. Verify and install SDR tools

```bash
~/kosmos-kernel/02-post-install.sh
```

It first checks the running kernel — version string, `/sys/kernel/realtime`, timer
frequency, CPU governor, USB, whether `ax25` loads — and prints a pass/fail summary.
Nothing is installed before that, so it is safe to run just for the checks.

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

`uname -r` is the reliable check: `sdr-rt.config` sets
`CONFIG_LOCALVERSION="-kosmos"`, so the version string is unambiguous. If it does not
contain `kosmos`, you booted the stock kernel.

## Reverting

If the Pi boots and you can SSH in:

```bash
sudo sed -i '/--- KosmOs custom kernel/,/--- end KosmOs/d' /boot/firmware/config.txt
sudo reboot
```

If it does not boot: pull the SD card, mount the boot partition on another machine (it
is FAT32), and delete the block between the `--- KosmOs custom kernel` and
`--- end KosmOs` markers in `config.txt`. The firmware falls back to the untouched
stock kernel. A copy of the original `config.txt` is also saved in the timestamped
`backup-*` directory alongside it.

Either way this restores `config.txt` byte-for-byte, and repeated
install/revert cycles leave no residue. Nothing else needs undoing, because nothing
else was changed — the `kosmos/` directory can be left in place or deleted.

To switch kernels for the RT benchmark, comment out the two directives inside that
block to boot stock, and uncomment them to boot KosmOs.

## What the config fragment changes

`sdr-rt.config` is a fragment, not a full config — it lists only what differs from
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

`02-post-install.sh` ends by setting the system locale to `ru_RU.UTF-8` and
installing Cyrillic fonts and Russian man pages. This is a personal preference of the
author's rather than anything SDR-related, and it is safe to remove — delete step 7
from the script, or undo it afterwards:

```bash
sudo localectl set-locale LANG=en_US.UTF-8
```

It affects only translated output: messages, date and number formatting. Commands,
paths and flags are unchanged, and most SDR tools ship no Russian translation and
stay in English regardless.

## Status and caveats

- The kernel build, install and rollback paths are the mature part of this repo.
- `02-post-install.sh` builds several tools from `git clone` of upstream `HEAD` with
  no pinned revisions, so an upstream change can break it. If a build step fails, it
  is worth checking that project's recent commits.
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

Decoding the WAV to an image needs a decoder that KosmOs does not install — 
[SatDump](https://github.com/SatDump/SatDump) is the usual choice, and can also run
the whole capture in one step.

Orbital elements go stale as orbits decay, so refresh them before a session:

```bash
mkdir -p ~/.config/satellite-tle
wget -O ~/.config/satellite-tle/noaa.tle \
  "https://celestrak.org/NORAD/elements/gp.php?GROUP=noaa&FORMAT=tle"
```

## License

No license has been declared yet. Until one is added, default copyright applies and
the code is not licensed for reuse.
