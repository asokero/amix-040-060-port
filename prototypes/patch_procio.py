#!/usr/bin/env python3
# patch_procio.py -- ISSUE-17/18: /proc process-memory I/O geometry, Model B
# (4KB page frame) conversion for the two procfs routines whose defects are
# PURE numeric constants (mask/shift/step), as opposed to prfastmapin whose
# entire walk structure is wrong on the 040 and is therefore replaced wholesale
# by prfastmap040.s (--weaken-symbol), not byte-patched.
#
# WHY prfastmapout and prusrio ARE byte-patched here but prfastmapin is NOT:
#
# prfastmapin (0x63484) is "a modified version of vtop()" (3b2 prmachdep.c:271)
# that walks the 030 SEGMENT tree via p->p_as->a_hat.hat_srama[sid-SCN2] =
# *(as+20) -> an array of 8-byte 030 SDEs.  On the 040 port, hat_alloc
# (hat040.s:1211) stores the **040 root table VA** at as@(20) instead -- 128
# four-byte pointer descriptors, a completely different structure.  No amount
# of shift/mask tweaking fixes a walk that dereferences the wrong data shape;
# the whole routine has to be replaced (prfastmap040.s does that, and adds the
# shared uvatopte040 walker vtop040.s also calls).  See prfastmap040.s's own
# header comment for the full derivation.
#
# prfastmapout (0x63592), by contrast, walks the ALREADY-CORRECT page_t array
# (pages/pages_base/pages_end -- the same 040-native structures every other
# Model B site in this tree uses) and its ONLY defect is that it still shifts
# the fast-map physical address by the STOCK 030 PNUMSHFT (11, i.e. >>11 to
# get a PFN on a 2KB page) instead of the Model B shift (12, 4KB page).  That
# is a pure constant swap -- the surrounding control flow, wakeprocs/page_abort
# calls, and byte offsets into page_t are all untouched and correct.  Hence a
# byte patch, not a rewrite.
#
# prusrio (0x644ac) is the /proc PIOCSRW-family page-loop driver: for each
# page in the request it calls prfastmapin (fast path, now correctly 040-aware
# via the .s override) or falls back to as_fault(F_SOFTLOCK)+prmapin / prmapout
# +as_fault(F_SOFTUNLOCK) per page, stepping by PAGESIZE.  Every one of its
# defects is likewise a stock-030 constant (PAGEMASK, PAGESIZE, as_fault byte
# length) baked in as an immediate; the loop shape itself is fine.  Hence byte
# patches here too.
#
# prusrio MUST be converted as ONE COMPLETE SET (mask + step + BOTH as_fault
# lengths), not a subset. patch_modelb.py:583-591 documents exactly this
# hazard from 2026-07-03: an earlier session flipped only the two as_fault
# pea-length immediates (0x645d8/0x6467a, F_SOFTLOCK/F_SOFTUNLOCK) while
# leaving the page/nextpage mask+step (0x64580 andiw #-2048, 0x64586 addil
# #2048) at their stock 2KB values.  Locking 4KB (the new length) while
# stepping the loop by 2KB (the still-stock step) makes two successive
# iterations' softlock regions overlap -- a page gets F_SOFTLOCK'd twice
# before its matching F_SOFTUNLOCK, imbalancing p_lck and hanging the system.
# That partial conversion was deliberately withdrawn at the time. This patch
# includes all four sites below in a single atomic group specifically to
# avoid repeating that bug.
#
# Each site asserts its expected OLD bytes before writing (fail-closed: any
# mismatch aborts the whole run rather than guessing an address).  Operates in
# place on build/unix-040.  Old bytes below were verified by disassembling the
# build/unix-040 rebuilt for ISSUE-15 (2026-07-25) with m68k-linux-gnu-objdump
# immediately before writing this script -- the addresses are stock-text and
# have not moved across the ISSUE-15 rebuild.

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

# .text sites: (vaddr, expect, new, name)
TEXT = [
 # prfastmapout @0x63592 -- 11x phys>>PNUMSHFT: moveq #11,d1 -> moveq #12,d1
 # (each site is immediately followed by lsrl %d1,%dX -- verified by objdump)
 (0x635a0, b"\x72\x0b", b"\x72\x0c",
  "prfastmapout:phys>>11 -> >>12 (site 1/11)"),
 (0x635c0, b"\x72\x0b", b"\x72\x0c",
  "prfastmapout:phys>>11 -> >>12 (site 2/11)"),
 (0x635e2, b"\x72\x0b", b"\x72\x0c",
  "prfastmapout:phys>>11 -> >>12 (site 3/11)"),
 (0x63694, b"\x72\x0b", b"\x72\x0c",
  "prfastmapout:phys>>11 -> >>12 (site 4/11)"),
 (0x636b4, b"\x72\x0b", b"\x72\x0c",
  "prfastmapout:phys>>11 -> >>12 (site 5/11)"),
 (0x636d6, b"\x72\x0b", b"\x72\x0c",
  "prfastmapout:phys>>11 -> >>12 (site 6/11)"),
 (0x636f6, b"\x72\x0b", b"\x72\x0c",
  "prfastmapout:phys>>11 -> >>12 (site 7/11)"),
 (0x63718, b"\x72\x0b", b"\x72\x0c",
  "prfastmapout:phys>>11 -> >>12 (site 8/11)"),
 (0x63738, b"\x72\x0b", b"\x72\x0c",
  "prfastmapout:phys>>11 -> >>12 (site 9/11)"),
 (0x6375a, b"\x72\x0b", b"\x72\x0c",
  "prfastmapout:phys>>11 -> >>12 (site 10/11)"),
 (0x6377a, b"\x72\x0b", b"\x72\x0c",
  "prfastmapout:phys>>11 -> >>12 (site 11/11)"),

 # prusrio @0x644ac -- page-loop mask/step + as_fault lengths (atomic group,
 # see docstring above re the 2026-07-03 partial-conversion boot jam)
 (0x64580, b"\x02\x45\xf8\x00", b"\x02\x45\xf0\x00",
  "prusrio:andiw #-2048,d5 (page = a & PAGEMASK)"),
 (0x64586, b"\x06\x81\x00\x00\x08\x00", b"\x06\x81\x00\x00\x10\x00",
  "prusrio:addil #2048,d1 (nextpage = page + PAGESIZE)"),
 (0x645d8, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00",
  "prusrio:pea 0x800 (as_fault F_SOFTLOCK len)"),
 (0x6467a, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00",
  "prusrio:pea 0x800 (as_fault F_SOFTUNLOCK len)"),
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

    if done and done != len(TEXT) and skip == 0:
        raise SystemExit("ABORT: partial procfs I/O patch (%d/%d) -- group is atomic" % (done, len(TEXT)))

    open(KERNEL,"wb").write(buf)
    print("patch_procio: %d patched, %d already, 0 failed" % (done, skip))
    if done + skip != len(TEXT):
        sys.exit(1)

main()
