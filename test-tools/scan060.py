#!/usr/bin/env python3
"""scan060.py -- find 68060-unimplemented integer instructions in an m68k binary.

Decides from the ENCODING, not from the mnemonic spelling: the 2.8.1-era objdump
in this tree prints the 64-bit forms as "mulsl <ea>,%d0,%d1" (comma), not the
Motorola "Dh:Dl" (colon), so a colon-based grep silently reports "clean".

Vector 61 (unimplemented integer instruction) on the 68060:
  MULU.L/MULS.L <ea>,Dh:Dl   32x32 -> 64   opcode 0x4C00..0x4C3F, ext bit10 = 1
  DIVU.L/DIVS.L <ea>,Dr:Dq   64/32         opcode 0x4C40..0x4C7F, ext bit10 = 1
  MOVEP, CMP2, CHK2, CAS2, misaligned CAS  (mnemonic match is enough)

usage: scan060.py <objdump-listing> [...]
"""
import re
import sys

LINE = re.compile(r"^\s*([0-9a-f]+):\s+((?:[0-9a-f]{4} )+)\s*(\S+)\s*(.*)$")
MNEM_OTHER = re.compile(r"^(movep|cmp2|chk2|cas2)")


def scan(path):
    hits = []
    total = 0
    for raw in open(path, "r", errors="replace"):
        m = LINE.match(raw)
        if not m:
            continue
        total += 1
        addr, hexwords, mnem, ops = m.group(1), m.group(2).split(), m.group(3), m.group(4)
        if MNEM_OTHER.match(mnem):
            hits.append((addr, mnem, ops, "060: %s not implemented" % mnem))
            continue
        if not mnem.startswith(("muls", "mulu", "divs", "divu")):
            continue
        if len(hexwords) < 2:
            continue
        op = int(hexwords[0], 16)
        ext = int(hexwords[1], 16)
        if not (0x4C00 <= op <= 0x4C7F):
            continue
        if not (ext & (1 << 10)):          # size = 0 -> 32-bit form, fine on the 060
            continue
        kind = "64-bit product" if op < 0x4C40 else "64-bit dividend"
        hits.append((addr, mnem, ops, "060 vector 61: %s" % kind))
    return hits, total


for path in sys.argv[1:]:
    hits, total = scan(path)
    print("== %s  (%d decoded lines)" % (path, total))
    if not hits:
        print("   CLEAN -- no 060-unimplemented integer instruction")
    for addr, mnem, ops, why in hits:
        print("   %s  %-8s %-32s %s" % (addr, mnem, ops, why))
    print("   total hits: %d" % len(hits))
