# batteryrun4.sh -- battery on 68040/68060-260806-05 (the segvn per-page permission fix).
# Re-addressed for textsize 0xe4b70.  Reads segvn_prot_magic first: an address that is
# merely plausible is the one failure a counter cannot report on itself.
ANCH=080FCE70
SVN=080FD144
X60=080FD110
BLK=080FD5C4		# cb_icode_calls .. ptd_tblfreed_n, 53 longs

mkdir -p /pgc
if [ "`/tmp/kpeek $SVN 1 | sed 's/.*= //;s/ .*//'`" != "53564e21" ]; then
	echo "ABORT: segvn_prot_magic mismatch -- wrong image or stale addresses." > /tmp/battery4.log
	exit 1
fi
{
	echo "=== ANCHORS ==="
	echo "hat_cm_ram:";        /tmp/kpeek $ANCH 1
	echo "segvn_prot block:";  /tmp/kpeek $SVN 5
	echo "cputype:";           /tmp/kpeek 080FD1A8 1
	echo
	echo "=== BEFORE ==="
	/tmp/kpeek $X60 14
	/tmp/kpeek $BLK 53
	echo
	for t in proctest fputest mlocktest msynctst mincoretst bigargv ptracepoke
	do
		echo "======== $t ========"; /tmp/$t 2>&1
	done
	echo "======== bmaptest /pgc ========";  /tmp/bmaptest /pgc 2>&1
	echo "======== devmaptest ========";     /tmp/devmaptest 2>&1
	echo "======== exectest 20 ========";    /tmp/exectest 20 2>&1
	echo "======== mul64test ========";      /tmp/mul64test 2>&1
	# NOTE: cases a and b ONLY.  Case c still retries, and on the 060 it prints a
	# "NOTICE: User BUS ERROR ... FAULT:1" line per iteration, which floods the console
	# and starves the machine -- it left a wedged PID 190 behind once.  c belongs in its
	# own supervised run, not in a battery.
	echo "======== protfault a ========";    /tmp/protfault a 2>&1
	echo "======== protfault b ========";    /tmp/protfault b 2>&1
	echo
	echo "=== AFTER ==="
	/tmp/kpeek $X60 14
	/tmp/kpeek $BLK 53
	echo BATTERYRUN4-DONE
} > /tmp/battery4.log 2>&1
