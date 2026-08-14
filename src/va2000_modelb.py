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
# Usage: python3 src/va2000_modelb.py
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


# PROVENANCE PIN, added 2026-07-28 after the user asked the right question: "is the 8-bit display
# mode support in the kernel driver, or is it still only on its own branch?"
#
# It was in -- but only because that branch happened to be the checked-out one.  This script reads
# whatever ~/kehitys/va2000-amix/src/va2000.c currently is, with no branch and no revision pinned,
# so `git checkout main` in that repo would silently produce a kernel WITHOUT the 8-bit support and
# no build-time signal at all.  wolf3d needs 8-bit: the branch adds VA2CLR_8BIT, the /2 pitch for
# two pixels per 16-bit word, 2x pixel doubling for small modes, and cur_bpp = 8.  On main the
# driver is 16-bit only ("This driver implements 16-bit only" -- its own comment).
#
# Same hazard, same fix as the Xsvga `exp` object whose path used to default into a /tmp scratchpad:
# pin the content and fail closed.  Updating the pin is a deliberate act; drifting past it is not.
EXPECT_SHA256 = "f5aa2c04beb3a7513380769f106c6b3aedf4233383116cdde52d94d8d7bd3595"
EXPECT_BRANCH = "va2000-8bit-support"     # va2000-amix commit 3f3af25
EXPECT_NOTE = ("the 8-bit display mode support wolf3d needs lives ONLY on this branch; "
               "main is 16-bit only")


def check_provenance():
    import hashlib
    got = hashlib.sha256(open(SRC_C, "rb").read()).hexdigest()
    if got == EXPECT_SHA256:
        print("va2000_modelb: source provenance OK (%s, %s)" % (EXPECT_BRANCH, got[:12]))
        return
    raise SystemExit(
        "ABORT: %s does not match the pinned source.\n"
        "       expected sha256 %s  (branch %s)\n"
        "       got      sha256 %s\n"
        "       %s\n"
        "       If the va2000-amix checkout moved, restore it:\n"
        "           cd ~/kehitys/va2000-amix && git checkout %s\n"
        "       If the driver genuinely changed, re-check the diff and update EXPECT_SHA256 here\n"
        "       ON PURPOSE -- silently building a different driver into the kernel is exactly the\n"
        "       failure this pin exists to prevent."
        % (SRC_C, EXPECT_SHA256, EXPECT_BRANCH, got, EXPECT_NOTE, EXPECT_BRANCH))


def main():
    if not os.path.isfile(SRC_C):
        raise SystemExit("ABORT: driver source not found: %s" % SRC_C)
    if not os.path.isfile(SRC_H):
        raise SystemExit("ABORT: driver header not found: %s" % SRC_H)
    check_provenance()

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
