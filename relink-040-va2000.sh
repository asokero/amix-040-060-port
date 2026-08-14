#!/bin/sh
# relink-040-va2000.sh -- EXPERIMENTAL: build an 040 kernel carrying BOTH
#   (a) the Motorola 68040 FPSP + AMIX glue (M1/M2/M4) -- the XRTG X11 server
#       is compiled natively by `cc` on AMIX, which emits fmovecr/fintrz that
#       the 68040 does not implement in hardware; without FPSP it crashes/traps.
#   (b) the MNT VA2000 RTG graphics driver (major 68, /dev/va2000), so the
#       user's XRTG server and wolf3d (both open /dev/va2000 and mmap it) can
#       be tested on the real Amiga 3000 + VA2000 board.
#
# NOT the standard kernel. VA2000 is NOT emulatable in Amiberry -- the
# emulator smoke test can only prove "boots clean, no board found, FPU intact".
# Real hardware validation is the user's job on the A3000.
#
# Driver source: ~/kehitys/va2000-amix/src/va2000.c (SEPARATE repo, untouched
# by this script). va2000_modelb.py copies it into build/ and converts the
# ONE 2 KiB-page phystopfn shift (va2000mmap, >>11) to the 4 KiB Model-B shift
# (>>12) that this kernel's device-mmap handlers all use (see
# patch_devmmap_pfn.py / patch_xsvga.py for the same class of fix elsewhere).
#
# io_init[] = { parinit, 0 } has no spare relocation to retarget to
# va2000init, so va2000init is invoked from a `parinit` WRAPPER instead
# (src/parinit_va2000.s): weaken the base's strong `parinit`,
# add-symbol parinit_orig at its known address, ld -r in a new strong
# `parinit` that calls va2000init() then tail-jmps parinit_orig.
#
# Requires the PC-relative-relocation loader fix (amix-unix-boot, rel.c, commit
# amix-unix-boot v1.0-040-060) for the FPSP body's ~330 PC-relative relocs -- same requirement as
# relink-040-fpsp-xsvga.sh.
#
# Usage: sh relink-040-va2000.sh [base-kernel] [output]
#   sh relink-040-va2000.sh                                    # debug base -> debug output
#   sh relink-040-va2000.sh build/unix-040 build/unix-040-va2000   # non-debug
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$(cd "$(dirname "$0")" && pwd)/tools/config-load.sh"
. "$(cd "$(dirname "$0")" && pwd)/tools/build-step.sh"

# $1 = base kernel (default: standard DEBUG base). $2 = output path.
# 2026-08-14: was unix-040-dbg.STD-backup, a scratch image from 2026-07-24 that predates FPSP
# being folded into the base.  The FPSP guard below (added 2026-07-26) therefore rejected this
# script's OWN default, so it could not run at all without an explicit argument.  Every other
# variant script defaults to build/unix-040-dbg; this one now does too.
IN="${1:-$HERE/build/unix-040-dbg}"
[ -f "$IN" ] || IN="$HERE/build/unix-040-dbg"
OUT="${2:-$HERE/build/unix-040-va2000-dbg}"
FPWORK="$HERE/build/fpsp-work/usr/src/sys/arch/m68k/fpsp"
PARINIT_ADDR=0xfe6c

[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
echo "[*] base: $(basename "$IN")"
m68k-linux-gnu-nm "$IN" | grep -qE " [Tt] fpsp_vec11$" || { echo "[FAIL] base does NOT carry FPSP -- since 2026-07-26 FPSP is part of relink-040.sh; rebuild the base"; exit 1; }
m68k-linux-gnu-nm "$IN" | grep -qE " [Tt] va2000init\$" && { echo "[FAIL] base already has va2000 linked -- use a plain base"; exit 1; }

PARINIT_LINE=$(m68k-linux-gnu-nm "$IN" | grep -E " T parinit\$") || { echo "ERROR: parinit not found in $IN"; exit 1; }
PARINIT_CUR=$(echo "$PARINIT_LINE" | awk '{print $1}')
PARINIT_EXPECT=$(printf '%08x' $PARINIT_ADDR)
[ "$PARINIT_CUR" = "$PARINIT_EXPECT" ] || {
	echo "ERROR: parinit @0x$PARINIT_CUR != expected 0x$PARINIT_EXPECT -- base layout drifted, re-verify address"
	exit 1
}
echo "      parinit @0x$PARINIT_CUR OK (matches expected 0x$PARINIT_EXPECT)"


# Model-B header set (2026-08-01).  The toolchain wrapper injects its own
# sysroot -I BEFORE every user -I, so the vanilla -I in AMIX_KERNEL_CFLAGS has
# never actually supplied <sys/immu.h> or <sys/param.h> -- both sysroot copies
# say the page is 2 KiB.  AMIX_SYSROOT points the compile at the mirror sysroot
# whose two geometry headers are Model B; the generator refuses to finish unless
# its probe passes there and FAILS against the stock one.
echo "[*] Model-B header set (mirror sysroot + geometry probe)"
sh "$HERE/src/mk_modelb_sysroot.sh" | sed 's/^/      /'
AMIX_SYSROOT="$HERE/build/sysroot-modelb"
export AMIX_SYSROOT

# Still needed even with the headers: va2000.c computes its PFN with a HARDCODED
# `>> 11`, not with phystopfn, and no header can reach a literal.  This is the
# division of labour -- headers cover macro users, this patcher covers the
# literal, and check_page_geometry.sh below covers both in the compiled bytes.
echo "[*] VA2000: Model-B source copy (>>11 -> >>12, exactly one site)"
python3 "$HERE/src/va2000_modelb.py"
echo "[*] VA2000: cross-compile build/va2000_040.c"
VA2000_CFLAGS=$(echo "$AMIX_KERNEL_CFLAGS" | sed 's/-m68020/-m68040/')
m68k-cbm-sysv4-gcc $VA2000_CFLAGS -I"$HERE/build" \
	-c "$HERE/build/va2000_040.c" -o "$HERE/build/va2000_040.o"
sh "$HERE/src/check_page_geometry.sh" "$HERE/build/va2000_040.o" | sed 's/^/      /'
echo "[*] VA2000: assemble the parinit wrapper"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/parinit_va2000.s" -o "$HERE/build/parinit_va2000.o"

echo "[*] checking va2000_040.o has no surprise unresolved refs:"
LEAK0=$(m68k-linux-gnu-nm "$HERE/build/va2000_040.o" | grep ' U ' | grep -vE '^\s*U (autocon|printf|uiomove|copyin|copyout)$' || true)
[ -z "$LEAK0" ] && echo "      only expected kernel imports (autocon/printf/uiomove/copyin/copyout)" \
	|| { echo "[FAIL] unexpected unresolved refs in va2000_040.o:"; echo "$LEAK0"; exit 1; }

echo "[*] weaken base parinit + expose parinit_orig -> build/unix-stage-va2000"
STAGE="$HERE/build/unix-stage-va2000"
cp "$IN" "$STAGE"
m68k-linux-gnu-objcopy \
	--weaken-symbol parinit \
	--add-symbol parinit_orig=.text:$PARINIT_ADDR,function,global \
	"$STAGE"

echo "[*] ld -r: base(weakened, FPSP already in it) + va2000_040.o + parinit_va2000.o"
m68k-cbm-sysv4-ld -r -o "$OUT" "$STAGE" \
	"$HERE/build/va2000_040.o" "$HERE/build/parinit_va2000.o"

echo "[*] symbols from both features must be defined:"
for s in fpsp_vec11 fpsp_done fpsp_fline fpsp_unimp \
	va2000init va2000open va2000close va2000read va2000write va2000ioctl va2000mmap va2000_boards \
	parinit parinit_orig; do
	m68k-linux-gnu-nm "$OUT" | grep -qE " [A-Za-z] $s\$" || { echo "[FAIL] $s missing"; exit 1; }
done
echo "      fpsp_vec11/done/fline/unimp + va2000* + parinit/parinit_orig OK"
LEAK=$(m68k-linux-gnu-nm "$OUT" | grep ' U ' | grep -iE 'fpsp_|mem_read|mem_write|real_|va2000' || true)
[ -z "$LEAK" ] && echo "      no unresolved FPSP/va2000 symbols" || { echo "[FAIL] unresolved:"; echo "$LEAK"; exit 1; }

# parinit must be a SINGLE strong def (our override), not still resolving to the stock body.
PCOUNT=$(m68k-linux-gnu-nm "$OUT" | grep -cE " T parinit\$")
[ "$PCOUNT" -eq 1 ] || { echo "[FAIL] expected exactly 1 strong 'parinit' def, found $PCOUNT"; exit 1; }

echo "[*] patch 3/3: cdevsw[68] -> va2000* (major 68 = /dev/va2000)"
run_step 8 python3 "$HERE/src/patch_va2000_cdevsw.py" "$OUT"

echo "[*] reloc validation:"
run_step 1 python3 "$HERE/src/check_relink_relocs.py" "$OUT"
DSZ=$(( 0x$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".data"{print $6}') ))
[ $((DSZ % 4)) -eq 0 ] && echo "[OK] .data 4-aligned" || { echo "[FAIL] .data misaligned"; exit 1; }
echo "[*] PC-relative relocs present (loader MUST have the amix-unix-boot v1.0-040-060 fix):"
m68k-linux-gnu-readelf -rW "$OUT" 2>/dev/null | awk '$3 ~ /^R_68K_PC/{n++} END{print "      "n" PC-relative records"}'

run_step all python3 "$HERE/src/stamp_buildid.py" "$OUT"
echo "[OK] built $OUT"
