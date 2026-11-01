#!/usr/bin/env python3
"""swapguard-retarget.py -- route swapadd through swapadd_guarded (src/swapguard.c, ISSUE-111).

  swapguard-retarget.py UNIX           patch the linked ET_REL kernel in place (idempotent)
  swapguard-retarget.py --check UNIX   verify, write nothing; exit 1 if the kernel is not retargeted

Three kinds of .rela entry change their symbol index, nothing else (no byte of .text moves):
  * every call of swapadd outside swg_swapadd -> swapadd_guarded.  In the base (relink-040.sh) the callers are
    swapconf, swapctl and swapfunc, as on the 68030 kernel; relink-040-f6.sh --swa later moves swapconf's call to the
    operand latch swa_latch and points the latch's own call at swapadd_guarded (src/patch_swapadd.py), so the
    finished kernel's callers are swa_latch, swapctl and swapfunc;
  * the initializer of swg_swapadd (src/swapguard.c's pointer to swapadd) -> swapadd;
  * swapadd's kmem_zalloc of the anon array -> swapguard_take.  It is the kmem_zalloc call in swapadd whose
    size was just shifted left by four (npages * 16): `asll #4,%d2; movel %d2,%sp@-; jsr kmem_zalloc`.
Every entry is found by symbol and by that instruction pattern, never by a fixed address.  The check wants
swapadd and its alias swapadd_real (when defined) named only from swg_swapadd, swapadd_guarded named from one of
the two caller sets above, swapguard_take named once (from swapadd) and swapguard_swapadd named from nowhere.  The
68030 kernel's tool (amigaux/amix kernel/k30/tools/swapguard-retarget.py) is the same but for the alias and the second set.
"""
import struct, sys

SHT_SYMTAB, SHT_RELA = 2, 4
CALLERS = (('swapconf', 'swapctl', 'swapfunc'), ('swa_latch', 'swapctl', 'swapfunc'))
TARGETS = ('swapadd', 'swapadd_real')
ANON_CALL = bytes.fromhex('e9822f024eb9')      # asll #4,%d2; movel %d2,%sp@-; jsr <abs32>


def load(path):
    b = bytearray(open(path, 'rb').read())
    if b[:4] != b'\x7fELF' or b[4] != 1 or b[5] != 2 or struct.unpack_from('>H', b, 16)[0] != 1:
        sys.exit('swapguard-retarget: %s is not an ELF32 big-endian ET_REL' % path)
    shoff, = struct.unpack_from('>I', b, 32)
    shentsize, shnum = struct.unpack_from('>HH', b, 46)
    sh = [struct.unpack_from('>IIIIIIIIII', b, shoff + i * shentsize) for i in range(shnum)]
    symtab = [s for s in sh if s[1] == SHT_SYMTAB]
    if len(symtab) != 1:
        sys.exit('swapguard-retarget: %d symbol tables' % len(symtab))
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
        sys.exit('swapguard-retarget: %d defined symbols named %s' % (len(hits), name))
    return hits[0]


def entries(b, sh, syms, names):
    """(rela entry file offset, containing function, target name, offset in its section, section) for every
    .rela entry against one of `names`"""
    out = []
    want = {i: s[0] for i, s in enumerate(syms) if s[0] in names}
    for s in sh:
        if s[1] != SHT_RELA:
            continue
        sec = s[7]                                   # sh_info: the section the relocations apply to
        funcs = sorted((v, n) for n, v, x, info in syms if x == sec and n and (info & 15) in (0, 1, 2))
        for o in range(s[4], s[4] + s[5], 12):
            off, info, add = struct.unpack_from('>IIi', b, o)
            if info >> 8 in want:
                fn = [n for v, n in funcs if v <= off]
                out.append((o, fn[-1] if fn else '?', want[info >> 8], off, sec))
    return out


def anon_site(b, sh, e):
    o, fn, name, off, sec = e
    p = sh[sec][4] + off - 4
    return fn in TARGETS and name in ('kmem_zalloc', 'swapguard_take') and bytes(b[p - 2:p + 4]) == ANON_CALL


def main():
    check = sys.argv[1:2] == ['--check']
    path = sys.argv[2] if check else (sys.argv[1] if len(sys.argv) == 2 else None)
    if not path:
        sys.exit(__doc__)
    b, sh, syms = load(path)
    ix = {n: index_of(syms, n) for n in ('swapadd', 'swapadd_guarded', 'swapguard_swapadd', 'swapguard_take')}
    names = TARGETS + ('swapadd_guarded', 'swapguard_swapadd', 'swapguard_take', 'kmem_zalloc')
    es = entries(b, sh, syms, names)
    named = lambda n: sorted(fn for o, fn, t, off, sec in es if t == n)
    anon = [e for e in es if anon_site(b, sh, e)]
    if check:
        direct = sorted(named('swapadd') + named('swapadd_real'))
        ok = (direct == ['swg_swapadd'] and tuple(named('swapadd_guarded')) in CALLERS
              and named('swapguard_take') in (['swapadd'], ['swapadd_real']) and named('swapguard_swapadd') == []
              and len(anon) == 1 and anon[0][2] == 'swapguard_take')
        print('swapguard-retarget: swapadd/swapadd_real from %s; swapadd_guarded from %s; swapguard_take from %s -- %s'
              % (direct or 'nowhere', named('swapadd_guarded') or 'nowhere',
                 named('swapguard_take') or 'nowhere', 'OK' if ok else 'NOT RETARGETED'))
        sys.exit(0 if ok else 1)
    if len(anon) != 1:
        sys.exit('swapguard-retarget: %d anon-array kmem_zalloc calls in swapadd (want 1)' % len(anon))
    todo = []
    for o, fn, t, off, sec in es:
        if t in TARGETS and fn != 'swg_swapadd':
            todo.append((o, ix['swapadd_guarded'], fn))
        elif t == 'swapguard_swapadd' and fn == 'swg_swapadd':
            todo.append((o, ix['swapadd'], fn))
    if anon[0][2] == 'kmem_zalloc':
        todo.append((anon[0][0], ix['swapguard_take'], anon[0][1]))
    if not todo:
        print('swapguard-retarget: already retargeted')
        return
    callers = sorted(fn for o, i, fn in todo if i == ix['swapadd_guarded'])
    if callers and tuple(callers) != CALLERS[0]:
        sys.exit('swapguard-retarget: swapadd called from %s, not %s' % (callers, list(CALLERS[0])))
    moved = [fn for o, i, fn in todo if i == ix['swapadd']]
    take = [fn for o, i, fn in todo if i == ix['swapguard_take']]
    for o, i, fn in todo:
        off, info, add = struct.unpack_from('>IIi', b, o)
        struct.pack_into('>IIi', b, o, off, (i << 8) | (info & 0xff), add)
    open(path, 'wb').write(b)
    print('swapguard-retarget: %d relocations: %s -> swapadd_guarded; %s -> swapadd; %s\'s anon kmem_zalloc '
          '-> swapguard_take' % (len(todo), ' '.join(callers) or '-', ' '.join(moved) or '-', ' '.join(take) or '-'))


if __name__ == '__main__':
    main()
