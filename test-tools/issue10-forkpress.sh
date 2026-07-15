#!/bin/sh
# ISSUE-10 fork-heavy variant: bias the corruption victim toward a forked USER
# child (which faults on its own heap = the resident-leaf morphology the
# SEGVCHAIN probe can analyze) rather than /sbin/init's control flow.
# Heavy fork/COW churn (the user-heap producers) + light copy pressure.
echo FORKPRESS-START
# light copy pressure (2 concurrent 4 MiB) to keep pages cycling through reclaim
cp /payload.bin /fp1.bin &
cp /payload.bin /fp2.bin &
# HEAVY fork/COW churn: repeated large hat_dup_cow runs -- each child touches COW
# pages and, if handed a reused frame, faults reading its OWN heap (SEGVDMP/SEGVCHAIN)
i=1
while [ $i -le 6 ]; do
	/tmp/hat_dup_cow 128 >/dev/null 2>&1 &
	i=`expr $i + 1`
done
wait
echo FORKPRESS-DONE
