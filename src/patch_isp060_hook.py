#!/usr/bin/env python3
# patch_isp060_hook.py -- send isp61_vec's declines to Motorola's ISP (DRIVER-LINE-9; opt-in,
# relink-040-isp060.sh).
#
#   patch_isp060_hook.py KERNEL            retarget; idempotent ([skip] when already done)
#   patch_isp060_hook.py --check KERNEL    verify a finished kernel; writes nothing
#
# THE EDIT.  One relocation word.  Every decline path of src/isp61_060.s ends at its single
# `jmp nullvect` (Lisp_stock), with the raw frame and all registers restored.  That relocation's
# symbol index becomes isp060_unimp (src/isp060_glue.s), which hands a user-origin vector-61
# frame on a 68060 to the package and sends everything else to nullvect itself.  No instruction
# byte changes; isp61's accepted forms are untouched.
#
# Asserted before anything is written: exactly one R_68K_32 inside isp61_vec names nullvect (or,
# already patched, isp060_unimp), addend 0, on the operand of `jmp <abs>.l`; isp060_unimp's own
# entry jumps to nullvect (its stock exit) once within its first 0x40 bytes; M68Kvec[61] still names isp61_vec.

import os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kelf import Elf, R_68K_32  # noqa: E402

VEC, OLD, NEW = "isp61_vec", "nullvect", "isp060_unimp"
STT_SECTION = 3


def extent(e, name):
    tidx = e.names.index(".text")
    vals, lo = set(), None
    for i in range(e.syn):
        s = e.sym(i)
        if s["shndx"] != tidx or s["info"] & 0xF == STT_SECTION or s["info"] >> 4 != 1:
            continue                    # globals only: the units keep their L-labels as locals
        vals.add(s["value"])
        if s["name"] == name:
            lo = s["value"]
    if lo is None:
        raise SystemExit("ABORT: %s is not a global .text symbol" % name)
    hi = min([v for v in vals if v > lo] or [e.sec[".text"]["size"]])
    return lo, hi


def refs(e, rt, lo, hi, names):
    out = []
    for off in sorted(rt):
        if lo <= off < hi:
            _, si, typ, ad = rt[off]
            n = e.target(si, ad)[2]
            if n in names:
                out.append((off, n, typ, ad))
    return out


def state(e):
    rt = e.rela(".rela.text")
    lo, hi = extent(e, VEC)
    r = refs(e, rt, lo, hi, (OLD, NEW))
    if len(r) != 1:
        raise SystemExit("ABORT: isp61_vec references nullvect/isp060_unimp %d times, want 1" % len(r))
    off, name, typ, ad = r[0]
    if typ != R_68K_32 or ad != 0 or e.text(off - 2, 2) != b"\x4e\xf9":
        raise SystemExit("ABORT: isp61_vec's reference at .text+0x%x is not `jmp %s`" % (off, name))
    # the hook's own exits: nullvect for what it declines, the package for the rest
    nlo, nhi = extent(e, NEW)
    first = refs(e, rt, nlo, min(nhi, nlo + 0x40), (OLD,))
    if len(first) != 1:
        raise SystemExit("ABORT: isp060_unimp's own stock exit (jmp nullvect within 0x40) found %d "
                         "times, want 1" % len(first))
    # M68Kvec[61] -> isp61_vec (the fast path stays first)
    vbase = e.sym(e.index("M68Kvec"))["value"]
    v61 = rt.get(vbase + 61 * 4)
    if v61 is None or e.target(v61[1], v61[3])[2] != VEC:
        raise SystemExit("ABORT: M68Kvec[61] does not name isp61_vec")
    return rt, off, ("hooked" if name == NEW else "stock")


def cmd_patch(path):
    e = Elf(path)
    rt, off, st = state(e)
    if st == "hooked":
        print("  [skip] isp61_vec's decline at .text 0x%x already goes to isp060_unimp" % (off - 2))
        return
    eo = rt[off][0]
    e.b[eo + 4:eo + 8] = struct.pack(">I", (e.index(NEW) << 8) | R_68K_32)
    open(path, "wb").write(e.b)
    if state(Elf(path))[2] != "hooked":
        raise SystemExit("ABORT: the retarget did not take")
    print("  [ok]   isp61_vec's decline at .text 0x%x: nullvect -> isp060_unimp (68060 ISP)" % (off - 2))


def cmd_check(path):
    e = Elf(path)
    _, off, st = state(e)
    if st != "hooked":
        raise SystemExit("FAIL: isp61_vec's decline at .text 0x%x still goes to nullvect" % (off - 2))
    data, didx = e.sec[".data"], e.names.index(".data")
    s = e.sym(e.index("i60_magic"))
    v = struct.unpack(">I", e.b[data["offset"] + s["value"]:data["offset"] + s["value"] + 4])[0]
    if s["shndx"] != didx or v != 0x49533630:
        raise SystemExit("FAIL: i60_magic is 0x%x, want 0x49533630 (\"IS60\")" % v)
    print("  [ok]   ISP hook present: isp61_vec declines -> isp060_unimp; M68Kvec[61] = isp61_vec; "
          "i60_magic IS60")


def main():
    a = sys.argv[1:]
    if len(a) == 1 and not a[0].startswith("-"):
        cmd_patch(a[0])
    elif len(a) == 2 and a[0] == "--check":
        cmd_check(a[1])
    else:
        raise SystemExit("usage: patch_isp060_hook.py [--check] KERNEL")


main()
