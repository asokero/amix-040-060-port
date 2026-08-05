# mkall060.sh -- compile the battery on the 68060, where the gcc chain is dead.
#
# 2026-08-05: /usr/bin/cc is a sh wrapper around gcc 2.7.2.3, and gcc's own
# cpp/cc1 contain 64-bit muls.l (magic-multiply division) which the 68060 does
# not implement -> vector 61 -> SIGKILL.  Measured, not assumed: the console
# printed "SIGKILL sent to pid 263 (.../cpp ...) because of vector 0xF4,
# pc=0x80006ED6" and 0x80006ED6 disassembles to
#     mulsl #-2078209981,%d0,%d1     (ext 0x1c00, bit10 = 1 = 64-bit product)
#
# /usr/ccs/bin/cc is the ORIGINAL AT&T SVR4 driver (1991).  It predates gcc's
# magic-multiply optimization and emits divsll #100,%d0,%d0 (ext 0x0800,
# bit10 = 0 = 32-bit dividend) which the 060 DOES implement.  Verified by
# disassembling its output, not by exit status.
#
#     (nohup sh /tmp/mkall060.sh > /tmp/mkall060.log 2>&1 &)
CC=/usr/ccs/bin/cc
cd /tmp
for t in memwatch leaktest kpoke exectest devmaptest proctest fputest mlocktest \
         msynctst mincoretst bigargv ptracepoke bmaptest mul64test
do
	echo "==== $CC $t ===="
	$CC -o $t $t.c 2>&1 | tail -5
	ls -l $t 2>&1
done
echo MKALL060-DONE
