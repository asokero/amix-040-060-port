#!/bin/sh
# build-isp060.sh -- DRIVER-LINE-9 (opt-in): Motorola's M68060 Integer Support Package as one
# relocatable object the kernel relink can consume: build/isp060_pkg.o.
#
# Source: the freely-redistributable M68060 Software Package as imported by NetBSD
# (sys/arch/m68k/060sp/isp.S, the isp.sa hex image in GNU syntax) inside the pinned syssrc.tgz --
# the same tarball and the same pin as build-fpsp060.sh.  The licence notice (copyright.S) is
# linked in and MUST be retained.
#
# Like the FPSP, the ISP is ADDRESS-based: no symbols, entry points at fixed offsets from the top
# of the image, OS call-outs through a 128-byte table placed immediately before it.  So:
#     src/isp060_head.s + 060sp/isp.S + src/isp060_glue.s
# are concatenated and assembled as ONE unit, and the entry table is decoded from the result every
# build: a wrong offset does not fail to link -- it jumps into the middle of the package.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tools/config-load.sh"
. "$HERE/tools/netbsd-pin.sh"
TGZ="${1:-$NETBSD_SYSSRC}"
WORK="$HERE/build/isp060-work"
SUB="usr/src/sys/arch/m68k/060sp"
command -v m68k-linux-gnu-gcc >/dev/null || { echo "ERROR: m68k-linux-gnu-gcc not on PATH"; exit 1; }

echo "[*] checking $(basename "$TGZ") against the pin"
netbsd_syssrc_verify "$TGZ"
rm -rf "$WORK"; mkdir -p "$WORK"
tar xzf "$TGZ" -C "$WORK" --exclude='*CVS*' "$SUB/isp.S" "$SUB/copyright.S"
SP="$WORK/$SUB"

echo "[*] the image alone: size and interface"
m68k-linux-gnu-gcc -x assembler-with-cpp -m68060 -c "$SP/isp.S" -o "$WORK/isp-image.o"
TSZ=$(m68k-linux-gnu-readelf -SW "$WORK/isp-image.o" | awk '{gsub(/[][]/,"")} $2==".text"{print $6}')
[ "$TSZ" = "001880" ] || { echo "[FAIL] isp image .text 0x$TSZ != 0x001880 (the measured package)"; exit 1; }
UND=$(m68k-linux-gnu-nm "$WORK/isp-image.o" | grep -c ' U ' || true)
[ "$UND" = "0" ] || { echo "[FAIL] isp image: expected 0 unresolved symbols, got $UND"; exit 1; }
echo "      image .text = 0x$TSZ, 0 unresolved symbols (address-based interface)"

PKGSRC="$HERE/build/isp060_pkg.s"
PKGOBJ="$HERE/build/isp060_pkg.o"
echo "[*] concatenate head + isp.S + glue -> $(basename "$PKGSRC"); then copyright.S after it"
cat "$HERE/src/isp060_head.s" "$SP/isp.S" "$HERE/src/isp060_glue.s" > "$PKGSRC"
m68k-linux-gnu-gcc -x assembler-with-cpp -m68060 -c "$PKGSRC" -o "$WORK/isp060_body.o"
m68k-linux-gnu-gcc -x assembler-with-cpp -m68060 -c "$SP/copyright.S" -o "$WORK/copyright060.o"
m68k-linux-gnu-ld -r -o "$PKGOBJ" "$WORK/isp060_body.o" "$WORK/copyright060.o"

TOP=$(m68k-linux-gnu-nm "$PKGOBJ" | awk '$3=="isp060_top"{print $1}')
IMG=$(m68k-linux-gnu-nm "$PKGOBJ" | awk '$3=="isp060_image"{print $1}')
[ "$TOP" = "00000000" ] || { echo "[FAIL] isp060_top at 0x$TOP, must be 0"; exit 1; }
[ "$IMG" = "00000080" ] || { echo "[FAIL] isp060_image at 0x$IMG, must be 0x80 (table = 128 B)"; exit 1; }
echo "      isp060_top = 0x$TOP, isp060_image = 0x$IMG (table is exactly 128 bytes)"

echo "[*] decode the entry-point table THROUGH the call-out section"
m68k-linux-gnu-objcopy -O binary --only-section=.text "$PKGOBJ" "$WORK/pkg.bin"
python3 - "$WORK/pkg.bin" "$((0x$TSZ))" <<-'PY'
	import sys
	b = open(sys.argv[1], 'rb').read()
	isz = int(sys.argv[2])
	bad = 0
	for i in range(32):
	    v = int.from_bytes(b[i*4:i*4+4], 'big')
	    if not (128 + isz <= v < len(b)):
	        print("      [FAIL] call-out slot %d = 0x%08x is not in the glue" % (i, v))
	        bad += 1
	print("      32 call-out slots all point into the glue (past the image)")
	names = ['unimp', 'cas', 'cas2', 'cas_finish', 'cas2_finish', 'cas_inrange', 'cas_terminate',
	         'cas_restart']
	for i, n in enumerate(names):
	    o = 128 + i * 8
	    op = int.from_bytes(b[o:o+2], 'big')
	    tgt = o + 2 + int.from_bytes(b[o+2:o+6], 'big', signed=True)
	    ok = op == 0x60ff and 128 < tgt < 128 + isz
	    print("      TOP+128+0x%02x -> 0x%05x  _060_isp_%-13s %s"
	          % (i * 8, tgt, n, "" if ok else "<-- NOT a bra.l into the image"))
	    bad += 0 if ok else 1
	if bad:
	    sys.exit("[FAIL] packaged layout is wrong")
	PY

for s in isp060_unimp i60_magic i60_entry_n i60_done_n i60_dbz_n; do
	m68k-linux-gnu-nm "$PKGOBJ" | grep -qE " [A-Za-z] $s\$" || { echo "[FAIL] $s not defined"; exit 1; }
done
UND=$(m68k-linux-gnu-nm "$PKGOBJ" | awk '$1=="U"{print $2}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
WANT="copyin copyout cputype nullvect panic sup_cacr ureturn"
[ "$UND" = "$WANT" ] || { echo "[FAIL] unresolved: $UND"; echo "       want:       $WANT"; exit 1; }
echo "      unresolved (the kernel supplies these): $UND"
( m68k-cbm-sysv4-ld -r -o "$WORK/cbmcheck.o" "$PKGOBJ" ) \
	&& echo "      m68k-cbm-sysv4-ld -r accepts $(basename "$PKGOBJ")" \
	|| { echo "[FAIL] m68k-cbm-sysv4-ld rejects $(basename "$PKGOBJ")"; exit 1; }
echo "[OK] built $PKGOBJ  ($(m68k-linux-gnu-size "$PKGOBJ" | awk 'NR==2{print "text " $1 ", data " $2}'))"
