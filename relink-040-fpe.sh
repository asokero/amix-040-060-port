#!/bin/sh
# relink-040-fpe.sh -- link the NetBSD/m68k floating-point emulator into a 68040/68060 kernel,
# so that a part with no FPU runs floating point instead of taking SIGSYS (2026-08-26).
#
# For a 68LC060 this is the difference between "awk 3.75 prints nothing and the process dies"
# and a working libc.  On a part that HAS an FPU nothing here engages: fpuinit's probe is the
# authority, the emulator arms only on its negative answer, and fpe_entry_n stays 0 for the
# whole boot.  That counter is the regression bar.  Its one deliberate exception is the
# fpe_v11_* frame-format census, counted AHEAD of both gates and expected to move on any rig --
# it is how an FPU-present 68040 latches the format-2 frame this tree has only ever cited
# (docs/contracts/FPE-R4-DELTA.md 5).
#
#   sh relink-040-fpe.sh [base-kernel] [output]
#   FPE=0 sh relink-040-fpe.sh ...        rollback: reproduce the base image byte for byte
#
# WHAT GOES IN
#   build/fpe-src/      20 NetBSD C files + 4 machine-ABI headers, EXTRACTED at build time
#                       from the pinned tarball by src/extract_fpe.sh -- never checked in
#   src/fpe-compat/     first-party headers for what AMIX does not have (and for the two
#                       places NetBSD's headers collide with AMIX's)
#   src/fpe_glue.c      the trap-frame shim, the entry lock, the interposed panic/copy paths,
#                       and the SVR4 si_code derivation
#   src/fpe040.s        the vector-11 arm, the FP-state presentation, and the .balign 4 that
#                       closes the link -- so it is linked LAST, always
#
# Contract: docs/contracts/FPE-INTEGRATION-CONTRACT.md.  Design: docs/contracts/
# FPE-GLUE-DESIGN.md.  Read the design doc before changing anything in here; several of the
# steps below look like taste and are not.
#
# THIS RUNS AFTER relink-040.sh, over its finished output, and that is deliberate.  The arm
# has to sit ahead of fpsp_vec11, and the way this port installs a handler ahead of another is
# a vector-table relocation retarget, not a source edit to the handler being displaced.  So
# nothing in relink-040.sh moves, an FPE kernel is one extra pass over a normal one, and
# "without the FPE" is the base image itself rather than a second configuration of the first.

set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tools/config-load.sh"
. "$HERE/tools/build-step.sh"

FPE="${FPE:-1}"
IN="${1:-$HERE/build/unix-040}"
OUT="${2:-$HERE/build/unix-040-fpe}"

[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
echo "[*] base: $(basename "$IN")  ($(sha256sum "$IN" | cut -c1-16)...)"

# ---------------------------------------------------------------- the rollback switch
# Not "skip some steps": produce the base image and PROVE it is the base image.  A rollback
# that is only believed is not a rollback.
if [ "$FPE" = 0 ]; then
	cp "$IN" "$OUT"
	A=$(sha256sum "$IN"  | cut -d' ' -f1)
	B=$(sha256sum "$OUT" | cut -d' ' -f1)
	[ "$A" = "$B" ] || { echo "[FAIL] FPE=0 output differs from the base"; exit 1; }
	echo "[OK] FPE=0: $OUT is the base image, sha256 $A"
	exit 0
fi

# ---------------------------------------------------------------- 0. the extracted tree
# The emulator is not in this repository.  It comes out of the same pinned NetBSD tarball the
# FPSP does (build-fpsp040.sh), into build/fpe-src/, and the gate is a freshness gate: extract
# when the tree is absent, refuse when what is there is not the tarball's bytes.
echo "[*] FPE sources from the pinned tarball (extract, then diff against it)"
run_step indent sh "$HERE/src/extract_fpe.sh"
FPESRC="$HERE/build/fpe-src"

# ---------------------------------------------------------------- 1. the header set
# Same Model-B mirror sysroot every C file compiled into this kernel must see, established
# exactly as relink-040-z3660.sh:38-41 does.  The emulator does no page arithmetic, but it
# includes <sys/param.h>, and a kernel built from two page geometries is not a thing to find
# out about later.
echo "[*] Model-B header set (mirror sysroot + geometry probe)"
sh "$HERE/src/mk_modelb_sysroot.sh" | sed 's/^/      /'
AMIX_SYSROOT="$HERE/build/sysroot-modelb"
export AMIX_SYSROOT

# ---------------------------------------------------------------- 2. the compiler
# gcc 2.7.2.3 emits the SGS bit-field operand `bfffo %d3{#0:#32},%d2` and GNU as 2.8.1 rejects
# it; fpu_subr.c is the one file of the twenty that hits it.  The repair belongs in
# gcc-cross-amix's wrapper beside the four it already makes, and until it lands there this
# generates a wrapper that has it.  See src/mk_fpe_cc.py -- including why the obvious
# "compile -S, fix, assemble" is wrong.
echo "[*] compiler with the SGS bit-field repair"
CCLOG="$HERE/build/fpe-cc.log"
python3 "$HERE/src/mk_fpe_cc.py" "$HERE/build/fpe-cc" >"$CCLOG" 2>&1 \
	|| { sed 's/^/    /' "$CCLOG"; exit 1; }
sed '$d' "$CCLOG"
CC=$(tail -1 "$CCLOG")
[ -x "$CC" ] || { echo "[FAIL] no usable compiler from mk_fpe_cc.py"; exit 1; }

# ---------------------------------------------------------------- 3. the emulator objects
# The include order is forced, not chosen.  The cross-gcc wrapper prepends the sysroot include
# path ahead of every command-line -I, so a shim can never shadow an AMIX header: every MI
# header the emulator includes (<sys/types.h>, <sys/param.h>, <sys/systm.h>, <sys/signal.h>,
# <sys/siginfo.h>, <sys/time.h>, <float.h>, <stdio.h>, <stdlib.h>, <string.h>) is AMIX's own.
# What the two -I directories add is what AMIX does not have -- and fpe-compat comes first so
# that its m68k/m68k.h shadows the NetBSD one, which is the cputype collision's fix.
CF=$(echo "$AMIX_KERNEL_CFLAGS" | sed 's/-m68020/-m68040/')
INC="-I$HERE/src/fpe-compat -I$FPESRC/include -I$FPESRC"

# The three interpositions, and each is a contract this port must keep and the emulator code
# does not.  See src/fpe_glue.c for all three bodies.
#   panic    frozen decision 8: a user process's arithmetic never takes the kernel down
#   copyin   FPSP-INTEGRATION-PLAN.md:350-367: the return value may not be ignored, and the
#   copyout  the emulator's fpu_calcea.c ignores all six of them
DEFS="-Dpanic=fpe_panic -Dcopyin=fpe_copyin -Dcopyout=fpe_copyout"

echo "[*] cross-compiling the 20 extracted emulator files"
OBJDIR="$HERE/build/fpe-obj"
rm -rf "$OBJDIR"; mkdir -p "$OBJDIR"
FPEOBJS=
for f in "$FPESRC"/*.c; do
	b=$(basename "$f" .c)
	"$CC" $CF $INC $DEFS -c "$f" -o "$OBJDIR/$b.o"
	FPEOBJS="$FPEOBJS $OBJDIR/$b.o"
done
N=$(echo $FPEOBJS | wc -w)
[ "$N" = 20 ] || { echo "[FAIL] $N objects, expected 20 (files.fpe lists 20)"; exit 1; }
echo "      20/20 objects, $(m68k-linux-gnu-size $FPEOBJS | awk 'NR>1{t+=$1;d+=$2;b+=$3}
	END{printf ".text %d  .data %d  .bss %d", t, d, b}')"

# The 396 bytes of .bss are the emulator's per-invocation state -- fpu_emulate.c's `insn` and
# `fe`, and function-local statics in fpu_log.c and fpu_rem.c.  It is shared, so entry is
# serialised (FPE-GLUE-DESIGN.md 4.1).  Asserted here because a vendor import that grew a new
# static would otherwise pass silently through a lock designed for these three files.
BSS=$(m68k-linux-gnu-size $FPEOBJS | awk 'NR>1{b+=$3} END{print b}')
[ "$BSS" = 396 ] || {
	echo "[FAIL] emulator .bss is $BSS bytes, expected 396."
	echo "       That is the shared emulator state the entry lock exists for; a change means"
	echo "       new state whose lifetime has not been argued.  See FPE-GLUE-DESIGN.md 4.1."
	exit 1
}

# ---------------------------------------------------------------- 4. the glue
echo "[*] compiling the glue"
"$CC" $CF $INC -c "$HERE/src/fpe_glue.c" -o "$OBJDIR/fpe_glue.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/fpe040.s" -o "$OBJDIR/fpe040.o"
m68k-linux-gnu-size "$OBJDIR/fpe_glue.o" "$OBJDIR/fpe040.o" | sed 's/^/      /'

# ---------------------------------------------------------------- 5. the override surface
# Seven strong symbols get replaced and one file-local one gets exposed.
#
#   prhasfp                    answers for fpu_present OR fpu_emul (frozen decision 9).  No
#                              *_orig: the body is one instruction and is fully replaced.
#   fpuinit                    runs the accepted probe first, arms only on its no-FPU answer
#   fpu_save/restore/setup     present an idle 68881 frame instead of touching hardware
#   fpu_setup_gated            the sendsig gate, answered for the pair (round 4 fix 2)
#   setregs                    the exec gate lives INSIDE the stock body, so owning setregs is
#                              the only way to reach it (round 4 fix 2)
#   trapsig                    file-local in stock; the glue builds the k_siginfo_t itself and
#                              needs the entry point u_trap uses
#
# Addresses come from nm of THIS base, never from a note: whichever of these bodies is already
# an override from relink-040.sh (src/fpu060.s, src/fpuinit060.s, src/srgtrap.s) is what the
# *_fpe_orig alias must reach, and those move with every build.  So the chains are ours -> this
# port's own arm -> the stock body, intact in both directions.
echo "[*] weakening the override surface (addresses read from the base, not assumed)"
STAGE="$HERE/build/unix-stage-fpe"
cp "$IN" "$STAGE"
OCARGS="--globalize-symbol trapsig --weaken-symbol prhasfp"
for s in fpuinit fpu_save fpu_restore fpu_setup fpu_setup_gated setregs; do
	A=$(m68k-linux-gnu-nm "$IN" | awk -v s="$s" '$3==s && ($2=="T"||$2=="t"){print $1}')
	[ -n "$A" ] || { echo "[FAIL] $s not found in $IN"; exit 1; }
	echo "      $s -> ${s}_fpe_orig @ 0x$A"
	OCARGS="$OCARGS --weaken-symbol $s --add-symbol ${s}_fpe_orig=.text:0x${A},function,global"
done
m68k-linux-gnu-objcopy $OCARGS "$STAGE"

# ---------------------------------------------------------------- 6. the link
# ORDER MATTERS, and it is the .balign law of BUILDING.md:249-250.  The loader copies text and
# data as ONE block and places .bss at data_end UNALIGNED, so the final .text and .data sizes
# have to be multiples of 4.  Seven of the twenty emulator objects have a .text size that is
# 2 mod 4 (fpu_exp 1558, fpu_int 234, fpu_log 4902, fpu_mul 938, fpu_rem 770, fpu_subr 402,
# fpu_trig 3070), the compiler pads to 2, and a COMPILED object cannot end its own section
# with .balign 4.  src/fpe040.s does, so it goes last -- and the two guards after the link are
# what actually check it rather than trusting this comment.
echo "[*] ld -r: base + 20 emulator + glue (fpe040.o LAST: it carries the .balign 4)"
m68k-cbm-sysv4-ld -r -o "$OUT" "$STAGE" $FPEOBJS "$OBJDIR/fpe_glue.o" "$OBJDIR/fpe040.o"

# ---------------------------------------------------------------- 7. symbol assertions
echo "[*] symbols that must be defined:"
for s in fpe_magic fpe_vec11 fpe_decline fpe_trap fpe_setjmp fpe_longjmp fpu_emul fpe_sigpend \
	 fpe_entry_n fpe_cputype fpe_cputype_amix fpu_emulate ufetch_short \
	 fpe_panic fpe_copyin fpe_copyout \
	 prhasfp fpuinit fpu_save fpu_restore fpu_setup fpu_setup_gated setregs \
	 fpuinit_fpe_orig fpu_save_fpe_orig fpu_restore_fpe_orig fpu_setup_fpe_orig \
	 fpu_setup_gated_fpe_orig setregs_fpe_orig trapsig; do
	m68k-linux-gnu-nm "$OUT" | grep -E " [TtDdBb] $s\$" | sed "s/^/      /" \
		|| { echo "[FAIL] $s not defined"; exit 1; }
done

# The override actually moved.  `ld -r` does not fail when a definition is dropped -- it
# leaves the stock body strong and links cleanly (BUILDING.md:252-255), which is the failure
# mode this port has paid for.  So ask: is there exactly ONE definition of each, and is it
# ours?  Ours are the ones at a higher address than the base's text end.
BASETEXT=$(m68k-linux-gnu-readelf -SW "$STAGE" | awk '{gsub(/[][]/,"")} $2==".text"{print strtonum("0x"$6)}')
for s in prhasfp fpuinit fpu_save fpu_restore fpu_setup fpu_setup_gated setregs; do
	A=$(m68k-linux-gnu-nm "$OUT" | awk -v s="$s" '$3==s && $2=="T"{print strtonum("0x"$1)}')
	C=$(echo "$A" | wc -w)
	[ "$C" = 1 ] || { echo "[FAIL] $s has $C strong definitions"; exit 1; }
	[ "$A" -ge "$BASETEXT" ] || {
		echo "[FAIL] $s still resolves into the base image at $A (< base .text end $BASETEXT)"
		echo "       -- the weaken/override did not take."
		exit 1; }
	echo "      $s overridden (0x$(printf %x $A), past the base's .text end)"
done

LEAK=$(m68k-linux-gnu-nm "$OUT" | awk '$1=="U" && $2!="edata" && $2!="end" && $2!="etext" {print $2}')
[ -z "$LEAK" ] || { echo "[FAIL] unresolved symbols:"; echo "$LEAK"; exit 1; }
echo "[OK] no unresolved symbols"

# src/ucz_dbg.s must never be in an FPE kernel.  Its bzero of mc_state[4..199] is safe only
# while that field is never written, and under emulation prhasfp() is true, so prgetfpstate
# genuinely fills mc_state[23..76] with the FP state -- 216 real bytes the arm would destroy.
# Its own uc_flags gate happens to decline for that reason, but "declines by luck" is not the
# property to ship: the gate is here, at the link.  FPE-GLUE-DESIGN.md 7.
m68k-linux-gnu-nm "$OUT" | grep -qE " [Dd] ucp_magic\$" && {
	echo "[FAIL] src/ucz_dbg.s is linked into this kernel and must not be -- see"
	echo "       FPE-GLUE-DESIGN.md section 7."
	exit 1; }
echo "[OK] ucz_dbg not linked"

# ---------------------------------------------------------------- 8. the vector
echo "[*] vector-11 arm"
run_step indent python3 "$HERE/src/patch_fpe_vec11.py" "$OUT"

# ---------------------------------------------------------------- 9. packaging guards
# The standard pair every relink in this tree runs, plus the .text one that this build is the
# first to actually need.
CONTIG=$(m68k-linux-gnu-readelf -SW "$OUT" | awk '
	{gsub(/[][]/,"")}
	$2==".text" {to=$5; ts=$6}
	$2==".data" {do_=$5}
	END{print to, ts, do_}')
set -- $CONTIG
TSZ=$(( 0x$2 ))
set -- $(( 0x$1 + 0x$2 )) $(( 0x$3 ))
[ "$1" = "$2" ] && echo "[OK] text/data contiguous." \
	|| { echo "[FAIL] text/data NOT contiguous"; exit 1; }
[ $((TSZ % 4)) -eq 0 ] && echo "[OK] .text size 0x$(printf %x $TSZ) is 4-aligned." \
	|| { echo "[FAIL] .text size not 4-aligned -- is fpe040.o last in the link?"; exit 1; }
DSZ=$(( 0x$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".data"{print $6}') ))
[ $((DSZ % 4)) -eq 0 ] && echo "[OK] .data size 0x$(printf %x $DSZ) is 4-aligned." \
	|| { echo "[FAIL] .data size not 4-aligned -> .bss misaligned at runtime"; exit 1; }

run_step indent python3 "$HERE/src/patch_b2_flip.py" "$OUT" --check
run_step 1 python3 "$HERE/src/check_relink_relocs.py" "$OUT"
run_step indent python3 "$HERE/src/check_fpe_relocs.py" "$OUT"
python3 "$HERE/src/stamp_buildid.py" "$OUT"

echo "[OK] built $OUT"
echo "     boot: unix_boot040 $(basename "$OUT")   <- unix_boot040 is MANDATORY"
echo "     expect on a part WITH an FPU:  fpe_entry_n == 0 and fpu_emul == 0, all boot"
echo "                                    -- but the pre-gate fpe_v11_* census DOES move there"
echo "     expect on a 68LC060:           'fpu emulation enabled' after 'no fpu detected'"
echo "                                    fpe_cputype_amix == 60, fpe_cputype == 3"
