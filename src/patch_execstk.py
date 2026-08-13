#!/usr/bin/env python3
# patch_execstk.py -- Model B (4KB page frame) exec initial-stack conversion
# group (2026-07-19).
#
# Authoritative specs: amix-kernel-analysis/vm-map/EXEC-INITIALSTK-PATCH-SPEC.md
# + DATA-INITIALIZER-PAGESIZE-CENSUS.md action matrix prio 1 (commit cbbf40f).
#
# Source contract (svr4-src-3b2 os/machdep.c extractarg + os/exec.c):
#   int exec_initialstk = ctob(SSIZE);          /* SSIZE==1 -> one page */
#   bsize = ptrs + strings + exec_initialstk;
#   psize = btoc(bsize);  bsize = ctob(psize);  /* the +0x7ff / >>11 / <<11 trio */
# The m68k port adds a 64-page-group rounding ((psize+63)&~63, then <<11) for
# execstk_addr's fixed stack-window stepping below userstack (0xC0800000).
#
# In the compiled binary ONE moveq #11 at 0x587d8 feeds ALL THREE shifts:
#   0x587da  lsrl %d1,%d2   psize = btoc(bsize)
#   0x587e4  asll %d1,%d2   bsize = ctob(psize)
#   0x587f6  asll %d1,%d2   64-page-group base -> byte size for execstk_addr
# so the atomic group is: data word 0x800->0x1000, round-up 0x7ff->0xfff, and
# the shared shift count 11->12.  (The spec's three listed operations collapse
# to two instruction sites plus the initializer.)  execstk_addr itself is
# already clean (0 residuals; converted by the earlier Tier-0/Tier-2 groups).
#
# Changing only the data word would leave extractarg rounding at 2KB; changing
# only the instructions would leave a one-page stack allocation at 0x800 --
# both halves must land together (spec: atomic group).
#
# Each site asserts its expected OLD bytes before writing.  Operates in place on
# build/unix-040, AFTER patch_modelb*.py + patch_writeback.py + patch_swapin.py.

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
        if u32(b,o+4)==2:                      # SHT_SYMTAB
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
 (0x587d0, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff",
  "extractarg:addil #2047 d0 (btoc round-up of bsize)"),
 (0x587d8, b"\x72\x0b", b"\x72\x0c",
  "extractarg:moveq #11 d1 (shared shift: btoc/ctob/64-page-group)"),
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
            print("  [skip] %-62s %s already" % (name, where)); skip+=1
        elif cur==old:
            buf[fo:fo+len(new)]=new
            print("  [ok]   %-62s %s %s->%s" % (name, where, old.hex(), new.hex())); done+=1
        else:
            raise SystemExit("ABORT %s %s: found %s expected %s" % (name, where, cur.hex(), old.hex()))

    for vaddr, old, new, name in TEXT:
        patch(toff + (vaddr - taddr), old, new, name, "@0x%05x" % vaddr)

    # exec_initialstk .data initializer -- resolved from the symtab, NOT a
    # hardcoded file offset (spec: "resolve the data word by symbol/relocation").
    shndx, val = find_sym(bytes(buf), "exec_initialstk")
    for nm,(i,a,o) in secs.items():
        if i==shndx: dsec, doff = nm, o; break
    else:
        raise SystemExit("exec_initialstk section index %d not found" % shndx)
    patch(doff + val, b"\x00\x00\x08\x00", b"\x00\x00\x10\x00",
          "exec_initialstk DATA initializer 0x800 -> 0x1000",
          "@%s+0x%x" % (dsec, val))

    open(KERNEL,"wb").write(buf)
    print("Model B exec-stack group: %d patched, %d already -> %s" % (done, skip, KERNEL))

main()
