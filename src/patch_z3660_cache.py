#!/usr/bin/env python3
# patch_z3660_cache.py -- stamp the z3660_cache arm into a linked kernel image.
#
#   python3 patch_z3660_cache.py <image> --check
#   python3 patch_z3660_cache.py <image> --set <0|40|60>
#
# WHAT IT IS FOR.  The piscsi driver's cache-maintenance knob is a C tentative
# definition (amix-z3660scsi/src/z3660.c:320), so an unmodified link leaves it a COMMON
# symbol with no file storage and the only way to change it is /dev/kmem on a running
# multiuser system.  src/z3660_cache_arm.s gives it a .data home; this script writes the
# value into that home and then proves, on the finished image, that the write reached the
# driver rather than a stray copy.
#
# THE ASSERTION IS THE POINT.  Four ways this can silently do nothing, all of which the
# linker accepts without a word:
#
#   1. z3660_cache_arm.o is not in the link at all -- the symbol stays COMMON, the driver
#      still reads a bss zero, and the image looks stamped because nothing was checked.
#   2. it IS in the link but the driver object is not, so the value is written to a word
#      no code reads.
#   3. the block moved and a hardcoded offset wrote into a neighbour.
#   4. the write happened but was superseded by a later `ld -r` in the pipeline.
#
# So: the symbol is located through the symbol table, its section index is required to be
# .data (SHN_COMMON is a hard refusal -- that IS case 1), the magic word in front of it is
# required to read 'ZCA!', the witness word behind it is stamped too and required to agree,
# the driver is required to be present in the same image, and the whole file is re-read
# after the write with every changed byte accounted for.  Run it LAST, after every link.

import struct
import sys

VALUES = (0, 40, 60)
MAGIC = 0x5A434121                      # 'ZCA!'
SHN_COMMON = 0xFFF2

argv = sys.argv[1:]
if len(argv) == 2 and argv[1] == "--check":
    IMG, WANT = argv[0], None
elif len(argv) == 3 and argv[1] == "--set":
    IMG, WANT = argv[0], int(argv[2])
    if WANT not in VALUES:
        raise SystemExit("patch_z3660_cache: --set must be one of %s" % (VALUES,))
else:
    raise SystemExit("usage: patch_z3660_cache.py <image> --check | <image> --set <0|40|60>")


def u16(b, o):
    return struct.unpack(">H", b[o:o+2])[0]


def u32(b, o):
    return struct.unpack(">I", b[o:o+4])[0]


buf = bytearray(open(IMG, "rb").read())
if buf[:4] != b"\x7fELF":
    raise SystemExit("ABORT: %s is not ELF" % IMG)

e_shoff = u32(buf, 32)
e_shentsize, e_shnum, e_shstrndx = u16(buf, 46), u16(buf, 48), u16(buf, 50)
shdr = []
for i in range(e_shnum):
    o = e_shoff + i * e_shentsize
    shdr.append({"name": u32(buf, o), "addr": u32(buf, o+12), "offset": u32(buf, o+16),
                 "size": u32(buf, o+20), "link": u32(buf, o+24), "entsize": u32(buf, o+36)})
shstr = shdr[e_shstrndx]["offset"]


def secname(sh):
    e = buf.index(b"\0", shstr + sh["name"])
    return buf[shstr + sh["name"]:e].decode()


names = [secname(sh) for sh in shdr]
sec = dict(zip(names, shdr))
data_idx = names.index(".data")
data, symtab = sec[".data"], sec[".symtab"]
strtab = shdr[symtab["link"]]
so, se, sn = symtab["offset"], symtab["entsize"], symtab["size"] // symtab["entsize"]
sto = strtab["offset"]

syms = {}
for i in range(sn):
    n = u32(buf, so + i*se)
    e = buf.index(b"\0", sto + n)
    name = buf[sto + n:e].decode("latin1")
    if name:
        syms.setdefault(name, []).append((u32(buf, so + i*se + 4), u16(buf, so + i*se + 14)))

WANTED = ("zc_magic", "z3660_cache", "zc_armed")
for s in WANTED:
    if s not in syms:
        raise SystemExit("ABORT: %s is not defined -- src/z3660_cache_arm.s is not in the link" % s)
    if len(syms[s]) != 1:
        raise SystemExit("ABORT: %s has %d definitions, expected exactly 1" % (s, len(syms[s])))

for s in WANTED:
    val, shndx = syms[s][0]
    if shndx == SHN_COMMON:
        raise SystemExit("ABORT: %s is still COMMON -- the definition did not absorb it, so the "
                         "driver reads a bss zero no matter what this script writes" % s)
    if shndx != data_idx:
        raise SystemExit("ABORT: %s is in section %d, expected .data (%d)" % (s, shndx, data_idx))

# The driver has to be in the same image, or the knob has no reader.
if "z3660queue" not in syms:
    raise SystemExit("ABORT: z3660queue is not defined -- this image has no piscsi driver, so "
                     "z3660_cache has no reader")

a_magic = syms["zc_magic"][0][0]
a_cache = syms["z3660_cache"][0][0]
a_armed = syms["zc_armed"][0][0]
if (a_cache, a_armed) != (a_magic + 4, a_magic + 8):
    raise SystemExit("ABORT: block layout is magic/+4/+8 by construction, got %x/%x/%x"
                     % (a_magic, a_cache, a_armed))


def foff(addr):
    return data["offset"] + (addr - data["addr"])


magic = u32(buf, foff(a_magic))
if magic != MAGIC:
    raise SystemExit("ABORT: zc_magic reads 0x%08x, expected 0x%08x ('ZCA!')" % (magic, MAGIC))

cur = u32(buf, foff(a_cache))
armed = u32(buf, foff(a_armed))
if cur not in VALUES or armed not in VALUES:
    raise SystemExit("ABORT: z3660_cache/zc_armed hold 0x%08x/0x%08x, expected one of %s"
                     % (cur, armed, VALUES))
if cur != armed:
    raise SystemExit("ABORT: z3660_cache %d and its witness zc_armed %d disagree" % (cur, armed))

ARM = {0: "arm A (cache maintenance OFF -- the shipping default)",
       40: "arm B/040 (68040 DC maintenance)",
       60: "arm B/060 (68060 DC maintenance)"}

print("   zc_magic     @ .data+0x%06x = %08x 'ZCA!'" % (a_magic, magic))
print("   z3660_cache  @ .data+0x%06x = %-3d  %s" % (a_cache, cur, ARM[cur]))
print("   zc_armed     @ .data+0x%06x = %-3d  (witness)" % (a_armed, armed))
if "z3660eth_cache" in syms:
    ev, esh = syms["z3660eth_cache"][0]
    print("   z3660eth_cache: %s -- deliberately NOT armed (single variable)"
          % ("COMMON, zeroed into bss" if esh == SHN_COMMON else "in section %d" % esh))

if WANT is None:
    raise SystemExit(0)

if cur == WANT:
    print("   [skip] already %d" % WANT)
    raise SystemExit(0)

before = bytes(buf)
struct.pack_into(">I", buf, foff(a_cache), WANT)
struct.pack_into(">I", buf, foff(a_armed), WANT)
open(IMG, "wb").write(buf)

back = open(IMG, "rb").read()
if len(back) != len(before):
    raise SystemExit("ABORT: size changed %d -> %d" % (len(before), len(back)))
diff = [i for i in range(len(back)) if before[i] != back[i]]
allowed = set(range(foff(a_cache), foff(a_cache) + 4)) | set(range(foff(a_armed), foff(a_armed) + 4))
stray = [i for i in diff if i not in allowed]
if stray:
    raise SystemExit("ABORT: %d byte(s) changed outside the two words: %s"
                     % (len(stray), ["0x%x" % s for s in stray[:8]]))
if u32(back, foff(a_cache)) != WANT or u32(back, foff(a_armed)) != WANT:
    raise SystemExit("ABORT: read-back does not hold %d" % WANT)
print("   [ok]   z3660_cache %d -> %d  (%s); %d byte(s) differ, all inside the two words"
      % (cur, WANT, ARM[WANT], len(diff)))
