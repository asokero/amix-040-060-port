#!/usr/bin/env python3
"""stamp-cputype.py -- flip a linked 040-line kernel's `cputype` between 40 and 60.

  python3 tools/stamp-cputype.py <image> --check
  python3 tools/stamp-cputype.py <in-image> <out-image> --set <40|60>

WHY THIS EXISTS.  Every 68060 artifact this port has ever booted is its 68040 sibling with
one byte changed: `cputype` 40 -> 60 in .data.  The loader normally pokes that word itself
(unix_boot.c, pokesymlong), but an image is also handed to the bench and to silicon with the
value already in it, and until now the flip was done by hand.  A hand-poked word is exactly
the class of edit this tree refuses everywhere else: `cputype` gates fpu_save/fpu_restore/
fpu_setup, isp61_vec, the FPSP 060 call-outs and the ISSUE-10 cure, so a flip that lands on
the wrong address does not fail -- it produces a kernel that silently takes 68040 branches on
68060 silicon.

So the word is located through the symbol table, its section is required to be .data, the old
value is required to be one of {40, 60}, `pcr_boot` (the word immediately after it) is
required to still hold its 0xffffffff sentinel, and after the write the whole file is re-read
with every changed byte accounted for.
"""
import struct
import sys

VALUES = (40, 60)
SENTINEL = 0xFFFFFFFF
SHN_COMMON = 0xFFF2

argv = sys.argv[1:]
if len(argv) == 2 and argv[1] == "--check":
    SRC, DST, WANT = argv[0], None, None
elif len(argv) == 4 and argv[2] == "--set":
    SRC, DST, WANT = argv[0], argv[1], int(argv[3])
    if WANT not in VALUES:
        raise SystemExit("stamp-cputype: --set must be 40 or 60")
else:
    raise SystemExit("usage: stamp-cputype.py <image> --check\n"
                     "       stamp-cputype.py <in> <out> --set <40|60>")


def u16(b, o):
    return struct.unpack(">H", b[o:o+2])[0]


def u32(b, o):
    return struct.unpack(">I", b[o:o+4])[0]


buf = bytearray(open(SRC, "rb").read())
if buf[:4] != b"\x7fELF":
    raise SystemExit("ABORT: %s is not ELF" % SRC)
if u16(buf, 16) != 1:
    raise SystemExit("ABORT: %s is not ET_REL" % SRC)

e_shoff = u32(buf, 32)
e_shentsize, e_shnum, e_shstrndx = u16(buf, 46), u16(buf, 48), u16(buf, 50)
shdr = [buf[e_shoff + i*e_shentsize:e_shoff + (i+1)*e_shentsize] for i in range(e_shnum)]
shstr = u32(shdr[e_shstrndx], 16)


def sname(s):
    n = u32(s, 0)
    return bytes(buf[shstr + n:buf.index(b"\0", shstr + n)]).decode()


names = [sname(s) for s in shdr]
data_idx = names.index(".data")
d_addr, d_off = u32(shdr[data_idx], 12), u32(shdr[data_idx], 16)
symtab = shdr[names.index(".symtab")]
sy_off, sy_size, sy_link = u32(symtab, 16), u32(symtab, 20), u32(symtab, 24)
sy_ent = u32(symtab, 36)
str_off = u32(shdr[sy_link], 16)

found = {}
for i in range(sy_size // sy_ent):
    o = sy_off + i * sy_ent
    n = u32(buf, o)
    nm = bytes(buf[str_off + n:buf.index(b"\0", str_off + n)]).decode("latin1")
    if nm in ("cputype", "pcr_boot"):
        found.setdefault(nm, []).append((u32(buf, o + 4), u16(buf, o + 14)))

for nm in ("cputype", "pcr_boot"):
    if nm not in found:
        raise SystemExit("ABORT: no %s symbol -- this is not an 040-line kernel of this port" % nm)
    if len(found[nm]) != 1:
        raise SystemExit("ABORT: %s has %d definitions, expected 1" % (nm, len(found[nm])))
    if found[nm][0][1] != data_idx:
        raise SystemExit("ABORT: %s is not in .data (section %d)" % (nm, found[nm][0][1]))

a_cpu = found["cputype"][0][0]
a_pcr = found["pcr_boot"][0][0]
f_cpu = d_off + (a_cpu - d_addr)
f_pcr = d_off + (a_pcr - d_addr)
cur = u32(buf, f_cpu)
pcr = u32(buf, f_pcr)

if cur not in VALUES:
    raise SystemExit("ABORT: cputype @.data+0x%x holds %d, expected 40 or 60" % (a_cpu, cur))
if pcr != SENTINEL:
    raise SystemExit("ABORT: pcr_boot @.data+0x%x holds 0x%08x, not the 0x%08x sentinel -- "
                     "this image has already run, or the block moved" % (a_pcr, pcr, SENTINEL))

print("   cputype  @ .data+0x%06x = %d" % (a_cpu, cur))
print("   pcr_boot @ .data+0x%06x = 0x%08x (sentinel intact)" % (a_pcr, pcr))

if WANT is None:
    raise SystemExit(0)

before = bytes(buf)
struct.pack_into(">I", buf, f_cpu, WANT)
open(DST, "wb").write(buf)

back = open(DST, "rb").read()
if len(back) != len(before):
    raise SystemExit("ABORT: size changed %d -> %d" % (len(before), len(back)))
diff = [i for i in range(len(back)) if before[i] != back[i]]
stray = [i for i in diff if not (f_cpu <= i < f_cpu + 4)]
if stray:
    raise SystemExit("ABORT: %d byte(s) changed outside cputype: %s"
                     % (len(stray), ["0x%x" % s for s in stray[:8]]))
if u32(back, f_cpu) != WANT:
    raise SystemExit("ABORT: read-back does not hold %d" % WANT)
print("   [ok]   cputype %d -> %d; %d byte(s) differ, all inside cputype -> %s"
      % (cur, WANT, len(diff), DST))
