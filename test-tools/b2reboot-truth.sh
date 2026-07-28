#!/bin/sh
# b2reboot-truth.sh -- the copyback acceptance item that was still missing: does data written with
# a COPYBACK data cache survive a reboot, byte for byte?
#
# WHY THIS TEST EXISTS AND WHAT IT ACTUALLY PROVES
# With write-through, every store reaches memory as it happens.  With copyback (hat_cm_ram = 0x20)
# stores sit in DIRTY D-cache lines and the disk only sees them when something pushes the cache --
# the hooks landed dormant in July do that (cb_release040 page pushes, hat040's Lhl_dofree ordering,
# dma_cache040's prepare=cpusha / complete=range-cinvl protocol).  So the question copyback has to
# answer is not "does it run" but "does the data land".  A reboot is the cheapest boundary that
# forces the whole chain: dirty lines -> cache push -> buffer cache -> disk -> a fresh boot's reads.
#
# USE b2verify, NOT `sum`.  This is the 23.7. lesson, and it cost that session a wrong verdict:
# AMIX's `sum` prints a PARTIAL read-progress count after ferror(), so a transient read error looks
# exactly like a short file, which is how a clean B2 run was read as silent disk corruption.
# b2verify reports the real errno, st_size, and whether a close/reopen/retry succeeds.
#
# TWO PHASES, because the boundary is the reboot:
#     sh b2reboot-truth.sh write      before the reboot   (writes, syncs, records expectations)
#     ... reboot the machine ...
#     sh b2reboot-truth.sh verify     after  the reboot   (byte-compares every file)
#
# /b2dt, not /tmp: /tmp is cleared on every AMIX boot, which would delete the evidence the reboot
# was supposed to preserve.  (The same trap the ISSUE-37 state files had to avoid.)
#
# Needs /payload.bin (the 4 MiB reference) and /tmp/b2verify (cc -o b2verify b2verify.c).
# Run it on BOTH kernels: the copyback one is the test, the write-through one is the control that
# shows the harness itself is sound.  uname -m identifies which.

REF=/payload.bin
DIR=/b2dt
V=/tmp/b2verify
N=6

[ -f "$REF" ] || { echo "MISSING $REF"; exit 20; }

case "$1" in
write)
	[ -x "$V" ] || { echo "MISSING $V (cc -o b2verify b2verify.c)"; exit 20; }
	mkdir -p $DIR
	rm -f $DIR/f* $DIR/EXPECT
	echo "B2RT WRITE kernel=`uname -m`"
	i=1
	while [ $i -le $N ]; do
		cp $REF $DIR/f$i || { echo "B2RT FAIL cp f$i"; exit 1; }
		echo "  wrote $DIR/f$i"
		i=`expr $i + 1`
	done
	# Record what the next boot must find, so the verify phase cannot be fooled by a
	# half-written set: the count, the reference size, and the kernel that wrote it.
	echo "n=$N ref=$REF size=`ls -l $REF | awk '{print $5}'` kernel=`uname -m`" > $DIR/EXPECT
	sync
	sleep 2
	sync
	echo "B2RT WRITE-DONE synced.  Now REBOOT (clean: 'init 6' or haltsys), then:"
	echo "B2RT   sh b2reboot-truth.sh verify"
	echo "B2RT NOTE: a clean reboot is the documented acceptance item.  A POWER CUT is the"
	echo "B2RT       stronger variant and was never run for copyback -- if you want it, do the"
	echo "B2RT       write phase, wait for the disk to go quiet, then cut power."
	;;
verify)
	[ -x "$V" ] || { echo "MISSING $V -- recompile it, /tmp was cleared by the boot"; exit 20; }
	[ -f $DIR/EXPECT ] || { echo "B2RT FAIL no $DIR/EXPECT -- was the write phase run?"; exit 1; }
	echo "B2RT VERIFY kernel=`uname -m`"
	echo "B2RT wrote-by: `cat $DIR/EXPECT`"
	bad=0
	i=1
	while [ $i -le $N ]; do
		if [ -f $DIR/f$i ]; then
			$V $REF $DIR/f$i b2rt-f$i || bad=`expr $bad + 1`
		else
			echo "B2RT FAIL $DIR/f$i MISSING after the reboot"
			bad=`expr $bad + 1`
		fi
		i=`expr $i + 1`
	done
	if [ $bad -eq 0 ]; then
		echo "B2RT-RESULT PASS ($N files, every byte survived the reboot)"
	else
		echo "B2RT-RESULT FAIL ($bad of $N bad)"
		echo "B2RT   read the CLASS: V1_* = transient read fault, file intact on reopen (that is"
		echo "B2RT   ISSUE-22, NOT copyback).  V3/V4/V5/V6 = persistent -> a real copyback"
		echo "B2RT   disk-truth defect: capture this output and STOP."
	fi
	;;
*)
	echo "usage: sh b2reboot-truth.sh write|verify"
	exit 2
	;;
esac
