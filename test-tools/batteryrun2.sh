# batteryrun2.sh -- ISSUE-40 criterion 4: the 9-test battery on 68040-260802-01,
# the kernel with BOTH ISSUE-40 halves (2026-08-02).
#
# Re-addressed from batteryrun.sh; every address below is for THIS image
# (0x08000000 + textsize 0xe4868 + nm(.data)) and the anchors prove it.
#
# What is new versus the 260801-04 run: hat_ptfree now runs an ownership gate and
# four list removals on every table-page free, so the ptd block is read either
# side.  ptd_keep0_n/keepn_n/meta_n/badlink_n must ALL still be zero afterwards.
#
# /pgc first: bmaptest reports FAIL from a missing directory, and that is a
# report about the test environment, not about the kernel.
# devmaptest is EXPECTED to move hat_pfnmiss_n by exactly +2.
CB=080FD230
KD=080FD24C
I39=080FD27C
PTD=080FD2E8
ANCH=080FCB68

mkdir -p /pgc

{
	echo "=== ANCHORS ==="
	echo "hat_cm_ram (expect 00000020):"; /kpeek $ANCH 1
	echo "i39_magic (expect 49333921):";  /kpeek $I39 1
	echo "ptd_magic (expect 50544421):";  /kpeek $PTD 1
	echo
	echo "=== counters BEFORE ==="
	/kpeek $CB 4
	/kpeek $KD 3
	/kpeek $PTD 11
	echo
	for t in proctest fputest mlocktest msynctst mincoretst bigargv ptracepoke
	do
		echo "======== $t ========"
		/tmp/$t 2>&1
	done
	echo "======== bmaptest /pgc ========"
	/tmp/bmaptest /pgc 2>&1
	echo "======== devmaptest (expect hat_pfnmiss_n +2) ========"
	/tmp/devmaptest 2>&1
	echo "======== exectest 20 ========"
	/tmp/exectest 20 2>&1
	echo
	echo "=== counters AFTER ==="
	/kpeek $CB 4
	/kpeek $KD 3
	/kpeek $PTD 11
	echo BATTERYRUN2-DONE
} > /tmp/battery2.log 2>&1
