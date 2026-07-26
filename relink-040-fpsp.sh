#!/bin/sh
# relink-040-fpsp.sh -- RETIRED 2026-07-26.  Do not use.
#
# The Motorola FPSP is no longer an add-on layer: it is part of the BASE link in
# relink-040.sh.  The reason is in that script's FPSP block -- the 68040 traps the
# FP instructions it does not implement, so completing the ISA is the kernel's job,
# and a kernel without FPSP is an incomplete 68040 rather than a kernel missing an
# option.  Keeping it separate also doubled the kernel matrix and caused the
# 2026-07-25 near-miss where the graphics kernels were built from a stale base.
#
#   FPSP kernel:      sh relink-040.sh            (then relink-040-dbg.sh for probes)
#   NO-FPSP bisect:   FPSP=0 sh relink-040.sh
#
# Kept as a stub rather than deleted so an old command line fails loudly instead of
# silently doing nothing.  Git history has the original.
echo "relink-040-fpsp.sh is RETIRED -- FPSP is in the base link."
echo "  build with FPSP:    sh relink-040.sh"
echo "  build without FPSP: FPSP=0 sh relink-040.sh"
exit 1
