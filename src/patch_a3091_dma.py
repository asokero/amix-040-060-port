#!/usr/bin/env python3
# patch_a3091_dma.py -- caches Step B / B1: retarget the A3091/SDMAC stopdma
# call sites to the DMA-coherency wrapper (2026-07-20).
#
# Spec: amix-kernel-analysis/vm-map/DMA-INITIATOR-CENSUS.md +
# DMA-PREPARE-COMPLETE-CONTRACT.md (commit 58f1cda).  Companion object is
# src/dma_cache040.s (dma_a3091_stopdma + dma_cache_fromdev_complete).
#
# WHY a relocation retarget instead of the usual globalize+weaken override:
# startdma/stopdma are file-LOCAL 't' symbols and the image contains THREE
# same-named copies (A2090 0xc580/0xc5f0, A2091 0xcc18/0xcd3c, A3091
# 0xd40a/0xd4cc).  --globalize-symbol stopdma would promote all three to global
# -> multiple-definition link error, and a global override cannot capture a
# local relocation anyway.  So we retarget ONLY the four a3091 `jsr stopdma`
# relocations (.rela.text r_offsets below) from the local a3091 stopdma symbol
# (value 0xd4cc) to the global dma_a3091_stopdma wrapper.  The real body stays
# reachable through the relink --add-symbol alias a3091_stopdma_orig (=0xd4cc).
# A2090/A2091 relocations are untouched -> those controllers are unaffected and
# remain available for a later hook (A2500UX / Zorro SCSI).
#
# ld -r tracks relocations by symbol, not raw index, so the retarget done here
# on build/unix-040 is preserved when relink-040-dbg.sh / -quiet.sh re-link on
# top (the wrapper symbol is carried in via cp); no need to re-run per variant.
#
# Every edit asserts: (1) the four r_offsets each carry a `jsr abs` opcode
# (0x4eb9) at r_offset-2; (2) each currently references a symbol named "stopdma"
# whose st_value is 0xd4cc (the a3091 body, NOT A2090/A2091); (3) the wrapper
# symbol dma_a3091_stopdma is defined.  Abort on any mismatch.  Idempotent:
# already-retargeted relocs are detected and skipped.

import struct, sys
KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"

# a3091 `jsr stopdma` relocation offsets (== .text section offsets == vaddrs)
A3091_STOPDMA_CALLS = [0xd170, 0xd1c8, 0xd2ce, 0xd34a]
A3091_STOPDMA_VALUE = 0xd4cc          # st_value of the a3091 local stopdma body
WRAPPER = "dma_a3091_stopdma"
R_68K_32 = 1

# B2 (2026-07-23, A3091-B2-PREPARE-PATCH-SPEC.md): the TWO a3091 `jsr startdma`
# relocations get prepare wrappers.  0xd0b2 = initial arm from startany;
# 0xd21a = disconnect/reconnect re-arm (distinct wrapper entry that counts
# dma_reconn_arm, then shares the prepare body).  The A2090/A2091 startdma
# sites (0xc2b8/0xc87e/0xca2a) must remain untouched -- asserted by value.
A3091_STARTDMA_VALUE = 0xd40a         # st_value of the a3091 local startdma body
START_RETARGETS = [
    (0xd0b2, "dma_a3091_startdma"),
    (0xd21a, "dma_a3091_startdma_reconn"),
]

def u16(b, o): return struct.unpack(">H", b[o:o+2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o+4])[0]

def main():
    buf = bytearray(open(KERNEL, "rb").read())

    # --- ELF32 big-endian section headers ---
    e_shoff = u32(buf, 32)
    e_shentsize = u16(buf, 46)
    e_shnum = u16(buf, 48)
    e_shstrndx = u16(buf, 50)

    shdr = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        shdr.append({
            "name": u32(buf, o + 0), "type": u32(buf, o + 4),
            "addr": u32(buf, o + 12), "offset": u32(buf, o + 16),
            "size": u32(buf, o + 20), "link": u32(buf, o + 24),
            "entsize": u32(buf, o + 36),
        })
    shstr_off = shdr[e_shstrndx]["offset"]
    def secname(sh):
        e = buf.index(b"\0", shstr_off + sh["name"])
        return buf[shstr_off + sh["name"]:e].decode()

    sec = {secname(sh): sh for sh in shdr}
    text = sec[".text"]
    symtab = sec[".symtab"]
    strtab = shdr[symtab["link"]]     # .symtab's associated string table
    rela = sec[".rela.text"]

    text_foff = text["offset"]        # file offset of .text (== addr + 0x34 normally)

    # --- symbol table helpers ---
    sym_off, sym_ent, sym_n = symtab["offset"], symtab["entsize"], symtab["size"] // symtab["entsize"]
    str_off = strtab["offset"]
    def sym_name(idx):
        st_name = u32(buf, sym_off + idx * sym_ent + 0)
        e = buf.index(b"\0", str_off + st_name)
        return buf[str_off + st_name:e].decode()
    def sym_value(idx):
        return u32(buf, sym_off + idx * sym_ent + 4)

    # locate the wrapper global
    wrap_idx = None
    for i in range(sym_n):
        if sym_name(i) == WRAPPER:
            wrap_idx = i
            break
    if wrap_idx is None:
        raise SystemExit("ABORT: wrapper symbol %s not found (dma_cache040.o linked?)" % WRAPPER)

    # --- retarget the four a3091 stopdma relocations ---
    rela_off, rela_ent, rela_n = rela["offset"], rela["entsize"], rela["size"] // rela["entsize"]
    targets = set(A3091_STOPDMA_CALLS)
    done = skip = 0
    seen = set()

    for i in range(rela_n):
        o = rela_off + i * rela_ent
        r_offset = u32(buf, o + 0)
        if r_offset not in targets:
            continue
        r_info = u32(buf, o + 4)
        cur_sym, r_type = r_info >> 8, r_info & 0xff
        seen.add(r_offset)

        # (1) opcode assertion: `jsr abs.l` (0x4eb9) at r_offset-2
        opc = bytes(buf[text_foff + (r_offset - 2):text_foff + r_offset])
        if opc != b"\x4e\xb9":
            raise SystemExit("ABORT @0x%05x: expected jsr(4eb9) at -2, found %s"
                             % (r_offset, opc.hex()))
        if r_type != R_68K_32:
            raise SystemExit("ABORT @0x%05x: reloc type %d != R_68K_32" % (r_offset, r_type))

        if cur_sym == wrap_idx:
            print("  [skip] @0x%05x already -> %s" % (r_offset, WRAPPER)); skip += 1
            continue

        # (2) current target must be the a3091 stopdma body
        nm, val = sym_name(cur_sym), sym_value(cur_sym)
        if nm != "stopdma" or val != A3091_STOPDMA_VALUE:
            raise SystemExit("ABORT @0x%05x: target is %s@0x%x, expected stopdma@0x%x"
                             % (r_offset, nm, val, A3091_STOPDMA_VALUE))

        # (3) retarget
        new_info = (wrap_idx << 8) | R_68K_32
        struct.pack_into(">I", buf, o + 4, new_info)
        print("  [ok]   @0x%05x  stopdma@0x%x -> %s (sym #%d)"
              % (r_offset, val, WRAPPER, wrap_idx)); done += 1

    missing = targets - seen
    if missing:
        raise SystemExit("ABORT: a3091 stopdma reloc(s) not found: %s"
                         % ", ".join("0x%05x" % m for m in sorted(missing)))
    if done and skip:
        raise SystemExit("ABORT: partial retarget (%d done, %d already) -- group is atomic" % (done, skip))

    # --- B2: retarget the two a3091 startdma relocations to prepare wrappers ---
    sdone = sskip = 0
    for r_target, wrap_name in START_RETARGETS:
        widx = None
        for i in range(sym_n):
            if sym_name(i) == wrap_name:
                widx = i
                break
        if widx is None:
            raise SystemExit("ABORT: wrapper symbol %s not found (dma_cache040.o linked?)" % wrap_name)
        hit = None
        for i in range(rela_n):
            o = rela_off + i * rela_ent
            if u32(buf, o + 0) == r_target:
                hit = o
                break
        if hit is None:
            raise SystemExit("ABORT: a3091 startdma reloc 0x%05x not found" % r_target)
        r_info = u32(buf, hit + 4)
        cur_sym, r_type = r_info >> 8, r_info & 0xff
        opc = bytes(buf[text_foff + (r_target - 2):text_foff + r_target])
        if opc != b"\x4e\xb9":
            raise SystemExit("ABORT @0x%05x: expected jsr(4eb9) at -2, found %s"
                             % (r_target, opc.hex()))
        if r_type != R_68K_32:
            raise SystemExit("ABORT @0x%05x: reloc type %d != R_68K_32" % (r_target, r_type))
        if cur_sym == widx:
            print("  [skip] @0x%05x already -> %s" % (r_target, wrap_name)); sskip += 1
            continue
        nm, val = sym_name(cur_sym), sym_value(cur_sym)
        if nm != "startdma" or val != A3091_STARTDMA_VALUE:
            raise SystemExit("ABORT @0x%05x: target is %s@0x%x, expected startdma@0x%x"
                             % (r_target, nm, val, A3091_STARTDMA_VALUE))
        struct.pack_into(">I", buf, hit + 4, (widx << 8) | R_68K_32)
        print("  [ok]   @0x%05x  startdma@0x%x -> %s (sym #%d)"
              % (r_target, val, wrap_name, widx)); sdone += 1
    if sdone and sskip:
        raise SystemExit("ABORT: partial startdma retarget (%d done, %d already) -- group is atomic"
                         % (sdone, sskip))

    open(KERNEL, "wb").write(buf)
    print("A3091 DMA retarget: stop %d+%d, start %d+%d (done+already) -> %s"
          % (done, skip, sdone, sskip, KERNEL))

main()
