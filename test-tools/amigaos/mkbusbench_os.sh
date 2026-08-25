#!/bin/sh
# mkbusbench_os.sh -- cross-build the AmigaOS twin of busbench.
#
# This is the ONLY tool in this repository that is built for AmigaOS rather than for
# AMIX, and it exists for one measurement: the same VA2000, in the same machine, driven
# by an OS we did not write, as a control on our own 7.66 MB/s Zorro III number.
#
# -O2 is deliberate and safe ONLY because every benchmarked access in the source is
# volatile.  If that ever stops being true, gcc will quietly turn the write loop into a
# memset() and the comparison against the AMIX cc build becomes meaningless.
#
# -m68060 would let gcc emit 060-only encodings; we build for 68020 instead so the same
# binary runs whatever accelerator is fitted.  The benchmark is bus-bound, so the
# instruction selection is not what we are measuring.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
GCC="$HOME/kehitys/amiga-gcc-bin/bin/m68k-amigaos-gcc"

[ -x "$GCC" ] || { echo "ERROR: no AmigaOS cross-compiler at $GCC"; exit 1; }

"$GCC" -O2 -m68020 -fomit-frame-pointer \
	-Wall -Wno-unused-but-set-variable \
	-o "$HERE/busbench_os" "$HERE/busbench_os.c" \
	-lamiga

# ---- codegen check: the loops must still BE the loops -------------------
# This is not belt-and-braces.  The write32/write16 ratio is the bus-width
# discriminator, and gcc merges adjacent 16-bit stores into 32-bit ones the moment
# volatile stops holding it back -- at which point write16 measures itself and the
# ratio silently becomes meaningless while every number still looks plausible.
# So verify the emitted instructions, not the source.  Same reasoning as
# src/check_page_geometry.sh on the AMIX side.
#
# WHAT THIS CHECK HAS AND HAS NOT DEMONSTRATED (measured 2026-08-22):
#   - It DISCRIMINATES: fed a wword() deliberately rewritten to do 32-bit stores, the
#     16-bit store count goes 4 -> 0 and the build fails.  Proven by injection, not assumed.
#   - It is FAIL-SAFE: if the awk body extraction ever stops matching, the count is 0 and
#     the build FAILS.  A broken check cannot pass silently.
#   - It has NEVER FIRED on real input.  gcc 6.5 for m68k does not merge these word stores
#     even with volatile removed -- tested both ways.  So volatile here is a guard against
#     a future compiler, not a fix for an observed defect.  Do not remove it on the grounds
#     that "the check passes anyway"; the check passing is what it looks like when the
#     guard is working.
"$GCC" -O2 -m68020 -fomit-frame-pointer -S -o "$HERE/.busbench_os.s" "$HERE/busbench_os.c"

fail=0
body() { awk "/^_$1:/{on=1} on{print} on&&/rts/{exit}" "$HERE/.busbench_os.s"; }

n=$(body wlong | grep -c "move\.l %*d[0-9]*,(")
[ "$n" -ge 4 ] || { echo "[FAIL] wlong: expected >=4 32-bit stores in the loop, found $n"; fail=1; }

n=$(body wword | grep -c "move\.w #23130,(")
[ "$n" -ge 4 ] || { echo "[FAIL] wword: expected >=4 SEPARATE 16-bit stores of 0x5a5a, found $n"; \
                    echo "       gcc has merged the word stores -- the width ratio is now meaningless"; fail=1; }

n=$(body rlong | grep -c "move\.l ([0-9]*,*%*a[0-9]*),")
[ "$n" -ge 3 ] || { echo "[FAIL] rlong: expected >=3 32-bit loads in the loop, found $n"; fail=1; }

grep -qE "jsr .*mem(set|cpy)|jbsr .*mem" "$HERE/.busbench_os.s" && \
	{ echo "[FAIL] a loop was turned into a memset/memcpy call"; fail=1; }

rm -f "$HERE/.busbench_os.s"
[ "$fail" -eq 0 ] || { echo "[FAIL] codegen check failed -- the AmigaOS and AMIX builds no longer measure the same thing"; exit 1; }
echo "      codegen OK: 4x32-bit stores, 4x SEPARATE 16-bit stores, 4x32-bit loads, no memset"


ls -l "$HERE/busbench_os"
echo "[OK] built $HERE/busbench_os"
echo
echo "Copy to the Amiga and run, in this order:"
echo "    busbench_os -l                        # what is on the bus, and at what address"
echo "    busbench_os 6d6e:1 1048576 10000      # VA2000 framebuffer (reference runs first)"
