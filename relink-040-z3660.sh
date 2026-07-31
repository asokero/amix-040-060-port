#!/bin/sh
# relink-040-z3660.sh -- a 68040 kernel carrying the two Z3660 drivers, for a
# bench where the Z3660's own 68040 emulation is being developed (2026-07-31).
#
#   ~/kehitys/amix-z3660scsi   PISCSI mailbox SCSI   (z3660queue)
#   ~/kehitys/amix-z3660net    STREAMS/DLPI ethernet (z3660ethinfo -> zen0)
#
# Both upstream repos are SEPARATE PROJECTS and are never modified: their sources
# are copied into build/ by z3660_modelb.py, which converts the ONE thing that is
# wrong for us -- they target a 2 KiB-page kernel and inline phystopfn() as
# `pa >> 11`, which on Model B maps (pa>>11)<<12 = 2*pa, the WRONG physical page.
# See Z3660-KERNEL-FEASIBILITY-260731.md for the evidence and the wiring map.
#
# Registration (patch_z3660.py): a four-row scsicard[] table replacing the stock
# three, the cdevsw[48].d_str streamtab store from the parinit hook, and the
# dd.c completion-ordering island (their src/kernel-patches/dd.c.patch, which we
# can only apply as a relocation retarget because we have dd.c as a binary).
#
# NOT the standard kernel.  usage: sh relink-040-z3660.sh [base-kernel] [output]
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "/home/asokero/kehitys/amix-playground/gcc-cross-amix/build/env.sh"
V=/home/asokero/kehitys/amix-playground/vanilla

IN="${1:-$HERE/build/unix-040-dbg}"
OUT="${2:-$HERE/build/unix-040-z3660}"
[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
echo "[*] base: $(basename "$IN")"

echo "[*] Model-B source copies (phystopfn 2 KiB -> 4 KiB; page counts halved, bytes unchanged)"
python3 "$HERE/prototypes/z3660_modelb.py"

echo "[*] cross-compiling both drivers"
CF=$(echo "$AMIX_KERNEL_CFLAGS" | sed 's/-m68020/-m68040/')
m68k-cbm-sysv4-gcc $CF -I"$V/usr/sys/amiga/alien" -I"$HERE/build" \
	-c "$HERE/build/z3660_040.c"    -o "$HERE/build/z3660_040.o"
m68k-cbm-sysv4-gcc $CF -I"$V/usr/sys/amiga/alien" -I"$HERE/build" \
	-c "$HERE/build/z3660eth_040.c" -o "$HERE/build/z3660eth_040.o"

# Guard the conversion at the OBJECT level, not at the source level: the whole
# point of the geometry defect is that it is invisible in behaviour until it
# corrupts, so the shift is asserted in the compiled bytes.
# The signature is a shift BY 11, i.e. `moveq #11,%dN` immediately followed by an
# `lsrl %dN,...` -- not the constant 11 by itself: both drivers legitimately load
# 11 as a value (a SCSI CDB length compare; a DLPI constant written into a
# structure), and an over-eager grep on `moveq #11` fails on those.  Asserted in
# the compiled bytes because a wrong page shift is invisible until it corrupts.
for o in z3660_040 z3660eth_040; do
	if m68k-linux-gnu-objdump -d "$HERE/build/$o.o" | grep -A1 "moveq #11," | grep -q "lsrl"; then
		echo "[FAIL] $o.o still shifts by 11 (2 KiB PFN) -- z3660_modelb.py did not take"; exit 1
	fi
	m68k-linux-gnu-objdump -d "$HERE/build/$o.o" | grep -A1 "moveq #12," | grep -q "lsrl" \
		|| { echo "[FAIL] $o.o has no 4 KiB page shift at all -- phystopfn override missing?"; exit 1; }
done
echo "[OK] both driver objects shift by 12 (4 KiB PFN), none by 11"

echo "[*] assembling the registration glue"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/z3660_glue040.s" -o "$HERE/build/z3660_glue040.o"

# parinit is the io_init[] hook (same one the VA2000 driver uses, and for the same
# reason).  Weaken the stock one and expose it as parinit_orig so the glue can
# tail-jump to it.  PARINIT_ADDR is asserted, not assumed.
PARINIT_ADDR=0xfe6c
cp "$IN" "$HERE/build/unix-stage-z3660"
m68k-linux-gnu-objcopy \
	--weaken-symbol parinit \
	--add-symbol parinit_orig=.text:${PARINIT_ADDR},function,global \
	--globalize-symbol startio \
	"$HERE/build/unix-stage-z3660"

# ORDER MATTERS.  z3660eth_040.o's .text is 0x10f2 bytes -- not a multiple of 4,
# because the C compiler pads to 2 -- and the loader copies text+data as ONE block,
# so a .text whose total size is not 4-aligned leaves a 2-byte hole between them
# and the contiguity guard below (rightly) fails.  Every hand-written override in
# this tree ends its sections with `.balign 4` for the same reason; a compiled
# object cannot, so the glue -- which does -- is linked LAST and its trailing
# .balign 4 closes the gap.
echo "[*] ld -r: base + both drivers + glue (glue LAST: it carries the .balign 4)"
m68k-cbm-sysv4-ld -r -o "$OUT" "$HERE/build/unix-stage-z3660" \
	"$HERE/build/z3660_040.o" "$HERE/build/z3660eth_040.o" "$HERE/build/z3660_glue040.o"

echo "[*] symbols that must be defined:"
for s in z3660queue z3660present z3660ethinfo z3660_scsicard dd_startio_first parinit parinit_orig; do
	m68k-linux-gnu-nm "$OUT" | grep -E " [TtDdBb] $s\$" | sed "s/^/      /" \
		|| { echo "[FAIL] $s not defined"; exit 1; }
done
LEAK=$(m68k-linux-gnu-nm "$OUT" | awk '$1=="U" && $2!="edata" && $2!="end" && $2!="etext" {print $2}')
[ -z "$LEAK" ] || { echo "[FAIL] unresolved symbols:"; echo "$LEAK"; exit 1; }
echo "[OK] no unresolved symbols"

echo "[*] wiring (scsicard row + loop bound + dd.c ordering island)"
python3 "$HERE/prototypes/patch_z3660.py" "$OUT"

# The standard packaging guards -- same ones every other relink in this tree runs.
CONTIG=$(m68k-linux-gnu-readelf -SW "$OUT" | awk '
	{gsub(/[][]/,"")} $2==".text"{to=strtonum("0x"$5); ts=strtonum("0x"$6)}
	$2==".data"{do_=strtonum("0x"$5)} END{printf("%d %d", to+ts, do_)}')
set -- $CONTIG
[ "$1" = "$2" ] && echo "[OK] text/data contiguous." \
	|| { echo "[FAIL] text/data NOT contiguous"; exit 1; }
DSZ=$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".data"{print strtonum("0x"$6)}')
[ $((DSZ % 4)) -eq 0 ] && echo "[OK] .data size 0x$(printf %x $DSZ) is 4-aligned." \
	|| { echo "[FAIL] .data size not 4-aligned -> .bss misaligned at runtime"; exit 1; }
python3 "$HERE/prototypes/patch_b2_flip.py" "$OUT" --check | sed 's/^/      /'
( cd "$HERE" && python3 prototypes/check_relink_relocs.py "$OUT" | tail -1 )
python3 "$HERE/prototypes/stamp_buildid.py" "$OUT"

echo "[OK] built $OUT"
echo "     boot: unix_boot040 $(basename "$OUT")   <- unix_boot040 is MANDATORY"
echo "     nodes: mknod /dev/zen0 c 48 0     (ethernet; then slink + ifconfig)"
echo "     NOTE: with no Z3660 present, autocon() misses the board and z3660queue is"
echo "           never called -- the kernel is safe to boot on this A3000."
