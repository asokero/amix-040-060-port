#!/usr/bin/env python3
# patch_sysconfig_pagesize.py -- sysconfig(_CONFIG_PAGESIZE) must report 4096, not 2048.
#
# THE DEFECT
# The kernel runs on 4 KiB pages (Model B) but tells user space its page size is 2048:
#
#     0x44e7c   movel #2048,%a0@        <- sysconfig's _CONFIG_PAGESIZE case
#
# Every program that asks the kernel its page size gets the wrong answer.  That is not a
# compatibility choice, it is the kernel misreporting itself, and it is ALSO the mechanism by
# which a program ends up at a half-page address: compute an alignment from 2048, land at
# page+0x800, and then hit the genuinely ABI-shaped defects in mmap/munmap/mprotect (which
# Codex's RESIDUAL-FAMILIES-FOLLOWUP.md lists at 0x583a6 / 0x5844c / 0x584f2 / 0x58572).
#
# So this fix REDUCES exposure to those four rather than being part of the same decision.
# Its risk profile is the opposite of theirs: they turn currently-succeeding calls into
# EINVAL, which is a genuine compatibility break; this one only stops a wrong answer.
# Therefore it lands ALONE and FIRST.  Recorded in docs/archive/RESUME-HERE-260727.md and, from the hardware
# session, in test-tools/realhw-verify-260727.txt.
#
# SOURCE CONTRACT
# svr4-src-3b2/usr/src/uts/3b2/sys/sysconfig.h:21  #define _CONFIG_PAGESIZE 6
# The disassembly agrees: `moveq #6,%d1` at 0x44e22 is the case comparison whose branch
# reaches 0x44e7c.  Classified the WHOLE function (0x44e12..0x44e92, 128 bytes) rather than
# trusting a single-site claim; there is exactly one page-size immediate in it.
#
# CANARIES -- asserted UNCHANGED, because a mechanical constant sweep would have taken them:
#   0x44e72  movel #198808,%a0@   _CONFIG_POSIX_VER.  198808 = August 1988 = POSIX.1-1988,
#                                 not a size.  Directly adjacent to the target.
#   0x44e22  moveq #6,%d1         the _CONFIG_PAGESIZE case VALUE itself.  Converting this
#                                 would silently move the page-size query to command 12.
#
# Idempotent; asserts old bytes; fails closed.  Usage:
#   python3 src/patch_sysconfig_pagesize.py [kernel]     (default build/unix-040)

import sys, os

KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"
TEXT_OFF = 0x34                      # .text file offset in this ET_REL image

# (vaddr, old, new, name)
SITES = [
    (0x44e7c, b"\x20\xbc\x00\x00\x08\x00", b"\x20\xbc\x00\x00\x10\x00",
     "sysconfig:_CONFIG_PAGESIZE movel #2048 -> #4096"),
]

# (vaddr, expected_bytes, why)
CANARIES = [
    (0x44e72, b"\x20\xbc\x00\x03\x08\x98", "_CONFIG_POSIX_VER 198808 = 0x30898 (POSIX.1-1988), NOT a size"),
    (0x44e22, b"\x72\x06",                 "_CONFIG_PAGESIZE case VALUE 6, must not become 12"),
]


def main():
    if not os.path.isfile(KERNEL):
        raise SystemExit("ABORT: kernel not found: %s" % KERNEL)
    with open(KERNEL, "rb") as f:
        img = bytearray(f.read())

    # ---- canaries first: if the neighbourhood is not what we think, do not write ----
    for va, want, why in CANARIES:
        off = va + TEXT_OFF
        got = bytes(img[off:off + len(want)])
        if got != want:
            raise SystemExit(
                "ABORT: canary @0x%x is %s, expected %s (%s)\n"
                "       The image is not the one this patch was derived against."
                % (va, got.hex(), want.hex(), why))
        print("  [canary] @0x%05x %s -- unchanged, %s" % (va, want.hex(), why))

    patched = already = 0
    for va, old, new, name in SITES:
        off = va + TEXT_OFF
        got = bytes(img[off:off + len(old)])
        if got == new:
            print("  [skip]   @0x%05x already %s  %s" % (va, new.hex(), name))
            already += 1
            continue
        if got != old:
            raise SystemExit(
                "ABORT: @0x%x is %s, expected %s (%s)"
                % (va, got.hex(), old.hex(), name))
        img[off:off + len(new)] = new
        print("  [ok]     @0x%05x %s -> %s  %s" % (va, old.hex(), new.hex(), name))
        patched += 1

    if patched:
        with open(KERNEL, "wb") as f:
            f.write(img)
    print("patch_sysconfig_pagesize: %d patched, %d already, %d canaries intact -> %s"
          % (patched, already, len(CANARIES), KERNEL))


if __name__ == "__main__":
    main()
