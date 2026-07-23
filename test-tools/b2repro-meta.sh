#!/bin/sh
# b2repro-meta.sh - F2 metadata-turbulence reproducer
# (amix-kernel-analysis vm-map/B2-CORRUPTION-FIX-SPEC.md Part F2).
#
# Raises inode / single-indirect / cylinder-group / allocation-map traffic
# WITHOUT 96 simultaneous 4 MiB copies, to expose a copyback metadata-coherency
# defect (if one exists) faster than burst4 and to distinguish metadata from
# data.  Files are 64-128 KiB so they cross the UFS direct-block limit and force
# single-indirect allocation; create/delete order is varied to churn inode and
# cylinder-group reuse.  Every file is verified byte-exact with b2verify, which
# captures the REAL errno + st_size (not sum's read-progress count).
#
# Stops on the FIRST non-V0 (b2verify exit != 0) so the DMA ring + counters can
# be dumped before further disk activity perturbs the evidence.
#
# Usage:  sh b2repro-meta.sh [workers] [iters] [label]
#   needs /tmp/b2verify (compiled) + a reference payload /tmp/ref.bin
#   (make ref.bin ~96 KiB so it crosses the direct-block limit, e.g.
#    dd if=/payload.bin of=/tmp/ref.bin bs=1024 count=96)
set -- ${1:-3} ${2:-200} ${3:-meta}
WORKERS=$1; ITERS=$2; LABEL=$3
REF=/tmp/ref.bin
V=/tmp/b2verify
FLAG=/tmp/b2repro.stop

[ -f "$REF" ] || { echo "MISSING $REF (dd if=/payload.bin of=$REF bs=1024 count=96)"; exit 20; }
[ -x "$V" ]   || { echo "MISSING $V (cc -o b2verify b2verify.c)"; exit 20; }
rm -f $FLAG

worker() {
	wid=$1
	dir=/tmp/mt$wid
	rm -rf $dir; mkdir -p $dir
	n=1
	while [ $n -le $ITERS ]; do
		[ -f $FLAG ] && return
		# create a small set crossing the direct-block limit
		j=1
		while [ $j -le 8 ]; do
			cp $REF $dir/f$j.$n
			j=`expr $j + 1`
		done
		sync
		# verify each (reopen forces fresh reads through the cache/DMA path)
		j=1
		while [ $j -le 8 ]; do
			$V $REF $dir/f$j.$n "$LABEL-w$wid-i$n-f$j"
			rc=$?
			if [ $rc -ne 0 ]; then
				echo "STOP w$wid i$n f$j class=$rc" > $FLAG
				return
			fi
			j=`expr $j + 1`
		done
		# rename + unlink to churn inode / cg reuse (varied order by parity)
		if [ `expr $n % 2` -eq 0 ]; then
			j=1; while [ $j -le 8 ]; do mv $dir/f$j.$n $dir/r$j.$n; j=`expr $j + 1`; done
			j=8; while [ $j -ge 1 ]; do rm -f $dir/r$j.$n; j=`expr $j - 1`; done
		else
			j=8; while [ $j -ge 1 ]; do rm -f $dir/f$j.$n; j=`expr $j - 1`; done
		fi
		[ `expr $n % 10` -eq 0 ] && sync
		n=`expr $n + 1`
	done
}

echo "B2REPRO-META start workers=$WORKERS iters=$ITERS label=$LABEL"
w=1
while [ $w -le $WORKERS ]; do
	worker $w &
	w=`expr $w + 1`
done
wait
if [ -f $FLAG ]; then
	echo "B2REPRO-META FAILURE:"; cat $FLAG
else
	echo "B2REPRO-META CLEAN (no non-V0 in $WORKERS x $ITERS)"
fi
echo B2REPRO-META-DONE
