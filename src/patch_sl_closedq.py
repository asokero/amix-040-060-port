#!/usr/bin/env python3
# patch_sl_closedq.py -- ISSUE-75: the built-in serial driver's callouts must not
# touch a stream that has been closed (2026-10-03).
#
# Stock sl.c: TCSBRK always runs slproc(T_BREAK), which arms
# timeout(sl_ttrstrt, tp, HZ/4) and drops the id; slclose sets t_rdqp to NULL and
# never cancels it.  The callout then runs sl_ttrstrt -> slproc(T_TIME) ->
# getoblk(tp), and getoblk forms WR(t_rdqp) = 0 + sizeof(queue_t) = 0x40 with no
# test.  getq(0x40) walks Kickstart's leftover vector table in chip RAM; on solon
# it faults at getq+0x4c with va 0x614E6167.  M_DELAY's callout `delay` reaches
# getoblk the same way after a close.
#
# sl_ttrstrt itself has no room (32 bytes, two fixed relocations), and neither has
# getoblk's prologue.  The guard goes one level up, at the two places that call
# getoblk from a callout, both of which have a spl pair around a single
# `andiw #-2,t_state` (clear TIMEOUT).  A read-modify-write of memory is one
# instruction and cannot be split by an interrupt on any 68k, so the spl pair adds
# nothing, and its bytes pay for the test:
#
#   slproc, case T_TIME @0x12390 (36 bytes, a3 = tp):
#     andiw #-2,%a3@(56)          clear TIMEOUT, as before
#     tstl  %a3@(24)              t_rdqp
#     beqw  0x1243c               closed: to slproc's own epilogue
#     movew #0x8001,0xdff09c      irequest(AIESTBE), as before
#     movew #0x8001,0xdff09a
#     braw  0x12434               getoblk(tp), as before
#     nop
#
#   delay @0x11fb6 (16 bytes, a0 = tp):
#     andiw #-2,%a0@(56)          clear TIMEOUT, as before
#     tstl  %a0@(24)              t_rdqp
#     beqs  0x11fce               closed: skip the getoblk call
#     nop ; nop
#     (movel %a0,%sp@- ; jsr getoblk -- unchanged, relocation unchanged)
#
# sl_ttrstrt still calls slparam(OPEN) first, so the break TCSBRK started is still
# cleared after a close, exactly as stock does.  Not covered: the bufcall(getoblk)
# that TCGETA/TCGETS arm when allocb fails -- a third route, needing allocation
# failure followed by a close.
#
# Usage: python3 patch_sl_closedq.py <image>

import struct
import sys

IMG = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"
TEXT_OFF = 0x34

SITES = [
    ("slproc T_TIME", 0x12390,
     "40c2" "46fc2400" "026bfffe0038" "40c0" "46c2"
     "33fc800100dff09c" "33fc800100dff09a" "60000082",
     "026bfffe0038" "4aab0018" "670000a0"
     "33fc800100dff09c" "33fc800100dff09a" "60000084" "4e71"),
    ("delay", 0x11fb6,
     "40c0" "46fc2400" "0268fffe0038" "40c1" "46c0",
     "0268fffe0038" "4aa80018" "670c" "4e71" "4e71"),
]


def text_relocs(buf):
    """Offsets in .text that carry a relocation, from .rela.text."""
    shoff, = struct.unpack(">I", buf[0x20:0x24])
    shentsize, shnum, shstrndx = struct.unpack(">HHH", buf[0x2e:0x34])
    secs = [struct.unpack(">IIIIIIIIII", buf[shoff + i * shentsize:shoff + (i + 1) * shentsize])
            for i in range(shnum)]
    strtab = secs[shstrndx]
    out = set()
    for s in secs:
        name = buf[strtab[4] + s[0]:buf.index(b"\0", strtab[4] + s[0])].decode()
        if name != ".rela.text":
            continue
        for k in range(s[5] // 12):
            off, = struct.unpack(">I", buf[s[4] + 12 * k:s[4] + 12 * k + 4])
            out.add(off)
    return out


def main():
    buf = bytearray(open(IMG, "rb").read())
    relocs = text_relocs(buf)
    for name, site, old, new in SITES:
        old, new = bytes.fromhex(old), bytes.fromhex(new)
        if len(old) != len(new):
            raise SystemExit("ABORT: %s: old %d bytes, new %d" % (name, len(old), len(new)))
        hit = [r for r in relocs if site - 3 <= r < site + len(old)]
        if hit:
            raise SystemExit("ABORT: %s: relocation inside 0x%05x+%d at %s"
                             % (name, site, len(old), ", ".join("0x%05x" % r for r in hit)))
        cur = bytes(buf[TEXT_OFF + site:TEXT_OFF + site + len(old)])
        if cur == new:
            print("  [skip] ISSUE-75 %s @0x%05x already guarded" % (name, site))
            continue
        if cur != old:
            raise SystemExit("ABORT: %s @0x%05x has %s, expected %s (base drifted?)"
                             % (name, site, cur.hex(), old.hex()))
        buf[TEXT_OFF + site:TEXT_OFF + site + len(new)] = new
        print("  [ok]   ISSUE-75 %s @0x%05x: t_rdqp == NULL skips getoblk" % (name, site))
    open(IMG, "wb").write(buf)


main()
