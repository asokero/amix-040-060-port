# issue40e.sh -- ISSUE-40 ACCEPTANCE on real hardware, both halves in (2026-08-02).
#
# Part 1 (legacy SDT, src/legacysdt040.s) is hardware-proven to fire and to
# return zero pages.  Part 2 (src/ptdatfree040.s, contract
# vm-map/ISSUE40-PTDAT-TEARDOWN-CONTRACT.md) retires the ptdat metadata that pinned
# the backing page.  On the emulator, 419 teardowns per phase, one boot, one
# variable:
#
#     ptd_on = 1   availrmem   -7      ptd_pgfreed_n +209
#     ptd_on = 0   availrmem -211      ptd_pgfreed_n    0
#     ptd_on = 1   availrmem    0      ptd_pgfreed_n +206
#
# THE PRE-REGISTERED CRITERION, written 2026-08-01 before either half existed:
#
#   1. leaktest 300 1 leaves availrmem/availsmem/pages_pp_kernel flat within
#      background noise                                  (was -300/-300/+300)
#   2. availrmem + pages_pp_kernel still conserved
#   3. leaktest 300 0 (fork) behaves as before
#   5. no ~21 pages/min drift under load        <- needs the long run, not this
#
# Criterion 4 (battery 9/9 + burst 96/96 + hat_pfnmiss_n exactly +2) is the
# separate full-battery session; i40regr2.sh covers its safety subset.
#
# PREDICTIONS for this run, so it can fail:
#   300 fork+exec, ptd_on=1   availrmem ~ 0 (was -315 on this machine)
#   300 fork+exec, ptd_on=0   availrmem ~ -300, i.e. the old kernel exactly
#   ptd_pgfreed_n rises with the exec count while ptd_on = 1
#   ptd_keep0_n = ptd_keepn_n = ptd_meta_n = ptd_badlink_n = 0
#   i40_pgfreed_n STAYS 0 -- it samples the wrong window on purpose; see the
#     counter-boundary correction in the ptdat contract.  Its staying zero is
#     NOT a failure, and requiring it to move would be requiring the wrong
#     instrument to move.
#
# Detached: nohup sh /tmp/issue40e.sh > /tmp/i40e.log 2>&1 &
#
# Addresses are for build/unix-040 = 68040-260802-01, textsize 0xe4868,
# 0x08000000 + textsize + nm(.data).  Valid for THIS image only; the anchors
# below are what proves it and the script refuses to run without them.

PPK=080EFD90		# pages_pp_kernel -- plain .data
PTD=080FD2E8		# ptd_magic .. ptd_tblfreed_n, 11 contiguous longs
PTDON=080FD2EC		# ptd_on (the A/B gate)
I40=080FD2B4		# i40_magic .. i40_last_bits, 13 contiguous longs
BADA=080FD250		# hat_badaslot_n
PFNM=080FD24C		# hat_pfnmiss_n
CBRJ=080FD234		# cb_rel_reject

v() { /kpeek $1 1 | sed 's/.*= //;s/ .*//'; }
d() { echo "16i `echo $1 | tr abcdef ABCDEF` p" | dc 2>/dev/null; }

echo "=== anchors: nothing below means anything unless these read back ==="
echo "  ptd_magic  = `v 080FD2E8`   expect 50544421"
echo "  i40_magic  = `v 080FD2B4`   expect 49343021"
echo "  i39_magic  = `v 080FD27C`   expect 49333921"
echo "  hat_cm_ram = `v 080FCB68`   expect 00000020  (copyback)"
if [ "`v 080FD2E8`" != "50544421" ]; then
	echo "ABORT: ptd_magic mismatch -- wrong image or stale addresses. Nothing was run."
	exit 1
fi
if [ "`v 080FD27C`" != "49333921" ]; then
	echo "ABORT: i39_magic mismatch -- the availrmem pointer table is not where we think."
	exit 1
fi

AR=`v 080FD284`		# i39_availrmem_p CONTENT (availrmem is COMMON)
AS=`v 080FD288`		# i39_availsmem_p CONTENT
echo "  availrmem @$AR   availsmem @$AS   pages_pp_kernel @$PPK (direct)"
echo

rd() {
	a=`v $AR`; s=`v $AS`; p=`v $PPK`
	echo "  $1  availrmem=$a (`d $a`)  availsmem=$s (`d $s`)  ppk=$p (`d $p`)"
}
ptd() {
	echo "  $1  ptd block (magic on calls retired PGFREED keep0 keepN meta badlink wake tblfreed):"
	/kpeek $PTD 11 | sed 's/^/      /'
	echo "      badaslot=`v $BADA`  pfnmiss=`v $PFNM`  cb_rel_reject=`v $CBRJ`"
}

date
rd "settle    "
sleep 30
rd "baseline  "
ptd "baseline  "

echo "--- phase 1: 300 fork (control: must stay flat, as it always has) ---"
/tmp/leaktest 300 0 > /dev/null
sleep 30
rd "fork  x300"

echo "--- phase 2: 300 fork+exec, FIX ON  (the criterion) ---"
/tmp/leaktest 300 1 > /dev/null
sleep 30
rd "exec  x300"
ptd "exec  x300"

echo "--- phase 3: 300 fork+exec, FIX ON ---"
/tmp/leaktest 300 1 > /dev/null
sleep 30
rd "exec  x300"
ptd "exec  x300"

echo "--- phase 4: gate part 2 OFF (ptd_on 1 -> 0) = the pre-fix kernel ---"
/tmp/kpoke $PTDON 1 0

echo "--- phase 5: 300 fork+exec, FIX OFF (must lose ~300 again) ---"
/tmp/leaktest 300 1 > /dev/null
sleep 30
rd "exec  x300"
ptd "exec  x300"

echo "--- phase 6: gate part 2 back ON (0 -> 1) ---"
/tmp/kpoke $PTDON 0 1

echo "--- phase 7: 300 fork+exec, FIX ON again (must be flat again) ---"
/tmp/leaktest 300 1 > /dev/null
sleep 30
rd "exec  x300"
ptd "exec  x300"

echo "--- phase 8: 300 fork (control again) ---"
/tmp/leaktest 300 0 > /dev/null
sleep 30
rd "fork  x300"

echo "--- phase 9: 3 min idle (nothing should drift) ---"
sleep 180
rd "idle 3min "
ptd "idle 3min "
date
echo ISSUE40E-DONE
