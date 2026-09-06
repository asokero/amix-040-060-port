# va2probe.sh -- which accesses does the VA2000 decode?  Bourne sh for the guest.
#
# Each probe is its own process: a user bus error is SIGKILL here and cannot be caught,
# so a missing "VA2BYTE OK" line IS the result.  Exit 137 = 128 + SIGKILL(9).
#
# Write probes read the location and write THE SAME VALUE BACK, so the bus cycle happens
# and nothing changes.  Order is by rising risk: read-only registers, then the framebuffer,
# then the register the write-back replay actually died on (0x70/0x71), then the control.
#
# 0x2000 is the POSITIVE CONTROL -- the undecoded gap between the register window (ends
# 0x1000) and the framebuffer (starts 0x10000).  It must die.  If it survives, the harness
# is not detecting deaths and no other line means anything.
cd /tmp
for probe in "0 b x" "1 b x" "0 w x" \
             "10000 b x" "10001 b x" "10000 w x" \
             "70 b x" "71 b x" "70 w x" \
             "2000 b r"
do
	set -- $probe
	./va2byte $1 $2 $3
	echo "VA2BYTE EXIT off=$1 width=$2 mode=$3 status=$?"
done
echo VA2PROBE-DONE
