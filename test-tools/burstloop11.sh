# burstloop11.sh -- burst suite driver, AMIX-grep-safe (2026-08-13).
#
# WHY A NEW ONE.  burstloop.sh's anomaly line is INERT on AMIX: it uses `\|` alternation,
# which this grep does not support, so it has been silently matching nothing since it was
# written.  docs/REALHW-260807-11-ACCEPTANCE.md recorded that and re-checked by hand; this
# driver does it one pattern per call so the run reports for itself.
#
# Prerequisites on the machine:
#   /payload.bin        4 MiB source file
#   /tmp/hat_dup_cow    fork/COW stressor (NAS: amix/hwtest-260801/)
#   /tmp/burst4.sh      the burst body
#   free disk for 6 x /press*.bin
#
#   (nohup sh /tmp/burstloop11.sh 3 > /tmp/burstloop11.log 2>&1 &)
R=${1:-3}
r=1
while [ $r -le $R ]; do
	echo "======== ROUND $r ========"
	sh /tmp/burst4.sh
	r=`expr $r + 1`
done
echo "======== BURSTLOOP-SUMMARY ========"
echo "rounds=$R"
echo "good_sums (expect 24 per round):"
grep -c '1570 8192' /tmp/burstloop11.log
echo "---- anomalies, ONE PATTERN PER CALL (AMIX grep has no -E, no \\| ) ----"
for pat in 'bad address' 'Bad address' 'read error' 'cannot open' 'can.t open' 'No space' 'BUS ERROR' 'PANIC' 'Segmentation' 'Killed'
do
	n=`grep -c "$pat" /tmp/burstloop11.log`
	echo "  $pat : $n"
done
# The sum lines are `1570 8192 /pressN.bin`, so match on the FILENAME, not on the
# size alone.  The previous form -- grep 8192, minus 1570 8192 -- read the very log it
# was writing into, and its own header contains 8192 without 1570 8192, so the check
# matched itself and always emitted one false line (2026-08-25).  A check that reports
# on its own output cannot report zero, which is the reading everybody wants from it.
echo "---- wrong sums (a burst line whose checksum is not the expected one) ----"
grep '8192 /press' /tmp/burstloop11.log | grep -v '1570 8192 /press'
echo BURSTLOOP11-DONE
