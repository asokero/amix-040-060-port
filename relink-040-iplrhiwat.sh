#!/bin/sh
# relink-040-iplrhiwat.sh -- OPT-IN: raise IP's lower read queue high-water mark 0x2000 -> 0x10000
# (ISSUE-81, src/patch_ip_lrhiwat.py, 2026-10-30).
#
# Not in relink-040.sh's base list, on purpose: the default chain changes only by a decision recorded
# in STATUS.  It links nothing; it is a four-byte .data patch located through iplrinit's relocation.
#
# BUILD IDS.  On an unstamped base, run it before relink-040-fpe.sh, which stamps the id.  On an
# already-stamped kernel (an accepted image, or its serial-mirror twin) it stamps a new id itself,
# so one build id never names two byte-sets.  Then the only differences from the input are the
# bytes of mi_hiwat and the id.
#
# The work is done on a scratch copy in build/, and OUT is written only when every check has
# passed (Codex review, 2026-10-30):
#   - the scratch copy is stamped where it sits, so the id comes from build/.build-seq whatever OUT
#     is; a fresh output directory would otherwise restart the day's sequence (F1);
#   - IN is never written, and OUT may not be IN, so a failure cannot leave the input patched
#     under its old id (F3);
#   - the gate compares IN and the result byte for byte: same length, differences only inside
#     mi_hiwat and, when restamped, the 16-byte buildid, and a restamped id differs from IN's (F4).
#
# usage: sh relink-040-iplrhiwat.sh [base-kernel] [output]
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tools/build-step.sh"

IN="${1:-$HERE/build/unix-040}"
OUT="${2:-$HERE/build/unix-040-iplrhiwat}"
[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
if [ "$IN" = "$OUT" ] || [ "$IN" -ef "$OUT" ]; then
	echo "ERROR: output is the input ($OUT); this pass never writes its input"; exit 1
fi
echo "[*] base: $(basename "$IN")  (sha256 $(sha256sum "$IN" | cut -d' ' -f1))"
TMP="$HERE/build/.iplrhiwat.$$"
trap 'rm -f "$TMP"' EXIT INT TERM
cp "$IN" "$TMP"
run_step all python3 "$HERE/src/patch_ip_lrhiwat.py" "$TMP"
run_step all python3 "$HERE/src/patch_ip_lrhiwat.py" --check "$TMP"
# Stamped or not is read from the `buildid` field itself: the reserved literal is " 68040-000000-00".
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
from patch_ip_lrhiwat import locate, FIXED
src, new, restamp = sys.argv[2], sys.argv[3], sys.argv[4] == "1"
a, b = open(src, "rb").read(), open(new, "rb").read()
if len(a) != len(b):
    sys.exit("[FAIL] length changed: %d -> %d" % (len(a), len(b)))
e = Elf(new)
n, site, cur = locate(e)
if cur != FIXED:
    sys.exit("[FAIL] mi_hiwat is 0x%x, not 0x%x" % (cur, FIXED))
d = e.sec[".data"]["offset"]
allowed = set(range(d + site, d + site + 4))
s = e.sym(e.index("buildid")); bo = e.sec[e.names[s["shndx"]]]["offset"] + s["value"]
if restamp:
    allowed |= set(range(bo, bo + 16))
    if a[bo:bo + 16] == b[bo:bo + 16]:
        sys.exit("[FAIL] restamped, but the build id is still %r" % b[bo:bo + 16].decode("latin1"))
diff = [i for i in range(len(a)) if a[i] != b[i]]
stray = [i for i in diff if i not in allowed]
if stray:
    sys.exit("[FAIL] %d byte(s) changed outside mi_hiwat and the build id, first at file 0x%x"
             % (len(stray), stray[0]))
print("      bytes changed against the input: %d, all inside mi_hiwat%s"
      % (len(diff), " and the build id" if restamp else ""))
' "$HERE/src" "$IN" "$TMP" "$RESTAMP"
mv "$TMP" "$OUT"
trap - EXIT INT TERM
echo "[OK] built $OUT"
