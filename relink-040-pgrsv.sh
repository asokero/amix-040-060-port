#!/bin/sh
# relink-040-pgrsv.sh -- OPT-IN: a free-page reserve in front of page_get (DRIVER-LINE-8; 2026-10-06).
# Not part of any default chain.  Closes the low-memory deadlock where pageout sleeps on freemem
# waiting for the buffer its own page push needs (the I3 install hang, 32 MB rig).
#
#   src/pgrsv.c              pgrsv_get(): ordinary callers wait (or fail, if they may not wait) until
#                            pgrsv_pages pages would remain, then call page_get -- SVR4.2's minpagefree
#   src/patch_pgrsv_sites.py every `jsr page_get` but segkmem_alloc's and page_delmem's -> pgrsv_get
#                            (relocation words only); page_get's two file-statics exposed as aliases
#   src/pgrsv_tail040.s      the closing .balign 4
#
# Order: anywhere after the passes that link page_get callers of their own (none today), before
# relink-040-fpe.sh, which is always the last link.  For the r6 chain of this line:
#   dd -> z3660 -> f4arms -> f6 -> monsw -> zz9000 -> rth1 -> ttcompat -> pgrsv -> fpe
#
# Gates: the exact import and export sets, no .rodata, no COMMON, no collision with the base,
# scan060 CLEAN, both SR writes present, the call sites asserted and re-checked.
#
# usage: sh relink-040-pgrsv.sh [base-kernel] [output]
#   PGRSV_BASE_SHA256=<hex>  refuse any base but that one
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tools/config-load.sh"
. "$HERE/tools/build-step.sh"

IN="${1:-$HERE/build/unix-040}"
OUT="${2:-$HERE/build/unix-040-pgrsv}"
[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
m68k-linux-gnu-readelf -h "$IN" >/dev/null 2>&1 || { echo "ERROR: $IN is not an ELF object"; exit 1; }
BASESHA=$(sha256sum "$IN" | cut -d' ' -f1)
echo "[*] base: $(basename "$IN")  (sha256 $BASESHA)"
[ -z "$PGRSV_BASE_SHA256" ] || [ "$PGRSV_BASE_SHA256" = "$BASESHA" ] \
	|| { echo "[FAIL] base sha256 $BASESHA is not the pinned $PGRSV_BASE_SHA256"; exit 1; }

# ---------------------------------------------------------------- 0. the base's shape
NM_IN=$(m68k-linux-gnu-nm "$IN")
echo "$NM_IN" | grep -qE " [Tt] fpsp_vec11\$" \
	|| { echo "[FAIL] base does NOT carry FPSP -- not a finished relink-040.sh output"; exit 1; }
echo "$NM_IN" | grep -qE " [Tt] fpe_vec11\$" \
	&& { echo "[FAIL] base already carries the FPE -- this pass runs BEFORE relink-040-fpe.sh"; exit 1; }
echo "$NM_IN" | grep -qE " [Tt] pgrsv_get\$" \
	&& { echo "[FAIL] base already has the reserve linked -- use a base without this pass"; exit 1; }
WEAK=$(echo "$NM_IN" | awk '$2 ~ /^[WwVv]$/ {print $3}')
[ -z "$WEAK" ] || { echo "[FAIL] $IN carries weak symbols -- a stage file, not a finished base"; exit 1; }
echo "$NM_IN" | grep -qE " T page_get\$" || { echo "[FAIL] base has no global page_get"; exit 1; }

# ---------------------------------------------------------------- 1. the compile and its gates
echo "[*] cross-compiling src/pgrsv.c (-m68040 dialect)"
CF=$(echo "$AMIX_KERNEL_CFLAGS" | sed 's/-m68020/-m68040/')
OBJ="$HERE/build/pgrsv.o"
m68k-cbm-sysv4-gcc $CF -c "$HERE/src/pgrsv.c" -o "$OBJ"
m68k-linux-gnu-size "$OBJ" | sed 's/^/      /'
M=$(m68k-linux-gnu-readelf -SW "$OBJ" | awk '{gsub(/[][]/,"")} $2 ~ /^\.rodata/ {print $2}')
[ -z "$M" ] || { echo "[FAIL] pgrsv.o carries $M -- the image has .text and .data only"; exit 1; }

echo "[*] 68060 instruction census (kernel mode: nothing emulates a hit)"
LC_ALL=C m68k-linux-gnu-objdump -d "$OBJ" > "$HERE/build/pgrsv.lst"
SCAN=$(python3 "$HERE/test-tools/scan060.py" "$HERE/build/pgrsv.lst")
SCANLINES=$(echo "$SCAN" | sed -n 's/.*(\([0-9][0-9]*\) decoded lines).*/\1/p')
[ -n "$SCANLINES" ] && [ "$SCANLINES" -gt 50 ] \
	|| { echo "[FAIL] scan060 decoded ${SCANLINES:-0} lines of pgrsv.lst -- not a listing it understood"; exit 1; }
echo "$SCAN" | grep -q 'CLEAN -- no candidate found' \
	|| { echo "[FAIL] scan060: pgrsv.o is not CLEAN"; echo "$SCAN"; exit 1; }
echo "      [OK]   scan060 CLEAN ($SCANLINES decoded lines)"
# -traditional can drop an asm it thinks dead (T-9): both SR writes must be in the object.
NSR=$(grep -c 'movew %d[0-7],%sr\|movew #9216,%sr' "$HERE/build/pgrsv.lst" || true)
[ "$NSR" -ge 2 ] || { echo "[FAIL] pgrsv.o carries $NSR SR writes, want the splimp and the splx"; exit 1; }

echo "[*] page geometry in the compiled bytes (no 2 KiB shift from the cross headers)"
run_step indent sh "$HERE/src/check_page_geometry.sh" "$OBJ"

echo "[*] imports and exports must be exactly these:"
WANT="bclnlist cleanup curproc freemem page_get pgrsv_fmw pgrsv_mpg proc_pageout proc_sched sleep wakeprocs"
GOT=$(m68k-linux-gnu-nm "$OBJ" | awk '$1=="U"{print $2}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$GOT" = "$WANT" ] || { echo "[FAIL] unresolved set is: $GOT"; echo "       expected:          $WANT"; exit 1; }
WANTX="pgrsv_calls pgrsv_fails pgrsv_get pgrsv_magic pgrsv_pages pgrsv_waits"
GOTX=$(m68k-linux-gnu-nm "$OBJ" | awk '$2 ~ /^[TDBC]$/{print $3}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$GOTX" = "$WANTX" ] || { echo "[FAIL] exported set is: $GOTX"; echo "       expected:        $WANTX"; exit 1; }
echo "      imports: $GOT"
echo "      exports: $GOTX"
COMMONS=$(m68k-linux-gnu-nm "$OBJ" | awk '$2=="C"{print $3}')
[ -z "$COMMONS" ] || { echo "[FAIL] pgrsv.o has COMMON symbols"; exit 1; }
DUP=$(for s in $GOTX pgrsv_fmw pgrsv_mpg; do echo "$NM_IN" | awk -v s="$s" 'NF==3 && $3==s{print s}'; done)
[ -z "$DUP" ] || { echo "[FAIL] the base already defines: $DUP"; exit 1; }

echo "[*] page_get's file-statics, located by the instructions that use them"
STAGE="$HERE/build/unix-stage-pgrsv"
cp "$IN" "$STAGE"
for a in $(python3 "$HERE/src/patch_pgrsv_sites.py" --aliases "$IN"); do
	echo "      $a"
	m68k-linux-gnu-objcopy --add-symbol "$a" "$STAGE"
done
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/pgrsv_tail040.s" -o "$HERE/build/pgrsv_tail040.o"

# ---------------------------------------------------------------- 2. the link
echo "[*] ld -r: base + pgrsv.o + pgrsv_tail040.o (LAST: the .balign 4)"
m68k-cbm-sysv4-ld -r -o "$OUT" "$STAGE" "$OBJ" "$HERE/build/pgrsv_tail040.o"
NM_OUT=$(m68k-linux-gnu-nm "$OUT")
for s in $GOTX; do
	echo "$NM_OUT" | grep -qE " [TD] $s\$" || { echo "[FAIL] $s not a global definition in $OUT"; exit 1; }
done
LEAK=$(echo "$NM_OUT" | awk '$1=="U" && $2!="edata" && $2!="end" && $2!="etext" {print $2}')
[ -z "$LEAK" ] || { echo "[FAIL] unresolved symbols:"; echo "$LEAK"; exit 1; }
echo "[OK] no unresolved symbols"

# ---------------------------------------------------------------- 3. the call sites
echo "[*] page_get's ordinary callers -> pgrsv_get"
run_step all python3 "$HERE/src/patch_pgrsv_sites.py" "$OUT"
run_step all python3 "$HERE/src/patch_pgrsv_sites.py" --check "$OUT"

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
	|| { echo "[FAIL] .text size not 4-aligned -- is pgrsv_tail040.o last in the link?"; exit 1; }
DSZ=$(( 0x$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".data"{print $6}') ))
[ $((DSZ % 4)) -eq 0 ] && echo "[OK] .data size 0x$(printf %x $DSZ) is 4-aligned." \
	|| { echo "[FAIL] .data size not 4-aligned -> .bss misaligned at runtime"; exit 1; }
run_step indent python3 "$HERE/src/patch_b2_flip.py" "$OUT" --check
run_step 1 python3 "$HERE/src/check_relink_relocs.py" "$OUT"
python3 "$HERE/src/stamp_buildid.py" "$OUT"

echo "[OK] built $OUT"
echo "     next:  relink-040-fpe.sh (always the last link)"
