#!/usr/bin/env python3
# check_vproc.py -- assert v.v_proc == 200, the invariant krnxmemflt040.s's
# per-process depth table depends on (2026-07-31).
#
# Lkx_proc_depth has one cell per process slot, indexed by p_pidp->pid_prslot,
# which pid_assign derives from the procdir index.  The table is sized 200 in
# source.  If the v_proc tunable is ever raised, an out-of-range slot would be
# counted by Lkx_badslot and pushed to the shared fallback cell -- correct, but
# it silently degrades the gate for every process above 200.  So the build
# asserts the two numbers agree instead of trusting a comment.
#
# Usage: python3 check_vproc.py <image>

import struct, sys

IMG = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"
TABLE_SLOTS = 200
V_PROC_OFF = 8                      # v.v_proc = v+8


def u16(b, o): return struct.unpack(">H", b[o:o+2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o+4])[0]


def main():
    buf = open(IMG, "rb").read()
    e_shoff, e_shentsize = u32(buf, 32), u16(buf, 46)
    e_shnum, e_shstrndx = u16(buf, 48), u16(buf, 50)
    sh = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        sh.append({"name": u32(buf, o), "offset": u32(buf, o + 16), "size": u32(buf, o + 20),
                   "link": u32(buf, o + 24), "entsize": u32(buf, o + 36), "idx": i})
    shstr = sh[e_shstrndx]["offset"]

    def nm(s):
        e = buf.index(b"\0", shstr + s["name"])
        return buf[shstr + s["name"]:e].decode()

    sec = {nm(s): s for s in sh}
    data, symtab = sec[".data"], sec[".symtab"]
    strtab = sh[symtab["link"]]
    v = None
    for i in range(symtab["size"] // symtab["entsize"]):
        o = symtab["offset"] + i * symtab["entsize"]
        n = u32(buf, o)
        e = buf.index(b"\0", strtab["offset"] + n)
        if buf[strtab["offset"] + n:e] == b"v" and u16(buf, o + 14) == data["idx"]:
            v = u32(buf, o + 4)
            break
    if v is None:
        raise SystemExit("ABORT: symbol v not found in .data")

    got = u32(buf, data["offset"] + v + V_PROC_OFF)
    if got != TABLE_SLOTS:
        raise SystemExit("ABORT: v.v_proc = %d but Lkx_proc_depth has %d cells "
                         "-- grow the table in krnxmemflt040.s in the same change"
                         % (got, TABLE_SLOTS))
    print("  [ok]   v.v_proc = %d == Lkx_proc_depth cells (per-process depth gate covers every slot)" % got)


main()
