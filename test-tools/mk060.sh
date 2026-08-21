# mk060.sh -- compile the 68060-specific tests in the guest.
# Same compiler rule as mkall6.sh and for the same reason: /usr/bin/cc is a gcc
# wrapper whose own cpp/cc1 contain 64-bit muls.l, which the 68060 does not
# implement, so it dies on vector 61 before it reaches the source.
#     (nohup sh -c "sh /tmp/mk060.sh > /tmp/mk060.log 2>&1" &)
#
# ⚠ IT ONLY BUILDS ONE OF THE FOUR, and that is not a bug in the script -- it is
# what the guest compiler can do.  Measured 2026-08-21:
#   fputest060   builds here.
#   fp060probe   does NOT: it uses __asm__ volatile, which the 1991 AT&T cc does
#                not know ("undefined symbol: __asm__").
#   isp61ea      does NOT: isp61ea_asm.s is GNU assembler syntax (# immediates)
#                and /usr/ccs/bin/as rejects it ("invalid instruction name").
#   fpenab060    likewise.
# Those three are CROSS-BUILT ON THE HOST and transferred as binaries:
#   m68k-cbm-sysv4-gcc -m68040 -o fp060probe fp060probe.c
#   m68k-linux-gnu-as -m68040 isp61ea_asm.s -o isp61ea_asm.o
#   m68k-cbm-sysv4-gcc -m68040 -o isp61ea isp61ea.c isp61ea_asm.o
# fpenab060_asm.s does not assemble with the GNU as here either (line 36); its
# recipe is still unknown and it was skipped on 2026-08-21.
CC=/usr/ccs/bin/cc
cd /tmp
echo "==== $CC fp060probe"
$CC -o fp060probe fp060probe.c 2>&1 | tail -5
echo "==== $CC fputest060"
$CC -o fputest060 fputest060.c 2>&1 | tail -5
echo "==== $CC isp61ea (+ asm)"
$CC -o isp61ea isp61ea.c isp61ea_asm.s 2>&1 | tail -5
echo "==== $CC fpenab060 (+ asm)"
$CC -o fpenab060 fpenab060.c fpenab060_asm.s 2>&1 | tail -5
ls -l fp060probe fputest060 isp61ea fpenab060 2>&1
echo MK060-DONE
