# burstrepeat3.sh -- burst regression on 68060-260806-02 (F2), 2026-08-06.
#
# Same body as burstrepeat2.sh, re-addressed (+0x250, see batteryrun3.sh) and run
# for TWO suites rather than four.  Why two: this is a regression check on a change
# that touches only the vector-61 trap path, not the teardown path ISSUE-40's
# four-suite criterion was designed to stress -- and that criterion already passed
# on the 060 in F0 (68060-260802-01, 96/96 x4).  Two suites still cover the
# integrity claim (48 sums) and give two availrmem buckets to compare against F0's
# 0.35 pages/min.  Stated here so the shorter run is not later mistaken for the
# full ISSUE-40 acceptance.
#
# usage: (nohup sh -c "sh /tmp/burstrepeat3.sh 2 > /tmp/burstrepeat3.out 2>&1" &)
N=${1:-2}
ANCH=080FCD64
X60=080FD004
ISP=080FD07C
BLK=080FD490
I39=080FD4CC

if [ "`/kpeek $ISP 1 | sed 's/.*= //;s/ .*//'`" != "49363121" ]; then
	echo "ABORT: isp61_magic mismatch -- wrong image or stale addresses." > /tmp/burstrepeat3.log
	exit 1
fi

/tmp/memwatch $I39 7200 2000 > /tmp/memwatch-repeat3.log 2>&1 &
MW=$!

echo "=== burstrepeat3: $N suites, no reboot in between ===" > /tmp/burstrepeat3.log
date >> /tmp/burstrepeat3.log
/kpeek $ANCH 1 >> /tmp/burstrepeat3.log
/kpeek $BLK 53 >> /tmp/burstrepeat3.log

r=1
while [ $r -le $N ]; do
	echo "" >> /tmp/burstrepeat3.log
	echo "-------- SUITE $r start --------" >> /tmp/burstrepeat3.log
	date >> /tmp/burstrepeat3.log
	cd /
	sh /tmp/burstloop.sh 4 > /tmp/burst3-suite$r.log 2>&1
	echo "SUITE $r good_sums=`grep -c '1570 8192' /tmp/burst3-suite$r.log` (expect 96)" >> /tmp/burstrepeat3.log
	date >> /tmp/burstrepeat3.log
	echo "counters after suite $r:" >> /tmp/burstrepeat3.log
	/kpeek $X60 8 >> /tmp/burstrepeat3.log
	/kpeek $ISP 12 >> /tmp/burstrepeat3.log
	/kpeek $BLK 53 >> /tmp/burstrepeat3.log
	r=`expr $r + 1`
done

kill $MW 2>/dev/null
echo "" >> /tmp/burstrepeat3.log
/kpeek $ANCH 1 >> /tmp/burstrepeat3.log
echo BURSTREPEAT3-DONE >> /tmp/burstrepeat3.log
