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

echo "[*] assembling genuine 68040 trap/fault runtime ports (moved out of the dbg overlay --"
echo "    these are REAL fixes, not diagnostics, so they belong in the base kernel):"
echo "      getfault040 = decode the 040 format-7 access-error frame (fault address)"
echo "      userspace040 = classify user-vs-kernel fault from the 040 SSW (route copyout)"
echo "      vtop040      = DTT0 identity phys for disk DMA (va < 0x40000000)"
echo "      wb040        = 040 access-error WRITE-BACK replay (the init copyout(icode) fix)"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/getfault040.s"  -o "$HERE/build/getfault040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/userspace040.s" -o "$HERE/build/userspace040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/vtop040.s"      -o "$HERE/build/vtop040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/wb040.s"        -o "$HERE/build/wb040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/segvn_cow040.s" -o "$HERE/build/segvn_cow040.o"

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
	--globalize-symbol hat_sdtalloc \
	--globalize-symbol hat_pt2ptdat \
	--globalize-symbol hat_ptfree \
	--globalize-symbol free_pts \
	--globalize-symbol pt_waiting \
	--globalize-symbol usrxmemflt \
	--globalize-symbol krnxmemflt \
	--globalize-symbol segvn_fault \
	"$HERE/build/unix-stage1"
m68k-linux-gnu-objcopy \
	--weaken-symbol pstart \
	--weaken-symbol sysseginit \
	--weaken-symbol vatosde \
	--weaken-symbol vatopte \
	--weaken-symbol hat_pteload \
	--weaken-symbol hat_unlock \
	--weaken-symbol hat_unload \
	--weaken-symbol hat_alloc \
	--weaken-symbol hat_free \
	--weaken-symbol hat_ptfree \
	"$HERE/build/unix-stage1"

# Genuine 040 trap/fault runtime overrides (getfault040/userspace040/vtop040/wb040).
# usrxmemflt is file-LOCAL ('t') -> globalized above so wb040's strong def binds and the
# original is reachable via the alias.  vtop040 tail-jmps the aliased original for the
# kvseg/user path.  get_fault and userspace are GLOBAL T -> plain weaken is enough.
m68k-linux-gnu-objcopy \
	--weaken-symbol get_fault \
	--weaken-symbol userspace \
	--weaken-symbol vtop \
	--add-symbol vtop_orig=.text:0xb7568,function,global \
	--weaken-symbol usrxmemflt \
	--add-symbol usrxmemflt_orig=.text:0x5aede,function,global \
	--weaken-symbol krnxmemflt \
	--add-symbol krnxmemflt_orig=.text:0x5b140,function,global \
	--weaken-symbol segvn_fault \
	--add-symbol segvn_fault_orig=.text:0xac434,function,global \
	"$HERE/build/unix-stage1"

OUT="$HERE/build/unix-040"
echo "[*] relinking -> $OUT"
m68k-cbm-sysv4-ld -r -o "$OUT" "$HERE/build/unix-stage1" \
	"$HERE/build/pstart040.o" "$HERE/build/kvm040.o" "$HERE/build/hat040.o" \
	"$HERE/build/getfault040.o" "$HERE/build/userspace040.o" \
	"$HERE/build/vtop040.o" "$HERE/build/wb040.o" "$HERE/build/segvn_cow040.o"

echo
echo "[*] overridden symbols (each must be a single strong def):"
for s in pstart sysseginit vatosde vatopte hat_pteload hat_unlock hat_unload hat_alloc hat_free hat_ptfree get_fault userspace vtop usrxmemflt usrxmemflt_orig krnxmemflt krnxmemflt_orig vtop_orig segvn_fault segvn_fault_orig; do
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

echo "[*] Model B Tier-2 pager/fs page-I/O (dir-read chain) byte patches"
python3 "$HERE/prototypes/patch_modelb_pager.py" "$OUT" | tail -3

echo
echo "[*] reloc validation:"
( cd "$HERE" && python3 prototypes/check_relink_relocs.py | tail -1 )

echo
echo "[OK] built $OUT -- boot on 68040: unix_boot unix-040"
