#!/usr/bin/env python3
# patch_ip_lrhiwat.py -- ISSUE-81: IP's lower read queue has a high-water mark of 0x2000, less than
# the fragments of one 8 KiB NFS reply, so the A2065 driver's canput fails and it drops received
# frames (2026-10-30).
#
#   patch_ip_lrhiwat.py KERNEL           write the fix; idempotent ([skip] when already done)
#   patch_ip_lrhiwat.py --check KERNEL   say which value KERNEL carries; write nothing
#
# THE DEFECT.  The first queue above the driver with a service procedure is IP's lower (mux) read
# queue: qinit `iplrinit`, qi_srvp `ipintr`.  canput() refuses when it is QFULL.  setq copies its
# water marks at I_LINK from the module_info that iplrinit names, entry [3] of the five-entry
# `ipm_info` table (the MUXRQ slot), whose mi_hiwat is 0x2000 (8192) and mi_lowat 0x400.  Stock
# 2.1c has the same values, and so do the 3B2, i386 SVR4 and SVR4.2 ip_main.c.  Measured on 060 HW
# (solon, A2065, NFSv2/UDP rsize 8192): 156 drops in a 149 MB read; a live poke of the instantiated
# queue's q_hiwat to 0x10000 took them to 0 (KNOWN-ISSUES.md, ISSUE-81).
#
# THE FIX.  Entry [3]'s mi_hiwat only, 0x2000 -> 0x10000: four bytes of .data, no relocation, no
# layout change.  mi_minpsz, mi_maxpsz and mi_lowat are untouched, and so are the other four
# entries -- [2] (HDRQ) is what ipopen sends to the stream head in M_SETOPTS, which is a different
# queue.  The 32-bit field holds 0x10000; setq copies all 32 bits.  INITQPARMS can still overwrite
# the table, but its value is 16-bit and cannot express 0x10000.
#
# The entry is found through the relocation, not by index: iplrinit's qi_minfo (+20) must point
# into ipm_info at a 24-byte entry boundary, and iplrinit's qi_srvp (+4) must be ipintr.  The
# tool asserts the entry's stock shape around the field and that no relocation writes into it.

import os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kelf import Elf, R_68K_32, u32  # noqa: E402

ENTSZ, NENT = 24, 5                  # sizeof(struct module_info), entries in ipm_info
QI_SRVP, QI_MINFO = 4, 20            # struct qinit
MI_MINPSZ, MI_MAXPSZ, MI_HIWAT, MI_LOWAT = 8, 12, 16, 20
STOCK, FIXED = 0x2000, 0x10000


def data_sym(e, name):
    didx = e.names.index(".data")
    hits = [e.sym(i) for i in range(e.syn) if e.sym(i)["name"] == name and e.sym(i)["shndx"] == didx]
    if len(hits) != 1:
        raise SystemExit("ABORT: want exactly one %s in .data, found %d" % (name, len(hits)))
    return hits[0]["value"]


def d32(e, off):
    return u32(e.b, e.sec[".data"]["offset"] + off)


def locate(e):
    ipm, lr = data_sym(e, "ipm_info"), data_sym(e, "iplrinit")
    rd = e.rela(".rela.data")
    # Every image this was written against has only R_68K_32 in .rela.data, one record per
    # offset.  Requiring that of the whole table makes the reading below exact: each pointer is
    # S+A, and each record writes the four bytes at its offset, no more.  Anything else is an
    # image this tool does not understand, so it stops (Codex review F2, 2026-10-30).
    rs = e.sec[".rela.data"]
    if len(rd) != rs["size"] // rs["entsize"]:
        raise SystemExit("ABORT: .rela.data has two records at one offset")
    if any(t != R_68K_32 for _, _, t, _ in rd.values()):
        raise SystemExit("ABORT: .rela.data has a relocation type other than R_68K_32")
    for want, field in (("ipintr", QI_SRVP), ("ipm_info", QI_MINFO)):
        if lr + field not in rd:
            raise SystemExit("ABORT: no relocation at iplrinit+%d (.data 0x%x)" % (field, lr + field))
    _, sidx, _, add = rd[lr + QI_SRVP]
    if e.target(sidx, add)[0] != ".text" or e.target(sidx, add)[2:] != ("ipintr", True):
        raise SystemExit("ABORT: iplrinit's qi_srvp is not ipintr")
    _, sidx, _, add = rd[lr + QI_MINFO]
    sec, ent, _, _ = e.target(sidx, add)
    if sec != ".data" or (ent - ipm) % ENTSZ or not 0 <= (ent - ipm) // ENTSZ < NENT:
        raise SystemExit("ABORT: iplrinit's qi_minfo (.data 0x%x) is not an ipm_info entry" % ent)
    n = (ent - ipm) // ENTSZ
    site = ent + MI_HIWAT
    for off in rd:
        if off < site + 4 and off + 4 > site:
            raise SystemExit("ABORT: the relocation at .data 0x%x writes into mi_hiwat" % off)
    shape = (d32(e, ent + MI_MINPSZ), d32(e, ent + MI_MAXPSZ), d32(e, ent + MI_LOWAT))
    if shape != (0, 0x2000, 0x400):
        raise SystemExit("ABORT: ipm_info[%d] is not the stock shape (minpsz, maxpsz, lowat = %s)"
                         % (n, ", ".join("0x%x" % v for v in shape)))
    others = [d32(e, ipm + i * ENTSZ + MI_HIWAT) for i in range(NENT) if i != n]
    if others != [STOCK] * (NENT - 1):
        raise SystemExit("ABORT: another ipm_info entry's mi_hiwat is not 0x%x" % STOCK)
    cur = d32(e, site)
    if cur not in (STOCK, FIXED):
        raise SystemExit("ABORT: ipm_info[%d].mi_hiwat is 0x%x, neither stock nor fixed" % (n, cur))
    return n, site, cur


def main():
    a = sys.argv[1:]
    check = len(a) == 2 and a[0] == "--check"
    if not (len(a) == 1 or check):
        raise SystemExit("usage: patch_ip_lrhiwat.py [--check] KERNEL")
    path = a[-1]
    e = Elf(path)
    n, site, cur = locate(e)
    if check:
        print("  %s ipm_info[%d].mi_hiwat .data 0x%x = 0x%x" % ("[ok]  " if cur == FIXED else "[old] ",
                                                              n, site, cur))
        sys.exit(0 if cur == FIXED else 1)
    if cur == FIXED:
        print("  [skip] ipm_info[%d].mi_hiwat .data 0x%x already 0x%x" % (n, site, FIXED))
        return
    d = e.sec[".data"]["offset"] + site
    e.b[d:d + 4] = struct.pack(">I", FIXED)
    open(path, "wb").write(e.b)
    if locate(Elf(path))[2] != FIXED:
        raise SystemExit("ABORT: the write did not take")
    print("  [ok]   ipm_info[%d].mi_hiwat .data 0x%x: 0x%x -> 0x%x (IP lower read queue)"
          % (n, site, STOCK, FIXED))


if __name__ == "__main__":
    main()
