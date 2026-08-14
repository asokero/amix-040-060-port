#!/usr/bin/env python3
# patch_swapin.py -- Model B (4KB page frame) block-swap page-IN conversion group
# (ISSUE-10 remaining producer, 2026-07-19).
#
# After the hat_pageunload040 M-harvest fix (260718-03) dirty anon pages DO reach
# swap, but the swap-IN path was never hot before and still carries the old 2KB
# page contract.  The exact patch contract is retained below; its cross-family
# status is in docs/contracts/PRODUCER-CONSUMER-ASYMMETRY-CENSUS.md.  The decisive defect is the
# compiled DATA initializer `int klustsize = 0x800` (specvnops.c KLUSTSIZE =
# PAGESIZE): spec_getapage submits a 2KB read into the freshly allocated 4KB page
# and then EXPLICITLY ZEROES bytes 0x800..0xfff ("destructive tail zero") -> every
# swapped-in anon page loses its upper half -> heap/stack garbage -> 4AFC005F
# avalanche exactly when swap-in traffic starts.
#
# klustsize reader census (ALL R_68K_32 relocs against the symbol; verified against
# both vanilla and the current build -- there are exactly 6, no writers):
#   0x66cc2  spec_getapage  adj_klustsize load           -> blkoff/blksz math, OK at 0x1000
#   0x66e76  spec_getapage  read-ahead off2 divide        -> 4K-aligned at 0x1000, OK
#   0x66e82  spec_getapage  read-ahead off2 multiply      -> OK
#   0x66eb8  spec_getapage  read-ahead EOF bound          -> OK
#   0x66eca  spec_getapage  read-ahead blksz              -> OK
#   0x6733e  spec_putpage   adj_klustsize load            -> offlo/offhi klustering, OK
# (The UNKNOWN_SIZE PAGESIZE branches at 0x66cb6/0x67330 were already converted by
# patch_writeback.py / patch_modelb_pager.py; only the global was missed -- the
# "123/123 pager sites" claim covered instruction immediates, not .data.)
#
# The instruction sites below are the related contract residuals from the same
# audit (static acceptance criteria 2, 3 and 6); the .data patch is criterion 1.
# swap_maxcontig (.data+0xb544 = 0x200) intentionally NOT touched: single reader
# is swap_alloc's area-rotation policy counter, a no-op with one swap area.
#
# Each site asserts its expected OLD bytes before writing.  Operates in place on
# build/unix-040, AFTER patch_modelb*.py + patch_writeback.py.

import struct, sys
KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"

def u16(b,o): return struct.unpack(">H", b[o:o+2])[0]
def u32(b,o): return struct.unpack(">I", b[o:o+4])[0]

def sections(b):
    sh=u32(b,32); ent=u16(b,46); n=u16(b,48); st=u16(b,50)
    so=u32(b, sh+st*ent+16)
    out={}
    for i in range(n):
        o=sh+i*ent; nm=u32(b,o)
        e=b.index(b"\0", so+nm)
        out[b[so+nm:e].decode()]=(i, u32(b,o+12), u32(b,o+16))  # (index, addr, offset)
    return out

def find_sym(b, name):
    """(section_index, st_value) of a named symbol in an ET_REL symtab."""
    sh=u32(b,32); ent=u16(b,46); n=u16(b,48)
    for i in range(n):
        o=sh+i*ent
        # sh_type SYMTAB=2
        if u32(b,o+4)==2:
            soff=u32(b,o+16); ssize=u32(b,o+20); slink=u32(b,o+24)
            stro=u32(b, sh+slink*ent+16)
            for j in range(ssize//16):
                so_=soff+j*16
                nm=u32(b,so_)
                e=b.index(b"\0", stro+nm)
                if b[stro+nm:e].decode()==name:
                    return u16(b,so_+14), u32(b,so_+4)   # st_shndx, st_value
    raise SystemExit("symbol %s not found" % name)

# .text sites: (vaddr, expect, new, name)
TEXT = [
 (0x6711a, b"\x06\x81\x00\x00\x07\xff", b"\x06\x81\x00\x00\x0f\xff",
  "spec_getpage:addil #2047 d1 (EOF allowance s_size+PAGEOFFSET)"),
 (0x67186, b"\x0c\x82\x00\x00\x08\x00", b"\x0c\x82\x00\x00\x10\x00",
  "spec_getpage:cmpil #2048 d2 (len<=PAGESIZE direct-provider gate)"),
 (0xad9a6, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00",
  "anon_getpage:pea 2048 (VOP_GETPAGE len = one full page)"),
 (0xb1a28, b"\x06\x82\x00\x00\x08\x00", b"\x06\x82\x00\x00\x10\x00",
  "pvn_fail:addil #2048 d2 (failed-I/O bytes per page-list node)"),
]

def main():
    buf=bytearray(open(KERNEL,"rb").read())
    secs=sections(bytes(buf))
    tidx, taddr, toff = secs[".text"]
    done=skip=0

    def patch(fo, old, new, name, where):
        nonlocal done, skip
        cur=bytes(buf[fo:fo+len(old)])
        if cur==new:
            print("  [skip] %-58s %s already" % (name, where)); skip+=1
        elif cur==old:
            buf[fo:fo+len(new)]=new
            print("  [ok]   %-58s %s %s->%s" % (name, where, old.hex(), new.hex())); done+=1
        else:
            raise SystemExit("ABORT %s %s: found %s expected %s" % (name, where, cur.hex(), old.hex()))

    for vaddr, old, new, name in TEXT:
        patch(toff + (vaddr - taddr), old, new, name, "@0x%05x" % vaddr)

    # klustsize .data initializer -- resolved from the symtab, NOT hardcoded, so a
    # layout shift in a future relink cannot silently patch the wrong longword.
    shndx, val = find_sym(bytes(buf), "klustsize")
    for nm,(i,a,o) in secs.items():
        if i==shndx: dsec, doff = nm, o; break
    else:
        raise SystemExit("klustsize section index %d not found" % shndx)
    patch(doff + val, b"\x00\x00\x08\x00", b"\x00\x00\x10\x00",
          "klustsize DATA initializer 0x800 -> 0x1000",
          "@%s+0x%x" % (dsec, val))

    open(KERNEL,"wb").write(buf)
    print("Model B swap-in group: %d patched, %d already -> %s" % (done, skip, KERNEL))

main()
