#!/bin/sh
# check_page_geometry.sh -- assert, in the COMPILED BYTES, that an object uses
# the Model-B 4 KiB page shift and not the stock 2 KiB one (2026-08-01).
#
# Generalised from the per-driver check that shipped inside relink-040-z3660.sh,
# because the question is not about one driver: any C compiled into this kernel
# can carry a 2 KiB page shift, and the defect is invisible in behaviour until
# it maps the wrong physical page.  The source-level and header-level fixes are
# both upstream of this; this is the thing that FAILS THE BUILD if either was
# skipped.
#
# THE SIGNATURE is a shift BY 11 -- `moveq #11,%dN` immediately followed by an
# `lsrl` OR `asrl` -- never the constant 11 on its own.  Drivers legitimately
# load 11 as a value (a SCSI CDB length compare, a DLPI constant), and an
# over-eager grep on `moveq #11` fails on those.  Learned the hard way; do not
# "simplify".
#
# BOTH shift forms are required, and that is not pedantry: z3660.c's
# phystopfn(paddr_t) is unsigned and compiles to `lsrl`, while va2000.c's
# hand-written `(base + offset) >> 11` is SIGNED and compiles to `asrl`.  A
# checker that only knew `lsrl` reported the va2000 object clean -- measured
# 2026-08-01, and it is exactly the object with a hardcoded 2 KiB shift.
#
# NOTE ON SCOPE.  Headers (include-modelb/) fix macro users such as phystopfn,
# btop and btopr.  They CANNOT fix a literal `>> 11` written into a driver's
# source -- va2000.c has one, which is why va2000_modelb.py stays load-bearing.
# This object-level check is what covers both cases at once.
#
# An object with NO page shift at all is reported and accepted: plenty of
# compiled-in code never converts an address to a page number.  What is refused
# is a shift by 11.
#
# usage: sh src/check_page_geometry.sh obj.o [obj.o ...]
set -e

OD="${OBJDUMP:-m68k-linux-gnu-objdump}"
rc=0

for o in "$@"; do
	[ -f "$o" ] || { echo "[FAIL] $(basename "$o"): no such object"; rc=1; continue; }
	d=$("$OD" -d "$o")
	bad=$(echo "$d" | grep -A1 "moveq #11," | grep -cE "lsrl|asrl" || true)
	good=$(echo "$d" | grep -A1 "moveq #12," | grep -cE "lsrl|asrl" || true)
	if [ "$bad" -gt 0 ]; then
		echo "[FAIL] $(basename "$o"): $bad site(s) shift by 11 (2 KiB page) -- Model-B geometry did NOT reach this compile"
		rc=1
	elif [ "$good" -gt 0 ]; then
		echo "[OK]   $(basename "$o"): $good page shift(s), all by 12 (4 KiB)"
	else
		echo "[--]   $(basename "$o"): no page shift in this object"
	fi
done

exit $rc
