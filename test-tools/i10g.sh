# i10g.sh -- ISSUE-10 GENESIS: what FIRST wrote 0x4AFC0000 into a free-list link,
# and whether that genesis is a kernel store, a user store, or inherited frame
# content sh was handed and merely reads.
#
# Companion to i10w.sh, which named the PROPAGATION: the store at user 0x80014AA0
# is sh's own free-block coalescing `move.l (a1),(a0)`, a USER, correctly-addressed
# COPY whose value 0x4AFC0000 was read from another arena slot that already held it.
# So the genesis is one hop upstream, on a different page.  i10g_hook (src/i10rev040.s)
# rides the same resolved fault tail as i10w_hook and answers it two independent ways
# in ONE boot, without protecting any page:
#   PART W  -- the FIRST resolved fault whose write-back DATA is 0x4AFC0000 (a store
#              of the poison that faulted -- the first store into a fresh demand-zero
#              arena page always does), confirmed by re-reading the target.  Its SR
#              bit settles kernel-vs-user for the genesis.
#   PART I  -- on every resolved arena-band fault, the just-resolved frame is scanned
#              for the poison; the FIRST frame holding it is latched with its identity,
#              its fill census and the block around the word -- the frame AS HANDED OUT
#              on a demand-zero page-in.  Dense foreign content = an inherited prior
#              owner's page (a fill gap); isolated in clean zero = a store PART W caught.
#
# Bourne sh for the guest (AGENTS.md "Code that runs on AMIX itself"): backticks,
# no $(...), no [[ ]].  Same 68040 install miniroot as i10w.sh -- a UFS root with
# /bin, /etc, /dev and nothing else -- and it off-loads its log by dd-ing it back
# into the source disk's raw slice, this rig having no network.
#
# THE ARM IS A kpoke.  i10g_on ships 0 so the watch is inert through the whole boot;
# this driver flips it to 1 with kpoke immediately before the wall, so only the wall's
# own sh is watched.  i10g_armproc is read back for the post-hoc check.
#
# IG / IGON are the runtime addresses of i10g_magic and i10g_on for the kernel under
# test, from `tools/status-facts.sh <kernel> 0x07000000`.  They MOVE every build (the
# block sits in .data, which shifts by the size of any .text change), so a rebuild must
# refresh them; the values below are the 68040-260819 genesis-watch kernel.
#
# Usage on the guest:  sh /i10g.sh    (writes /i10g.log, publishes it at
#                                      slice-5 1 KiB block 25696)

LOG=/i10g.log
IG=0710C8B4
IGON=0710C8B8

exec > $LOG 2>&1

echo I10G-START

echo "--- reclaim what earlier runs left on this miniroot ---"
rm -f /t.sh /shmband /i10.log /i10bench.sh /i10p.sh /i10p.log /i10c.sh /i10c.log /i10w.sh /i10w.log /x.sh /l.txt /m.txt /w.txt
sync

echo "--- stage kpeek + kpoke out of the raw slice tail ---"
dd if=/dev/dsk/c0d0s5 of=/kpeek bs=1024 skip=25600 count=32
dd if=/dev/dsk/c0d0s5 of=/kpoke bs=1024 skip=25632 count=32
chmod 755 /kpeek /kpoke
sync

echo "--- BEFORE: the i10g block (magic must be 49314721, on/armed/latched all 0) ---"
/kpeek $IG 132
sync

# MOUNT READ-ONLY (mflag 1): a read-write mount of this s5 payload slice fails with
# ENOSPC on any image whose slice 4 was previously mounted rw and never unmounted --
# which is every image a crashed bench run leaves behind.  The probe only ever reads.
echo "--- mount the install source (slice 4, s5) at /cdrom, READ-ONLY ---"
/etc/mount /dev/dsk/c0d0s4 /cdrom 1 s5
echo "MOUNT rc=$?"
sync

echo "--- ARM: kpoke i10g_on 0 -> 1 (the genesis watch is now live) ---"
# The kernel's default write-protect band is the single page 0x80014000 -- the page the
# wall reads the corrupt link from, where PART I finds the poison's first appearance.  To
# widen it (e.g. to also cover page 0x80013), kpoke i10g_plo lower before arming.
/kpoke $IGON 0 1
echo "KPOKE rc=$?"
/kpeek $IG 132
sync

echo "--- THE WALL: sh -n parses the whole script and executes none of it ---"
sh -n /cdrom/install/bin/setup.sh
echo "WALL rc=$?"
sync

echo "--- AFTER: the genesis capture (i10g, 132 longs) ---"
/kpeek $IG 132
echo I10G-END
sync
sync

# publish the log into the raw slice for the host to read byte-exactly
dd if=$LOG of=/dev/dsk/c0d0s5 bs=1024 seek=25696
sync
sync
echo I10G-PUBLISHED > /dev/console
