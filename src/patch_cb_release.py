#!/usr/bin/env python3
# patch_cb_release.py -- caches Step B2: install the copyback page-release
# barrier hooks (2026-07-23).  Spec: analyysirepo vm-map/CB-PAGE-LIFECYCLE-
# CLOSURE.md (pinned 5f745d5 / base sha d3e1f80a).  Companion object:
# src/cb_release040.s (Lcb_core + the two islands below).
#
# Hook 1 -- page_free @0xafb08: the six bytes 40c3 46fc 2400 (movew %sr,%d3 +
#   movew &0x2400,%sr) are replaced with `bsr.l cb_pgfree_enter` (61ff+disp32).
#   PC-relative on purpose: a byte-patched ABSOLUTE target would need loader
#   rebasing (kernel is ET_REL, rel.c applies relocations at boot) -- writing a
#   raw link address is exactly the 040 detour-jmp Line-F trap.  bsr.l needs no
#   relocation at all.  The island replays the displaced SR pair, releases
#   a2=pp, rts -> 0xafb0e (before freemem++/p_free publication).
#   NOTE: the displacement depends on the island's final .text address, which
#   can differ per link variant -> this script MUST be re-run after EVERY ld -r
#   (relink-040.sh, -dbg, -quiet).  It is idempotent: an already-patched site
#   (61ff) gets its displacement re-verified/re-computed for the current image.
#
# Hook 2 -- free_vp_pages @0xafd98: the six bytes are 52b9 + a 4-byte field
#   covered by an R_68K_32 relocation to `freemem` (addql &1,freemem).  The
#   opcode word is rewritten 52b9 -> 4eb9 (jsr abs.l) and the EXISTING
#   relocation is retargeted freemem -> cb_vpfree_enter (same mechanism as
#   patch_a3091_dma.py; ld -r tracks the retarget by symbol into dbg/quiet).
#   Leaving the freemem reloc in place would have the loader write freemem's
#   address over the jsr operand.  The island replays freemem++ itself.
#
# Every edit asserts pinned old bytes / relocation identity and fails closed.

import struct, sys
KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"

PGFREE_SITE = 0xafb08
PGFREE_OLD = bytes.fromhex("40c346fc2400")
PGFREE_ISLAND = "cb_pgfree_enter"

VPFREE_SITE = 0xafd98            # opcode word offset; reloc field = +2
VPFREE_ISLAND = "cb_vpfree_enter"
R_68K_32 = 1

def u16(b, o): return struct.unpack(">H", b[o:o+2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o+4])[0]

def main():
    buf = bytearray(open(KERNEL, "rb").read())

    e_shoff = u32(buf, 32); e_shentsize = u16(buf, 46)
    e_shnum = u16(buf, 48); e_shstrndx = u16(buf, 50)
    shdr = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        shdr.append({"name": u32(buf, o), "type": u32(buf, o+4),
                     "addr": u32(buf, o+12), "offset": u32(buf, o+16),
                     "size": u32(buf, o+20), "link": u32(buf, o+24),
                     "entsize": u32(buf, o+36)})
    shstr = shdr[e_shstrndx]["offset"]
    def nm(sh):
        e = buf.index(b"\0", shstr + sh["name"])
        return buf[shstr + sh["name"]:e].decode()
    sec = {nm(sh): sh for sh in shdr}
    text, symtab, rela = sec[".text"], sec[".symtab"], sec[".rela.text"]
    strtab = shdr[symtab["link"]]
    tfo = text["offset"]

    so, se, sn = symtab["offset"], symtab["entsize"], symtab["size"] // symtab["entsize"]
    sto = strtab["offset"]
    def sym_name(i):
        n = u32(buf, so + i*se)
        e = buf.index(b"\0", sto + n)
        return buf[sto + n:e].decode()
    def sym_value(i): return u32(buf, so + i*se + 4)
    def find_sym(name):
        for i in range(sn):
            if sym_name(i) == name:
                return i
        raise SystemExit("ABORT: symbol %s not found (cb_release040.o linked?)" % name)

    # ---- hook 1: page_free bsr.l ----
    isl1 = sym_value(find_sym(PGFREE_ISLAND))
    disp = (isl1 - (PGFREE_SITE + 2)) & 0xffffffff
    want = b"\x61\xff" + struct.pack(">I", disp)
    cur = bytes(buf[tfo+PGFREE_SITE:tfo+PGFREE_SITE+6])
    if cur == PGFREE_OLD:
        buf[tfo+PGFREE_SITE:tfo+PGFREE_SITE+6] = want
        print("  [ok]   page_free @0x%05x: %s -> bsr.l %s (disp 0x%08x)"
              % (PGFREE_SITE, PGFREE_OLD.hex(), PGFREE_ISLAND, disp))
    elif cur[:2] == b"\x61\xff":
        if cur == want:
            print("  [skip] page_free @0x%05x already -> %s" % (PGFREE_SITE, PGFREE_ISLAND))
        else:
            buf[tfo+PGFREE_SITE:tfo+PGFREE_SITE+6] = want
            print("  [ok]   page_free @0x%05x: bsr.l disp re-fixed for this image (0x%08x)"
                  % (PGFREE_SITE, disp))
    else:
        raise SystemExit("ABORT @0x%05x: bytes %s, expected %s or 61ff-patched"
                         % (PGFREE_SITE, cur.hex(), PGFREE_OLD.hex()))

    # ---- hook 2: free_vp_pages jsr + reloc retarget ----
    isl2 = find_sym(VPFREE_ISLAND)
    ro, re, rn = rela["offset"], rela["entsize"], rela["size"] // rela["entsize"]
    hit = None
    for i in range(rn):
        o = ro + i*re
        if u32(buf, o) == VPFREE_SITE + 2:
            hit = o
            break
    if hit is None:
        raise SystemExit("ABORT: no relocation at 0x%05x (free_vp_pages freemem field)"
                         % (VPFREE_SITE + 2))
    r_info = u32(buf, hit + 4)
    cur_sym, r_type = r_info >> 8, r_info & 0xff
    if r_type != R_68K_32:
        raise SystemExit("ABORT: reloc type %d != R_68K_32" % r_type)
    opc = bytes(buf[tfo+VPFREE_SITE:tfo+VPFREE_SITE+2])
    if cur_sym == isl2 and opc == b"\x4e\xb9":
        print("  [skip] free_vp_pages @0x%05x already -> %s" % (VPFREE_SITE, VPFREE_ISLAND))
    else:
        if sym_name(cur_sym) != "freemem":
            raise SystemExit("ABORT: reloc target %s, expected freemem" % sym_name(cur_sym))
        if opc != b"\x52\xb9":
            raise SystemExit("ABORT @0x%05x: opcode %s, expected 52b9 (addql &1,freemem)"
                             % (VPFREE_SITE, opc.hex()))
        buf[tfo+VPFREE_SITE:tfo+VPFREE_SITE+2] = b"\x4e\xb9"
        struct.pack_into(">I", buf, hit + 4, (isl2 << 8) | R_68K_32)
        print("  [ok]   free_vp_pages @0x%05x: addql freemem -> jsr %s (reloc retarget)"
              % (VPFREE_SITE, VPFREE_ISLAND))

    open(KERNEL, "wb").write(buf)
    print("CB page-release hooks installed -> %s" % KERNEL)

main()
