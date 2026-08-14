#!/usr/bin/env python3
# patch_devmmap2.py -- ISSUE-33: the remaining device-mmap page-geometry crossings.
#
# Follows docs/contracts/PRODUCER-CONSUMER-ASYMMETRY-CENSUS.md "P2: device mmap and PFN
# boundary", narrowed to the two crossings that are actually reachable and harmful.
# Source contract: svr4-src-3b2/usr/src/uts/3b2/vm/seg_dev.c.
#
# GROUP A -- d_mmap PFN producers (3 sites).  LIVE WRONG-PHYSICAL-ADDRESS BUG.
#   A device's d_mmap entry point must return a PAGE FRAME NUMBER, and the 040-native
#   consumer hat_devload (0xb4cec) maps it as `pfn << 12`.  mmmmap (/dev/mem) and
#   resmmap still compute `phys >> 11`, i.e. a 2 KiB PFN, which is TWICE the correct
#   value -- hat_devload then maps 2x the intended physical address.
#   This is the identical defect patch_devmmap_pfn.py already fixed for scrmmap/ammmap/
#   timmap (the fractal/julia black-screen fix); those three are asserted as canaries
#   below so this patch cannot run against an image where they regressed.
#
# GROUP B -- segdev_incore vector stride (4 sites).  LIVE USER-BUFFER OVERRUN.
#   The public mincore(2) path was converted to 4 KiB by patch_mincore.py (0x585e2,
#   0x58670, 0x58678), so the caller sizes its vector at btopr_4k(len) bytes.  But
#   segdev_incore writes one byte per 2 KiB:
#       roundup(len,2048) ; loop { *vec++ = 1 ; len -= 2048 ; acc += 2048 }
#   so mincore() over a DEVICE mapping writes TWICE as many bytes as the caller
#   allocated.  Producer/consumer split, same class as ISSUE-27/28/31/32.
#
# DELIBERATELY NOT CONVERTED, and asserted UNCHANGED:
#   The rest of the segdev family (segdev_fault/dup/unmap/free/setprot/checkprot/
#   getprot, and spec_segmap's 0x6766a loop step) keeps its 2 KiB geometry.  It is
#   INTERNALLY CONSISTENT -- the vpage array is sized and indexed with the same
#   seg_page() shift throughout -- and its two external crossings are benign:
#     * hat_devload: a 2 KiB fault-loop step calls hat_devload twice per 4 KiB page,
#       and because d_mmap now returns a 4 KiB PFN both calls carry the SAME pfn and
#       hat_devload rounds the address down to the page.  The duplicate load is
#       idempotent -- wasteful, not wrong.  (This is why the already-landed
#       scrmmap/ammmap/timmap fix worked with an unconverted segdev.)
#     * segdev_getprot's vector fill is only exercised for len > 0, and its only
#       caller as_getprot (0xaecfc, vm_as.c:945) passes len = 0 and the address of a
#       single int, so no vector is ever over-filled through that path.
#   Converting the family would mean moving the vpage array size and every seg_page()
#   index together; there is no demonstrated defect to justify that risk today.
#   spec_segmap 0x67694 `moveq #12` is `return ENOMEM`, NOT a 4 KiB conversion -- the
#   fourth errno false positive this campaign has produced.
#
# Old bytes verified against build 68040-260725-15.

import struct, sys, os
KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"
GROUPS = set((os.environ.get("DEVMMAP2_GROUPS") or "pfn,incore").split(","))

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

TEXT = [
 ("pfn",    0x20688, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff",
  "mmmmap:btop(vtop(off)) round -- /dev/mem PFN"),
 ("pfn",    0x2068e, b"\x72\x0b", b"\x72\x0c",
  "mmmmap:btop shift -- /dev/mem PFN"),
 ("pfn",    0xd7186, b"\x72\x0b", b"\x72\x0c",
  "resmmap:btop(boards[minor]+off) shift"),

 ("incore", 0xa838a, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff",
  "segdev_incore:roundup(len, PAGESIZE)"),
 ("incore", 0xa8390, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00",
  "segdev_incore:roundup mask"),
 ("incore", 0xa839e, b"\x06\x80\xff\xff\xf8\x00", b"\x06\x80\xff\xff\xf0\x00",
  "segdev_incore:len -= PAGESIZE per vector byte"),
 ("incore", 0xa83a4, b"\x06\x81\x00\x00\x08\x00", b"\x06\x81\x00\x00\x10\x00",
  "segdev_incore:covered += PAGESIZE per vector byte"),
]

# already-4 KiB d_mmap producers: if any of these regressed, the PFN contract is broken
# and this patch must not run.
CANARY_NEW = [
 (0x08384, b"\x78\x0c\xe8\xa8", "scrmmap PFN shift (patch_devmmap_pfn.py)"),
 (0x0e0d2, b"\x72\x0c\xe2\xa8", "ammmap PFN shift (patch_devmmap_pfn.py)"),
 (0x13cac, b"\x74\x0c\xe4\xa8", "timmap PFN shift (patch_devmmap_pfn.py)"),
 (0x58678, b"\x72\x0c",         "public mincore page shift (patch_mincore.py)"),
]
# deliberately-retained 2 KiB segdev geometry: assert it is still old, so that a future
# partial conversion of the family cannot silently desynchronise the vpage array.
CANARY_OLD = [
 (0xa7fe4, b"\x7e\x0b", "segdev_fault seg_page() -- family kept at 2 KiB on purpose"),
 (0xa82a6, b"\x76\x0b", "segdev_getprot seg_page() -- family kept at 2 KiB on purpose"),
 (0x6766a, b"\xd4\xfc\x08\x00", "spec_segmap loop step -- family kept at 2 KiB on purpose"),
]

def main():
    buf=bytearray(open(KERNEL,"rb").read())
    secs=sections(bytes(buf))
    tidx, taddr, toff = secs[".text"]

    for vaddr, want, what in CANARY_NEW + CANARY_OLD:
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
            print("  [skip] %-7s %-50s %s already" % (grp, name, where)); skip+=1
        elif cur==old:
            buf[fo:fo+len(new)]=new
            print("  [ok]   %-7s %-50s %s %s->%s" % (grp, name, where, old.hex(), new.hex())); done+=1
        else:
            raise SystemExit("ABORT %s %s: found %s expected %s" % (name, where, cur.hex(), old.hex()))

    open(KERNEL,"wb").write(buf)
    print("patch_devmmap2 groups=%s: %d patched, %d already, %d not-selected "
          "(4 converted + 3 retained canaries intact) -> %s"
          % (",".join(sorted(GROUPS)), done, skip, off, KERNEL))
    if done + skip != len(sel):
        sys.exit(1)

main()
