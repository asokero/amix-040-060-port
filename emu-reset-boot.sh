#!/bin/sh
# emu-reset-boot.sh (2026-07-14) -- deterministic emulator test-cycle boot:
#   1. stop any running Amiberry instance
#   2. reset the AMIX disk to the GOLDEN image (a crashed previous run otherwise
#      leaves a dirty fs -> fsck>reboot loop stalls the next automated cycle;
#      see KNOWN-ISSUES ISSUE-14 -- every run now starts from a known-clean fs,
#      so any corruption found is fresh, never inherited)
#   3. start the LOCAL Amiberry build (a2065-backport; /usr/bin/amiberry 8.2.2
#      cannot deliver host->guest frames) with the 040 or 060 AMIX config
#   4. capture serial (TCP:1234) into a log; build/unix_boot040 mirrors its
#      diagnostics there since 2026-07-14 and auto-continues its diagnostic
#      pause after 10 s (pass -w in the startup-sequence for the old
#      wait-forever behaviour on real-HW photo sessions)
#
# usage: sh emu-reset-boot.sh [040|060|lc060|040unimp|a3640] [serial-logfile] [kernel-image]
#
# THE THIRD ARGUMENT (2026-07-31).  The guest's startup-sequence loads DH2:
# unix-040-dbg, i.e. build/unix-040-dbg by name, so every test used to be staged
# by copying over that file by hand -- which twice destroyed a real dbg build in
# one session, once badly enough that drivers got linked in twice.  Pass the image
# instead and the script stages it, and protects whatever genuine build was there:
# the previous contents are saved to build/unix-040-dbg.real unless they are just
# a previously staged test image (tracked in build/.emu-image).
#   sh emu-reset-boot.sh 040 /tmp/x.log build/unix-040-quiet
#   sh emu-reset-boot.sh restore                 <- put the saved dbg build back
#
# NOTE: the serial-capture nc loop stays in the background across Amiberry
# restarts; kill it with:  pkill -f 'nc localhost 1234'
# Guest state is WIPED every run -- transfer test binaries via tftp each time
# (tftp_onesock.py; guest: tftp 10.0.2.2 1069). If inbound telnet (2323) stalls,
# the guest must send one packet first: ping 10.0.2.2 on the console (or bake it
# into the golden image's /etc/inet/rc.inet).
set -e

CPU="${1:-040}"
LOG="${2:-/tmp/amix-emu-serial-$CPU.log}"
IMG="${3:-}"
HERE0=$(cd "$(dirname "$0")" && pwd)
. "$(cd "$(dirname "$0")" && pwd)/tools/config-load.sh"
SLOT="$HERE0/build/unix-040-dbg"
MARK="$HERE0/build/.emu-image"

if [ "$CPU" = "restore" ]; then
	if [ -f "$SLOT.real" ]; then
		cp "$SLOT.real" "$SLOT"; rm -f "$MARK"
		echo "[*] restored the saved dbg build into $(basename "$SLOT")"
	else
		echo "[*] nothing to restore ($SLOT.real does not exist)"
	fi
	exit 0
fi

if [ -n "$IMG" ]; then
	[ -f "$IMG" ] || { echo "ERROR: kernel image missing: $IMG"; exit 1; }
	# Protect a genuine dbg build: save it unless the slot already holds a staged
	# test image (i.e. its checksum matches what we last staged).
	if [ -f "$SLOT" ]; then
		cur=$(sha256sum "$SLOT" | cut -d" " -f1)
		last=$(cat "$MARK" 2>/dev/null | cut -d" " -f1)
		if [ "$cur" != "$last" ]; then
			cp "$SLOT" "$SLOT.real"
			echo "[*] saved the existing $(basename "$SLOT") -> $(basename "$SLOT").real"
		fi
	fi
	cp "$IMG" "$SLOT"
	sha256sum "$SLOT" | sed "s|$| $IMG|" > "$MARK"
	# The month was hardcoded as 2607 and every August build therefore staged as "?".
	BID=$(strings -a "$IMG" 2>/dev/null | grep -m1 "680[46]0-[0-9][0-9][0-9][0-9][0-9][0-9]-" || echo "?")
	echo "[*] staged $(basename "$IMG") -> $(basename "$SLOT")   build id: $BID"
fi
HD="$AMIBERRY_HDF"
GOLDEN="$HD/amix_hardfileX11R5-net.hdf"
DISK="$HD/amix_hardfileX11R5.hdf"
AMIBERRY=$AMIBERRY_BIN

case "$CPU" in
  040) CONF=$AMIBERRY_CONF/a3000ux.uae ;;
  060) CONF=$AMIBERRY_CONF/a3000ux060.uae ;;
  # lc060 (2026-08-28): a 68060 with NO FPU -- cpu_model=68060, fpu_model=0.  The FPU is a
  # separate UAE setting from the CPU, so the 68LC060 the collaborating line runs in silicon is
  # a config option here.  That matters twice over: it is the only bed on this side that can
  # exercise an FPU-ABSENT path at all, and this project has three counter families
  # (fpc_*_nofpu_n and the soft-FPU lane's engage arm) that have only ever been measured
  # DORMANT because fpu_present reads 1 on every machine here.  A dormant counter is not a
  # passing one.
  # Both new configs are made from the stock ones with a single sed, the way every config in
  # $AMIBERRY_CONF is the reader's own rather than the repository's:
  #     sed 's/^fpu_model=68060/fpu_model=0/'            a3000ux060.uae > a3000ux060lc.uae
  #     sed 's/^fpu_no_unimplemented=true/...=false/'     a3000ux.uae    > a3000ux-unimp.uae
  lc060) CONF=$AMIBERRY_CONF/a3000ux060lc.uae ;;
  # 040unimp (2026-08-28): a 68040 WITH an FPU that actually traps unimplemented FP
  # instructions -- fpu_no_unimplemented=false.  The stock 040 and 060 configs both set it
  # TRUE, i.e. the emulated FPU implements everything and vector 11 never fires, which is the
  # concrete form of the AGENTS warning that this emulator "is not proof for which instructions
  # the CPU traps as unimplemented".  Every FPSP unimplemented-path counter this project has
  # ever read as zero in the emulator was read on a bed configured never to reach it.
  040unimp) CONF=$AMIBERRY_CONF/a3000ux-unimp.uae ;;
  # a3640 (2026-07-31): an 040 CPU card with NO RAM of its own.  Same machine as
  # 040 except mbresmem_size=0, so there is no fast RAM at 0x08000000 and the
  # kernel must load into A3000 motherboard fast RAM at 0x07000000 instead.  The
  # port turned out to have no hardcoded load address (checked: the only
  # 0x08000000 in the base objects are comments, a debug-only RAM scan, wb040's
  # FSLW MA bit mask and a diagnostic print gate), so this config exists to test
  # that claim rather than to fix anything.
  a3640) CONF=$AMIBERRY_CONF/a3000ux-a3640.uae ;;
  *) echo "usage: $0 [040|060|lc060|040unimp|a3640] [serial-logfile]"; exit 1 ;;
esac

[ -f "$GOLDEN" ] || { echo "ERROR: golden image missing: $GOLDEN"; exit 1; }
[ -x "$AMIBERRY" ] || { echo "ERROR: local amiberry build missing: $AMIBERRY (puavoOS wiped deps? see install-packages memory)"; exit 1; }

if pgrep -f "amiberry -f" > /dev/null 2>&1; then
	echo "[*] stopping running amiberry"
	pkill -f "amiberry -f" || true
	sleep 2
fi

# Kill any prior serial-capture loop too: only one client can hold the single
# TCP:1234 serial connection, so a leftover loop from an earlier run steals the
# port and the new run's log stays empty (learned the hard way 2026-07-15).
if pgrep -f "nc localhost 1234" > /dev/null 2>&1; then
	echo "[*] stopping stale serial-capture loop(s)"
	pkill -f "nc localhost 1234" || true
	sleep 1
fi

echo "[*] restoring golden image: $(basename "$GOLDEN") -> $(basename "$DISK")"
cp "$GOLDEN" "$DISK"

: > "$LOG"
# setsid: detach the capture loop from this shell's process group so it
# survives the caller's cleanup (an agent/tool session reaps its own group).
setsid sh -c "while :; do nc localhost 1234 >> '$LOG' 2>/dev/null; sleep 1; done" > /dev/null 2>&1 &
echo "[*] serial capture -> $LOG (setsid nc-loop pid $!)"

DISPLAY="${DISPLAY:-:1}" setsid "$AMIBERRY" -f "$CONF" -G -D > /dev/null 2>&1 &
echo "[*] amiberry started (pid $!, config $(basename "$CONF"))"
echo "    telnet: localhost 2323 | IPC: /run/user/12044/amiberry.sock (TAB-separated)"
