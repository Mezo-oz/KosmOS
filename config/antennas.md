# Antenna Selection Guide

Which antenna for which mission, and why.

The antenna is the part of an SDR setup that most determines whether anything
works, and the part most often skipped. A £20 dongle on a good antenna beats a
£300 dongle on a bad one, every time — no amount of gain, filtering or real-time
kernel recovers a signal the antenna never picked up.

---

## Start here

| Mission | Antenna | Effort |
|---|---|---|
| NOAA APT weather images | **V-dipole**, 137 MHz | one afternoon, ~£5 of parts |
| Weather sats, whole pass | **QFH** or turnstile | a weekend |
| ADS-B aircraft | **λ/4 ground plane**, 1090 MHz | 20 minutes |
| Anything, to start scanning | **the dongle's dipole kit** | already in the box |
| GOES geostationary imagery | **dish + L-band LNA** | a project |
| Tracking one satellite | **Yagi + rotator** | a bigger project |
| General wideband monitoring | **discone** | buy, don't build |
| HF | **long wire or loop** | depends entirely on your site |

If you are starting the project: build the V-dipole. It is the cheapest path from
nothing to a satellite image, and getting one image out changes how the rest of the
work feels.

---

## The two things that matter more than the antenna type

### 1. Polarisation

Satellites transmit **circular** polarisation, because a spacecraft's orientation
relative to you changes throughout a pass and a linear antenna would fade in and
out as the geometry rotated.

A linear antenna receiving a circular signal loses about **3 dB** — half the
power — and that is a fixed, unavoidable loss, not something to tune out. It is
also *the acceptable trade*: a V-dipole is linear, loses that 3 dB, and still
produces good NOAA images, because 137 MHz downlinks are strong.

Where it stops being acceptable is when you are already short of signal: L-band,
weak cubesats, low elevations. That is when a QFH or turnstile earns its build
time.

Terrestrial signals are a different rule: match what the transmitter uses.
Broadcast FM, airband, marine and most ISM are vertical. ADS-B is vertical.

### 2. Where it is, not what it is

Height and sky view beat design. A mediocre antenna on a roof outperforms an
excellent one indoors, because at 137 MHz a satellite at 20° elevation is being
received through however many walls, and a building is a very effective attenuator.

For satellite work, what you want is a clear view of the *horizon in every
direction*, because a pass starts and ends there. A garden with a clear north-south
line beats a balcony facing one way.

Keep coax short, and keep it away from mains wiring and switching power supplies
— a cheap USB charger will raise your noise floor further than a better antenna
will lower it.

---

## V-dipole — 137 MHz weather satellites

The standard first build, and the reason it works so well for APT is geometry: two
elements in a 120° V, mounted horizontally, produce a rough approximation of a
sky-facing pattern with usable circular response.

```
        \           /
         \  120°   /      each leg ~53 cm
          \       /
           \_____/        feedpoint: coax centre to one leg,
                          shield to the other
        mounted horizontally, V opening upward
```

- **Leg length: 53–54 cm.** λ/4 at 137.5 MHz is 54.5 cm; real elements come out
  ~5% short because of end effects, and published builds settle on 53–54 cm.
- **Angle: 120°.** Not critical to a degree, but 90° and 180° both measurably
  worse. 180° is a plain dipole.
- **Orientation: horizontal, opening up.** The V lies in a horizontal plane. A
  common mistake is standing it vertically, which nulls the overhead sky.
- **Align the V north-south** if your passes are polar, which for NOAA they are.
- Any conductor works: brass rod, welding rod, copper tube, coat hanger. Rigidity
  matters more than material.
- No balun, no matching network, no tuning. It is receive-only.

### On SWR

Receive-only setups do not need an SWR meter and cannot be damaged by a mismatch.
A badly matched receive antenna loses some signal; it does not reflect power into
anything that minds. Do not spend money on matching equipment for this project.

---

## QFH — quadrifilar helicoidal

The proper answer for weather satellites: genuinely circular, with a pattern that
favours the whole sky rather than straight up, so a pass stays usable from horizon
to horizon instead of peaking overhead and fading.

Worth building when the V-dipole has proved the chain works and low-elevation
dropouts have become the limiting factor. It is a fiddly build — the dimensions
are unforgiving and there is real geometry involved — so it is the second antenna,
not the first.

A **turnstile** (two crossed dipoles with a 90° phasing line) is easier to build
and gets most of the way there.

---

## Dish — GOES and L-band

Geostationary means point once and never move it, which is the appeal. Everything
else about it is harder.

- **Dish size**: a 60–100 cm grid or prime-focus dish is the usual starting point
  for GOES HRIT at 1694 MHz.
- **An LNA at the feed is not optional.** At 1.7 GHz, coax loss is severe and any
  loss ahead of the first amplifier is added directly to the noise figure. The LNA
  goes at the antenna, not at the radio.
- **A filter helps more than you expect.** Mobile phone bands sit close by and
  will overload a wideband LNA.
- Feed choices: a helical feed or a patch. Patches are commercially available and
  much less work.

The RTL-SDR Blog v3 and v4 have a software-switchable **bias tee** for powering an
LNA up the coax:

```bash
rtl_biast -b 1     # bias tee on
rtl_biast -b 0     # off
```

Turn it off before connecting anything that is not expecting DC on its input.

---

## Yagi — directional tracking

High gain in one direction, which for a moving satellite means it must be aimed
continuously — so a Yagi implies a rotator and rotator control (`hamlib`,
`rotctld`, in the ROADMAP under Phase 1b).

Worth it for weak signals from a known target. Not worth it for general reception:
a Yagi pointed the wrong way is worse than a dipole.

Also useful hand-held for finding an interference source, where the directionality
is the point.

---

## λ/4 ground plane — ADS-B at 1090 MHz

The quickest possible win in this document, and the best diagnostic you have.

- Vertical element: **6.9 cm** (λ/4 at 1090 MHz), minus the usual few percent.
- Three or four radials of the same length, sloping down at ~45°.
- An SMA connector with a 6.9 cm wire soldered into the centre pin works.

Aircraft are line-of-sight and everywhere, so this gives results in minutes almost
anywhere. **Use it as the first test of any new setup**: if ADS-B works, the
dongle, the USB path, the driver and the software are all fine, and any satellite
problem is antenna, timing or geometry — which cuts the search space in half.

Purpose-built ADS-B collinears are cheap and noticeably better if you want range.

---

## Discone — wideband monitoring

Not efficient at any one frequency, usable across a huge range. The right choice
for browsing spectrum and finding out what is on the air locally, and the wrong
choice for any specific weak-signal mission.

Buy rather than build: the geometry is unforgiving and commercial ones are cheap.

---

## HF — below 30 MHz

The RTL-SDR Blog v3 and v4 reach HF through direct sampling, which makes shortwave
possible but not easy.

A long wire or a magnetic loop, and expect to fight noise: HF reception is
dominated by local electrical interference, and a magnetic loop's ability to be
rotated to null out an interference source is often worth more than any gain
figure.

Out of scope for the SATCOM focus, but the hardware can do it.

---

## Field kit

The ROADMAP's Phase 3c field deployment needs antennas that survive transport,
which is a different requirement from performing well.

- **V-dipole with hinged legs** — folds flat, sets up in seconds, and its
  performance is not sensitive to being a few degrees off.
- **Telescopic whip** (the dongle's dipole kit) — adjustable across bands, packs
  into nothing, mediocre everywhere. The right compromise for a go-bag.
- **A tripod and 3 m of mast** improves any of them more than swapping antenna
  type will.
- Bring more coax than you think, and bring adapters. A field session lost to a
  missing SMA-to-BNC adapter is a very annoying way to learn this.

---

## What to buy first

1. **The RTL-SDR Blog v4 kit** — comes with the telescopic dipole, which is enough
   for FM, airband, ADS-B and a first NOAA attempt.
2. **Brass rod and an SMA pigtail** — the V-dipole, ~£5.
3. **An ADS-B LNA/filter** if aircraft turn out to be the interesting part.
4. **Nothing else until something specific is limiting you.** The next purchase
   should be a response to a measurement, not a guess.
