#!/bin/sh
# b2repro-copy.sh - F1 instrumented copy-pressure reproducer
# (amix-kernel-analysis vm-map/B2-CORRUPTION-FIX-SPEC.md Part F1).
#
# This is the DIRECT instrumented version of the exact workload that already
# reproduced the anomaly under burst4 (~1-2 hits per 8-16 bursts): 6x concurrent
# 4 MiB NFS-payload copies + a hat_dup_cow 64 churn per burst.  The ONLY change
# vs the original pressure.sh/burst4.sh is that verification uses b2verify
# instead of `sum`, so the FIRST failure is CLASSIFIED (real errno + st_size +
# close/reopen/retry) instead of being reported as sum's ambiguous partial
# read-progress count.
#
# It resolves the open question directly:
#   V1_*  -> transient read fault, file intact on reopen (== ISSUE-22, NOT B2)
#   V3/V4/V5/V6 -> persistent: a real B2 disk-truth defect -> capture + escalate
#
# Stops ALL workers on the first non-V0 so the exact failing file, offset, errno,
# and st_size are preserved before further disk activity.
#
# Usage:  sh b2repro-copy.sh [bursts] [label]
#   needs /tmp/b2verify (compiled) + /payload.bin (the 4 MiB reference) +
#         /tmp/hat_dup_cow (optional; the churn runs only if present)
set -- ${1:-16} ${2:-copy}
BURSTS=$1; LABEL=$2
REF=/payload.bin
V=/tmp/b2verify
FLAG=/tmp/b2repro.stop

[ -f "$REF" ] || { echo "MISSING $REF"; exit 20; }
[ -x "$V" ]   || { echo "MISSING $V (cc -o b2verify b2verify.c)"; exit 20; }
rm -f $FLAG

echo "B2REPRO-COPY start bursts=$BURSTS label=$LABEL ref=$REF"
b=1
while [ $b -le $BURSTS ]; do
	[ -f $FLAG ] && break
	echo "COPY-BURST-$b"
	# 6 concurrent 4 MiB copies = the pressure that reproduced under burst4
	i=1
	while [ $i -le 6 ]; do
		cp $REF /cp$i.bin &
		i=`expr $i + 1`
	done
	# concurrent fork/COW churn (part of the original memory pressure)
	[ -x /tmp/hat_dup_cow ] && /tmp/hat_dup_cow 64 >/dev/null 2>&1 &
	wait
	sync
	# CLASSIFY each copy with b2verify (real errno + st_size + reopen/retry)
	i=1
	while [ $i -le 6 ]; do
		$V $REF /cp$i.bin "$LABEL-b$b-cp$i"
		rc=$?
		if [ $rc -ne 0 ]; then
			echo "STOP burst=$b cp=$i class=$rc" > $FLAG
			break
		fi
		i=`expr $i + 1`
	done
	rm -f /cp1.bin /cp2.bin /cp3.bin /cp4.bin /cp5.bin /cp6.bin
	sync
	b=`expr $b + 1`
done

if [ -f $FLAG ]; then
	echo "B2REPRO-COPY FAILURE (first non-V0):"; cat $FLAG
	echo "  (see the B2V ... CLASS=... line above for errno/st_size/retry)"
else
	echo "B2REPRO-COPY CLEAN (0 non-V0 in $BURSTS bursts)"
fi
echo B2REPRO-COPY-DONE
