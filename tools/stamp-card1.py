#!/usr/bin/env python3
"""stamp-card1.py -- re-stamp an already-gated 040-line AMIX kernel ET_REL from
card 0 to CARD 1 (the Z3660 piscsi controller), located BY SYMBOL.

WHY THIS EXISTS.  amix-kerntools tools/kernel-rootdev-stamp.py is card-0-ONLY, and
not only by contract (bootchain-v1.json rootdev.patch.scope.card) -- by CODE:

  1. Spec.check_id() refuses card != convention.card.
  2. SymbolKernel._decode()'s coherence gate refuses a rootdev whose card != spec.card
     (so it would refuse the card-1 image on read-back).
  3. Spec.device_name() hardcodes "/dev/dsk/c%dd0s%d" -- DECIMAL.  On card 1 the
     controller nibble is 8..15 and the real /dev nodes spell it as ONE HEX digit
     (the box's grid is c0..cf; card 1 / target 6 is `ced0s1`, never `c14d0s1`).
     A decimal formatter would write a swap pathname that does not exist on the box.

(1) and (3) live in the tool, not the contract, so --contract cannot redirect it.
kerntools is read-only in this task, so this script imports the tool AS A MODULE and
reuses its ELF walk, its full input coherence gate, its relocation invariant and its
checksums; it adds ONLY the card-1 arithmetic, the hex node naming, and a card-1-aware
output validation.  The write discipline (atomic replace, whole-file re-read, only the
two intended ranges may differ) is preserved.

Nothing in amix-kerntools is modified.

PROVENANCE.  This lived as an untracked build/stamp-card1.py from the 2026-08-22 re-root
session onwards -- load-bearing (every card-1 artifact since is stamped by it) and outside
version control, which is a bad combination for a tool whose job is to write bytes into a
kernel.  Promoted verbatim on 2026-08-25; the only change is that the path to the
amix-kerntools tool it imports is now resolved rather than hard-coded to one developer's
home directory.
"""
import hashlib
import importlib.util
import os
import struct
import sys

# The sibling repository, by relative path (the same discovery rule amix-kerntools itself
# uses for the driver repos), overridable for a checkout laid out differently.
_HERE = os.path.dirname(os.path.abspath(__file__))
KTOOL = os.environ.get("AMIX_KERNTOOLS_ROOTDEV_STAMP") or os.path.normpath(
    os.path.join(_HERE, os.pardir, os.pardir, "amix-kerntools", "tools",
                 "kernel-rootdev-stamp.py"))


def load_ktool():
    if not os.path.isfile(KTOOL):
        sys.exit("stamp-card1: kernel-rootdev-stamp.py not found at %s\n"
                 "             set AMIX_KERNTOOLS_ROOTDEV_STAMP to its path" % KTOOL)
    spec = importlib.util.spec_from_file_location("krs", KTOOL)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


K = load_ktool()

BLOCK_MAJOR = 18
L_BITSMINOR = 18
L_MAXMIN = 0x3FFFF


# ---------------------------------------------------------------- arithmetic --
# Reimplemented independently of the tool (the contract's conformance_protocol asks
# for independent implementations that AGREE on the vectors), then cross-checked
# against the tool over the card-0 domain where the two overlap.

def compose_minor(unit, slice_, card):
    """amiga/alien/sd.h:  sdunit = bits 0-2, sdcard = bit 3 (SDCARDS 2), sdpart = bits 4-6."""
    assert 0 <= unit <= 7 and 0 <= slice_ <= 7 and 0 <= card <= 1
    return (slice_ << 4) | (card << 3) | unit


def compose_dev(unit, slice_, card):
    """SVR4 makedevice(): (major << L_BITSMINOR) | (minor & L_MAXMIN)."""
    return (BLOCK_MAJOR << L_BITSMINOR) | (compose_minor(unit, slice_, card) & L_MAXMIN)


def decode(dev):
    minor = dev & L_MAXMIN
    return dict(major=(dev >> L_BITSMINOR) & 0xFF, minor=minor,
                unit=minor & 0o7, card=(minor >> 3) & 0o1, slice=(minor >> 4) & 0o7,
                controller=minor & 0x0F, drive=(minor >> 7) & 1)


def node(unit, slice_, card):
    """The /dev node pathname.  The controller is (card<<3)|unit rendered as ONE HEX
    digit -- the box's /dev grid is c0..cf x d0/d1 x s0..s7 (256 nodes = the whole 8-bit
    MINOR space).  For card 0 this is identical to the tool's decimal formatter."""
    return "/dev/dsk/c%xd0s%d" % ((card << 3) | unit, slice_)


def selfcheck(spec0):
    """Prove the independent arithmetic agrees with the tool + the contract where their
    domains overlap (card 0), so the ONLY new behaviour is the card-1 part."""
    problems = []
    for unit in range(8):
        for sl in range(8):
            if compose_dev(unit, sl, 0) != spec0.compose_dev(unit, sl):
                problems.append("compose_dev disagrees at unit %d slice %d" % (unit, sl))
            if node(unit, sl, 0) != spec0.device_name(unit, sl):
                problems.append("node() disagrees with the tool at unit %d slice %d: %s vs %s"
                                % (unit, sl, node(unit, sl, 0), spec0.device_name(unit, sl)))
    # the contract's own published vectors
    contract = K.load_contract()
    for v in contract["rootdev"]["patch"]["vectors"]["valid"]:
        got = compose_dev(v["id"], v["root_slice"], 0)
        if "0x%08x" % got != v["rootdev"]:
            problems.append("contract vector id %d: got 0x%08x want %s"
                            % (v["id"], got, v["rootdev"]))
        if node(v["id"], v["root_slice"], 0) != v["root_device"]:
            problems.append("contract vector id %d: node %s want %s"
                            % (v["id"], node(v["id"], v["root_slice"], 0), v["root_device"]))
        if node(v["id"], v["swap_slice"], 0) != v["swap_device"]:
            problems.append("contract vector id %d: swap node mismatch" % v["id"])
    # the two card-1 facts the C3b run measured behaviourally on this same kernel
    if compose_minor(0, 0, 1) != 8:
        problems.append("card1/target0/slice0 minor != 8 (measured node c8d0s0)")
    if node(0, 0, 1) != "/dev/dsk/c8d0s0":
        problems.append("card1/target0/slice0 node != c8d0s0")
    if node(6, 1, 1) != "/dev/dsk/ced0s1":
        problems.append("card1/target6/slice1 node != ced0s1 (measured, reads the root disk)")
    return problems


# ------------------------------------------------------------------ the stamp --

def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: stamp-card1.py <in-et_rel> <out-et_rel>\n")
        return 2
    src, dst = sys.argv[1], sys.argv[2]

    spec0 = K.Spec(K.load_contract(), K.CONTRACT)

    print("== 0. independent-arithmetic self-check (agrees with the tool + contract on card 0)")
    problems = selfcheck(spec0)
    if problems:
        for p in problems:
            print("   FAIL " + p)
        return 1
    print("   ok  64 card-0 dev_t + 64 card-0 node names identical to the tool's;")
    print("       all 6 contract vectors reproduced; c8d0s0/ced0s1 card-1 names reproduced")

    print("== 1. INPUT GATE -- the unmodified kernel-rootdev-stamp.py coherence gate")
    img = K.SymbolKernel(src, spec0)          # refuses unless fully coherent, card 0
    want_in = compose_dev(6, 1, 0)
    if img.rootdev != want_in:
        sys.stderr.write("REFUSED: input rootdev 0x%08x, expected the card-0 base 0x%08x\n"
                         % (img.rootdev, want_in))
        return 1
    if img.swap_device != node(6, 2, 0):
        sys.stderr.write("REFUSED: input swap %r, expected %r\n"
                         % (img.swap_device, node(6, 2, 0)))
        return 1
    print("   ok  %s" % src)
    print("       rootdev 0x%08x (%s)  swap %s  bo_size %d  rootfstype empty"
          % (img.rootdev, img.root_device, img.swap_device, img.bo_size))
    print("       rootdev @file 0x%x   bo_name @file 0x%x   %d .data relocs scanned, 0 in range"
          % (img.off_rootdev, img.off_name, img.reloc_scanned))

    print("== 2. compose the CARD 1 destination")
    new_dev = compose_dev(6, 1, 1)
    new_swap = node(6, 2, 1)
    d = decode(new_dev)
    print("   rootdev 0x%08x  major %d minor %d = (slice %d << 4)|(card %d << 3)|unit %d  -> %s"
          % (new_dev, d["major"], d["minor"], d["slice"], d["card"], d["unit"],
             node(6, 1, 1)))
    print("   swap dev_t equivalent 0x%08x  minor %d  -> bo_name %s"
          % (compose_dev(6, 2, 1), compose_minor(6, 2, 1), new_swap))

    print("== 3. write the two fields, nothing else")
    out = bytearray(img.data)
    field = spec0.bo["bo_name"][1]                     # 128
    out[img.off_rootdev:img.off_rootdev + 4] = struct.pack(">I", new_dev)
    nm = new_swap.encode("latin1")
    if len(nm) + 1 > field:
        sys.stderr.write("REFUSED: swap name does not fit bo_name\n")
        return 1
    out[img.off_name:img.off_name + field] = nm + b"\0" * (field - len(nm))
    out = bytes(out)

    tmp = dst + ".card1-stamp.tmp"
    with open(tmp, "wb") as fh:
        fh.write(out)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, dst)

    print("== 4. re-read from disk and compare the WHOLE file")
    with open(dst, "rb") as fh:
        back = fh.read()
    if len(back) != len(img.data):
        sys.stderr.write("REFUSED: size changed %d -> %d\n" % (len(img.data), len(back)))
        return 1
    rd = (img.off_rootdev, img.off_rootdev + 4)
    nmr = (img.off_name, img.off_name + field)
    diff = [i for i in range(len(back)) if img.data[i] != back[i]]
    stray = [i for i in diff if not (rd[0] <= i < rd[1] or nmr[0] <= i < nmr[1])]
    if stray:
        sys.stderr.write("REFUSED: %d byte(s) changed outside the two ranges: %s\n"
                         % (len(stray), ["0x%x" % s for s in stray[:8]]))
        return 1
    print("   ok  size unchanged (%d B); exactly %d byte(s) differ, all inside the two ranges:"
          % (len(back), len(diff)))
    for i in diff:
        where = "rootdev+%d" % (i - rd[0]) if rd[0] <= i < rd[1] else "bo_name+%d" % (i - nmr[0])
        print("       @0x%06x  %-12s 0x%02x '%s' -> 0x%02x '%s'"
              % (i, where, img.data[i], chr(img.data[i]) if 32 <= img.data[i] < 127 else '.',
                 back[i], chr(back[i]) if 32 <= back[i] < 127 else '.'))

    print("== 5. OUTPUT VALIDATION -- card-1 aware (the tool's gate cannot run here)")
    bad = []
    got_dev = struct.unpack_from(">I", back, img.off_rootdev)[0]
    g = decode(got_dev)
    if got_dev != new_dev:
        bad.append("rootdev read-back 0x%08x != 0x%08x" % (got_dev, new_dev))
    if g["major"] != BLOCK_MAJOR:
        bad.append("rootdev major %d is not the sd block major %d" % (g["major"], BLOCK_MAJOR))
    if g["card"] != 1:
        bad.append("rootdev card is %d, wanted 1" % g["card"])
    if g["slice"] != 1 or g["unit"] != 6:
        bad.append("rootdev slice/unit = %d/%d, wanted 1/6" % (g["slice"], g["unit"]))
    raw = back[img.off_name:img.off_name + field]
    name = raw.split(b"\0", 1)[0].decode("latin1")
    if name != new_swap:
        bad.append("bo_name %r != %r" % (name, new_swap))
    if raw[len(name):].strip(b"\0"):
        bad.append("bo_name field is not NUL-padded past the string")
    # THE CONSISTENCY CHECK, in hex: the controller digit must equal rootdev's minor & 0x0F
    ctrl_digit = name[len("/dev/dsk/c")]
    if int(ctrl_digit, 16) != g["controller"]:
        bad.append("bo_name controller digit '%s' (=%d) != rootdev minor&0x0F (=%d)"
                   % (ctrl_digit, int(ctrl_digit, 16), g["controller"]))
    if int(name[-1]) != 2:
        bad.append("swap slice in bo_name is not 2")
    # struct bootobj: everything else untouched
    for fname in ("bo_flags", "bo_offset", "bo_vp"):
        off = spec0.bo[fname][0]
        if struct.unpack_from(">I", back, img.off_swapfile + off)[0] != 0:
            bad.append("%s is non-zero" % fname)
    fo, fl = spec0.bo["bo_fstype"]
    if back[img.off_swapfile + fo:img.off_swapfile + fo + fl].strip(b"\0"):
        bad.append("bo_fstype is not empty")
    bo_size = struct.unpack_from(">I", back, img.off_swapfile + spec0.bo["bo_size"][0])[0]
    if bo_size != img.bo_size:
        bad.append("bo_size changed %d -> %d" % (img.bo_size, bo_size))
    # rootfstype still empty
    if back[img.off_rootfstype:img.off_rootfstype + img.rootfstype_size].strip(b"\0"):
        bad.append("rootfstype is no longer empty")
    # anchor still unique, no forbidden string
    if back.count(spec0.anchor) != 1:
        bad.append("anchor no longer occurs exactly once")
    for f in spec0.forbidden:
        if f in back:
            bad.append("forbidden string %r appeared" % f)
    if back.index(spec0.anchor) != img.off_name:
        bad.append("anchor moved")
    # relocation invariant, re-run on the OUTPUT
    elf = K.Elf(back, dst)
    data = elf.section(".data")
    base = data["addr"]
    rd_lo = img.site_rootdev_addr - base
    nm_lo = img.site_swapfile_addr + spec0.bo["bo_name"][0] - base
    rf_lo = img.site_rootfstype_addr - base
    hits = elf.reloc_hits(data, [(rd_lo, rd_lo + 4), (nm_lo, nm_lo + field),
                                 (rf_lo, rf_lo + img.rootfstype_size)])
    if hits:
        bad.append("%d relocation(s) now overlap a written range" % len(hits))
    if elf.e_type != K.ET_REL:
        bad.append("output is no longer ET_REL")
    if bad:
        for b in bad:
            sys.stderr.write("   REFUSED: %s\n" % b)
        return 1
    print("   ok  rootdev 0x%08x major %d minor %d -> card %d target %d slice %d (%s)"
          % (got_dev, g["major"], g["minor"], g["card"], g["unit"], g["slice"], node(6, 1, 1)))
    print("   ok  bo_name %r; controller digit '%s' == rootdev minor&0x0F (%d) [CONSISTENCY]"
          % (name, ctrl_digit, g["controller"]))
    print("   ok  bo_size %d, bo_fstype/bo_flags/bo_offset/bo_vp untouched; rootfstype empty")
    print("   ok  ET_REL preserved; anchor unique at 0x%x; 0 relocations over either range"
          % img.off_name)

    s, blocks = K.sum_r(back)
    print("== 6. identity")
    print("   size %d   sum -r %05d %d   svr4-sum 0x%04x" % (len(back), s, blocks, K.svr4_sum(back)))
    print("   md5    %s" % hashlib.md5(back).hexdigest())
    print("   sha256 %s" % hashlib.sha256(back).hexdigest())
    return 0


if __name__ == "__main__":
    sys.exit(main())
