#!/usr/bin/env python3
"""hatmap-nosdt-retarget.py -- hat_map's legacy segment-table growth -> hat_growsdt_user (ISSUE-110).

  hatmap-nosdt-retarget.py UNIX           patch the linked ET_REL kernel in place (idempotent)
  hatmap-nosdt-retarget.py --check UNIX   verify, write nothing; exit 1 if the kernel is not retargeted

src/hatmap_nosdt040.s defines hat_growsdt_user, which grows no legacy 030 segment table for a user address
space (the table's descriptors would land in the native root's entries A0..A7).  The .rela entries naming
hat_growsdt are found by symbol; only the one inside hat_map changes its symbol index, and no byte of .text
moves.  The check wants hat_growsdt_user named exactly once, from hat_map, and hat_growsdt named from hat_map
never.  The other callers of hat_growsdt (hat_init for the kernel address space, the dead stock bodies of
hat_dup/hat_exec/hat_swapout, and hat_growsdt_user's own tail call) are left as they are.
"""
import struct, sys

SHT_SYMTAB, SHT_RELA = 2, 4
SITE = 'hat_map'


def load(path):
    b = bytearray(open(path, 'rb').read())
    if b[:4] != b'\x7fELF' or b[4] != 1 or b[5] != 2 or struct.unpack_from('>H', b, 16)[0] != 1:
        sys.exit('hatmap-nosdt-retarget: %s is not an ELF32 big-endian ET_REL' % path)
    shoff, = struct.unpack_from('>I', b, 32)
    shentsize, shnum = struct.unpack_from('>HH', b, 46)
    sh = [struct.unpack_from('>IIIIIIIIII', b, shoff + i * shentsize) for i in range(shnum)]
    symtab = [s for s in sh if s[1] == SHT_SYMTAB]
    if len(symtab) != 1:
        sys.exit('hatmap-nosdt-retarget: %d symbol tables' % len(symtab))
    st = symtab[0]
    stroff = sh[st[6]][4]
    syms = []
    for i in range(st[5] // 16):
        name, value, size, info, other, shndx = struct.unpack_from('>IIIBBH', b, st[4] + 16 * i)
        syms.append((bytes(b[stroff + name:b.index(0, stroff + name)]).decode(), value, shndx, info))
    return b, sh, syms


def index_of(syms, name):
    hits = [i for i, s in enumerate(syms) if s[0] == name and s[2] != 0]
    if len(hits) != 1:
        sys.exit('hatmap-nosdt-retarget: %d defined symbols named %s' % (len(hits), name))
    return hits[0]


def callers(b, sh, syms, target):
    """(rela entry file offset, containing global function, patched-site bytes ok) for each entry against target."""
    out = []
    ti = [i for i, s in enumerate(syms) if s[0] == target]
    for s in sh:
        if s[1] != SHT_RELA:
            continue
        sec = s[7]
        data = sh[sec][4]
        funcs = sorted((v, n) for n, v, x, info in syms if x == sec and n and (info >> 4) == 1)
        for o in range(s[4], s[4] + s[5], 12):
            off, info, add = struct.unpack_from('>IIi', b, o)
            if info >> 8 in ti:
                fn = [n for v, n in funcs if v <= off]
                jsr = b[data + off - 2:data + off] == b'\x4e\xb9' and (info & 0xff) == 1 and add == 0
                out.append((o, fn[-1] if fn else '?', jsr))
    return out


def main():
    check = sys.argv[1:2] == ['--check']
    path = sys.argv[2] if check else (sys.argv[1] if len(sys.argv) == 2 else None)
    if not path:
        sys.exit(__doc__)
    b, sh, syms = load(path)
    user = index_of(syms, 'hat_growsdt_user')
    index_of(syms, 'hat_growsdt')
    left = [fn for o, fn, j in callers(b, sh, syms, 'hat_growsdt') if fn == SITE]
    done = [fn for o, fn, j in callers(b, sh, syms, 'hat_growsdt_user')]
    if check:
        ok = not left and done == [SITE]
        print('hatmap-nosdt-retarget: hat_growsdt_user named from %s; hat_growsdt from %s %d time(s) -- %s'
              % (done or 'nowhere', SITE, len(left), 'OK' if ok else 'NOT RETARGETED'))
        sys.exit(0 if ok else 1)
    todo = [(o, j) for o, fn, j in callers(b, sh, syms, 'hat_growsdt') if fn == SITE]
    if not todo:
        print('hatmap-nosdt-retarget: already retargeted' if done == [SITE] else
              'hatmap-nosdt-retarget: %s names hat_growsdt nowhere' % SITE)
        sys.exit(0 if done == [SITE] else 1)
    if len(todo) != 1 or not todo[0][1]:
        sys.exit('hatmap-nosdt-retarget: %s has %d hat_growsdt relocation(s); expected one `jsr abs.l` R_68K_32'
                 % (SITE, len(todo)))
    o = todo[0][0]
    off, info, add = struct.unpack_from('>IIi', b, o)
    struct.pack_into('>IIi', b, o, off, (user << 8) | (info & 0xff), add)
    open(path, 'wb').write(b)
    print('hatmap-nosdt-retarget: %s .text+0x%x hat_growsdt -> hat_growsdt_user' % (SITE, off))


if __name__ == '__main__':
    main()
