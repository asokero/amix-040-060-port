#!/bin/sh
# test-ttcompat-init.sh -- hermetic self-test of src/patch_ttcompat_init.py (ISSUE-77).
# Assembles tiny ET_REL objects that carry a local `ttcompatopen` with the stock clear sequence at +0x80
# (and variants), and checks: stock -> exactly the fixed bytes, idempotent, --check exit codes, nothing
# outside the span changes, the narrow driver-line form upgraded to the wide one, and refusals for a
# foreign span and for a relocation inside the span.
#
#     sh tools/test-ttcompat-init.sh          # exits 0 if every case passes
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tools/config-load.sh"
W="$HERE/build/test-ttcompat"; mkdir -p "$W"
P="$HERE/src/patch_ttcompat_init.py"
fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

# the stock shape: 0x78 bytes of nops, clrl 4, clrl 8, clrb 12..27, clrl 28, rts
{
	printf '\t.text\nttcompatopen:\n'
	i=0; while [ $i -lt 60 ]; do printf '\t.word 0x4e71\n'; i=$((i + 1)); done
	printf '\t.word 0x42a8,0x0004,0x42a8,0x0008\n'
	n=12; while [ $n -le 27 ]; do printf '\t.word 0x4228,%d\n' $n; n=$((n + 1)); done
	printf '\t.word 0x42a8,0x001c\n\t.word 0x4e75\n'
} > "$W/stock.s"
m68k-cbm-sysv4-gcc -m68040 -c "$W/stock.s" -o "$W/stock.o"
span() { m68k-linux-gnu-objcopy -O binary -j .text "$1" "$W/span.bin"; python3 -c "print(open('$W/span.bin','rb').read()[0x80:0xc0].hex())"; }

cp "$W/stock.o" "$W/t.o"
if python3 "$P" --check "$W/t.o" >/dev/null 2>&1; then fail "--check on stock exits 1"; else pass "--check on stock exits 1"; fi
python3 "$P" "$W/t.o" | grep -q '\[ok\]' && pass "patches the stock object" || fail "patches the stock object"
python3 "$P" "$W/t.o" | grep -q '\[skip\]' && pass "a second run is a skip" || fail "a second run is a skip"
python3 "$P" --check "$W/t.o" >/dev/null 2>&1 && pass "--check on fixed exits 0" || fail "--check on fixed exits 0"
WANT=$(python3 -c "
import struct
print((b''.join(struct.pack('>HH', 0x42a8, n) for n in range(12, 0x44, 4) if n != 28) + b'\x4e\x71' * 6).hex())")
GOT=$(span "$W/t.o")
[ "$GOT" = "$WANT" ] && pass "the span holds exactly the fixed bytes" || { fail "the span holds exactly the fixed bytes"; echo "  got  $GOT"; echo "  want $WANT"; }
N=$(cmp -l "$W/stock.o" "$W/t.o" | wc -l)
[ "$N" -le 64 ] && pass "nothing outside the span changed ($N bytes)" || fail "nothing outside the span changed ($N bytes)"

# the driver line's 1.0 bytes: clrl 12/16/20/24, clrl 56/60/64, 18 nops -> --check says old, a run upgrades
awk '/^\t.word 0x4228,12$/{printf "\t.word 0x42a8,12,0x42a8,16,0x42a8,20,0x42a8,24,0x42a8,56,0x42a8,60,0x42a8,64\n"; i=0; while (i < 18) {print "\t.word 0x4e71"; i++}; skip=1; next} skip==1 && /^\t.word 0x4228,/{next} {skip=0; print}' "$W/stock.s" > "$W/narrow.s"
m68k-cbm-sysv4-gcc -m68040 -c "$W/narrow.s" -o "$W/narrow.o"
if python3 "$P" --check "$W/narrow.o" >/dev/null 2>&1; then fail "--check on the narrow form exits 1"; else pass "--check on the narrow form exits 1"; fi
python3 "$P" "$W/narrow.o" | grep -q 'was the narrow fix' && pass "upgrades the narrow form" || fail "upgrades the narrow form"
[ "$(span "$W/narrow.o")" = "$WANT" ] && pass "the upgraded span holds exactly the fixed bytes" || fail "the upgraded span holds exactly the fixed bytes"

sed 's/^\t.word 0x4228,20$/\t.word 0x4228,99/' "$W/stock.s" > "$W/bad.s"
m68k-cbm-sysv4-gcc -m68040 -c "$W/bad.s" -o "$W/bad.o"
if python3 "$P" "$W/bad.o" >/dev/null 2>&1; then fail "refuses a foreign span"; else pass "refuses a foreign span"; fi

awk '/^\t.word 0x4228,16$/{print "\t.long extsym"; skip=1; next} skip==1 && /^\t.word 0x4228,17$/{skip=0; next} {print}' "$W/stock.s" > "$W/rel.s"
m68k-cbm-sysv4-gcc -m68040 -c "$W/rel.s" -o "$W/rel.o"
if python3 "$P" "$W/rel.o" >/dev/null 2>&1; then fail "refuses a relocation in the span"; else pass "refuses a relocation in the span"; fi

echo "$([ $fails = 0 ] && echo PASS || echo FAIL): $fails failing"
[ $fails = 0 ]
