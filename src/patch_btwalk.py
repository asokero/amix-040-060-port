#!/usr/bin/env python3
# patch_btwalk.py -- ISSUE-50: replace backtrace's 64 KiB frame-pointer window with
# a real validity test (2026-08-21).  Companion object: src/btwalk.s.
#
# backtrace @0x595a4 accepted a frame pointer only inside [0x40000000, 0x4000FFFF]
# -- a 64 KiB slice of the u-block -- and that test was the walk's ONLY terminator.
# The 26 bytes at 0x5960e..0x59627 are the whole test:
#
#   0cae 3fff ffff fffc   cmpil #0x3FFFFFFF,%fp@(-4)
#   6300 0010             blsw  59628
#   0cae 4000 ffff fffc   cmpil #0x4000FFFF,%fp@(-4)
#   6200 0004             bhiw  59628
#   7001                  moveq #1,%d0
#
# They are replaced with `bsr.l bt_frame_ok` + NOP padding.  The `tstl %d0 / beqw`
# at 0x59628 is left alone, so the island's contract is the old code's exactly:
# d0 = 1 continue, d0 = 0 stop.
#
# PC-relative on purpose: a byte-patched ABSOLUTE target would need loader rebasing
# (the kernel is ET_REL and rel.c applies relocations at boot), which is the 040
# detour-jmp Line-F trap.  bsr.l needs no relocation at all -- but the displacement
# depends on the island's final .text address, so THIS SCRIPT MUST BE RE-RUN AFTER
# EVERY ld -r.  It is idempotent: an already-patched site (61ff) has its
# displacement re-verified and recomputed for the current image.
#
# Verified before writing: no branch anywhere in backtrace targets an address
# inside the replaced range, so removing those two internal branch targets is safe.
#
# Usage: python3 patch_btwalk.py <image>

import struct
import sys

IMG = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"
TEXT_OFF = 0x34                     # .text file offset in this ET_REL image
SITE = 0x5960E                      # start of the old validity test
END = 0x59628                       # first byte after it (the `tstl %d0`)
OLD = bytes.fromhex("0cae3ffffffffffc630000100cae4000fffffffc620000047001")
ISLAND = "bt_frame_ok"
NOP = b"\x4e\x71"


def u16(b, o): return struct.unpack(">H", b[o:o + 2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o + 4])[0]


def main():
    buf = bytearray(open(IMG, "rb").read())
    span = END - SITE
    assert span == len(OLD) == 26, "span/OLD disagree: %d/%d" % (span, len(OLD))

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
        raise SystemExit("ABORT: %s not defined (is btwalk.o linked?)" % ISLAND)

    # ---- assert the site, allowing an idempotent re-run ----
    cur = bytes(buf[TEXT_OFF + SITE:TEXT_OFF + END])
    if cur == OLD:
        state = "fresh"
    elif cur[:2] == b"\x61\xff":
        state = "repatch"
    else:
        raise SystemExit("ABORT: site @0x%05x is neither the pinned test nor a bsr.l:\n  %s"
                         % (SITE, cur.hex()))

    # bsr.l: displacement is relative to the extension word, i.e. SITE+2
    disp = (target - (SITE + 2)) & 0xFFFFFFFF
    new = b"\x61\xff" + struct.pack(">I", disp)
    new += NOP * ((span - len(new)) // 2)
    assert len(new) == span, "padding arithmetic wrong: %d != %d" % (len(new), span)

    buf[TEXT_OFF + SITE:TEXT_OFF + END] = new
    open(IMG, "wb").write(buf)
    print("  [ok]   ISSUE-50 frame test installed @0x%05x (%s): bsr.l %s @0x%05x, %d NOPs"
          % (SITE, state, ISLAND, target, (span - 6) // 2))


main()
