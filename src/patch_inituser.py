#!/usr/bin/env python3
# patch_inituser.py -- ISSUE-52 round 4: replace _start's frame-build + user RTE
# with a jump to the capture island (2026-08-21).  Companion object: src/inituser.s.
#
# _start builds PID 1's launch frame and RTEs to user at 0x4a..0x5f:
#
#   4a: 323c 0000   movew #0,%d1
#   4e: 3f01        movew %d1,%sp@-      ; format word 0x0000
#   50: 2f00        movel %d0,%sp@-      ; PC (sets N from d0)
#   52: 6b08        bmis  5c
#   54: 323c 2000   movew #0x2000,%d1    ; supervisor SR (non-user arm)
#   58: 3f01        movew %d1,%sp@-
#   5a: 4e73        rte
#   5c: 3f01        movew %d1,%sp@-      ; SR = 0x0000 -- USER
#   5e: 4e73        rte
#
# These 22 bytes are replaced by `bra.l ini_user_rte` (0x60ff + disp32) plus NOP
# padding.  The island rebuilds the identical frame from d0, latches, and RTEs, so
# a good kernel launches PID 1 exactly as before.
#
# bra.l, NOT bsr.l: bra pushes no return address, so the island's %sp read reports
# the true SSP the RTE pops from -- the whole point of the capture.  PC-relative,
# so no relocation and no loader rebasing (the 040 detour-jmp Line-F trap).  The
# displacement depends on the island's final .text address, so THIS SCRIPT MUST BE
# RE-RUN AFTER EVERY ld -r.  Idempotent: an already-patched site (60ff) has its
# displacement re-verified and recomputed for the current image.
#
# This is downstream of patch_inittrap.py (round 3, the jsr main retarget at 0x46);
# the two do not overlap.  d0 survives ini_main's rts into 0x4a unchanged, so the
# island sees exactly what _start would have pushed.
#
# Usage: python3 patch_inituser.py <image>

import struct
import sys

IMG = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"
TEXT_OFF = 0x34
SITE = 0x4A
END = 0x60
OLD = bytes.fromhex("323c00003f012f006b08323c20003f014e733f014e73")
ISLAND = "ini_user_rte"
NOP = b"\x4e\x71"


def u16(b, o): return struct.unpack(">H", b[o:o + 2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o + 4])[0]


def main():
    buf = bytearray(open(IMG, "rb").read())
    span = END - SITE
    assert span == len(OLD) == 22, "span/OLD disagree: %d/%d" % (span, len(OLD))

    # ---- locate the island in the linked symbol table ----
    e_shoff, e_shentsize = u32(buf, 32), u16(buf, 46)
    e_shnum, e_shstrndx = u16(buf, 48), u16(buf, 50)
    sh = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        sh.append({"name": u32(buf, o), "offset": u32(buf, o + 16), "size": u32(buf, o + 20),
                   "link": u32(buf, o + 24), "entsize": u32(buf, o + 36)})
    shstr = sh[e_shstrndx]["offset"]

    def nm(s):
        e = buf.index(b"\0", shstr + s["name"])
        return buf[shstr + s["name"]:e].decode()

    sec = {nm(s): s for s in sh}
    symtab = sec[".symtab"]
    strtab = sh[symtab["link"]]
    target = None
    for j in range(symtab["size"] // symtab["entsize"]):
        o = symtab["offset"] + j * symtab["entsize"]
        n = u32(buf, o)
        e = buf.index(b"\0", strtab["offset"] + n)
        if buf[strtab["offset"] + n:e].decode() == ISLAND:
            target = u32(buf, o + 4)
            break
    if target is None:
        raise SystemExit("ABORT: %s not defined (is inituser.o linked?)" % ISLAND)

    cur = bytes(buf[TEXT_OFF + SITE:TEXT_OFF + END])
    if cur == OLD:
        state = "fresh"
    elif cur[:2] == b"\x60\xff":
        state = "repatch"
    else:
        raise SystemExit("ABORT: site @0x%05x is neither the pinned handoff nor a bra.l:\n  %s"
                         % (SITE, cur.hex()))

    # bra.l: displacement relative to the extension word, i.e. SITE + 2
    disp = (target - (SITE + 2)) & 0xFFFFFFFF
    new = b"\x60\xff" + struct.pack(">I", disp)
    new += NOP * ((span - len(new)) // 2)
    assert len(new) == span, "padding arithmetic wrong: %d != %d" % (len(new), span)

    buf[TEXT_OFF + SITE:TEXT_OFF + END] = new
    open(IMG, "wb").write(buf)
    print("  [ok]   ISSUE-52 user-RTE capture installed @0x%05x (%s): bra.l %s @0x%05x, %d NOPs"
          % (SITE, state, ISLAND, target, (span - 6) // 2))


main()
