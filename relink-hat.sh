#!/bin/sh
# relink-hat.sh -- override the binary-only HAT page-table functions in the AMIX
# kernel with their 68040 ports (prototypes/hat040.s -> build/hat040.o) and relink.
#
# Unlike pstart (a GLOBAL symbol), the HAT functions are file-LOCAL (`t`).  The
# --weaken-symbol trick alone cannot override a local or redirect its callers, so
# we first --globalize-symbol each one (local -> global), then --weaken-symbol the
# ones we actually replace.  The strong defs in hat040.o then override the weak
# kernel defs AND the kernel's internal callers re-resolve to them.  (Verified;
# see prototypes/hat-040-port-worklist.md "KEY MECHANISM".)
#
# Output: build/unix-040-hat   (then run the same MMU-instruction patch scripts as
# the pstart build: patch_pflusha_040.py / patch_pmmu_040.py, on THIS output).
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
. "$(cd "$(dirname "$0")" && pwd)/tools/config-load.sh"
STOCK="${STOCK:-$AMIX_ROOT/stand/unix}"
mkdir -p "$HERE/build"

# Every file-local HAT symbol hat040.o references or replaces must be globalized so
# our references bind / our strong defs can override.  Add names here as functions
# are ported into hat040.s.
GLOBALIZE="hat_pteload hat_ptalloc hat_pt2ptdat hat_sdtalloc hat_growsdt"
# Only the functions hat040.o actually REDEFINES get weakened (strong def wins).
# Keep this in sync with the .globl directives in hat040.s.
WEAKEN="hat_pteload"

# 1. Assemble the 040 HAT replacement object.
echo "[*] assembling hat040.s -> build/hat040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/hat040.s" -o "$HERE/build/hat040.o"

# 2. Globalize all referenced/replaced locals, then weaken the replaced ones.
echo "[*] globalize: $GLOBALIZE"
cp "$STOCK" "$HERE/build/unix-stage1-hat"
GLOBOPTS=""
for s in $GLOBALIZE; do GLOBOPTS="$GLOBOPTS --globalize-symbol $s"; done
m68k-linux-gnu-objcopy $GLOBOPTS "$HERE/build/unix-stage1-hat"
echo "[*] weaken (replaced): $WEAKEN"
WEAKOPTS=""
for s in $WEAKEN; do WEAKOPTS="$WEAKOPTS --weaken-symbol $s"; done
m68k-linux-gnu-objcopy $WEAKOPTS "$HERE/build/unix-stage1-hat"

# 3. Relink (cross ld -r).
OUT="$HERE/build/unix-040-hat"
echo "[*] relinking -> $OUT"
m68k-cbm-sysv4-ld -r -o "$OUT" "$HERE/build/unix-stage1-hat" "$HERE/build/hat040.o"

# 4. Verify each replaced symbol resolved to a single strong def, no stray UND.
echo
for s in $WEAKEN; do
    echo "[*] $s ->"; m68k-linux-gnu-nm "$OUT" | grep -E " $s\$" | sed 's/^/      /'
done
echo "[*] UND HAT/helper refs (should be NONE):"
m68k-linux-gnu-nm "$OUT" | grep ' U ' | grep -iE 'hat_|cmn_err|flushmmu' | sed 's/^/      /' || echo "      (none)"
echo
m68k-linux-gnu-size "$OUT" | sed 's/^/      /'

# 5. text/data contiguity (loader copies them as one block; hat040.o .text must be
#    a multiple of 4 bytes).
CONTIG=$(m68k-linux-gnu-readelf -SW "$OUT" 2>/dev/null | awk '
    {gsub(/[][]/,"")}
    $2==".text" {to=strtonum("0x"$5); ts=strtonum("0x"$6)}
    $2==".data" {do_=strtonum("0x"$5)}
    END{printf("%d %d", to+ts, do_)}')
set -- $CONTIG
if [ "$1" = "$2" ]; then
    echo "[OK] text/data contiguous."
else
    echo "[FAIL] text/data NOT contiguous: text_end=0x$(printf %x $1) data_off=0x$(printf %x $2)"
    echo "       -> pad hat040.o .text to a multiple of 4 bytes."
    exit 1
fi
echo
echo "[OK] built $OUT"
echo "     NOTE: this build replaces ONLY the functions in WEAKEN ($WEAKEN)."
echo "     page_init won't advance until the whole coupled batch (hat_pteload,"
echo "     hat_ptalloc, hat_sdtalloc, hat_growsdt) is ported -- see worklist."
echo "     Next: combine with pstart040 + run patch_pflusha_040.py/patch_pmmu_040.py."
