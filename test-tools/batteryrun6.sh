# batteryrun6.sh -- battery on 68040/68060-260807-09 (F3 M2b: the 68060 FPSP).
# Re-addressed from batteryrun5.sh for textsize 0xf2508 (-06 was 0xe4bb8).  The 060 package
# is 54 KiB of .text, so every anchor was recomputed from nm, never slid by a constant.
# Adds the f60 block: an FPSP that declines is as much a regression as one that crashes.
ANCH=0810A808
SVN=0810AAE4
X60=0810AAA8		# x60_fmt4_n .. x60_siginfo_n, 15 longs
BLK=0810B084		# cb_icode_calls .. ptd_tblfreed_n, 53 longs
F60=0810B164		# f60_magic .. f60_superdone_n, 16 longs

mkdir -p /pgc
if [ "`/tmp/kpeek $SVN 1 | sed 's/.*= //;s/ .*//'`" != "53564e21" ]; then
	echo "ABORT: segvn_prot_magic mismatch -- wrong image or stale addresses." > /tmp/battery6.log
	exit 1
fi
if [ "`/tmp/kpeek $F60 1 | sed 's/.*= //;s/ .*//'`" != "46503630" ]; then
	echo "ABORT: f60_magic mismatch -- wrong image or stale addresses." > /tmp/battery6.log
	exit 1
fi
{
	echo "=== ANCHORS ==="
	echo "hat_cm_ram:";        /tmp/kpeek $ANCH 1
	echo "segvn_prot block:";  /tmp/kpeek $SVN 5
	echo "cputype:";           /tmp/kpeek 0810AB48 1
	echo
	echo "=== BEFORE ==="
	/tmp/kpeek $X60 15
	/tmp/kpeek $BLK 53
	echo "f60:"; /tmp/kpeek $F60 16
	echo
	for t in proctest fputest mlocktest msynctst mincoretst bigargv ptracepoke
	do
		echo "======== $t ========"; /tmp/$t 2>&1
	done
	echo "======== bmaptest /pgc ========";  /tmp/bmaptest /pgc 2>&1
	echo "======== devmaptest ========";     /tmp/devmaptest 2>&1
	echo "======== exectest 20 ========";    /tmp/exectest 20 2>&1
	echo "======== mul64test ========";      /tmp/mul64test 2>&1
	echo "======== protfault a ========";    /tmp/protfault a 2>&1
	echo "======== protfault b ========";    /tmp/protfault b 2>&1
	echo
	echo "=== AFTER ==="
	/tmp/kpeek $X60 15
	/tmp/kpeek $BLK 53
	echo "f60:"; /tmp/kpeek $F60 16
	echo BATTERYRUN6-DONE
} > /tmp/battery6.log 2>&1
