#!/bin/sh
# relink-040-isp060.sh -- OPT-IN: Motorola's M68060 Integer Support Package behind isp61
# (DRIVER-LINE-9; 2026-10-06).  Not part of any default chain.
#
#   build-isp060.sh            build/isp060_pkg.o = src/isp060_head.s + 060sp/isp.S + src/isp060_glue.s
#   src/patch_isp060_hook.py   isp61_vec's one `jmp nullvect` (every decline) -> isp060_unimp
#
# Vector 61 still enters isp61_vec, the hardware-measured fast path for the 64-bit multiplies the
# userland uses; what it declines now reaches the package (64-bit divides with vector-5 zero
# divide, the other multiply forms, movep, cmp2/chk2; cas/cas2 are terminated, see the glue)
# instead of nullvect.
#
# Order: after relink-040.sh (isp61 and the FPSP are in the base), before relink-040-fpe.sh, which
# is always the last link.  For the r6 chain of this line:
#   dd -> z3660 -> f4arms -> f6 -> monsw -> zz9000 -> rth1 -> ttcompat -> [pgrsv] -> isp060 -> fpe
#
# Gates: the package's entry table (build-isp060.sh), the exact import set, no collision with the
# base, scan060 of the package with exactly its one known data false positive, the hook asserted
# and re-checked.
#
# usage: sh relink-040-isp060.sh [base-kernel] [output]
#   ISP060_BASE_SHA256=<hex>  refuse any base but that one
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tools/config-load.sh"
. "$HERE/tools/build-step.sh"

IN="${1:-$HERE/build/unix-040}"
OUT="${2:-$HERE/build/unix-040-isp060}"
[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
m68k-linux-gnu-readelf -h "$IN" >/dev/null 2>&1 || { echo "ERROR: $IN is not an ELF object"; exit 1; }
BASESHA=$(sha256sum "$IN" | cut -d' ' -f1)
echo "[*] base: $(basename "$IN")  (sha256 $BASESHA)"
[ -z "$ISP060_BASE_SHA256" ] || [ "$ISP060_BASE_SHA256" = "$BASESHA" ] \
	|| { echo "[FAIL] base sha256 $BASESHA is not the pinned $ISP060_BASE_SHA256"; exit 1; }

# ---------------------------------------------------------------- 0. the base's shape
NM_IN=$(m68k-linux-gnu-nm "$IN")
echo "$NM_IN" | grep -qE " [Tt] fpsp060_top\$" \
	|| { echo "[FAIL] base does NOT carry the 68060 FPSP -- not a finished relink-040.sh output"; exit 1; }
echo "$NM_IN" | grep -qE " [Tt] fpe_vec11\$" \
	&& { echo "[FAIL] base already carries the FPE -- this pass runs BEFORE relink-040-fpe.sh"; exit 1; }
echo "$NM_IN" | grep -qE " [Tt] isp060_top\$" \
	&& { echo "[FAIL] base already has the ISP linked -- use a base without this pass"; exit 1; }
echo "$NM_IN" | grep -qE " T isp61_vec\$" || { echo "[FAIL] base has no isp61_vec"; exit 1; }
WEAK=$(echo "$NM_IN" | awk '$2 ~ /^[WwVv]$/ {print $3}')
[ -z "$WEAK" ] || { echo "[FAIL] $IN carries weak symbols -- a stage file, not a finished base"; exit 1; }

# ---------------------------------------------------------------- 1. the package and its gates
echo "[*] build-isp060.sh"
run_step indent sh "$HERE/build-isp060.sh"
PKG="$HERE/build/isp060_pkg.o"
echo "[*] 68060 instruction census of the package"
LC_ALL=C m68k-linux-gnu-objdump -d "$PKG" > "$HERE/build/isp060_pkg.lst"
SCAN=$(python3 "$HERE/test-tools/scan060.py" "$HERE/build/isp060_pkg.lst")
SCANLINES=$(echo "$SCAN" | sed -n 's/.*(\([0-9][0-9]*\) decoded lines).*/\1/p')
[ -n "$SCANLINES" ] && [ "$SCANLINES" -gt 2000 ] \
	|| { echo "[FAIL] scan060 decoded ${SCANLINES:-0} lines -- not a listing it understood"; exit 1; }
# The one known hit is data: the word 0x010a inside the image's 16-bit offset table at package
# .text 0x5e4 (neighbours 0x00ec, 0x0128, 0x0146 are offsets too), decoded as `movepw`.
HITS=$(echo "$SCAN" | grep -cE '^ +[0-9a-f]+ ' || true)
echo "$SCAN" | grep -qE '^ +5e4 +movepw ' && [ "$HITS" = "1" ] \
	|| { echo "[FAIL] scan060: expected exactly the known data hit at 0x5e4"; echo "$SCAN"; exit 1; }
python3 - "$PKG" <<-'PY'
	import subprocess, sys
	b = subprocess.run(['m68k-linux-gnu-objcopy', '-O', 'binary', '--only-section=.text', sys.argv[1], '/dev/stdout'],
	                   capture_output=True).stdout
	want = bytes.fromhex('00ec010a01280146')
	if b[0x5e2:0x5ea] != want:
	    sys.exit("[FAIL] the bytes around 0x5e4 are %s, not the offset table %s" % (b[0x5e2:0x5ea].hex(), want.hex()))
	PY
echo "      [OK]   scan060: the one known data hit (offset table word at 0x5e4), $SCANLINES decoded lines"

echo "[*] imports must be exactly these, and all present in the base:"
WANT="copyin copyout cputype nullvect panic sup_cacr ureturn"
GOT=$(m68k-linux-gnu-nm "$PKG" | awk '$1=="U"{print $2}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$GOT" = "$WANT" ] || { echo "[FAIL] unresolved set is: $GOT"; echo "       expected:          $WANT"; exit 1; }
for s in $WANT; do
	echo "$NM_IN" | awk -v s="$s" 'NF==3 && $3==s && $2 ~ /^[TDBC]$/ {f=1} END{exit !f}' \
		|| { echo "[FAIL] the base does not define $s"; exit 1; }
done
echo "      imports: $GOT"
EXPS=$(m68k-linux-gnu-nm "$PKG" | awk '$2 ~ /^[TDB]$/{print $3}')
DUP=$(for s in $EXPS; do echo "$NM_IN" | awk -v s="$s" 'NF==3 && $3==s{print s}'; done)
[ -z "$DUP" ] || { echo "[FAIL] the base already defines: $DUP"; exit 1; }

# ---------------------------------------------------------------- 2. the link
echo "[*] ld -r: base + isp060_pkg.o"
m68k-cbm-sysv4-ld -r -o "$OUT" "$IN" "$PKG"
NM_OUT=$(m68k-linux-gnu-nm "$OUT")
for s in isp060_top isp060_unimp i60_magic; do
	echo "$NM_OUT" | grep -qE " [TD] $s\$" || { echo "[FAIL] $s not a global definition in $OUT"; exit 1; }
done
LEAK=$(echo "$NM_OUT" | awk '$1=="U" && $2!="edata" && $2!="end" && $2!="etext" {print $2}')
[ -z "$LEAK" ] || { echo "[FAIL] unresolved symbols:"; echo "$LEAK"; exit 1; }
echo "[OK] no unresolved symbols"

# ---------------------------------------------------------------- 3. the hook
echo "[*] isp61_vec's declines -> isp060_unimp"
run_step all python3 "$HERE/src/patch_isp060_hook.py" "$OUT"
run_step all python3 "$HERE/src/patch_isp060_hook.py" --check "$OUT"

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
	|| { echo "[FAIL] .text size not 4-aligned"; exit 1; }
DSZ=$(( 0x$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".data"{print $6}') ))
[ $((DSZ % 4)) -eq 0 ] && echo "[OK] .data size 0x$(printf %x $DSZ) is 4-aligned." \
	|| { echo "[FAIL] .data size not 4-aligned -> .bss misaligned at runtime"; exit 1; }
run_step indent python3 "$HERE/src/patch_b2_flip.py" "$OUT" --check
run_step 1 python3 "$HERE/src/check_relink_relocs.py" "$OUT"
python3 "$HERE/src/stamp_buildid.py" "$OUT"

echo "[OK] built $OUT"
echo "     next:  relink-040-fpe.sh (always the last link)"
