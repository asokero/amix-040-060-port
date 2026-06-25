#!/bin/sh
# relink-030-dbg.sh -- 030 BASELINE reference trace.
#
# Builds the STOCK 68030 kernel (vanilla/stand/unix) with the serial conputc hook + the SAME
# exec/lookup direct markers as the 040 dbg build (execmark.s), so a HEALTHY boot prints the
# exact, correct order of E/L/c/n/k/i/B/D/G/F/V/X.  Comparing that reference against the 040
# boot (which hangs at E/L) pins exactly which step diverges and on which FS path (s5 dirlook/
# iget vs ufs_lookup).  NO 040 patches, NO scheduler overrides -- just serial + markers.
#
# The marker _orig alias addresses are taken straight from vanilla/stand/unix (== the stock 030
# kernel), so they are correct here by construction.  serdbg_mark comes from the STANDALONE
# serdbg_mark.o (NOT mainmarks.o, whose resume040/sched overrides are 040-only).
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
IN="/home/asokero/kehitys/amix-playground/vanilla/stand/unix"
ENV="/home/asokero/kehitys/amix-playground/gcc-cross-amix/build/env.sh"
. "$ENV"

[ -f "$IN" ] || { echo "ERROR: stock kernel $IN missing"; exit 1; }

echo "[*] assembling serial hook + standalone serdbg_mark + exec/lookup markers"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/serdbg.s"       -o "$HERE/build/serdbg.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/serdbg_mark.s"  -o "$HERE/build/serdbg_mark.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/execmark.s"     -o "$HERE/build/execmark.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/asfault_probe.s" -o "$HERE/build/asfault_probe.o"

echo "[*] weaken conputc + all marker targets; add _orig aliases (addrs from stock unix)"
cp "$IN" "$HERE/build/unix-030-dbg-stage1"
m68k-linux-gnu-objcopy \
	--weaken-symbol conputc \
	--add-symbol exece_orig=.text:0x56444,function,global          --weaken-symbol exece \
	--add-symbol gexec_orig=.text:0x576c0,function,global          --weaken-symbol gexec \
	--add-symbol elfexec_orig=.text:0xb80f2,function,global        --weaken-symbol elfexec \
	--add-symbol relvm_orig=.text:0x419b4,function,global          --weaken-symbol relvm \
	--add-symbol setregs_orig=.text:0x58b62,function,global        --weaken-symbol setregs \
	--add-symbol lookuppn_orig=.text:0x5c2ea,function,global       --weaken-symbol lookuppn \
	--add-symbol bread_orig=.text:0x3c154,function,global          --weaken-symbol bread \
	--add-symbol biodone_orig=.text:0x3ce3a,function,global        --weaken-symbol biodone \
	--add-symbol pn_getcomponent_orig=.text:0x5c952,function,global --weaken-symbol pn_getcomponent \
	--add-symbol dnlc_lookup_orig=.text:0x5b89a,function,global    --weaken-symbol dnlc_lookup \
	--add-symbol dirlook_orig=.text:0x6dbe0,function,global        --weaken-symbol dirlook \
	--add-symbol iget_orig=.text:0x6f724,function,global           --weaken-symbol iget \
	--add-symbol copyinstr_orig=.text:0x43ef4,function,global       --weaken-symbol copyinstr \
	--add-symbol u_trap_orig=.text:0x5a47e,function,global         --weaken-symbol u_trap \
	--add-symbol exhd_getmap_orig=.text:0x5704e,function,global    --weaken-symbol exhd_getmap \
	--add-symbol as_fault_orig=.text:0xae108,function,global       --weaken-symbol as_fault \
	"$HERE/build/unix-030-dbg-stage1"

OUT="$HERE/build/unix-030-dbg"
echo "[*] relinking -> $OUT"
m68k-cbm-sysv4-ld -r -o "$OUT" "$HERE/build/unix-030-dbg-stage1" \
	"$HERE/build/serdbg.o" "$HERE/build/serdbg_mark.o" "$HERE/build/asfault_probe.o"

# text/data contiguity (loader copies them as one block)
CONTIG=$(m68k-linux-gnu-readelf -SW "$OUT" 2>/dev/null | awk '
	{gsub(/[][]/,"")}
	$2==".text" {to=strtonum("0x"$5); ts=strtonum("0x"$6)}
	$2==".data" {do_=strtonum("0x"$5)}
	END{printf("%d %d", to+ts, do_)}')
set -- $CONTIG
if [ "$1" = "$2" ]; then echo "[OK] text/data contiguous."
else echo "[FAIL] text/data NOT contiguous: text_end=0x$(printf %x $1) data_off=0x$(printf %x $2)"; exit 1; fi

echo "[*] override defs (each ONE strong T in overlay region, _orig = stock low addr):"
m68k-linux-gnu-nm "$OUT" | grep -E " (exece|lookuppn|bread|conputc)$" | sed 's/^/      /'
echo "[*] UND leaks (should be none):"
m68k-linux-gnu-nm "$OUT" | grep ' U ' | grep -iE 'serdbg_mark|coputc|exece|lookuppn' | sed 's/^/      LEAK: /' || echo "      (none)"

echo
echo "[OK] built $OUT -- boot the STOCK 030 loader against it for the healthy reference trace."
