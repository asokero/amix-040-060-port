# netbsd-pin.sh -- which NetBSD source tarball this port builds from, and the gate that proves
# a given file IS it.  Sourced, never executed:
#
#     . "$HERE/tools/netbsd-pin.sh"
#     netbsd_syssrc_verify "$TGZ"
#
# THE PIN LIVES HERE, AND A GATE MAY NOT CARRY ITS OWN COPY OF IT.  Four scripts extract vendor
# source out of that tarball and compile it into things the kernel runs:
#
#     build-fpsp040.sh    usr/src/sys/arch/m68k/fpsp    -> build/fpsp040.o
#     build-fpsp060.sh    usr/src/sys/arch/m68k/060sp   -> build/fpsp060.o, fpsp060_pkg.o
#     build-ftest060.sh   .../060sp/dist/ftest.sa       -> build/ftest060
#     src/extract_fpe.sh  usr/src/sys/arch/m68k/fpe     -> build/fpe-src/
#
# Until 2026-08-28 only the fourth checked the tarball.  The other three took whatever
# $NETBSD_SYSSRC (or argv[1]) pointed at, so swapping the tarball silently changed three build
# inputs while the one script that would have objected was not on that path.  A gate that covers
# one of four call sites is not a pin; it is a place the pin happens to be enforced.
#
# One value, one file, for a second reason: when the pin last moved (NetBSD 9.4 -> 10.1) the
# sha256 had to be edited in several places at once, and a check whose expected value exists in
# several copies is a check that will eventually disagree with itself.  Bumping the pin is now
# an edit to the line below, plus prose wherever prose quotes it.
#
# WHY NOT config.sh: config.sh is local-only and is not in this repository (config.sh.example
# is).  A check that reads its expected value from a file the repository does not carry cannot
# fail on a machine that has the wrong file -- it just believes it.  config.sh names WHICH file
# to use; this names WHAT that file has to be, and only one of those is the project's to decide.
#
# WHY FAILURES GO TO STDERR: relink-040.sh runs two of the four as `sh build-fpsp0x0.sh
# >/dev/null`, because their normal output is 40 lines of assertions nobody reads during a
# kernel build.  On stdout the reason for a refusal would be discarded and the relink would die
# with an exit status and no explanation.

# NetBSD 10.1 syssrc.tgz, 79497697 bytes, from
# https://cdn.netbsd.org/pub/NetBSD/NetBSD-10.1/source/sets/syssrc.tgz
# sha512 766ac21f33cfe0e701dfedb894fa07f36d811da1a12e979181e8fca7af4e627852680ce42a7b29e97dd3e2e402ddf9ae7bfba60c8d7dc6b8a3354d8ce8c06926
# HISTORY: rounds <=12 of the FPE lane built from NetBSD 9.4 syssrc.tgz, 59991883 bytes,
# sha256 5e1f101748d8ff04a37aba845133e0f5804d1ca9b995c99f05cc39874ab3120b.  The two tarballs
# produce byte-identical fpsp/060sp objects -- they differ there only in comments and RCS id
# lines -- and differ for real in exactly one FPE file, fpu_explode.c 1.15 -> 1.16.
NETBSD_SYSSRC_SHA256=76a600e703d2e964753323e264d3ec07d0c6cbe134648fc8f0f13ed9faaa1be4

# netbsd_syssrc_verify <path> -- the file exists and is the pinned tarball, or the caller dies.
# Prints the sha it accepted, so a build log records which vendor source it was made from.
netbsd_syssrc_verify() {
	_np_f="$1"
	[ -n "$_np_f" ] || {
		echo "[FAIL] netbsd_syssrc_verify: called without a tarball path" >&2
		exit 1
	}
	[ -f "$_np_f" ] || {
		echo "[FAIL] NetBSD source tarball not found: $_np_f" >&2
		echo "       config.sh's NETBSD_SYSSRC must name the pinned syssrc.tgz;" >&2
		echo "       config.sh.example says which release and where to fetch it." >&2
		exit 1
	}
	_np_got=$(sha256sum "$_np_f" | cut -d' ' -f1)
	[ "$_np_got" = "$NETBSD_SYSSRC_SHA256" ] || {
		echo "[FAIL] $_np_f is not the pinned NetBSD source tarball" >&2
		echo "       sha256   $_np_got" >&2
		echo "       expected $NETBSD_SYSSRC_SHA256" >&2
		echo "       A different tarball is different vendor source, and everything this port" >&2
		echo "       measured was measured on the pinned one.  The pin is tools/netbsd-pin.sh." >&2
		exit 1
	}
	echo "      tarball sha256 $NETBSD_SYSSRC_SHA256"
	unset _np_f _np_got
}
