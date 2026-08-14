#!/usr/bin/env python3
# patch_pageoutdefs.py -- Model B (4KB page frame) pageout-policy defaults
# conversion group (2026-07-19).
#
# Authoritative spec: docs/contracts/SETUPCLOCK-VMETER-PATCH-SPEC.md.
#
# The pageout thresholds lotsfree/desfree/minfree have ZERO .data initializers;
# setupclock installs the compiled defaults on every normal boot.  Those
# defaults are byte policies expressed in old 2KB pages, so under Model B the
# system pages out at TWICE the intended byte thresholds -- live-observed as
# burst-thrash with freemem frozen at 129 = lotsfree+1 (emu burst-3 wchan
# triage, test-tools/issue10-swapin-fix-260719.txt).  Preserving the documented
# BYTE thresholds under 4KB pages:
#   lotsfree  256KB: 128 -> 64 pages     desfree  100KB: 50 -> 25 pages
#   minfree    32KB:  16 ->  8 pages
# The subsequent memory-fraction caps (freemem-derived divides) and the
# desfree/2 cap are page-relative and structurally correct as-is.
#
# setupclock's final `fastscan * PAGESIZE` minimum still converted bytes with
# <<11; one moveq #11 at 0x51f6a feeds the single asll.  (The handspread ptob
# at 0x51eee was already converted by patch_writeback.py group `pageoutd`.)
# fastscan=200 itself is a page RATE (policy review) and is NOT changed here.
#
# vmmeter (os/vm_meter.c):
#   deficit -= MIN(deficit, MAX(deficit/10, UsefulPagesPerIO * maxpgio / 2));
#   #define UsefulPagesPerIO nz((MAXBSIZE/PAGESIZE)/2)
# MAXBSIZE=8192: old (8192/2048)/2 = 2, Model B (8192/4096)/2 = 1.  The
# compiler folded UPIO=2 as `asll #1` before the rounded `asrl #1`, making the
# expression effectively plain maxpgio.  MIN/MAX expansion evaluates it FOUR
# times; each `asll #1,%d0` (e380) becomes `nop` (4e71) -> maxpgio/2.  The
# preceding movel sets the CCR the following bpl tests, and nop preserves CCR,
# so the signed-division rounding semantics are unchanged.  maxpgio itself
# stays 40 I/O operations/s (correct initializer).
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

# .text sites: (vaddr, expect, new, name)
TEXT = [
 # setupclock boot defaults (byte thresholds -> Model B pages)
 (0x51dcc, b"\x23\xfc\x00\x00\x00\x80", b"\x23\xfc\x00\x00\x00\x40",
  "setupclock:movel #128 lotsfree (256KB default)"),
 (0x51e24, b"\x74\x32", b"\x74\x19",
  "setupclock:moveq #50 desfree (100KB default)"),
 (0x51e7e, b"\x74\x10", b"\x74\x08",
  "setupclock:moveq #16 minfree (32KB default)"),
 (0x51f6a, b"\x74\x0b", b"\x74\x0c",
  "setupclock:moveq #11 (fastscan * PAGESIZE minimum)"),
 # vmmeter UsefulPagesPerIO fold 2 -> 1 (4 MIN/MAX-expanded evaluations)
 (0x51aba, b"\xe3\x80", b"\x4e\x71",
  "vmmeter:asll #1 maxpgio -> nop (UPIO fold, eval 1)"),
 (0x51ad0, b"\xe3\x80", b"\x4e\x71",
  "vmmeter:asll #1 maxpgio -> nop (UPIO fold, eval 2)"),
 (0x51b10, b"\xe3\x80", b"\x4e\x71",
  "vmmeter:asll #1 maxpgio -> nop (UPIO fold, eval 3)"),
 (0x51b26, b"\xe3\x80", b"\x4e\x71",
  "vmmeter:asll #1 maxpgio -> nop (UPIO fold, eval 4)"),
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

    open(KERNEL,"wb").write(buf)
    print("Model B pageout-defaults group: %d patched, %d already -> %s" % (done, skip, KERNEL))

main()
