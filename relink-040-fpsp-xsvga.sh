#!/bin/sh
# relink-040-fpsp-xsvga.sh -- RETIRED 2026-07-26.  Do not use.
#
# This script existed to produce ONE kernel carrying both the Motorola FPSP and the
# Xsvga driver, back when FPSP was an add-on layer.  FPSP is now part of the base link
# (see the FPSP block in relink-040.sh), so "base + FPSP + xsvga" and "base + xsvga"
# are the same thing and this script is a duplicate of relink-040-xsvga.sh.
#
#   Xsvga only:        sh relink-040-xsvga.sh  [base] [exp]
#   VA2000 only:       sh relink-040-va2000.sh [base] [out]
#   BOTH RTG drivers:  sh relink-040-rtg.sh    [base] [out]
#
# Kept as a stub rather than deleted so an old command line fails loudly instead of
# quietly building a kernel from a stale default base -- which is exactly what happened
# on 2026-07-25.  Git history has the original.
echo "relink-040-fpsp-xsvga.sh is RETIRED -- FPSP is in the base link."
echo "  Xsvga only:       sh relink-040-xsvga.sh"
echo "  both RTG drivers: sh relink-040-rtg.sh"
exit 1
