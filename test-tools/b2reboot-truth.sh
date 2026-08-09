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
	# Record the UPTIME too, so the verify phase can tell whether the reboot it depends on
	# actually happened.  A test that cannot detect its own precondition will happily report a
	# pass for a run that never crossed the boundary -- which is exactly what a first version of
	# this script did when it printed "every byte survived the reboot" after no reboot at all.
	echo "n=$N ref=$REF size=`ls -l $REF | awk '{print $5}'` kernel=`uname -m` uptime=`uptime`" > $DIR/EXPECT
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
	echo "B2RT now:      uptime=`uptime`"
	# FAIL CLOSED on the two preconditions rather than printing them and hoping someone reads.
	# Learned the hard way: a reboot came back on the DEFAULT kernel, not the one that wrote, and
	# only a manual uname check caught it.  A test that can detect its own precondition must also
	# refuse to run without it, or it is just a comment.
	WROTE_K=`sed -n 's/.*kernel=\(.*\) uptime=.*/\1/p' $DIR/EXPECT`
	NOW_K=`uname -m`
	if [ "$WROTE_K" != "$NOW_K" ]; then
		echo "B2RT ABORT: kernel MISMATCH."
		echo "B2RT   wrote: $WROTE_K"
		echo "B2RT   now:   $NOW_K"
		echo "B2RT   Booting the default kernel instead of the one under test measures one"
		echo "B2RT   kernel's writes through another kernel's reads.  Boot the writer and re-run;"
		echo "B2RT   /b2dt survives, so the write phase does NOT need repeating."
		exit 3
	fi
	# `uptime` prints THREE forms: "up 39 mins" below an hour, "up  1:15" above it, and
	# "up 2 days,  3:45" above a day.  The original guard understood only the first, so above
	# an hour WROTE_MIN came out EMPTY and the -n test skipped the guard silently: it failed
	# OPEN, the opposite of what its own comment promises.  Found and worked around by hand in
	# REALHW-260806-06-ACCEPTANCE.md (defect 1); fixed here 2026-08-09.
	#
	# The leading clock ("  6:04pm") also contains H:MM, so the H:MM pattern is anchored after
	# "up" -- matching the clock instead would compare wall times and call every run a reboot.
	up_minutes() {
		_hh=`echo "$1" | sed -n 's/.*up  *\([0-9][0-9]*\):\([0-9][0-9]\).*/\1/p'`
		_mm=`echo "$1" | sed -n 's/.*up  *\([0-9][0-9]*\):\([0-9][0-9]\).*/\2/p'`
		if [ -n "$_hh" ]; then expr $_hh \* 60 + $_mm; return; fi
		_d=`echo "$1" | sed -n 's/.*up  *\([0-9][0-9]*\) day.*/\1/p'`
		if [ -n "$_d" ]; then expr $_d \* 1440; return; fi
		echo "$1" | sed -n 's/.*up  *\([0-9][0-9]*\) *min.*/\1/p'
	}
	WROTE_MIN=`up_minutes "\`cat $DIR/EXPECT\`"`
	NOW_MIN=`up_minutes "\`uptime\`"`
	# Still fails open if BOTH are unparseable, but that is now a genuinely unknown format
	# rather than the ordinary case of a machine that has been up an hour.
	[ -z "$WROTE_MIN" ] && echo "B2RT WARN: could not parse the writer's uptime -- guard skipped"
	[ -z "$NOW_MIN" ] && echo "B2RT WARN: could not parse the current uptime -- guard skipped"
	if [ -n "$WROTE_MIN" ] && [ -n "$NOW_MIN" ] && [ "$NOW_MIN" -gt "$WROTE_MIN" ]; then
		echo "B2RT ABORT: uptime went UP ($WROTE_MIN -> $NOW_MIN min): no reboot happened."
		echo "B2RT   This would only show the page cache still holds the data."
		exit 3
	fi
	echo "B2RT preconditions OK: same kernel, and uptime shows a real reboot"
	echo "B2RT ^ COMPARE THOSE TWO UPTIMES.  If the current one is LARGER, the machine was never"
	echo "B2RT   rebooted and this run proves nothing about the reboot boundary -- it only shows"
	echo "B2RT   the page cache still has the data."
	echo "B2RT   (Also check the kernel: it must be the SAME one that wrote, or you have measured"
	echo "B2RT   one kernel's writes through another kernel's reads.)"
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
		echo "B2RT-RESULT PASS ($N files, every byte intact) -- valid ONLY if the uptimes above"
		echo "B2RT   show a reboot actually happened between the phases."
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
