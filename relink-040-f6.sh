#!/bin/sh
# relink-040-f6.sh -- the three BLIZZARD F4 attempt-6 instruments, as a post-pass over an
# already-finished round-5 kernel.  None of them touches the base build, so the base stays
# byte-comparable to the artifacts attempts 3, 4 and 5 booted.
#
#   --kvd   link src/kvecdisp040.s and chain it in front of the ISSUE-106 user-trap latch at
#           the utraps -> srg_utraps edge.  Reads M68Kvec and the VBR from the side of the
#           dispatch chain that RAN, and carries a twin counter deliberately placed in a
#           different .data page.  Decides attempt 5's kvp_n / srg_ut_n contradiction
#           (docs/060-F4-M2-ATT6-PREREG-260825.md 2.1 and Table K).
#
#   --mcs   link src/mcstate_dbg.s over stock savecontext (0x58f10, WRAPPED -- the stamp does
#           not exist until it returns) and stock restorecontext (0x58d76, PROLOGUE hook --
#           the frame to check is its argument).  Folds the checksummed region three times
#           per refusal and latches mc_state[0..3] plus eight block folds.  Takes the verdict
#           attempt-5 pre-reg 7 forbade (Table L).
#
#   --swa   link src/swapadd_dbg.s and retarget swapconf's one `jsr swapadd` to it.  Latches
#           all four operands, swapinfo either side, and the return.  THE ROUND'S ANCHOR: it
#           fires once per boot, before userland, so it produces a reading even on a boot that
#           panics in swapconf (Table M).
#
# The input must ALREADY carry the round-5 arms, i.e. be the output of
#   sh relink-040-f4arms.sh --ufault --cache 60 <z3660-kernel> <out>
# Building a round-6 arm over a base without them would silently measure a different kernel:
# no ufault census, and -- worse -- no cache arm, which is the difference between reaching
# userland and stopping at swapconf's lookup.
#
# usage: sh relink-040-f6.sh [--kvd] [--mcs] [--swa] <in-kernel> <out-kernel>
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tools/config-load.sh"
. "$HERE/tools/build-step.sh"

KVD=0
MCS=0
SWA=0
while [ $# -gt 2 ]; do
	case "$1" in
	--kvd) KVD=1; shift ;;
	--mcs) MCS=1; shift ;;
	--swa) SWA=1; shift ;;
	*)     echo "ERROR: unknown option $1"; exit 1 ;;
	esac
done
[ $# -eq 2 ] || { echo "usage: sh relink-040-f6.sh [--kvd] [--mcs] [--swa] <in> <out>"; exit 1; }
IN="$1"; OUT="$2"
[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
[ "$KVD" = 1 ] || [ "$MCS" = 1 ] || [ "$SWA" = 1 ] \
	|| { echo "ERROR: nothing to do -- pass --kvd, --mcs and/or --swa"; exit 1; }
echo "[*] base: $(basename "$IN")   arms: kvd=$KVD mcs=$MCS swa=$SWA"

NM=m68k-linux-gnu-nm

# ---------------------------------------------------------------- the input's own identity
# Every one of these is a silent-wrong-kernel trap if it is missing, so they are asserted
# BEFORE anything is assembled rather than after the link.
$NM "$IN" | grep -qE " [TtDdBb] z3660queue\$" \
	|| { echo "[FAIL] $IN has no z3660queue -- this post-pass belongs after relink-040-z3660.sh"; exit 1; }
$NM "$IN" | grep -qE " [Tt] uft_latch\$" \
	|| { echo "[FAIL] $IN has no uft_latch -- run relink-040-f4arms.sh --ufault first"; exit 1; }
$NM "$IN" | grep -qE " [Dd] zc_magic\$" \
	|| { echo "[FAIL] $IN has no zc_magic -- run relink-040-f4arms.sh --cache 60 first"; exit 1; }
ZCA=$($NM "$IN" | awk '$3=="z3660_cache" && ($2=="D"||$2=="d") {print $1}')
[ -n "$ZCA" ] \
	|| { echo "[FAIL] z3660_cache is still a COMMON in $IN -- the cache arm is not baked in"; exit 1; }
echo "[OK] the round-5 arms are present: uft_latch, zc_magic, z3660_cache defined in .data"

# The cache arm's VALUE is read out of the file, not assumed: --cache 0 links identically and
# stops at swapconf's lookup, which would make every round-6 reading a measurement of the
# wrong boot.
run_step indent python3 "$HERE/src/patch_z3660_cache.py" "$IN" --check

cp "$IN" "$HERE/build/unix-stage-f6"

OBJS=""
OC=""

# ---------------------------------------------------------------- assert-then-weaken
# A hardcoded address is only safe if the code at it is the code the override was written
# against.  Twelve bytes is past the register save, which is enough to identify the body.
# .text file offset is 0x34.
assert_body() {	# assert_body <name> <hex-addr> <24-hex-digit-prefix>
	GOT=$(od -An -tx1 -j $((0x34 + 0x$2)) -N 12 "$IN" | tr -d ' \n')
	[ "$GOT" = "$3" ] \
		|| { echo "[FAIL] $1 at 0x$2: bytes $GOT, expected $3"; exit 1; }
	SYM=$($NM "$IN" | awk -v n="$1" '$3==n && ($2=="T"||$2=="t") {print $1}')
	[ "$SYM" = "000$2" ] \
		|| { echo "[FAIL] $1 is not at 0x$2 (nm: '$SYM')"; exit 1; }
	echo "[OK] stock $1 @0x$2: entry bytes and symbol match the pinned image"
}

if [ "$KVD" = 1 ]; then
	# The census chains in FRONT of the ISSUE-106 srg latch, so that latch has to be there
	# already -- chaining in front of a raw u_trap would drop it silently.  The patcher
	# refuses that too; asserting here stops the build before it assembles anything.
	$NM "$IN" | grep -qE " [Tt] srg_utraps\$" \
		|| { echo "[FAIL] $IN has no srg_utraps -- run relink-040.sh (patch_srgtrap.py) first"; exit 1; }
	for S in M68Kvec nullvect kvp_n kvp_on srg_ut_n; do
		$NM "$IN" | grep -qE " [TtDdBb] $S\$" \
			|| { echo "[FAIL] $IN has no $S -- the census has nothing to read"; exit 1; }
	done
	echo "[OK] the ISSUE-106 srg latch and all five census inputs are present"
	m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/kvecdisp040.s" -o "$HERE/build/kvecdisp040.o"
	OBJS="$OBJS $HERE/build/kvecdisp040.o"
fi

if [ "$MCS" = 1 ]; then
	assert_body savecontext    58f10 4e56000048e70030246e0008
	assert_body restorecontext 58d76 4e56000048e72030246e0008
	m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/mcstate_dbg.s" -o "$HERE/build/mcstate_dbg.o"
	OBJS="$OBJS $HERE/build/mcstate_dbg.o"
	OC="$OC --weaken-symbol savecontext --add-symbol savecontext_orig=.text:0x58f10,function,global"
	OC="$OC --weaken-symbol restorecontext --add-symbol restorecontext_orig=.text:0x58d76,function,global"
fi

if [ "$SWA" = 1 ]; then
	# swapadd is FILE-LOCAL, so it is reached through an added global rather than weakened.
	assert_body swapadd b3138 4e56ff9048e73f3c2a2e000c
	$NM "$IN" | grep -qE " C swapinfo\$" \
		|| { echo "[FAIL] swapinfo is not a COMMON in $IN -- the latch cannot reference it"; exit 1; }
	m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/swapadd_dbg.s" -o "$HERE/build/swapadd_dbg.o"
	OBJS="$OBJS $HERE/build/swapadd_dbg.o"
	OC="$OC --add-symbol swapadd_real=.text:0xb3138,function,global"
fi

if [ -n "$OC" ]; then
	m68k-linux-gnu-objcopy $OC "$HERE/build/unix-stage-f6"
fi

echo "[*] ld -r: base +$(echo "$OBJS" | sed 's#[^ ]*/##g')"
m68k-cbm-sysv4-ld -r -o "$OUT" "$HERE/build/unix-stage-f6" $OBJS

LEAK=$($NM "$OUT" | awk '$1=="U" && $2!="edata" && $2!="end" && $2!="etext" {print $2}')
[ -z "$LEAK" ] || { echo "[FAIL] unresolved symbols:"; echo "$LEAK"; exit 1; }
echo "[OK] no unresolved symbols"

# ---------------------------------------------------------------- adjacency, asked of the LINK
# The copy loops in these units walk consecutive longwords, so a reordering edit would still
# assemble, still link, and quietly mislabel every slot on the console -- which is worse than
# not reading them at all.  So the LINK is asked, not the source file.
adjacent() {	# adjacent <label> <sym> <sym> ...
	LBL="$1"; shift
	PREV=""
	for R in "$@"; do
		A=$($NM "$OUT" | awk -v r="$R" '$3==r && ($2=="D" || $2=="d") {print $1}')
		[ -n "$A" ] || { echo "[FAIL] $R is not a .data symbol in $OUT"; exit 1; }
		A=$(( 0x$A ))
		if [ -n "$PREV" ] && [ $(( A - PREV )) -ne 4 ]; then
			echo "[FAIL] $R is $(( A - PREV )) bytes after its predecessor, expected 4"; exit 1
		fi
		PREV=$A
	done
	echo "[OK] $LBL"
}

symaddr() {	# symaddr <sym> -- decimal .data address, or empty
	A=$($NM "$OUT" | awk -v r="$1" '$3==r && ($2=="D" || $2=="d") {print $1}')
	[ -n "$A" ] && echo $(( 0x$A ))
}

if [ "$KVD" = 1 ]; then
	echo "[*] vector-dispatch census"
	$NM "$OUT" | grep -qE " [Tt] kvd_utraps\$" \
		|| { echo "[FAIL] kvd_utraps missing -- kvecdisp040.o is not in the link"; exit 1; }
	$NM "$OUT" | grep -qE " [Dd] kvd_magic\$" \
		|| { echo "[FAIL] kvd_magic is not a .data symbol -- the block has no file storage"; exit 1; }
	$NM "$OUT" | grep -qE " [Dd] kvfar_magic\$" \
		|| { echo "[FAIL] kvfar_magic is not a .data symbol"; exit 1; }
	adjacent "the kvd block is 40 adjacent longwords, in declaration order" \
		kvd_magic kvd_on kvd_n kvd_split_n kvd_split_first kvd_aud_n kvd_stamp \
		kvd_f_sr kvd_f_pc kvd_f_fv kvd_f_vec kvd_f_usp kvd_f_nowusp kvd_f_vbr \
		kvd_f_tabaddr kvd_f_nullvect kvd_f_e_vec kvd_f_e_vec_c \
		kvd_l_vec kvd_l_pc kvd_l_fv kvd_l_sr \
		kvd_a_at kvd_a_vbr kvd_a_e2 kvd_a_e2c kvd_a_e32 kvd_a_e32c kvd_a_e11 \
		kvd_a_nvcnt kvd_a_sum kvd_a_sum0 kvd_a_chg_n kvd_a_i kvd_a_was kvd_a_now \
		kvd_a_kvpn kvd_a_kvpon kvd_a_srgn kvd_snap
	# The whole point of the twin counter is that it is in a DIFFERENT 4 KiB page, so a
	# page-scoped lost write shows up as a divergence.  Assert the distance from the link
	# rather than trusting the .space in the source.
	KN=$(symaddr kvd_n); KF=$(symaddr kvfar_n)
	[ -n "$KN" ] && [ -n "$KF" ] || { echo "[FAIL] kvd_n / kvfar_n not both in .data"; exit 1; }
	GAP=$(( KF - KN ))
	[ "$GAP" -ge 8192 ] \
		|| { echo "[FAIL] kvfar_n is only $GAP bytes past kvd_n, need >= 8192"; exit 1; }
	[ $(( KN / 4096 )) -ne $(( KF / 4096 )) ] \
		|| { echo "[FAIL] kvd_n and kvfar_n share a 4 KiB page"; exit 1; }
	echo "[OK] kvfar_n is $GAP bytes past kvd_n, in a different 4 KiB page"
	run_step indent python3 "$HERE/src/patch_kvecdisp.py" "$OUT"
fi

if [ "$MCS" = 1 ]; then
	echo "[*] ucontext stamp latch"
	for P in savecontext:58f10 restorecontext:58d76; do
		S=${P%%:*}; A=${P##*:}
		NEW=$($NM "$OUT" | awk -v n="$S" '$3==n && $2=="T" {print $1}')
		ORIG=$($NM "$OUT" | awk -v n="${S}_orig" '$3==n {print $1}')
		[ -n "$NEW" ] && [ "$NEW" != "000$A" ] \
			|| { echo "[FAIL] strong $S is stock/missing (addr='$NEW') -- the latch is not in the kernel"; exit 1; }
		[ "$ORIG" = "000$A" ] \
			|| { echo "[FAIL] ${S}_orig is '$ORIG', expected 000$A -- the hand-off has no target"; exit 1; }
		[ "$($NM "$OUT" | grep -cE " T $S\$")" = "1" ] \
			|| { echo "[FAIL] $S does not have exactly one strong definition"; exit 1; }
		echo "[OK] $S bound @0x$NEW; the stock body is reachable as ${S}_orig @0x$ORIG"
	done
	$NM "$OUT" | grep -qE " [Dd] mcs_magic\$" \
		|| { echo "[FAIL] mcs_magic is not a .data symbol -- the block has no file storage"; exit 1; }
	adjacent "mcs_b_blk0..blk7 are eight adjacent longwords, in declaration order" \
		mcs_b_blk0 mcs_b_blk1 mcs_b_blk2 mcs_b_blk3 mcs_b_blk4 mcs_b_blk5 mcs_b_blk6 mcs_b_blk7
	adjacent "mcs_g_blk0..blk7 are eight adjacent longwords, in declaration order" \
		mcs_g_blk0 mcs_g_blk1 mcs_g_blk2 mcs_g_blk3 mcs_g_blk4 mcs_g_blk5 mcs_g_blk6 mcs_g_blk7
fi

if [ "$SWA" = 1 ]; then
	echo "[*] swapadd operand latch"
	$NM "$OUT" | grep -qE " [Tt] swa_latch\$" \
		|| { echo "[FAIL] swa_latch missing -- swapadd_dbg.o is not in the link"; exit 1; }
	$NM "$OUT" | grep -qE " [Dd] swa_magic\$" \
		|| { echo "[FAIL] swa_magic is not a .data symbol -- the block has no file storage"; exit 1; }
	REAL=$($NM "$OUT" | awk '$3=="swapadd_real" {print $1}')
	[ "$REAL" = "000b3138" ] \
		|| { echo "[FAIL] swapadd_real is '$REAL', expected 000b3138"; exit 1; }
	adjacent "the swa block is 15 adjacent longwords, in declaration order" \
		swa_magic swa_n swa_vp swa_lowblk swa_nblks swa_name swa_si_pre swa_nsf_pre \
		swa_ret swa_si_post swa_nsf_post swa_si_start swa_si_npgs swa_si_flags swa_stamp
	run_step indent python3 "$HERE/src/patch_swapadd.py" "$OUT"
fi

# The standard packaging guards -- the same ones relink-040-f4arms.sh runs, for the same
# reasons: an unaligned .text total leaves a hole the loader copies as one block, and an
# unaligned .data size lands .bss on an odd address (rel.c puts .bss at data_end as-is).
CONTIG=$(m68k-linux-gnu-readelf -SW "$OUT" | awk '
	{gsub(/[][]/,"")}
	$2==".text" {to=$5; ts=$6}
	$2==".data" {do_=$5}
	END{print to, ts, do_}')
set -- $CONTIG
set -- $(( 0x$1 + 0x$2 )) $(( 0x$3 ))
[ "$1" = "$2" ] && echo "[OK] text/data contiguous." \
	|| { echo "[FAIL] text/data NOT contiguous"; exit 1; }
DSZ=$(( 0x$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".data"{print $6}') ))
[ $((DSZ % 4)) -eq 0 ] && echo "[OK] .data size 0x$(printf %x $DSZ) is 4-aligned." \
	|| { echo "[FAIL] .data size not 4-aligned -> .bss misaligned at runtime"; exit 1; }
run_step indent python3 "$HERE/src/patch_b2_flip.py" "$OUT" --check
run_step 1 python3 "$HERE/src/check_relink_relocs.py" "$OUT"
python3 "$HERE/src/stamp_buildid.py" "$OUT"

echo "[OK] built $OUT"
echo "     boot: unix_boot040 $(basename "$OUT")   <- unix_boot040 is MANDATORY"
