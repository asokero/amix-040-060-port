#!/usr/bin/env python3
# patch_ttcompat_init.py -- ISSUE-77 (the driver line's DRIVER-LINE-7): stock ttcompatopen() leaves
# most of its per-stream state uninitialised, so a console stream can panic the kernel with
# "ttcompat: unexpected ioctl acknowledgment" at boot (2026-10-05).
#
#   patch_ttcompat_init.py KERNEL           write the fix; idempotent ([skip] when already done)
#   patch_ttcompat_init.py --check KERNEL   say which bytes KERNEL carries; write nothing
#
# THE DEFECT.  ttcompatopen allocb()s its 0x44-byte per-stream state and points q_ptr at b_rptr.
# It clears bytes 4..31 and nothing else, so 32..0x43 keep whatever the reused STREAMS buffer last
# held -- among them t_state (+56), t_iocid (+60) and t_ioccmd (+64).  ttcompat_ioctl_ack takes an
# M_IOCACK as its own when bit 3 (TS_IOCWAIT) of t_state is set and ioc_id equals t_iocid, and then
# switches on t_ioccmd; a command it never sent reaches the switch's default, which panics.  The 3B2
# SVR4 ttcompatopen has the same shape; the later i386 SVR4 and SVR4.2 versions bzero the whole
# structure after the allocb (KNOWN-ISSUES.md, ISSUE-77).
#
# THE FIX, AND THE CHOICE IN IT.  Same length, no relocation, no layout change.  The 16 single-byte
# clears of bytes 12..27 (`clrb %a0@(n)`, 64 bytes of code at ttcompatopen+0x80) become thirteen
# longword clears and six nops.  With the stock `clrl` at 4, 8 and 28 around the span, all of
# 4..0x43 is then zero at open: the USL bzero's effect over every byte the stock open does not set
# itself.  %a0 holds the state there (b_rptr of the new block).
#   The driver line's 1.0 kernels carry a narrower form: the same span cleared 12..27 and then only
# +56, +60 and +64, the three fields the ack path is known to trust.  The wide form is the one
# chosen here (2026-10-17, on the suggestion in the reply that recorded ISSUE-77): offsets 32..55
# also kept leftovers, and nothing known reads them before writing them, but a full clear removes
# the question instead of answering it field by field.  This tool recognises the narrow bytes,
# reports them, and rewrites them to the wide form.
#
# The site is found by symbol (the local `ttcompatopen`, exactly one), so the same tool serves the
# 68040/060 bases (.text 0x36f7c) and a 68030 ET_REL; it asserts the stock code around the span and
# that no relocation covers it before writing.

import os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kelf import Elf  # noqa: E402

OFF = 0x80                                   # from ttcompatopen
CLRB, CLRL, NOP = 0x4228, 0x42a8, b"\x4e\x71"
WIDE_OFFS = tuple(n for n in range(0x0c, 0x44, 4) if n != 0x1c)   # 0x1c is the stock clrl behind
STOCK = b"".join(struct.pack(">HH", CLRB, n) for n in range(0x0c, 0x1c))      # clrb %a0@(12..27)
FIXED = b"".join(struct.pack(">HH", CLRL, n) for n in WIDE_OFFS) + NOP * 6     # clrl ...; nops
NARROW = b"".join(struct.pack(">HH", CLRL, n) for n in (0x0c, 0x10, 0x14, 0x18, 0x38, 0x3c, 0x40)) \
    + NOP * 18                                                                   # driver line 1.0
assert len(WIDE_OFFS) == 13 and len(STOCK) == len(FIXED) == len(NARROW) == 64
BEFORE = bytes.fromhex("42a8000442a80008")   # clrl %a0@(4); clrl %a0@(8) -- the stock lines in front
AFTER = bytes.fromhex("42a8001c")            # clrl %a0@(28)                 -- and behind
STATE = {STOCK: "stock: 32..0x43 left uninitialised",
         NARROW: "narrow fix: only +56/+60/+64 cleared beyond 4..31",
         FIXED: "4..0x43 cleared at open (fixed)"}


def locate(e):
    tidx = e.names.index(".text")
    hits = [e.sym(i) for i in range(e.syn)
            if e.sym(i)["name"] == "ttcompatopen" and e.sym(i)["shndx"] == tidx]
    if len(hits) != 1:
        raise SystemExit("ABORT: want exactly one ttcompatopen in .text, found %d" % len(hits))
    site = hits[0]["value"] + OFF
    if e.text(site - 8, 8) != BEFORE or e.text(site + 64, 4) != AFTER:
        raise SystemExit("ABORT: the code around ttcompatopen+0x%x is not the stock clear sequence" % OFF)
    rt = e.rela(".rela.text") if ".rela.text" in e.sec else {}    # an object without relocations has none
    for off in rt:
        if site <= off < site + 64:
            raise SystemExit("ABORT: a relocation at .text 0x%x lies in the span" % off)
    cur = e.text(site, 64)
    if cur not in STATE:
        raise SystemExit("ABORT: ttcompatopen+0x%x holds neither the stock nor a fixed form" % OFF)
    return site, cur


def main():
    a = sys.argv[1:]
    check = len(a) == 2 and a[0] == "--check"
    if not (len(a) == 1 or check):
        raise SystemExit("usage: patch_ttcompat_init.py [--check] KERNEL")
    path = a[-1]
    e = Elf(path)
    site, cur = locate(e)
    if check:
        print("  %s ttcompatopen .text 0x%x: %s" % ("[ok]  " if cur == FIXED else "[old] ", site, STATE[cur]))
        sys.exit(0 if cur == FIXED else 1)
    if cur == FIXED:
        print("  [skip] ttcompatopen .text 0x%x already clears 4..0x43" % site)
        return
    t = e.sec[".text"]["offset"] + site
    e.b[t:t + 64] = FIXED
    open(path, "wb").write(e.b)
    if locate(Elf(path))[1] != FIXED:
        raise SystemExit("ABORT: the write did not take")
    print("  [ok]   ttcompatopen .text 0x%x: clears 4..0x43 at open (was %s)" % (
        site, "the narrow fix" if cur == NARROW else "stock"))


main()
