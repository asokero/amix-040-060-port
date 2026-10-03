#!/usr/bin/env python3
# patch_autocon_lsr.py -- ISSUE-76: autocon() never matches a manufacturer id at
# or above 0x8000 (2026-10-03).
#
# Stock support.c, autocon (around line 314): the board key `pc` is a signed long,
# and the manufacturer half is taken as `pc >> 16`.  The compiler emits an
# arithmetic shift, so 0xC0DE0001 yields 0xFFFFC0DE, while the table side is the
# 16-bit er_Manufacturer zero-extended into %d5.  The compare can never succeed for
# such an id, and the board is reported absent:
#
#   1927a:  3a30 1814   movew %a0@(14,%d1:l),%d5   ; er_Manufacturer, %d5 cleared before
#   1927e:  2006        movel %d6,%d0              ; pc
#   19280:  7e10        moveq #16,%d7
#   19282:  eea0        asrl  %d7,%d0              ; <- sign-extends
#   19284:  b085        cmpl  %d5,%d0
#
# FIX, one instruction and the same length: `lsrl %d7,%d0` (0xeea8).  The product
# compare that follows masks with 0xffff and is unaffected.  Every manufacturer
# id the stock drivers and this tree's external drivers look up is below 0x8000
# (0x0202, 0x0406, 0x041d, 0x07ee; VA2000 0x6d6e, Z3660 0x144b), so for those the
# result is identical; the patch matters to a board such as the A4092 (0xc0de).
#
# Usage: python3 patch_autocon_lsr.py <image>

import sys

IMG = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"
TEXT_OFF = 0x34
CTX = 0x1927a
OLD = bytes.fromhex("3a301814" "2006" "7e10" "eea0" "b085")
NEW = bytes.fromhex("3a301814" "2006" "7e10" "eea8" "b085")


def main():
    buf = bytearray(open(IMG, "rb").read())
    cur = bytes(buf[TEXT_OFF + CTX:TEXT_OFF + CTX + len(OLD)])
    if cur == NEW:
        print("  [skip] ISSUE-76 autocon shift already unsigned @0x%05x" % (CTX + 8))
        return
    if cur != OLD:
        raise SystemExit("ABORT: autocon @0x%05x has %s, expected %s (base drifted?)"
                         % (CTX, cur.hex(), OLD.hex()))
    buf[TEXT_OFF + CTX:TEXT_OFF + CTX + len(NEW)] = NEW
    open(IMG, "wb").write(buf)
    print("  [ok]   ISSUE-76 autocon @0x%05x: asrl -> lsrl (ids >= 0x8000 match)" % (CTX + 8))


main()
