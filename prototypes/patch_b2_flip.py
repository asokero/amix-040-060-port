#!/usr/bin/env python3
# patch_b2_flip.py -- caches Step B2: produce a COPYBACK variant of a linked
# kernel image by flipping the hat_cm_ram staging global 0x00 -> 0x20
# (2026-07-23; spec = CM-PTE-WRITER-MATRIX.md stage table + the three B2 docs).
#
#   python3 patch_b2_flip.py <input-image> <output-image>
#
# Two artifact sets by design (CB-PAGE-LIFECYCLE-CLOSURE / A3091 spec runtime
# acceptance: "baseline smoke before the CM flip"): the normal relink output
# keeps hat_cm_ram=0x00 (WT + all B2 hooks live = the HW-session baseline);
# this script copies it and flips ONLY the one .data long, then the caller
# re-stamps the buildid.  Reverting B2 on hardware = boot the WT image.
#
# Locates hat_cm_ram via the symbol table (never a hardcoded offset), asserts
# the old value 0x00000000, fails closed on anything unexpected.

import struct, sys

if len(sys.argv) != 3:
    raise SystemExit("usage: patch_b2_flip.py <input-image> <output-image>")
SRC, DST = sys.argv[1], sys.argv[2]

CB = 0x00000020

def u16(b, o): return struct.unpack(">H", b[o:o+2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o+4])[0]

buf = bytearray(open(SRC, "rb").read())

e_shoff = u32(buf, 32); e_shentsize = u16(buf, 46)
e_shnum = u16(buf, 48); e_shstrndx = u16(buf, 50)
shdr = []
for i in range(e_shnum):
    o = e_shoff + i * e_shentsize
    shdr.append({"name": u32(buf, o), "addr": u32(buf, o+12),
                 "offset": u32(buf, o+16), "size": u32(buf, o+20),
                 "link": u32(buf, o+24), "entsize": u32(buf, o+36)})
shstr = shdr[e_shstrndx]["offset"]
def nm(sh):
    e = buf.index(b"\0", shstr + sh["name"])
    return buf[shstr + sh["name"]:e].decode()
sec = {nm(sh): sh for sh in shdr}
data, symtab = sec[".data"], sec[".symtab"]
strtab = shdr[symtab["link"]]

so, se, sn = symtab["offset"], symtab["entsize"], symtab["size"] // symtab["entsize"]
sto = strtab["offset"]
val = None
for i in range(sn):
    n = u32(buf, so + i*se)
    e = buf.index(b"\0", sto + n)
    if buf[sto + n:e] == b"hat_cm_ram":
        val = u32(buf, so + i*se + 4)
        break
if val is None:
    raise SystemExit("ABORT: hat_cm_ram symbol not found")

foff = data["offset"] + (val - data["addr"])
cur = u32(buf, foff)
if cur == CB:
    print("  [skip] hat_cm_ram @.data+0x%x already 0x%08x (copyback)" % (val, CB))
elif cur == 0:
    struct.pack_into(">I", buf, foff, CB)
    print("  [ok]   hat_cm_ram @.data+0x%x: 0x00000000 -> 0x%08x (WT -> COPYBACK)" % (val, CB))
else:
    raise SystemExit("ABORT: hat_cm_ram @.data+0x%x holds 0x%08x, expected 0 or 0x20" % (val, cur))

open(DST, "wb").write(buf)
print("B2 copyback variant -> %s" % DST)
