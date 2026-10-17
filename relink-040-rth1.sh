#!/bin/sh
# relink-040-rth1.sh -- the kernel half of the RTH1 root hint (docs/contracts/RTH1-ROOT-HINT.md;
# 2026-10-05): one kernel per family that roots on the disk the boot loader names.
#
#   src/rth1.c            rth1_apply() reads the record at bootinfo+0x678 and sets rootdev and the
#                         controller digit of swapfile.bo_name together, or leaves both as linked;
#                         rth1_mountroot() = rth1_apply(); vfs_mountroot()
#   src/patch_rth1_hook.py  the one relocation of main's `jsr vfs_mountroot` -> rth1_mountroot
#   src/sdcardbase040.s   linked only when the base lacks sdcardbase (no a4091 pass), with sd's
#                         controller array exposed as sd_queue_tbl
#   src/rth1_tail040.s    the closing .balign 4
#
# Order: after every pass that registers a controller or adds sdcardbase (a4091, ide), before
# relink-040-fpe.sh, which is always the last link.  The chain of this line:
#   dd -> a3q -> z3660 -> monsw -> zz9000 -> a4091 -> ide -> cdfs -> rth1 -> fpe
# The base must still carry the root and swap name it was stamped with (c6d0s1 / c6d0s2 for the
# one-kernel families): they are the built-in root this pass falls back to.
#
# Gates: the exact import and export sets, no .rodata, no COMMON, no collision with the base,
# scan060 CLEAN (no division, no 64-bit multiply), the hook asserted and re-checked.
#
# usage: sh relink-040-rth1.sh [base-kernel] [output]
#   RTH1_BASE_SHA256=<hex>  refuse any base but that one
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tools/config-load.sh"
. "$HERE/tools/build-step.sh"

IN="${1:-$HERE/build/unix-040}"
OUT="${2:-$HERE/build/unix-040-rth1}"
[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
m68k-linux-gnu-readelf -h "$IN" >/dev/null 2>&1 || { echo "ERROR: $IN is not an ELF object"; exit 1; }
BASESHA=$(sha256sum "$IN" | cut -d' ' -f1)
echo "[*] base: $(basename "$IN")  (sha256 $BASESHA)"
[ -z "$RTH1_BASE_SHA256" ] || [ "$RTH1_BASE_SHA256" = "$BASESHA" ] \
	|| { echo "[FAIL] base sha256 $BASESHA is not the pinned $RTH1_BASE_SHA256"; exit 1; }

# ---------------------------------------------------------------- 0. the base's shape
NM_IN=$(m68k-linux-gnu-nm "$IN")
echo "$NM_IN" | grep -qE " [Tt] fpsp_vec11\$" \
	|| { echo "[FAIL] base does NOT carry FPSP -- not a finished relink-040.sh output"; exit 1; }
echo "$NM_IN" | grep -qE " [Tt] fpe_vec11\$" \
	&& { echo "[FAIL] base already carries the FPE -- this pass runs BEFORE relink-040-fpe.sh"; exit 1; }
echo "$NM_IN" | grep -qE " [Tt] rth1_mountroot\$" \
	&& { echo "[FAIL] base already has the RTH1 hook linked -- use a base without this pass"; exit 1; }
WEAK=$(echo "$NM_IN" | awk '$2 ~ /^[WwVv]$/ {print $3}')
[ -z "$WEAK" ] || { echo "[FAIL] $IN carries weak symbols -- a stage file, not a finished base"; exit 1; }
for s in bootinfo rootdev swapfile; do
	echo "$NM_IN" | grep -qE " D $s\$" || { echo "[FAIL] base has no global .data $s"; exit 1; }
done
SDCB=0
echo "$NM_IN" | grep -qE " T sdcardbase\$" && SDCB=1
echo "      sdcardbase: $([ $SDCB = 1 ] && echo "in the base (the a4091 pass)" || echo "absent -- linked here")"

# ---------------------------------------------------------------- 1. the compile and its gates
echo "[*] cross-compiling src/rth1.c (-m68040 dialect)"
CF=$(echo "$AMIX_KERNEL_CFLAGS" | sed 's/-m68020/-m68040/')
OBJ="$HERE/build/rth1.o"
m68k-cbm-sysv4-gcc $CF -c "$HERE/src/rth1.c" -o "$OBJ"
m68k-linux-gnu-size "$OBJ" | sed 's/^/      /'
M=$(m68k-linux-gnu-readelf -SW "$OBJ" | awk '{gsub(/[][]/,"")} $2 ~ /^\.rodata/ {print $2}')
[ -z "$M" ] || { echo "[FAIL] rth1.o carries $M -- the image has .text and .data only"; exit 1; }

echo "[*] 68060 instruction census (kernel mode: nothing emulates a hit)"
LC_ALL=C m68k-linux-gnu-objdump -d "$OBJ" > "$HERE/build/rth1.lst"
SCAN=$(python3 "$HERE/test-tools/scan060.py" "$HERE/build/rth1.lst")
SCANLINES=$(echo "$SCAN" | sed -n 's/.*(\([0-9][0-9]*\) decoded lines).*/\1/p')
[ -n "$SCANLINES" ] && [ "$SCANLINES" -gt 100 ] \
	|| { echo "[FAIL] scan060 decoded ${SCANLINES:-0} lines of rth1.lst -- not a listing it understood"; exit 1; }
echo "$SCAN" | grep -q 'CLEAN -- no candidate found' \
	|| { echo "[FAIL] scan060: rth1.o is not CLEAN"; echo "$SCAN"; exit 1; }
echo "      [OK]   scan060 CLEAN ($SCANLINES decoded lines)"

echo "[*] page geometry in the compiled bytes (no 2 KiB shift from the cross headers)"
run_step indent sh "$HERE/src/check_page_geometry.sh" "$OBJ"

echo "[*] imports and exports must be exactly these:"
WANT="bootinfo printf rootdev sdcardbase sdopen swapfile vfs_mountroot"
GOT=$(m68k-linux-gnu-nm "$OBJ" | awk '$1=="U"{print $2}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$GOT" = "$WANT" ] || { echo "[FAIL] unresolved set is: $GOT"; echo "       expected:          $WANT"; exit 1; }
WANTX="rth1_apply rth1_mountroot rth1_used rth1_why"
GOTX=$(m68k-linux-gnu-nm "$OBJ" | awk '$2 ~ /^[TDBC]$/{print $3}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$GOTX" = "$WANTX" ] || { echo "[FAIL] exported set is: $GOTX"; echo "       expected:        $WANTX"; exit 1; }
echo "      imports: $GOT"
echo "      exports: $GOTX"
COMMONS=$(m68k-linux-gnu-nm "$OBJ" | awk '$2=="C"{print $3}')
[ -z "$COMMONS" ] || { echo "[FAIL] rth1.o has COMMON symbols"; exit 1; }
DUP=$(for s in $GOTX; do echo "$NM_IN" | awk -v s="$s" 'NF==3 && $3==s{print s}'; done)
[ -z "$DUP" ] || { echo "[FAIL] rth1.o defines names the base already has: $DUP"; exit 1; }

echo "[*] assembling the closing object$([ $SDCB = 0 ] && echo " and sdcardbase")"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/rth1_tail040.s" -o "$HERE/build/rth1_tail040.o"
OBJS="$OBJ"
STAGE="$HERE/build/unix-stage-rth1"
cp "$IN" "$STAGE"
if [ $SDCB = 0 ]; then
	m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/sdcardbase040.s" -o "$HERE/build/sdcardbase040-rth1.o"
	QT=$(python3 "$HERE/src/patch_rth1_hook.py" --queue-tbl "$IN")
	echo "      sd's controller array: $QT"
	m68k-linux-gnu-objcopy --add-symbol "$QT" "$STAGE"
	OBJS="$OBJS $HERE/build/sdcardbase040-rth1.o"
fi

# ---------------------------------------------------------------- 2. the link
echo "[*] ld -r: base + rth1.o$([ $SDCB = 0 ] && echo " + sdcardbase040.o") + rth1_tail040.o (LAST: the .balign 4)"
m68k-cbm-sysv4-ld -r -o "$OUT" "$STAGE" $OBJS "$HERE/build/rth1_tail040.o"
NM_OUT=$(m68k-linux-gnu-nm "$OUT")
for s in $GOTX sdcardbase; do
	echo "$NM_OUT" | grep -qE " [TD] $s\$" || { echo "[FAIL] $s not a global definition in $OUT"; exit 1; }
done
LEAK=$(echo "$NM_OUT" | awk '$1=="U" && $2!="edata" && $2!="end" && $2!="etext" {print $2}')
[ -z "$LEAK" ] || { echo "[FAIL] unresolved symbols:"; echo "$LEAK"; exit 1; }
echo "[OK] no unresolved symbols"

# ---------------------------------------------------------------- 3. the hook
echo "[*] main's jsr vfs_mountroot -> rth1_mountroot"
run_step all python3 "$HERE/src/patch_rth1_hook.py" "$OUT"
run_step all python3 "$HERE/src/patch_rth1_hook.py" --check "$OUT"

# ---------------------------------------------------------------- 4. packaging guards
CONTIG=$(m68k-linux-gnu-readelf -SW "$OUT" | awk '
	{gsub(/[][]/,"")}
	$2==".text" {to=$5; ts=$6}
	$2==".data" {do_=$5}
	END{print to, ts, do_}')
set -- $CONTIG
TSZ=$(( 0x$2 ))
set -- $(( 0x$1 + 0x$2 )) $(( 0x$3 ))
[ "$1" = "$2" ] && echo "[OK] text/data contiguous." \
	|| { echo "[FAIL] text/data NOT contiguous"; exit 1; }
[ $((TSZ % 4)) -eq 0 ] && echo "[OK] .text size 0x$(printf %x $TSZ) is 4-aligned." \
	|| { echo "[FAIL] .text size not 4-aligned -- is rth1_tail040.o last in the link?"; exit 1; }
DSZ=$(( 0x$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".data"{print $6}') ))
[ $((DSZ % 4)) -eq 0 ] && echo "[OK] .data size 0x$(printf %x $DSZ) is 4-aligned." \
	|| { echo "[FAIL] .data size not 4-aligned -> .bss misaligned at runtime"; exit 1; }
run_step indent python3 "$HERE/src/patch_b2_flip.py" "$OUT" --check
run_step 1 python3 "$HERE/src/check_relink_relocs.py" "$OUT"
python3 "$HERE/src/stamp_buildid.py" "$OUT"

echo "[OK] built $OUT"
echo "     next:  relink-040-fpe.sh (always the last link)"
