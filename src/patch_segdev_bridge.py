#!/usr/bin/env python3
# patch_segdev_bridge.py -- ISSUE-49: step segdev one HARDWARE page at a time (2026-08-26).
#
# THE DEFECT.  Model B made the page frame 4 KiB, but segdev kept a 2 KiB stride: both the
# spec_segmap preflight and the segdev_fault loop probe d_mmap every 2048 bytes.  Two
# consequences, both observed:
#   * a 2048-aligned device mmap offset yields the NEXT page -- devmaptest T1, red in every
#     battery run since it was written; and
#   * a mapping whose logical length is not a 4 KiB multiple gets its tail probe rejected,
#     which is what stops DPaint.
#
# THE REPAIR, and why it is three instructions rather than twenty-one sites.  The software
# vpage array keeps its 2 KiB representation -- two entries per hardware page -- and the
# fault loop consumes the PAIR: it reads the first entry for protection and advances the
# pointer by two entries.  Converting the representation itself is the 21-site unit in
# SEGDEV-4K-REPRESENTATION-SPEC.md and is NOT needed to fix either failure above.
#
# Reviewed against this image in
# amix-kernel-analysis/vm-map/ISSUE49-DPAINT-DEVICE-MMAP-REVIEW.md, which verified the loop
# structure in the m68k binary rather than reasoning from the C: spec_segmap's stride has no
# hidden end pointer derived from 2048, and segdev_fault's vpage advance is inside the same
# loop as its address step.
#
# WHAT THIS DEPENDS ON, WHICH IS NOT IN THIS FILE.  Pair equality holds only because the
# generic as_fault / as_setprot / as_checkprot / as_unmap boundaries round to 4 KiB before
# segdev sees anything.  Nothing links those two facts.  src/segdevchk040.s measures it --
# sdc_setprot_bad and sdc_unmap_bad must stay 0 -- because a coupling that is only written
# down decays quietly, and this project has proved that twice in one day.
#
# Every edit asserts its old bytes.  Idempotent: already-patched sites are detected.

import struct, sys

KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"

# (name, .text vaddr, old, new, what)
SITES = [
    ("spec_segmap",  0x6766a, "d4fc0800",     "d4fc1000",
     "preflight probe stride 2048 -> 4096"),
    ("segdev_fault", 0xa804c, "544a",         "584a",
     "vpage pointer +2 bytes -> +4 (consume the pair)"),
    ("segdev_fault", 0xa80aa, "068200000800", "068200001000",
     "fault loop address stride 2048 -> 4096"),
]

# The seg_page shift at 0xa7fe4 deliberately STAYS 11: the array is still paired, and the
# first entry of each pair is the one the 4 KiB PTE takes its protection from.  Asserted so
# that a future 4 KiB conversion cannot land here half-done without this patcher noticing.
SHIFT_SITE = (0xa7fe4, "7e0b")          # moveq #11,%d7 -- the 2 KiB seg_page shift

def u16(b, o): return struct.unpack(">H", b[o:o+2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o+4])[0]

def text_offset(b):
    e_shoff, e_shentsize = u32(b, 32), u16(b, 46)
    e_shnum, e_shstrndx = u16(b, 48), u16(b, 50)
    sh = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        sh.append({"name": u32(b, o), "offset": u32(b, o + 16), "size": u32(b, o + 20)})
    stro = sh[e_shstrndx]["offset"]
    for s in sh:
        e = b.index(b"\0", stro + s["name"])
        if b[stro + s["name"]:e] == b".text":
            return s["offset"]
    sys.exit("patch_segdev_bridge: ERROR: no .text section")

def main():
    b = bytearray(open(KERNEL, "rb").read())
    t = text_offset(b)

    got = bytes(b[t + SHIFT_SITE[0]:t + SHIFT_SITE[0] + 2]).hex()
    if got != SHIFT_SITE[1]:
        sys.exit("patch_segdev_bridge: ABORT: seg_page shift site @0x%05x reads %s, expected %s "
                 "-- the vpage representation may have been converted; this bridge assumes it "
                 "has NOT" % (SHIFT_SITE[0], got, SHIFT_SITE[1]))

    done = skip = 0
    for name, va, old, new, what in SITES:
        n = len(old) // 2
        cur = bytes(b[t + va:t + va + n]).hex()
        if cur == new:
            print("  [skip] %-13s @0x%05x already %s  %s" % (name, va, new, what))
            skip += 1
            continue
        if cur != old:
            sys.exit("patch_segdev_bridge: ABORT @0x%05x (%s): reads %s, expected %s -- "
                     "layout drifted, re-verify against the disassembly before patching"
                     % (va, name, cur, old))
        b[t + va:t + va + n] = bytes.fromhex(new)
        print("  [ok]   %-13s @0x%05x  %s -> %s  %s" % (name, va, old, new, what))
        done += 1

    if done + skip != len(SITES):
        sys.exit("patch_segdev_bridge: ABORT: handled %d of %d sites" % (done + skip, len(SITES)))
    if done:
        open(KERNEL, "wb").write(b)
    print("patch_segdev_bridge: %d patched, %d already, seg_page shift left at 11 -> %s"
          % (done, skip, KERNEL))

if __name__ == "__main__":
    main()
