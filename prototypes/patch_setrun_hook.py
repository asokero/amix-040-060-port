#!/usr/bin/env python3
# patch_setrun_hook.py -- install the setrun(0x489c2) detour (see mainmarks.s).
# Overwrites setrun's first 8 bytes (linkw %fp,#0 ; moveml %d2/%a2,%sp@-) with
# `jmp setrun_hook` (4ef9 <addr>) + nop.  setrun_hook re-executes those two insns
# and jmps back to setrun+8.  Finds setrun_hook's vaddr from the ELF symbol table.
# Operates in place on build/unix-040-dbg, AFTER the relink.  Diagnostic only.

import struct, sys
KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040-dbg"
SETRUN = 0x489c2
OLD = b"\x4e\x56\x00\x00\x48\xe7\x20\x20"   # linkw %fp,#0 ; moveml %d2/%a2,%sp@-

def u16(b,o): return struct.unpack(">H", b[o:o+2])[0]
def u32(b,o): return struct.unpack(">I", b[o:o+4])[0]

def sections(b):
    sh=u32(b,32); ent=u16(b,46); n=u16(b,48); st=u16(b,50)
    so=u32(b, sh+st*ent+16)
    out={}
    for i in range(n):
        o=sh+i*ent; nm=u32(b,o); e=b.index(b"\0",so+nm)
        out[b[so+nm:e].decode()]=(u32(b,o+12), u32(b,o+16), u32(b,o+20), u32(b,o+4))  # addr,off,size,type
    return out

def sym_addr(b, secs, name):
    syoff=secs[".symtab"][1]; sysz=secs[".symtab"][2]
    stoff=secs[".strtab"][1]
    for o in range(syoff, syoff+sysz, 16):
        nm=u32(b,o); val=u32(b,o+4)
        e=b.index(b"\0", stoff+nm)
        if b[stoff+nm:e]==name.encode(): return val
    raise SystemExit("symbol %s not found" % name)

def text_off(secs): return secs[".text"][0], secs[".text"][1]

def main():
    b=bytearray(open(KERNEL,"rb").read())
    secs=sections(b)
    hook=sym_addr(b, secs, "setrun_hook")
    sa, so = text_off(secs)
    fo = so + (SETRUN - sa)
    cur=bytes(b[fo:fo+8])
    new=b"\x4e\xf9"+struct.pack(">I",hook)+b"\x4e\x71"   # jmp hook ; nop
    if cur==new:
        print("  [skip] setrun detour already installed"); return
    if cur!=OLD:
        raise SystemExit("ABORT setrun@0x%x: found %s expected %s" % (SETRUN,cur.hex(),OLD.hex()))
    b[fo:fo+8]=new
    open(KERNEL,"wb").write(b)
    print("  [ok] setrun@0x%05x -> jmp setrun_hook(0x%05x) + nop" % (SETRUN, hook))

main()
