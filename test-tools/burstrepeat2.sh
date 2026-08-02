# burstrepeat2.sh -- ISSUE-40 criterion 5, the run that started all of this
# (2026-08-02).  Same shape as burstrepeat.sh on 68040-260801-04, re-addressed
# for 68040-260802-01, so the two logs are directly comparable.
#
# WHAT IS BEING COMPARED.  On 260801-04, four consecutive 16-burst suites without
# a reboot gave availrmem in ten-minute buckets:
#     3981 -> 3698 -> 3405 -> 3128 -> 2891 -> 2690 -> 2450 -> 2235 -> 2035 -> 1847
# i.e. ~21 pages/min, no recovery in 100 minutes, and the suites themselves
# inflated 24m37s -> 27m03s -> 34m56s -> 45m56s (+87 %) for identical work.
# Data integrity was 96/96 throughout, so the failure was purely resource decay.
#
# PREDICTION, pre-registered: with both ISSUE-40 halves the bucket series stays
# flat, the four suite wall-clocks stay within a few minutes of each other, and
# good_sums is 96 every suite.  The suite TIMES are the strongest signal here
# because they depend on no counter of ours at all.
#
# usage: sh burstrepeat2.sh [suites]      (default 4)
N=${1:-4}
CB=080FD230
KD=080FD24C
I39=080FD27C
PTD=080FD2E8
ANCH=080FCB68

if [ "`/kpeek $PTD 1 | sed 's/.*= //;s/ .*//'`" != "50544421" ]; then
	echo "ABORT: ptd_magic mismatch -- wrong image or stale addresses." > /tmp/burstrepeat2.log
	exit 1
fi

# 2 s sampling; 4 suites is ~100 min.
/tmp/memwatch $I39 7200 2000 > /tmp/memwatch-repeat2.log 2>&1 &
MW=$!

echo "=== burstrepeat2: $N suites, no reboot in between ===" > /tmp/burstrepeat2.log
date >> /tmp/burstrepeat2.log
/kpeek $ANCH 1 >> /tmp/burstrepeat2.log
/kpeek $PTD 11 >> /tmp/burstrepeat2.log

r=1
while [ $r -le $N ]; do
	echo "" >> /tmp/burstrepeat2.log
	echo "-------- SUITE $r start --------" >> /tmp/burstrepeat2.log
	date >> /tmp/burstrepeat2.log
	cd /
	sh /tmp/burstloop.sh 4 > /tmp/burst2-suite$r.log 2>&1
	echo "SUITE $r good_sums=`grep -c '1570 8192' /tmp/burst2-suite$r.log` (expect 96)" >> /tmp/burstrepeat2.log
	date >> /tmp/burstrepeat2.log
	echo "counters after suite $r:" >> /tmp/burstrepeat2.log
	/kpeek $KD 3 >> /tmp/burstrepeat2.log
	/kpeek $I39 6 >> /tmp/burstrepeat2.log
	/kpeek $CB 4 >> /tmp/burstrepeat2.log
	/kpeek $PTD 11 >> /tmp/burstrepeat2.log
	r=`expr $r + 1`
done

kill $MW 2>/dev/null
echo "" >> /tmp/burstrepeat2.log
/kpeek $ANCH 1 >> /tmp/burstrepeat2.log
echo BURSTREPEAT2-DONE >> /tmp/burstrepeat2.log
