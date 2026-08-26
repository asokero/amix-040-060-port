#!/bin/sh
# relink-040-f7.sh -- the BLIZZARD F4 attempt-7 instrument, as a post-pass of its OWN over an
# already-finished round-7 kernel.  One option, one unit, one change: that separation is the
# whole reason attempt 7 is a round rather than an addition to round 6's script, because a
# determinism proof taken over a stage that carries two changes measures two things at once.
#
#   --ucp   link src/ucp_dbg.s over stock savecontext (0x58f10, WRAPPED -- the stamp does not
#           exist until it returns) and stock restorecontext (0x58d76, PROLOGUE hook -- the
#           frame to check is its argument).  Shadows the whole 804-byte checksummed region
#           into a four-slot ring at every save and, at every restore whose 201-fold is not
#           FFFFFFFF, pairs the object with ITS OWN EARLIER SELF by stamp and latches the
#           first twelve differing longwords as (index, save-time, restore-time).
#           Registered in docs/060-F4-M2-ATT7-PREREG-260825.md 4.1-4.4, which was committed
#           before src/ucp_dbg.s was written.
#
# The input must ALREADY carry the round-5 arms, i.e. be the output of
#   sh relink-040-f4arms.sh --ufault --cache 60 <z3660-kernel> <out>
# and, for the attempt-7 primary, of relink-040-f6.sh --kvd --swa on top of that.  Building
# this arm over a base without them would silently measure a different kernel: no ufault
# census (and ucp reads uft_have to know when the wall happened), and -- worse -- no cache
# arm, which is the difference between reaching userland and stopping at swapconf's lookup.
#
# --ucp AND --mcs ARE MUTUALLY EXCLUSIVE, and this script refuses rather than discovers it.
# Both units define savecontext and restorecontext, so an input carrying mcs_magic cannot take
# this one; and per the pre-registration 4.5 running both would fold the same region five
# times per signal for no added information.  ucp supersedes mcs's Table L rows, keeps its
# counters under this round's prefix, and retires the rows.
#
# usage: sh relink-040-f7.sh --ucp <in-kernel> <out-kernel>
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tools/config-load.sh"
. "$HERE/tools/build-step.sh"

UCP=0
while [ $# -gt 2 ]; do
	case "$1" in
	--ucp) UCP=1; shift ;;
	*)     echo "ERROR: unknown option $1"; exit 1 ;;
	esac
done
[ $# -eq 2 ] || { echo "usage: sh relink-040-f7.sh --ucp <in> <out>"; exit 1; }
IN="$1"; OUT="$2"
[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
[ "$UCP" = 1 ] || { echo "ERROR: nothing to do -- pass --ucp"; exit 1; }
echo "[*] base: $(basename "$IN")   arms: ucp=$UCP"

NM=m68k-linux-gnu-nm

# ---------------------------------------------------------------- the input's own identity
# Every one of these is a silent-wrong-kernel trap if it is missing, so they are asserted
# BEFORE anything is assembled rather than after the link.
$NM "$IN" | grep -qE " [TtDdBb] z3660queue\$" \
	|| { echo "[FAIL] $IN has no z3660queue -- this post-pass belongs after relink-040-z3660.sh"; exit 1; }
$NM "$IN" | grep -qE " [Tt] uft_latch\$" \
	|| { echo "[FAIL] $IN has no uft_latch -- run relink-040-f4arms.sh --ufault first"; exit 1; }
$NM "$IN" | grep -qE " [Dd] uft_have\$" \
	|| { echo "[FAIL] $IN has no uft_have -- ucp's layout row has no freeze key"; exit 1; }
$NM "$IN" | grep -qE " [Dd] zc_magic\$" \
	|| { echo "[FAIL] $IN has no zc_magic -- run relink-040-f4arms.sh --cache 60 first"; exit 1; }
ZCA=$($NM "$IN" | awk '$3=="z3660_cache" && ($2=="D"||$2=="d") {print $1}')
[ -n "$ZCA" ] \
	|| { echo "[FAIL] z3660_cache is still a COMMON in $IN -- the cache arm is not baked in"; exit 1; }
echo "[OK] the round-5 arms are present: uft_latch, uft_have, zc_magic, z3660_cache in .data"

# The cache arm's VALUE is read out of the file, not assumed: --cache 0 links identically and
# stops at swapconf's lookup, which would make every round-7 reading a measurement of the
# wrong boot.
run_step indent python3 "$HERE/src/patch_z3660_cache.py" "$IN" --check

# The exclusion, refused rather than discovered at ld -r time with a multiple-definition
# message that says nothing about why the two arms cannot share a kernel.
if $NM "$IN" | grep -qE " [Dd] mcs_magic\$"; then
	echo "[FAIL] $IN carries mcs_magic -- ucp SUPERSEDES mcs (pre-reg 4.5) and both units"
	echo "       define savecontext/restorecontext.  Build the input with"
	echo "       relink-040-f6.sh --kvd --swa, without --mcs."
	exit 1
fi
echo "[OK] the input does not carry mcs -- ucp is the only savecontext/restorecontext hook"

cp "$IN" "$HERE/build/unix-stage-f7"

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

if [ "$UCP" = 1 ]; then
	assert_body savecontext    58f10 4e56000048e70030246e0008
	assert_body restorecontext 58d76 4e56000048e72030246e0008
	m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/ucp_dbg.s" -o "$HERE/build/ucp_dbg.o"
	OBJS="$OBJS $HERE/build/ucp_dbg.o"
	OC="$OC --weaken-symbol savecontext --add-symbol savecontext_orig=.text:0x58f10,function,global"
	OC="$OC --weaken-symbol restorecontext --add-symbol restorecontext_orig=.text:0x58d76,function,global"
fi

if [ -n "$OC" ]; then
	m68k-linux-gnu-objcopy $OC "$HERE/build/unix-stage-f7"
fi

echo "[*] ld -r: base +$(echo "$OBJS" | sed 's#[^ ]*/##g')"
m68k-cbm-sysv4-ld -r -o "$OUT" "$HERE/build/unix-stage-f7" $OBJS

LEAK=$($NM "$OUT" | awk '$1=="U" && $2!="edata" && $2!="end" && $2!="etext" {print $2}')
[ -z "$LEAK" ] || { echo "[FAIL] unresolved symbols:"; echo "$LEAK"; exit 1; }
echo "[OK] no unresolved symbols"

# ---------------------------------------------------------------- adjacency, asked of the LINK
# The copy loops in this unit walk consecutive longwords, so a reordering edit would still
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

if [ "$UCP" = 1 ]; then
	echo "[*] paired ucontext bracket"
	for P in savecontext:58f10 restorecontext:58d76; do
		S=${P%%:*}; A=${P##*:}
		NEW=$($NM "$OUT" | awk -v n="$S" '$3==n && $2=="T" {print $1}')
		ORIG=$($NM "$OUT" | awk -v n="${S}_orig" '$3==n {print $1}')
		[ -n "$NEW" ] && [ "$NEW" != "000$A" ] \
			|| { echo "[FAIL] strong $S is stock/missing (addr='$NEW') -- the bracket is not in the kernel"; exit 1; }
		[ "$ORIG" = "000$A" ] \
			|| { echo "[FAIL] ${S}_orig is '$ORIG', expected 000$A -- the hand-off has no target"; exit 1; }
		[ "$($NM "$OUT" | grep -cE " T $S\$")" = "1" ] \
			|| { echo "[FAIL] $S does not have exactly one strong definition"; exit 1; }
		echo "[OK] $S bound @0x$NEW; the stock body is reachable as ${S}_orig @0x$ORIG"
	done
	$NM "$OUT" | grep -qE " [Dd] ucp_magic\$" \
		|| { echo "[FAIL] ucp_magic is not a .data symbol -- the block has no file storage"; exit 1; }
	$NM "$OUT" | grep -qE " [Dd] ucpshadow\$" \
		|| { echo "[FAIL] ucpshadow is not a .data symbol -- the ring has no file storage"; exit 1; }

	# The 84 counters, in declaration order.  The names are BUILT here rather than pasted, so
	# a source that renumbers the triples or the mc_state window fails this gate instead of
	# passing it with a plausible-looking sheet.
	UHEAD="ucp_magic ucp_on ucp_slots ucp_slot ucp_doff ucp_sent0 ucp_sent0_n"
	UHEAD="$UHEAD ucp_save_n ucp_s_bad_n ucp_ring_i ucp_r_n ucp_bad_n ucp_hit_n ucp_miss_n"
	UHEAD="$UHEAD ucp_dup_n ucp_self_void ucp_diffev_n ucp_stamp"
	UHEAD="$UHEAD ucp_b_seq ucp_b_ucp ucp_b_fold ucp_b_stamp ucp_b_slot ucp_b_s_seq"
	UHEAD="$UHEAD ucp_b_s_ucp ucp_b_s_fold ucp_b_n ucp_b_bits"
	I=0
	while [ $I -lt 12 ]; do UHEAD="$UHEAD ucp_b_i$I ucp_b_s$I ucp_b_r$I"; I=$(( I + 1 )); done
	UHEAD="$UHEAD ucp_ms_lock ucp_ms_seq ucp_ms_ucp ucp_ms_stamp"
	I=4
	while [ $I -lt 20 ]; do UHEAD="$UHEAD ucp_ms$I"; I=$(( I + 1 )); done
	adjacent "the ucp block is 84 adjacent longwords, in declaration order" $UHEAD

	# ... and nothing ELSE answers to ucp_*, or a counter would exist outside the one kpeek
	# the counter sheet tells the operator to take.
	NDECL=$(echo $UHEAD | wc -w)
	NDATA=$($NM "$OUT" | awk '($2=="D"||$2=="d") && $3 ~ /^ucp_/' | wc -l)
	[ "$NDECL" = 84 ] && [ "$NDATA" = 84 ] \
		|| { echo "[FAIL] ucp_* .data symbols: $NDATA, declared list: $NDECL, expected 84 each"; exit 1; }
	echo "[OK] exactly 84 ucp_* .data symbols, all of them inside the one-kpeek window"

	# The ring geometry is read out of the ARTIFACT's own .data and out of the section
	# headers, never from the source file, because the source is not what boots.
	python3 - "$OUT" <<'PY'
import struct, subprocess, sys
img = sys.argv[1]
f = open(img, 'rb').read()
def u16(o): return struct.unpack('>H', f[o:o+2])[0]
def u32(o): return struct.unpack('>I', f[o:o+4])[0]
e_shoff, e_shentsize, e_shnum, e_shstrndx = u32(32), u16(46), u16(48), u16(50)
secs = []
for i in range(e_shnum):
    b = e_shoff + i*e_shentsize
    secs.append(dict(name=u32(b), addr=u32(b+12), off=u32(b+16), size=u32(b+20)))
shstr = secs[e_shstrndx]['off']
for s in secs:
    o = shstr + s['name']; s['nm'] = f[o:f.index(b'\0', o)].decode('latin1')
data = next(s for s in secs if s['nm'] == '.data')
syms = {}
for line in subprocess.run(['m68k-linux-gnu-nm', img],
                           capture_output=True, text=True).stdout.splitlines():
    p = line.split()
    if len(p) == 3 and p[1] in 'Dd':
        syms.setdefault(p[2], int(p[0], 16))
def rd(name):
    return u32(data['off'] + (syms[name] - data['addr']))
bad = 0
for name, want in (('ucp_slots', 4), ('ucp_slot', 820), ('ucp_doff', 16),
                   ('ucp_on', 1), ('ucp_magic', 0x55435021)):
    got = rd(name)
    if got != want:
        print("[FAIL] %s reads %08x in .data, expected %08x" % (name, got, want)); bad += 1
need = rd('ucp_slots') * rd('ucp_slot')
have = data['addr'] + data['size'] - syms['ucpshadow']
if have < need:
    print("[FAIL] ucpshadow has %d bytes to the end of .data, the ring needs %d" % (have, need))
    bad += 1
if bad:
    raise SystemExit(1)
print("[OK] ring geometry, read out of the artifact: %d slots of %d bytes, %d copied bytes "
      "at +%d, %d bytes of .data from ucpshadow"
      % (rd('ucp_slots'), rd('ucp_slot'), rd('ucp_slot') - rd('ucp_doff'), rd('ucp_doff'), have))
print("[OK] ucp_magic 'UCP!', ucp_on 1, sentinel slot ucp_sent0 %08x (runtime-written)"
      % rd('ucp_sent0'))
PY
fi

# The standard packaging guards -- the same ones relink-040-f6.sh runs, for the same reasons:
# an unaligned .text total leaves a hole the loader copies as one block, and an unaligned
# .data size lands .bss on an odd address (rel.c puts .bss at data_end as-is).
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
