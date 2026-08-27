#!/usr/bin/env python3
# patch_a3091_intr.py -- ISSUE-53: route the level-2 A3091 interrupt through the
# source-demultiplex wrapper in src/a3091demux040.s (2026-08-27).
#
# WHY.  a3091intr admits an interrupt on SDMAC ISTR bit 4 (INT_P) and then reads the
# WD33C93A SCSI Status register unconditionally.  INT_P is an AGGREGATE of the WD's own
# request (INTS), the SDMAC's end-of-process (E_INT) and the FIFO error sources, so an
# event the SCSI controller never raised is dispatched on a status register the data sheet
# does not define for that read.  atab[IDLE][8] returns DEAD and the machine needs a power
# cycle -- four times on 2026-08-26 across three kernels.  The wrapper classifies the
# source from ONE ISTR snapshot taken before anything else and hands the WD's own events,
# unchanged, to the stock body.  Background: docs/A3091-WEDGE-CAPTURED-260826.md and
# amix-kernel-analysis/vm-map/A3091-SPURIOUS-COMPLETION-AUDIT.md.
#
# WHY A TABLE RETARGET AND NOT globalize+weaken.  The handler is reached only through
# int2_tbl, which amiga/ml/ttrap.s's p2int walks with `jsr (%a0)` per entry.  Retargeting
# that one relocation leaves a3091intr a strong global that the wrapper can still call by
# name -- no weakening, no --add-symbol alias, and the stock body is not touched.  Same
# mechanism as patch_a3091_dma.py and patch_segdev_ops.py.
#
# WHAT IS ASSERTED, all against build/unix-040 as measured on 2026-08-27:
#   1. int2_tbl exists at .data+0x998c with st_size 24 -- the table did not move or resize
#   2. ALL FIVE slots hold the expected handler, by NAME and st_value, so a reordered or
#      reconfigured table aborts instead of retargeting somebody else's driver
#   3. the sixth slot (.data+0x99a0) has NO relocation -- it is the NULL terminator, and
#      p2int stops there; a relocation appearing would mean a sixth handler exists
#   4. the slot we edit is R_68K_32 with addend 0
#   5. a3091intr_demux exists (a3091demux040.o actually linked)
# Abort on any mismatch.  Idempotent.

import struct, sys

KERNEL   = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"
R_68K_32 = 1

TABLE      = "int2_tbl"
TABLE_OFF  = 0x998c
TABLE_SIZE = 24
WRAPPER    = "a3091intr_demux"

# .data offset -> (symbol, st_value).  The whole table, not only our slot: this is the
# check that we are editing the A3000 SCSI entry and not, say, the ethernet one.
SLOTS = [
    (0x998c, "aciaaintr", 0x0def8),
    (0x9990, "jbintr",    0x0fb3e),
    (0x9994, "a2091intr", 0x0c8a0),
    (0x9998, "a3091intr", 0x0d0e0),   # <- ours
    (0x999c, "aenintr",   0x15702),
]
OURS      = 0x9998
TERMINATOR = 0x99a0

def u16(b, o): return struct.unpack_from(">H", b, o)[0]
def u32(b, o): return struct.unpack_from(">I", b, o)[0]

def main():
    b = bytearray(open(KERNEL, "rb").read())
    e_shoff, e_shentsize = u32(b, 32), u16(b, 46)
    e_shnum, e_shstrndx  = u16(b, 48), u16(b, 50)

    sh = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        sh.append({"name": u32(b, o), "offset": u32(b, o + 16), "size": u32(b, o + 20),
                   "link": u32(b, o + 24), "entsize": u32(b, o + 36)})
    stro = sh[e_shstrndx]["offset"]
    def secname(s):
        e = b.index(b"\0", stro + s["name"])
        return b[stro + s["name"]:e].decode()
    sec = {secname(s): s for s in sh}

    if ".rela.data" not in sec:
        sys.exit("patch_a3091_intr: ABORT: no .rela.data -- int2_tbl is not relocated here")
    rela, symtab = sec[".rela.data"], sec[".symtab"]
    strtab = sh[symtab["link"]]
    so, se, sn = symtab["offset"], symtab["entsize"], symtab["size"] // symtab["entsize"]
    stro2 = strtab["offset"]

    def sym_name(i):
        n = u32(b, so + i * se)
        e = b.index(b"\0", stro2 + n)
        return b[stro2 + n:e].decode()
    def sym_value(i): return u32(b, so + i * se + 4)
    def sym_size(i):  return u32(b, so + i * se + 8)

    wrap_idx = tbl_idx = None
    for i in range(sn):
        n = sym_name(i)
        if n == WRAPPER and wrap_idx is None:
            wrap_idx = i
        elif n == TABLE and tbl_idx is None:
            tbl_idx = i
    if wrap_idx is None:
        sys.exit("patch_a3091_intr: ABORT: %s not found (a3091demux040.o linked?)" % WRAPPER)
    if tbl_idx is None:
        sys.exit("patch_a3091_intr: ABORT: %s not found" % TABLE)
    if sym_value(tbl_idx) != TABLE_OFF or sym_size(tbl_idx) != TABLE_SIZE:
        sys.exit("patch_a3091_intr: ABORT: %s is .data+0x%05x size %d, expected .data+0x%05x "
                 "size %d -- the table moved or gained a handler"
                 % (TABLE, sym_value(tbl_idx), sym_size(tbl_idx), TABLE_OFF, TABLE_SIZE))

    ro, re_, rn = rela["offset"], rela["entsize"], rela["size"] // rela["entsize"]
    byoff = {}
    for i in range(rn):
        o = ro + i * re_
        r_off = u32(b, o)
        if TABLE_OFF <= r_off <= TERMINATOR:
            byoff[r_off] = o

    if TERMINATOR in byoff:
        sys.exit("patch_a3091_intr: ABORT: .data+0x%05x is relocated -- int2_tbl's NULL "
                 "terminator is a handler now, so the table is not the one measured"
                 % TERMINATOR)

    done = skip = 0
    for off, want, want_val in SLOTS:
        if off not in byoff:
            sys.exit("patch_a3091_intr: ABORT: no relocation at .data+0x%05x (%s slot)"
                     % (off, want))
        o = byoff[off]
        info = u32(b, o + 4)
        cur, rtype = info >> 8, info & 0xff
        addend = u32(b, o + 8)
        if rtype != R_68K_32:
            sys.exit("patch_a3091_intr: ABORT @0x%05x: reloc type %d != R_68K_32" % (off, rtype))
        if off != OURS:
            n, v = sym_name(cur), sym_value(cur)
            if n != want or v != want_val:
                sys.exit("patch_a3091_intr: ABORT @0x%05x: slot holds %s@0x%x, expected %s@0x%x "
                         "-- int2_tbl is not the table this was measured against"
                         % (off, n, v, want, want_val))
            print("  [keep] int2_tbl[%d] -> %s@0x%x" % ((off - TABLE_OFF) // 4, n, v))
            continue
        if cur == wrap_idx:
            print("  [skip] int2_tbl[%d] already -> %s" % ((off - TABLE_OFF) // 4, WRAPPER))
            skip += 1
            continue
        n, v = sym_name(cur), sym_value(cur)
        if n != want or v != want_val:
            sys.exit("patch_a3091_intr: ABORT @0x%05x: slot holds %s@0x%x, expected %s@0x%x"
                     % (off, n, v, want, want_val))
        if addend != 0:
            sys.exit("patch_a3091_intr: ABORT @0x%05x: addend is 0x%x, expected 0" % (off, addend))
        struct.pack_into(">I", b, o + 4, (wrap_idx << 8) | R_68K_32)
        print("  [ok]   int2_tbl[%d]  %s@0x%x -> %s (sym #%d)"
              % ((off - TABLE_OFF) // 4, n, v, WRAPPER, wrap_idx))
        done += 1

    if done + skip != 1:
        sys.exit("patch_a3091_intr: ABORT: handled %d slots, expected exactly 1" % (done + skip))
    if done:
        open(KERNEL, "wb").write(b)
    print("patch_a3091_intr: %d retargeted, %d already, 4 neighbours asserted -> %s"
          % (done, skip, KERNEL))

if __name__ == "__main__":
    main()
