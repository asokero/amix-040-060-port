#!/usr/bin/env python3
"""
patch_pstart_040.py  --  produce `unix-040` from the stock AMIX `unix` kernel.

DRAFT 1 -- "no-paging bring-up probe" for 68040.

Background
----------
`pstart` (kernel offset 0xd44) builds the bootstrap page tables in 68030
long-format (2 KB pages, 8-byte table descriptors, 2/13/6 tree) and then
enables the MMU with three 030-only PMMU instructions at offsets 0xfd6..0xfe5:

    fd6:  f010 4800       pmove %a0@,%srp      ; load supervisor root pointer
    fda:  f000 2400       pflusha              ; flush ATC
    fde:  f039 4000 ....  pmove tc_on,%tc      ; enable MMU (reloc -> tc_on @ 0xfe2)

On a 68040 `pmove` is illegal -> this is the first in-kernel crash once copyit's
040 MMU-disable works (confirmed empirically: B-Trap F010 at bind_base+0xfd6).

A *correct* 040 pstart must rebuild these tables in 040 format (4 KB pages,
4-byte descriptors, fixed 7/7/6 tree) -- but the tables it produces are also
consumed by the binary-only HAT/VM layer in 030 format, so real paging needs a
VM-wide conversion.  This DRAFT defers all of that:

DRAFT 1 strategy
----------------
copyit already left the 040 with the MMU DISABLED (movec #0 -> TC), i.e. flat
1:1 translation.  The kernel is bound to a physical address and runs there 1:1,
so it can keep running flat.  We therefore simply SKIP pstart's MMU-enable:

    fd6:  f518            pflusha              ; 040 ATC flush (hygiene; harmless)
    fd8:  6000 000c       bra.w  0xfe6         ; jump straight to `jsr vstart`
    fdc:  4e71 * 5        nop  (dead padding)  ; the tc_on reloc @0xfe2 lands here,
                                               ; harmlessly, because it is skipped

All of pstart's table-building bookkeeping (cpuroot/userroot/st_top1/kuptr/
ublksde) still runs and stays consistent; we only avoid turning paging on.
This lets AMIX boot as far as it can with flat translation and exposes the NEXT
real blocker (expected: CACR/cache setup in mlsetup, or the first place the
kernel genuinely needs paging).  It does NOT depend on a kernel relink.

Why branch-over instead of editing the relocation
--------------------------------------------------
The final `unix` is relocatable; unix_boot's rel.c applies R_68K_32 records.
There is a tc_on R_68K_32 reloc at file/vaddr 0xfe2.  Rather than delete or
neutralise it (which rel.c would otherwise apply on top of our patch), we place
the patch so 0xfe2 falls inside the `bra.w`-skipped dead region: the reloc is
still applied, but into bytes that are never executed.  Zero ELF surgery.

Usage:  python3 patch_pstart_040.py [path/to/unix] [path/to/unix-040]
"""

import sys, shutil, struct

# --- geometry (verified against vanilla/stand/unix) ---------------------------
TEXT_FILE_OFFSET = 0x34      # .text section file offset (readelf -S)
PSTART_MMU_VADDR = 0xfd6     # start of the 030 MMU-enable sequence
PATCH_LEN        = 16        # bytes 0xfd6 .. 0xfe5 (srp 4 + pflusha 4 + pmove-tc 8)
VSTART_VADDR     = 0xfe6     # `jsr vstart` -- where control must resume

# Bytes currently expected at the patch site (sanity guard before writing).
EXPECT = bytes.fromhex("f0104800" "f0002400" "f0394000" "00000000")

# --- Draft-1 replacement ------------------------------------------------------
#   f518            pflusha            (040 ATC flush)
#   6000 000c       bra.w 0xfe6        (disp from 0xfd8+2=0xfda -> 0xfe6 = 0x0c)
#   4e71 x5         nop padding (dead; tc_on reloc @0xfe2 lands here)
assert (VSTART_VADDR - (PSTART_MMU_VADDR + 2 + 2)) == 0x0c
PATCH = bytes.fromhex("f518") + struct.pack(">HH", 0x6000, 0x000c) + b"\x4e\x71" * 5
assert len(PATCH) == PATCH_LEN, len(PATCH)


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else \
        "/home/asokero/kehitys/amix-playground/vanilla/stand/unix"
    dst = sys.argv[2] if len(sys.argv) > 2 else \
        "/home/asokero/kehitys/amix-playground/kernelsupport/build/unix-040"

    import os
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst)

    off = TEXT_FILE_OFFSET + PSTART_MMU_VADDR
    with open(dst, "r+b") as f:
        f.seek(off)
        cur = f.read(PATCH_LEN)
        if cur != EXPECT:
            sys.exit("ABORT: bytes at 0x%x are not the expected 030 MMU-enable\n"
                     "  found:    %s\n  expected: %s"
                     % (off, cur.hex(), EXPECT.hex()))
        f.seek(off)
        f.write(PATCH)

    print("patched %s -> %s" % (src, dst))
    print("  file offset 0x%x: %s  (was %s)" % (off, PATCH.hex(), EXPECT.hex()))
    print("  pstart 0xfd6: pflusha; bra.w 0xfe6  (MMU stays OFF -> kernel runs flat 1:1)")


if __name__ == "__main__":
    main()
