#!/usr/bin/env python3
# patch_rth1_hook.py -- route main's one call to vfs_mountroot through rth1_mountroot, the kernel
# half of the RTH1 root hint (docs/contracts/RTH1-ROOT-HINT.md, src/rth1.c; 2026-10-05).
#
#   patch_rth1_hook.py KERNEL             retarget; idempotent ([skip] when already done)
#   patch_rth1_hook.py --check KERNEL     verify a finished kernel carries the hook; writes nothing
#   patch_rth1_hook.py --queue-tbl BASE   print the objcopy argument that names sd's controller array
#
# THE EDIT.  One relocation word.  In main, `jsr vfs_mountroot` is 4eb9 followed by an absolute
# longword that an R_68K_32 relocation fills; the relocation's symbol index is changed from
# vfs_mountroot to rth1_mountroot.  rth1_mountroot calls rth1_apply and then vfs_mountroot itself,
# so the root is still mounted at the same point of main, after io_init has let sd register its
# controllers.  No instruction byte changes.
#
# Asserted before anything is written: exactly one R_68K_32 in main names vfs_mountroot (or,
# already patched, rth1_mountroot), with addend 0, on the operand of a `jsr <abs>.l`; and
# rth1_mountroot's own body calls vfs_mountroot -- otherwise the retarget would leave the root
# unmounted.  Works on any ET_REL that carries main, so the 68030 kit runs the same file.
#
# --queue-tbl: sd.o keeps its two controller records in a file-static .bss array.  The three
# accessors sdopen, sdqueue and sdhardwarename each `lea` it through one relocation; when they
# agree, the array is exposed as sd_queue_tbl for src/sdcardbase040.s (the way the driver line's
# a4091 pass does it, for kernels built without that pass).

import os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kelf import Elf, R_68K_32  # noqa: E402

HOOK, CALLEE, CALLER = "rth1_mountroot", "vfs_mountroot", "main"
QUEUE_LEAS = (0xD6D2, 0xD6FE, 0xD720)         # sdopen, sdqueue, sdhardwarename: `lea queue,%a0`


def u32(b, o): return struct.unpack(">I", b[o:o + 4])[0]


def text_extent(e, name):
    """[lo, hi) of a defined .text symbol: up to the next .text symbol with a higher value."""
    tidx = e.names.index(".text")
    vals, lo = set(), None
    for i in range(e.syn):
        s = e.sym(i)
        if s["shndx"] != tidx or s["info"] & 0xF == 3:     # skip the section symbol
            continue
        vals.add(s["value"])
        if s["name"] == name:
            if lo is not None and lo != s["value"]:
                raise SystemExit("ABORT: two definitions of %s" % name)
            lo = s["value"]
    if lo is None:
        raise SystemExit("ABORT: %s is not defined in .text" % name)
    hi = min([v for v in vals if v > lo] or [e.sec[".text"]["size"]])
    return lo, hi


def calls(e, rt, lo, hi, names):
    """The jsr-abs relocations in [lo, hi) whose global target is one of names: [(off, name)]."""
    out = []
    for off in sorted(rt):
        if not lo <= off < hi:
            continue
        _, si, typ, ad = rt[off]
        sec, val, name, glob = e.target(si, ad)
        if name in names:
            if typ != R_68K_32 or ad != 0 or e.text(off - 2, 2) != b"\x4e\xb9":
                raise SystemExit("ABORT: the reference to %s at .text+0x%x is not `jsr %s` "
                                 "(type %d, addend %d)" % (name, off, name, typ, ad))
            out.append((off, name))
    return out


def state(e):
    """(rt, the relocation offset in main, 'stock' or 'hooked')."""
    rt = e.rela(".rela.text")
    lo, hi = text_extent(e, CALLER)
    c = calls(e, rt, lo, hi, (CALLEE, HOOK))
    if len(c) != 1:
        raise SystemExit("ABORT: main references vfs_mountroot/rth1_mountroot %d times, want 1: %s"
                         % (len(c), ", ".join("0x%x %s" % x for x in c)))
    off, name = c[0]
    hlo, hhi = text_extent(e, HOOK)
    inner = calls(e, rt, hlo, hhi, (CALLEE,))
    if len(inner) != 1:
        raise SystemExit("ABORT: rth1_mountroot calls vfs_mountroot %d times, want 1" % len(inner))
    return rt, off, ("hooked" if name == HOOK else "stock")


def cmd_patch(path):
    e = Elf(path)
    rt, off, st = state(e)
    if st == "hooked":
        print("  [skip] main's jsr at .text 0x%x already calls rth1_mountroot" % (off - 2))
        return
    eo = rt[off][0]
    e.b[eo + 4:eo + 8] = struct.pack(">I", (e.index(HOOK) << 8) | R_68K_32)
    open(path, "wb").write(e.b)
    e2 = Elf(path)
    if state(e2)[2] != "hooked":
        raise SystemExit("ABORT: the retarget did not take")
    print("  [ok]   main's jsr at .text 0x%x: vfs_mountroot -> rth1_mountroot (RTH1 root hint)"
          % (off - 2))


def cmd_check(path):
    e = Elf(path)
    _, off, st = state(e)
    if st != "hooked":
        raise SystemExit("FAIL: main's jsr at .text 0x%x still calls vfs_mountroot" % (off - 2))
    data = e.sec[".data"]
    didx = e.names.index(".data")
    for name in ("rth1_used", "rth1_why"):
        s = e.sym(e.index(name))
        if s["shndx"] != didx:
            raise SystemExit("FAIL: %s is not in .data" % name)
        v = u32(e.b, data["offset"] + s["value"])
        if v != 0xFFFFFFFF:
            raise SystemExit("FAIL: %s is 0x%x in the image, want 0xffffffff (not run)" % (name, v))
    e.index("sdcardbase")
    print("  [ok]   RTH1 hook present: main's jsr at .text 0x%x calls rth1_mountroot, which calls "
          "vfs_mountroot; rth1_used/rth1_why unset; sdcardbase linked" % (off - 2))


def cmd_queue_tbl(path):
    e = Elf(path)
    rt = e.rela(".rela.text")
    qt = set()
    for site in QUEUE_LEAS:
        if e.text(site, 2) != b"\x41\xf9" or (site + 2) not in rt:
            raise SystemExit("ABORT: .text+0x%x is not sd's relocated `lea queue,%%a0`" % site)
        _, si, typ, ad = rt[site + 2]
        sec, off, _, _ = e.target(si, ad)
        qt.add((sec, off))
    if len(qt) != 1 or next(iter(qt))[0] != ".bss":
        raise SystemExit("ABORT: sd's three accessors do not agree on one .bss array: %s" % sorted(qt))
    print("sd_queue_tbl=.bss:0x%x,object,global" % next(iter(qt))[1])


def main():
    a = sys.argv[1:]
    if len(a) == 1 and not a[0].startswith("-"):
        cmd_patch(a[0])
    elif len(a) == 2 and a[0] == "--check":
        cmd_check(a[1])
    elif len(a) == 2 and a[0] == "--queue-tbl":
        cmd_queue_tbl(a[1])
    else:
        raise SystemExit("usage: patch_rth1_hook.py [--check|--queue-tbl] KERNEL")


main()
