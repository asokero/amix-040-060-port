# i10t.sh -- ISSUE-10 confound #1: observe the store that lands 0x4AFC0000 at
# 0x80014AA0 on the ORDINARY (non-faulting) path the uninstrumented wall takes,
# so the genesis verdict is separated from the write-protect method that produced
# it.
#
# THE CONFOUND.  i10g (PART FOUR) caught the store by WRITE-PROTECTING the poison
# page, which forces the store to fault and routes its completion through the
# 68040 deferred-write-back replay in src/wb040.s.  That capture cannot tell
#   (A) the ordinary, non-faulting store already fabricates 0x4AFC0000 -- the 040
#       write-back core (the emulator's, possibly silicon's); from
#   (B) the value appears only because the write-protect forced the deferred/replay
#       path -- an artifact of the method, not of the store the real wall runs.
# i10t (PART FIVE, src/i10rev040.s) cuts it: on the resolved tail of the ORDINARY
# demand-zero that first brings in the poison page, it sets the 68040 trace bit on
# the wall's own sh (a USER store, so T1 is live for it), installs its own vector-9
# handler, and single-steps sh ON THE ORDINARY PATH -- no page protected, no fault,
# no replay.  It latches the first transition of 0x80014AA0 into the poison and
# records, decisively:
#   i10t_wbdelta  -- wb_replay_n across that one step.  0 proves the store did NOT
#                    fault and did NOT go through wb040_replay: the ordinary path.
#   i10t_srcr     -- which address register held the poison as a NON-destination
#                    source.  -1 with after==poison => the ordinary store FABRICATED
#                    it (world A).  >=0 => it faithfully COPIED it (world B: the
#                    genesis is one hop upstream and i10g's attribution was the
#                    method artifact).
#   i10t_before/after, i10t_culpc, i10t_r0..r14, i10t_pv0..6 -- the raw evidence.
#
# WHERE THIS RUNS.  The install miniroot -- a UFS root with /bin, /etc, /dev and
# nothing else: no /usr, no /tmp, no compiler, no network.  kpeek/kpoke are cross-
# built host-side and parked in the free tail of the source disk's raw slice, so
# the first thing here is a pair of dd's, not a copy.  Bourne sh for the guest
# (AGENTS.md "Code that runs on AMIX itself"): backticks, no $(...), no [[ ]], no
# `grep -q`.  It off-loads its log by dd-ing it back into the source disk's raw
# slice, this rig having no network.
#
# TWO KNOB CHANGES vs i10g, both by kpoke here:
#   * i10g_plo 0x80014000 -> 0   so PART P never write-protects any page -- the
#     stores i10t observes must be ordinary, non-faulting stores.
#   * i10t_want 0 -> 1           enables the trace arm (ships 0 = fully dormant).
# i10g_on is armed too, because i10t_maybe_arm is reached from i10g_hook.
#
# THE LOAD BASE IS NOT KNOWN IN ADVANCE, so read i10t_magic at BOTH candidate bases:
# the A3000 motherboard base 0x07000000 (this rig: a3000mem, mbresmem_size=0) and
# the accelerator base 0x08000000.  The one that answers i10t_magic = 49315421
# ("I1T!") is the live block; the other returns whatever else lives there.  The
# addresses below MOVE every build (the block sits in .data, which shifts by any
# .text change), so a rebuild must refresh them from
# `tools/status-facts.sh <kernel> 0x07000000`; the values are the 68040-260819-38
# trace-watch kernel (i10rev040.s + PART FIVE).
#
# Usage on the guest:  sh /i10t.sh   (writes /i10t.log, publishes it at
#                                     slice-5 1 KiB block 25696)

LOG=/i10t.log

# --- base 0x07000000 (this rig) ---
IT=0710CD7C		# i10t_magic
ITWANT=0710CD80		# i10t_want
IGON=0710CB70		# i10g_on
IGPLO=0710CD10		# i10g_plo
# --- base 0x08000000 (accelerator; +0x01000000) ---
IT8=0810CD7C
ITWANT8=0810CD80
IGON8=0810CB70
IGPLO8=0810CD10

exec > $LOG 2>&1

echo I10T-START

echo "--- reclaim what earlier runs left on this miniroot ---"
rm -f /t.sh /shmband /i10.log /i10bench.sh /i10p.sh /i10p.log /i10c.sh /i10c.log /i10w.sh /i10w.log /i10g.sh /i10g.log /x.sh /l.txt /m.txt /w.txt
sync

echo "--- stage kpeek + kpoke out of the raw slice tail ---"
dd if=/dev/dsk/c0d0s5 of=/kpeek bs=1024 skip=25600 count=32
dd if=/dev/dsk/c0d0s5 of=/kpoke bs=1024 skip=25632 count=32
chmod 755 /kpeek /kpoke
sync

echo "--- BASE PICK: i10t_magic must read 49315421 (I1T!) at the live base ---"
echo "base 0x07:"
/kpeek $IT 1
echo "base 0x08:"
/kpeek $IT8 1
sync

echo "--- BEFORE: the i10t block (magic first; want/on/armed/latched must be 0) ---"
/kpeek $IT 50
sync

echo "--- DISABLE the write-protect band: i10g_plo 0x80014000 -> 0 (both bases) ---"
# So PART P never protects a page; every store i10t sees is an ORDINARY store.
/kpoke $IGPLO 80014000 0
/kpoke $IGPLO8 80014000 0
echo "KPOKE plo rc=$?"

echo "--- ARM i10g so i10g_hook runs (it calls i10t_maybe_arm): i10g_on 0 -> 1 ---"
/kpoke $IGON 0 1
/kpoke $IGON8 0 1
echo "KPOKE i10g_on rc=$?"

echo "--- ARM the trace-watch: i10t_want 0 -> 1 ---"
/kpoke $ITWANT 0 1
/kpoke $ITWANT8 0 1
echo "KPOKE i10t_want rc=$?"
/kpeek $IT 50
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

echo "--- AFTER: the trace-watch capture (i10t, 50 longs) ---"
/kpeek $IT 50
echo I10T-END
sync
sync

# publish the log into the raw slice for the host to read byte-exactly
dd if=$LOG of=/dev/dsk/c0d0s5 bs=1024 seek=25696
sync
sync
echo I10T-PUBLISHED > /dev/console
