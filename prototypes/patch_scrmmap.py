#!/usr/bin/env python3
# patch_scrmmap.py -- Model B (4KB page frame) device-mmap PFN conversion for
# the /dev/screen framebuffer (2026-07-24).
#
# ROOT CAUSE (emulator-reproduced): fractal/julia open /dev/screen, NewBitmap
# mmaps the chip-RAM bitplanes, DisplayScreen shows them, the compute child
# draws pixels -- but the screen stays BLACK.  No error, no kernel fault; the
# program draws into the WRONG physical pages.
#
# scrdev.c scrmmap() returns:
#     phystopfn(bp->bpl[bpnum] + offset)
# and immu.h defines  phystopfn(pa) = (u_int)(pa) >> PNUMSHFT  with PNUMSHFT=11
# (NBPP 2048 -- the stock 2 KiB geometry).  Under Model B the VM maps a d_mmap
# PFN as (PFN << 12), so a PFN of (pa >> 11) resolves to (pa >> 11) << 12 =
# 2 * pa -- the user framebuffer lands at DOUBLE the bitplane address, the
# display DMA scans the untouched (zero) bitplanes -> black screen.
#
# patch_modelb converted the PFN<<11 -> <<12 direction (719 sites) but not this
# inverse >>11 phystopfn in the device-mmap handlers.  This restores the exact
# 4 KiB geometry for scrmmap's returned PFN: the single `moveq #11` feeding the
# phystopfn `lsrl` becomes `moveq #12`.
#
# Site (kernel .text, build/unix-040):
#   scrmmap @0x82f8; phystopfn shift at 0x8384: 78 0b (moveq #11,%d4) followed
#   by e8 a8 (lsrl %d4,%d0).  -> 78 0c (moveq #12,%d4).
#
# Asserts the OLD bytes (incl. the trailing lsrl) before writing; idempotent.
# Runs on build/unix-040 after the other Model B groups; inherited into the
# dbg/quiet variants (they re-link on top of the patched base).
#
# SCOPE NOTE: ammmap (/dev/amiga) and timmap carry the same clean phystopfn
# >>11 residual and are candidates for the same fix; mmmmap (/dev/mem) and
# resmmap mix in a btopr (+2047 >>11) round-up and need independent handling.
# This patch converts ONLY the reproduced+verified scrmmap site.

import struct, sys
KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"

def u16(b, o): return struct.unpack(">H", b[o:o+2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o+4])[0]

def sections(b):
    sh = u32(b, 32); ent = u16(b, 46); n = u16(b, 48); st = u16(b, 50)
    so = u32(b, sh + st * ent + 16)
    out = {}
    for i in range(n):
        o = sh + i * ent; nm = u32(b, o)
        e = b.index(b"\0", so + nm)
        out[b[so + nm:e].decode()] = (u32(b, o + 12), u32(b, o + 16))  # (addr, offset)
    return out

# .text site: vaddr, expect (moveq #11,%d4 ; lsrl %d4,%d0), new, name
SITE = (0x8384, b"\x78\x0b\xe8\xa8", b"\x78\x0c\xe8\xa8",
        "scrmmap:moveq #11 d4 (phystopfn >>11 -> >>12; /dev/screen framebuffer)")

def main():
    buf = bytearray(open(KERNEL, "rb").read())
    secs = sections(bytes(buf))
    taddr, toff = secs[".text"]
    vaddr, old, new, name = SITE
    fo = toff + (vaddr - taddr)
    cur = bytes(buf[fo:fo + len(old)])
    if cur == new:
        print("  [skip] %s @0x%05x already >>12" % (name, vaddr))
    elif cur == old:
        buf[fo:fo + len(new)] = new
        print("  [ok]   %s @0x%05x  %s -> %s" % (name, vaddr, old.hex(), new.hex()))
    else:
        raise SystemExit("ABORT @0x%05x: bytes %s, expected %s (moveq#11+lsrl) or %s"
                         % (vaddr, cur.hex(), old.hex(), new.hex()))
    open(KERNEL, "wb").write(buf)
    print("scrmmap /dev/screen PFN geometry: done -> %s" % KERNEL)

main()
