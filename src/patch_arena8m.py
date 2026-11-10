#!/usr/bin/env python3
# patch_arena8m.py -- ISSUE-80: grow the kernel VA arena (sptmap/kvseg at syssegs 0x40040000) from
# 4 MB to 8 MB, so that a 128 MB machine keeps arena headroom under NFS load (2026-10-30).
#
#   patch_arena8m.py KERNEL           write the layout; idempotent ([skip] when already done)
#   patch_arena8m.py --check KERNEL   say which layout KERNEL carries; write nothing
#
# THE DEFECT.  The arena is 1024 4 KiB clicks.  kvm_init maps the page-frame database and hash
# into it permanently, and that map grows with RAM: about 482 clicks at 128 MB.  On solon (060 HW,
# 128 MB) 991 clicks are used at idle, and a heavy NFS tar wedges in clget's KM_SLEEP
# kmem_alloc(8800) when no 3-click extent is left.  At 64 MB (unix_boot040 -m 64) the same tar
# passes.  KNOWN-ISSUES.md ISSUE-80; the route is Codex's private ISSUE80-ARENA-ROUTE-CODEX-RESULT.md
# §Q4.
#
# THE LAYOUT.  Everything stays in 4 KiB clicks and syssegs stays at 0x40040000:
#   mlsetup     mfree(sptmap, 0x400 -> 0x800, syssegs click)            the map's extent
#   kvm_init    segkmem_create(kas, syssegs, 0x400000 -> 0x800000, kvseg) the segment's size
#   sysseginit  loop bound 1023 -> 2047: 32 pointer descriptors and 2048 linear leaf PTEs (8 KiB).
#               The return value already follows the loop, so kvm_init's first free click moves
#               on by two pages instead of one.
#   kvsegmap    ABS 0x40440000 -> 0x40840000, which is the end of the new arena
#   kvsegu      ABS 0x48440000 -> 0x48840000; segmap's window keeps its 128 MB, so the segu
#               windows move with it and the two cannot overlap
#   kseg/unkseg the ksegtbl key (VA - syssegs) >> 17 -> >> 18.  ksegtbl is 32 bytes, one byte per
#               key.  kseg allocates through ptmalloc(sptmap, n, 0x3f), whose start is aligned to
#               64 clicks (3B2 os/machdep.c, ptmalloc), i.e. 256 KiB under 4 KiB clicks, so >> 18
#               keeps every key distinct and 8 MB needs keys 0..31 only.  Codex's §Q4 grew the
#               table to 64 bytes instead; the shift is the same-size form of that change.
#   hat_pteload the port's segmap probe window [kvsegmap+0x8000, +0xa000), compared as two
#               immediates, moves with kvsegmap (port images only; absent from stock).
#
# Every site is found by its symbol and its exact old bytes, and by the relocations around it.
# Every site must be all old or all new; a mixture aborts.  Nothing else changes: the patch writes
# immediates and two symbol values, adds no code and moves no section.
#
# Not here: ISSUE-82's wakeup (src/patch_freepool_wake.py), which relink-040-arena8m.sh applies
# with this one.

import os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kelf import Elf, u32  # noqa: E402

SHN_ABS = 0xFFF1
OLD_SEGMAP, NEW_SEGMAP = 0x40440000, 0x40840000
OLD_SEGU, NEW_SEGU = 0x48440000, 0x48840000


def die(msg):
    raise SystemExit("ABORT: " + msg)


class Site(object):
    """A run of bytes at a .text offset, old and new form."""

    def __init__(self, what, off, old, new):
        self.what, self.off, self.old, self.new = what, off, bytes(old), bytes(new)


def text_sym(e, name):
    tidx = e.names.index(".text")
    hits = [e.sym(i)["value"] for i in range(e.syn)
            if e.sym(i)["name"] == name and e.sym(i)["shndx"] == tidx]
    if len(hits) != 1:
        die("want exactly one %s in .text, found %d" % (name, len(hits)))
    return hits[0]


def reloc_to(e, rt, off, name):
    if off not in rt:
        return False
    _, sidx, typ, add = rt[off]
    return typ == 1 and e.sym(sidx)["name"] == name and add == 0


def find(e, rt, fn, span, forms, checks, what):
    """The one offset in [fn, fn+span) where either form occurs and every check holds."""
    base = e.sec[".text"]["offset"]
    body = bytes(e.b[base + fn:base + fn + span])
    hits = []
    for form in forms:
        i = body.find(form)
        while i >= 0:
            off = fn + i
            if all(reloc_to(e, rt, off + d, n) for d, n in checks):
                hits.append(off)
            i = body.find(form, i + 1)
    if len(hits) != 1:
        die("%s: want exactly one site, found %d" % (what, len(hits)))
    return hits[0]


def sites(e):
    rt = e.rela(".rela.text")
    out = []

    # mlsetup: pea 0x400 ; movel a0,-(sp) ; jsr mfree
    old, new = b"\x48\x78\x04\x00\x2f\x08\x4e\xb9", b"\x48\x78\x08\x00\x2f\x08\x4e\xb9"
    off = find(e, rt, text_sym(e, "mlsetup"), 0x200, (old, new), ((8, "mfree"),), "mlsetup mfree")
    out.append(Site("mlsetup sptmap clicks", off + 2, b"\x04\x00", b"\x08\x00"))

    # kvm_init: pea kvseg ; movel #size,-(sp) ; pea syssegs
    old, new = b"\x2f\x3c\x00\x40\x00\x00\x48\x79", b"\x2f\x3c\x00\x80\x00\x00\x48\x79"
    off = find(e, rt, text_sym(e, "kvm_init"), 0x200, (old, new),
               ((-4, "kvseg"), (8, "syssegs")), "kvm_init segkmem_create")
    out.append(Site("kvm_init kvseg size", off + 2, b"\x00\x40\x00\x00", b"\x00\x80\x00\x00"))

    # sysseginit: addil #64,d1 ; cmpil #1023,d1 ; ble
    old = b"\x06\x81\x00\x00\x00\x40\x0c\x81\x00\x00\x03\xff\x6f"
    new = old[:10] + b"\x07\xff" + old[12:]
    off = find(e, rt, text_sym(e, "sysseginit"), 0x100, (old, new), (), "sysseginit loop bound")
    out.append(Site("sysseginit leaf count", off + 10, b"\x03\xff", b"\x07\xff"))

    # kseg: its ptmalloc mask must be 0x3f, or the >> 18 key is not unique
    ks = text_sym(e, "kseg")
    find(e, rt, ks, 0x40, (b"\x48\x78\x00\x3f\x2f\x03\x48\x79",),
         ((8, "sptmap"), (14, "ptmalloc")), "kseg ptmalloc(sptmap, n, 0x3f)")
    # kseg: subil #syssegs,d0 ; moveq #17,d1 ; lsrl d1,d0 ; andil #0x1fff,d0 ; lea ksegtbl,a0
    tail = b"\xe2\xa8\x02\x80\x00\x00\x1f\xff\x41\xf9"
    off = find(e, rt, ks, 0x120, (b"\x72\x11" + tail, b"\x72\x12" + tail),
               ((-4, "syssegs"), (12, "ksegtbl")), "kseg ksegtbl key")
    out.append(Site("kseg ksegtbl shift", off, b"\x72\x11", b"\x72\x12"))
    # unkseg: subil #syssegs,d2 ; moveq #17,d0 ; lsrl d0,d2 ; andil #0x1fff,d2 ; lea ksegtbl,a2
    tail = b"\xe0\xaa\x02\x82\x00\x00\x1f\xff\x45\xf9"
    off = find(e, rt, text_sym(e, "unkseg"), 0x60, (b"\x70\x11" + tail, b"\x70\x12" + tail),
               ((-4, "syssegs"), (12, "ksegtbl")), "unkseg ksegtbl key")
    out.append(Site("unkseg ksegtbl shift", off, b"\x70\x11", b"\x70\x12"))

    # hat_pteload's segmap probe window (port only)
    tidx = e.names.index(".text")
    if any(e.sym(i)["name"] == "Lbt_ptl_skip" and e.sym(i)["shndx"] == tidx for i in range(e.syn)):
        lo = text_sym(e, "Lbt_ptl_skip")
        for d, rel, br in ((0, 0x8000, b"\x65"), (10, 0xa000, b"\x64")):
            o32 = struct.pack(">I", OLD_SEGMAP + rel)
            n32 = struct.pack(">I", NEW_SEGMAP + rel)
            off = find(e, rt, lo + d, 7, (b"\x0c\x82" + o32 + br, b"\x0c\x82" + n32 + br), (),
                       "hat_pteload probe +0x%x" % rel)
            out.append(Site("hat_pteload probe kvsegmap+0x%x" % rel, off + 2, o32, n32))

    # No relocation may write into any of these bytes.
    for s in out:
        for r in rt:
            if r < s.off + len(s.old) and r + 4 > s.off:
                die("%s: the relocation at .text 0x%x writes into the site" % (s.what, r))
    return out


def abs_syms(e):
    """[(name, symtab file offset of st_value, old, new)] for kvsegmap and kvsegu."""
    out = []
    for name, old, new in (("kvsegmap", OLD_SEGMAP, NEW_SEGMAP), ("kvsegu", OLD_SEGU, NEW_SEGU)):
        hits = [i for i in range(e.syn) if e.sym(i)["name"] == name]
        if len(hits) != 1 or e.sym(hits[0])["shndx"] != SHN_ABS:
            die("want exactly one SHN_ABS %s" % name)
        out.append((name, e.syo + hits[0] * e.sye + 4, old, new))
    s = [i for i in range(e.syn) if e.sym(i)["name"] == "syssegs"]
    if len(s) != 1 or e.sym(s[0])["shndx"] != SHN_ABS or e.sym(s[0])["value"] != 0x40040000:
        die("syssegs is not SHN_ABS 0x40040000")
    k = [i for i in range(e.syn) if e.sym(i)["name"] == "ksegtbl"]
    if len(k) != 1 or u32(e.b, e.syo + k[0] * e.sye + 8) != 32:
        die("ksegtbl is not one 32-byte object")
    return out


def state(e):
    """'old', 'new', or abort on a mixture.  Also returns the sites and symbols."""
    ss, syms = sites(e), abs_syms(e)
    base = e.sec[".text"]["offset"]
    seen = set()
    for s in ss:
        cur = bytes(e.b[base + s.off:base + s.off + len(s.old)])
        seen.add("old" if cur == s.old else "new" if cur == s.new else "?" + s.what)
    for name, vo, old, new in syms:
        cur = u32(e.b, vo)
        seen.add("old" if cur == old else "new" if cur == new else "?" + name)
    if len(seen) != 1 or next(iter(seen)) not in ("old", "new"):
        die("the layout sites disagree: %s" % ", ".join(sorted(seen)))
    return next(iter(seen)), ss, syms


def main():
    a = sys.argv[1:]
    check = len(a) == 2 and a[0] == "--check"
    if not (len(a) == 1 or check):
        raise SystemExit("usage: patch_arena8m.py [--check] KERNEL")
    path = a[-1]
    e = Elf(path)
    st, ss, syms = state(e)
    if check:
        print("  %s arena %s (%d sites, kvsegmap/kvsegu)" % ("[ok]  " if st == "new" else "[old] ",
                                                            "8 MB" if st == "new" else "4 MB", len(ss)))
        sys.exit(0 if st == "new" else 1)
    if st == "new":
        print("  [skip] arena already 8 MB")
        return
    base = e.sec[".text"]["offset"]
    for s in ss:
        e.b[base + s.off:base + s.off + len(s.new)] = s.new
        print("  [ok]   .text 0x%05x %-34s %s -> %s" % (s.off, s.what, s.old.hex(), s.new.hex()))
    for name, vo, old, new in syms:
        e.b[vo:vo + 4] = struct.pack(">I", new)
        print("  [ok]   ABS %-40s 0x%08x -> 0x%08x" % (name, old, new))
    open(path, "wb").write(e.b)
    if state(Elf(path))[0] != "new":
        die("the write did not take")


if __name__ == "__main__":
    main()
