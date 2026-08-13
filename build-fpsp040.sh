#!/bin/sh
# build-fpsp040.sh -- M1 of the FPU Tier-2 work: reproduce the Motorola 68040
# FPSP package BODY as a relocatable object our kernel relink can consume.
#
# Source: the freely-redistributable Motorola M68040 Floating-Point Software
# Package, as imported by NetBSD (sys/arch/m68k/fpsp) inside netbsd/syssrc.tgz.
# The Motorola copyright/modification notice (copyright.s) is linked into the
# object and MUST be retained (license condition).
#
# What this builds: the OS-INDEPENDENT package body only.  netbsd.sa (NetBSD's
# OS-adaptation layer) is deliberately EXCLUDED, so the result exports the 8
# fpsp_* exception entry points and leaves the 12 OS-glue symbols UNRESOLVED
# (fpsp_done, fpsp_fmt_error, mem_read, mem_write, real_{bsun,fline,inex,operr,
# ovfl,snan,trace,unfl}).  Those are implemented by the AMIX glue in M2
# (vector-11 dispatch, ureturn return path, copyin/copyout mem access) per
# analyysirepo vm-map/FPSP-INTEGRATION-PLAN.md.
#
# Toolchain: convert .sa->.s with the NetBSD asm2gas script, assemble with the
# GNU m68k toolchain (the CBM SysV4 assembler does not accept the generated
# GNU/MIT syntax), ld -r into one ELF object.  That object IS accepted by
# m68k-cbm-sysv4-ld -r for the kernel relink (asserted below).
#
# Output: build/fpsp040.o  (.text 0x9952 = 39250 bytes)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$(cd "$(dirname "$0")" && pwd)/tools/config-load.sh"
TGZ="${1:-$NETBSD_SYSSRC}"
WORK="$HERE/build/fpsp-work"
OUT="$HERE/build/fpsp040.o"
FPSP_SUB="usr/src/sys/arch/m68k/fpsp"

[ -f "$TGZ" ] || { echo "ERROR: netbsd source tarball missing: $TGZ"; exit 1; }
command -v m68k-linux-gnu-gcc >/dev/null || { echo "ERROR: m68k-linux-gnu-gcc not on PATH"; exit 1; }

echo "[*] extracting $FPSP_SUB from $(basename "$TGZ")"
rm -rf "$WORK"; mkdir -p "$WORK"
tar xzf "$TGZ" -C "$WORK" --exclude='*CVS*' "$FPSP_SUB"
FP="$WORK/$FPSP_SUB"
cd "$FP"

# Package-body members (Makefile O_FILES minus netbsd.o; copyright is already .s).
SA="bindec binstr decbin do_func gen_except get_op kernel_ex res_func round \
    sacos sasin satan satanh scosh setox sgetem sint slogn slog2 smovecr \
    srem_mod scale ssin ssinh stan stanh sto_res stwotox tbldo util \
    x_bsun x_fline x_operr x_ovfl x_snan x_store x_unfl x_unimp x_unsupp bugfix"

echo "[*] asm2gas: fpsp.h -> fpsp.defs"
SED=sed sh asm2gas fpsp.h > fpsp.defs

echo "[*] asm2gas: .sa -> .s  (+ assemble -x assembler-with-cpp -m68040)"
OBJS="copyright.o"
m68k-linux-gnu-gcc -x assembler-with-cpp -m68040 -I. -c copyright.s -o copyright.o
for f in $SA; do
	SED=sed sh asm2gas $f.sa > $f.s
	m68k-linux-gnu-gcc -x assembler-with-cpp -m68040 -I. -c $f.s -o $f.o
	OBJS="$OBJS $f.o"
done

echo "[*] ld -r -> $(basename "$OUT")"
m68k-linux-gnu-ld -r -o "$OUT" $OBJS

# ---- assertions (M1 acceptance) ----
TSZ=$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".text"{print $6}')
[ "$TSZ" = "009952" ] || { echo "[FAIL] .text size 0x$TSZ != 0x9952 (39250)"; exit 1; }
echo "[OK] .text = 0x9952 (39250 bytes)"

for s in fpsp_bsun fpsp_fline fpsp_operr fpsp_ovfl fpsp_snan fpsp_unfl fpsp_unimp fpsp_unsupp; do
	m68k-linux-gnu-nm "$OUT" | grep -qE " T $s\$" || { echo "[FAIL] entry $s not defined"; exit 1; }
done
echo "[OK] 8 fpsp_* entry points defined"

UND=$(m68k-linux-gnu-nm "$OUT" | grep -c ' U ')
echo "[OK] $UND unresolved OS-glue symbols (expect 12; provided by M2):"
m68k-linux-gnu-nm "$OUT" | grep ' U ' | sed 's/^/      /'
[ "$UND" = "12" ] || { echo "[FAIL] expected 12 unresolved, got $UND"; exit 1; }

# relink compatibility: the kernel's SysV4 ld must accept this object
( . $GCC_CROSS_ENV 2>/dev/null
  m68k-cbm-sysv4-ld -r -o "$HERE/build/fpsp-cbmcheck.o" "$OUT" ) \
	&& echo "[OK] m68k-cbm-sysv4-ld -r accepts fpsp040.o (kernel-relink compatible)" \
	|| { echo "[FAIL] m68k-cbm-sysv4-ld rejects fpsp040.o"; exit 1; }
rm -f "$HERE/build/fpsp-cbmcheck.o"

echo "[OK] M1 complete -- build/fpsp040.o  sha256:"
sha256sum "$OUT"
