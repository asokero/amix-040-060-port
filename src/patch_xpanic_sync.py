#!/usr/bin/env python3
# patch_xpanic_sync.py -- ISSUE-105: xpanic decided whether to sync() from
# uninitialised bits (2026-08-21).
#
# xpanic @0x3e668 gates its sync() call like this:
#
#   3e688:  40c0        movew %sr,%d0          ; writes only the LOW word of d0
#   3e68a:  46fc 2400   movew #9216,%sr
#   3e68e:  2d40 fffc   movel %d0,%fp@(-4)     ; stores the FULL LONG
#   3e692:  40c1        movew %sr,%d1          ; dead
#   3e694:  46c0        movew %d0,%sr          ; restores from the REGISTER
#   3e696:  e8ee 0143 fffc  bftst %fp@(-4),5,3 ; tests bits 26-24 of that long
#   3e69c:  6600 0008   bnew  3e6a6            ; non-zero -> SKIP sync
#   3e6a0:  4eb9 ....   jsr   sync
#
# `bftst {5:3}` on a memory operand counts from the MSB of the addressed byte, so
# it tests bits 26-24 of the stored longword -- bits 10-8 of d0's HIGH word, which
# `movew %sr,%d0` never writes.  What is in it is whatever the preceding
# `jsr sysdump` (0x3e682) left in d0.  Measured: two panics on the same kernel
# family, one with syncg_calls = 1 and one with 0.
#
# FIX, one instruction and the same length: rewrite the store as
#
#   3e68e:  42ae fffc   clrl %fp@(-4)
#
# so the tested field is deterministically zero and the panic path ALWAYS reaches
# sync().  Three things make this the safe direction rather than the clever one:
#
#   * `%fp@(-4)` is read by nothing else in xpanic -- the SR restore at 0x3e694
#     comes from %d0, the register, which this does not touch;
#   * always-sync is the intended SVR4 panic semantic (flush filesystems on the way
#     out), and skipping would silently drop that;
#   * sync() on the panic path is safe at any point in boot since ISSUE-100 -- it
#     skips vfs switch rows that vfsinit has not filled instead of calling NULL.
#     Landing this without that guard in place would be reckless; with it, it is
#     the behaviour the code always meant to have.
#
# Usage: python3 patch_xpanic_sync.py <image>

import sys

IMG = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"
TEXT_OFF = 0x34
SITE = 0x3E68E
OLD = bytes.fromhex("2d40fffc")     # movel %d0,%fp@(-4)
NEW = bytes.fromhex("42aefffc")     # clrl  %fp@(-4)


def main():
    buf = bytearray(open(IMG, "rb").read())
    cur = bytes(buf[TEXT_OFF + SITE:TEXT_OFF + SITE + 4])
    if cur == NEW:
        print("  [skip] ISSUE-105 sync gate already deterministic @0x%05x" % SITE)
        return
    if cur != OLD:
        raise SystemExit("ABORT: xpanic @0x%05x has %s, expected %s (base drifted?)"
                         % (SITE, cur.hex(), OLD.hex()))
    buf[TEXT_OFF + SITE:TEXT_OFF + SITE + 4] = NEW
    open(IMG, "wb").write(buf)
    print("  [ok]   ISSUE-105 sync gate @0x%05x: movel %%d0 -> clrl (always sync)" % SITE)


main()
