# hg.sh -- ISSUE-10 CURE acceptance run (2026-08-21).  Bourne sh for the guest:
# backticks, no $(...), no [[ ]], and NO grep (the install miniroot has none).
#
# WHAT IS BEING PROVED.  src/hgfault040.s completes a user first-touch WRITE one
# page past the process break instead of letting the 68040 discard it.  This run
# takes the four readings that can settle that on the bench, in one boot, and the
# order matters: the counters are read BEFORE anything so their ship-time state is
# on the record, and the hg_on A/B is LAST so the wall's disappearance is shown to
# be this code and not the weather.
#
#   1  the wall            sh -n on the install script.  PASS = no 4AFC0003 flood,
#                          no "no space", rc 0.
#   2  the counters        hg_grow_n > 0, hg_landed_n == hg_grow_n, hg_mapfail_n 0,
#                          hg_unres_n 0, and wbf_dropped_n must STOP advancing --
#                          that last one is the regression sensor, not a nicety:
#                          it counts write-backs the kernel is still throwing away.
#   3  first touch         hgpoc grow (one byte per page, TOP-DOWN, read back) and
#                          hgpoc past 0 -- the direct, sh-free form of the defect:
#                          write a longword past the break and read it back.
#   4  the negatives       hgpoc past 1024 = a wild write 1 MiB up, which must STILL
#                          die by signal and must tick hg_far_n and NOT hg_grow_n;
#                          hgpoc churn = sh's grow/give-back oscillation; and the
#                          hg_on = 0 A/B, which must bring the wall back.
#
# THE ADDRESSES BELOW MOVE ON EVERY BUILD.  Refresh them from
#   sh tools/status-facts.sh build/unix-040 0x07000000
# The load base is not known in advance either, so the magic is read at both
# candidate bases and the one that answers 48474621 ("HGF!") is the live block.
#
# Usage on the guest:  sh /hg.sh    (writes /hg.log, publishes it at slice-5
#                                    1 KiB block 25792)

LOG=/hg.log

# --- base 0x07000000 (this rig) --- 16 longs starting at hg_magic
HG=0710E1B4
HGON=0710E1B8
HGGROW=0710E1D0
HGLAND=0710E1D4
WBFDROP=0710D824
# --- base 0x08000000 (accelerator; +0x01000000) ---
HG8=0810E1B4
HGON8=0810E1B8

exec > $LOG 2>&1

echo HG-START

echo "--- reclaim what earlier runs left on this miniroot ---"
rm -f /t.sh /i10.log /i10a.sh /i10a.log /i10b.sh /i10b.log /i10c.sh /i10c.log /i10d.log /i10r.sh /i10r.log /i10s.sh /i10s.log /i10t.sh /i10t.log /iar.txt /icl.txt /wbf.log /shm-n.log /core
sync

echo "--- stage kpeek + kpoke + hgpoc out of the raw slice tail ---"
dd if=/dev/dsk/c0d0s5 of=/kpeek bs=1024 skip=25600 count=32
dd if=/dev/dsk/c0d0s5 of=/kpoke bs=1024 skip=25632 count=32
dd if=/dev/dsk/c0d0s5 of=/hgpoc bs=1024 skip=25696 count=32
chmod 755 /kpeek /kpoke /hgpoc
sync

echo "--- BASE PICK: hg_magic must read 48474621 (HGF!) at the live base ---"
echo "base 0x07:"
/kpeek $HG 1
echo "base 0x08:"
/kpeek $HG8 1
sync

echo "--- BEFORE: the hg block (magic, hg_on, then the counters) ---"
/kpeek $HG 16
echo "wbf_dropped_n BEFORE:"
/kpeek $WBFDROP 1
sync

echo "--- mount the install source (slice 4, s5) at /cdrom, READ-ONLY ---"
/etc/mount /dev/dsk/c0d0s4 /cdrom 1 s5
echo "MOUNT rc=$?"
sync

echo "=== STEP 1: THE WALL -- sh -n parses the whole script and executes none of it ==="
sh -n /cdrom/install/bin/setup.sh
echo "WALL rc=$?"
sync

echo "=== STEP 2: the counters after the wall ==="
/kpeek $HG 16
echo "wbf_dropped_n AFTER the wall:"
/kpeek $WBFDROP 1
sync

echo "=== STEP 3a: first-touch write, one byte per page, TOP-DOWN, 24 pages ==="
/hgpoc grow 24
echo "GROW rc=$?"
sync
echo "=== STEP 3b: the defect itself -- a longword past the break, read back ==="
/hgpoc past 0
echo "PAST0 rc=$?"
sync
echo "--- counters after the first-touch probes ---"
/kpeek $HG 16
sync

echo "=== STEP 4a: NEGATIVE -- a wild write 1 MiB above the break must still die ==="
/hgpoc past 1024
echo "PAST1024 rc=$? (3 = killed by signal = PASS)"
sync
echo "--- counters after the wild write: hg_far_n must have moved, hg_grow_n must not ---"
/kpeek $HG 16
sync

echo "=== STEP 4b: brk churn -- grow and give back, 64 rounds ==="
/hgpoc churn 64
echo "CHURN rc=$?"
sync
/kpeek $HG 16
sync

echo "=== STEP 4c: A/B -- hg_on 1 -> 0 and run the wall again ==="
/kpoke $HGON 1 0
/kpoke $HGON8 1 0
echo "KPOKE hg_on -> 0 rc=$?"
/kpeek $HG 16
sync
sh -n /cdrom/install/bin/setup.sh
echo "WALL-OFF rc=$? (1 = the wall came back = the cure is what removed it)"
sync
echo "--- counters with the cure OFF: hg_grow_n must be unchanged ---"
/kpeek $HG 16
echo "wbf_dropped_n with the cure OFF:"
/kpeek $WBFDROP 1
sync
echo "--- and the same probe that passed above must now fail ---"
/hgpoc past 0
echo "PAST0-OFF rc=$? (1 or 3 = the store is lost again)"
sync
/kpeek $HG 16
sync

echo HG-END
sync
sync

# publish the log into the raw slice; block 25792 is the free window earlier runs used
dd if=$LOG of=/dev/dsk/c0d0s5 bs=1024 seek=25792
sync
sync
echo HG-PUBLISHED > /dev/console
/kpeek $HGGROW 1 > /dev/console
/kpeek $HGLAND 1 > /dev/console
