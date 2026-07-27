#!/usr/bin/env python3
"""nfstruth-verify.py -- the server-side half of the ISSUE-35 acceptance test.

Run this on the HOST against the same directory as the server sees it (for us: the
gvfs SMB mount of the NAS), i.e. through a DIFFERENT client and a DIFFERENT protocol
from the one that wrote the file.  That is the point: a same-client read can be served
from the writer's own page cache and would pass on a broken kernel.

Checks, per file:
  1. size            -- catches the ISSUE-35 truncation (last 2048 bytes missing)
  2. EVERY BYTE      -- catches unwritten upper halves in earlier full 8 KiB slots,
                        which a size check cannot see.  This is the part the original
                        size sweep was missing.

The expected byte for absolute offset o is ((o >> 9) % 251) + 1 -- identical to
patbyte() in nfstruth.c.  Never zero, distinct per 512-byte region.

usage: nfstruth-verify.py <dir>
"""
import sys, os, re


def patbyte(o):
    return ((o >> 9) % 251) + 1


def check(path, expect):
    data = open(path, "rb").read()
    out = []
    if len(data) != expect:
        out.append("SIZE %d != %d (short by %d)" % (len(data), expect, expect - len(data)))
    bad = []
    for o in range(min(len(data), expect)):
        if data[o] != patbyte(o):
            bad.append(o)
            if len(bad) > 4096:
                break
    if bad:
        # summarise as 512-byte regions, which is how the defect presents
        regions = sorted(set(o >> 9 for o in bad))
        out.append("BYTES %d wrong in %d region(s) of 512; first at offset %d "
                   "(page offset %d of 4096), regions %s%s"
                   % (len(bad), len(regions), bad[0], bad[0] % 4096,
                      regions[:8], " ..." if len(regions) > 8 else ""))
    return out


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: nfstruth-verify.py <dir>")
    d = sys.argv[1]
    files = sorted(f for f in os.listdir(d) if re.match(r"truth\d+\.bin$", f))
    if not files:
        raise SystemExit("no truth*.bin in %s -- run nfstruth on the guest first" % d)
    fails = 0
    for f in files:
        expect = int(re.match(r"truth(\d+)\.bin$", f).group(1))
        problems = check(os.path.join(d, f), expect)
        if problems:
            fails += 1
            print("  FAIL %-18s %s" % (f, "; ".join(problems)))
        else:
            print("  ok   %-18s %d bytes, every byte matches" % (f, expect))
    print()
    print("NFSTRUTH-VERIFY-RESULT %s (%d of %d files bad)"
          % ("FAIL" if fails else "PASS", fails, len(files)))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
