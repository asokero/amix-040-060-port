#!/usr/bin/env python3
# z3660_modelb.py -- Model B (4 KiB page frame) adaptation of the two Z3660
# drivers for a 68040 kernel (2026-07-31).  Same idiom as va2000_modelb.py:
# the upstream repos are SEPARATE PROJECTS and are never modified; this copies
# their sources into build/ and rewrites the page-geometry sites there, so the
# resulting object's bytes stay traceable to a source line.
#
#   $Z3660_SCSI_SRC                           -> build/z3660_040.c
#   $Z3660_NET_SRC/z3660eth.c                 -> build/z3660eth_040.c   (+ .h copies)
#
# WHY (measured, not assumed): both drivers were written for the stock 68030
# kernel, whose page is 2 KiB.  Compiled against the vanilla headers, they carry
# two classes of 2 KiB dependency, and the first one is silently catastrophic:
#
#   1. phystopfn(pa) inlines from <sys/immu.h> as `pa >> PNUMSHFT` with
#      PNUMSHFT = 11.  Verified in the compiled object: `moveq #11,%d1;
#      lsrl %d1,%d0`, twice in z3660.o (the regs and bounce mappings).  On a
#      Model-B kernel a PFN is pa >> 12, so an unconverted value maps the page
#      at (pa>>11)<<12 = 2*pa -- a mapping of the WRONG PHYSICAL PAGE, which is
#      exactly the device-mmap defect already fixed kernel-side for
#      scrmmap/ammmap/timmap/svgammap and for the VA2000 driver.
#   2. Page COUNTS are sized in 2 KiB units, and the sources said so out loud:
#      z3660.c   `#define BOUNCE_PAGES 32   /* 64KB bounce; Amix NBPP is 2KB, not 4KB! */`
#      z3660eth.h `#define ZZ_FRAME_PAGES 64            /* 64 * 2048 = 128 KB */`
#      Halving them keeps the mapped BYTE size identical, which is what the
#      firmware windows are actually specified in.  (Over-mapping would probably
#      be harmless here since the extra pages are still board space -- but
#      "probably harmless" is not a thing this port ships.)
#
# ---------------------------------------------------------------------------
# BOTH DRIVER TREES HAVE SINCE FIXED (2) AT THE SOURCE, and this script now
# recognises that rather than failing on it.  Upstream's window geometry is
# stated in BYTES and the page count is derived from NBPP at compile time:
#
#      z3660.c    #define BOUNCE_BYTES  0x00010000
#                 #define BOUNCE_PAGES  Z3660_PAGES(BOUNCE_BYTES)
#      z3660eth.h #define ZZ_FRAME_BYTES 0x20000
#                 #define ZZ_FRAME_PAGES ((ZZ_FRAME_BYTES + NBPP - 1) / NBPP)
#
# which is strictly better than halving a literal here: the count follows
# whatever NBPP the compile actually sees, so it cannot disagree with the kernel
# it is being linked into.  Measured through the Model-B mirror sysroot, the
# unmodified sources emit exactly the counts this script used to write by hand
# (`pea 0x10` = 16 bounce pages, `pea 0x20` = 32 frame pages), and through the
# stock sysroot the SAME sources emit 32 and 64.  So on the derived form there
# is nothing left to rewrite, and rewriting anyway would replace a
# self-adjusting expression with a constant -- a regression.
#
# Each page-count site therefore accepts EITHER form and refuses anything else:
# the legacy literal is rewritten as before, the derived expression is left
# alone, and a site that matches neither (or both) aborts the build.  Silent
# drift still fails; upstream having fixed the defect no longer does.
# ---------------------------------------------------------------------------
#
# Every replacement count is asserted exactly, so upstream drift or an
# over-match fails the build instead of producing a quietly wrong driver.
#
# Usage: python3 src/z3660_modelb.py

import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(os.path.dirname(HERE), "build")
# Both driver trees come from config.sh -- see the note in va2000_modelb.py for why these are
# not hard-coded paths any more.
SCSI_SRC = os.environ.get("Z3660_SCSI_SRC")
NET_DIR = os.environ.get("Z3660_NET_SRC")
if not SCSI_SRC or not NET_DIR:
    sys.exit("Z3660_SCSI_SRC and Z3660_NET_SRC must be set (config.sh).  They point at the\n"
             "amix-z3660scsi and amix-z3660net source trees; only relink-040-z3660.sh needs them.")
SCSI_SRC = os.path.expanduser(SCSI_SRC)
NET_DIR = os.path.expanduser(NET_DIR)

PNUM = "((u_int)(paddr) >> 12)"


def sub_exact(text, old, new, count, what):
    n = text.count(old)
    if n != count:
        raise SystemExit("ABORT: %s -- expected %d occurrence(s) of %r, found %d "
                         "(upstream drifted?)" % (what, count, old, n))
    print("  [ok]   %-42s %d site(s)" % (what, count))
    return text.replace(old, new)


def page_count(text, legacy_old, legacy_new, derived_re, what):
    """Accept either the legacy 2 KiB literal or an NBPP-derived expression.

    Exactly one of the two must be present.  The literal is halved (byte size
    unchanged); the derived expression is left untouched, because it already
    produces the Model-B count from the NBPP the compile sees -- see the header
    comment for the measured evidence that the two agree.

    Anything else -- neither form, both forms, or the literal more than once --
    aborts.  The point of this script is that a page count can never be wrong by
    accident, and "I did not recognise the source" is a way to be wrong.
    """
    n_legacy = text.count(legacy_old)
    derived = re.search(derived_re, text, re.M)
    if n_legacy and derived:
        raise SystemExit("ABORT: %s -- source has BOTH the legacy literal and an "
                         "NBPP-derived definition; cannot tell which one the "
                         "compiler will use" % what)
    if n_legacy == 1:
        print("  [ok]   %-42s legacy literal halved" % what)
        return text.replace(legacy_old, legacy_new)
    if n_legacy > 1:
        raise SystemExit("ABORT: %s -- %d copies of the legacy literal, expected 1"
                         % (what, n_legacy))
    if derived:
        print("  [ok]   %-42s already NBPP-derived, left as-is" % what)
        print("         %s" % derived.group(0).strip())
        return text
    raise SystemExit("ABORT: %s -- neither the legacy 2 KiB literal nor an "
                     "NBPP-derived definition found (upstream drifted?).\n"
                     "       Looked for: %r\n"
                     "                or /%s/" % (what, legacy_old, derived_re))


def phystopfn_override(text, marker):
    """Force phystopfn to the Model-B shift right after the immu.h include.

    Overriding at the call site rather than editing <sys/immu.h> keeps the
    licensed sysroot untouched and puts the conversion in the driver's own
    source, where a reader looking at the object can find it.

    KEPT ON PURPOSE THOUGH IT IS NOW REDUNDANT, and that is measured rather than
    assumed: compiled through the Model-B mirror sysroot, the UNMODIFIED driver
    sources produce objects whose .text, .data, relocations, disassembly and
    symbol table are byte-identical to the ones produced from these rewritten
    copies -- the only difference in the file is the embedded source filename.
    The mirror sysroot's <sys/immu.h> already carries PNUMSHFT 12, so this
    #define lands on top of an identical definition.

    It stays because it costs nothing and it is the second of two independent
    guards (the first being mk_modelb_sysroot.sh's probe, the third being the
    object-level check in src/check_page_geometry.sh).  Do not read its presence
    as evidence that the header set is insufficient -- it is not.
    """
    if "sys/immu.h" not in text:
        raise SystemExit("ABORT: %s does not include sys/immu.h -- geometry assumption changed" % marker)
    inc = [l for l in text.split("\n") if "sys/immu.h" in l and l.lstrip().startswith("#include")]
    if len(inc) != 1:
        raise SystemExit("ABORT: %s has %d sys/immu.h includes, expected 1" % (marker, len(inc)))
    line = inc[0]
    block = (line + "\n"
             "/* Model B (4 KiB pages, PNUMSHFT=12): the stock immu.h inlines phystopfn()\n"
             " * with the 2 KiB shift, which would map (pa>>11)<<12 = 2*pa -- the wrong\n"
             " * physical page.  Added by amix-040-060-port/src/z3660_modelb.py. */\n"
             "#undef  phystopfn\n"
             "#define phystopfn(paddr)\t" + PNUM + "\n")
    print("  [ok]   %-42s 1 site" % ("phystopfn -> 4 KiB shift (" + marker + ")"))
    return text.replace(line, block, 1)


def main():
    if not os.path.isdir(BUILD):
        os.makedirs(BUILD)

    # ---- SCSI -------------------------------------------------------------
    if not os.path.exists(SCSI_SRC):
        raise SystemExit("ABORT: %s missing (clone amix-z3660scsi)" % SCSI_SRC)
    t = open(SCSI_SRC).read()
    t = phystopfn_override(t, "z3660.c")
    t = page_count(t,
                   "#define\tBOUNCE_PAGES\t32\t\t/* 64KB bounce; Amix NBPP is 2KB, not 4KB! */",
                   "#define\tBOUNCE_PAGES\t16\t\t/* 64KB bounce; Model B NBPP is 4 KiB (z3660_modelb.py) */",
                   r"^#define\s+BOUNCE_PAGES\s+Z3660_PAGES\(",
                   "BOUNCE_PAGES (64 KB bounce window)")
    open(os.path.join(BUILD, "z3660_040.c"), "w").write(t)
    print("  [ok]   build/z3660_040.c written")

    # ---- ethernet ---------------------------------------------------------
    net_c = os.path.join(NET_DIR, "z3660eth.c")
    if not os.path.exists(net_c):
        raise SystemExit("ABORT: %s missing (clone amix-z3660net)" % net_c)
    t = open(net_c).read()
    t = phystopfn_override(t, "z3660eth.c")
    open(os.path.join(BUILD, "z3660eth_040.c"), "w").write(t)
    print("  [ok]   build/z3660eth_040.c written")

    h = open(os.path.join(NET_DIR, "z3660eth.h")).read()
    h = page_count(h,
                   "#define ZZ_FRAME_PAGES\t64\t\t\t/* 64 * 2048 = 128 KB */",
                   "#define ZZ_FRAME_PAGES\t32\t\t\t/* 32 * 4096 = 128 KB (z3660_modelb.py) */",
                   r"^#define\s+ZZ_FRAME_PAGES\s+\(\(ZZ_FRAME_BYTES\s*\+\s*NBPP",
                   "ZZ_FRAME_PAGES (128 KB frame window)")
    open(os.path.join(BUILD, "z3660eth.h"), "w").write(h)
    for extra in ("z3660ethuser.h",):
        src = os.path.join(NET_DIR, extra)
        if os.path.exists(src):
            shutil.copy(src, os.path.join(BUILD, extra))
            print("  [ok]   %s copied unmodified" % extra)
    print("z3660_modelb: upstream repos untouched; patched copies in build/")


main()
