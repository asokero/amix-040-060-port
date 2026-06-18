#!/bin/sh
# relink-pstart.sh -- override pstart in the AMIX kernel and relink -> unix-040.
#
# This is the Draft-2 relink driver.  It renames the kernel's existing `pstart`
# to `pstart_030`, then links in a replacement object that (re)defines `pstart`.
# Because the final `unix` is itself a relocatable `ld -r` object (symbols +
# R_68K_32 relocs intact), callers of `pstart` re-resolve to the replacement and
# the original stays as `pstart_030`.
#
# Toolchains (both operate on elf32-m68k):
#   * m68k-linux-gnu-objcopy  -- modern binutils, for --redefine-sym
#     (the cross objcopy 2.8.1 lacks it).
#   * m68k-cbm-sysv4-ld       -- cross ld; round-trips the kernel byte-faithfully
#     (verified: same text/data/bss, symbol & reloc counts).
#   * m68k-cbm-sysv4-gcc      -- cross as, to assemble the replacement object.
#
# Usage:
#   sh relink-pstart.sh                 # VALIDATION: trampoline (behaves like stock)
#   sh relink-pstart.sh path/to/pstart040.o   # Draft 2: real 040 pstart
#
# Output: build/unix-040
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
STOCK="${STOCK:-/home/asokero/kehitys/amix-playground/vanilla/stand/unix}"
ENV="/home/asokero/kehitys/amix-playground/gcc-cross-amix/build/env.sh"
. "$ENV"

mkdir -p "$HERE/build"
REPL="$1"

# 1. Replacement object: caller-supplied .o, or build the validation trampoline.
#    Distinct output names so the relink-test kernel can't be confused with the
#    Draft-1 no-paging probe (also build/unix-040) or a real Draft-2 build.
if [ -z "$REPL" ]; then
    echo "[*] no replacement given -> building validation trampoline (jmp pstart_030)"
    REPL="$HERE/build/pstart_repl.o"
    m68k-cbm-sysv4-gcc -c "$HERE/prototypes/pstart_trampoline.s" -o "$REPL"
    OUT="$HERE/build/unix-040-relinktest"
    MODE="trampoline (should boot IDENTICALLY to stock unix)"
else
    echo "[*] using replacement object: $REPL"
    OUT="$HERE/build/unix-040"
    MODE="custom pstart replacement"
fi

# 2. Rename the kernel's original pstart -> pstart_030.
echo "[*] renaming stock pstart -> pstart_030"
cp "$STOCK" "$HERE/build/unix-stage1"
m68k-linux-gnu-objcopy --redefine-sym pstart=pstart_030 "$HERE/build/unix-stage1"

# 3. Relink the kernel with the replacement object (cross ld -r).
echo "[*] relinking -> $OUT"
m68k-cbm-sysv4-ld -r -o "$OUT" "$HERE/build/unix-stage1" "$REPL"

# 4. Verify the override resolved.
echo
echo "[*] result symbols:"
m68k-linux-gnu-nm "$OUT" | grep -E ' (pstart|pstart_030)$' | sed 's/^/      /'
NEW=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="pstart"{print $1}')
echo "[*] new pstart @ 0x$NEW:"
m68k-linux-gnu-objdump -dr --start-address=0x$NEW --stop-address=$((0x$NEW+12)) "$OUT" \
    2>/dev/null | sed -n '/<pstart>:/,$p' | sed 's/^/      /' | head -6
echo
m68k-linux-gnu-size "$OUT" | sed 's/^/      /'

# 5. Verify .text/.data stay contiguous in the file (unix_boot/copyit require it:
#    they copy text+data as one block).  ld pads .data to its alignment, so the
#    replacement object's .text must be a multiple of 4 bytes.
echo
CONTIG=$(m68k-linux-gnu-readelf -SW "$OUT" 2>/dev/null | awk '
    {gsub(/[][]/,"")}
    $2==".text" {to=strtonum("0x"$5); ts=strtonum("0x"$6)}
    $2==".data" {do_=strtonum("0x"$5)}
    END{printf("%d %d", to+ts, do_)}')
set -- $CONTIG
if [ "$1" = "$2" ]; then
    echo "[OK] text/data contiguous (text_end=0x$(printf %x $1) == data_off)."
else
    echo "[FAIL] text/data NOT contiguous: text_end=0x$(printf %x $1) data_off=0x$(printf %x $2)"
    echo "       -> pad the replacement object's .text to a multiple of 4 bytes."
    exit 1
fi
echo
echo "[OK] built $OUT  ($MODE)"
echo "     copy to your AmigaDOS volume and boot:  unix_boot $(basename "$OUT")"
