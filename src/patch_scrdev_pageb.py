#!/usr/bin/env python3
# patch_scrdev_pageb.py -- ISSUE-49: make a /dev/screen bitplane 4 KiB aligned and a whole
# number of pages long (2026-08-27).
#
# WHY.  scrmmap returns phystopfn(bp->bpl[n] + offset) and patch_devmmap_pfn.py made that
# phystopfn a 4 KiB shift (`lsrl #12`, site 0x8384).  But allocbmap asks for its planes with
# AllocMem(size, MEMF_CHIP|MEMF_PAGEB), and the MEMF_PAGEB path aligns to param.h's PAGESIZE
# -- still 0x800.  So a plane base can be 2048 mod 4096, and then the frame scrmmap hands
# back STARTS 2048 BYTES BEFORE THE PLANE: every byte the user sees is 2048 bytes early.
# Measured on 68060-260827-06 -- a mapped 640x512x1 plane at 0x00013800.
#
# The same path also frees the slack after p1+nbytes back to the chip pool, so a 4 KiB
# mapping of a 10240-byte plane covers 2048 bytes the plane does not own.  Alignment alone
# leaves that tail; rounding alone leaves the displacement.  Both halves are here.
#
# TWO MECHANISMS, because the second does not fit in place:
#
#   1. FOUR immediates in AllocMem's MEMF_PAGEB path, widened 2 KiB -> 4 KiB.  All four are
#      needed and the fourth is easy to miss: it is not in the alignment arithmetic but in
#      the TAIL-SLACK FREE, `btoC(PAGESIZE - (p1-p0))`, compiled as `movel #2079,%d0; subl
#      %d2,%d0; lsrl #5`.  Widening the first three and not that one would free 2048 bytes
#      that were never allocated, which corrupts the chip map silently.
#
#   2. allocbmap and freebmap replaced by src/scrdevfix040.s, which rounds
#      width*height/8 up to 4096.  The compiler left eight bytes where twelve are needed,
#      and the size is computed INSIDE allocbmap so a wrapper has nothing to intercept.
#      Both have exactly one call-site relocation each, so they are retargeted the same way
#      patch_a3091_badhardware.py retargets `badhardware` -- no weakening, and the stock
#      bodies stay where they are.
#
# scrmmap's bound `offset < width*height/8` is deliberately NOT touched: segdev probes
# d_mmap on page-aligned offsets only, and the last one for a mapping of len bytes is
# roundup(len,4096)-4096, which is always below the unrounded size.
#
# Every edit asserts its old bytes, and each relocation asserts its target by NAME and
# st_value.  Idempotent.

import struct, sys

KERNEL   = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"
R_68K_32 = 1

# (name, .text vaddr, old, new, what)
SITES = [
    ("AllocMem", 0x73d8, "0680 0000 081f", "0680 0000 101f",
     "btoC(nbytes + PAGESIZE): 2048+31 -> 4096+31"),
    ("AllocMem", 0x73f2, "0684 0000 07ff", "0684 0000 0fff",
     "p0 + PAGEOFFSET: 2047 -> 4095"),
    ("AllocMem", 0x73fc, "026e f800 fffe", "026e f000 fffe",
     "& PAGEMASK on the low word: ~2047 -> ~4095"),
    ("AllocMem", 0x7438, "203c 0000 081f", "203c 0000 101f",
     "btoC(PAGESIZE - (p1-p0)) tail-slack free: 2048+31 -> 4096+31"),
]

# (.rela.text r_offset, current symbol, its st_value, override)
CALLS = [
    (0x7e74, "allocbmap", 0x74e8, "scr_allocbmap"),
    (0x7956, "freebmap",  0x7580, "scr_freebmap"),
]

def u16(b, o): return struct.unpack_from(">H", b, o)[0]
def u32(b, o): return struct.unpack_from(">I", b, o)[0]

def sections(b):
    e_shoff, e_shentsize = u32(b, 32), u16(b, 46)
    e_shnum, e_shstrndx  = u16(b, 48), u16(b, 50)
    sh = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        sh.append({"name": u32(b, o), "offset": u32(b, o + 16), "size": u32(b, o + 20),
                   "link": u32(b, o + 24), "entsize": u32(b, o + 36)})
    stro = sh[e_shstrndx]["offset"]
    def nm(s):
        e = b.index(b"\0", stro + s["name"])
        return b[stro + s["name"]:e].decode()
    return sh, {nm(s): s for s in sh}

def main():
    b = bytearray(open(KERNEL, "rb").read())
    sh, sec = sections(b)
    text_foff = sec[".text"]["offset"]

    # ---------------------------------------------------------------- 1. the immediates
    done = skip = 0
    for name, va, old, new, what in SITES:
        oldb = bytes.fromhex(old.replace(" ", ""))
        newb = bytes.fromhex(new.replace(" ", ""))
        assert len(oldb) == len(newb)
        at = text_foff + va
        cur = bytes(b[at:at + len(oldb)])
        if cur == newb:
            print("  [skip] %s @0x%05x already %s" % (name, va, new))
            skip += 1
            continue
        if cur != oldb:
            sys.exit("patch_scrdev_pageb: ABORT %s @0x%05x: found %s, expected %s"
                     % (name, va, cur.hex(), oldb.hex()))
        b[at:at + len(newb)] = newb
        print("  [ok]   %s @0x%05x  %s -> %s  (%s)" % (name, va, old, new, what))
        done += 1
    if done + skip != len(SITES):
        sys.exit("patch_scrdev_pageb: ABORT: handled %d of %d immediates"
                 % (done + skip, len(SITES)))

    # ---------------------------------------------------------------- 2. the two calls
    rela, symtab = sec[".rela.text"], sec[".symtab"]
    strtab = sh[symtab["link"]]
    so, se, sn = symtab["offset"], symtab["entsize"], symtab["size"] // symtab["entsize"]
    stro2 = strtab["offset"]

    def sym_name(i):
        n = u32(b, so + i * se)
        e = b.index(b"\0", stro2 + n)
        return b[stro2 + n:e].decode()
    def sym_value(i): return u32(b, so + i * se + 4)

    idx = {}
    for i in range(sn):
        n = sym_name(i)
        if n in ("scr_allocbmap", "scr_freebmap") and n not in idx:
            idx[n] = i
    for _, _, _, ov in CALLS:
        if ov not in idx:
            sys.exit("patch_scrdev_pageb: ABORT: %s not found (scrdevfix040.o linked?)" % ov)

    ro, re_, rn = rela["offset"], rela["entsize"], rela["size"] // rela["entsize"]
    byoff = {}
    for i in range(rn):
        o = ro + i * re_
        byoff.setdefault(u32(b, o), o)

    rdone = rskip = 0
    for r_off, want, want_val, ov in CALLS:
        if r_off not in byoff:
            sys.exit("patch_scrdev_pageb: ABORT: no relocation at .text+0x%05x (%s call site)"
                     % (r_off, want))
        o = byoff[r_off]
        info = u32(b, o + 4)
        cur, rtype = info >> 8, info & 0xff
        if rtype != R_68K_32:
            sys.exit("patch_scrdev_pageb: ABORT @0x%05x: reloc type %d != R_68K_32"
                     % (r_off, rtype))
        opc = bytes(b[text_foff + r_off - 2:text_foff + r_off])
        if opc != b"\x4e\xb9":
            sys.exit("patch_scrdev_pageb: ABORT @0x%05x: expected jsr(4eb9) at -2, found %s"
                     % (r_off, opc.hex()))
        if cur == idx[ov]:
            print("  [skip] @0x%05x already -> %s" % (r_off, ov))
            rskip += 1
            continue
        n, v = sym_name(cur), sym_value(cur)
        if n != want or v != want_val:
            sys.exit("patch_scrdev_pageb: ABORT @0x%05x: call targets %s@0x%x, expected %s@0x%x"
                     % (r_off, n, v, want, want_val))
        struct.pack_into(">I", b, o + 4, (idx[ov] << 8) | R_68K_32)
        print("  [ok]   @0x%05x  %s@0x%x -> %s (sym #%d)" % (r_off, n, v, ov, idx[ov]))
        rdone += 1

    if rdone + rskip != len(CALLS):
        sys.exit("patch_scrdev_pageb: ABORT: handled %d of %d call sites"
                 % (rdone + rskip, len(CALLS)))

    if done or rdone:
        open(KERNEL, "wb").write(b)
    print("patch_scrdev_pageb: %d/%d immediates, %d/%d calls retargeted -> %s"
          % (done, len(SITES), rdone, len(CALLS), KERNEL))

if __name__ == "__main__":
    main()
