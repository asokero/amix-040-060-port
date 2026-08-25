# i10bench.sh -- ISSUE-10 reverse-map counters across the install-miniroot
# setup.sh parse wall (2026-08-19).  Bourne sh for the guest: backticks, no
# $(...), no [[ ]], no `grep -q` (AGENTS.md "Code that runs on AMIX itself").
#
# WHERE THIS RUNS.  The install miniroot -- a UFS root with /bin, /etc, /dev and
# nothing else.  No /usr, no /tmp, no compiler, no network.  The two binaries it
# needs are cross-built host-side and parked in the free tail of the source
# disk's raw slice, which is why the first thing here is a pair of dd's rather
# than a copy: dd and chmod are in the miniroot, a package manager is not.
#
# WHAT IT MEASURES.  The `i10` counter block around the installer's setup.sh --
# the run that dies with repeated `User BUS ERROR at 4AFC0003` at PID 19.  If a
# bounded reverse-map unlink giving up is what produces that fault, then
# i10_rpfail_n / i10_hlfail_n / i10_hffail_n move in step with it.  If they do
# not move, they do not move -- and i10_deep_n then says whether that is because
# no chain ever came close to the 256-node bound, which is the difference
# between "did not happen" and "could not have happened".
#
# ORDER IS DELIBERATE.  The two `sh -n` passes come FIRST and are the sharper
# experiment: -n parses the whole file and executes none of it.  If the fault
# fires under -n, the wall is in parsing alone; if it does not, execution is
# required and "parse-time" is the wrong name for it.  They also cannot block on
# input, so they are the samples most likely to survive a run that later hangs.
# Only then do the three full runs, whose exit codes and console transcript are
# the reproduction proper.
#
# THE LOAD BASE IS NOT KNOWN IN ADVANCE, so this reads the block at BOTH
# candidate bases every time and lets the reader pick: the A3000 motherboard
# base 0x07000000 (this rig: a3000mem, mbresmem_size=0) and the accelerator base
# 0x08000000.  The one that answers i10_magic = 49313021 is the live block; the
# other returns whatever else lives there.  Reading the magic first is the rule
# these counter blocks exist under -- a stale address does not fail, it lies.
#
# Kernel cmn_err output does NOT arrive here.  NOTICE lines go to the console,
# so the fault transcript is the screenshots and this file is the numbers; both
# halves are needed and neither substitutes for the other.
#
# Usage on the guest:  sh /i10bench.sh          (writes /i10.log)

LOG=/i10.log
A8=0810B8F8
A7=0710B8F8

exec > $LOG 2>&1

echo I10BENCH-START

echo "--- stage the probes out of the raw slice tail ---"
dd if=/dev/dsk/c0d0s5 of=/kpeek bs=1024 skip=25600 count=32
dd if=/dev/dsk/c0d0s5 of=/shmband bs=1024 skip=25632 count=32
chmod 755 /kpeek
chmod 755 /shmband
sync

# sample <label>   -- both candidate bases, magic first
sample() {
	echo "I10SAMPLE $1 base08"
	/kpeek $A8 6
	echo "I10SAMPLE $1 base07"
	/kpeek $A7 6
	sync
}

sample baseline

echo "--- mount the install source (slice 4, s5) at /cdrom ---"
/etc/mount /dev/dsk/c0d0s4 /cdrom 0 s5
sync
sample after-mount

echo "--- PARSE-ONLY 1: sh -n setup.sh (parses everything, runs nothing) ---"
sh -n /cdrom/install/bin/setup.sh
echo "PARSE-ONLY setup.sh exit=$?"
sync
sample after-parse-setup

echo "--- PARSE-ONLY 2: sh -n install.sh (bigger file, same shell) ---"
sh -n /cdrom/install/bin/install.sh
echo "PARSE-ONLY install.sh exit=$?"
sync
sample after-parse-install

echo "--- REPRO 1: sh setup.sh ---"
sh /cdrom/install/bin/setup.sh < /dev/null
echo "REPRO 1 exit=$?"
sync
sample after-repro-1

echo "--- REPRO 2 ---"
sh /cdrom/install/bin/setup.sh < /dev/null
echo "REPRO 2 exit=$?"
sync
sample after-repro-2

echo "--- REPRO 3 ---"
sh /cdrom/install/bin/setup.sh < /dev/null
echo "REPRO 3 exit=$?"
sync
sample after-repro-3

echo I10BENCH-END
sync
sync
