# xsvga-provenance.sh -- where the Xsvga driver object lives, and which build it is.
# Sourced by relink-040-xsvga.sh and relink-040-rtg.sh.  Not executable on its own.
#
# WHY THIS FILE EXISTS
# The Xsvga driver (Klaus Burckert, Piccolo / Picasso II Zorro-II) ships as a BINARY
# `exp` object -- the AMIX DDK distribution model.  We have no source for it.  Our
# integration is therefore a byte patch against a specific build, and
# prototypes/patch_xsvga.py asserts exact old bytes at fixed offsets.
#
# Until 2026-07-26 both relink scripts defaulted EXP to a path under /tmp -- a session
# scratchpad.  That is not a hygiene problem, it is a REPRODUCIBILITY problem: the next
# rebuild might not find the file, or worse, might find a different `exp` at the same
# path and get a confusing byte-assert failure instead of a clear one.  Hence: one
# durable path, one recorded checksum, checked before use.
#
# The object is deliberately NOT in this repo -- it is third-party and not ours to
# redistribute (same treatment as the AT&T headers in .gitignore).  Supply your own
# copy from the original Xsvga distribution (install.svga) and point XSVGA_EXP at it.

XSVGA_EXP="${XSVGA_EXP:-/home/asokero/kehitys/va2000-amixdev/svga-dev/svga/exp}"

# The build patch_xsvga.py was written against.  A different `exp` is not necessarily
# wrong, but it MUST be re-verified: the patch would either fail its byte asserts (fine,
# loud) or -- if the offsets happen to hold different code -- corrupt the driver (not
# fine, silent).  Override only after re-deriving the offsets.
XSVGA_SHA256="97a9a39d544aa73c733cd444a18663707c52a22802122f1e7312963481c72301"
XSVGA_SIZE=60464

xsvga_check_exp() {
	[ -f "$XSVGA_EXP" ] || {
		echo "ERROR: Xsvga driver object missing: $XSVGA_EXP"
		echo "       It is third-party and not in this repo.  Extract it from the"
		echo "       original Xsvga distribution (install.svga) and either put it at"
		echo "       that path or set XSVGA_EXP=/your/path."
		return 1
	}
	got=`sha256sum "$XSVGA_EXP" | cut -d' ' -f1`
	if [ "$got" != "$XSVGA_SHA256" ]; then
		echo "ERROR: Xsvga exp checksum mismatch -- patch_xsvga.py's byte offsets were"
		echo "       derived against a different build."
		echo "         file:     $XSVGA_EXP (`stat -c%s \"$XSVGA_EXP\"` bytes)"
		echo "         expected: $XSVGA_SHA256"
		echo "         got:      $got"
		echo "       Re-derive the offsets before overriding XSVGA_SHA256."
		return 1
	fi
	echo "      exp OK: $XSVGA_EXP"
	echo "              sha256 $XSVGA_SHA256 ($XSVGA_SIZE bytes)"
	return 0
}
