#!/usr/bin/env python3
# patch_pflusha_040.py -- HAT-port PROBE step 1.
# Replace every 68030 `pflusha` (f000 2400, 4 bytes) in the kernel's live code
# with the 68040 `pflusha` (f518) + `nop` (4e71) -- same size, in-place.  The
# 030 encoding is ILLEGAL on a 68040; this makes the TLB-flushes legal so the
# kernel can advance past them (the hang should move on to the still-030
# `pmove %crp` sites, confirming the HAT-layer diagnosis).
#
# Operates on the RELINKED kernel (build/unix-040, which already has pstart040),
# in place.  Re-run after each relink.  Idempotent (skips already-patched sites).
# Run from the repo root: python3 prototypes/patch_pflusha_040.py
#
# Site list = the live pflusha instructions from hat-040-port-worklist.md
# (excludes the dead pstart_030).  Each is verified to be f000 2400 before
# patching; a mismatch aborts (so a rebuilt kernel with shifted offsets is
# caught rather than silently corrupted).

import struct, sys

KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"

# (vaddr offset, function) -- pflusha sites in the live kernel code.
SITES = [
    (0x00038, "_start"),
    (0x000b2, "resume"),
    (0x58ca + 0xb0000, "hat_map"),    # 0xb58ca
    (0x70ee + 0xb0000, "hat_exec"),   # 0xb70ee
    (0x7476 + 0xb0000, "hat_asload"), # 0xb7476
    (0x78d0 + 0xb0000, "flushmmu"),   # 0xb78d0
    (0x9240 + 0xb0000, "swtch"),      # 0xb9240
]

OLD = b"\xf0\x00\x24\x00"   # 030 pflusha
NEW = b"\xf5\x18\x4e\x71"   # 040 pflusha (f518) + nop (4e71)

def u16(b, o): return struct.unpack(">H", b[o:o+2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o+4])[0]

def text_section(buf):
    e_shoff = u32(buf, 32); e_shentsize = u16(buf, 46)
    e_shnum = u16(buf, 48); e_shstrndx = u16(buf, 50)
    shstr_off = u32(buf, e_shoff + e_shstrndx*e_shentsize + 16)
    for i in range(e_shnum):
        b = e_shoff + i*e_shentsize
        name_off = u32(buf, b)
        end = buf.index(b"\0", shstr_off + name_off)
        name = buf[shstr_off + name_off:end].decode("latin1")
        if name == ".text":
            return u32(buf, b+12), u32(buf, b+16)   # sh_addr, sh_offset
    raise SystemExit("no .text section")

def main():
    with open(KERNEL, "rb") as f:
        buf = bytearray(f.read())
    sh_addr, sh_off = text_section(buf)
    patched = skipped = 0
    for vaddr, fn in SITES:
        fo = sh_off + (vaddr - sh_addr)
        cur = bytes(buf[fo:fo+4])
        if cur == NEW:
            print("  [skip] %-11s @0x%05x already 040 pflusha" % (fn, vaddr))
            skipped += 1
        elif cur == OLD:
            buf[fo:fo+4] = NEW
            print("  [patch] %-11s @0x%05x  f000 2400 -> f518 4e71" % (fn, vaddr))
            patched += 1
        else:
            raise SystemExit("ABORT: %s @0x%05x (file 0x%x) is %s, not a pflusha"
                             % (fn, vaddr, fo, cur.hex()))
    with open(KERNEL, "wb") as f:
        f.write(buf)
    print("done: %d patched, %d already-patched -> %s" % (patched, skipped, KERNEL))

main()
