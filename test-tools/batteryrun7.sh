# batteryrun7.sh -- battery on 68040/68060-260809-02 (the widened vector-61 EA decode).
# Re-addressed from batteryrun6.sh for textsize 0xf25dc (-11 was 0xf2508).  Every anchor was
# recomputed from nm for THIS image, never slid by a constant.
# Adds the isp61 block: this build changes the vector-61 unit, so a run that does not read
# those counters cannot tell a working decode from one that never ran.
ANCH=0810A8DC
SVN=0810ABB8
X60=0810AB7C		# x60_fmt4_n .. x60_siginfo_n, 15 longs
BLK=0810B164		# cb_icode_calls .. ptd_tblfreed_n, 53 longs
F60=0810B244		# f60_magic .. f60_superdone_n, 16 longs
I61=0810AC24		# isp61_magic .. isp61_opfetch_fail_n, 15 longs

mkdir -p /pgc
if [ "`/tmp/kpeek $SVN 1 | sed 's/.*= //;s/ .*//'`" != "53564e21" ]; then
	echo "ABORT: segvn_prot_magic mismatch -- wrong image or stale addresses." > /tmp/battery7.log
	exit 1
fi
if [ "`/tmp/kpeek $F60 1 | sed 's/.*= //;s/ .*//'`" != "46503630" ]; then
	echo "ABORT: f60_magic mismatch -- wrong image or stale addresses." > /tmp/battery7.log
	exit 1
fi
{
	echo "=== ANCHORS ==="
	echo "hat_cm_ram:";        /tmp/kpeek $ANCH 1
	echo "segvn_prot block:";  /tmp/kpeek $SVN 5
	echo "cputype:";           /tmp/kpeek 0810AC1C 1
	echo
	echo "=== BEFORE ==="
	/tmp/kpeek $X60 15
	/tmp/kpeek $BLK 53
	echo "f60:"; /tmp/kpeek $F60 16
	echo "isp61:"; /tmp/kpeek $I61 15
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
	echo "isp61:"; /tmp/kpeek $I61 15
	echo BATTERYRUN7-DONE
} > /tmp/battery7.log 2>&1
