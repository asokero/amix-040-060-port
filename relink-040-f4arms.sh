#!/bin/sh
# relink-040-f4arms.sh -- the two BLIZZARD F4 attempt-4 arms, as a post-pass over an
# already-finished Z3660-carrying kernel.  Neither arm touches the base build, so the
# base stays byte-comparable to the artifact the previous attempt booted.
#
#   --dbg        layer src/swapconf_dbg.s over stock swapconf (0xb401e).  The override
#                probes every prefix of the swap pathname twice, with a whole-data-cache
#                push+invalidate between the passes, and then either tail-jumps to the
#                real swapconf or skips swap so the boot carries on into userland.
#                NAMES the 2026-08-25 `swapconf lookupname ... error 20` stop.
#
#   --cache N    link src/z3660_cache_arm.s, which gives the piscsi driver's
#                z3660_cache knob a .data home (it is a C tentative definition, hence a
#                COMMON symbol with no file storage), and stamp it to N.
#                N = 0 is the control: behaviourally identical to the unmodified common,
#                and one word away from the arm it is the control for.
#                The driver's own repository is NOT modified -- a defined symbol simply
#                beats a common at link time.
#                N is a CPU-FAMILY LABEL, not a bitmask: amix-z3660scsi/src/z3660.c tests
#                the knob for zero versus non-zero at every site and no site distinguishes
#                40 from 60, so the arm is binary and 40 and 60 select the same behaviour.
#
#   --ufault     link src/ufault_dbg.s and chain it in front of the ISSUE-52 latch at the
#                fatal user-fault NOTICE.  Census only: it latches the first fault in full
#                (registers, FSLW, break, u_ar0, rootdir), rewrites a LAST block on every
#                fault, and keeps the user-stack watermarks that say whether signal frames
#                are stacking.  It changes no behaviour and dereferences no user address --
#                the round-5 instrument for the /sbin/init wall arm B reached.
#
# usage: sh relink-040-f4arms.sh [--dbg] [--ufault] [--cache N] <in-kernel> <out-kernel>
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tools/config-load.sh"
. "$HERE/tools/build-step.sh"

DBG=0
UFAULT=0
CACHE=""
while [ $# -gt 2 ]; do
	case "$1" in
	--dbg)    DBG=1; shift ;;
	--ufault) UFAULT=1; shift ;;
	--cache)  CACHE="$2"; shift 2 ;;
	*)        echo "ERROR: unknown option $1"; exit 1 ;;
	esac
done
[ $# -eq 2 ] || { echo "usage: sh relink-040-f4arms.sh [--dbg] [--ufault] [--cache N] <in> <out>"; exit 1; }
IN="$1"; OUT="$2"
[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
[ "$DBG" = 1 ] || [ "$UFAULT" = 1 ] || [ -n "$CACHE" ] \
	|| { echo "ERROR: nothing to do -- pass --dbg, --ufault and/or --cache N"; exit 1; }
echo "[*] base: $(basename "$IN")   arms: dbg=$DBG ufault=$UFAULT cache=${CACHE:-none}"

# The base has to be a Z3660-carrying kernel: --cache has no reader without the driver,
# and --dbg without it produces an artifact that cannot open this rig's root device --
# which is the precondition attempt 1 was killed by.
m68k-linux-gnu-nm "$IN" | grep -qE " [TtDdBb] z3660queue\$" \
	|| { echo "[FAIL] $IN has no z3660queue -- this post-pass belongs after relink-040-z3660.sh"; exit 1; }

OBJS=""
OC=""
SWAPCONF_ADDR=0xb401e
SWAPCONF_BYTES=4e56000048e72030203c0000

cp "$IN" "$HERE/build/unix-stage-f4arms"

if [ "$DBG" = 1 ]; then
	# Assert the body BEFORE weakening it: a hardcoded address is only safe if the code
	# at it is the code the override was written against.  Twelve bytes is past the
	# register save, which is enough to identify swapconf.  .text file offset is 0x34.
	GOT=$(od -An -tx1 -j $((0x34 + SWAPCONF_ADDR)) -N 12 "$IN" | tr -d ' \n')
	[ "$GOT" = "$SWAPCONF_BYTES" ] \
		|| { echo "[FAIL] swapconf at $SWAPCONF_ADDR: bytes $GOT, expected $SWAPCONF_BYTES"; exit 1; }
	SYM=$(m68k-linux-gnu-nm "$IN" | awk '$3=="swapconf" && $2=="T" {print $1}')
	[ "$SYM" = "000b401e" ] \
		|| { echo "[FAIL] swapconf is not a global T at $SWAPCONF_ADDR (nm: '$SYM')"; exit 1; }
	echo "[OK] stock swapconf @$SWAPCONF_ADDR: entry bytes and symbol match the pinned image"

	# The override reads the swap pathname out of swapfile.bo_name, i.e. swapfile+0x10.
	# That offset is stock swapconf's own (its relocations use swapfile+0x10 for the path
	# and swapfile+0x9c for &bo_vp), so assert it rather than trusting the header.
	run_step indent python3 "$HERE/src/check_swap_boname.py" "$IN"

	m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/swapconf_dbg.s" -o "$HERE/build/swapconf_dbg.o"
	OBJS="$OBJS $HERE/build/swapconf_dbg.o"
	OC="$OC --weaken-symbol swapconf --add-symbol swapconf_orig=.text:${SWAPCONF_ADDR},function,global"
fi

if [ "$UFAULT" = 1 ]; then
	# The census chains in FRONT of the ISSUE-52 latch, so that latch has to be there
	# already.  Asserting it here as well as in the patcher means the build stops before it
	# assembles anything, rather than after.
	m68k-linux-gnu-nm "$IN" | grep -qE " [Tt] unt_latch\$" \
		|| { echo "[FAIL] $IN has no unt_latch -- run relink-040.sh (patch_usptrap.py) first"; exit 1; }
	echo "[OK] the ISSUE-52 latch is present; the census will chain in front of it"
	m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/ufault_dbg.s" -o "$HERE/build/ufault_dbg.o"
	OBJS="$OBJS $HERE/build/ufault_dbg.o"
fi

if [ -n "$CACHE" ]; then
	# The knob must arrive as a COMMON in the input, i.e. it must still be the driver's own
	# tentative definition.  Anything else means this post-pass has already run, or the
	# driver changed, and either way the "one word apart" claim would be false.
	m68k-linux-gnu-nm "$IN" | grep -qE "^0*4 C z3660_cache\$" \
		|| { echo "[FAIL] z3660_cache is not a 4-byte COMMON in $IN -- refusing to guess"; exit 1; }
	echo "[OK] z3660_cache arrives as a COMMON; the .data definition will absorb it"
	m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/z3660_cache_arm.s" -o "$HERE/build/z3660_cache_arm.o"
	OBJS="$OBJS $HERE/build/z3660_cache_arm.o"
fi

if [ -n "$OC" ]; then
	m68k-linux-gnu-objcopy $OC "$HERE/build/unix-stage-f4arms"
fi

echo "[*] ld -r: base +$(echo "$OBJS" | sed 's#[^ ]*/##g')"
m68k-cbm-sysv4-ld -r -o "$OUT" "$HERE/build/unix-stage-f4arms" $OBJS

if [ "$DBG" = 1 ]; then
	NEW=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="swapconf" && $2=="T" {print $1}')
	ORIG=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="swapconf_orig" {print $1}')
	[ -n "$NEW" ] && [ "$NEW" != "000b401e" ] \
		|| { echo "[FAIL] strong swapconf is stock/missing (addr='$NEW') -- the probe is not in the kernel"; exit 1; }
	[ "$ORIG" = "000b401e" ] \
		|| { echo "[FAIL] swapconf_orig is '$ORIG', expected 000b401e -- the tail jump has no target"; exit 1; }
	[ "$(m68k-linux-gnu-nm "$OUT" | grep -cE " T swapconf\$")" = "1" ] \
		|| { echo "[FAIL] swapconf does not have exactly one strong definition"; exit 1; }
	m68k-linux-gnu-nm "$OUT" | grep -qE " [Dd] swd_magic\$" \
		|| { echo "[FAIL] swd_magic missing -- swapconf_dbg.o is not in the link"; exit 1; }
	echo "[OK] swapconf probe bound @0x$NEW; the stock body is reachable as swapconf_orig @0x$ORIG"
fi

LEAK=$(m68k-linux-gnu-nm "$OUT" | awk '$1=="U" && $2!="edata" && $2!="end" && $2!="etext" {print $2}')
[ -z "$LEAK" ] || { echo "[FAIL] unresolved symbols:"; echo "$LEAK"; exit 1; }
echo "[OK] no unresolved symbols"

if [ "$UFAULT" = 1 ]; then
	echo "[*] fatal user-fault census"
	m68k-linux-gnu-nm "$OUT" | grep -qE " [Tt] uft_latch\$" \
		|| { echo "[FAIL] uft_latch missing -- ufault_dbg.o is not in the link"; exit 1; }
	m68k-linux-gnu-nm "$OUT" | grep -qE " [Dd] uft_magic\$" \
		|| { echo "[FAIL] uft_magic is not a .data symbol -- the block has no file storage"; exit 1; }
	# The copy loop writes sixteen consecutive longwords starting at uft_f_d0, so d0-d7/a0-a7
	# must be adjacent AND in that order.  An edit that reordered the .data declarations would
	# still assemble, still link, and quietly mislabel every register on the console -- which
	# is worse than not reading them at all.  So the link is asked, not the source file.
	WANT="uft_f_d0 uft_f_d1 uft_f_d2 uft_f_d3 uft_f_d4 uft_f_d5 uft_f_d6 uft_f_d7"
	WANT="$WANT uft_f_a0 uft_f_a1 uft_f_a2 uft_f_a3 uft_f_a4 uft_f_a5 uft_f_a6 uft_f_a7"
	PREV=""
	for R in $WANT; do
		A=$(m68k-linux-gnu-nm "$OUT" | awk -v r="$R" '$3==r && ($2=="D" || $2=="d") {print $1}')
		[ -n "$A" ] || { echo "[FAIL] $R is not a .data symbol in $OUT"; exit 1; }
		A=$(( 0x$A ))
		if [ -n "$PREV" ] && [ $(( A - PREV )) -ne 4 ]; then
			echo "[FAIL] $R is $(( A - PREV )) bytes after its predecessor, expected 4"; exit 1
		fi
		PREV=$A
	done
	echo "[OK] uft_f_d0..a7 are sixteen adjacent longwords, in declaration order"
	run_step indent python3 "$HERE/src/patch_ufault.py" "$OUT"
fi

if [ -n "$CACHE" ]; then
	echo "[*] z3660_cache arm"
	run_step indent python3 "$HERE/src/patch_z3660_cache.py" "$OUT" --set "$CACHE"
fi

# The standard packaging guards -- the same ones relink-040-z3660.sh runs, for the same
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
