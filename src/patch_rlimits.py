#!/usr/bin/env python3
# patch_rlimits.py -- the per-process soft limits for data and virtual memory: 16 MiB -> unlimited (2026-11-01).
#
#   patch_rlimits.py KERNEL           write the values; idempotent ([skip] when already done)
#   patch_rlimits.py --check KERNEL   say whether KERNEL carries the stock or the new values; write nothing
#
# THE LIMITS.  master.d/kernel compiles the fourteen rlimit tunables into `rlimits[]` (.data, struct rlimit pairs,
# soft then hard): CPU, FSIZE, DATA, STACK, CORE, NOFILE, VMEM.  The stock kernel carries
#     SCPULIM 0x7fffffff  HCPULIM 0x7fffffff   SFSZLIM 0x10000000  HFSZLIM 0x7fffffff
#     SDATLIM 0x01000000  HDATLIM 0x7fffffff   SSTKLIM 0x01000000  HSTKLIM 0x7fffffff
#     SCORLIM 0x00100000  HCORLIM 0x7fffffff   SFNOLIM 0x40        HFNOLIM 0x400
#     SVMMLIM 0x01000000  HVMMLIM 0x7fffffff
# so a process stops at 16 MiB of data and 16 MiB of address space unless it raises its own soft limit, which
# the stock /bin/sh's ulimit and most programs never do.  Every hard limit the kernel's values allow is already
# 0x7fffffff (RLIM_INFINITY).
#
# THE CHANGE.  SDATLIM and SVMMLIM become 0x7fffffff; SSTKLIM stays 0x01000000 (a 16 MiB soft stack, which
# `ulimit -s unlimited` can raise to the hard limit); nothing else changes.  The array is found by symbol, every
# one of its fourteen words is asserted against the stock or the new table before anything is written, and no
# relocation may cover it.

import os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kelf import Elf  # noqa: E402

INF = 0x7fffffff
STOCK = (INF, INF, 0x10000000, INF, 0x01000000, INF, 0x01000000, INF, 0x00100000, INF, 0x40, 0x400, 0x01000000, INF)
NEW = STOCK[:4] + (INF,) + STOCK[5:12] + (INF,) + STOCK[13:]
CHANGED = {4: "SDATLIM", 12: "SVMMLIM"}


def locate(e):
    didx = e.names.index(".data")
    hits = [e.sym(i) for i in range(e.syn) if e.sym(i)["name"] == "rlimits" and e.sym(i)["shndx"] == didx]
    if len(hits) != 1:
        raise SystemExit("ABORT: want exactly one rlimits in .data, found %d" % len(hits))
    base = hits[0]["value"]
    rd = e.rela(".rela.data")
    for off in range(base, base + 4 * len(STOCK), 2):
        if off in rd:
            raise SystemExit("ABORT: a relocation at .data 0x%x covers rlimits" % off)
    d = e.sec[".data"]["offset"] + base
    words = struct.unpack(">14I", bytes(e.b[d:d + 4 * len(STOCK)]))
    if words not in (STOCK, NEW):
        raise SystemExit("ABORT: rlimits (.data 0x%x) is %s, neither the stock nor the new table"
                         % (base, " ".join("%x" % w for w in words)))
    return base, words


def main():
    a = sys.argv[1:]
    check = len(a) == 2 and a[0] == "--check"
    if not (len(a) == 1 or check):
        raise SystemExit("usage: patch_rlimits.py [--check] KERNEL")
    path = a[-1]
    e = Elf(path)
    base, words = locate(e)
    if check:
        print("  %s rlimits .data 0x%x: SDATLIM 0x%x SVMMLIM 0x%x SSTKLIM 0x%x (%s)"
              % ("[ok]  " if words == NEW else "[stock]", base, words[4], words[12], words[6],
                 "unlimited data and address space" if words == NEW else "stock: 16 MiB soft data and vmem"))
        sys.exit(0 if words == NEW else 1)
    if words == NEW:
        print("  [skip] rlimits .data 0x%x already carries the new values" % base)
        return
    d = e.sec[".data"]["offset"] + base
    e.b[d:d + 4 * len(NEW)] = struct.pack(">14I", *NEW)
    open(path, "wb").write(e.b)
    if locate(Elf(path))[1] != NEW:
        raise SystemExit("ABORT: the write did not take")
    print("  [ok]   rlimits .data 0x%x: %s 0x01000000 -> 0x%x" % (base, ", ".join(CHANGED.values()), INF))


# Guarded: readers may load this file for its tables, and an unguarded main() would patch their argv.
if __name__ == "__main__":
    main()
