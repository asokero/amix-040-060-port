#!/usr/bin/env python3
# patch_xpage_flip.py -- turn the ISSUE-37/xpage handling OFF in a finished kernel image, to make
# an A/B control that differs from the shipping image in ONE BYTE.
#
# WHY THIS EXISTS.  The ISSUE-22 reproducer (b2repro-copy, 16 bursts) ran CLEAN on 68040-260728-18,
# where the same workload on 68040-260723-07/-10 failed inside the first two bursts -- twice, on two
# kernels, both dbg builds, so the comparison is like-for-like.  But those images are five weeks of
# other fixes apart, so a clean run does not attribute the improvement to the xpage fix by itself.
# Flipping xpage_on in an otherwise identical image does.  This is the same discipline that made
# ISSUE-36's closure defensible (its A/B pair differed in five bytes).
#
# Locates xpage_on through the symbol table, never a hardcoded offset; asserts the old value; fails
# closed.  Re-stamp the flipped copy (prototypes/stamp_buildid.py) so `uname -m` tells them apart --
# two kernels with the same id in one session is its own bug.
#
# usage: python3 prototypes/patch_xpage_flip.py <kernel>      (writes in place: 1 -> 0)

import sys, os, struct, subprocess

if len(sys.argv) != 2:
    raise SystemExit("usage: %s <kernel-elf>" % sys.argv[0])
K = sys.argv[1]

nm = subprocess.run(["m68k-linux-gnu-nm", K], capture_output=True, text=True).stdout
addr = None
for l in nm.splitlines():
    p = l.split()
    if len(p) == 3 and p[2] == "xpage_on" and p[1] in "dD":
        addr = int(p[0], 16)
if addr is None:
    raise SystemExit("ABORT: xpage_on not found as a .data symbol in %s\n"
                     "       (a kernel built before the flag exists cannot be used as this A/B)" % K)

h = subprocess.run(["m68k-linux-gnu-objdump", "-h", K], capture_output=True, text=True).stdout
doff = None
for l in h.splitlines():
    p = l.split()
    if len(p) > 5 and p[1] == ".data":
        doff = int(p[5], 16)
if doff is None:
    raise SystemExit("ABORT: no .data section header in %s" % K)

off = doff + addr
d = bytearray(open(K, "rb").read())
cur = struct.unpack(">I", bytes(d[off:off + 4]))[0]
if cur == 0:
    print("patch_xpage_flip: already 0 (xpage handling OFF) -- %s" % K)
    raise SystemExit(0)
if cur != 1:
    raise SystemExit("ABORT: xpage_on is %d, expected 1 -- refusing to guess" % cur)
d[off:off + 4] = struct.pack(">I", 0)
open(K, "wb").write(d)
print("patch_xpage_flip: xpage_on 1 -> 0 at .data+0x%x (file 0x%x) -> %s" % (addr, off, K))
print("                  this image now has the ISSUE-37 loop back ON PURPOSE; re-stamp its buildid")
