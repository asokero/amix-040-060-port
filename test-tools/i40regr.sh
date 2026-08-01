# i40regr.sh -- ISSUE-40 part 1 SAFETY check on real hardware (2026-08-01).
#
# The new teardown edge runs on EVERY process exit and every exec, and it calls
# a retained stock body (hat_growsdt -> hat_sdtfree) that this port had never
# invoked before.  That is the risk this script covers; issue40d.sh covers the
# measurement.  Run this FIRST -- if it does not pass there is no point reading
# leak numbers.
#
#     nohup sh /tmp/i40regr.sh > /tmp/i40regr.log 2>&1 &
#
# What each piece proves:
#   exectest 20   the exec path survives 20 rounds (the ISSUE-38 acceptance test)
#   hat_dup_cow   fork/COW still correct (1/32/256)
#   i40_bad_n     MUST be 0: nonzero means the shape guard rejected a descriptor,
#                 i.e. sections 2/3 alias something real on THIS memory map
#   i40_err_n     MUST be 0: nonzero means hat_growsdt is not the body we read
#   cb_rel_reject MUST stay 0 (Codex's runtime acceptance list)
#   hat_pfnmiss_n MUST move +2 per devmaptest and by nothing else

v() { /kpeek $1 1 | sed 's/.*= //;s/ .*//'; }

echo "=== anchors ==="
echo "  i40_magic  = `v 080FD138`   expect 49343021"
echo "  hat_cm_ram = `v 080FC9EC`   expect 00000020"
if [ "`v 080FD138`" != "49343021" ]; then
	echo "ABORT: i40_magic mismatch -- wrong image or stale addresses."
	exit 1
fi

echo
echo "=== before ==="
/kpeek 080FD138 13 | sed 's/^/  /'
echo "  badaslot=`v 080FD0D4`  pfnmiss=`v 080FD0D0`  cb_rel_reject=`v 080FD0B8`"

date
echo
echo "=== exectest 20 ==="
/tmp/exectest 20

echo
echo "=== hat_dup_cow 1 / 32 / 256 ==="
/tmp/hat_dup_cow 1
/tmp/hat_dup_cow 32
/tmp/hat_dup_cow 256

echo
echo "=== devmaptest (hat_pfnmiss_n must move EXACTLY +2 across this) ==="
echo "  pfnmiss before = `v 080FD0D0`"
/tmp/devmaptest
echo "  pfnmiss after  = `v 080FD0D0`"

echo
echo "=== after ==="
/kpeek 080FD138 13 | sed 's/^/  /'
echo "  badaslot=`v 080FD0D4`  pfnmiss=`v 080FD0D0`  cb_rel_reject=`v 080FD0B8`"
date
echo I40REGR-DONE
