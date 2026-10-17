#!/usr/bin/env python3
"""rth1-record.py -- encode, write and decode the RTH1 root hint's records
(docs/contracts/RTH1-ROOT-HINT.md).  The reference encoder for the installer and the rigs.

  rth1-record.py rootrec --unit N (--id 0xMMMMPP00 | --base 0xADDR | --mobo) [--base 0xADDR]
        print the 0x1c-byte RTO1 root record as hex
  rth1-record.py write-rootrec IMAGE --slice OFFSET --unit N (...as above...)
        write it into the kernel info block of the boot slice at byte OFFSET of IMAGE
        (IBLK at OFFSET+0x2600, record at +0x100 = OFFSET+0x2700); refuses to overwrite anything
        but zeros or an earlier RTO1
  rth1-record.py clear-rootrec IMAGE --slice OFFSET
        zero the record area again
  rth1-record.py show-rootrec IMAGE --slice OFFSET
  rth1-record.py decode HEX
        decode an RTH1 record (0x38 bytes, e.g. read from kernel bootinfo+0x678) or an RTO1 one

--id is er_Manufacturer << 16 | er_Product << 8, e.g. 0x144b0100 for the Z3660 SCSI,
0xc0de0100 for the A4092 and 0x02025400 for the A4091.  The slice offset is what
amix-kerntools/tools/bootpart-kernel.py show prints as "boot slice: offset".
"""
import argparse, struct, sys

RTH1, RTO1 = 0x52544831, 0x52544F31
IBLK_OFF, REC_IN_IBLK, RTO1_LEN, RTH1_LEN = 0x2600, 0x100, 0x1c, 0x38
FLAGS = [(0x01, "BOOT"), (0x02, "BCDEV"), (0x04, "BMOBO"), (0x08, "ROOT"), (0x10, "AMBIG")]


def seal(longs):
    return longs + [(-sum(longs)) & 0xFFFFFFFF]


def rootrec(unit, base, ident, mobo):
    if not 0 <= unit <= 7:
        raise SystemExit("ABORT: unit %d: the Amix unit is a SCSI target 0-7" % unit)
    if not mobo and base == 0 and ident == 0:
        raise SystemExit("ABORT: name the controller: --id, --base or --mobo")
    if mobo and (base or ident):
        raise SystemExit("ABORT: --mobo names the motherboard controller; it takes no --id/--base")
    return struct.pack(">7I", *seal([RTO1, 0x00010000 | RTO1_LEN, unit, base, ident, 1 if mobo else 0]))


def sum0(b):
    return sum(struct.unpack(">%dI" % (len(b) // 4), b)) & 0xFFFFFFFF == 0


def describe_rto1(b):
    m, vl, unit, base, ident, fl, ck = struct.unpack(">7I", b)
    ok = m == RTO1 and vl >> 16 == 1 and (vl & 0xFFFF) >= RTO1_LEN and sum0(b)
    ctl = "motherboard" if fl & 1 else ("board %08x" % base if base else "id %06x" % (ident >> 8))
    return "RTO1 %s: unit %d, %s%s" % ("valid" if ok else "INVALID", unit, ctl,
                                       (" id %06x" % (ident >> 8)) if base and ident else "")


def describe_rth1(b):
    w = struct.unpack(">14I", b[:RTH1_LEN])
    ok = w[0] == RTH1 and w[1] >> 16 == 1 and (w[1] & 0xFFFF) >= RTH1_LEN and sum0(b[:28])
    fl = "|".join(n for v, n in FLAGS if w[2] & v) or "0"
    out = ["RTH1 %s: flags %s, boot unit %d, board %08x, id %06x"
           % ("valid" if ok else "INVALID", fl, w[3], w[4], w[5] >> 8)]
    root = b[28:56]
    out.append("  root: " + (describe_rto1(root) if any(root) else "none"))
    return "\n".join(out)


def image_slot(path, slice_off):
    with open(path, "rb") as f:
        f.seek(slice_off + IBLK_OFF)
        iblk = f.read(512)
    if iblk[:4] != b"IBLK":
        raise SystemExit("ABORT: no kernel IBLK at %s+0x%x (is --slice the boot slice?)" % (path, slice_off + IBLK_OFF))
    return iblk[REC_IN_IBLK:REC_IN_IBLK + RTO1_LEN]


def write_at(path, off, data):
    with open(path, "r+b") as f:
        f.seek(off)
        f.write(data)


def ctl_args(p):
    p.add_argument("--unit", type=int, required=True)
    p.add_argument("--id", type=lambda s: int(s, 0), default=0)
    p.add_argument("--base", type=lambda s: int(s, 0), default=0)
    p.add_argument("--mobo", action="store_true")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("rootrec"); ctl_args(p)
    for name in ("write-rootrec", "clear-rootrec", "show-rootrec"):
        p = sub.add_parser(name)
        p.add_argument("image")
        p.add_argument("--slice", type=lambda s: int(s, 0), required=True)
        if name == "write-rootrec":
            ctl_args(p)
    p = sub.add_parser("decode"); p.add_argument("hex", nargs="+")
    a = ap.parse_args()

    if a.cmd == "rootrec":
        print(rootrec(a.unit, a.base, a.id, a.mobo).hex())
    elif a.cmd == "decode":
        b = bytes.fromhex("".join(a.hex))
        if b[:4] == struct.pack(">I", RTO1):
            print(describe_rto1(b[:RTO1_LEN]))
        else:
            print(describe_rth1(b))
    else:
        cur = image_slot(a.image, a.slice)
        at = a.slice + IBLK_OFF + REC_IN_IBLK
        if a.cmd == "show-rootrec":
            print(describe_rto1(cur) if any(cur) else "no root record")
            return
        if any(cur) and cur[:4] != struct.pack(">I", RTO1):
            raise SystemExit("ABORT: IBLK+0x100 holds %s, neither zeros nor an RTO1 -- not overwriting" % cur.hex())
        if a.cmd == "clear-rootrec":
            write_at(a.image, at, bytes(RTO1_LEN))
            print("cleared the root record at %s+0x%x" % (a.image, at))
        else:
            rec = rootrec(a.unit, a.base, a.id, a.mobo)
            write_at(a.image, at, rec)
            if image_slot(a.image, a.slice) != rec:
                raise SystemExit("ABORT: read-back differs")
            print("wrote %s at %s+0x%x" % (describe_rto1(rec), a.image, at))


main()
