# i10r.sh -- ISSUE-10: audit what the kernel DID with the one user write fault
# whose pending store vanishes, so the branch that swallows it can be named.
#
# WHAT IS BEING AUDITED.  An emulator-side watch traced the setup.sh wall end to
# end and found the poison 0x4AFC0000 is not fabricated by anything: it is the
# kernel's own ILLEGAL-at-null sentinel, read legally through user VA 0 after
# /bin/sh's free-list walk followed a NULL link.  The NULL is there because sh's
# end-of-arena marker store (_end+1 = 0x800114B5, written to the newly grown
# bloktop at user 0x800152A0) VANISHED.  The 68040 pushed a format-7 access-error
# frame for that store carrying a valid pending write-back --
#     ssw=0401 (fc=1 user data, rw=W, sz=L, atc=1), wb3v=1 wb3s=81 wb3d=800114b5
# -- and the kernel returned as-if-resolved: nothing mapped, nothing zero-filled,
# no store replayed, no signal posted.  Five ticks later the WALK's byte read
# faults on the same page and THAT fault maps and zero-fills it, so the walk reads
# zeros where its marker should be, follows the NULL, and walls.
#
# The emulator can see that the kernel did nothing.  It cannot see WHERE.  PART SIX
# of src/i10rev040.s (i10r) latches that one fault from inside the fault path --
# both ends of usrxmemflt -- and records the frame the wrapper was handed, the
# verdict it returned, the k_siginfo_t it returned it in, what ptest said before
# and after, whether anything got mapped, and how many write-back slots the replay
# actually re-issued.
#
# NOTHING IS WRITE-PROTECTED BY THIS RUN.  i10r hooks the wrapper directly, so it
# needs neither i10g_on nor i10w_on and both stay 0: the fault it audits is the
# ordinary fault the uninstrumented wall takes.  The only poke is the address to
# watch.
#
# HOW TO READ THE CAPTURE (magic first, then i10r_latched -- with latched = 0 every
# field below it is ship-time state and says nothing about any fault):
#   i10r_pre_w3s   bit 7 set (0081) = the CPU handed the kernel a pending store;
#                  i10r_pre_w3a/w3d are its target and data (expect 800152a0 /
#                  800114b5).  If these are 0 while the emulator's WB7 line shows
#                  them set, the kernel's READ of the frame is the defect
#   i10r_wb_d      write-back slots actually re-issued during this fault.  0 with
#                  i10r_dec3 = 1 is the finding: a pending store, and none landed
#   i10r_ret       usrxmemflt's verdict: 0 = it reported the fault resolved
#   i10r_sisig     infop->si_signo: 0 = no signal will be posted to the process
#   i10r_pte_post  the fault address's leaf PTE afterwards: 0 = nothing was mapped
#   i10r_tv_post   the longword at the fault address afterwards: equal to
#                  i10r_pre_w3d only if the store was landed
#   i10r_branch    DERIVED from i10r_pt_pre and i10r_pre_ssw -- the stock
#                  classifier's own branch: 1 = 030 B SIGSEGV, 2 = 030 S,
#                  3 = F_INVAL demand, 4 = F_PROT COW, 5 = hardbus (resident,
#                  write-protected, read), 6 = hardbus with NO fault bits at all
#   i10r_pt_pre / i10r_pt_post   ptest's 030-form PSR before and after: 0x400 = not
#                  present, 0x800 = write-protected, 0 = resident and writable.
#                  0x400 both times = the resolution mapped nothing
#
# WHERE THIS RUNS.  The install miniroot -- a UFS root with /bin, /etc, /dev and
# nothing else: no /usr, no /tmp, no compiler, no network.  kpeek/kpoke are cross-
# built host-side and parked in the free tail of the source disk's raw slice, so
# the first thing here is a pair of dd's, not a copy.  Bourne sh for the guest
# (AGENTS.md "Code that runs on AMIX itself"): backticks, no $(...), no [[ ]], no
# `grep -q`.  It off-loads its log by dd-ing it back into the source disk's raw
# slice, this rig having no network.
#
# THE LOAD BASE IS NOT KNOWN IN ADVANCE, so read i10r_magic at BOTH candidate bases:
# the A3000 motherboard base 0x07000000 (this rig: a3000mem, mbresmem_size=0) and
# the accelerator base 0x08000000.  The one that answers i10r_magic = 49315221
# ("I1R!") is the live block; the other returns whatever else lives there.  The
# addresses below MOVE every build (the block sits in .data, which shifts with any
# .text change), so a rebuild must refresh them from
# `tools/status-facts.sh <kernel> 0x07000000`; the values are the resolution-audit
# kernel 68040-260819-41 / its byte-identical control rebuild -42.
#
# Usage on the guest:  sh /i10r.sh   (writes /i10r.log, publishes it at
#                                     slice-5 1 KiB block 25728)

LOG=/i10r.log

# --- base 0x07000000 (this rig) ---
IR=0710D2EC		# i10r_magic
IRWVA=0710D2F0		# i10r_watchva
IRMASK=0710D2F4		# i10r_famask
IRLAT=0710D31C		# i10r_latched
# --- base 0x08000000 (accelerator; +0x01000000) ---
IR8=0810D2EC
IRWVA8=0810D2F0
IRMASK8=0810D2F4

# The address whose write fault vanished, measured emulator-side on this exact
# script and disk: the bloktop of the fatal arena grow.
WVA=800152A0

exec > $LOG 2>&1

echo I10R-START

echo "--- reclaim what earlier runs left on this miniroot ---"
rm -f /t.sh /shmband /i10.log /i10bench.sh /i10p.sh /i10p.log /i10c.sh /i10c.log /i10w.sh /i10w.log /i10g.sh /i10g.log /i10t.sh /i10t.log /x.sh /l.txt /m.txt /w.txt /irl.txt
sync

echo "--- stage kpeek + kpoke out of the raw slice tail ---"
dd if=/dev/dsk/c0d0s5 of=/kpeek bs=1024 skip=25600 count=32
dd if=/dev/dsk/c0d0s5 of=/kpoke bs=1024 skip=25632 count=32
chmod 755 /kpeek /kpoke
sync

echo "--- BASE PICK: i10r_magic must read 49315221 (I1R!) at the live base ---"
echo "base 0x07:"
/kpeek $IR 1
echo "base 0x08:"
/kpeek $IR8 1
sync

echo "--- BEFORE: the i10r block (magic first; watchva/pend/latched must be 0) ---"
/kpeek $IR 79
sync

echo "--- ARM the audit: i10r_watchva 0 -> $WVA (both bases) ---"
# The ONLY poke this run makes.  i10g_on and i10w_on stay 0, so no page is write-
# protected and the audited fault is the ordinary one the uninstrumented wall takes.
/kpoke $IRWVA 0 $WVA
/kpoke $IRWVA8 0 $WVA
echo "KPOKE i10r_watchva rc=$?"
/kpeek $IR 79
sync

# MOUNT READ-ONLY (mflag 1): a read-write mount of this s5 payload slice fails with
# ENOSPC on any image whose slice 4 was previously mounted rw and never unmounted --
# which is every image a crashed bench run leaves behind.  The probe only ever reads.
echo "--- mount the install source (slice 4, s5) at /cdrom, READ-ONLY ---"
/etc/mount /dev/dsk/c0d0s4 /cdrom 1 s5
echo "MOUNT rc=$?"
sync

echo "--- THE WALL: sh -n parses the whole script and executes none of it ---"
sh -n /cdrom/install/bin/setup.sh
echo "WALL rc=$?"
sync

echo "--- AFTER (pass 1, exact address): the i10r block, 79 longs ---"
/kpeek $IR 79
sync

# PASS 2, only if pass 1 never latched.  The watched address is one process's
# bloktop, and a run whose arena grows differently would never present it.  Widening
# i10r_famask to a page makes the audit take the first write-class fault ANYWHERE in
# page 0x80015 instead, which is the same event with a coarser aim.  Doing this in
# the same boot is deliberate: a second boot costs more than a second parse.
/kpeek $IRLAT 1 > /irl.txt
if grep '= 00000001' /irl.txt > /dev/null 2>&1; then
	echo "--- pass 1 LATCHED on the exact address: no second pass needed ---"
else
	echo "--- pass 1 did NOT latch: widen i10r_famask to the PAGE and re-run ---"
	/kpoke $IRMASK ffffffff fffff000
	/kpoke $IRMASK8 ffffffff fffff000
	echo "KPOKE i10r_famask rc=$?"
	/kpoke $IRWVA $WVA 80015000
	/kpoke $IRWVA8 $WVA 80015000
	echo "KPOKE i10r_watchva rc=$?"
	/kpeek $IR 79
	sync
	echo "--- THE WALL again, page-aimed ---"
	sh -n /cdrom/install/bin/setup.sh
	echo "WALL2 rc=$?"
	sync
	echo "--- AFTER (pass 2, page-aimed): the i10r block, 79 longs ---"
	/kpeek $IR 79
fi
sync

echo "--- context: the write-back denial + replay counters (wbf_magic = WBF!, 32 longs"
echo "    reaching past the wbf block into wb_dfc_on .. wb_replay_n/wb_replay_odd) ---"
# wb_replay_n is the absolute counter i10r_wb_d is a delta of; wbf_fail_n and
# wbf_swallow_n say whether any write-back was DENIED rather than never attempted.
/kpeek 0710C65C 32
echo I10R-END
sync
sync

# publish the log into the raw slice for the host to read byte-exactly.  Block 25728
# is free; 25856 and the 59 blocks after it hold a /bin/sh copy and must not be
# written over.
dd if=$LOG of=/dev/dsk/c0d0s5 bs=1024 seek=25728
sync
sync
echo I10R-PUBLISHED > /dev/console
