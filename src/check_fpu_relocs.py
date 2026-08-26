#!/usr/bin/env python3
# check_fpu_relocs.py -- F1-M1: the Tier-1 spec's own relink assertions, run on
# the finished kernel (2026-08-24).
#
# FPU-TIER1-ENABLE-SPEC.md:205-210 requires, before the image is believed:
#   * the expected call relocation counts still equal 5 / 3 / 3;
#   * init_tbl has one relocation to fpuinit;
#   * fpu_ptr still relocates to fixed u + 0x9c;
#   * fpu_present remains the existing global object.
# "Abort the relink on any mismatch."
#
# Counts are checked as SITES rather than as totals, because a total is exactly
# the kind of number that stays right while its parts move: the override units
# add their own calls to the same symbols, so `3` would still read `3` after a
# stock call site had been retargeted somewhere unintended.  The eleven pinned
# sites below are the stock image's own, measured against it.
#
# With the sendsig gate installed (--gated) one of the three setup sites names
# fpu_setup_gated instead.  That one difference is the entire F1-M2 call-site
# change and it is asserted rather than assumed.

import struct, sys

R_68K_32 = 1

SITES = {
    "fpu_save":    [0x041930, 0x058ea6, 0x058f8c, 0x0b7ffc, 0x0b920c],
    "fpu_restore": [0x058ecc, 0x058fd0, 0x0b9060],
    "fpu_setup":   [0x019bd0, 0x058c34, 0x05921c],
}
SENDSIG_SITE = 0x05921c          # sendsig+0x1f8, the one F1-M2 retargets
U_FPU_INFO = 0x9c                # fpu_ptr = u + 0x9c, and it must not move


def u16(b, o): return struct.unpack(">H", b[o:o+2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o+4])[0]


def main():
    path = sys.argv[1]
    gated = "--gated" in sys.argv[2:]
    b = open(path, "rb").read()
    e_shoff = u32(b, 32); e_shentsize = u16(b, 46)
    e_shnum = u16(b, 48); e_shstrndx = u16(b, 50)
    sh = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        sh.append(dict(name=u32(b, o), offset=u32(b, o+16), size=u32(b, o+20),
                       link=u32(b, o+24), entsize=u32(b, o+36)))
    shstr = sh[e_shstrndx]["offset"]

    def nm(s):
        e = b.index(b"\0", shstr + s["name"]); return b[shstr+s["name"]:e].decode()
    byname = {nm(s): s for s in sh}
    symtab = byname[".symtab"]; strtab = sh[symtab["link"]]
    so, se = symtab["offset"], symtab["entsize"]
    sn = symtab["size"] // se
    stroff = strtab["offset"]

    def symname(i):
        n = u32(b, so + i*se); e = b.index(b"\0", stroff + n)
        return b[stroff+n:e].decode()

    syms = {}
    for i in range(sn):
        o = so + i*se
        syms.setdefault(symname(i), (u32(b, o+4), b[o+12], u16(b, o+14)))

    def relocs(sec):
        s = byname[sec]
        n = s["size"] // s["entsize"]
        out = {}
        for i in range(n):
            o = s["offset"] + i*s["entsize"]
            info = u32(b, o+4)
            out.setdefault(u32(b, o), []).append(
                (symname(info >> 8), info & 0xff, struct.unpack(">i", b[o+8:o+12])[0]))
        return out

    rtext = relocs(".rela.text")
    rdata = relocs(".rela.data")
    fails = []

    want = dict(SITES)
    if gated:
        want["fpu_setup"] = [a for a in SITES["fpu_setup"] if a != SENDSIG_SITE]

    for name, sites in want.items():
        for off in sites:
            got = rtext.get(off)
            if not got:
                fails.append("no .rela.text reloc at 0x%06x (expected %s)" % (off, name))
            elif got[0][0] != name:
                fails.append("0x%06x names %s, expected %s" % (off, got[0][0], name))
        print("      %-16s %d/%d stock call sites bind as expected"
              % (name, len(sites), len(SITES[name])))

    got = rtext.get(SENDSIG_SITE)
    tgt = got[0][0] if got else None
    if gated:
        if tgt != "fpu_setup_gated":
            fails.append("sendsig+0x1f8 names %s, expected fpu_setup_gated" % tgt)
        else:
            print("      sendsig+0x1f8    -> fpu_setup_gated (the F1-M2 gate)")
    elif tgt != "fpu_setup":
        fails.append("sendsig+0x1f8 names %s, expected fpu_setup (ungated build)" % tgt)

    if "init_tbl" not in syms:
        fails.append("init_tbl not found")
    else:
        it = syms["init_tbl"][0]
        hits = [(o, r) for o, rs in rdata.items() for r in rs
                if r[0] == "fpuinit" and o == it]
        others = [o for o, rs in rdata.items() for r in rs if r[0] == "fpuinit" and o != it]
        if len(hits) != 1:
            fails.append("init_tbl+0 has %d relocations to fpuinit, expected 1" % len(hits))
        elif others:
            fails.append("fpuinit is also reached from .data offsets %s"
                         % ["0x%x" % o for o in others])
        else:
            print("      init_tbl+0       -> fpuinit, and nothing else in .data does")

    if "fpu_ptr" not in syms:
        fails.append("fpu_ptr not found")
    else:
        rp = rdata.get(syms["fpu_ptr"][0])
        if not rp or rp[0][0] != "u" or rp[0][2] != U_FPU_INFO:
            fails.append("fpu_ptr initializer is %s, expected u + 0x%x"
                         % (rp, U_FPU_INFO))
        else:
            print("      fpu_ptr         -> u + 0x%02x (fpu_info, unmoved)" % U_FPU_INFO)

    fp = syms.get("fpu_present")
    if not fp:
        fails.append("fpu_present not found")
    elif fp[1] != 0x11:
        fails.append("fpu_present st_info is 0x%02x, expected 0x11 (global object)" % fp[1])
    else:
        print("      fpu_present      global object at 0x%08x, .data" % fp[0])

    if fails:
        for f in fails:
            print("[FAIL] %s" % f)
        sys.exit(1)
    print("FPU relink assertions pass (5/3/3 sites, init_tbl, fpu_ptr, fpu_present)")


main()
