#!/bin/sh
# cdfs_modelb.sh -- build the cdfs (ODFileSystem) kernel filesystem through the
# Model-B header set and report whether it is fit to link into a 68040 kernel
# (2026-08-19).
#
#   the amix-cdfs repository   read-only optical filesystem (ISO9660/RockRidge/
#                              Joliet/UDF/HFS/HFS+/CDDA), mounted as `-F cdfs`
#
# Like the Z3660 drivers, amix-cdfs is a SEPARATE PROJECT and is never modified.
# Unlike them it needs no source adaptation at all, so there is no cdfs_modelb.py
# beside this: its own Makefile already builds an `amix-kernel` target, and the
# only thing this script does to it is (a) point $AMIX_SYSROOT at the Model-B
# mirror and (b) redirect the output tree into build/ here, so not one byte is
# written inside the cdfs checkout.
#
# ---------------------------------------------------------------------------
# WHY THIS IS A DIFFERENTIAL BUILD AND NOT JUST check_page_geometry.sh
#
# src/check_page_geometry.sh looks for `moveq #11,%dN` followed by lsrl/asrl.
# That signature is exactly right for a driver, and it is WRONG IN BOTH
# DIRECTIONS on a filesystem for optical media -- measured, both times:
#
#   FALSE POSITIVE.  An ISO9660 logical sector is 2048 bytes.  Every
#   `byte_offset / 2048` in the backends compiles to the same `moveq #11; lsrl`
#   as a 2 KiB page shift, and the checker calls seven cdfs objects (iso9660,
#   udf, hfs, hfsplus, joliet, cdda, cdfs_vnodeops) FAILED for it.  Those shifts
#   are the CD sector size, a fact about the medium, and halving them would
#   corrupt every read.
#
#   FALSE NEGATIVE.  platform/amix-kernel/amix_kern_media.c is the one file that
#   genuinely depends on the page size -- its DMA page-cross guard is
#   `(addr & (NBPP-1)) + nbyte > NBPP`.  That compiles to andi/cmpi and an
#   alignment test as `bftst %d6,21,11`, and contains no page SHIFT at all, so
#   the checker reports it clean whatever NBPP it was built with.
#
# So the question the checker asks -- "is there a 2 KiB shift in here?" -- cannot
# be the gate for this component.  The question that CAN be is:
#
#     does this object change when the page geometry changes?
#
# An object built identically through the 2 KiB and the 4 KiB header sets is
# geometry-INDEPENDENT by proof, whatever shifts it contains, so its `>> 11`
# sites are provably about something other than pages.  An object that DIFFERS
# is geometry-dependent, and then -- and only then -- a surviving 2 KiB shift is
# a real Model-B miss.  That is the rule below, and it needs no per-file
# exception list: nothing has to be trusted, only compiled twice.
# ---------------------------------------------------------------------------
#
# usage: sh src/cdfs_modelb.sh [path-to-base-kernel]
#        (base kernel defaults to build/unix-040; it is used ONLY to resolve
#         cdfs's undefined symbols for the link-scope report -- nothing is
#         linked and no kernel is written.)
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$(cd "$(dirname "$0")" && pwd)/../tools/config-load.sh"

CDFS="${CDFS_SRC:-$HERE/../amix-cdfs}"
[ -f "$CDFS/Makefile" ] || { echo "ERROR: amix-cdfs not found at $CDFS (set CDFS_SRC)"; exit 1; }
KERNEL="${1:-$HERE/build/unix-040}"
OD="${OBJDUMP:-m68k-linux-gnu-objdump}"
NM="${NM:-m68k-linux-gnu-nm}"

MODELB="$HERE/build/cdfs-modelb"
STOCK="$HERE/build/cdfs-stockgeom"
REAL="${AMIX_REAL_SYSROOT:-$AMIX_CROSS/m68k-cbm-sysv4/sysroot}"

echo "[*] cdfs source: $CDFS   (read-only; output goes to build/ here)"

echo "[*] Model-B header set (mirror sysroot + geometry probe)"
sh "$HERE/src/mk_modelb_sysroot.sh" | sed 's/^/      /'

# Two builds of the same sources: the real one, and the 2 KiB control that makes
# the comparison mean something.  AMIX_KERNEL_BUILD is redirected on the make
# command line so the cdfs checkout is never written to; AMIX_SYSROOT is passed
# through the environment because the Makefile takes it with ?=.
#
# NOTE the flags are deliberately NOT overridden.  AMIX_KERNEL_CFLAGS carries a
# target-specific `+= -fno-builtin` for kstring.o (without which gcc rewrites the
# memcpy/memset bodies into calls to themselves), and a command-line assignment
# would silently defeat that append.  Anything extra belongs in CPPFLAGS, which
# the rule also passes and the Makefile never sets.
build_one() {
	echo "[*] building cdfs amix-kernel through $2"
	rm -rf "$1"
	( cd "$CDFS" && AMIX_SYSROOT="$3" \
		make amix-kernel AMIX_KERNEL_BUILD="$1" ) | sed 's/^/      /'
}
build_one "$MODELB" "the Model-B mirror sysroot" "$HERE/build/sysroot-modelb"
build_one "$STOCK"  "the STOCK 2 KiB sysroot (control)" "$REAL"

# The whole point of touching another project's tree only through make: prove it.
if command -v git >/dev/null 2>&1 && git -C "$CDFS" rev-parse --git-dir >/dev/null 2>&1; then
	DIRTY=$(git -C "$CDFS" status --porcelain)
	[ -z "$DIRTY" ] && echo "[OK] cdfs checkout untouched (git status clean)" \
		|| { echo "[FAIL] the cdfs checkout was modified by this build:"; echo "$DIRTY"; exit 1; }
fi

# ---------------------------------------------------------------- the partition
echo
echo "[*] partitioning objects by whether the page geometry changed them"
rc=0
DEP=""
for f in $(cd "$MODELB" && find . -name '*.o' ! -name libcdfskern.o | sort); do
	b=$(basename "$f")
	# A shift by 11 is what check_page_geometry.sh keys on; recorded here so the
	# two facts can be reported together rather than one without the other.
	shift11=$("$OD" -d "$MODELB/$f" | grep -A1 "moveq #11," | grep -cE "lsrl|asrl" || true)
	if cmp -s "$MODELB/$f" "$STOCK/$f"; then
		if [ "$shift11" -gt 0 ]; then
			printf "  [OK]   %-22s geometry-INDEPENDENT (byte-identical under 2K and 4K)\n" "$b"
			printf "         %s\n" \
			  "...and its $shift11 shift-by-11 site(s) are therefore provably NOT page shifts"
		else
			printf "  [OK]   %-22s geometry-INDEPENDENT (byte-identical under 2K and 4K)\n" "$b"
		fi
	else
		DEP="$DEP $f"
		if [ "$shift11" -gt 0 ]; then
			printf "  [FAIL] %-22s geometry-DEPENDENT and still holds %s shift(s) by 11\n" "$b" "$shift11"
			rc=1
		else
			printf "  [**]   %-22s geometry-DEPENDENT -- constants below need reading\n" "$b"
		fi
	fi
done

# A geometry-dependent object is where the real review is, and it is small enough
# to print in full: every instruction that moved, side by side.  This is the part
# a human signs off on; the script only guarantees the list is complete.
echo
if [ -z "$DEP" ]; then
	echo "[**] NO object depends on the page geometry -- suspicious for a component"
	echo "     that mounts a device: expected at least the DMA media backend.  Check"
	echo "     that the control build really used the stock sysroot."
	rc=1
else
	# Plain temp files rather than process substitution: this script runs under
	# /bin/sh, which on Debian/Ubuntu is dash, and `<(...)` is a bashism that
	# fails there with a bare "Syntax error: "(" unexpected".
	for f in $DEP; do
		echo "[*] $(basename "$f"): every instruction that changed with the page size"
		echo "     (left = stock 2 KiB, right = Model-B 4 KiB)"
		"$OD" -d "$STOCK/$f"  | tail -n +3 > "$HERE/build/.cdfs-dis-stock"
		"$OD" -d "$MODELB/$f" | tail -n +3 > "$HERE/build/.cdfs-dis-modelb"
		diff "$HERE/build/.cdfs-dis-stock" "$HERE/build/.cdfs-dis-modelb" \
			| sed 's/^/       /' || true
		echo
	done
fi

# ---------------------------------------------------------------- link scope
# Nothing is linked here.  The kernel-side registration a mountable filesystem
# needs -- a vfssw[] slot and its init call -- does not exist in this tree yet,
# so a relink script would have nothing to wire.  What CAN be settled now, and is
# the thing that scopes the work, is whether the base kernel actually exports
# everything cdfs calls.
echo "[*] link scope against $(basename "$KERNEL")"
if [ -f "$KERNEL" ]; then
	"$NM" "$KERNEL" | awk '$1!="U" && NF==3 {print $3}' | sort -u > "$HERE/build/.cdfs-kdefs"
	"$NM" "$MODELB/libcdfskern.o" | awk '$1=="U"{print $2}' | sort > "$HERE/build/.cdfs-undef"
	miss=0
	while read s; do
		if grep -qx "$s" "$HERE/build/.cdfs-kdefs"; then
			printf "      %-16s resolved by the kernel\n" "$s"
		else
			printf "      %-16s NOT in the kernel\n" "$s"
			miss=$((miss + 1))
		fi
	done < "$HERE/build/.cdfs-undef"
	echo "      -- $miss symbol(s) unresolved by the kernel image."
	echo "         The cdfs Makefile leaves the three 64-bit soft-arithmetic helpers"
	echo "         (__udivdi3 / __umoddi3 / __lshrdi3) undefined on purpose; they come"
	echo "         from the cross toolchain's libgcc.a at the real kernel link.  Any"
	echo "         OTHER name in that list is a genuine gap."
else
	echo "      [skip] $KERNEL not built -- run relink-040.sh first"
fi

echo
echo "[*] NOT LINKED.  cdfs is a filesystem, not a device driver: registering it"
echo "    needs a vfssw[] slot and an init call, and this tree has no such glue"
echo "    yet (there is no relink-040-cdfs.sh).  This script stops at 'the objects"
echo "    are correct and the kernel exports what they call'."
exit $rc
