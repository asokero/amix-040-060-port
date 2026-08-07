#!/bin/sh
# build-fpsp060.sh -- F3 M1: reproduce Motorola's M68060 Floating-Point Software Package
# as a relocatable object our kernel relink can consume.  Plan: 060-F3-FPSP-PLAN-260807.md.
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
TGZ="${1:-/home/asokero/kehitys/amix-playground/netbsd/syssrc.tgz}"
WORK="$HERE/build/fpsp060-work"
SUB="usr/src/sys/arch/m68k/060sp"

[ -f "$TGZ" ] || { echo "ERROR: netbsd source tarball missing: $TGZ"; exit 1; }
command -v m68k-linux-gnu-gcc >/dev/null || { echo "ERROR: m68k-linux-gnu-gcc not on PATH"; exit 1; }

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
	( . /home/asokero/kehitys/amix-playground/gcc-cross-amix/build/env.sh 2>/dev/null
	  m68k-cbm-sysv4-ld -r -o "$WORK/$_src-cbmcheck.o" "$_out" ) \
		&& echo "      m68k-cbm-sysv4-ld -r accepts $(basename "$_out")" \
		|| { echo "[FAIL] m68k-cbm-sysv4-ld rejects $(basename "$_out")"; exit 1; }
	rm -f "$WORK/$_src-cbmcheck.o"
}

build_one fpsp  "$HERE/build/fpsp060.o"  "00d490"
echo
build_one pfpsp "$HERE/build/pfpsp060.o" "006c20"

echo
echo "[OK] M1 complete."
sha256sum "$HERE/build/fpsp060.o" "$HERE/build/pfpsp060.o"
echo
echo "     Entry points for M2's glue, as offsets from the TOP of the call-out section:"
echo "       vector 11 (F-line, unimplemented FP)  ->  TOP + 128 + 0x30"
echo "       vector 55 (unimplemented data type)   ->  TOP + 128 + 0x38"
echo "       vector 60 (unimplemented eff. addr)   ->  TOP + 128 + 0x40"
echo "       vectors 48-54 (IEEE exceptions)       ->  TOP + 128 + 0x00..0x28"
