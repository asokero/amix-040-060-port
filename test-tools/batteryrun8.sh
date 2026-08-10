# batteryrun8.sh -- battery on the RTG kernel 68060-260809-03 (unix-040-rtg-isp).
# Re-addressed from batteryrun7.sh for textsize 0xfb608: the two graphics drivers move
# EVERY anchor, so none of batteryrun7.sh's addresses apply.  Recomputed from nm, never
# slid by a constant.  The isp61 block is read because this image carries the widened decode.
ANCH=08113908
SVN=08113BE4
X60=08113BA8		# x60_fmt4_n .. x60_siginfo_n, 15 longs
BLK=08114190		# cb_icode_calls .. ptd_tblfreed_n, 53 longs
F60=08114270		# f60_magic .. f60_superdone_n, 16 longs
I61=08113C50		# isp61_magic .. isp61_opfetch_fail_n, 15 longs

mkdir -p /pgc
if [ "`/tmp/kpeek $SVN 1 | sed 's/.*= //;s/ .*//'`" != "53564e21" ]; then
	echo "ABORT: segvn_prot_magic mismatch -- wrong image or stale addresses." > /tmp/battery8.log
	exit 1
fi
if [ "`/tmp/kpeek $F60 1 | sed 's/.*= //;s/ .*//'`" != "46503630" ]; then
	echo "ABORT: f60_magic mismatch -- wrong image or stale addresses." > /tmp/battery8.log
	exit 1
fi
{
	echo "=== ANCHORS ==="
	echo "hat_cm_ram:";        /tmp/kpeek $ANCH 1
	echo "segvn_prot block:";  /tmp/kpeek $SVN 5
	echo "cputype:";           /tmp/kpeek 08113C48 1
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
	echo BATTERYRUN8-DONE
} > /tmp/battery8.log 2>&1
