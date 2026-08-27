#!/bin/sh
# check-env.sh -- verify every external dependency before you try to build.
#
#   sh tools/check-env.sh
#
# Exits non-zero if anything MANDATORY is missing.  Optional dependencies are reported but do
# not fail the check: you can build a kernel without an emulator, and without the graphics
# drivers, and without Ghidra.
#
# The point of this script is that a missing tool should be named here, once, rather than
# discovered as a confusing error in the middle of a 300-step relink.
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tools/config-load.sh"

RED=''; GRN=''; YEL=''; OFF=''
if [ -t 1 ]; then RED='\033[31m'; GRN='\033[32m'; YEL='\033[33m'; OFF='\033[0m'; fi
fail=0; warn=0

say_ok()   { printf "  ${GRN}ok${OFF}      %-22s %s\n" "$1" "$2"; }
say_bad()  { printf "  ${RED}MISSING${OFF} %-22s %s\n" "$1" "$2"; fail=$((fail+1)); }
say_warn() { printf "  ${YEL}absent${OFF}  %-22s %s\n" "$1" "$2"; warn=$((warn+1)); }

need_tool() {   # name, hint
	if command -v "$1" >/dev/null 2>&1; then say_ok "$1" "$(command -v "$1")"
	else say_bad "$1" "$2"; fi
}
want_tool() {
	if command -v "$1" >/dev/null 2>&1; then say_ok "$1" "$(command -v "$1")"
	else say_warn "$1" "$2"; fi
}
need_file() {   # path, label, hint
	if [ -e "$1" ]; then say_ok "$2" "$1"
	else say_bad "$2" "$3 (config.sh says: $1)"; fi
}
want_file() {
	if [ -e "$1" ]; then say_ok "$2" "$1"
	else say_warn "$2" "$3"; fi
}

echo "AMIX 68040/68060 port -- environment check"
echo
echo "MANDATORY: to build a kernel"

# 1. The AMIX cross toolchain.  Put it on PATH the way the build does, then look for it.
# PATH is set by config-load.sh, which also makes config.sh win over the toolchain env.
need_file "$GCC_CROSS_ENV" "cross env.sh" "the AMIX cross toolchain's environment script"
need_tool m68k-cbm-sysv4-gcc "build the AMIX cross toolchain -- see BUILDING.md"
need_tool m68k-cbm-sysv4-ld  "same toolchain"

# 2. GNU m68k binutils.
for t in m68k-linux-gnu-nm m68k-linux-gnu-objcopy m68k-linux-gnu-objdump \
         m68k-linux-gnu-readelf m68k-linux-gnu-size m68k-linux-gnu-gcc; do
	need_tool "$t" "Debian/Ubuntu: apt install binutils-m68k-linux-gnu gcc-m68k-linux-gnu"
done

# 3. Ordinary tools the scripts assume.
need_tool python3 "any Python 3"
need_tool patch   "GNU patch"
need_tool sha256sum "coreutils"

# 4. Your own AMIX kernel -- the thing this port patches.
EXPECT_SHA=7d26cb6f04991be5776d9e5361259b20b413d97e3da33bf88e6f312e7be2ec23
if [ -f "$AMIX_ROOT/stand/unix" ]; then
	got=$(sha256sum "$AMIX_ROOT/stand/unix" | cut -d' ' -f1)
	if [ "$got" = "$EXPECT_SHA" ]; then
		say_ok "AMIX kernel" "$AMIX_ROOT/stand/unix (sha256 matches)"
	else
		printf "  ${RED}WRONG${OFF}   %-22s %s\n" "AMIX kernel" "$AMIX_ROOT/stand/unix"
		echo "          sha256 $got"
		echo "          expected $EXPECT_SHA  (AMIX SVR4 2.1c)"
		echo "          The patch scripts use hard-coded addresses; a different build would be"
		echo "          patched at the WRONG BYTES rather than refused.  Please report the hash"
		echo "          you have -- see BUILDING.md."
		fail=$((fail+1))
	fi
else
	say_bad "AMIX kernel" "mount your own AMIX install and set AMIX_ROOT (config.sh)"
fi

# 5. NetBSD tarball, for Motorola's FPSP/ISP packages.
#
# PINNED, and pinned to something a third party can obtain and verify without trusting us.
# Until 2026-08-27 this said "any recent NetBSD source tarball" and checked only that the file
# existed -- and BUILDING.md said the same.  Nothing anywhere compared its contents.  So the
# FPSP in every hardware-accepted image came from whatever tarball happened to be on the build
# host, two people could build from different NetBSD sources with nothing saying so, and a fresh
# clone would get a DIFFERENT FPSP from the one the acceptance runs proved.  It came to light
# when a collaborator quoted a pin that did not match ours.
#
# The value below is NetBSD's own published SHA512 for the 10.1 source set, from
#   https://cdn.netbsd.org/pub/NetBSD/NetBSD-10.1/source/sets/SHA512
# so this check is against upstream rather than against a number this project invented.  The
# local archive was confirmed byte-identical to it on 2026-08-27, which is why no rebuild was
# needed to adopt the pin: the accepted images were already built from this exact file.
#
# A different tarball is a different FPSP, not a variation.  Do not relax this to make a build
# pass -- fetch the pinned set.
NETBSD_SHA512=766ac21f33cfe0e701dfedb894fa07f36d811da1a12e979181e8fca7af4e627852680ce42a7b29e97dd3e2e402ddf9ae7bfba60c8d7dc6b8a3354d8ce8c06926
NETBSD_URL=https://cdn.netbsd.org/pub/NetBSD/NetBSD-10.1/source/sets/syssrc.tgz
if [ -e "$NETBSD_SYSSRC" ]; then
	got=$(sha512sum "$NETBSD_SYSSRC" | cut -d" " -f1)
	if [ "$got" = "$NETBSD_SHA512" ]; then
		say_ok "NetBSD syssrc.tgz" "$NETBSD_SYSSRC (NetBSD 10.1, upstream SHA512 verified)"
	else
		say_bad "NetBSD syssrc.tgz" "WRONG ARCHIVE -- this is not the pinned NetBSD 10.1 source set"
		echo "          have     $got"
		echo "          expected $NETBSD_SHA512"
		echo "          Motorola's FPSP and ISP are extracted from this archive, so a different"
		echo "          one yields a different support package than the accepted images contain."
		echo "          Fetch: $NETBSD_URL"
		echo "          Verify against NetBSD's own SHA512 file in the same directory."
		fail=$((fail+1))
	fi
else
	say_bad "NetBSD syssrc.tgz" "NetBSD 10.1 source set; fetch $NETBSD_URL (config.sh says: $NETBSD_SYSSRC)"
fi

echo
echo "OPTIONAL: emulator testing"
want_file "$AMIBERRY_BIN" "amiberry" "a LOCAL build is needed -- the packaged 8.2.2 cannot deliver host->guest frames"
want_file "$AMIBERRY_CONF" "amiberry configs" "directory holding a3000ux.uae / a3000ux060.uae"
want_file "$AMIBERRY_HDF" "amiberry hardfiles" "directory holding the AMIX disk image"
want_tool nc "netcat, for the serial capture loop"
want_tool xdotool "only needed to focus the emulator window for console keystrokes"

echo
echo "OPTIONAL: graphics kernels"
want_file "$XSVGA_EXP" "Xsvga object" "needed only by relink-040-xsvga.sh / relink-040-rtg.sh"
want_file "$VA2000_SRC" "VA2000 driver source" "needed only by relink-040-va2000.sh / relink-040-rtg.sh (repo: va2000-amix)"
want_file "$Z3660_SCSI_SRC" "Z3660 SCSI source" "needed only by relink-040-z3660.sh (repo: amix-z3660scsi)"
want_file "$Z3660_NET_SRC" "Z3660 net source"   "needed only by relink-040-z3660.sh (repo: amix-z3660net)"

echo
echo "OPTIONAL: analysis and hardware testing"
want_file "$GHIDRA_HOME" "Ghidra" "only for tools/ghidra-decomp.sh"
want_file "$HERE/local/secrets.env" "local/secrets.env" "needed only by test-tools/hw.py -- cp local/secrets.env.example local/secrets.env"

echo
if [ "$fail" -gt 0 ]; then
	printf "${RED}%d mandatory dependency/dependencies missing${OFF} -- the build will not work yet.\n" "$fail"
	exit 1
fi
printf "${GRN}All mandatory dependencies present.${OFF}"
[ "$warn" -gt 0 ] && printf "  (%d optional absent -- fine unless you need them.)" "$warn"
echo
echo "Next:  sh relink-040.sh"
exit 0
