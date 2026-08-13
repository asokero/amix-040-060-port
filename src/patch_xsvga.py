#!/usr/bin/env python3
# patch_xsvga.py -- register + geometry-fix the Klaus Burckert Xsvga graphics
# driver (svga/exp) after it has been ld -r'd into the 040 kernel (2026-07-24).
#
# EXPERIMENTAL third-party driver test -- NOT part of the standard vanilla
# kernel.  Driver source: gateway-amix-cd/install.svga (binary-only `exp`, ET_REL
# m68k).  Feasibility recorded in memory amix-xsvga-driver-feasibility.
#
# Two edits on the merged image (build/unix-040-xsvga[-dbg]):
#
# 1. cdevsw[67] registration (major 67 = svgadev; kernel.c_diff): the six
#    d_open..d_mmap slots of cdevsw[67] currently carry R_68K_32 relocations to
#    `nodev`.  Retarget them to svgaopen/svgaclose/svgaread/svgawrite/svgaioctl/
#    svgammap (same relocation-retarget mechanism as patch_a3091_dma.py).  The
#    remaining slots (d_segmap..d_flag) stay ND/notty/nostr/nullflag as stock.
#
# 2. svgammap Model-B geometry: the driver's own d_mmap returns
#    phystopfn(board + offset) with the stock 2 KiB shift (moveq #11 ; lsrl),
#    so on our 4 KiB kernel the framebuffer would land at 2*pa -> black screen
#    (identical to the scrmmap bug we already fixed).  Convert its moveq #11 ->
#    #12 (old-byte asserted), same as patch_devmmap_pfn.py.
#
# Idempotent; fails closed on any mismatch.  Run after ld -r links svga/exp.

import struct, sys
KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040-xsvga-dbg"
R_68K_32 = 1

# cdevsw[67] d_open..d_mmap relocation r_offsets -> svga entry symbol names
CDEVSW67 = [
    (0xab70, "svgaopen"),
    (0xab74, "svgaclose"),
    (0xab78, "svgaread"),
    (0xab7c, "svgawrite"),
    (0xab80, "svgaioctl"),
    (0xab84, "svgammap"),
]
EXPECT_CUR = "nodev"   # current relocation target for a "no device" slot

def u16(o, b): return struct.unpack(">H", b[o:o+2])[0]
def u32(o, b): return struct.unpack(">I", b[o:o+4])[0]

def main():
    b = bytearray(open(KERNEL, "rb").read())
    e_shoff = u32(32, b); e_shentsize = u16(46, b); e_shnum = u16(48, b); e_shstrndx = u16(50, b)
    sh = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        sh.append(dict(name=u32(o, b), type=u32(o+4, b), addr=u32(o+12, b),
                       offset=u32(o+16, b), size=u32(o+20, b), link=u32(o+24, b),
                       entsize=u32(o+36, b)))
    shstr = sh[e_shstrndx]["offset"]
    def nm(s):
        e = b.index(b"\0", shstr + s["name"]); return b[shstr + s["name"]:e].decode()
    byname = {nm(s): s for s in sh}
    symtab = byname[".symtab"]; strtab = sh[symtab["link"]]
    so, se = symtab["offset"], symtab["entsize"]; sn = symtab["size"] // se
    stroff = strtab["offset"]
    def symname(i):
        o = so + i*se; n = u32(o, b); e = b.index(b"\0", stroff + n); return b[stroff+n:e].decode()
    def sym_index(name):
        for i in range(sn):
            if symname(i) == name: return i
        raise SystemExit("ABORT: symbol %s not found" % name)
    def sym_value(name):
        return u32(so + sym_index(name)*se + 4, b)

    text = byname[".text"]; tfo = text["offset"]

    # ---- edit 1: retarget cdevsw[67] relocations nodev -> svga* ----
    rela = byname[".rela.data"]
    ro, re = rela["offset"], rela["entsize"]; rn = rela["size"] // re
    want = {off: sym_index(name) for off, name in CDEVSW67}
    reloc_at = {}
    for i in range(rn):
        o = ro + i*re; roff = u32(o, b)
        if roff in want:
            reloc_at[roff] = o
    done = skip = 0
    for off, name in CDEVSW67:
        if off not in reloc_at:
            raise SystemExit("ABORT: no .rela.data reloc at cdevsw[67] 0x%x (%s)" % (off, name))
        o = reloc_at[off]; rinfo = u32(o+4, b); cur = rinfo >> 8; typ = rinfo & 0xff
        if typ != R_68K_32:
            raise SystemExit("ABORT @0x%x: reloc type %d != R_68K_32" % (off, typ))
        tgt = sym_index(name)
        if cur == tgt:
            print("  [skip] cdevsw[67] @0x%x already -> %s" % (off, name)); skip += 1; continue
        if symname(cur) != EXPECT_CUR:
            raise SystemExit("ABORT @0x%x: current target %s, expected %s" % (off, symname(cur), EXPECT_CUR))
        struct.pack_into(">I", b, o+4, (tgt << 8) | R_68K_32)
        print("  [ok]   cdevsw[67] @0x%x  %s -> %s (0x%x)" % (off, EXPECT_CUR, name, sym_value(name)))
        done += 1
    if done and skip:
        raise SystemExit("ABORT: partial cdevsw[67] retarget (%d/%d) -- atomic group" % (done, skip))

    # ---- edit 2: svgammap phystopfn >>11 -> >>12 ----
    sm = sym_value("svgammap")
    site = sm + 0x48
    fo = tfo + (site - text["addr"])
    old = b"\x72\x0b\xe2\xa8"; new = b"\x72\x0c\xe2\xa8"
    cur = bytes(b[fo:fo+4])
    if cur == new:
        print("  [skip] svgammap @0x%x phystopfn already >>12" % site)
    elif cur == old:
        b[fo:fo+4] = new
        print("  [ok]   svgammap @0x%x phystopfn >>11 -> >>12" % site)
    else:
        raise SystemExit("ABORT @0x%x: svgammap bytes %s, expected %s/%s" % (site, cur.hex(), old.hex(), new.hex()))

    open(KERNEL, "wb").write(b)
    print("Xsvga registered (cdevsw[67]) + geometry-fixed -> %s" % KERNEL)

main()
