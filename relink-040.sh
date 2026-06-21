#!/bin/sh
# relink-040.sh -- build the page_init-milestone 68040 kernel: pstart040 (bootstrap
# paging + kvseg scaffold) + kvm040 (sysseginit pointer descs + segkmem_mapin leaf
# PTEs).  Combines the override mechanisms (see worklist):
#   * pstart        GLOBAL -> --weaken-symbol           (pstart040.o redefines it)
#   * segkmem_mapin GLOBAL -> --weaken-symbol           (kvm040.o redefines it)
#   * sysseginit    LOCAL  -> --globalize-symbol then --weaken-symbol (kvm040.o redefines)
# Then patch the remaining 030 PMMU instructions (patch_pflusha/patch_pmmu).
#
# Output: build/unix-040  (ready to boot on a 68040; should advance past the old
# page_init+0x4a bus error if the kvseg map is now correct).
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
STOCK="${STOCK:-/home/asokero/kehitys/amix-playground/vanilla/stand/unix}"
ENV="/home/asokero/kehitys/amix-playground/gcc-cross-amix/build/env.sh"
. "$ENV"
mkdir -p "$HERE/build"

echo "[*] assembling pstart040.s + kvm040.s + hat040.s"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/pstart040.s" -o "$HERE/build/pstart040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/kvm040.s"    -o "$HERE/build/kvm040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/hat040.s"    -o "$HERE/build/hat040.o"

echo "[*] globalize local fns (so overrides + cross-refs bind); weaken the replaced ones"
cp "$STOCK" "$HERE/build/unix-stage1"
# sysseginit, hat_pteload are REPLACED (globalize+weaken).  hat_ptalloc, hat_pt2ptdat
# are file-LOCAL but CALLED by our hat040.o (and byte-patched in place by patch_modelb),
# so globalize them too -- else ld -r can't bind hat040.o's refs to the kernel's local
# defs (the crashsw/crash_sync RELA-guru lesson).
m68k-linux-gnu-objcopy \
	--globalize-symbol sysseginit \
	--globalize-symbol hat_pteload \
	--globalize-symbol hat_ptalloc \
	--globalize-symbol hat_pt2ptdat \
	--globalize-symbol free_pts \
	--globalize-symbol pt_waiting \
	"$HERE/build/unix-stage1"
m68k-linux-gnu-objcopy \
	--weaken-symbol pstart \
	--weaken-symbol sysseginit \
	--weaken-symbol vatosde \
	--weaken-symbol vatopte \
	--weaken-symbol hat_pteload \
	--weaken-symbol hat_unlock \
	"$HERE/build/unix-stage1"

OUT="$HERE/build/unix-040"
echo "[*] relinking -> $OUT"
m68k-cbm-sysv4-ld -r -o "$OUT" "$HERE/build/unix-stage1" \
	"$HERE/build/pstart040.o" "$HERE/build/kvm040.o" "$HERE/build/hat040.o"

echo
echo "[*] overridden symbols (each must be a single strong def):"
for s in pstart sysseginit vatosde vatopte hat_pteload hat_unlock; do
	m68k-linux-gnu-nm "$OUT" | grep -E " $s\$" | sed "s/^/      $s: /"
done
echo "[*] stray UND refs (should be NONE for our globals):"
m68k-linux-gnu-nm "$OUT" | grep ' U ' | grep -iE 'kptr040|kroot040|sysseginit|segkmem_mapin|kptbl|syssegs' \
	| sed 's/^/      /' || echo "      (none)"
echo
m68k-linux-gnu-size "$OUT" | sed 's/^/      /'

# text/data contiguity (loader copies them as one block)
CONTIG=$(m68k-linux-gnu-readelf -SW "$OUT" 2>/dev/null | awk '
	{gsub(/[][]/,"")}
	$2==".text" {to=strtonum("0x"$5); ts=strtonum("0x"$6)}
	$2==".data" {do_=strtonum("0x"$5)}
	END{printf("%d %d", to+ts, do_)}')
set -- $CONTIG
if [ "$1" = "$2" ]; then echo "[OK] text/data contiguous."
else echo "[FAIL] text/data NOT contiguous: text_end=0x$(printf %x $1) data_off=0x$(printf %x $2)"; exit 1; fi

echo
echo "[*] patching remaining 030 PMMU instructions (pflusha, ptest stubs)"
python3 "$HERE/prototypes/patch_pflusha_040.py" "$OUT" | tail -2
python3 "$HERE/prototypes/patch_pmmu_040.py" "$OUT" | tail -2

echo "[*] Model B (4KB page frame) Tier-0 byte patches"
python3 "$HERE/prototypes/patch_modelb.py" "$OUT" | tail -3

echo
echo "[*] reloc validation:"
( cd "$HERE" && python3 prototypes/check_relink_relocs.py | tail -1 )

echo
echo "[OK] built $OUT -- boot on 68040: unix_boot unix-040"
