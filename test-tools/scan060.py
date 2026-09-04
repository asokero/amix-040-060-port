#!/usr/bin/env python3
"""scan060.py -- find 68060-unimplemented integer instructions in an m68k binary.

Decides from the ENCODING, not from the mnemonic spelling: the 2.8.1-era objdump
in this tree prints the 64-bit forms as "mulsl <ea>,%d0,%d1" (comma), not the
Motorola "Dh:Dl" (colon), so a colon-based grep silently reports "clean".

Vector 61 (unimplemented integer instruction) on the 68060:
  MULU.L/MULS.L <ea>,Dh:Dl   32x32 -> 64   opcode 0x4C00..0x4C3F, ext bit10 = 1
  DIVU.L/DIVS.L <ea>,Dr:Dq   64/32         opcode 0x4C40..0x4C7F, ext bit10 = 1
  MOVEP, CMP2, CHK2, CAS2, misaligned CAS  (mnemonic match is enough)

WHAT A RESULT PROVES, AND WHAT IT DOES NOT (2026-09-04).  objdump disassembles
linearly, so anything that is not code decodes as code anyway.  That happens
INSIDE .text: a gcc switch dispatch puts its offset table immediately after the
jmp, and those offsets decode as instructions.  In the AMIX Doom binary all 14
MOVEP "hits" were jump-table entries -- a run of increasing 16-bit values, step
0x26, sitting four bytes past a `movew %pc@(...,%dN:l:2),%d0` / `jmp` pair.
A section filter does NOT catch this: the table is in a code section.

So the two verdicts are not symmetric:

  a CLEAN result is strong    -- data decoded as code can only ADD candidates
  a DIRTY result is a LIST    -- each candidate needs its surrounding bytes read

with one limit on the clean side worth stating, because it is easy to promote
"can only add" into "can never hide".  That holds when the misdecoded bytes are
data, which contains no real instruction to lose.  It does not hold in general:
if a decoder loses sync inside real code, a real instruction can be consumed as
another's operand and vanish from the listing.

HOW FAR THAT LIMIT ACTUALLY REACHES, measured 2026-09-04 rather than reasoned.
Both objdumps in this tree -- Debian binutils 2.44 and the 2.8.1-era cross one
-- restart decoding at every symbol boundary.  Fed an opword whose extension
word would cross a label, each stops and emits a .short instead of consuming
the next function's first instruction.  So lost sync is CONTAINED WITHIN ONE
SYMBOL, and cannot hide anything past the next label.

Two consequences, both counter-intuitive:

  * A desync detector built on "the next instruction must start exactly at the
    label address" cannot fire on either objdump, because objdump already
    guarantees it.  Run against the Doom listing -- 800 labels, 43 922
    instruction starts, 14 known-bad lines -- it reports zero.  A check that
    passes on the known-bad case is worse than no check: it manufactures
    confidence.  That is why this file records the property instead of testing
    for it.
  * Per-function disassembly from the symbol table, the obvious thorough fix,
    is a no-op for the same reason.  What remains open is only a table INSIDE a
    function hiding a real instruction before the end of that same function,
    and only following control flow closes it.

--context is therefore the working check, and for the clean verdicts this
project actually leans on there is corroboration outside the tool: libc.so.1
and ld.so.1 scanned clean, and the machine boots, runs a shell, telnet and
Dhrystone on a real 68060 without a vector-61 death, which exercises them far
harder than a disassembler reads them.

Reading a candidate: a `jmp` followed by increasing 16-bit values is a table.
A `movel` of an immediate followed by the multiply is code.  For MOVEP there is
also a prior that needs no bytes at all -- gcc 2.x never emits MOVEP from C, so
a MOVEP in a compiled C binary is a misdecode until proven otherwise.  No such
prior exists for the multiply and divide forms: an ordinary compiler emits them
constantly, so only the surrounding bytes decide.

usage: scan060.py [--context] <objdump-listing> [...]
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


args = sys.argv[1:]
want_context = "--context" in args
paths = [a for a in args if a != "--context"]

for path in paths:
    hits, total = scan(path)
    lines = open(path, "r", errors="replace").read().splitlines() if want_context else []
    print("== %s  (%d decoded lines)" % (path, total))
    if not hits:
        print("   CLEAN -- no candidate found.  Data decoding as code can only add")
        print("   candidates, so a clean listing is the strong verdict; see the note")
        print("   in this file on the one way a real instruction can still hide.")
    for addr, mnem, ops, why in hits:
        print("   %s  %-8s %-32s %s" % (addr, mnem, ops, why))
        if want_context:
            for i, raw in enumerate(lines):
                if raw.lstrip().startswith(addr + ":"):
                    for ctx in lines[max(0, i - 3):i + 4]:
                        print("        | %s" % ctx.rstrip())
                    break
            print()
    if hits:
        print("   total candidates: %d -- each needs its surrounding bytes read"
              " before it counts as an instruction" % len(hits))
