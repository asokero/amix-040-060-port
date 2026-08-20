# i10d.sh -- ISSUE-10 CPU-INDEPENDENT brk/sbrk ring tracer readout (040/060 AND 030).
#
# WHY.  User ruling: sh is the SAME binary on 030/040/060, so the desync (sh's blok arena
# top 0x800152A0 lands past its break 0x80014FB4) must be the 040 kernel granting a
# different brk result than 030/060 for identical requests.  i10d (PART ELEVEN) records a
# ring of the last 24 brk calls -- {newbrk, p_brkbase, p_brksize BEFORE, AFTER, brkend
# AFTER, ret}.  Run this on the 040 build, then on the 030 build (relink-030-i10d.sh) and
# the 060, and COMPARE: for the identical sh sbrk sequence, does the 040 grant a smaller
# brkend (under-grow: brkend < requested) where the 030 does not?
#
# ONE PROBE, ALL CPUS.  brk is the same sysent slot everywhere; the 040/060 image and the
# standalone 030 image publish the SAME I1D! block layout.  This script finds whichever is
# live by its magic and reads it -- no CPU/base guess needed.
#
# THE READOUT IS THE CONSOLE.  amiberry's slice-publish is unreliable under write
# buffering, so this ENDS by kpeek-ing the whole ring to /dev/console -- screenshot that.
# The slice publish (block 25792) stays as a backup.
#
# HOW TO READ THE RING (each entry is 6 longs):
#   [0] newbrk    the syscall's requested new break
#   [1] brkbase   p_brkbase (constant per proc)
#   [2] pre       p_brksize BEFORE this call
#   [3] post      p_brksize AFTER  this call
#   [4] brkend    brkbase + post = the GRANTED break after this call  <-- compare across CPUs
#   [5] ret       0 = ok, else errno (12 = ENOMEM)
# i10d_head (+0xc) is the next write slot; i10d_n (+0x8) the total.  If n<=24 the entries
# 0..n-1 are chronological; if n>24 the oldest is at head, newest at head-1.
# The decisive read: find the entry whose newbrk first reaches >= 0x800152A0 (sh's arena
# top).  If NO entry requests that high, sh writes past its break relying on kernel rounding
# the 040 did not grant.  If one does but its brkend stays < newbrk, the 040 UNDER-GREW.
#
# Bourne sh (backticks, no $(...), no [[ ]], no grep -q).  kpeek/kpoke staged from the raw
# slice tail.  The addresses below MOVE every build; refresh from
# `tools/status-facts.sh <kernel> <base>` (040 build at 0x07000000, 030 build at 0x08000000).

LOG=/i10d.log

# candidate live blocks: "magic on ring lo hi label"  (on=magic+4, ring=magic+0x34,
# lo=magic+0x18, hi=magic+0x1c -- identical layout on every CPU)
C1="0710DE88 0710DE8C 0710DEBC 0710DEA0 0710DEA4 040-0x07"
C2="0810DE88 0810DE8C 0810DEBC 0810DEA0 0810DEA4 040-0x08"
C3="070E7154 070E7158 070E7188 070E716C 070E7170 030-0x07"
C4="080E7154 080E7158 080E7188 080E716C 080E7170 030-0x08"

exec > $LOG 2>&1
echo I10D-START

echo "--- reclaim earlier probe droppings ---"
rm -f /i10a.sh /i10a.log /i10b.sh /i10b.log /i10c.sh /i10c.log /i10d.log2 /idm.txt /idl.txt
sync

echo "--- stage kpeek + kpoke out of the raw slice tail ---"
dd if=/dev/dsk/c0d0s5 of=/kpeek bs=1024 skip=25600 count=32
dd if=/dev/dsk/c0d0s5 of=/kpoke bs=1024 skip=25632 count=32
chmod 755 /kpeek /kpoke
sync

echo "--- BASE PICK: find the live I1D! block by magic (49314421) ---"
IDMAG=""
for cand in "$C1" "$C2" "$C3" "$C4"; do
	set -- $cand
	echo "try $6 magic @$1:"
	/kpeek $1 1 > /idm.txt
	cat /idm.txt
	if grep '= 49314421' /idm.txt > /dev/null 2>&1; then
		IDMAG=$1; IDON=$2; IDRING=$3; IDLO=$4; IDHI=$5; IDLBL=$6
		echo "LIVE i10d block: $IDLBL"
	fi
done
if [ -z "$IDMAG" ]; then
	echo "NO live I1D! block found -- refresh addresses from status-facts for THIS kernel"
	echo I10D-END
	sync
	exit 1
fi
sync

echo "--- BEFORE: the i10d header (magic first; on/n/head must be 0) ---"
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

echo "--- AFTER: the WHOLE i10d block (13 header + 24*6 ring = 157 longs) ---"
/kpeek $IDMAG 157
sync

echo I10D-END
sync
sync

# publish to the raw slice (backup) at block 25792
dd if=$LOG of=/dev/dsk/c0d0s5 bs=1024 seek=25792
sync
sync

# THE RELIABLE READOUT: dump the whole ring to the CONSOLE for a screenshot.
echo "==== I1D! ring ($IDLBL) -- screenshot this ====" > /dev/console
/kpeek $IDMAG 157 > /dev/console
echo I10D-PUBLISHED > /dev/console
