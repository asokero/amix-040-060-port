#!/usr/bin/env python3
# patch_devmmap_pfn.py -- Model B (4KB page frame) device-mmap PFN conversion
# for the clean phystopfn(>>11) framebuffer/hardware handlers (2026-07-24).
#
# immu.h defines  phystopfn(pa) = (u_int)(pa) >> PNUMSHFT  with PNUMSHFT=11
# (NBPP 2048, the stock 2 KiB geometry).  A character device's d_mmap returns a
# PFN that the VM maps as (PFN << 12) under Model B, so a returned pa>>11 lands
# the user mapping at (pa>>11)<<12 = 2*pa -- DOUBLE the intended physical page.
# For a framebuffer that means the program draws into the wrong pages and the
# display stays black (reproduced + fixed for /dev/screen; see the scrmmap entry
# below and the amix-devmmap-pfn-residual note).
#
# patch_modelb converted the PFN<<11 -> <<12 direction (719 sites) but missed
# this inverse >>11 phystopfn in the device-mmap handlers.  This restores the
# exact 4 KiB geometry: each site's phystopfn shift `moveq #11` -> `moveq #12`.
#
# Sites converted (all CLEAN phystopfn(pa)>>11, verified against source + disasm):
#   scrmmap  @0x8384  /dev/screen framebuffer  (scrdev.c: phystopfn(bpl+offset))
#                     -- reproduced + VISUALLY verified (fractal/julia)
#   ammmap   @0xe0d2  /dev/amiga chip/HW aperture (amiga.c: phystopfn(offset))
#   timmap   @0x13cac TIGA graphics board framebuffer (tiga.c: phystopfn(board+off))
#
# NOT converted here (mixed btopr (+2047)>>11 round-up, need independent care):
#   mmmmap (/dev/mem), resmmap.  See the /dev/mem 2 KiB-PFN audit note.
#
# Each site asserts its OLD bytes (moveq #11,Dn ; lsrl Dn,d0) before writing;
# idempotent.  Runs on build/unix-040 after the other Model B groups; inherited
# into the dbg/quiet variants (they re-link on top of the patched base).

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
        out[b[so + nm:e].decode()] = (u32(b, o + 12), u32(b, o + 16))
    return out

# (vaddr, old = moveq #11,Dn + lsrl Dn,d0, new = moveq #12,..., name)
SITES = [
    (0x08384, b"\x78\x0b\xe8\xa8", b"\x78\x0c\xe8\xa8",
     "scrmmap (/dev/screen framebuffer)"),
    (0x0e0d2, b"\x72\x0b\xe2\xa8", b"\x72\x0c\xe2\xa8",
     "ammmap (/dev/amiga chip/HW aperture)"),
    (0x13cac, b"\x74\x0b\xe4\xa8", b"\x74\x0c\xe4\xa8",
     "timmap (TIGA graphics board framebuffer)"),
]

def main():
    buf = bytearray(open(KERNEL, "rb").read())
    secs = sections(bytes(buf))
    taddr, toff = secs[".text"]
    done = skip = 0
    for vaddr, old, new, name in SITES:
        fo = toff + (vaddr - taddr)
        cur = bytes(buf[fo:fo + len(old)])
        if cur == new:
            print("  [skip] %s @0x%05x already >>12" % (name, vaddr)); skip += 1
        elif cur == old:
            buf[fo:fo + len(new)] = new
            print("  [ok]   %s @0x%05x  %s -> %s" % (name, vaddr, old.hex(), new.hex()))
            done += 1
        else:
            raise SystemExit("ABORT @0x%05x (%s): bytes %s, expected %s or %s"
                             % (vaddr, name, cur.hex(), old.hex(), new.hex()))
    open(KERNEL, "wb").write(buf)
    print("device-mmap phystopfn >>11->>12: %d patched, %d already -> %s"
          % (done, skip, KERNEL))

main()
