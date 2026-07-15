#!/bin/sh
# ISSUE-10 pressure repro -- concurrent 4 MiB copies + fork/COW churn to force
# page reclaim/pageout (maximizes stale-PTE page-reuse rate).  Run standalone on
# the guest so telnet per-command timeouts do not drop children mid-copy.
echo PRESSURE-START
# 6 concurrent 4 MiB copies = 24 MiB simultaneous copy pressure (one per the old
# "one per telnet session" recipe, but from a single detached script)
i=1
while [ $i -le 6 ]; do
	cp /payload.bin /press$i.bin &
	i=`expr $i + 1`
done
# concurrent fork/COW churn (the corruption escalates into forked sh/init)
/tmp/hat_dup_cow 64 >/dev/null 2>&1 &
wait
echo PRESSURE-COPIES-DONE
# verify file-data writeback stayed byte-perfect (isolates reuse-corruption from putpage)
sum /press1.bin /press2.bin /press3.bin /press4.bin /press5.bin /press6.bin
echo PRESSURE-DONE
