#!/usr/bin/env python3
# patch_a3091_badhardware.py -- retarget a3091intr's badhardware() call to the
# diagnostic interposer in src/a3091dbg040.s (2026-08-26).
#
# WHY.  On 2026-08-25 the machine wedged with one console line, `a3091: 0x16 0 0x8112B84`,
# and nothing else.  a3091.c's badhardware() prints exactly that and returns DEAD, from
# which the driver never recovers -- so the state that would explain WHY an unexpected
# completion arrived is destroyed at the moment it would be most useful.  The interposer
# prints and latches that state first, then tail-jumps to the stock body so its line still
# appears and DEAD is still returned.  Nothing about the driver's behaviour changes.
# Background: docs/A3091-WEDGE-PRESTUDY-260826.md.
#
# WHY A RELOCATION RETARGET AND NOT globalize+weaken -- the same reasoning as
# patch_a3091_dma.py, and it matters more here.  `badhardware` is a file-LOCAL static and
# the image holds TWO of them:
#     0xcf46   in `service`   (a different driver; its call site is at 0xcba6)
#     0xd666   in a3091.c     (its call site is at 0xd3a6)
# A strong global `badhardware` would capture both, so the other driver's faults would
# print A3091 state -- a diagnostic that lies about which hardware misbehaved is worse
# than none.  Retargeting the single a3091 relocation leaves `service` untouched.
#
# ONE relocation covers all three source-level calls: a3091.c's cases 1, 3 and 8 each do
# `istate = badhardware(ss)`, and the compiler merged them into one tail at 0xd3a2
# (`movel %d2,%sp@-; jsr badhardware; movel %d0,istate`).  Verified in the disassembly --
# there are exactly two `badhardware` relocations in the whole image, and one is service's.
#
# Every edit asserts: (1) `jsr abs.l` (0x4eb9) at r_offset-2; (2) the reloc type is
# R_68K_32; (3) the current target is named "badhardware" AND has st_value 0xd666, which
# is what keeps this off service's copy even if the offset were ever wrong; (4) the
# interposer symbol exists.  Abort on any mismatch.  Idempotent.

import struct, sys
KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"

A3091_BADHW_CALL  = 0xd3a6      # the single `jsr badhardware` reloc inside a3091intr
A3091_BADHW_VALUE = 0xd666      # st_value of the a3091 local badhardware body
SERVICE_BADHW     = 0xcf46      # the OTHER one -- must never be touched
INTERPOSER        = "a3091_badhardware_dbg"
R_68K_32          = 1

def u32(b, o): return struct.unpack_from(">I", b, o)[0]
def u16(b, o): return struct.unpack_from(">H", b, o)[0]

def main():
    buf = bytearray(open(KERNEL, "rb").read())
    e_shoff, e_shentsize = u32(buf, 32), u16(buf, 46)
    e_shnum, e_shstrndx  = u16(buf, 48), u16(buf, 50)

    shdr = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        shdr.append({"name": u32(buf, o + 0), "offset": u32(buf, o + 16),
                     "size": u32(buf, o + 20), "link": u32(buf, o + 24),
                     "entsize": u32(buf, o + 36)})
    shstr_off = shdr[e_shstrndx]["offset"]
    def secname(sh):
        e = buf.index(b"\0", shstr_off + sh["name"])
        return buf[shstr_off + sh["name"]:e].decode()
    sec = {secname(sh): sh for sh in shdr}

    text, symtab, rela = sec[".text"], sec[".symtab"], sec[".rela.text"]
    strtab = shdr[symtab["link"]]
    text_foff = text["offset"]
    sym_off, sym_ent = symtab["offset"], symtab["entsize"]
    sym_n = symtab["size"] // sym_ent
    str_off = strtab["offset"]

    def sym_name(i):
        st_name = u32(buf, sym_off + i * sym_ent + 0)
        e = buf.index(b"\0", str_off + st_name)
        return buf[str_off + st_name:e].decode()
    def sym_value(i):
        return u32(buf, sym_off + i * sym_ent + 4)

    new_idx = None
    for i in range(sym_n):
        if sym_name(i) == INTERPOSER:
            new_idx = i
            break
    if new_idx is None:
        raise SystemExit("ABORT: %s not found (a3091dbg040.o linked?)" % INTERPOSER)

    rela_off, rela_ent = rela["offset"], rela["entsize"]
    rela_n = rela["size"] // rela_ent

    # Survey first: every badhardware relocation in the image, so a changed layout is
    # LOUD rather than silently retargeting nothing.
    found = []
    for i in range(rela_n):
        o = rela_off + i * rela_ent
        cur = u32(buf, o + 4) >> 8
        nm = sym_name(cur)
        if nm == "badhardware" or cur == new_idx:
            found.append((u32(buf, o + 0), o, cur, nm, sym_value(cur)))

    done = skip = 0
    for r_offset, o, cur_sym, nm, val in found:
        if cur_sym == new_idx:
            print("  [skip] @0x%05x already -> %s" % (r_offset, INTERPOSER)); skip += 1
            continue
        if val == SERVICE_BADHW:
            print("  [left] @0x%05x -> badhardware@0x%x (service; not ours)" % (r_offset, val))
            continue
        if r_offset != A3091_BADHW_CALL:
            raise SystemExit("ABORT: unexpected a3091 badhardware reloc @0x%05x "
                             "(expected 0x%05x) -- layout drifted, re-verify"
                             % (r_offset, A3091_BADHW_CALL))
        opc = bytes(buf[text_foff + r_offset - 2:text_foff + r_offset])
        if opc != b"\x4e\xb9":
            raise SystemExit("ABORT @0x%05x: expected jsr(4eb9) at -2, found %s"
                             % (r_offset, opc.hex()))
        if (u32(buf, o + 4) & 0xff) != R_68K_32:
            raise SystemExit("ABORT @0x%05x: reloc type is not R_68K_32" % r_offset)
        if val != A3091_BADHW_VALUE:
            raise SystemExit("ABORT @0x%05x: target is %s@0x%x, expected badhardware@0x%x"
                             % (r_offset, nm, val, A3091_BADHW_VALUE))
        struct.pack_into(">I", buf, o + 4, (new_idx << 8) | R_68K_32)
        print("  [ok]   @0x%05x  badhardware@0x%x -> %s (sym #%d)"
              % (r_offset, val, INTERPOSER, new_idx))
        done += 1

    if done + skip != 1:
        raise SystemExit("ABORT: expected exactly 1 a3091 badhardware call site, "
                         "handled %d (found %d badhardware relocs total)"
                         % (done + skip, len(found)))
    if done:
        open(KERNEL, "wb").write(buf)
    print("patch_a3091_badhardware: %d retargeted, %d already, service left alone -> %s"
          % (done, skip, KERNEL))

if __name__ == "__main__":
    main()
