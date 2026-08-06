# burstrepeat5.sh -- burst regression on 68060-260806-06 (ISSUE-41 + F4), 2026-08-06.
#
# Same body as burstrepeat3.sh, re-addressed for textsize 0xe4bb8.  Anchors recomputed
# from nm rather than slid by a constant: F4 added counters inside .data, so the offsets
# between blocks changed, not just their base.  Two suites, same reasoning as
# burstrepeat3.sh: this is a regression check on segvn_faultpage's per-page permission
# check and the 060 far-page signal path, not a re-run of ISSUE-40's four-suite teardown
# criterion (which passed on the 060 in F0, 96/96 x4).  Stated so the shorter run is not
# later mistaken for the full ISSUE-40 acceptance.
#
# On real hardware /payload.bin sums to "1570 8192"; on the emulator it was regenerated
# and sums to "0 8192" -- the grep below is written for the hardware value.
#
# usage: (nohup sh -c "sh /tmp/burstrepeat5.sh 2 > /tmp/burstrepeat5.out 2>&1" &)
N=${1:-2}
ANCH=080FCEB8
X60=080FD158
ISP=080FD200
BLK=080FD614
I39=080FD650

if [ "`/kpeek $ISP 1 | sed 's/.*= //;s/ .*//'`" != "49363121" ]; then
	echo "ABORT: isp61_magic mismatch -- wrong image or stale addresses." > /tmp/burstrepeat5.log
	exit 1
fi
if [ "`/kpeek 080FD194 1 | sed 's/.*= //;s/ .*//'`" != "53564e21" ]; then
	echo "ABORT: segvn_prot_magic mismatch -- wrong image or stale addresses." > /tmp/burstrepeat5.log
	exit 1
fi

/tmp/memwatch $I39 7200 2000 > /tmp/memwatch-repeat5.log 2>&1 &
MW=$!

echo "=== burstrepeat5: $N suites, no reboot in between ===" > /tmp/burstrepeat5.log
date >> /tmp/burstrepeat5.log
/kpeek $ANCH 1 >> /tmp/burstrepeat5.log
/kpeek 080FD194 3 >> /tmp/burstrepeat5.log
/kpeek $BLK 53 >> /tmp/burstrepeat5.log

r=1
while [ $r -le $N ]; do
	echo "" >> /tmp/burstrepeat5.log
	echo "-------- SUITE $r start --------" >> /tmp/burstrepeat5.log
	date >> /tmp/burstrepeat5.log
	cd /
	sh /tmp/burstloop.sh 4 > /tmp/burst5-suite$r.log 2>&1
	echo "SUITE $r good_sums=`grep -c '1570 8192' /tmp/burst5-suite$r.log` (expect 96)" >> /tmp/burstrepeat5.log
	date >> /tmp/burstrepeat5.log
	echo "counters after suite $r:" >> /tmp/burstrepeat5.log
	/kpeek $X60 15 >> /tmp/burstrepeat5.log
	/kpeek 080FD194 3 >> /tmp/burstrepeat5.log
	/kpeek $ISP 12 >> /tmp/burstrepeat5.log
	/kpeek $BLK 53 >> /tmp/burstrepeat5.log
	r=`expr $r + 1`
done

kill $MW 2>/dev/null
echo "" >> /tmp/burstrepeat5.log
/kpeek $ANCH 1 >> /tmp/burstrepeat5.log
echo BURSTREPEAT5-DONE >> /tmp/burstrepeat5.log
