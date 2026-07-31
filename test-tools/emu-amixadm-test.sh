#!/bin/sh
# emu-amixadm-test.sh -- one ISSUE-10 reproduction cycle in the emulator, unattended.
#
# 2026-07-29: amixadm bus-errors on probe-less kernels and not on dbg ones, and it
# reproduces in Amiberry -- which turns a bug that needed a hardware session into a
# ~4 minute local loop.  This script is that loop:
#
#   boot the image under test -> wait for the console to settle -> log in ->
#   run amixadm -> count "BUS ERROR at 4AFC" lines on the serial mirror
#
# The image is copied over build/unix-040-dbg because that is the name the golden
# image's startup-sequence loads from DH2: (= build/).  The caller is responsible
# for restoring it; see the RESTORE note below.
#
# The kernel under test MUST carry serdbg (quiet or dbg builds), or the console
# NOTICE lines never reach the serial log and this script sees nothing.  A silent
# result from a base image would be an instrument failure, not a clean run.
#
# usage: sh emu-amixadm-test.sh <image> <label> [settle-seconds] [watch-seconds]
#
# AMIX_EMU_CPU selects the emulated machine (2026-07-31): 040 (default, A3000 +
# Mercury-like 32 MB at 0x08000000) or a3640 (an 040 card with NO RAM of its own,
# so 16 MB of motherboard RAM only).  The amixadm trigger is intermittent and the
# a3640 machine is a different memory-pressure regime, which is exactly the kind of
# variable a rate measurement should sweep.

set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
IMG="$1"
LABEL="${2:-test}"
SETTLE="${3:-20}"
WATCH="${4:-90}"
LOG="/tmp/emu-amixadm-$LABEL.log"

[ -f "$IMG" ] || { echo "no such image: $IMG"; exit 2; }
cp "$IMG" "$HERE/build/unix-040-dbg"
echo "[*] $LABEL: booting $(basename "$IMG") on ${AMIX_EMU_CPU:-040} -> $LOG"
sh "$HERE/emu-reset-boot.sh" "${AMIX_EMU_CPU:-040}" "$LOG" > /dev/null 2>&1

# The login prompt comes from getty via the tty, NOT through the conputc mirror, so
# there is no "ready" string to wait for.  Wait for the kernel's own output to stop.
prev=-1
same=0
while [ $same -lt 4 ]; do
	sleep 5
	cur=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
	if [ "$cur" = "$prev" ]; then same=$((same+1)); else same=0; fi
	prev=$cur
done
sleep "$SETTLE"
echo "[*] $LABEL: console settled at $prev bytes, logging in"

python3 "$HERE/test-tools/sendkeys.py" 'root' RET > /dev/null 2>&1
sleep 8
python3 "$HERE/test-tools/sendkeys.py" '/usr/amiga/bin/amixadm' RET > /dev/null 2>&1

i=0
while [ $i -lt "$WATCH" ]; do
	n=$(grep -ac "BUS ERROR at 4AFC" "$LOG" 2>/dev/null || echo 0)
	if [ "$n" -gt 0 ]; then
		echo "RESULT $LABEL: REPRODUCED ($n bus errors)"
		exit 1
	fi
	sleep 5
	i=$((i+5))
done
echo "RESULT $LABEL: no bus error in ${WATCH}s"
echo "   (check $LOG grew and that this image carries serdbg -- silence from a"
echo "    base image means the instrument was absent, not that the bug was)"
exit 0
