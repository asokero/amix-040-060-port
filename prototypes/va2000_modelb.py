#!/usr/bin/env python3
# va2000_modelb.py -- Model B (4 KiB page frame) adaptation of the MNT VA2000
# driver source for the EXPERIMENTAL 040 va2000 kernel (2026-07-24).
#
# The upstream driver at ~/kehitys/va2000-amix/src/va2000.c targets the
# vanilla 68030/2 KiB kernel (that repo is a SEPARATE project -- DO NOT MODIFY
# IT).  It has exactly ONE page-size dependency: va2000mmap() returns
# phystopfn(pa) with the stock 2 KiB shift `>> 11` (PNUMSHFT=11).  Our 040
# kernel uses 4 KiB pages (Model B, PNUMSHFT=12), so a VM mapping built from an
# unconverted >>11 value would land at (pa>>11)<<12 = 2*pa -- the same
# device-mmap PFN bug already fixed for scrmmap/ammmap/timmap/svgammap (see
# patch_devmmap_pfn.py / patch_xsvga.py).  Converting the *source* (rather than
# patching the compiled object, since we compile this driver ourselves) is
# cleaner and keeps the object's bytes traceable to a source line.
#
# This script copies va2000.c (untouched) into build/, rewrites the ONE
# `>> 11` in va2000mmap to `>> 12`, and asserts the replacement count is
# exactly 1 -- fails hard otherwise so a silent no-op (source drifted
# upstream) or an over-match is never possible.
#
# Usage: python3 prototypes/va2000_modelb.py
#   reads:  ~/kehitys/va2000-amix/src/va2000.c
#   writes: build/va2000_040.c   (copy, patched)
#   also copies va2000.h unmodified alongside it (va2000.c does
#   #include "va2000.h" and needs it in the same directory to compile).

import shutil
import sys
import os

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.expanduser("~/kehitys/va2000-amix/src")
SRC_C = os.path.join(SRC_DIR, "va2000.c")
SRC_H = os.path.join(SRC_DIR, "va2000.h")
OUT_C = os.path.join(HERE, "build", "va2000_040.c")
OUT_H = os.path.join(HERE, "build", "va2000.h")

OLD = "        return (int)((va2000_boards[mindev] + offset) >> 11);\n"
NEW = ("        /* Model-B (4 KiB page, PNUMSHFT=12) adaptation of the vanilla\n"
       "         * 2 KiB-page (PNUMSHFT=11) shift -- see va2000_modelb.py header.\n"
       "         * The VM builds the user mapping as (returned_pfn << 12), so this\n"
       "         * must return pa >> 12, not the stock kernel's pa >> 11. */\n"
       "        return (int)((va2000_boards[mindev] + offset) >> 12);\n")


def main():
    if not os.path.isfile(SRC_C):
        raise SystemExit("ABORT: driver source not found: %s" % SRC_C)
    if not os.path.isfile(SRC_H):
        raise SystemExit("ABORT: driver header not found: %s" % SRC_H)

    text = open(SRC_C).read()
    n = text.count(OLD)
    if n != 1:
        raise SystemExit(
            "ABORT: expected exactly ONE occurrence of the vanilla >>11 shift "
            "in va2000mmap, found %d.  Upstream source (%s) may have changed "
            "-- update OLD/NEW in this script after re-checking the diff." % (n, SRC_C))

    patched = text.replace(OLD, NEW, 1)
    if patched.count(">> 12)") != 1 or ">> 11)" in patched:
        raise SystemExit("ABORT: post-patch sanity check failed (unexpected >>11/>>12 count)")

    os.makedirs(os.path.dirname(OUT_C), exist_ok=True)
    with open(OUT_C, "w") as f:
        f.write(patched)
    shutil.copyfile(SRC_H, OUT_H)

    print("  [ok] va2000mmap phystopfn >>11 -> >>12 (1 site) -> %s" % OUT_C)
    print("  [ok] va2000.h copied unmodified -> %s" % OUT_H)
    print("va2000_modelb: %s untouched (read-only); patched copy in build/" % SRC_C)


if __name__ == "__main__":
    main()
