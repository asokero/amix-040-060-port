#!/usr/bin/env python3
"""nfsreadtruth-gen.py -- HOST side of the NFS read-side test: write the cold files.

The files must be produced BY THE SERVER and never by the AMIX client, and must carry a
name the client has never seen, or the client page cache serves the read and the test
proves nothing.  So this runs on the host, writing through the SMB mount of the same
share the guest has mounted over NFS.

Pattern: byte at absolute offset o is ((o >> 9) % 251) + 1 -- identical to patbyte() in
nfsreadtruth.c and nfstruth.c.  Never zero, distinct per 512-byte region.

usage: nfsreadtruth-gen.py <server-side-dir> <tag>
"""
import sys, os

SIZES = [8192, 8315, 12288, 16507]      # 8192, 8192+123, 12288, 16384+123


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: nfsreadtruth-gen.py <dir> <tag>")
    d, tag = sys.argv[1], sys.argv[2]
    os.makedirs(d, exist_ok=True)
    for sz in SIZES:
        data = bytes((((o >> 9) % 251) + 1) for o in range(sz))
        p = os.path.join(d, "rd%s-%d.bin" % (tag, sz))
        with open(p, "wb") as f:
            f.write(data)
        print("  wrote %s (%d bytes)" % (p, sz))
    print("host side done -- now on the guest:")
    print("  ./nfsreadtruth <nfs-dir> %s" % tag)


if __name__ == "__main__":
    main()
