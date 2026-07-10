#!/usr/bin/env python3
"""patch_framesz060.py -- 060-B (2026-07-10): set framesz[4] = 16.

The kernel's trap code sizes exception frames from the 16-entry `framesz`
byte table at .data+0x72ac (one entry per frame-format nibble; consumed by
ttrap.s stkclear/stkrestore).  The vanilla table is
    fmt:   0  1  2  3  4  5  6  7  8  9  a  b  c  d  e  f
    bytes: 8  8 12  0  0  0  0 60  0 20 32 92  0  0  0  0
-- format 7 (the 68040 access error, 60 bytes) was present all along, which is
part of why the 040 port needed no table change.  The 68060 instead pushes a
FORMAT 4 access-error frame (8 words = 16 bytes: SR, PC, fmt/vec, FA, FSLW),
whose entry is 0.  With 0, signal-path frame conversion mis-sizes the frame.
One byte: framesz[4] = 16.  Harmless on 030/040 (they never generate format 4).

A signature check (fmt0=8, fmt1=8, fmt7=60) guards against layout drift.
Idempotent.  Usage: patch_framesz060.py <kernel-ET_REL-elf>
"""
import struct
import sys

FRAMESZ_DATA_OFF = 0x72AC   # framesz symbol, offset within .data (nm: 000072ac D framesz)


def main():
    path = sys.argv[1]
    with open(path, 'rb') as fh:
        data = bytearray(fh.read())

    # ELF32 big-endian section headers
    (shoff,) = struct.unpack('>I', data[0x20:0x24])
    (shentsize, shnum, shstrndx) = struct.unpack('>3H', data[0x2E:0x34])

    def shdr(i):
        o = shoff + i * shentsize
        return struct.unpack('>10I', data[o:o + 40])

    strtab_off = shdr(shstrndx)[4]

    def secname(i):
        n = strtab_off + shdr(i)[0]
        return data[n:data.index(b'\0', n)].decode()

    data_off = None
    for i in range(shnum):
        if secname(i) == '.data':
            data_off = shdr(i)[4]
            break
    if data_off is None:
        sys.exit(f"FAIL: no .data section in {path}")

    tbl_off = data_off + FRAMESZ_DATA_OFF
    tbl = bytes(data[tbl_off:tbl_off + 16])
    if not (tbl[0] == 8 and tbl[1] == 8 and tbl[7] == 60):
        sys.exit(f"FAIL: framesz signature mismatch at .data+{FRAMESZ_DATA_OFF:#x}: "
                 f"{tbl.hex()} (expected fmt0=8 fmt1=8 fmt7=60) -- layout drifted, NOT patching")
    old = tbl[4]
    if old not in (0, 16):
        sys.exit(f"FAIL: framesz[4] = {old}, expected 0 (vanilla) or 16 (already patched)")

    data[tbl_off + 4] = 16
    with open(path, 'wb') as fh:
        fh.write(data)
    print(f"    framesz[4] @ .data+{FRAMESZ_DATA_OFF + 4:#x}: {old} -> 16 "
          f"({'already patched' if old == 16 else 'patched'}; table {tbl.hex()})")


if __name__ == '__main__':
    main()
