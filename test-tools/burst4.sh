#!/bin/sh
# 4 bursts x (6 x 4 MiB concurrent copies + hat_dup_cow 64).  Run detached.
#
# RECOVERED INTO THE REPOSITORY 2026-08-21.  burstloop11.sh has been tracked here
# and names this file as a prerequisite, but the file itself was not -- it lived
# only on the NAS (amix/hwtest-260801/) and on whichever machine last ran it.  A
# fresh clone therefore could not run step 6 of docs/ACCEPTANCE.md at all.  This
# copy is byte-identical to the NAS one apart from this comment block.
#
# STILL MISSING: /tmp/hat_dup_cow, the fork/COW stressor launched below, is a
# BINARY on the NAS (amix/hwtest-260801/, also f2-260806b, hw260719,
# hwtest-260727, hwtest-260801b) and no source for it is in this repository.
# Without it the copies still run and the 24 sums per round still verify data
# integrity, but the concurrent fork/COW pressure -- which is what made ISSUE-40
# visible -- does not happen.  A run without it is a weaker test and must say so.
#
# Expect 24 lines of `1570 8192` per round: 4 bursts x 6 files.
b=1
while [ $b -le 4 ]; do
	echo BURST $b
	i=1
	while [ $i -le 6 ]; do
		cp /payload.bin /press$i.bin &
		i=`expr $i + 1`
	done
	/tmp/hat_dup_cow 64 >/dev/null 2>&1 &
	wait
	sum /press1.bin /press2.bin /press3.bin /press4.bin /press5.bin /press6.bin
	b=`expr $b + 1`
done
echo ALLBURSTS-DONE
