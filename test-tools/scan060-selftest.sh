#!/bin/sh
# Positive control for scan060.py -- see scan060-selftest.s for why it exists.
# Exits 0 only if the scanner reports exactly the four removed forms.
set -e
HERE=$(dirname "$0")
AS=${AS:-m68k-linux-gnu-as}
OBJDUMP=${OBJDUMP:-m68k-linux-gnu-objdump}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' 0

"$AS" -m68020 -o "$TMP/t.o" "$HERE/scan060-selftest.s"
"$OBJDUMP" -d "$TMP/t.o" > "$TMP/t.dis"
python3 "$HERE/scan060.py" "$TMP/t.dis" > "$TMP/t.out"

n=$(grep -c "vector 61" "$TMP/t.out" || true)
if [ "$n" != "4" ]; then
	echo "SCAN060-SELFTEST FAIL: expected 4 candidates, got $n"
	cat "$TMP/t.out"
	exit 1
fi
# The kept forms are the ones that must be absent, and the count alone would not
# prove it: four hits could be the wrong four.  Check the encodings reported.
for want in "4c41 3402" "4c41 3c02" "4c01 3402" "4c01 3c02"; do
	grep -q "$want" "$TMP/t.dis" || { echo "SCAN060-SELFTEST FAIL: $want absent from listing"; exit 1; }
done
for kept in 3002 3802 3003 3000; do
	addr=$(grep "	4c[04]1* $kept" "$TMP/t.dis" | head -1 | cut -d: -f1 | tr -d ' ')
	[ -z "$addr" ] && continue
	if grep -q "^   $addr " "$TMP/t.out"; then
		echo "SCAN060-SELFTEST FAIL: kept form at $addr reported as a candidate"
		exit 1
	fi
done
echo "SCAN060-SELFTEST PASS: 4 removed forms reported, 4 kept forms silent"
