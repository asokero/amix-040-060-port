#!/bin/sh
# build-ftest060.sh -- F3 M2b: build Motorola's own M68060 FPSP TEST suite as an AMIX user
# program, so the kernel FPSP can be judged by the vendor's yardstick and not only by ours.
#
# Source: dist/ftest.sa from the M68060 Software Package, as imported by NetBSD
# (sys/arch/m68k/060sp), the same tarball build-fpsp060.sh uses.  Unlike fpsp.S/pfpsp.S,
# NetBSD did NOT convert ftest.sa to GNU syntax -- it is still Motorola `dc.l $xxxxxxxx`.
# The conversion is mechanical and is done here rather than checked in, so the input stays
# the pristine vendor file.
#
# LAYOUT, and it is the same contract the kernel package has (test.doc):
#     [ 128-byte call-out section ]  test-tools/ftest060_head.s   (print_string/print_number)
#     [ ftest.sa image            ]  entry points at +0x00 / +0x08 / +0x10
#     [ AMIX call-outs + runner   ]  test-tools/ftest060_tail.s
# concatenated into ONE assembly unit, because the table entries are symbol differences.
#
# TWO TOOLCHAINS, on purpose:
#   * the image is assembled by m68k-linux-gnu-gcc, which is the only one of the three that
#     takes the package's syntax (and the one build-fpsp060.sh already trusts with it);
#   * the C main and the final link are m68k-cbm-sysv4-gcc, because the result has to be an
#     AMIX SVR4 executable.
# The two produce compatible m68k ELF objects -- the kernel relink already depends on that.
#
# Output: build/ftest060  (push to the guest and run: `ftest060 all`)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
TGZ="${1:-/home/asokero/kehitys/amix-playground/netbsd/syssrc.tgz}"
WORK="$HERE/build/ftest060-work"
SUB="usr/src/sys/arch/m68k/060sp"

[ -f "$TGZ" ] || { echo "ERROR: netbsd source tarball missing: $TGZ"; exit 1; }
command -v m68k-linux-gnu-gcc >/dev/null || { echo "ERROR: m68k-linux-gnu-gcc not on PATH"; exit 1; }

echo "[*] extracting $SUB/dist/ftest.sa"
rm -rf "$WORK"; mkdir -p "$WORK"
tar xzf "$TGZ" -C "$WORK" --exclude='*CVS*' "$SUB/dist/ftest.sa"
SA="$WORK/$SUB/dist/ftest.sa"

echo "[*] converting Motorola dc.l/\$ to GNU .long/0x"
sed -e 's/^#/|/' -e 's/dc\.l/.long/' -e 's/\$/0x/g' "$SA" > "$WORK/ftest_image.s"
# Assert the conversion produced data and nothing else survived as a directive we did not mean.
LONGS=$(grep -c '^	.long' "$WORK/ftest_image.s" || true)
[ "$LONGS" -gt 300 ] || { echo "[FAIL] only $LONGS .long lines after conversion"; exit 1; }
echo "      $LONGS .long lines"

echo "[*] concatenate head + image + tail"
SRC="$HERE/build/ftest060_pkg.s"
cat "$HERE/test-tools/ftest060_head.s" "$WORK/ftest_image.s" "$HERE/test-tools/ftest060_tail.s" > "$SRC"
m68k-linux-gnu-gcc -x assembler-with-cpp -m68060 -c "$SRC" -o "$HERE/build/ftest060_pkg.o"

TOP=$(m68k-linux-gnu-nm "$HERE/build/ftest060_pkg.o" | awk '$3=="ftest060_top"{print $1}')
IMG=$(m68k-linux-gnu-nm "$HERE/build/ftest060_pkg.o" | awk '$3=="ftest060_image"{print $1}')
[ "$TOP" = "00000000" ] || { echo "[FAIL] ftest060_top at 0x$TOP, must be 0"; exit 1; }
[ "$IMG" = "00000080" ] || { echo "[FAIL] ftest060_image at 0x$IMG, must be 0x80"; exit 1; }
echo "      ftest060_top = 0x$TOP, ftest060_image = 0x$IMG (table is exactly 128 bytes)"

# The three entry points must be bra.l into the image.  Decoded, not assumed -- this is the
# same risk the kernel package has: a wrong offset does not fail to link, it jumps into data.
echo "[*] decode the entry-point table"
m68k-linux-gnu-objcopy -O binary --only-section=.text "$HERE/build/ftest060_pkg.o" "$WORK/pkg.bin"
python3 - "$WORK/pkg.bin" <<-'PY'
	import sys
	b = open(sys.argv[1], 'rb').read()
	bad = 0
	for off, name in ((0x00, 'main'), (0x08, 'unimp'), (0x10, 'enabled')):
	    o = 128 + off
	    op = int.from_bytes(b[o:o+2], 'big')
	    tgt = o + 2 + int.from_bytes(b[o+2:o+6], 'big')
	    ok = op == 0x60ff and 128 < tgt < len(b)
	    print("      TOP+128+0x%02x -> 0x%05x  _060TESTS_%-8s %s"
	          % (off, tgt, name, "" if ok else "<-- NOT a bra.l into the image"))
	    bad += 0 if ok else 1
	if bad:
	    sys.exit("[FAIL] entry-point table is not where test.doc says")
	PY

echo "[*] compile main and link as an AMIX SVR4 executable"
. /home/asokero/kehitys/amix-playground/gcc-cross-amix/build/env.sh 2>/dev/null
m68k-cbm-sysv4-gcc -m68020 -m68881 -o "$HERE/build/ftest060" \
	"$HERE/test-tools/ftest060.c" "$HERE/build/ftest060_pkg.o"

file "$HERE/build/ftest060" 2>/dev/null || true
ls -l "$HERE/build/ftest060"
echo "[OK] build/ftest060 -- push to the guest and run: ftest060 all"
