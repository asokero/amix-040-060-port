#!/usr/bin/env python3
# check_root_family.py -- name, and check, the root-storage family of a linked 040-line AMIX
# kernel: which SCSI controllers it can register at all, and which of them the compiled-in
# rootdev will try to mount root through (2026-08-27).
#
# WHY THIS EXISTS.  A relink pass that takes a base kernel as an argument inherits that base's
# root-storage family silently.  `relink-040-fpe.sh` asserts fifteen things about the FPE glue
# and nothing about the base, so its build log records the artifact's sha256 and not the one
# fact a deployment decision needs -- which controller this kernel will mount root through.
# Round 6 cashed that in: an FPE kernel built over `build/unix-040` (no Z3660 driver, rootdev
# card 0) was staged to the A4000 + Z3660 rig, mounted root through card 0, and bus-errored in
# a3091's initialize() writing 0x00DD0002.  docs/contracts/FPE-R7-METAL.md has the full decode;
# docs/060-F4-M2-PREREG-260824.md:42 registered the same failure, from a different lane, in
# August -- as a gate that was never mechanised.  This is that gate.
#
# WHAT IT READS, all from the artifact and none of it from the build recipe:
#
#   rootdev      .data OBJECT -> major/minor -> card, target, slice, /dev node.
#                minor is (slice << 4) | (card << 3) | unit; amiga/alien/sd.h, SDCARDS 2.
#   bo_name      the swap node, found by the `/dev/dsk/c` anchor, which occurs exactly once.
#   scsicard[]   the table `sd`'s init() walks, taken from the symbol the `lea ...,%a3`
#                relocation at .text+0xD74C actually names -- so a retargeted table
#                (src/patch_z3660.py edit 1) is reported as what it is.
#   loop bound   the `moveq #N,%d1` immediate at .text+0xD79F: init() scans rows 0..N.
#   the rows     12 bytes each: autoconfig id, controller queue function, name string.  The
#                queue function comes from the .rela.data relocation, so what is reported is
#                what will actually be called.
#
# WHAT IT ASSERTS, and fails closed on:
#
#   1. bo_name's controller digit == rootdev minor & 0x0F.  The same consistency rule
#      tools/stamp-card1.py:230-234 enforces at stamp time, re-checked wherever this runs.
#   2. loop bound + 1 == the number of rows the named table actually has, where the table
#      symbol carries a size.  src/patch_z3660.py writes both; a stale bound against a
#      retargeted table would walk off the end of one or ignore a row of the other.
#   3. every row the loop will scan resolves to a DEFINED controller-queue function.
#   4. rootdev's card < SDCARDS.
#
# WHAT IT DOES NOT DO is decide which family is right.  It cannot: whether card 0 is a real
# A3000 controller or a phantom that answers autoconfig and then does not drive DSACK is a
# property of the rig, not of the image.  --require-queue and --require-card let a build that
# knows its target rig say so, and refuse a base of the wrong family instead of discovering it
# on the bench.
#
#   python3 src/check_root_family.py <kernel>
#   python3 src/check_root_family.py <kernel> --require-queue z3660queue --require-card 1
#
# Exit 0 = coherent (and, if given, the requirements are met).  Exit 1 = refused.

import struct
import sys

SDCARDS = 2
ROW = 12                       # scsicard[] row: { long id; long (*queue)(); char *name; }
LEA_SITE = 0x0000D74A          # `lea <scsicard>,%a3`
LEA_OPCODE = b"\x47\xf9"
LEA_RELOC = 0x0000D74C         # its operand -- the relocation src/patch_z3660.py retargets
BOUND_SITE = 0x0000D79E        # `moveq #N,%d1`
MOVEQ_OPCODE = 0x72
ANCHOR = b"/dev/dsk/c"
R_68K_32 = 1
STT_SECTION = 3
SHN_UNDEF = 0
L_BITSMINOR = 18
L_MAXMIN = 0x3FFFF


def u16(b, o):
    return struct.unpack(">H", b[o:o + 2])[0]


def u32(b, o):
    return struct.unpack(">I", b[o:o + 4])[0]


def i32(b, o):
    return struct.unpack(">i", b[o:o + 4])[0]


class Elf(object):
    def __init__(self, path):
        self.path = path
        self.b = open(path, "rb").read()
        b = self.b
        if b[:4] != b"\x7fELF":
            raise SystemExit("REFUSED: %s is not ELF" % path)
        if u16(b, 16) != 1:
            raise SystemExit("REFUSED: %s is not ET_REL" % path)
        shoff, shentsize = u32(b, 32), u16(b, 46)
        shnum, shstrndx = u16(b, 48), u16(b, 50)
        self.sh = []
        for i in range(shnum):
            o = shoff + i * shentsize
            self.sh.append(dict(name=u32(b, o), addr=u32(b, o + 12), offset=u32(b, o + 16),
                                size=u32(b, o + 20), link=u32(b, o + 24),
                                entsize=u32(b, o + 36)))
        shstr = self.sh[shstrndx]["offset"]

        def sname(s):
            e = b.index(b"\0", shstr + s["name"])
            return b[shstr + s["name"]:e].decode()

        self.names = [sname(s) for s in self.sh]
        self.byname = dict(zip(self.names, self.sh))
        for want in (".text", ".data", ".symtab", ".rela.text", ".rela.data"):
            if want not in self.byname:
                raise SystemExit("REFUSED: %s has no %s -- not a relinked kernel of this port"
                                 % (path, want))
        st = self.byname[".symtab"]
        self.stroff = self.sh[st["link"]]["offset"]
        self.syo, self.sye = st["offset"], st["entsize"]
        self.syn = st["size"] // self.sye
        self._byname = None

    def symname(self, i):
        n = u32(self.b, self.syo + i * self.sye)
        e = self.b.index(b"\0", self.stroff + n)
        return self.b[self.stroff + n:e].decode("latin1")

    def sym(self, i):
        o = self.syo + i * self.sye
        return dict(name=self.symname(i), value=u32(self.b, o + 4), size=u32(self.b, o + 8),
                    info=self.b[o + 12], shndx=u16(self.b, o + 14))

    def lookup(self, name):
        """First DEFINED symbol of that name, else the first of any, else None."""
        if self._byname is None:
            self._byname = {}
            for i in range(self.syn):
                s = self.sym(i)
                if not s["name"]:
                    continue
                cur = self._byname.get(s["name"])
                if cur is None or (cur["shndx"] == SHN_UNDEF and s["shndx"] != SHN_UNDEF):
                    self._byname[s["name"]] = s
        return self._byname.get(name)

    def secbytes(self, name):
        s = self.byname[name]
        return self.b[s["offset"]:s["offset"] + s["size"]]

    def relocs(self, section):
        """{ r_offset: (symbol index, type, addend) } for one .rela.* section."""
        s = self.byname[section]
        out = {}
        for i in range(s["size"] // s["entsize"]):
            o = s["offset"] + i * s["entsize"]
            info = u32(self.b, o + 4)
            out[u32(self.b, o)] = (info >> 8, info & 0xFF, i32(self.b, o + 8))
        return out

    def target(self, relidx, addend):
        """Where a relocation points: (section name or None, offset within it, symbol name)."""
        s = self.sym(relidx)
        if s["info"] & 0xF == STT_SECTION:
            sec = self.names[s["shndx"]] if s["shndx"] < len(self.names) else None
            return sec, addend, sec or "?"
        sec = self.names[s["shndx"]] if 0 < s["shndx"] < len(self.names) else None
        return sec, s["value"] + addend, s["name"]

    def cstr(self, secname, off):
        try:
            d = self.secbytes(secname)
            return d[off:d.index(b"\0", off)].decode("latin1")
        except Exception:
            return None


def decode_dev(dev):
    minor = dev & L_MAXMIN
    return dict(major=(dev >> L_BITSMINOR) & 0xFF, minor=minor,
                unit=minor & 0o7, card=(minor >> 3) & 1, slice=(minor >> 4) & 0o7,
                controller=minor & 0x0F)


def node(card, unit, sl):
    # The controller is (card<<3)|unit rendered as ONE HEX digit: the /dev grid is c0..cf.
    return "/dev/dsk/c%xd0s%d" % ((card << 3) | unit, sl)


def main():
    argv = sys.argv[1:]
    if not argv or argv[0].startswith("-"):
        raise SystemExit("usage: check_root_family.py <kernel> "
                         "[--require-queue SYM] [--require-card N]")
    path = argv[0]
    want_queue = want_card = None
    i = 1
    while i < len(argv):
        if argv[i] == "--require-queue" and i + 1 < len(argv):
            want_queue = argv[i + 1]; i += 2
        elif argv[i] == "--require-card" and i + 1 < len(argv):
            want_card = int(argv[i + 1]); i += 2
        else:
            raise SystemExit("check_root_family: unknown argument %r" % argv[i])

    e = Elf(path)
    text = e.secbytes(".text")
    data = e.secbytes(".data")
    bad = []

    # ---------------------------------------------------------------- the root device
    rd = e.lookup("rootdev")
    if rd is None or e.names[rd["shndx"]] != ".data":
        raise SystemExit("REFUSED: no rootdev in .data -- not an 040-line kernel of this port")
    dev = u32(data, rd["value"])
    g = decode_dev(dev)
    root_node = node(g["card"], g["unit"], g["slice"])

    # ---------------------------------------------------------------- the swap node
    if e.b.count(ANCHOR) != 1:
        bad.append("the %r anchor occurs %d times, expected exactly once"
                   % (ANCHOR.decode(), e.b.count(ANCHOR)))
        swap = None
    else:
        o = e.b.index(ANCHOR)
        swap = e.b[o:e.b.index(b"\0", o)].decode("latin1")

    # ---------------------------------------------------------------- the controller registry
    if text[LEA_SITE:LEA_SITE + 2] != LEA_OPCODE:
        raise SystemExit("REFUSED: .text+0x%x holds %s, not the `lea <scsicard>,%%a3` opcode "
                         "%s -- this image is not the one these offsets were measured against"
                         % (LEA_SITE, text[LEA_SITE:LEA_SITE + 2].hex(), LEA_OPCODE.hex()))
    if text[BOUND_SITE] != MOVEQ_OPCODE:
        raise SystemExit("REFUSED: .text+0x%x holds 0x%02x, not a moveq -- the scsicard loop "
                         "bound has moved" % (BOUND_SITE, text[BOUND_SITE]))
    bound = text[BOUND_SITE + 1]
    nrows = bound + 1

    rt = e.relocs(".rela.text").get(LEA_RELOC)
    if rt is None or rt[1] != R_68K_32:
        raise SystemExit("REFUSED: no R_68K_32 relocation at .text+0x%x -- the scsicard[] "
                         "operand is not relocated" % LEA_RELOC)
    tsec, toff, tname = e.target(rt[0], rt[2])
    if tsec != ".data":
        raise SystemExit("REFUSED: scsicard[] symbol %r is not in .data (%s)" % (tname, tsec))
    tsym = e.lookup(tname)
    tsize = tsym["size"] if tsym else 0

    dr = e.relocs(".rela.data")
    rows = []
    for r in range(nrows):
        base = toff + r * ROW
        if base + ROW > len(data):
            bad.append("row %d runs past the end of .data" % r)
            break
        ident = u32(data, base)
        qrel = dr.get(base + 4)
        nrel = dr.get(base + 8)
        qname = qsec = None
        if qrel is None:
            bad.append("row %d has no relocation on its queue pointer" % r)
        else:
            qsec, _, qname = e.target(qrel[0], qrel[2])
        label = None
        if nrel is not None:
            nsec, noff, _ = e.target(nrel[0], nrel[2])
            if nsec in (".data", ".text"):
                label = e.cstr(nsec, noff)
        rows.append((r, ident, qname, label))
        if qname:
            qs = e.lookup(qname)
            if qs is None or qs["shndx"] == SHN_UNDEF:
                bad.append("row %d names %s, which is not defined in this image" % (r, qname))

    # ---------------------------------------------------------------- the assertions
    if tsize and tsize % ROW == 0 and tsize // ROW != nrows:
        bad.append("loop bound %d scans %d rows but %s is %d bytes = %d rows"
                   % (bound, nrows, tname, tsize, tsize // ROW))
    if swap is not None:
        digit = swap[len("/dev/dsk/c")]
        try:
            if int(digit, 16) != g["controller"]:
                bad.append("bo_name controller digit %r (=%d) != rootdev minor&0x0F (=%d)"
                           % (digit, int(digit, 16), g["controller"]))
        except ValueError:
            bad.append("bo_name controller digit %r is not hex" % digit)
    if g["card"] >= SDCARDS:
        bad.append("rootdev card %d >= SDCARDS %d -- queue[] has no such slot"
                   % (g["card"], SDCARDS))

    queues = [q for (_, _, q, _) in rows if q]

    # ---------------------------------------------------------------- the report
    print("   root      rootdev @.data+0x%06x = 0x%08x  major %d minor 0x%02x"
          % (rd["value"], dev, g["major"], g["minor"]))
    print("             = card %d / target %d / slice %d  ->  %s"
          % (g["card"], g["unit"], g["slice"], root_node))
    print("   swap      bo_name %r" % swap)
    print("   registry  %s @.data+0x%06x, loop bound %d -> %d row(s) scanned%s"
          % (tname, toff, bound, nrows,
             ", symbol size %d" % tsize if tsize else ""))
    for (r, ident, qname, label) in rows:
        print("      row %d  id 0x%08x  %-12s %s"
              % (r, ident, qname or "<unrelocated>", "%r" % label if label else ""))
    print("   FAMILY    root=card%d(%s) queues=%s" % (g["card"], root_node, "+".join(queues)))

    # ---------------------------------------------------------------- the requirements
    if want_queue is not None and want_queue not in queues:
        bad.append("--require-queue %s: not among the rows this kernel scans (%s). This image "
                   "cannot serve a rig whose root is on that controller, at any RAM size and "
                   "any load base -- the capability is absent, not merely unselected."
                   % (want_queue, "+".join(queues) or "none"))
    if want_card is not None and g["card"] != want_card:
        bad.append("--require-card %d: rootdev names card %d (%s)"
                   % (want_card, g["card"], root_node))

    if bad:
        sys.stderr.write("\n")
        for m in bad:
            sys.stderr.write("REFUSED: %s\n" % m)
        return 1
    print("   [ok]   root-storage family coherent%s"
          % ("" if want_queue is None and want_card is None else " and as required"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
