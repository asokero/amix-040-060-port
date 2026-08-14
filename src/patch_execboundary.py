#!/usr/bin/env python3
# patch_execboundary.py -- ISSUE-32: the live ELF exec page-geometry boundary.
#
# Authoritative census: docs/contracts/EXEC-BOUNDARY-CENSUS.md
# Source provenance:    svr4-src-3b2/usr/src/uts/3b2/os/exec.c  (exec.c:195-200, 285-287,
#                       804-846) and .../exec/elf/elf.c (elf.c:211, 352)
#
# GROUPS (env EXECBOUNDARY_GROUPS, default all).  Codex's minimal atomic units:
#
#   exhd     header-cache RANGE unit: exhd_getfbuf + exhd_nomap, 11 sites.
#            Both operate on the same exhdmap_t range list; converting one side alone
#            would make the list use one page geometry and its release/trim side
#            another.  The 8 KiB MAXBSIZE window (0x5677a `andiw #-8192`) is the
#            fbuf/header window, NOT a page, and is asserted as a canary.
#
#   execmap  live ELF mapping unit, 6 sites.  0x57a68/0x57a72 are the direct-VOP_MAP
#            eligibility test `(offset & PAGEOFFSET) == (addr & PAGEOFFSET)`: with a
#            2 KiB mask the loader can call a file offset and a virtual address equally
#            aligned when they are NOT equal modulo 4 KiB, and then take the direct
#            mapping path under the wrong page relationship.  The already-converted BSS
#            tail (0x57c1c `+4095`, 0x57c22 `>>12`) is asserted as a canary.
#
#   elfsz    *execsz page-count contract, 4 sites -- **CORRECTED FROM THE CENSUS**.
#            The census lists only the CONSUMER (elfexec 0xb8440/0xb8446,
#            `if (*execsz > btopr(u+0x7d4)) return ENOMEM`) and marks it "convert or
#            prove byte-unit exception".  The proof was done and it changed the answer:
#              * u+0x7d4 IS a byte value -- as_map @0xae52a compares it directly against
#                a byte quantity, and ulimit/getcoffhead use it as a byte limit;
#              * BUT the PRODUCER is also still 2 KiB: mapelfexec @0xb85f0 accumulates
#                `*execsz += btoc(p_memsz)` at 0xb86fe/0xb8704 with +2047/>>11.
#            So today both sides count in 2 KiB units and the limit check is CORRECT.
#            Converting only the consumer would make it twice as strict and exec would
#            start failing with spurious ENOMEM.  Producer and consumer must flip
#            together, which is why this group is 4 sites, not 2.
#            mapelfexec is a LOCAL symbol (`t mapelfexec`), which is why it fell outside
#            the raw candidate scan supplied with the task brief.
#
# DEFERRED, NOT IN THIS PATCH (census):
#   coffcore  9 sites -- COFF core-FILE layout; wrong bytes in a diagnostic artifact,
#             not the live process address space.  Convert only if COFF is shown
#             reachable, and as one unit.
#   getcoffhead 0xb7cce/0xb7cd4 and 0xb7d32/0xb7d38 -- the COFF-side *execsz producers.
#             Reached only through coffexec (deferred).  getcoffshlibs, which IS
#             reachable from an ELF exec carrying PT_SHLIB, contains no btoc site of its
#             own, so leaving the COFF producers old does not desynchronise the ELF
#             group.  If COFF is ever enabled these must convert with coffexec's own
#             consumer.
#   grow/brk  already 4 KiB; companion user-VM unit with its own acceptance test.
#
# hat_exec (0xd87f0) is the native 040 no-op override (clr.l d0 / rts); the old 030
# stack page-table transfer body is NOT called and must not be re-enabled by this work.
#
# Old bytes verified against build 68040-260725-13
# (735353d215e6679e71233c480edbabd265ff4a8fa6d9e7a2fc5226cd81c62d1d).

import struct, sys, os
KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"
GROUPS = set((os.environ.get("EXECBOUNDARY_GROUPS") or "exhd,execmap,elfsz").split(","))

def u16(b,o): return struct.unpack(">H", b[o:o+2])[0]
def u32(b,o): return struct.unpack(">I", b[o:o+4])[0]

def sections(b):
    sh=u32(b,32); ent=u16(b,46); n=u16(b,48); st=u16(b,50)
    so=u32(b, sh+st*ent+16)
    out={}
    for i in range(n):
        o=sh+i*ent; nm=u32(b,o)
        e=b.index(b"\0", so+nm)
        out[b[so+nm:e].decode()]=(i, u32(b,o+12), u32(b,o+16))
    return out

R47 = b"\x00\x00\x07\xff"; R95 = b"\x00\x00\x0f\xff"

TEXT = [
 # ---- exhd_getfbuf / exhd_nomap: one range-ownership unit --------------------
 ("exhd", 0x56786, b"\x02\x41\xf8\x00", b"\x02\x41\xf0\x00", "exhd_getfbuf:bpoff = off & PAGEMASK"),
 ("exhd", 0x567b4, b"\x06\x80"+R47,     b"\x06\x80"+R95,     "exhd_getfbuf:eoff + PAGESIZE-1"),
 ("exhd", 0x567bc, b"\x02\x41\xf8\x00", b"\x02\x41\xf0\x00", "exhd_getfbuf:epoff & PAGEMASK"),
 ("exhd", 0x569d6, b"\x02\x41\xf8\x00", b"\x02\x41\xf0\x00", "exhd_nomap:poff & PAGEMASK"),
 ("exhd", 0x569e2, b"\x06\x80"+R47,     b"\x06\x80"+R95,     "exhd_nomap:epoff + PAGESIZE-1"),
 ("exhd", 0x569ea, b"\x02\x41\xf8\x00", b"\x02\x41\xf0\x00", "exhd_nomap:epoff & PAGEMASK"),
 ("exhd", 0x56e26, b"\x02\x41\xf8\x00", b"\x02\x41\xf0\x00", "exhd_nomap:split poff & PAGEMASK"),
 ("exhd", 0x56e42, b"\x06\x82"+R47,     b"\x06\x82"+R95,     "exhd_nomap:split epoff + PAGESIZE-1"),
 ("exhd", 0x56e48, b"\x02\x42\xf8\x00", b"\x02\x42\xf0\x00", "exhd_nomap:split epoff & PAGEMASK"),
 ("exhd", 0x56f64, b"\x06\x82"+R47,     b"\x06\x82"+R95,     "exhd_nomap:tail epoff + PAGESIZE-1"),
 ("exhd", 0x56f6a, b"\x02\x42\xf8\x00", b"\x02\x42\xf0\x00", "exhd_nomap:tail epoff & PAGEMASK"),

 # ---- execmap: direct-map eligibility + mapping-input normalization ----------
 ("execmap", 0x57a68, b"\x02\x80"+R47, b"\x02\x80"+R95, "execmap:offset & PAGEOFFSET (VOP_MAP test)"),
 ("execmap", 0x57a72, b"\x02\x81"+R47, b"\x02\x81"+R95, "execmap:addr & PAGEOFFSET (VOP_MAP test)"),
 ("execmap", 0x57a9a, b"\x02\x6e\xf8\x00\x00\x0e", b"\x02\x6e\xf0\x00\x00\x0e", "execmap:offset &= PAGEMASK"),
 ("execmap", 0x57ac0, b"\x02\x6e\xf8\x00\x00\x1a", b"\x02\x6e\xf0\x00\x00\x1a", "execmap:2nd mapping input &= PAGEMASK"),
 ("execmap", 0x57b24, b"\x06\x80"+R47, b"\x06\x80"+R95, "execmap:len + PAGESIZE-1"),
 ("execmap", 0x57b2a, b"\x74\x0b",     b"\x74\x0c",     "execmap:len >> PAGESHIFT"),

 # ---- *execsz: PRODUCER and CONSUMER together (census listed only the consumer)
 ("elfsz", 0xb86fe, b"\x06\x80"+R47, b"\x06\x80"+R95, "mapelfexec:*execsz += btoc(p_memsz) round"),
 ("elfsz", 0xb8704, b"\x7e\x0b",     b"\x7e\x0c",     "mapelfexec:*execsz += btoc(p_memsz) shift"),
 ("elfsz", 0xb8440, b"\x06\x80"+R47, b"\x06\x80"+R95, "elfexec:btopr(u+0x7d4) limit round"),
 ("elfsz", 0xb8446, b"\x78\x0b",     b"\x78\x0c",     "elfexec:btopr(u+0x7d4) limit shift"),
]

CANARY = [
 (0x5677a, b"\x02\x41\xe0\x00",             "exhd_getfbuf boff & MAXBMASK -- 8 KiB fbuf window"),
 (0x57c1c, b"\x06\x80\x00\x00\x0f\xff",     "execmap BSS tail +4095 -- already converted"),
 (0x57c22, b"\x74\x0c",                     "execmap BSS tail >>12 -- already converted"),
 (0xb842c, b"\x24\xfc\x00\x00\x10\x00",     "elfexec AT_PAGESZ = 4096"),
 (0xb8406, b"\x02\x44\xe0\x00",             "elfexec & MAXBMASK -- 8 KiB aux-vector window"),
]

def main():
    buf=bytearray(open(KERNEL,"rb").read())
    secs=sections(bytes(buf))
    tidx, taddr, toff = secs[".text"]

    for vaddr, want, what in CANARY:
        fo = toff + (vaddr - taddr)
        if bytes(buf[fo:fo+len(want)]) != want:
            raise SystemExit("ABORT canary @0x%05x (%s): found %s expected %s"
                             % (vaddr, what, bytes(buf[fo:fo+len(want)]).hex(), want.hex()))

    done=skip=off=0
    sel=[t for t in TEXT if t[0] in GROUPS]
    for grp, vaddr, old, new, name in TEXT:
        if grp not in GROUPS:
            off += 1; continue
        fo = toff + (vaddr - taddr)
        where = "@0x%05x" % vaddr
        cur=bytes(buf[fo:fo+len(old)])
        if cur==new:
            print("  [skip] %-7s %-52s %s already" % (grp, name, where)); skip+=1
        elif cur==old:
            buf[fo:fo+len(new)]=new
            print("  [ok]   %-7s %-52s %s %s->%s" % (grp, name, where, old.hex(), new.hex())); done+=1
        else:
            raise SystemExit("ABORT %s %s: found %s expected %s" % (name, where, cur.hex(), old.hex()))

    # every selected group is internally atomic
    for g in ("exhd", "execmap", "elfsz"):
        if g not in GROUPS: continue
        n = len([t for t in TEXT if t[0]==g])
        gd = len([t for t in TEXT if t[0]==g and bytes(buf[toff+(t[1]-taddr):toff+(t[1]-taddr)+len(t[3])])==t[3]])
        if gd != n:
            raise SystemExit("ABORT: group %s partially converted (%d/%d) -- it is atomic" % (g, gd, n))

    open(KERNEL,"wb").write(buf)
    print("patch_execboundary groups=%s: %d patched, %d already, %d not-selected "
          "(5 canaries intact) -> %s"
          % (",".join(sorted(GROUPS)), done, skip, off, KERNEL))
    if done + skip != len(sel):
        sys.exit(1)

main()
