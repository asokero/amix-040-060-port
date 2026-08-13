#!/usr/bin/env python3
# patch_b2_flip.py -- set the hat_cm_ram staging global of a linked kernel image
# (2026-07-23; spec = CM-PTE-WRITER-MATRIX.md stage table + the three B2 docs).
#
#   python3 patch_b2_flip.py <input-image> <output-image> [--wt]
#   python3 patch_b2_flip.py <image> --check
#
# DIRECTION REVERSED 2026-07-30.  The base link now ships hat_cm_ram = 0x20
# (copyback) by default, because ISSUE-38 closed on hardware and a probe-less
# copyback kernel finally boots.  So the interesting derived image today is the
# WRITE-THROUGH control (--wt, 0x20 -> 0x00), used for one-variable cache A/Bs.
# Without --wt the script still produces/asserts the copyback value, which keeps
# every older recipe in the docs working (it is now normally a no-op "[skip]").
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

CB, WT = 0x00000020, 0x00000000

argv = sys.argv[1:]
CHECK = "--check" in argv
WANT_WT = "--wt" in argv
argv = [a for a in argv if not a.startswith("--")]
if CHECK:
    if len(argv) != 1:
        raise SystemExit("usage: patch_b2_flip.py <image> --check")
    SRC, DST = argv[0], None
elif len(argv) == 2:
    SRC, DST = argv
else:
    raise SystemExit("usage: patch_b2_flip.py <input-image> <output-image> [--wt] | <image> --check")
WANT = WT if WANT_WT else CB

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
if cur not in (WT, CB):
    raise SystemExit("ABORT: hat_cm_ram @.data+0x%x holds 0x%08x, expected 0x00 or 0x20" % (val, cur))

NAME = {WT: "WRITETHROUGH", CB: "COPYBACK"}
if CHECK:
    print("hat_cm_ram @.data+0x%x = 0x%08x (%s)" % (val, cur, NAME[cur]))
    raise SystemExit(0)

if cur == WANT:
    print("  [skip] hat_cm_ram @.data+0x%x already 0x%08x (%s)" % (val, cur, NAME[cur]))
else:
    struct.pack_into(">I", buf, foff, WANT)
    print("  [ok]   hat_cm_ram @.data+0x%x: 0x%08x -> 0x%08x (%s -> %s)"
          % (val, cur, WANT, NAME[cur], NAME[WANT]))

open(DST, "wb").write(buf)
print("%s variant -> %s" % (NAME[WANT], DST))
