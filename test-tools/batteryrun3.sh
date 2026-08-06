# batteryrun3.sh -- the acceptance battery on 68060-260806-02 (F2: the vector-61
# immediate-multiply unit), 2026-08-06.
#
# Re-addressed from batteryrun2.sh.  The x60_* (F1) and isp61_* (F2) counters added
# 84 bytes of .data ahead of the i39 block, so every address below moved by +0x250
# relative to 68040-260802-01 -- which is exactly why the magic words are read first
# and the run aborts if they do not match.  An address that is merely plausible is
# the one failure mode a counter cannot report on itself.
#
# NEW IN THIS RUN, and the reason it is worth doing at all: on the 68060 the whole
# battery is compiled by GCC, whose cpp/cc1 are built out of 64-bit immediate
# multiplies the CPU does not implement.  Every one of those goes through the F2
# handler.  So the battery is simultaneously a regression test of the kernel and the
# broadest end-to-end test of the handler we can run: ~1000 emulated instructions per
# compile, and a single wrong product would show up as a miscompiled test binary.
#
# usage: (nohup sh -c "sh /tmp/batteryrun3.sh > /tmp/batteryrun3.out 2>&1" &)
ANCH=080FCD64
X60=080FD004
ISP=080FD07C
BLK=080FD490		# cb_icode_calls .. ptd_tblfreed_n, 53 longs, one read

mkdir -p /pgc

# Refuse to produce numbers from the wrong image.
if [ "`/kpeek $ISP 1 | sed 's/.*= //;s/ .*//'`" != "49363121" ]; then
	echo "ABORT: isp61_magic mismatch -- wrong image or stale addresses." > /tmp/battery3.log
	exit 1
fi

{
	echo "=== ANCHORS ==="
	echo "hat_cm_ram (expect 00000020, copyback):"; /kpeek $ANCH 1
	echo "isp61_magic (expect 49363121):";          /kpeek $ISP 1
	echo "cputype (expect 0000003c) / pcr_boot:";   /kpeek 080FD074 2
	echo
	echo "=== counters BEFORE ==="
	echo "-- x60 (fmt4,ma,compat,rd,wr,farfail,fa,fslw):"; /kpeek $X60 8
	echo "-- isp61 (magic,entry,ok,mulu,muls,unsup,ifetch,nonuser,badframe,trace,pc,insn):"
	/kpeek $ISP 12
	echo "-- cb/kdbg/i39/i40/ptd block:"; /kpeek $BLK 53
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
	echo "======== mul64test (gcc-built: the F2 payload) ========"
	/tmp/mul64test 2>&1
	echo
	echo "=== counters AFTER ==="
	echo "-- x60:";    /kpeek $X60 8
	echo "-- isp61:";  /kpeek $ISP 12
	echo "-- block:";  /kpeek $BLK 53
	echo BATTERYRUN3-DONE
} > /tmp/battery3.log 2>&1
