#!/bin/sh
# relink-040-ttcompat.sh -- OPT-IN: clear the ttcompat per-stream state the stock open leaves
# uninitialised (ISSUE-77, src/patch_ttcompat_init.py; the driver line's DRIVER-LINE-7, 2026-10-05).
#
# Not in relink-040.sh's base list, on purpose: the default chain changes only by a decision recorded
# in STATUS.  When it is wanted, run this pass anywhere in the chain BEFORE relink-040-fpe.sh: fpe
# stamps the build id, and patching after the stamp would give one build id two byte-sets.  It links
# nothing; it is a same-length byte patch located by symbol.
#
# THE FORM.  All of 4..0x43 is cleared at open (thirteen `clrl` in the span of the stock `clrb`s),
# the effect of the bzero the later USL trees added.  The driver line's 1.0 kernels carry a narrower
# form that clears only the three fields the ack path trusts; the patcher's header says why the wide
# form was chosen, and it upgrades the narrow bytes if it meets them.
#
# usage: sh relink-040-ttcompat.sh [base-kernel] [output]
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tools/build-step.sh"

IN="${1:-$HERE/build/unix-040}"
OUT="${2:-$HERE/build/unix-040-ttcompat}"
[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
echo "[*] base: $(basename "$IN")  (sha256 $(sha256sum "$IN" | cut -d' ' -f1))"
m68k-linux-gnu-nm "$IN" | grep -qE " [Tt] fpe_vec11\$" \
	&& { echo "[FAIL] base already carries the FPE (and its build id) -- run this pass BEFORE relink-040-fpe.sh"; exit 1; }
[ "$IN" = "$OUT" ] || cp "$IN" "$OUT"
run_step all python3 "$HERE/src/patch_ttcompat_init.py" "$OUT"
run_step all python3 "$HERE/src/patch_ttcompat_init.py" --check "$OUT"
D=$(cmp -l "$IN" "$OUT" | wc -l)
echo "      bytes changed against the input: $D (at most 64, inside ttcompatopen)"
[ "$D" -le 64 ] || { echo "[FAIL] more than the 64-byte span changed"; exit 1; }
echo "[OK] built $OUT"
echo "     next:  relink-040-fpe.sh (always the last link; it stamps the build id)"
