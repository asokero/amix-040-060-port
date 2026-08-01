# i40regr2.sh -- ISSUE-40 SAFETY check, BOTH halves in (2026-08-02).
#
# Same shape as i40regr.sh, re-addressed for 68040-260802-01 (textsize 0xe4868)
# and extended with the ptdat block.  hat_ptfree now runs an ownership gate and
# four list removals on EVERY table-page free, so this is the run that decides
# whether part 2 is safe at all -- read it before any leak number.
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
#   ptd_keep0_n / ptd_keepn_n / ptd_meta_n / ptd_badlink_n
#                 MUST all be 0.  badlink nonzero would mean the ptdat_t layout
#                 is wrong for this image -- and the two-pass validation is what
#                 kept both lists intact when it fired
#   ptd_retired_n should equal ptd_calls (every table page cleanly retired)
#   i40_bad_n     MUST be 0: nonzero means the shape guard rejected a descriptor,
#                 i.e. sections 2/3 alias something real on THIS memory map
#   i40_err_n     MUST be 0: nonzero means hat_growsdt is not the body we read
#   cb_rel_reject MUST stay 0 (Codex's runtime acceptance list)
#   hat_pfnmiss_n MUST move +2 per devmaptest and by nothing else

v() { /kpeek $1 1 | sed 's/.*= //;s/ .*//'; }

echo "=== anchors ==="
echo "  ptd_magic  = `v 080FD2E8`   expect 50544421"
echo "  i40_magic  = `v 080FD2B4`   expect 49343021"
echo "  hat_cm_ram = `v 080FCB68`   expect 00000020"
if [ "`v 080FD2E8`" != "50544421" ]; then
	echo "ABORT: ptd_magic mismatch -- wrong image or stale addresses."
	exit 1
fi
if [ "`v 080FD2B4`" != "49343021" ]; then
	echo "ABORT: i40_magic mismatch -- wrong image or stale addresses."
	exit 1
fi

echo
echo "=== before ==="
/kpeek 080FD2B4 13 | sed 's/^/  /'
echo "  ptd block (magic on calls retired PGFREED keep0 keepN meta badlink wake tblfreed):"
/kpeek 080FD2E8 11 | sed 's/^/  /'
echo "  badaslot=`v 080FD250`  pfnmiss=`v 080FD24C`  cb_rel_reject=`v 080FD234`"

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
echo "  pfnmiss before = `v 080FD24C`"
/tmp/devmaptest
echo "  pfnmiss after  = `v 080FD24C`"

echo
echo "=== after ==="
/kpeek 080FD2B4 13 | sed 's/^/  /'
echo "  ptd block (magic on calls retired PGFREED keep0 keepN meta badlink wake tblfreed):"
/kpeek 080FD2E8 11 | sed 's/^/  /'
echo "  badaslot=`v 080FD250`  pfnmiss=`v 080FD24C`  cb_rel_reject=`v 080FD234`"
date
echo I40REGR2-DONE
