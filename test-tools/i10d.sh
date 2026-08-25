# i10d.sh -- ISSUE-10 CPU-independent brk/sbrk ring tracer WITH data-segment extent
# (040/060 AND 030).
#
# WHY.  i10d already proved brk grants byte-exact (newbrk==brkend) IDENTICALLY on 040 and
# 030 (same sh, brkbase 0x800114B4 both), so brk is exonerated: the sole 040-vs-030
# difference is that the 030 HONOURS sh's write ~748B past its logical break while the 040
# drops it (as_fault seg=0 -> SEGV_MAPERR).  This EXTENDED ring adds, per brk call, the
# actual data-segment extent, to say WHICH mechanism the 030 uses:
#   (A) RESERVE-AHEAD: the segment reaches PAST the break -> the past-break write is
#       already in-segment (seg@(brkend+0x1000) != 0, or seg_end > 0x800152A0).
#       040 fix = make brk/as_map reserve the segment ahead of the logical break.
#   (B) GROW-ON-FAULT: the segment is page-exact to the break (seg_end == page(break) =
#       0x80015000, seg@(brkend+0x1000) == 0) -> the 030 fault handler demand-grows it.
#       040 fix = restore that demand-grow in as_fault/segvn.
#
# ONE PROBE, ALL CPUS.  The 040/060 image and the standalone 030 image publish the SAME
# I1D! block.  This script finds whichever is live by its magic (grep-free -- grep is NOT
# on the install miniroot) and reads it.
#
# HOW TO READ EACH RING ENTRY (9 longs; i10d_stride confirms 9):
#   [0] newbrk    the sbrk request        [5] ret       0 = ok, 12 = ENOMEM
#   [1] brkbase   p_brkbase (constant)    [6] seg_end   s_base+s_size of the DATA segment
#   [2] pre       p_brksize BEFORE        [7] seg@brkend    seg ptr covering the break (0=none)
#   [3] post      p_brksize AFTER         [8] seg@nextpage  seg ptr covering brkend+0x1000
#   [4] brkend    brkbase+post = break        (nonzero = RESERVE-AHEAD, mechanism A)
# DECISIVE: on the 030, for the entry whose brkend ~0x80014FB4 (below the marker
# 0x800152A0), read [6] seg_end and [8] seg@nextpage.  seg_end > 0x800152A0 (or [8] != 0)
# = reserve-ahead (A).  seg_end == 0x80015000 with [8] == 0 = page-exact -> grow-on-fault
# (B).  Compare to the 040's [6]/[8] for the same break (i10c already saw seg=0 there).
#
# i10d_head (+0xc) is the next write slot, i10d_n (+0x8) the total.  RESET between runs:
# kpoke i10d_head 0, i10d_n 0 (and re-arm i10d_on).  Band filter [lo,hi) is kpoke-able.
#
# Bourne sh, GREP-FREE (case-match on backtick-captured kpeek output).  Addresses MOVE
# every build; refresh from `tools/status-facts.sh <kernel> <base>` (040 at 0x07000000,
# 030 at 0x08000000).

LOG=/i10d.log

# candidate live blocks: "magic on ring lo hi label" (on=+4, ring=+0x34, lo=+0x18, hi=+0x1c)
C1="0710DEE0 0710DEE4 0710DF14 0710DEF8 0710DEFC 040-0x07"
C2="0810DEE0 0810DEE4 0810DF14 0810DEF8 0810DEFC 040-0x08"
C3="070E71AC 070E71B0 070E71E0 070E71C4 070E71C8 030-0x07"
C4="080E71AC 080E71B0 080E71E0 080E71C4 080E71C8 030-0x08"

exec > $LOG 2>&1
echo I10D-START

echo "--- reclaim earlier probe droppings ---"
rm -f /i10a.sh /i10a.log /i10b.sh /i10b.log /i10c.sh /i10c.log /idm.txt /icl.txt
sync

echo "--- stage kpeek + kpoke out of the raw slice tail ---"
dd if=/dev/dsk/c0d0s5 of=/kpeek bs=1024 skip=25600 count=32
dd if=/dev/dsk/c0d0s5 of=/kpoke bs=1024 skip=25632 count=32
chmod 755 /kpeek /kpoke
sync

echo "--- BASE PICK (grep-free): find the live I1D! block by magic 49314421 ---"
IDMAG=""
for cand in "$C1" "$C2" "$C3" "$C4"; do
	set -- $cand
	OUT=`/kpeek $1 1`
	echo "$6 magic @$1: $OUT"
	case "$OUT" in
	*49314421*)
		IDMAG=$1; IDON=$2; IDRING=$3; IDLO=$4; IDHI=$5; IDLBL=$6
		echo "LIVE i10d block: $IDLBL"
		;;
	esac
done
if [ -z "$IDMAG" ]; then
	echo "NO live I1D! block -- refresh addresses from status-facts for THIS kernel"
	echo I10D-END
	sync
	exit 1
fi
sync

echo "--- BEFORE: the i10d header (magic first; on/n/head must be 0; stride must be 9) ---"
/kpeek $IDMAG 13
sync

echo "--- ARM: i10d_on 0 -> 1, band filter to sh's arena [0x80011000, 0x80020000) ---"
/kpoke $IDON 0 1
echo "KPOKE i10d_on rc=$?"
/kpoke $IDLO 0 80011000
/kpoke $IDHI ffffffff 80020000
echo "KPOKE band rc=$?"
/kpeek $IDMAG 13
sync

echo "--- mount the install source (slice 4, s5) at /cdrom, READ-ONLY ---"
/etc/mount /dev/dsk/c0d0s4 /cdrom 1 s5
echo "MOUNT rc=$?"
sync

echo "--- THE WALL: sh -n parses the whole script; the brk ring fills ---"
sh -n /cdrom/install/bin/setup.sh
echo "WALL rc=$?"
sync

echo "--- AFTER: the WHOLE i10d block (13 header + 16*9 ring = 157 longs) ---"
/kpeek $IDMAG 157
sync

echo I10D-END
sync
sync

# publish to the raw slice (backup) at block 25792
dd if=$LOG of=/dev/dsk/c0d0s5 bs=1024 seek=25792
sync
sync

# THE RELIABLE READOUT: dump the whole block to the CONSOLE for a screenshot.
echo "==== I1D! ring ($IDLBL) -- screenshot this ====" > /dev/console
/kpeek $IDMAG 157 > /dev/console
echo I10D-PUBLISHED > /dev/console
