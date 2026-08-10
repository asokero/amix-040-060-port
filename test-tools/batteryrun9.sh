# batteryrun9.sh -- battery on 68040/68060-260810-02 (F3 M3: vectors 55 and 60).
# Re-addressed for textsize 0xf264c.  The f60 block is read as 18 longs, not 16: M3
# appended f60_unsupp_n and f60_effadd_n at the end of it.  Every anchor recomputed from
# nm for THIS image and then audited as a set -- generating by substitution is exactly
# where a stale address survives, and it did twice on 2026-08-10.
ANCH=0810A94C
SVN=0810AC28
X60=0810ABEC		# x60_fmt4_n .. x60_siginfo_n, 15 longs
BLK=0810B1D4		# cb_icode_calls .. ptd_tblfreed_n, 53 longs
F60=0810B2B4		# f60_magic .. f60_superdone_n, 16 longs
I61=0810AC94		# isp61_magic .. isp61_opfetch_fail_n, 15 longs

mkdir -p /pgc
if [ "`/tmp/kpeek $SVN 1 | sed 's/.*= //;s/ .*//'`" != "53564e21" ]; then
	echo "ABORT: segvn_prot_magic mismatch -- wrong image or stale addresses." > /tmp/battery9.log
	exit 1
fi
if [ "`/tmp/kpeek $F60 1 | sed 's/.*= //;s/ .*//'`" != "46503630" ]; then
	echo "ABORT: f60_magic mismatch -- wrong image or stale addresses." > /tmp/battery9.log
	exit 1
fi
{
	echo "=== ANCHORS ==="
	echo "hat_cm_ram:";        /tmp/kpeek $ANCH 1
	echo "segvn_prot block:";  /tmp/kpeek $SVN 5
	echo "cputype:";           /tmp/kpeek 0810AC8C 1
	echo
	echo "=== BEFORE ==="
	/tmp/kpeek $X60 15
	/tmp/kpeek $BLK 53
	echo "f60:"; /tmp/kpeek $F60 18
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
	echo "f60:"; /tmp/kpeek $F60 18
	echo "isp61:"; /tmp/kpeek $I61 15
	echo BATTERYRUN9-DONE
} > /tmp/battery9.log 2>&1
