#!/usr/bin/env python3
# patch_btrace_on.py -- flip the DBG kernel's diagnostic flags to 1.  base/quiet
# leave them 0 (silent).
#   btrace_on (2026-07-20)  early-boot serial phase trace (btrace.s)
#   kdbg_on   (2026-07-31)  the VM diagnostic cmn_err sites in the genuine-fix
#                           objects (kdbg040.s) -- what makes the BASE kernel quiet
#
# btrace.s ships btrace_on = 0 (a .long in .data) so the base/quiet kernels are
# behaviour-identical.  This runs ONLY in relink-040-dbg.sh, on the FINAL dbg
# image, resolving btrace_on's address in that image's symbol table (its .data
# offset shifts under dbg's extra objects).  Sets the whole long to 1; btrace_mark
# does `tstl btrace_on` so any nonzero value enables the trace.
#
# Idempotent (already-1 is fine).  Aborts if the symbol is missing.

import struct, sys
KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040-dbg"

def u16(b, o): return struct.unpack(">H", b[o:o+2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o+4])[0]

def main():
    buf = bytearray(open(KERNEL, "rb").read())
    e_shoff, e_shentsize, e_shnum, e_shstrndx = u32(buf,32), u16(buf,46), u16(buf,48), u16(buf,50)

    shdr = []
    for i in range(e_shnum):
        o = e_shoff + i*e_shentsize
        shdr.append({"name":u32(buf,o), "offset":u32(buf,o+16),
                     "size":u32(buf,o+20), "link":u32(buf,o+24), "entsize":u32(buf,o+36)})
    shstr = shdr[e_shstrndx]["offset"]
    def secname(sh):
        e = buf.index(b"\0", shstr+sh["name"]); return buf[shstr+sh["name"]:e].decode()
    sec = {secname(sh): sh for sh in shdr}

    symtab = sec[".symtab"]; strtab = shdr[symtab["link"]]
    sym_off, sym_ent = symtab["offset"], symtab["entsize"]
    str_off = strtab["offset"]

    # sections whose addr==0 in this relocatable image; file data lives at sh_offset.
    # A .data symbol's file position = <.data sh_offset> + st_value.
    data = sec[".data"]; data_foff = data["offset"]

    target = None
    for i in range(symtab["size"] // sym_ent):
        o = sym_off + i*sym_ent
        st_name = u32(buf, o); e = buf.index(b"\0", str_off+st_name)
        if buf[str_off+st_name:e] == FLAG.encode():
            target = (u32(buf, o+4), u16(buf, o+14))   # (st_value, st_shndx)
            break
    if target is None:
        raise SystemExit("ABORT: %s symbol not found (its object linked?)" % FLAG)

    st_value, st_shndx = target
    # confirm it is in .data
    data_idx = shdr.index(data)
    if st_shndx != data_idx:
        raise SystemExit("ABORT: %s shndx %d != .data %d" % (FLAG, st_shndx, data_idx))

    fo = data_foff + st_value
    cur = u32(buf, fo)
    if cur == 1:
        print("  [skip] %s already 1 @0x%x" % (FLAG, st_value)); return
    if cur != 0:
        raise SystemExit("ABORT: %s = 0x%08x, expected 0 (or 1)" % (FLAG, cur))
    struct.pack_into(">I", buf, fo, 1)
    open(KERNEL, "wb").write(buf)
    print("  [ok]   %s 0 -> 1 @0x%x (%s)" % (FLAG, st_value, WHAT[FLAG]))

WHAT = {"btrace_on": "DBG early-boot serial phase trace enabled",
        "kdbg_on":   "DBG VM diagnostics enabled (base/quiet stay silent)"}
for FLAG in ("btrace_on", "kdbg_on"):
    main()
