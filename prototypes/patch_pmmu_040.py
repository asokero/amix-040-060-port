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
