# batteryrun5.sh -- battery on 68040/68060-260806-06 (ISSUE-41 segvn fix + F4 siginfo).
# Re-addressed from batteryrun4.sh for textsize 0xe4bb8 (-05 was 0xe4b70).  The shift is
# NOT a uniform +0x48: F4 added x60_far_addr/x60_siginfo_n inside .data, so every anchor
# was recomputed from nm, not slid.  Reads segvn_prot_magic first: an address that is
# merely plausible is the one failure a counter cannot report on itself.
ANCH=080FCEB8
SVN=080FD194
X60=080FD158		# x60_fmt4_n .. x60_siginfo_n, 15 longs (13 + far_addr + siginfo_n)
BLK=080FD614		# cb_icode_calls .. ptd_tblfreed_n, 53 longs

mkdir -p /pgc
if [ "`/tmp/kpeek $SVN 1 | sed 's/.*= //;s/ .*//'`" != "53564e21" ]; then
	echo "ABORT: segvn_prot_magic mismatch -- wrong image or stale addresses." > /tmp/battery5.log
	exit 1
fi
{
	echo "=== ANCHORS ==="
	echo "hat_cm_ram:";        /tmp/kpeek $ANCH 1
	echo "segvn_prot block:";  /tmp/kpeek $SVN 5
	echo "cputype:";           /tmp/kpeek 080FD1F8 1
	echo
	echo "=== BEFORE ==="
	/tmp/kpeek $X60 15
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
	/tmp/kpeek $X60 15
	/tmp/kpeek $BLK 53
	echo BATTERYRUN5-DONE
} > /tmp/battery5.log 2>&1
