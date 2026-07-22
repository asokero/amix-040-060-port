#!/usr/bin/env python3
# patch_config_cachefix.py -- ISSUE-21 fix: retarget _start's `jsr config` to the
# config_cachefix wrapper (2026-07-22).  Companion object prototypes/config040.s.
#
# _start (kernel entry 0x08000000) calls config() as the first C function via a
# single R_68K_32 relocation at .rela.text r_offset 0x26.  This retargets ONLY
# that relocation to config_cachefix (which disables the caches then tail-calls
# the real config via the relink alias config_orig=0x18f5c).  All other refs to
# the two `config` symbols (the separate bss data object at 0x10460; any later
# config() call) are left untouched -- same surgical approach as
# patch_a3091_dma.py, needed because `config` is not a unique symbol name.
#
# Asserts: the reloc at 0x26 currently targets a symbol named "config" whose
# st_value is 0x18f5c (the FUNCTION, not the bss object), and the 2 bytes at
# 0x24 are a jsr abs.l (0x4eb9).  Idempotent.  Run AFTER the relink (stock .text
# addresses unchanged by appended objects).

import struct, sys
KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"

JSR_CONFIG_ROFF = 0x26          # .rela.text r_offset of _start's jsr config operand
CONFIG_FUNC_VALUE = 0x18f5c     # st_value of the config FUNCTION (not the bss object)
WRAPPER = "config_cachefix"
R_68K_32 = 1

def u16(b, o): return struct.unpack(">H", b[o:o+2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o+4])[0]

def main():
    buf = bytearray(open(KERNEL, "rb").read())
    e_shoff, e_shent, e_shnum, e_shstr = u32(buf,32), u16(buf,46), u16(buf,48), u16(buf,50)
    sh = []
    for i in range(e_shnum):
        o = e_shoff + i*e_shent
        sh.append({"name":u32(buf,o),"type":u32(buf,o+4),"addr":u32(buf,o+12),
                   "offset":u32(buf,o+16),"size":u32(buf,o+20),"link":u32(buf,o+24),"entsize":u32(buf,o+36)})
    shstr = sh[e_shstr]["offset"]
    def snm(s):
        e = buf.index(b"\0", shstr+s["name"]); return buf[shstr+s["name"]:e].decode()
    sec = {snm(s): s for s in sh}
    text, rela, symtab = sec[".text"], sec[".rela.text"], sec[".symtab"]
    strtab = sh[symtab["link"]]
    sym_off, sym_ent = symtab["offset"], symtab["entsize"]
    str_off = strtab["offset"]
    text_foff = text["offset"]

    def sym_name(i):
        nm = u32(buf, sym_off+i*sym_ent); e = buf.index(b"\0", str_off+nm)
        return buf[str_off+nm:e].decode()
    def sym_value(i): return u32(buf, sym_off+i*sym_ent+4)

    wrap = None
    for i in range(symtab["size"]//sym_ent):
        if sym_name(i) == WRAPPER: wrap = i; break
    if wrap is None:
        raise SystemExit("ABORT: %s symbol not found (config040.o linked?)" % WRAPPER)

    rela_off, rela_ent, rela_n = rela["offset"], rela["entsize"], rela["size"]//rela["entsize"]
    for i in range(rela_n):
        o = rela_off + i*rela_ent
        if u32(buf, o) != JSR_CONFIG_ROFF:
            continue
        r_info = u32(buf, o+4); cur, rtype = r_info >> 8, r_info & 0xff
        opc = bytes(buf[text_foff + JSR_CONFIG_ROFF-2 : text_foff + JSR_CONFIG_ROFF])
        if opc != b"\x4e\xb9":
            raise SystemExit("ABORT: expected jsr(4eb9) at 0x24, found %s" % opc.hex())
        if rtype != R_68K_32:
            raise SystemExit("ABORT: reloc @0x26 type %d != R_68K_32" % rtype)
        if cur == wrap:
            print("  [skip] _start jsr config already -> %s" % WRAPPER); return
        nm, val = sym_name(cur), sym_value(cur)
        if nm != "config" or val != CONFIG_FUNC_VALUE:
            raise SystemExit("ABORT: reloc @0x26 targets %s@0x%x, expected config@0x%x"
                             % (nm, val, CONFIG_FUNC_VALUE))
        struct.pack_into(">I", buf, o+4, (wrap << 8) | R_68K_32)
        open(KERNEL, "wb").write(buf)
        print("  [ok]   _start jsr config@0x%x -> %s (sym #%d)" % (val, WRAPPER, wrap))
        return
    raise SystemExit("ABORT: reloc @0x26 (_start jsr config) not found")

main()
