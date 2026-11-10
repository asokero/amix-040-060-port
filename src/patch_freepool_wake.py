#!/usr/bin/env python3
# patch_freepool_wake.py -- ISSUE-82: kmem_freepool compares the clicks it just returned with the
# byte-valued Km_OsizeWanted, so retiring a pool never wakes an oversize sleeper (2026-10-30).
#
#   patch_freepool_wake.py KERNEL           write the fix; idempotent ([skip] when already done)
#   patch_freepool_wake.py --check KERNEL   say which form KERNEL carries; write nothing
#
# THE DEFECT (read from the binary by Codex, private NFS-HANG-KMA-CODEX-RESULT.md §Q1).  Both
# retirement paths leave the click count they passed to sptfree in d2: 4 for a big pool, 1 for a
# small one.  The wake test then reads
#
#     tstl  Km_OsizeWanted ; ble.w skip        nobody waiting
#     cmpl  Km_OsizeWanted,%d2 ; bcs.w skip    clicks < bytes: always, since every oversize
#     clrl  Km_OsizeWanted ; wakeprocs(&Km_OsizeWanted, 1)        request is over 4096 bytes
#
# The direct kmem_free path compares bytes and wakes correctly.  Stock 2.1c has the same shape
# with 2 KiB clicks (8/2); this tool accepts only the 4 KiB-click image.
#
# THE FIX.  The ble.w becomes `moveq #12,%d0 ; lsll %d0,%d2`: d2 is now the bytes returned, and
# the compare that follows is the intended one.  sptfree has already been called with the click
# count, so its argument is unchanged, and the wake still comes after the VA is back in the map.
# d0 is dead there (the loop head reloads it).  The `tstl` stays and sets flags nobody reads.
# Without the ble, a retirement with nobody waiting clears an already-zero Km_OsizeWanted and calls
# wakeprocs on a channel with no sleepers.  That happens only when a pool is retired.
#
# Not claimed: this makes the existing single-return test unit-correct.  A request that only
# several returns together, or a return next to a free extent, could satisfy is still not retried
# by this test (Codex, ISSUE80-ARENA-ROUTE-CODEX-RESULT.md §Q4).

import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kelf import Elf  # noqa: E402

OLD_BLE = b"\x6f\x00"            # ble.w (displacement checked separately)
NEW = b"\x70\x0c\xe1\xaa"        # moveq #12,%d0 ; lsll %d0,%d2


def die(msg):
    raise SystemExit("ABORT: " + msg)


def text_sym(e, name):
    tidx = e.names.index(".text")
    hits = [e.sym(i)["value"] for i in range(e.syn)
            if e.sym(i)["name"] == name and e.sym(i)["shndx"] == tidx]
    if len(hits) != 1:
        die("want exactly one %s in .text, found %d" % (name, len(hits)))
    return hits[0]


def locate(e):
    rt = e.rela(".rela.text")
    t = e.sec[".text"]["offset"]
    fn = text_sym(e, "kmem_freepool")

    def rel(off, name):
        return off in rt and rt[off][2] == 1 and e.sym(rt[off][1])["name"] == name and rt[off][3] == 0

    def w(off):
        return (e.b[t + off] << 8) | e.b[t + off + 1]

    hits = [o for o in range(fn, fn + 0x400, 2) if w(o) == 0x4ab9 and rel(o + 2, "Km_OsizeWanted")]
    if len(hits) != 1:
        die("want one `tstl Km_OsizeWanted` in kmem_freepool, found %d" % len(hits))
    a = hits[0]
    site = a + 6
    # cmpl Km_OsizeWanted,%d2 ; bcs.w skip ; clrl Km_OsizeWanted ; pea 1 ; pea Km_OsizeWanted ;
    # jsr wakeprocs
    if not (w(a + 10) == 0xb4b9 and rel(a + 12, "Km_OsizeWanted") and w(a + 16) == 0x6500
            and w(a + 20) == 0x42b9 and rel(a + 22, "Km_OsizeWanted")
            and bytes(e.b[t + a + 26:t + a + 30]) == b"\x48\x78\x00\x01"
            and w(a + 30) == 0x4879 and rel(a + 32, "Km_OsizeWanted")
            and w(a + 36) == 0x4eb9 and rel(a + 38, "wakeprocs")):
        die("the wake test after .text 0x%x is not the stock shape" % a)
    skip = a + 18 + ((w(a + 18) ^ 0x8000) - 0x8000)
    # d2 must hold 4 KiB clicks: the two sptfree calls that reach the test pass moveq #4 and #1
    for n in (4, 1):
        if not any(w(o) == 0x7400 | n and w(o + 2) == 0x4878 and w(o + 4) == 1 and w(o + 6) == 0x2f02
                   for o in range(fn, a, 2)):
            die("no `moveq #%d,%%d2 ; pea 1 ; movel %%d2,-(sp)` before the test: not 4 KiB clicks" % n)
    cur = bytes(e.b[t + site:t + site + 4])
    if cur[:2] == OLD_BLE:
        if site + 2 + ((w(site + 2) ^ 0x8000) - 0x8000) != skip:
            die("the ble.w at .text 0x%x does not go where the bcs.w goes" % site)
        state = "old"
    elif cur == NEW:
        state = "new"
    else:
        die("the 4 bytes at .text 0x%x are %s, neither stock nor fixed" % (site, cur.hex()))
    for r in rt:
        if r < site + 4 and r + 4 > site:
            die("the relocation at .text 0x%x writes into the site" % r)
    return site, state


def main():
    a = sys.argv[1:]
    check = len(a) == 2 and a[0] == "--check"
    if not (len(a) == 1 or check):
        raise SystemExit("usage: patch_freepool_wake.py [--check] KERNEL")
    path = a[-1]
    e = Elf(path)
    site, st = locate(e)
    if check:
        print("  %s kmem_freepool wake test .text 0x%x compares %s" % (
            "[ok]  " if st == "new" else "[old] ", site, "bytes" if st == "new" else "clicks"))
        sys.exit(0 if st == "new" else 1)
    if st == "new":
        print("  [skip] kmem_freepool wake test .text 0x%x already compares bytes" % site)
        return
    t = e.sec[".text"]["offset"]
    old = bytes(e.b[t + site:t + site + 4])
    e.b[t + site:t + site + 4] = NEW
    open(path, "wb").write(e.b)
    if locate(Elf(path))[1] != "new":
        die("the write did not take")
    print("  [ok]   .text 0x%x kmem_freepool wake test: %s -> %s (clicks << 12 before the compare)"
          % (site, old.hex(), NEW.hex()))


if __name__ == "__main__":
    main()
