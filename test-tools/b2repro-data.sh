#!/bin/sh
# b2repro-data.sh - F3 data-only control reproducer
# (amix-kernel-analysis vm-map/B2-CORRUPTION-FIX-SPEC.md Part F3).
#
# The DISCRIMINATOR against F2 (b2repro-meta.sh): here inode size and the block
# map stay CONSTANT -- a fixed set of files is preallocated once, then their
# ALREADY-ALLOCATED blocks are overwritten in place, over and over.  No create,
# no unlink, no size change -> zero inode/indirect/cylinder-group churn.
#
#   F2 fails, F3 clean  -> metadata allocation/update path implicated
#   F3 fails            -> page-data snapshot / TO_DEVICE coherency implicated
#   both fail w/ EFAULT  -> read-path / ISSUE-22
#   both persist reboot -> lower disk/controller/common path
#
# Every pass is verified byte-exact with b2verify (real errno + st_size).
# Stops on first non-V0.
#
# Usage:  sh b2repro-data.sh [files] [passes] [label]
#   needs /tmp/b2verify + /tmp/ref.bin (see b2repro-meta.sh header)
set -- ${1:-6} ${2:-400} ${3:-data}
FILES=$1; PASSES=$2; LABEL=$3
REF=/tmp/ref.bin
V=/tmp/b2verify
FLAG=/tmp/b2repro.stop

[ -f "$REF" ] || { echo "MISSING $REF (dd if=/payload.bin of=$REF bs=1024 count=96)"; exit 20; }
[ -x "$V" ]   || { echo "MISSING $V"; exit 20; }
rm -f $FLAG

# preallocate the fixed set ONCE (blocks allocated here, never freed/realloced)
dir=/tmp/dataonly
rm -rf $dir; mkdir -p $dir
i=1
while [ $i -le $FILES ]; do
	cp $REF $dir/d$i
	i=`expr $i + 1`
done
sync
echo "B2REPRO-DATA start files=$FILES passes=$PASSES label=$LABEL (blocks preallocated)"

p=1
while [ $p -le $PASSES ]; do
	[ -f $FLAG ] && break
	# overwrite in place: cp truncates to 0 then rewrites the SAME logical
	# blocks -- on UFS this reuses the file's existing block map (size const)
	i=1
	while [ $i -le $FILES ]; do
		cp $REF $dir/d$i &
		i=`expr $i + 1`
	done
	wait
	sync
	i=1
	while [ $i -le $FILES ]; do
		$V $REF $dir/d$i "$LABEL-p$p-d$i"
		rc=$?
		if [ $rc -ne 0 ]; then
			echo "STOP p$p d$i class=$rc" > $FLAG
			break
		fi
		i=`expr $i + 1`
	done
	p=`expr $p + 1`
done

if [ -f $FLAG ]; then
	echo "B2REPRO-DATA FAILURE:"; cat $FLAG
else
	echo "B2REPRO-DATA CLEAN (no non-V0 in $FILES x $PASSES)"
fi
echo B2REPRO-DATA-DONE
