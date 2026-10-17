#!/usr/bin/env python3
# patch_pgrsv_sites.py -- route page_get's ordinary callers through pgrsv_get, the free-page reserve
# of src/pgrsv.c (DRIVER-LINE-8; opt-in, relink-040-pgrsv.sh).
#
#   patch_pgrsv_sites.py KERNEL            retarget; idempotent ([skip] when already done)
#   patch_pgrsv_sites.py --check KERNEL    verify a finished kernel; writes nothing
#   patch_pgrsv_sites.py --aliases BASE    print the two objcopy --add-symbol arguments that name
#                                          page_get's file-static freemem_wait and max_page_get
#
# THE EDIT.  Relocation words only.  Every call to page_get is `jsr page_get` = 4eb9 + an absolute
# longword filled by an R_68K_32; the relocation's symbol index is changed from page_get to
# pgrsv_get at every site but the EXEMPT ones.  No instruction byte changes.
#
# EXEMPT keeps kernel memory on the direct path, as SVR4.2 does (seg_kmem.c sets P_NORESOURCELIM):
#   segkmem_alloc  every kmem_alloc/sptalloc page -- pageout's buffer-cache growth is one of them,
#                  and it is the allocation that must still succeed below the reserve;
#   hat_ptalloc,   page-table pages.  They are kernel memory too, and the mapping of a kernel page
#   hat_sdtalloc   (segkmem_alloc -> hat_memload -> hat_pteload) can need one, at interrupt level
#                  as well; hat_sdtalloc reports a failed allocation on the console.  Holding them
#                  at the reserve would move kernel failures earlier than stock, so they stay out;
#   page_delmem    memory removal at configuration time, not a consumer.
# Every other caller must be one this file KNOWS (CALLERS): a new caller in some future base aborts
# the pass instead of being classified by default.  The caller of a site is the FUNC symbol (global
# or file-static) it sits in; local labels such as LC%1 or Lhd_lookup are not FUNCs and are skipped.
#
# Asserted before anything is written: each site is `jsr <abs>.l`, type R_68K_32, addend 0; each
# EXEMPT caller has exactly one site; pgrsv_get is defined and calls page_get exactly once (else
# the retarget would lose the allocation).

import os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kelf import Elf, R_68K_32  # noqa: E402

CALLEE, HOOK = "page_get", "pgrsv_get"
EXEMPT = ("segkmem_alloc", "hat_ptalloc", "hat_sdtalloc", "page_delmem")
CALLERS = ("after:hat_devload", "anon_private", "anon_zero", "hat_dup", "pvn_kluster", "rfc_pageget",
           "rfc_writefill", "s5getapage", "segmap_pagecreate", "segu_get_orig", "ufs_getapage") + EXEMPT
STATICS = (("freemem_wait", "pgrsv_fmw", 0x52b9), ("max_page_get", "pgrsv_mpg", 0xb4b9))
STT_FUNC, STT_SECTION = 2, 3


def u16(b, o): return struct.unpack(">H", b[o:o + 2])[0]


def funcs_text(e):
    """Sorted [(value, size, name)] of the FUNC symbols, global or local, defined in .text."""
    tidx = e.names.index(".text")
    out = []
    for i in range(e.syn):
        s = e.sym(i)
        if s["shndx"] == tidx and s["info"] & 0xF == STT_FUNC:
            o = e.syo + i * e.sye
            out.append((s["value"], struct.unpack(">I", e.b[o + 8:o + 12])[0], s["name"]))
    return sorted(out)


def owner(gt, off):
    """The FUNC a site sits in.  A site past the end of the nearest FUNC below it (a body whose
    own symbol the base no longer carries) is named after:<that FUNC>."""
    best = None
    for v, sz, n in gt:
        if v <= off:
            best = (v, sz, n)
        else:
            break
    if best is None:
        return None
    v, sz, n = best
    return n if sz == 0 or off < v + sz else "after:" + n


def extent(gt, e, name):
    lo = [v for v, sz, n in gt if n == name]
    if len(lo) != 1:
        raise SystemExit("ABORT: %s is defined %d times in .text" % (name, len(lo)))
    hi = min([v for v, sz, n in gt if v > lo[0]] or [e.sec[".text"]["size"]])
    return lo[0], hi


def sites(e):
    """[(reloc offset, target name, caller)] for every relocation naming page_get or pgrsv_get."""
    rt = e.rela(".rela.text")
    gt = funcs_text(e)
    out = []
    for off in sorted(rt):
        _, si, typ, ad = rt[off]
        sec, val, name, glob = e.target(si, ad)
        if name not in (CALLEE, HOOK):
            continue
        caller = owner(gt, off)
        if caller == HOOK:
            continue                            # pgrsv_get's own call to page_get
        if typ != R_68K_32 or ad != 0 or e.text(off - 2, 2) != b"\x4e\xb9":
            raise SystemExit("ABORT: the reference to %s at .text+0x%x (in %s) is not `jsr %s` "
                             "(type %d, addend %d)" % (name, off, caller, name, typ, ad))
        if caller not in CALLERS:
            raise SystemExit("ABORT: %s calls page_get at .text+0x%x and is not a known caller; "
                             "classify it (CALLERS or EXEMPT) before running this pass" % (caller, off - 2))
        out.append((off, name, caller))
    return rt, gt, out


BTOPR = bytes.fromhex("068200000fff720ce2aa")    # page_get: addil #4095,%d2; moveq #12,%d1; lsrl %d1,%d2


def validate(e, rt, gt, ss):
    # pgrsv.c computes npages as (bytes + 0xfff) >> 12; the kernel's own page_get must do the same,
    # or the reserve would count in a different page than the allocator it guards.
    plo, phi = extent(gt, e, CALLEE)
    if BTOPR not in e.text(plo, min(phi - plo, 0x40)):
        raise SystemExit("ABORT: page_get's btopr is not +4095, >>12 (4 KiB pages) -- pgrsv.c's "
                         "PAGESHIFT would not match this kernel")
    for x in EXEMPT:
        n = [s for s in ss if s[2] == x]
        if len(n) != 1:
            raise SystemExit("ABORT: exempt caller %s has %d page_get sites, want 1" % (x, len(n)))
    lo, hi = extent(gt, e, HOOK)
    inner = []
    for off in sorted(rt):
        if lo <= off < hi:
            _, si, typ, ad = rt[off]
            if e.target(si, ad)[2] == CALLEE:
                inner.append(off)
    if len(inner) != 1:
        raise SystemExit("ABORT: pgrsv_get calls page_get %d times, want 1" % len(inner))


def cmd_patch(path):
    e = Elf(path)
    rt, gt, ss = sites(e)
    validate(e, rt, gt, ss)
    hidx = e.index(HOOK)
    todo = [s for s in ss if s[2] not in EXEMPT and s[1] == CALLEE]
    done = [s for s in ss if s[2] not in EXEMPT and s[1] == HOOK]
    bad = [s for s in ss if s[2] in EXEMPT and s[1] == HOOK]
    if bad:
        raise SystemExit("ABORT: an exempt caller already calls pgrsv_get: %s" % bad)
    if not todo:
        print("  [skip] all %d ordinary page_get sites already call pgrsv_get" % len(done))
        return
    if done:
        raise SystemExit("ABORT: half-patched base (%d done, %d not) -- start from a clean base"
                         % (len(done), len(todo)))
    for off, _, caller in todo:
        eo = rt[off][0]
        e.b[eo + 4:eo + 8] = struct.pack(">I", (hidx << 8) | R_68K_32)
    open(path, "wb").write(e.b)
    e2 = Elf(path)
    _, _, s2 = sites(e2)
    if any(s[1] != (CALLEE if s[2] in EXEMPT else HOOK) for s in s2):
        raise SystemExit("ABORT: the retarget did not take")
    for off, _, caller in todo:
        print("  [ok]   jsr at .text 0x%x in %s: page_get -> pgrsv_get" % (off - 2, caller))
    print("  [ok]   %d sites retargeted; exempt (direct page_get): %s"
          % (len(todo), ", ".join(EXEMPT)))


def cmd_check(path):
    e = Elf(path)
    rt, gt, ss = sites(e)
    validate(e, rt, gt, ss)
    wrong = [s for s in ss if s[1] != (CALLEE if s[2] in EXEMPT else HOOK)]
    if wrong:
        raise SystemExit("FAIL: %d page_get sites on the wrong path: %s"
                         % (len(wrong), ", ".join("%s@0x%x->%s" % (c, o - 2, n) for o, n, c in wrong)))
    data, didx = e.sec[".data"], e.names.index(".data")
    want = {"pgrsv_magic": 0x70677276, "pgrsv_pages": 20, "pgrsv_calls": 0, "pgrsv_waits": 0,
            "pgrsv_fails": 0}
    for name, v in sorted(want.items()):
        s = e.sym(e.index(name))
        got = struct.unpack(">I", e.b[data["offset"] + s["value"]:data["offset"] + s["value"] + 4])[0]
        if s["shndx"] != didx or got != v:
            raise SystemExit("FAIL: %s = 0x%x in the image, want 0x%x" % (name, got, v))
    for _, alias, _ in STATICS:
        e.index(alias)
    print("  [ok]   page-out reserve present: %d sites -> pgrsv_get, %s direct; pgrsv_pages 20, "
          "counters zero" % (len(ss) - len(EXEMPT), "/".join(EXEMPT)))


def cmd_aliases(path):
    """page_get's two file-statics, by the instruction that uses them: `addql #1,freemem_wait`
    (52b9) and `cmpl max_page_get,%d2` (b4b9).  Each must be the only reference of its kind."""
    e = Elf(path)
    rt, gt, _ = sites(e)
    lo, hi = extent(gt, e, CALLEE)
    for stat, alias, op in STATICS:
        hits = set()
        for off in sorted(rt):
            if not lo <= off < hi:
                continue
            _, si, typ, ad = rt[off]
            sec, val, name, _ = e.target(si, ad)
            if name == stat or (name is None and sec == ".bss"):
                if u16(e.text(off - 2, 2), 0) == op and sec == ".bss":
                    hits.add(val)
        if len(hits) != 1:
            raise SystemExit("ABORT: page_get's %s: %d candidates (%s)" % (stat, len(hits), sorted(hits)))
        print("%s=.bss:0x%x,object,global" % (alias, hits.pop()))


def main():
    a = sys.argv[1:]
    if len(a) == 1 and not a[0].startswith("-"):
        cmd_patch(a[0])
    elif len(a) == 2 and a[0] == "--check":
        cmd_check(a[1])
    elif len(a) == 2 and a[0] == "--aliases":
        cmd_aliases(a[1])
    else:
        raise SystemExit("usage: patch_pgrsv_sites.py [--check|--aliases] KERNEL")


main()
