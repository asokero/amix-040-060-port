# issue40d.sh -- ISSUE-40 part 1 on REAL HARDWARE (2026-08-01).
#
# The legacy-SDT teardown edge (src/legacysdt040.s, commit fbb93aa) is in
# this kernel.  On the emulator it provably fires and provably returns ZERO
# pages: i40_pgfreed_n = 0, i40_held_n = 434, residual p_sdtbits = 0x7FFC0000.
# This run asks whether the real machine agrees, because the two things the
# emulator cannot speak for are exactly the two this edge touches:
#
#   * pages_base/pages_end are elsewhere on the real memory map, and the shape
#     guard that protects hat_sdtfree from a non-allocator base is defined
#     against them;
#   * the real machine walks ~499 stale legacy descriptors per boot, vs a
#     handful in the emulator.
#
# PRE-REGISTERED, so it can fail.  Predictions:
#
#   leaktest 300 1   availrmem ~ -300   UNCHANGED -- half a fix fixes nothing
#   leaktest 300 0   fork behaves as before
#   i40_bad_n   = 0  (the shape guard never had to reject a descriptor)
#   i40_err_n   = 0  (hat_growsdt cannot fail a zero-length call)
#   i40_pgfreed_n = 0 and i40_held_n = i40_sec2_n + i40_sec3_n
#   i40_last_bits   nonzero above the object = the ptdat crumbs that pin the page
#   phase 6 (i40_on = 0)   IDENTICAL availrmem slope, hat_badaslot_n jumps
#
# If i40_bad_n > 0 the guard earned its keep and the contract's "A4..A7 are
# never native" argument is false on this machine -- say so before building the
# ptdat half on top of it.
#
# ALL VALUES ARE HEX (kpeek prints hex).  Deltas are computed on the host from
# this log; a best-effort decimal is printed next to each if dc(1) exists.
#
# Detached, because 4 x 300 fork/exec on a 25 MHz 040 plus settling outruns any
# telnet timeout:
#     nohup sh /tmp/issue40d.sh > /tmp/i40d.log 2>&1 &
#
# Addresses below are for build/unix-040 = 68040-260801-12, textsize 0xe46ec,
# computed as 0x08000000 + textsize + nm(.data).  THEY ARE NOT VALID FOR ANY
# OTHER IMAGE -- the anchors below are what proves that, and the script refuses
# to run if they do not read back.

PPK=080EFC14		# pages_pp_kernel -- plain .data, direct address
I40=080FD138		# i40_magic .. i40_last_bits, 13 contiguous longs
I40ON=080FD13C		# i40_on (the A/B gate)
BADA=080FD0D4		# hat_badaslot_n
PFNM=080FD0D0		# hat_pfnmiss_n
SDTF=080FD0D8		# hat_sdtfail_n
CBRJ=080FD0B8		# cb_rel_reject (Codex acceptance: must stay 0)

v() { /kpeek $1 1 | sed 's/.*= //;s/ .*//'; }
d() { echo "16i `echo $1 | tr abcdef ABCDEF` p" | dc 2>/dev/null; }

echo "=== anchors: nothing below this line means anything unless these read back ==="
echo "  i40_magic  = `v 080FD138`   expect 49343021"
echo "  i39_magic  = `v 080FD100`   expect 49333921"
echo "  hat_cm_ram = `v 080FC9EC`   expect 00000020  (copyback)"
if [ "`v 080FD138`" != "49343021" ]; then
	echo "ABORT: i40_magic mismatch -- wrong image or stale addresses. Nothing was run."
	exit 1
fi
if [ "`v 080FD100`" != "49333921" ]; then
	echo "ABORT: i39_magic mismatch -- the availrmem pointer table is not where we think."
	exit 1
fi

AR=`v 080FD108`		# i39_availrmem_p CONTENT: availrmem is COMMON, no offset
AS=`v 080FD10C`		# i39_availsmem_p CONTENT
echo "  availrmem @$AR   availsmem @$AS   pages_pp_kernel @$PPK (direct)"
echo

rd() {
	a=`v $AR`; s=`v $AS`; p=`v $PPK`
	echo "  $1  availrmem=$a (`d $a`)  availsmem=$s (`d $s`)  ppk=$p (`d $p`)"
}
i40() {
	echo "  $1  i40 block (magic on calls s2 s3 empty bad err pgfreed held lastn lastbase lastbits):"
	/kpeek $I40 13 | sed 's/^/      /'
	echo "      badaslot=`v $BADA`  pfnmiss=`v $PFNM`  sdtfail=`v $SDTF`  cb_rel_reject=`v $CBRJ`"
}

date
rd "settle    "
sleep 30
rd "baseline  "
i40 "baseline  "

echo "--- phase 1: 300 fork ---"
/tmp/leaktest 300 0 > /dev/null
sleep 30
rd "fork  x300"

echo "--- phase 2: 300 fork+exec ---"
/tmp/leaktest 300 1 > /dev/null
sleep 30
rd "exec  x300"
i40 "exec  x300"

echo "--- phase 3: 300 fork+exec ---"
/tmp/leaktest 300 1 > /dev/null
sleep 30
rd "exec  x300"
i40 "exec  x300"

echo "--- phase 4: 300 fork ---"
/tmp/leaktest 300 0 > /dev/null
sleep 30
rd "fork  x300"

# ---------------------------------------------------------------- one-boot A/B
# The decisive control: same boot, same workload, the edge gated OFF.  If the
# availrmem slope is identical and hat_badaslot_n jumps, the edge is doing
# exactly what the emulator said and the remaining leak is not its to fix.
echo "--- phase 5: gate the edge OFF (i40_on 1 -> 0) ---"
/tmp/kpoke $I40ON 1 0
i40 "gate off  "

echo "--- phase 6: 300 fork+exec with the edge OFF ---"
/tmp/leaktest 300 1 > /dev/null
sleep 30
rd "exec  x300"
i40 "exec  x300"

echo "--- phase 7: gate the edge back ON (0 -> 1) ---"
/tmp/kpoke $I40ON 0 1
i40 "gate on   "

date
echo ISSUE40D-DONE
