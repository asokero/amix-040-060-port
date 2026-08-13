#!/usr/bin/env python3
# patch_z3660.py -- wire the two Z3660 drivers into a relinked 68040 kernel
# (2026-07-31).  Three edits, each asserted against the bytes it expects, so a
# drifted base image fails the build instead of producing a mis-wired kernel.
# Rationale and the full address map: docs/Z3660-KERNEL-FEASIBILITY-260731.md.
#
#   1. scsicard[] : retarget the `lea scsicard,%a3` relocation @0xd74c to our
#      four-row table z3660_scsicard (same mechanism as patch_a3091_dma.py).
#   2. loop bound : `moveq #2,%d1` @0xd79e -> `moveq #3,%d1`, so init walks four
#      rows instead of three.  One byte.
#   3. dd.c order : retarget the `iodone` relocation @0xc0ae to the island
#      dd_startio_first, which runs startio(FIRST, dp) first and then tail-jumps
#      into iodone.  An in-place swap of the two calls is NOT possible: another
#      path branches straight into the `jsr startio` at 0xc0b6.
#
# Usage: python3 patch_z3660.py <image>

import os
import struct
import sys

IMG = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040-z3660"

LEA_RELOC = 0x0000D74C      # operand of `lea scsicard,%a3`
BOUND_OFF = 0x0000D79E      # `moveq #2,%d1`
BOUND_OLD = b"\x72\x02"
BOUND_NEW = b"\x72\x03"
IODONE_RELOC = 0x0000C0AE   # operand of dd.c's `jsr iodone`

# Rows 0-2 of our table must bind to the same bodies the stock table pointed at.
EXPECT_QUEUES = {"a3091queue", "a2090queue", "a2091queue"}


def u16(b, o): return struct.unpack(">H", b[o:o+2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o+4])[0]


def main():
    buf = bytearray(open(IMG, "rb").read())
    e_shoff, e_shentsize = u32(buf, 32), u16(buf, 46)
    e_shnum, e_shstrndx = u16(buf, 48), u16(buf, 50)
    sh = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        sh.append({"name": u32(buf, o), "type": u32(buf, o + 4), "offset": u32(buf, o + 16),
                   "size": u32(buf, o + 20), "link": u32(buf, o + 24),
                   "info": u32(buf, o + 28), "entsize": u32(buf, o + 36)})
    shstr = sh[e_shstrndx]["offset"]

    def nm(s):
        e = buf.index(b"\0", shstr + s["name"])
        return buf[shstr + s["name"]:e].decode()

    sec = {nm(s): s for s in sh}
    text, rela = sec[".text"], sec.get(".rela.text")
    if rela is None:
        raise SystemExit("ABORT: no .rela.text (is this the relinked image?)")
    symtab = sh[rela["link"]]
    strtab = sh[symtab["link"]]

    def symname(idx):
        o = symtab["offset"] + idx * symtab["entsize"]
        n = u32(buf, o)
        e = buf.index(b"\0", strtab["offset"] + n)
        return buf[strtab["offset"] + n:e].decode()

    def symindex(want):
        cnt = symtab["size"] // symtab["entsize"]
        for i in range(cnt):
            if symname(i) == want:
                return i
        raise SystemExit("ABORT: symbol %s not found (is z3660_glue040.o linked?)" % want)

    # ---- 1 + 3: relocation retargets -------------------------------------
    todo = {LEA_RELOC: ("scsicard", "z3660_scsicard", "scsicard[] -> four-row table")}
    # dd.c completion ordering: OFF BY DEFAULT since 2026-07-31, measured.
    # Their dd.c.patch (startio before iodone) is right for THEIR driver on a
    # SOURCE kernel.  Transcribed here as an island -- an in-place swap is
    # impossible because two paths share the single `jsr startio` at 0xc0b6 (the
    # other arrives via `braw` from 0xc094 with flag=2) -- the kernel panics
    # BEFORE the banner, inside sdqueue reached from startio, with a wild function
    # pointer (pc=0x62, illegal instruction).  Identical image without this one
    # edit boots clean, so the attribution is exact.  Whether their ordering is
    # unsafe for the STOCK A3091 path or the island's context assumption is subtly
    # wrong is NOT established, and it cannot be settled on a machine where their
    # driver never runs.  Enable with Z3660_DD_ORDER=1 when there is a Z3660 to
    # validate it against.
    if os.environ.get("Z3660_DD_ORDER") == "1":
        todo[IODONE_RELOC] = ("iodone", "dd_startio_first", "dd.c iodone -> startio-first island")
        print("  [warn] dd.c completion ordering ENABLED -- panics on a board-less machine")
    else:
        print("  [skip] dd.c completion ordering left stock (set Z3660_DD_ORDER=1 to apply)")
    done = set()
    n = rela["size"] // rela["entsize"]
    for i in range(n):
        o = rela["offset"] + i * rela["entsize"]
        r_off = u32(buf, o)
        if r_off not in todo:
            continue
        r_info = u32(buf, o + 4)
        old_sym, new_sym, what = todo[r_off]
        cur = symname(r_info >> 8)
        if cur == new_sym:
            print("  [skip] @0x%x already -> %s" % (r_off, new_sym))
            done.add(r_off)
            continue
        if cur != old_sym:
            raise SystemExit("ABORT: reloc @0x%x names %r, expected %r" % (r_off, cur, old_sym))
        struct.pack_into(">I", buf, o + 4, (symindex(new_sym) << 8) | (r_info & 0xFF))
        print("  [ok]   %-42s @0x%x  %s -> %s" % (what, r_off, old_sym, new_sym))
        done.add(r_off)
    missing = set(todo) - done
    if missing:
        raise SystemExit("ABORT: relocation(s) not found: %s"
                         % ", ".join("0x%x" % m for m in sorted(missing)))

    # ---- 2: the loop bound ------------------------------------------------
    fo = text["offset"] + BOUND_OFF
    cur = bytes(buf[fo:fo + 2])
    if cur == BOUND_NEW:
        print("  [skip] scsicard loop bound already 3 @0x%x" % BOUND_OFF)
    elif cur == BOUND_OLD:
        buf[fo:fo + 2] = BOUND_NEW
        print("  [ok]   %-42s @0x%x  moveq #2 -> #3" % ("scsicard loop bound (3 -> 4 rows)", BOUND_OFF))
    else:
        raise SystemExit("ABORT: bound @0x%x holds %s, expected 7202/7203" % (BOUND_OFF, cur.hex()))

    open(IMG, "wb").write(buf)
    print("Z3660 wiring installed -> %s" % IMG)


main()
