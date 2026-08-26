#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# KosmOS — A/B partition layout: the single source of truth
# ============================================================================
# ROADMAP Phase 4d opens with "Partition layout — decide this first; it is the
# expensive thing to change". This file is that decision, written once.
#
# WHY THIS FILE EXISTS AT ALL, rather than three hand-written files:
#
# The same layout has to be stated in three different languages that never see
# each other --
#
#   1. the partition table itself       (an sfdisk script)
#   2. autoboot.txt                     (firmware slot selector, by partition NUMBER)
#   3. RAUC's system.conf               (slot definitions, by DEVICE PATH)
#
# -- and if any two of them disagree, the failure is not a build error. It is a
# box that flashes fine, boots fine, updates fine, and then reverts to the wrong
# slot or writes an update over its own data partition. That class of bug is the
# reason ROADMAP records the packaging-list hazard in package-kernel.sh: two
# places describing one fact, kept in step by someone remembering. Here the fact
# is stated once, below, and the three consumers are generated from it.
#
# Nothing in this file touches a disk. It only prints. Callers redirect.
#
# Usage:
#   ./layout.sh sfdisk                 > parts.sfdisk
#   ./layout.sh autoboot A             > autoboot.txt
#   ./layout.sh rauc /dev/mmcblk0      > system.conf
#   ./layout.sh cmdline A /dev/mmcblk0
#   ./layout.sh fstab A /dev/mmcblk0   > <slot A root>/etc/fstab
#   ./layout.sh slotmap                > /etc/kosmos/slots.conf
#   ./layout.sh summary
#   ./layout.sh min-bytes
# ============================================================================

set -euo pipefail

# ============================================================================
# THE LAYOUT — everything below this block is derived from it
# ============================================================================
# Verified 2026-08-20 against the Raspberry Pi firmware autoboot.txt docs.
#
# p1 must be FAT and must come first: the firmware reads autoboot.txt from the
# first FAT partition. It holds that one file and nothing else, because the
# selector cannot live inside a slot it is responsible for selecting -- an
# update rewriting bootfs A would be rewriting the file that decides whether A
# boots. Same rule as "keep the EEPROM out of the update path", one level up.
#
# p2/p3 are FAT32 and must be MBR PRIMARIES: autoboot.txt's boot_partition
# directive can only name partitions 1-4. That spends three of the four
# primaries, so p4 is an extended container and the ext4 filesystems are
# logicals from p5 up. The firmware never names those -- only cmdline.txt does
# -- so nothing is given up by demoting them.

readonly SIZE_AUTOBOOT_MIB=16      # 512 bytes of content; 16 MiB is the floor FAT16 wants
readonly SIZE_BOOT_MIB=512         # matches Pi OS /boot/firmware, which fits a kernel + DTBs + overlays
# Per slot. MEASURED, not guessed — 4096 was a guess and it was wrong.
#
# The first full SATCOM build (2026-08-23) produced a rootfs of 6347 MiB, or
# 5054 MiB once the builder's own residue was removed. That overruns a 4096 MiB
# slot by 958 MiB, so the previous value could never have held a complete
# KosmOS image; the assembled image built earlier that day only fit because the
# SATCOM stack was not in it.
#
# 6144 leaves 1090 MiB of headroom at 82% full, and it is also the LARGEST
# value that still fits a nominal 16 GB card: two 6 GiB roots put the minimum
# image at 13856 MiB against roughly 15258 MiB usable, whereas 7 GiB roots need
# 15904 MiB and break 16 GB entirely. So this is not a round number chosen for
# comfort — it is the last one before a whole class of card stops working.
readonly SIZE_ROOT_MIB=6144
readonly ALIGN_MIB=4               # SD/eMMC erase-block friendly alignment

# Partition numbers. These are not cosmetic -- autoboot.txt refers to slots by
# these numbers, and getting one wrong is a silent boot into the wrong slot.
readonly PN_AUTOBOOT=1
readonly PN_BOOT_A=2
readonly PN_BOOT_B=3
readonly PN_EXTENDED=4
readonly PN_ROOT_A=5
readonly PN_ROOT_B=6
readonly PN_DATA=7

# Filesystem labels. RAUC does not need these, but a human staring at lsblk on a
# box that will not boot very much does.
readonly LABEL_AUTOBOOT="RPIBOOT"
readonly LABEL_BOOT_A="BOOT_A"
readonly LABEL_BOOT_B="BOOT_B"
readonly LABEL_ROOT_A="ROOT_A"
readonly LABEL_ROOT_B="ROOT_B"
readonly LABEL_DATA="KOSMOSDATA"

# RAUC's compatible string. A bundle built for one compatible refuses to install
# on another, which is what stops a Pi 5 bundle landing on a Pi 4.
readonly RAUC_COMPATIBLE="kosmos-rpi5"

# MBR partition type codes, as sfdisk wants them.
readonly TYPE_FAT16="0e"           # W95 FAT16 (LBA)
readonly TYPE_FAT32="0c"           # W95 FAT32 (LBA)
readonly TYPE_EXTENDED="05"
readonly TYPE_LINUX="83"

# ============================================================================
# Derived geometry
# ============================================================================
# Computed, never typed. The minimum card size in the release notes is a
# consequence of the table above, so it cannot drift away from it.

start_autoboot_mib() { echo "$ALIGN_MIB"; }
start_boot_a_mib()   { echo "$(( $(start_autoboot_mib) + SIZE_AUTOBOOT_MIB ))"; }
start_boot_b_mib()   { echo "$(( $(start_boot_a_mib) + SIZE_BOOT_MIB ))"; }
start_extended_mib() { echo "$(( $(start_boot_b_mib) + SIZE_BOOT_MIB ))"; }

# Logical partitions inside an extended partition each need an EBR sector ahead
# of them. One aligned gap per logical is simpler than counting sectors, and
# costs 4 MiB each.
start_root_a_mib()   { echo "$(( $(start_extended_mib) + ALIGN_MIB ))"; }
start_root_b_mib()   { echo "$(( $(start_root_a_mib) + SIZE_ROOT_MIB + ALIGN_MIB ))"; }
start_data_mib()     { echo "$(( $(start_root_b_mib) + SIZE_ROOT_MIB + ALIGN_MIB ))"; }

# Smallest card this layout fits on, with a token data partition. Anything less
# and the data partition -- the whole point of 4d -- has nowhere to go.
readonly MIN_DATA_MIB=512
min_image_mib()      { echo "$(( $(start_data_mib) + MIN_DATA_MIB ))"; }

# ============================================================================
# Emitters
# ============================================================================

emit_sfdisk() {
    cat <<-EOF
	# KosmOS A/B partition table — generated by image/layout.sh, do not hand-edit.
	# Apply with:  sfdisk <device> < this-file
	label: dos
	unit: sectors
	grain: $(( ALIGN_MIB * 1024 * 1024 ))

	# p1 — autoboot.txt only. Outside both slots by design.
	start=$(start_autoboot_mib)MiB, size=${SIZE_AUTOBOOT_MIB}MiB, type=${TYPE_FAT16}, bootable
	# p2 — bootfs A
	start=$(start_boot_a_mib)MiB, size=${SIZE_BOOT_MIB}MiB, type=${TYPE_FAT32}
	# p3 — bootfs B
	start=$(start_boot_b_mib)MiB, size=${SIZE_BOOT_MIB}MiB, type=${TYPE_FAT32}
	# p4 — extended container; holds p5..p7 because primaries are exhausted
	start=$(start_extended_mib)MiB, type=${TYPE_EXTENDED}
	# p5 — root A
	start=$(start_root_a_mib)MiB, size=${SIZE_ROOT_MIB}MiB, type=${TYPE_LINUX}
	# p6 — root B
	start=$(start_root_b_mib)MiB, size=${SIZE_ROOT_MIB}MiB, type=${TYPE_LINUX}
	# p7 — data; unsized, so it takes whatever the card has left
	start=$(start_data_mib)MiB, type=${TYPE_LINUX}
	EOF
}

# autoboot.txt — the firmware's slot selector.
#
# tryboot_a_b=1 is the load-bearing line. Without it the firmware looks for
# tryboot.txt and tryboot.img *inside* the boot partition, so every slot would
# need a second copy of its own config kept in sync. With it, the tryboot switch
# happens at partition level and each slot carries one ordinary config.txt.
#
# The [tryboot] section names the OTHER slot. That is the entire A/B mechanism:
# a normal boot takes boot_partition, a `reboot "0 tryboot"` takes the [tryboot]
# one exactly once, and if nothing marks the boot good the next boot falls back
# to boot_partition on its own. No counter, no daemon.
emit_autoboot() {
    local default_slot="$1"
    local normal try
    case "$default_slot" in
        A) normal="$PN_BOOT_A"; try="$PN_BOOT_B" ;;
        B) normal="$PN_BOOT_B"; try="$PN_BOOT_A" ;;
        *) die "autoboot: slot must be A or B, got '$default_slot'" ;;
    esac

    # The firmware caps this file at 512 bytes. Comments count toward that, so
    # keep them terse here and put the explanation in this script instead.
    cat <<-EOF
	[all]
	tryboot_a_b=1
	boot_partition=${normal}

	[tryboot]
	boot_partition=${try}
	EOF
}

# RAUC system.conf. Slots are named by device path, which is why this needs the
# target device: /dev/mmcblk0p5 on an SD card, /dev/nvme0n1p5 on the NVMe HAT
# that ROADMAP 4d says the U-Boot PCIe gap disqualifies us from ignoring.
emit_rauc() {
    local dev="$1"
    local p
    p="$(part_prefix "$dev")"

    cat <<-EOF
	# KosmOS RAUC slot definitions — generated by image/layout.sh, do not hand-edit.
	[system]
	compatible=${RAUC_COMPATIBLE}
	bootloader=custom
	# On the DATA partition: anywhere under / is inside a slot, so RAUC's record
	# of which slot is good would be destroyed by the update it is tracking.
	data-directory=/data/rauc

	[handlers]
	# RAUC ships no native Raspberry Pi firmware backend -- rauc/rauc#1599 is
	# the one that will, and it is still open. The custom backend is stock RAUC
	# (trixie has v1.13; it predates v1.11), so this is registered by config
	# and patches nothing. When #1599 lands, this key goes away and the
	# bootloader= above names the native backend instead. See ROADMAP 4d.
	# NO BACKTICKS IN THIS HEREDOC: it is unquoted, so they would run.
	bootloader-custom-backend=/usr/local/lib/kosmos/kosmos-boot-backend.sh

	[keyring]
	path=/etc/rauc/kosmos.cert.pem

	# bootname is what the custom backend maps onto autoboot.txt's boot_partition.
	# The bootfs slots hang off their rootfs by parent=, so RAUC writes the pair
	# together and a half-updated slot is not reachable.
	[slot.rootfs.0]
	device=${p}${PN_ROOT_A}
	type=ext4
	bootname=A

	[slot.bootfs.0]
	device=${p}${PN_BOOT_A}
	type=vfat
	parent=rootfs.0

	[slot.rootfs.1]
	device=${p}${PN_ROOT_B}
	type=ext4
	bootname=B

	[slot.bootfs.1]
	device=${p}${PN_BOOT_B}
	type=vfat
	parent=rootfs.1
	EOF
}

# cmdline.txt root= for one slot. The firmware picks the BOOT partition via
# autoboot.txt; nothing tells it which ROOT to use, so each slot's cmdline.txt
# has to name its own. Point slot B's cmdline at root A and the box boots a
# kernel from B onto a filesystem from A, which mostly works, which is worse
# than failing.
emit_cmdline() {
    local slot="$1" dev="$2"
    local p root
    p="$(part_prefix "$dev")"
    case "$slot" in
        A) root="${p}${PN_ROOT_A}" ;;
        B) root="${p}${PN_ROOT_B}" ;;
        *) die "cmdline: slot must be A or B, got '$slot'" ;;
    esac
    # rootwait because USB/NVMe enumeration loses the race with the kernel.
    # No init=/usr/lib/raspberrypi-sys-mods/firstboot: that resizes the root
    # partition to fill the card, which on this layout would eat slot B.
    echo "console=serial0,115200 console=tty1 root=${root} rootfstype=ext4 fsck.repair=yes rootwait"
}

# /etc/fstab for one slot. A fifth consumer of the same partition numbers, and
# the one with the least forgiving failure: an fstab naming the other slot's
# root gives a box that boots, mounts the wrong filesystem over itself, and is
# then updated in place by an update that believes it is writing to the spare.
#
# The data partition is mounted at /data and is the same partition in both
# slots -- that is the entire point of it. Which KosmOS state actually lives
# there is 4b's decision; this only guarantees it is mounted and survives.
#
# p1, the slot selector, is mounted too -- and was not, until 2026-08-26. It
# was written at BUILD time and never mounted on the running system, so
# autoboot.txt was unreachable from the box whose job is to rewrite it. Nothing
# caught it because every check so far ran against an image on the build host,
# never against a booted one.
#
# Mounted ro; the RAUC backend remounts rw for the instant it writes. This is
# the most load-bearing file on the card and FAT has no journal, so the less
# time it spends writable the fewer power cuts can find it that way. nofail so
# a card without p1 -- any pre-4d single-root image -- still boots.
emit_fstab() {
    local slot="$1" dev="$2"
    local p boot root
    p="$(part_prefix "$dev")"
    case "$slot" in
        A) boot="${p}${PN_BOOT_A}"; root="${p}${PN_ROOT_A}" ;;
        B) boot="${p}${PN_BOOT_B}"; root="${p}${PN_ROOT_B}" ;;
        *) die "fstab: slot must be A or B, got '$slot'" ;;
    esac
    echo "# KosmOS slot $slot — generated by image/layout.sh. Do not hand-edit."
    printf '%-24s %-16s %-8s %-28s %s\n' \
        "$boot"             "/boot/firmware" "vfat" "defaults"          "0 2" \
        "$root"             "/"              "ext4" "defaults,noatime"  "0 1" \
        "${p}${PN_DATA}"    "/data"          "ext4" "defaults,noatime"  "0 2" \
        "${p}${PN_AUTOBOOT}" "/boot/selector" "vfat" "ro,nofail,noatime" "0 2" \
        "proc"              "/proc"          "proc" "defaults"          "0 0"
}

# The slot map, for code running ON the target rather than building the image.
#
# A fourth consumer, and the reason it is generated rather than typed: the boot
# health check has to decide whether the partition the firmware booted and the
# root the kernel mounted belong to the SAME slot. That question cannot be asked
# without the p2/p3 and p5/p6 pairing above -- and a health check carrying its
# own copy of those numbers is precisely the two-places-one-fact hazard this
# file exists to abolish. Worse than the other three, in fact: the consumer that
# drifts here is the one that decides whether to roll an update back.
#
# The image build writes this to /etc/kosmos/slots.conf. Deliberately dumb
# KEY=VALUE, not shell: it is read by a script running as root at boot, and
# sourcing a file in that position turns a corrupt config into code execution.
emit_slotmap() {
    echo "# KosmOS slot map — generated by image/layout.sh. Do not edit."
    echo "# Consumed by image/health-check/slot-identity.sh."
    echo "KOSMOS_SLOT_A_BOOT=${PN_BOOT_A}"
    echo "KOSMOS_SLOT_A_ROOT=${PN_ROOT_A}"
    echo "KOSMOS_SLOT_B_BOOT=${PN_BOOT_B}"
    echo "KOSMOS_SLOT_B_ROOT=${PN_ROOT_B}"
    echo "KOSMOS_SELECTOR_PARTITION=${PN_AUTOBOOT}"
    echo "KOSMOS_DATA_PARTITION=${PN_DATA}"
    echo "KOSMOS_COMPATIBLE=${RAUC_COMPATIBLE}"
}

emit_summary() {
    printf '%-4s %-14s %-12s %10s  %s\n' "#" "TYPE" "LABEL" "SIZE" "PURPOSE"
    printf '%-4s %-14s %-12s %10s  %s\n' \
        "p${PN_AUTOBOOT}" "FAT16 primary" "$LABEL_AUTOBOOT" "${SIZE_AUTOBOOT_MIB}M" "autoboot.txt only — slot selector"
    printf '%-4s %-14s %-12s %10s  %s\n' \
        "p${PN_BOOT_A}" "FAT32 primary" "$LABEL_BOOT_A" "${SIZE_BOOT_MIB}M" "bootfs A"
    printf '%-4s %-14s %-12s %10s  %s\n' \
        "p${PN_BOOT_B}" "FAT32 primary" "$LABEL_BOOT_B" "${SIZE_BOOT_MIB}M" "bootfs B"
    printf '%-4s %-14s %-12s %10s  %s\n' \
        "p${PN_EXTENDED}" "extended" "-" "-" "container (primaries exhausted)"
    printf '%-4s %-14s %-12s %10s  %s\n' \
        "p${PN_ROOT_A}" "ext4 logical" "$LABEL_ROOT_A" "${SIZE_ROOT_MIB}M" "root A"
    printf '%-4s %-14s %-12s %10s  %s\n' \
        "p${PN_ROOT_B}" "ext4 logical" "$LABEL_ROOT_B" "${SIZE_ROOT_MIB}M" "root B"
    printf '%-4s %-14s %-12s %10s  %s\n' \
        "p${PN_DATA}" "ext4 logical" "$LABEL_DATA" "rest" "persistent data"
    echo
    echo "Minimum image: $(min_image_mib) MiB (with a ${MIN_DATA_MIB} MiB data partition)"
    echo "16 GB card: fits, but leaves only ~1.4 GiB for captures. 32 GB is the"
    echo "number for the release notes; 16 GB is the floor, not a recommendation."
}

# ============================================================================
# Helpers
# ============================================================================

die() { echo "layout.sh: $*" >&2; exit 1; }

# mmcblk0 -> mmcblk0p , nvme0n1 -> nvme0n1p , sda -> sda , loop0 -> loop0p
# Getting this wrong yields /dev/mmcblk05, which does not exist, and the error
# surfaces three steps later as a mount failure.
part_prefix() {
    local dev="$1"
    case "$dev" in
        *[0-9]) echo "${dev}p" ;;
        *)      echo "$dev" ;;
    esac
}

usage() {
    cat <<-EOF
	usage: layout.sh <command> [args]

	  sfdisk                    partition table script for sfdisk
	  autoboot <A|B>            autoboot.txt with the named slot as default
	  rauc <device>             RAUC system.conf   (e.g. /dev/mmcblk0)
	  cmdline <A|B> <device>    cmdline.txt root= line for one slot
	  fstab <A|B> <device>      /etc/fstab for one slot
	  slotmap                   /etc/kosmos/slots.conf for the target
	  summary                   human-readable table
	  min-bytes                 minimum image size in bytes

	Prints to stdout; touches no disk.
	EOF
}

main() {
    [ $# -ge 1 ] || { usage >&2; exit 2; }
    local cmd="$1"; shift
    case "$cmd" in
        sfdisk)    emit_sfdisk ;;
        autoboot)  [ $# -eq 1 ] || die "autoboot needs a slot"; emit_autoboot "$1" ;;
        rauc)      [ $# -eq 1 ] || die "rauc needs a device";   emit_rauc "$1" ;;
        cmdline)   [ $# -eq 2 ] || die "cmdline needs a slot and a device"
                   emit_cmdline "$1" "$2" ;;
        fstab)     [ $# -eq 2 ] || die "fstab needs a slot and a device"
                   emit_fstab "$1" "$2" ;;
        slotmap)   emit_slotmap ;;
        summary)   emit_summary ;;
        min-bytes) echo "$(( $(min_image_mib) * 1024 * 1024 ))" ;;
        -h|--help|help) usage ;;
        *)         usage >&2; exit 2 ;;
    esac
}

main "$@"
