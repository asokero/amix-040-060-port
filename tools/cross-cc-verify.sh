#!/bin/sh
# cross-cc-verify.sh -- does the installed AMIX cross compiler actually build 68040 code?
#
#   sh tools/cross-cc-verify.sh [path-to-m68k-cbm-sysv4-gcc]
#
# Sourced by check-env.sh for its pre-flight; runnable on its own when you want the detail.
# Defines cross_cc_verify(), which prints nothing and returns 0 when the compiler is fit, and
# prints why and returns 1 when it is not.
#
# WHY THIS EXISTS
#
# Until 2026-08-28 the compiler that produced every kernel and every hardware acceptance in this
# project existed only as sixty-six lines of uncommitted working-tree changes to
# gcc-cross-amix's amix-gcc-wrapper.sh, plus the copy installed beside it.  BUILDING.md told a
# reader to build the toolchain from its repository, and doing that gave a DIFFERENT compiler
# from the one all of the evidence came from.  Nothing anywhere noticed -- not one script asked
# what compiler it was using.  That is ISSUE-55, and this file is the part of it that stays
# fixed after the upstream PR lands.
#
# WHAT IT CHECKS, AND WHY IT IS A BEHAVIOUR TEST RATHER THAN A CHECKSUM
#
# Pinning the wrapper's hash would be brittle in the wrong direction: it fails on a harmless
# reformatting and would have to be re-pinned every time upstream moves, which trains people to
# re-pin without looking.  What actually matters is not which wrapper is installed but whether
# it can assemble what gcc emits at -m68040, so that is what gets measured -- compile a little C
# and require an object.
#
# The failure is loud rather than silent, which is worth knowing before you go hunting: gas
# reports each construct as `Error: ... statement ignored', and although the wording says
# `ignored' it still exits 1 and writes no object.  Measured on this tree's ten-function sample
# with each half of the repair present and absent:
#
#     wrapper                       errors   object
#     upstream, neither half            23   no
#     spelling rules only               11   no
#     -march only                       15   no
#     both (what this gate wants)        0   YES
#
# So both halves are needed and neither alone is enough -- and note 8 -> 11 in the third row:
# repairing the spellings UNCOVERS arch errors, because a corrected `fmovem.l' is itself a
# 68040 opcode that an assembler pinned at -m68020 then refuses.  The two repairs are not
# independent, which is why this gate tests the outcome instead of grepping for either one.

cross_cc_verify() {
	cc=${1:-m68k-cbm-sysv4-gcc}
	command -v "$cc" >/dev/null 2>&1 || { echo "no such compiler: $cc"; return 1; }

	d=$(mktemp -d "${TMPDIR:-/tmp}/amix-ccverify.XXXXXX") || return 1

	# Every function here is present for a construct that a wrapper missing the repairs cannot
	# assemble.  Do not trim this file down: each line is a probe.
	cat > "$d/probe.c" <<'EOF'
float  p_fmul(float a, float b)  { return a * b; }   /* fsmul.s  -- 040-only opcode */
float  p_fadd(float a, float b)  { return a + b; }   /* fsadd.s  -- 040-only opcode */
double p_dsub(double a, double b){ return a - b; }   /* fdsub.d  -- 040-only opcode */
double p_dneg(double a)          { return -a; }      /* fdneg.d  -- 040-only opcode */
int    p_d2i(double a)           { return (int)a; }  /* fmovm.l %fpcr + mov &16 + fdmov.d */
unsigned p_f2u(float f)          { return (unsigned)f; }               /* same sequence */
EOF

	( cd "$d" && "$cc" -m68040 -O -c probe.c -o probe.o ) > "$d/log" 2>&1
	rc=$?

	if [ "$rc" -eq 0 ] && [ -s "$d/probe.o" ]; then
		rm -rf "$d"
		return 0
	fi

	echo "the installed cross compiler cannot assemble 68040 code"
	echo "  compiler: $(command -v "$cc")"
	nspell=$(grep -c 'Unknown operator' "$d/log" 2>/dev/null || echo 0)
	narch=$(grep -c 'invalid instruction for this architecture' "$d/log" 2>/dev/null || echo 0)
	[ "$nspell" -gt 0 ] && echo "  $nspell x 'Unknown operator'  -- wrapper is missing the fmovem/fdmove/mov-suffix rules"
	[ "$narch" -gt 0 ] && echo "  $narch x 'invalid instruction for this architecture'"\
	                          "-- wrapper assembles at a hardcoded -m68020 instead of following -march"
	sed -n '1,4p' "$d/log" | sed 's/^/      /'
	echo "  Fix: install a wrapper carrying both repairs -- see BUILDING.md, ISSUE-55."
	echo "       Upstream PR: isoriano1968/gcc-cross-amix, from asokero:fixes-2026-08-asokero"
	rm -rf "$d"
	return 1
}

# Run it when invoked rather than sourced.  $0 ends in this file's name only in the former case.
case "$0" in
*cross-cc-verify.sh)
	if why=$(cross_cc_verify "$1"); then
		echo "[OK] $(command -v "${1:-m68k-cbm-sysv4-gcc}") builds 68040 code"
	else
		printf '%s\n' "$why"
		exit 1
	fi
	;;
esac
