#!/usr/bin/env python3
# check_swap_boname.py -- assert that swapfile.bo_name is where the swapconf probe thinks.
#
#   python3 check_swap_boname.py <kernel-elf>
#
# src/swapconf_dbg.s reads the swap pathname as `swapfile+0x10`, and derives the sibling
# (root-slice) node from it, so the whole instrument is wrong -- silently, and in a way that
# looks like a filesystem finding -- if struct bootobj ever moves.  The offset is not taken
# from a header: it is stock swapconf's own, read off its relocations (swapfile+0x10 for the
# path it hands to lookupname, swapfile+0x9c for the &bo_vp it hands back).  This asserts it
# against the image actually being built.

import struct
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: check_swap_boname.py <kernel-elf>")

b = open(sys.argv[1], "rb").read()
if b[:4] != b"\x7fELF":
    raise SystemExit("ABORT: not ELF")

sho = struct.unpack(">I", b[32:36])[0]
esz, num, stx = struct.unpack(">HHH", b[46:52])
sh = [b[sho + i*esz:sho + (i+1)*esz] for i in range(num)]
nameoff, shstr = struct.unpack(">II", sh[stx][16:24])


def sname(s):
    n = struct.unpack(">I", s[0:4])[0]
    return b[nameoff + n:b.index(b"\0", nameoff + n)].decode()


sec = {sname(s): struct.unpack(">III", s[12:24]) for s in sh}
symtab = next(s for s in sh if sname(s) == ".symtab")
sy_off, sy_size, sy_link, _, _, sy_ent = struct.unpack(">IIIIII", symtab[16:40])
str_off = struct.unpack(">I", sh[sy_link][16:20])[0]

swapfile = None
for i in range(sy_size // sy_ent):
    o = sy_off + i * sy_ent
    n = struct.unpack(">I", b[o:o+4])[0]
    if b[str_off + n:b.index(b"\0", str_off + n)] == b"swapfile":
        swapfile = struct.unpack(">I", b[o+4:o+8])[0]
        break
if swapfile is None:
    raise SystemExit("ABORT: no swapfile symbol")

da, do, _ = sec[".data"]
off = do + (swapfile - da) + 0x10
name = b[off:b.index(b"\0", off)].decode("latin1")
if not name.startswith("/dev/dsk/"):
    raise SystemExit("ABORT: swapfile+0x10 reads %r, not a /dev/dsk/ pathname -- "
                     "struct bootobj moved and the probe would read the wrong field" % name)
print("swapfile+0x10 (bo_name) = %r -- the probe's path source is correct" % name)
