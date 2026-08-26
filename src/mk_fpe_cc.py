#!/usr/bin/env python3
# mk_fpe_cc.py -- build/fpe-cc/, a cross-gcc that also repairs the SGS bit-field operand.
#
# THIS IS A TEMPORARY DUPLICATION OF A TOOLCHAIN FIX, and it is marked as one deliberately.
# The real home of the rewrite is gcc-cross-amix's own wrapper, in the same fix_asm chain that
# already repairs .swbeg, tdivs/tdivu, fsgldiv/fsglmul and the SGS compare operand order.  It
# is not FPE-specific: any C whose codegen reaches the bit-field-find-first-one pattern hits it.
# Until that lands upstream, an FPE build cannot proceed without it, so it is generated here --
# generated, not committed, so that the day the wrapper grows the line this script detects it
# and stops adding a second copy.
#
# THE DEFECT.  gcc 2.7.2.3 emits the SGS spelling of the bit-field operand, with '#' prefixes
# on offset and width:
#
#	bfffo %d3{#0:#32},%d2
#
# GNU as 2.8.1 wants {0:32} and rejects the SGS form outright:
#
#	Error: Missing operand
#	Error: operands mismatch -- statement `bfffo %d3{' ignored
#
# Measured on this tree: fpu_subr.c is the one file of the twenty that hits it, twice
# (contract 7.2 class B).  The rewrite is one perl substitution and the result disassembles as
# a normal bfffo.
#
# WHY A WHOLE WRAPPER COPY RATHER THAN "compile -S, fix, assemble".  The wrapper does NOT run
# fix_asm when it is given -S -- it execs the real compiler and returns raw SGS assembly.  So a
# compile-fix-assemble pipeline outside the wrapper would repair the bit field and silently
# LOSE the four repairs the wrapper normally makes, including .swbeg, whose absence
# misdispatches every switch statement.  Copying the wrapper and adding one line to the same
# chain keeps all five.
#
# Usage: python3 src/mk_fpe_cc.py <outdir>          (prints the compiler path it made)

import os, re, shutil, stat, subprocess, sys

TARGET = "m68k-cbm-sysv4"
ANCHOR = r"""perl -pi -e 's/^(\s*)\.swbeg\s+&(\d+)[ \t]*$/$1.long $2/'"""
FIX = """
	# ADDED by src/mk_fpe_cc.py -- see that script for the defect and for why this
	# belongs in gcc-cross-amix rather than here.  SGS bit-field operand: gcc 2.7.2.3
	# writes bfffo %d3{#0:#32},%d2 and GNU as 2.8.1 wants {0:32}.
	perl -pi -e 's/\\{#(\\d+):#(\\d+)\\}/{$1:$2}/g' "$1"
"""


def main():
    outdir = os.path.abspath(sys.argv[1])
    src = shutil.which(TARGET + "-gcc")
    if not src:
        sys.exit("ABORT: %s-gcc not on PATH (config-load.sh not sourced?)" % TARGET)
    bindir = os.path.dirname(src)
    text = open(src).read()

    if "s/\\{#" in text:
        print("      [skip] %s already repairs the SGS bit-field operand" % src)
        print(src)
        return

    if text.count(ANCHOR) != 1:
        sys.exit("ABORT: the .swbeg anchor is not present exactly once in %s -- the wrapper "
                 "changed shape and this generator must be re-checked" % src)
    text = text.replace(ANCHOR + ' "$1"', ANCHOR + ' "$1"\n' + FIX.strip("\n"))

    os.makedirs(outdir, exist_ok=True)
    # The wrapper resolves $target-gcc.real / -as / -ld relative to its OWN directory, so the
    # whole toolchain has to be reachable from outdir.  Symlinks, never copies: the real tools
    # must stay the installed ones.
    for e in sorted(os.listdir(bindir)):
        if not e.startswith(TARGET + "-"):
            continue
        dst = os.path.join(outdir, e)
        if os.path.islink(dst) or os.path.exists(dst):
            os.remove(dst)
        os.symlink(os.path.join(bindir, e), dst)

    cc = os.path.join(outdir, TARGET + "-gcc")
    os.remove(cc)
    open(cc, "w").write(text)
    os.chmod(cc, os.stat(src).st_mode | stat.S_IXUSR)

    # Prove the added line is there and that nothing else moved.
    d = subprocess.run(["diff", src, cc], capture_output=True, text=True).stdout
    added = [l for l in d.splitlines() if l.startswith("> ")]
    removed = [l for l in d.splitlines() if l.startswith("< ")]
    if removed or not any("{#" in l for l in added):
        sys.exit("ABORT: generated wrapper diff is not the single expected addition:\n" + d)
    print("      [ok]   %s = %s + %d added lines (SGS bit-field operand)"
          % (cc, src, len(added)))
    print(cc)


main()
