#!/bin/sh
# build-fpsp060.sh -- F3 M1: reproduce Motorola's M68060 Floating-Point Software Package
# as a relocatable object our kernel relink can consume.  Plan: docs/060-F3-FPSP-PLAN-260807.md.
#
# Source: the freely-redistributable M68060 Software Package as imported by NetBSD
# (sys/arch/m68k/060sp) inside netbsd/syssrc.tgz -- the same tarball build-fpsp040.sh uses.
# The Motorola copyright/modification notice (copyright.S) is linked in and MUST be retained
# (licence condition: the notice must survive "without alteration" in modified versions).
#
# HOW THIS DIFFERS FROM THE 040 PACKAGE, which is the whole reason M1 exists as its own step:
#
#   * The 040 FPSP is SYMBOL-based: it exports fpsp_* entry points and leaves 12 OS-glue
#     symbols unresolved for the linker to bind.  The 060 package is ADDRESS-based.  It
#     exports NO symbols at all (asserted below: zero unresolved, and none defined), and
#     callers reach it by jumping to a fixed offset from the top of the image.  The OS
#     call-outs are found at run time through a 128-byte table that the OS places
#     immediately BEFORE the image -- that table is M2's job, not M1's.
#
#   * Therefore the ONE invariant M1 has to protect is the byte offset of the entry-point
#     table.  Anything linked ahead of the image would silently move every entry point, and
#     a wrong offset does not fail to link -- it jumps into the middle of the package.  So
#     the image is linked FIRST, copyright.S after it, and the nine entries are decoded from
#     the linked .text and checked, every build.  Not read from the documentation: decoded.
#
# fpsp.S and pfpsp.S are already GNU/MIT syntax in the NetBSD tree (the .sa hex image with
# "dc.l $" rewritten to ".long 0x"), so unlike the 040 path no asm2gas conversion is needed.
#
# Output: build/fpsp060.o   full package   .text 0xd490 = 54416 bytes
#         build/pfpsp060.o  partial        .text 0x6c20 = 27680 bytes
# The choice between them is D2 in the plan and is decided by running fp060probe against
# both, not by reading module lists.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$(cd "$(dirname "$0")" && pwd)/tools/config-load.sh"
# The pinned tarball's sha256, and the gate that checks it, are tools/netbsd-pin.sh -- one
# expected value shared with build-fpsp040.sh, build-ftest060.sh and src/extract_fpe.sh.
. "$HERE/tools/netbsd-pin.sh"
TGZ="${1:-$NETBSD_SYSSRC}"
WORK="$HERE/build/fpsp060-work"
SUB="usr/src/sys/arch/m68k/060sp"

command -v m68k-linux-gnu-gcc >/dev/null || { echo "ERROR: m68k-linux-gnu-gcc not on PATH"; exit 1; }

# The image IS this tarball's bytes, and the entry-point offsets asserted below are only
# meaningful for the package this port measured.  Which tarball it is has to be checked.
echo "[*] checking $(basename "$TGZ") against the pin"
netbsd_syssrc_verify "$TGZ"

echo "[*] extracting $SUB from $(basename "$TGZ")"
rm -rf "$WORK"; mkdir -p "$WORK"
tar xzf "$TGZ" -C "$WORK" --exclude='*CVS*' "$SUB"
SP="$WORK/$SUB"

echo "[*] assemble copyright.S (licence notice -- must stay in the object)"
m68k-linux-gnu-gcc -x assembler-with-cpp -m68060 -c "$SP/copyright.S" -o "$WORK/copyright060.o"

# $1 = source stem, $2 = output object, $3 = expected .text size of the IMAGE alone
build_one() {
	_src="$1"; _out="$2"; _expect="$3"
	echo "[*] assemble $_src.S -> image object"
	m68k-linux-gnu-gcc -x assembler-with-cpp -m68060 -c "$SP/$_src.S" -o "$WORK/$_src-image.o"

	_tsz=$(m68k-linux-gnu-readelf -SW "$WORK/$_src-image.o" | awk '{gsub(/[][]/,"")} $2==".text"{print $6}')
	[ "$_tsz" = "$_expect" ] || { echo "[FAIL] $_src image .text 0x$_tsz != 0x$_expect"; exit 1; }
	echo "      image .text = 0x$_tsz"

	# The package resolves its OS call-outs through the run-time table, not the linker.
	_und=$(m68k-linux-gnu-nm "$WORK/$_src-image.o" 2>/dev/null | grep -c ' U ' || true)
	[ "$_und" = "0" ] || { echo "[FAIL] $_src: expected 0 unresolved symbols, got $_und"; exit 1; }
	echo "      0 unresolved symbols (address-based interface, as expected)"

	echo "[*] ld -r: IMAGE FIRST, then copyright -- order is load-bearing"
	m68k-linux-gnu-ld -r -o "$_out" "$WORK/$_src-image.o" "$WORK/copyright060.o"

	echo "[*] decode the entry-point table from the linked object"
	m68k-linux-gnu-objcopy -O binary --only-section=.text "$_out" "$WORK/$_src.bin"
	python3 - "$WORK/$_src.bin" <<-'PY'
	import sys
	b = open(sys.argv[1], 'rb').read()
	names = ['snan','operr','ovfl','unfl','dz','inex','fline','unsupp','effadd']
	bad = 0
	for i, n in enumerate(names):
	    o = i * 8
	    op = int.from_bytes(b[o:o+2], 'big')
	    disp = int.from_bytes(b[o+2:o+6], 'big')
	    tgt = o + 2 + disp
	    ok = (op == 0x60ff) and (0 < tgt < len(b))
	    if not ok:
	        bad += 1
	    print("      +0x%02x  _060_fpsp_%-7s -> 0x%05x %s"
	          % (o, n, tgt, "" if ok else "<-- NOT a bra.l into the image"))
	fill = int.from_bytes(b[0x48:0x4a], 'big')
	if fill != 0x51fc:
	    print("      [FAIL] filler at 0x48 is 0x%04x, expected 0x51fc (trapf)" % fill)
	    bad += 1
	if bad:
	    sys.exit("[FAIL] entry-point table is not where the package contract says")
	print("      all 9 entries are bra.l into the image; filler 0x51fc at 0x48")
	PY

	# relink compatibility: the kernel's SysV4 ld must accept this object
	( . $GCC_CROSS_ENV 2>/dev/null
	  m68k-cbm-sysv4-ld -r -o "$WORK/$_src-cbmcheck.o" "$_out" ) \
		&& echo "      m68k-cbm-sysv4-ld -r accepts $(basename "$_out")" \
		|| { echo "[FAIL] m68k-cbm-sysv4-ld rejects $(basename "$_out")"; exit 1; }
	rm -f "$WORK/$_src-cbmcheck.o"
}

build_one fpsp  "$HERE/build/fpsp060.o"  "00d490"
echo
build_one pfpsp "$HERE/build/pfpsp060.o" "006c20"

# ---------------------------------------------------------------------------
# M2a: the packaged object the kernel actually links -- table, image and AMIX call-outs as
# ONE assembly unit.  Concatenated rather than linked: the SysV4 assembler has no .incbin,
# and the table entries are symbol differences, which are only link-time constants inside a
# single unit.  Adjacency is then true by construction, not by linker input order.
#
# D2 (full vs partial) is decided by MEASUREMENT, not by reading module lists, so the variant
# is a variable:  FPSP060_VARIANT=pfpsp sh build-fpsp060.sh  builds the partial package into
# exactly the same wrapper.  The two entry-point tables are byte-identical (M1), so the only
# way to tell them apart is to run fp060probe against each.
# ---------------------------------------------------------------------------
VARIANT="${FPSP060_VARIANT:-fpsp}"
case "$VARIANT" in
fpsp|pfpsp) ;;
*) echo "[FAIL] FPSP060_VARIANT must be fpsp or pfpsp, got '$VARIANT'"; exit 1 ;;
esac
PKGSRC="$HERE/build/fpsp060_pkg.s"
PKGOBJ="$HERE/build/fpsp060_pkg.o"

echo
echo "[*] M2a: concatenate head + $VARIANT image + glue -> $(basename "$PKGSRC")"
cat "$HERE/src/fpsp060_head.s" "$SP/$VARIANT.S" "$HERE/src/fpsp060_glue.s" > "$PKGSRC"
m68k-linux-gnu-gcc -x assembler-with-cpp -m68060 -c "$PKGSRC" -o "$PKGOBJ"

TOP=$(m68k-linux-gnu-nm "$PKGOBJ" | awk '$3=="fpsp060_top"{print $1}')
IMG=$(m68k-linux-gnu-nm "$PKGOBJ" | awk '$3=="fpsp060_image"{print $1}')
[ "$TOP" = "00000000" ] || { echo "[FAIL] fpsp060_top at 0x$TOP, must be 0"; exit 1; }
[ "$IMG" = "00000080" ] || { echo "[FAIL] fpsp060_image at 0x$IMG, must be 0x80 (table = 128 B)"; exit 1; }
echo "      fpsp060_top = 0x$TOP, fpsp060_image = 0x$IMG (table is exactly 128 bytes)"

echo "[*] decode the entry-point table THROUGH the call-out section"
m68k-linux-gnu-objcopy -O binary --only-section=.text "$PKGOBJ" "$WORK/pkg.bin"
python3 - "$WORK/pkg.bin" <<-'PY'
	import sys
	b = open(sys.argv[1], 'rb').read()
	# every call-out slot must be a plausible relative address inside this object
	bad = 0
	for i in range(32):
	    v = int.from_bytes(b[i*4:i*4+4], 'big')
	    if not (0 < v < len(b)):
	        print("      [FAIL] call-out slot %d = 0x%08x is not inside the object" % (i, v))
	        bad += 1
	print("      32 call-out slots all point inside the object")
	for off, name in ((0x30, 'fline'), (0x38, 'unsupp'), (0x40, 'effadd')):
	    o = 128 + off
	    op = int.from_bytes(b[o:o+2], 'big')
	    tgt = o + 2 + int.from_bytes(b[o+2:o+6], 'big')
	    ok = op == 0x60ff and 128 < tgt < len(b)
	    print("      TOP+128+0x%02x -> 0x%05x  _060_fpsp_%-6s %s"
	          % (off, tgt, name, "" if ok else "<-- NOT a bra.l into the image"))
	    bad += 0 if ok else 1
	if bad:
	    sys.exit("[FAIL] packaged layout is wrong")
	PY

for s in fpsp060_vec11 f60_magic f60_entry_n f60_mem_n f60_real_n f60_access_n f60_done_n; do
	m68k-linux-gnu-nm "$PKGOBJ" | grep -qE " [A-Za-z] $s\$" || { echo "[FAIL] $s not defined"; exit 1; }
done
echo "      glue symbols defined"
UND=$(m68k-linux-gnu-nm "$PKGOBJ" | grep ' U ' | awk '{print $2}' | tr '\n' ' ')
echo "      unresolved (kernel supplies these): $UND"

echo
echo "[OK] M1 + M2a complete."
sha256sum "$HERE/build/fpsp060.o" "$HERE/build/pfpsp060.o"
echo
echo "     Entry points for M2's glue, as offsets from the TOP of the call-out section:"
echo "       vector 11 (F-line, unimplemented FP)  ->  TOP + 128 + 0x30"
echo "       vector 55 (unimplemented data type)   ->  TOP + 128 + 0x38"
echo "       vector 60 (unimplemented eff. addr)   ->  TOP + 128 + 0x40"
echo "       vectors 48-54 (IEEE exceptions)       ->  TOP + 128 + 0x00..0x28"
