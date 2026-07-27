#!/usr/bin/env python3
# patch_nfs_putpage.py -- ISSUE-35: nfs_putpage's io_len must advance in 4 KiB pages.
#
# THE DEFECT, PROVEN ON REAL HARDWARE 2026-07-27
# A file whose length is an exact multiple of 8192 lost exactly its last 2048 bytes when
# written to NFS.  Deterministic 3/3, local-disk control clean, and verified from the server
# side over a different protocol: the file ended at page offset 2048 of 4096, so the final
# 4 KiB page's upper half was never written.  Full record:
# test-tools/realhw-verify-260727.txt section 5, KNOWN-ISSUES.md ISSUE-35.
#
# ATTRIBUTION: OURS.  Codex settled it statically rather than by booting the 030 kernel
# (vm-map/NFS-REALHW-ISSUE35-FOLLOWUP.md): on stock 030 the same code is CORRECT, because
# page_t offsets advance by 2048 and io_len advances by 2048 together.  Model B moved the
# page population to 4 KiB and left io_len at 2 KiB.  This is a Model-B mixed-geometry
# regression, i.e. our own.
#
# THE MINIMUM ATOMIC UNIT IS EXACTLY TWO INSTRUCTIONS
#   0x8b9de   movel #2048,%d3      io_len = PAGESIZE            (first dirty page length)
#   0x8ba2c   addil #2048,%d3      io_len += PAGESIZE           (add one contiguous page)
#
# They MUST land together, and the reason is asymmetric:
#   * changing only 0x8ba2c does nothing -- the 2048-byte initial comparison never admits
#     the second page, so the add is never reached;
#   * changing only 0x8b9de admits the second page but then describes two 4 KiB pages as
#     6144 bytes, which is a NEW wrong length rather than a fix.
# So this script verifies BOTH sites before writing EITHER.
#
# THE OTHER FOUR SITES OF THE GROUP ARE DELIBERATELY NOT TOUCHED, and are asserted
# UNCHANGED as canaries.  nfs_putpage is at 0x8b7e8; the complete eventual conversion unit
# is six sites, but only this pair produces ISSUE-35 on an 8 KiB mount (vfs_bsize 0x2000),
# because both the old and new forms of the first pair select 8192 there:
#   0x8b84e  cmpi 0x7ff       MAX(vfs_bsize, PAGESIZE) gate
#   0x8b85a  movel #0x800     fallback PAGESIZE local minimum
#   0x8b916  addi  0x7ff      round file size
#   0x8b91c  andi  0xf800     rounded file boundary
# If a later change converts those four, this patch's minimum-pair reasoning no longer
# holds and the canaries here will stop the build so the reasoning gets revisited.
#
# ACCEPTANCE -- and the size sweep alone is NOT sufficient.  Codex's warning is important:
# a file whose reported size comes out right can still have unwritten upper halves in its
# earlier full slots, so `st_size` and a same-client read can both pass on a broken kernel.
# Use test-tools/nfstruth.c plus test-tools/nfstruth-verify.py, which compare BYTES from the
# server side against an absolute-offset-derived pattern.
#
# Idempotent; asserts old bytes; fails closed.  Usage:
#   python3 prototypes/patch_nfs_putpage.py [kernel]      (default build/unix-040)

import sys, os

KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"
TEXT_OFF = 0x34

# (vaddr, old, new, name) -- ATOMIC: all verified before any write
SITES = [
    (0x8b9de, b"\x26\x3c\x00\x00\x08\x00", b"\x26\x3c\x00\x00\x10\x00",
     "nfs_putpage:io_len = PAGESIZE  movel #2048 -> #4096"),
    (0x8ba2c, b"\x06\x83\x00\x00\x08\x00", b"\x06\x83\x00\x00\x10\x00",
     "nfs_putpage:io_len += PAGESIZE addil #2048 -> #4096"),
]

# (vaddr, expected_bytes, why) -- the rest of the six-site group, NOT part of this fix
CANARIES = [
    (0x8b84e, b"\x0c\xa8\x00\x00\x07\xff", "MAX(vfs_bsize,PAGESIZE) gate -- 8 KiB mount selects 8192 either way"),
    (0x8b85a, b"\x2d\x7c\x00\x00\x08\x00", "fallback PAGESIZE local minimum -- not reached on this mount"),
    (0x8b916, b"\x06\x80\x00\x00\x07\xff", "file-size round-up -- same result at an exact 4/8 KiB boundary"),
    (0x8b91c, b"\x02\x40\xf8\x00",         "rounded file boundary mask"),
]


def main():
    if not os.path.isfile(KERNEL):
        raise SystemExit("ABORT: kernel not found: %s" % KERNEL)
    with open(KERNEL, "rb") as f:
        img = bytearray(f.read())

    for va, want, why in CANARIES:
        off = va + TEXT_OFF
        got = bytes(img[off:off + len(want)])
        if got != want:
            raise SystemExit(
                "ABORT: canary @0x%x is %s, expected %s (%s)\n"
                "       Either the image is not the one this was derived against, or the\n"
                "       other four nfs_putpage sites have been converted -- in which case the\n"
                "       minimum-pair reasoning must be revisited before proceeding."
                % (va, got.hex(), want.hex(), why))
        print("  [canary] @0x%05x %-12s unchanged -- %s" % (va, want.hex(), why))

    # ---- phase 1: verify BOTH sites; write nothing yet (the unit is atomic) ----
    todo = []
    already = 0
    for va, old, new, name in SITES:
        off = va + TEXT_OFF
        got = bytes(img[off:off + len(old)])
        if got == new:
            print("  [skip]   @0x%05x already %s  %s" % (va, new.hex(), name))
            already += 1
            continue
        if got != old:
            raise SystemExit(
                "ABORT: @0x%x is %s, expected %s (%s)\n"
                "       NOTHING was written -- this pair only makes sense applied together."
                % (va, got.hex(), old.hex(), name))
        todo.append((off, va, old, new, name))

    if todo and already:
        raise SystemExit(
            "ABORT: the pair is HALF applied (%d already, %d pending).  A half-converted\n"
            "       nfs_putpage describes two 4 KiB pages as 6144 bytes, which is worse than\n"
            "       either endpoint.  Restore the kernel and re-run." % (already, len(todo)))

    # ---- phase 2: both verified, now write ----
    for off, va, old, new, name in todo:
        img[off:off + len(new)] = new
        print("  [ok]     @0x%05x %s -> %s  %s" % (va, old.hex(), new.hex(), name))

    if todo:
        with open(KERNEL, "wb") as f:
            f.write(img)
    print("patch_nfs_putpage: %d patched, %d already, %d canaries intact (ISSUE-35) -> %s"
          % (len(todo), already, len(CANARIES), KERNEL))


if __name__ == "__main__":
    main()
