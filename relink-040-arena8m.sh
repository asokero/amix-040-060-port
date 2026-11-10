#!/bin/sh
# relink-040-arena8m.sh -- (was OPT-IN, now also in the base) the 8 MB kernel VA arena (ISSUE-80,
# src/patch_arena8m.py) and the unit-correct kmem_freepool wakeup (ISSUE-82,
# src/patch_freepool_wake.py), 2026-10-30.
#
# IN THE DEFAULT CHAIN SINCE 2026-11-10: relink-040.sh runs the same patcher(s) on its finished link
# (STATUS, ISSUE-80/82), so over a current base this script changes only the build id.  It stays for
# older stamped kernels, such as an accepted image or its serial-mirror twin.  Before that date it
# was kept out of the base on purpose: the default chain changes only by a decision recorded in
# STATUS.
# It links nothing: same-size immediates in .text and two SHN_ABS symbol values.  The route and its
# acceptance plan are Codex's (private ISSUE80-ARENA-ROUTE-CODEX-RESULT.md).
#
# BUILD IDS.  On an unstamped base, run it before relink-040-fpe.sh, which stamps the id.  On an
# already-stamped kernel it stamps a new id itself.  As in relink-040-iplrhiwat.sh, the work is
# done on a scratch copy in build/ (so the id comes from build/.build-seq), IN is never written, OUT
# is written only when every check has passed, and the gate compares IN and the result byte for
# byte: same length, and differences only inside the sites the two patchers name and, when
# restamped, the 16-byte buildid.
#
# usage: sh relink-040-arena8m.sh [base-kernel] [output]
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tools/build-step.sh"

IN="${1:-$HERE/build/unix-040}"
OUT="${2:-$HERE/build/unix-040-arena8m}"
[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
if [ "$IN" = "$OUT" ] || [ "$IN" -ef "$OUT" ]; then
	echo "ERROR: output is the input ($OUT); this pass never writes its input"; exit 1
fi
echo "[*] base: $(basename "$IN")  (sha256 $(sha256sum "$IN" | cut -d' ' -f1))"
TMP="$HERE/build/.arena8m.$$"
trap 'rm -f "$TMP"' EXIT INT TERM
cp "$IN" "$TMP"
run_step all python3 "$HERE/src/patch_arena8m.py" "$TMP"
run_step all python3 "$HERE/src/patch_arena8m.py" --check "$TMP"
run_step all python3 "$HERE/src/patch_freepool_wake.py" "$TMP"
run_step all python3 "$HERE/src/patch_freepool_wake.py" --check "$TMP"
BID=$(python3 -c '
import sys; sys.path.insert(0, sys.argv[1])
from kelf import Elf
e = Elf(sys.argv[2]); s = e.sym(e.index("buildid")); d = e.sec[e.names[s["shndx"]]]["offset"]
print(bytes(e.b[d + s["value"]:d + s["value"] + 16]).decode("latin1").strip())' "$HERE/src" "$IN")
echo "      input build id: $BID"
RESTAMP=0
if [ "$BID" != "68040-000000-00" ]; then
	echo "[*] the base is stamped -- stamping a new build id"
	python3 "$HERE/src/stamp_buildid.py" "$TMP"
	RESTAMP=1
fi
python3 -c '
import sys; sys.path.insert(0, sys.argv[1])
from kelf import Elf
import patch_arena8m, patch_freepool_wake
src, new, restamp = sys.argv[2], sys.argv[3], sys.argv[4] == "1"
a, b = open(src, "rb").read(), open(new, "rb").read()
if len(a) != len(b):
    sys.exit("[FAIL] length changed: %d -> %d" % (len(a), len(b)))
e = Elf(new)
st, ss, syms = patch_arena8m.state(e)
site, fst = patch_freepool_wake.locate(e)
if st != "new" or fst != "new":
    sys.exit("[FAIL] the result is not fully patched (arena %s, wakeup %s)" % (st, fst))
t = e.sec[".text"]["offset"]
allowed = set()
for s in ss:
    allowed |= set(range(t + s.off, t + s.off + len(s.new)))
for _, vo, _, _ in syms:
    allowed |= set(range(vo, vo + 4))
allowed |= set(range(t + site, t + site + 4))
s = e.sym(e.index("buildid")); bo = e.sec[e.names[s["shndx"]]]["offset"] + s["value"]
if restamp:
    allowed |= set(range(bo, bo + 16))
    if a[bo:bo + 16] == b[bo:bo + 16]:
        sys.exit("[FAIL] restamped, but the build id is still %r" % b[bo:bo + 16].decode("latin1"))
diff = [i for i in range(len(a)) if a[i] != b[i]]
stray = [i for i in diff if i not in allowed]
if stray:
    sys.exit("[FAIL] %d byte(s) changed outside the named sites, first at file 0x%x"
             % (len(stray), stray[0]))
print("      bytes changed against the input: %d, all inside the %d named sites%s"
      % (len(diff), len(ss) + len(syms) + 1, " and the build id" if restamp else ""))
' "$HERE/src" "$IN" "$TMP" "$RESTAMP"
run_step all python3 "$HERE/src/check_relink_relocs.py" "$TMP"
mv "$TMP" "$OUT"
trap - EXIT INT TERM
echo "[OK] built $OUT"
