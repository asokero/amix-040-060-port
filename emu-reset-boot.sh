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
# usage: sh emu-reset-boot.sh [040|060] [serial-logfile]
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
HD="/home/asokero/Asiakirjat/FS-UAE/Hard Drives"
GOLDEN="$HD/amix_hardfileX11R5-net.hdf"
DISK="$HD/amix_hardfileX11R5.hdf"
AMIBERRY=/home/asokero/kehitys/amiberry/build/amiberry

case "$CPU" in
  040) CONF=/home/asokero/Amiberry/Configurations/a3000ux.uae ;;
  060) CONF=/home/asokero/Amiberry/Configurations/a3000ux060.uae ;;
  # a3640 (2026-07-31): an 040 CPU card with NO RAM of its own.  Same machine as
  # 040 except mbresmem_size=0, so there is no fast RAM at 0x08000000 and the
  # kernel must load into A3000 motherboard fast RAM at 0x07000000 instead.  The
  # port turned out to have no hardcoded load address (checked: the only
  # 0x08000000 in the base objects are comments, a debug-only RAM scan, wb040's
  # FSLW MA bit mask and a diagnostic print gate), so this config exists to test
  # that claim rather than to fix anything.
  a3640) CONF=/home/asokero/Amiberry/Configurations/a3000ux-a3640.uae ;;
  *) echo "usage: $0 [040|060|a3640] [serial-logfile]"; exit 1 ;;
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
