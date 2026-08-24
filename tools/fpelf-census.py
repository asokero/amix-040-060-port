#!/usr/bin/env python3
# fpelf-census.py -- which installed binaries claim to REQUIRE hardware floating
# point?  (F1, 2026-08-24.)
#
# Usage: python3 tools/fpelf-census.py <root> [<root> ...]
#
# WHY THIS EXISTS.  getelfhead refuses to exec an FP-required binary when
# `fpu_present` is zero.  Decoded from the pinned image at getelfhead+0x76:
#
#     btst #0,ehdr+39        e_flags bit 0 -- "hardware FP required"
#     beq  ...continue       not set: nothing to check
#     tstl fpu_present
#     beq  ...reject         set, and no FPU: refuse the exec
#
# Byte 39 is the low byte of `e_flags` in a 32-bit big-endian ELF header
# (e_ident 0-15, e_type 16, e_machine 18, e_version 20, e_entry 24, e_phoff 28,
# e_shoff 32, e_flags 36).  So the policy turns on one bit that the AMIX
# toolchain either sets or does not, and whether that bit is ever set decides
# whether the gate is a real blocker on a 68LC060 or a latent branch.
#
# This counts HEADERS.  The instruction census (287 reachable `fmovecr` across
# 64 files) counts something else entirely: what a binary would execute.  A
# binary can be full of FP and not marked, which is the interesting case,
# because then it runs until it traps rather than being refused at exec.

import os, struct, sys

EM_68K = 4
EF_FP_REQUIRED = 0x1
ET = {1: "REL", 2: "EXEC", 3: "DYN", 4: "CORE"}


def header(path):
    try:
        if os.path.getsize(path) < 40:
            return None
        with open(path, "rb") as f:
            h = f.read(40)
    except OSError:
        return None
    if h[:4] != b"\x7fELF" or h[4] != 1 or h[5] != 2:
        return None                      # not a 32-bit big-endian ELF
    e_type, e_machine = struct.unpack(">HH", h[16:20])
    e_flags = struct.unpack(">I", h[36:40])[0]
    if e_machine != EM_68K:
        return None
    return e_type, e_flags


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: fpelf-census.py <root> [<root> ...]")
    total = 0
    by_type = {}
    flagged = []
    flagsets = {}
    for root in sys.argv[1:]:
        for dp, _, fn in os.walk(root):
            for name in fn:
                p = os.path.join(dp, name)
                if os.path.islink(p):
                    continue
                h = header(p)
                if h is None:
                    continue
                e_type, e_flags = h
                total += 1
                by_type[e_type] = by_type.get(e_type, 0) + 1
                flagsets[e_flags] = flagsets.get(e_flags, 0) + 1
                if e_flags & EF_FP_REQUIRED:
                    flagged.append((p, e_type, e_flags))

    print("m68k ELF objects examined: %d" % total)
    for t in sorted(by_type):
        print("   ET_%-5s %d" % (ET.get(t, str(t)), by_type[t]))
    print("distinct e_flags values seen:")
    for v in sorted(flagsets):
        print("   0x%08x  %d file(s)%s"
              % (v, flagsets[v], "   <- bit 0 set" if v & EF_FP_REQUIRED else ""))
    print("FP-REQUIRED (e_flags bit 0 set): %d" % len(flagged))
    for p, t, v in flagged:
        print("   ET_%-5s e_flags=0x%08x  %s" % (ET.get(t, str(t)), v, p))
    if total == 0:
        sys.exit("nothing examined -- is that a tree of AMIX binaries?")


main()
