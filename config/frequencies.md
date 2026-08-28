<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Frequency Reference

A working cheatsheet for the signals MolniyaOS is built to receive, plus the ones
worth knowing about while you are already listening.

**Before you trust a number here, check it.** Satellite downlinks get retuned,
spacecraft fail, and ISM allocations are regional. Rows marked ⚠️ are the ones
most likely to have moved since this was written (2026-07-29). `config/` is a
cheatsheet, not an authority — CelesTrak, the satellite operator, and your
national regulator are.

Everything below is **receive-only**. Transmitting on most of these needs a
licence, and on some of them is a criminal offence regardless of licence.

---

## The RTL-SDR Blog v4's reach

Worth knowing up front, because it decides which sections of this document are
theoretical for you.

| | |
|---|---|
| Tuner | R828D |
| Continuous range | roughly 24 MHz – 1766 MHz |
| Below 24 MHz | via the built-in HF path, not the tuner |
| Practical ceiling | 1766 MHz |

So every L-band target listed here — Inmarsat at 1.5 GHz, Iridium at 1.6 GHz,
GOES at 1.69 GHz — is *inside* the dongle's range. That is not the same as being
receivable: at those frequencies the link budget, not the tuner, is the limit, and
you need gain in front of the radio. See `antennas.md`.

---

## Weather satellites — the first target

### NOAA APT (137 MHz, analogue, LEO)

The easiest first capture in the hobby: strong downlink, simple modulation,
10–15 minute passes, and an image at the end that proves the whole chain works.

| Satellite | Downlink | NORAD | Notes |
|---|---|---|---|
| NOAA 15 | 137.620 MHz | 25338 | oldest of the three, still transmitting |
| NOAA 18 | 137.9125 MHz | 28654 | note the four decimal places |
| NOAA 19 | 137.100 MHz | 33591 | usually the strongest |

- Bandwidth ~34 kHz. `rtl_fm -s 48000` is plenty.
- **Horizontal-ish, but really you want circular.** APT is transmitted
  right-hand circular; a V-dipole is the cheap compromise.
- These are the three catalogue numbers `automation/tle-updater.sh` fetches by
  default, and they are *not* in CelesTrak's `weather` group — see that script's
  header for why.

### Meteor-M LRPT (137 MHz, digital, LEO) ⚠️

Russian polar orbiters. Digital QPSK rather than analogue APT, so the image is
either good or absent — no gradual degradation.

| Satellite | Downlink | Notes |
|---|---|---|
| Meteor-M N2-3 | 137.900 MHz | ⚠️ verify before a pass |
| Meteor-M N2-4 | 137.900 MHz | ⚠️ verify; check which is active |

Meteor downlinks have a history of being switched off, retuned, and coming back.
Check the current state with SatDump's own satellite list or a recent community
report before blaming your setup.

### HRPT / AHRPT (1.7 GHz, digital, LEO) ⚠️

The high-resolution downlink from the same spacecraft. Vastly more data than APT,
and a completely different difficulty class: ~3 MHz of bandwidth, and you need a
tracking dish, an LNA, and a fast enough capture path — which is precisely the
thing the RT kernel work exists to provide.

| Signal | Downlink | Notes |
|---|---|---|
| NOAA HRPT | 1698, 1702.5, 1707 MHz | ⚠️ per-satellite |
| MetOp AHRPT | 1701.3 MHz | ⚠️ per-satellite |
| Meteor HRPT | ~1700 MHz | ⚠️ verify |

### GOES (geostationary) ⚠️

Geostationary, so no tracking and no passes — point once and leave it. Higher
resolution and continuous coverage, at the cost of needing a dish aimed correctly
and an LNA.

| Signal | Downlink | Notes |
|---|---|---|
| GOES HRIT | 1694.1 MHz | full-disk imagery |
| GOES GRB | 1686.6 MHz | ⚠️ much wider; not RTL-SDR territory |

HRIT is within reach of an RTL-SDR plus a modest dish and a good L-band LNA. GRB
is not — the bandwidth is far beyond what the dongle can deliver.

---

## SATCOM — career-relevant, receive-only

| Signal | Band | Notes |
|---|---|---|
| Iridium | 1616 – 1626.5 MHz | TDMA bursts; needs `gr-iridium` + GNU Radio |
| Inmarsat STD-C | ~1537 – 1541 MHz | maritime safety (EGC); decodable with a patch antenna and LNA |
| Inmarsat AERO | ~1545 MHz region ⚠️ | aeronautical |
| GPS L1 | 1575.42 MHz | receivable, but decoding it is its own project |

Iridium and Inmarsat are the two on this list that map directly onto SATCOM job
descriptions: Iridium is TDMA, Inmarsat is FDMA, and being able to say you have
demodulated both is worth more than being able to name them.

**Do not transmit anywhere near these.** Uplinks sit close to the downlinks, and
these are safety-of-life services.

---

## Aircraft and ships

| Signal | Frequency | Tool |
|---|---|---|
| ADS-B (1090ES) | 1090 MHz | `dump1090` |
| UAT (US, general aviation) | 978 MHz | `dump978` — not installed by MolniyaOS |
| Airband voice (AM) | 118 – 137 MHz | `rtl_fm -M am` |
| ACARS | 131.550 MHz and regional variants ⚠️ | `acarsdec` — not installed |
| AIS channel 1 | 161.975 MHz | `gr-ais`, `rtl-ais` |
| AIS channel 2 | 162.025 MHz | as above |

ADS-B is the best sanity check in this whole document: 1090 MHz, a stub antenna,
and `dump1090` gives traffic within minutes almost anywhere. If ADS-B works, the
dongle, the USB path and the driver are all fine, and any satellite problem is
antenna or timing.

---

## Amateur radio

| Use | Allocation | Notes |
|---|---|---|
| Satellite downlinks (2 m) | 145.800 – 146.000 MHz | IARU satellite subband |
| Satellite downlinks (70 cm) | 435 – 438 MHz | IARU satellite subband |
| ISS APRS digipeater | 145.825 MHz | packet; the kernel's AX.25 stack applies |
| ISS SSTV / voice | 145.800 MHz | intermittent, event-driven |
| APRS terrestrial (N. America) | 144.390 MHz | `direwolf` |
| APRS terrestrial (Europe) | 144.800 MHz | `direwolf` |

Cubesat telemetry lives mostly in those two satellite subbands.
`gr-satellites` covers hundreds of them and already handles Doppler — contribute
a decoder there rather than writing one here.

---

## ISM and consumer devices

Regional. **433 MHz in Europe and 915 MHz in North America are not
interchangeable**, and neither is legal to transmit on in the other's region.

| Band | Region | Typical use |
|---|---|---|
| 315 MHz | N. America | car remotes, garage doors, cheap sensors |
| 433.05 – 434.79 MHz | ITU Region 1 (Europe etc.) | weather stations, sensors, remotes |
| 868.0 – 868.6 MHz | Europe | LoRa, smart meters, alarms |
| 902 – 928 MHz | N. America | LoRa, meters, Zigbee-adjacent |
| 2.4 GHz | worldwide | out of the RTL-SDR's range |

`rtl_433` defaults to 433.92 MHz. The three worth sweeping are 433.92, 868.3 and
915.0 MHz:

```bash
rtl_433 -f 433.92M -f 868.3M -f 915M -H 30    # hop every 30 s
```

---

## Also on the dial

Not project targets, but useful for testing and for knowing what a real signal
looks like.

| Signal | Frequency | Why it is useful |
|---|---|---|
| FM broadcast | 88 – 108 MHz | the loudest thing you own; use it to prove the RF chain |
| NOAA Weather Radio | 162.400 – 162.550 MHz (N. America) | strong, continuous, local |
| Marine VHF | 156 – 162 MHz | channel 16 is 156.800 MHz |
| DAB (Europe) | 174 – 240 MHz | wideband digital |
| POCSAG / FLEX pagers | regional ⚠️ | `multimon-ng`; scan to find local transmitters |

A first-light check that needs no antenna theory:

```bash
rtl_power -f 88M:108M:125k -i 10 -1 fm_band.csv
```

If the FM band shows peaks, the hardware works.

---

## Quick wavelength maths

Element lengths come from this and nothing else. λ = 299.792458 / f(MHz).

| Frequency | λ | λ/2 | λ/4 |
|---|---|---|---|
| 137.5 MHz | 218.0 cm | 109.0 cm | 54.5 cm |
| 145.9 MHz | 205.5 cm | 102.7 cm | 51.4 cm |
| 162.0 MHz | 185.1 cm | 92.5 cm | 46.3 cm |
| 437.0 MHz | 68.6 cm | 34.3 cm | 17.2 cm |
| 1090 MHz | 27.5 cm | 13.8 cm | 6.9 cm |
| 1694 MHz | 17.7 cm | 8.8 cm | 4.4 cm |

Real elements come out roughly 5% shorter than the free-space figure, because of
end effects and the element's own diameter. That is why published NOAA V-dipole
builds specify 53–54 cm rather than 54.5. See `antennas.md`.

---

## Legal

Receiving is not universally legal. Several countries restrict listening to
anything not intended for you, and some restrict decoding even where listening is
allowed. Transmitting on the amateur bands needs a licence; transmitting on the
satellite, aeronautical, maritime or SATCOM allocations above is illegal for you
under every circumstance this project will ever produce.

MolniyaOS installs no transmit capability, and none of the tools here can transmit
with an RTL-SDR — it is a receiver. Check your own jurisdiction before decoding.
