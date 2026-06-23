#!/usr/bin/env python3
# patch_pmmu_040.py -- HAT-port "stub & map" step.
# Byte-patch the kernel's 68030 PMMU instructions (illegal on the 68040) with
# minimal legal stubs so the kernel advances past each one, letting us map the
# WHOLE chain of HAT blockers (each surfaces as a clean kernel panic) before
# doing the proper 040 ports.  Operates on build/unix-040 in place; re-run after
# each relink (after patch_pflusha_040.py).  Each site is byte-verified first.
#
# STUBBED SO FAR:
#   ptest  (0x3a8): 030 `ptestr (a0),7` + `pmove psr,sp@(4)` -> return PSR=0x400
#                   (030 "invalid" bit) so callers treat the fault as page-not-
#                   present.  Crude but advances the map.
#   ptest0 (0x3c0): same instrs, but ptest0 returns 0 anyway -> just NOP them out.
#
# (pflusha is handled by patch_pflusha_040.py; pmove %crp etc. come next.)

import struct, sys
KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"

def u16(b,o): return struct.unpack(">H", b[o:o+2])[0]
def u32(b,o): return struct.unpack(">I", b[o:o+4])[0]
def text_sec(b):
    sh=u32(b,32); ent=u16(b,46); n=u16(b,48); st=u16(b,50)
    so=u32(b, sh+st*ent+16)
    for i in range(n):
        o=sh+i*ent; nm=u32(b,o)
        e=b.index(b"\0", so+nm)
        if b[so+nm:e]==b".text": return u32(b,o+12), u32(b,o+16)
    raise SystemExit("no .text")

# (vaddr, expect_bytes, new_bytes, name)
NOP=b"\x4e\x71"
PATCHES = [
    # ptest: ptestr (f010 9e11) + pmove psr,sp@(4) (f02f 6200 0004) = 10 bytes
    #   -> movew #0x0400,%sp@(4) (3f7c 0400 0004) + nop + nop
    (0x3ac, b"\xf0\x10\x9e\x11\xf0\x2f\x62\x00\x00\x04",
            b"\x3f\x7c\x04\x00\x00\x04"+NOP+NOP, "ptest"),
    # ptest0: ptestr (f010 8211) + pmove psr,sp@(4) = 10 bytes -> 5x nop
    (0x3c4, b"\xf0\x10\x82\x11\xf0\x2f\x62\x00\x00\x04",
            NOP*5, "ptest0"),
    # nomsg (0x18ece) -- halt/reboot path: pmove %a0@,%tc / %crp / %srp disable the 030
    # MMU before the hardware reset (bset #7,0xde0002).  On 040 these are F-line -> a
    # recursive Line-F trap loop after any PANIC.  NOP them: the MMU stays on, but the
    # reset register 0xde0002 is identity-covered by DTT0 regardless of paging, so the
    # reset still fires -> clean reboot/halt instead of an infinite trap loop.
    (0x18ed8, b"\xf0\x10\x40\x00", NOP+NOP, "nomsg:pmove tc"),
    (0x18ee2, b"\xf0\x10\x4c\x00", NOP+NOP, "nomsg:pmove crp"),
    (0x18ee6, b"\xf0\x10\x48\x00", NOP+NOP, "nomsg:pmove srp"),
    # swtch (0xb923c) -- the CONTEXT-SWITCH per-proc root load.  swtch computes
    # d0 = svirtophys(newproc->p_as->hat_root) (the per-proc 040 root phys, built by
    # the ported hat_alloc in hat040.s), stashes it to userroot+4, then loads it with
    # the 030 `pmove %a1@,%crp` (a1=&userroot).  On 040 that is an F-line; replace it
    # with `movec %d0,%urp` (4e7b 0806) -- d0 still holds the phys root at this point
    # (the userroot store left it intact), and 040 user-mode accesses use URP while the
    # kernel keeps SRP=kroot040.  The following pflusha (0xb9240) is already converted
    # to the 040 form by patch_pflusha_040.py.  NOT a NOP: a real 030->040 instr swap.
    (0xb923c, b"\xf0\x11\x4c\x00", b"\x4e\x7b\x08\x06", "swtch:pmove crp -> movec d0,urp"),
    # hat_map (0xb58c6) -- the child-fork address-space root load, reached for the FIRST time
    # now that the 040 context switch works and proc 1 actually runs its procdup/hat path.
    # hat_map computes a0 = svirtophys(as->root) (the new proc's 040 root phys), stores it to
    # userroot+4, then loads it with the 030 `pmove %a1@,%crp` (a1=&userroot) -> F-line on 040.
    # Here d0 does NOT hold the phys (it was reloaded with fp-152), but a0 DOES, so replace with
    # `movec %a0,%urp` (4e7b 8806) -- 040 user-mode root.  The following pflusha (0xb58ca) is
    # already converted by patch_pflusha_040.py.  Same real 030->040 swap as the swtch site.
    (0xb58c6, b"\xf0\x11\x4c\x00", b"\x4e\x7b\x88\x06", "hat_map:pmove crp -> movec a0,urp"),
]

def main():
    buf=bytearray(open(KERNEL,"rb").read())
    sa, so = text_sec(buf)
    done=skip=0
    for vaddr, old, new, name in PATCHES:
        assert len(old)==len(new), name
        fo = so + (vaddr - sa)
        cur = bytes(buf[fo:fo+len(old)])
        if cur==new:
            print("  [skip] %-8s @0x%05x already stubbed" % (name,vaddr)); skip+=1
        elif cur==old:
            buf[fo:fo+len(new)]=new
            print("  [stub] %-8s @0x%05x  %s -> %s" % (name,vaddr,old.hex(),new.hex())); done+=1
        else:
            raise SystemExit("ABORT %s @0x%05x: found %s" % (name,vaddr,cur.hex()))
    open(KERNEL,"wb").write(buf)
    print("done: %d stubbed, %d already -> %s" % (done,skip,KERNEL))

main()
