# batteryrun-260819-13.sh -- battery driver for image 68040/68060-260819-13
#   artifact sha256 8131fc300e6a452d3388b0a5c88fd1e2d9c8cdf8d0aa78969a964b6091739009
#   built from wip/zorro3; load base 0x08000000 (Mercury)
#
# Addresses come from `sh tools/status-facts.sh build/unix-040-va2000-dbg` on the
# host.  They are image- and load-base-specific: an A3640 binds 16 MiB lower and
# EVERY address here is then wrong.  Do not reuse this file for another image.
#
# EVERY block that is read is magic-checked first -- ten blocks, ten checks.
# batteryrun10.sh read nine and checked eight (segvn_prot), while its header said
# otherwise; see docs/ACCEPTANCE.md.  Count them yourself before trusting this.
#
#   (nohup sh -c "sh /tmp/batteryrun-260819-13.sh > /tmp/battery.log 2>&1" &)
K=/kpeek

CMF=0810F2BC        ; CMF_N=5
F60=0810FD9C        ; F60_N=31
FPC=0810F784        ; FPC_N=13
I39=0810FCF8        ; I39_N=14
I40=0810FD30        ; I40_N=13
ISP61=0810F748      ; ISP61_N=15
KVP=0810F7B8        ; KVP_N=9
PTD=0810FD64        ; PTD_N=11
SEGVN_PROT=0810F6DC ; SEGVN_PROT_N=5
WBF=0810F610        ; WBF_N=25

echo "=== IDENTITY ==="
uname -m

echo "=== MAGIC CHECK (10 blocks, 10 checks) ==="
chk() {
	m=`$K $1 1 | sed "s/.*= //;s/ .*//"`
	if [ "$m" != "$2" ]; then
		echo "ABORT: $3 = $m, expected $2"; exit 1
	fi
}
chk $CMF        434d4642 cmf_magic
chk $F60        46503630 f60_magic
chk $FPC        46504321 fpc_magic
chk $I39        49333921 i39_magic
chk $I40        49343021 i40_magic
chk $ISP61      49363121 isp61_magic
chk $KVP        4b565021 kvp_magic
chk $PTD        50544421 ptd_magic
chk $SEGVN_PROT 53564e21 segvn_prot_magic
chk $WBF        57424621 wbf_magic
echo "all 10 magics OK"

dump() {
	echo "cmf:"        ; $K $CMF        $CMF_N
	echo "f60:"        ; $K $F60        $F60_N
	echo "fpc:"        ; $K $FPC        $FPC_N
	echo "i39:"        ; $K $I39        $I39_N
	echo "i40:"        ; $K $I40        $I40_N
	echo "isp61:"      ; $K $ISP61      $ISP61_N
	echo "kvp:"        ; $K $KVP        $KVP_N
	echo "ptd:"        ; $K $PTD        $PTD_N
	echo "segvn_prot:" ; $K $SEGVN_PROT $SEGVN_PROT_N
	echo "wbf:"        ; $K $WBF        $WBF_N
}

echo "=== COUNTERS BEFORE ==="
dump

echo "=== BATTERY ==="
cd /tmp
echo "---- proctest";    ./proctest
echo "---- fputest";     ./fputest
echo "---- mlocktest";   ./mlocktest
echo "---- msynctst";    ./msynctst
echo "---- mincoretst";  ./mincoretst
echo "---- bigargv";     ./bigargv
echo "---- ptracepoke";  ./ptracepoke
echo "---- bmaptest";    ./bmaptest
echo "---- devmaptest";  ./devmaptest
echo "---- exectest 20"; ./exectest 20
echo "---- mul64test";   ./mul64test
echo "---- protfault a"; ./protfault a
echo "---- protfault b"; ./protfault b

echo "=== COUNTERS AFTER ==="
dump

echo "=== VERDICT ==="
# One expected success line per test.  A MISSING line is a FAIL, not a pass --
# fputest carries no -RESULT token and mul64test says WRONG rather than FAIL, so
# a generic grep would report a broken battery as green (docs/ACCEPTANCE.md).
L=/tmp/battery.log
bad=0
want() {
	if grep "$1" $L > /dev/null 2>&1; then
		echo "  ok      $2"
	else
		echo "  MISSING $2   (expected: $1)"; bad=`expr $bad + 1`
	fi
}
want "PROCTEST-RESULT PASS"   proctest
want "FPUTEST Test A PASS"    fputest
want "MLOCKTEST-RESULT PASS"  mlocktest
want "MSYNC-OK"               msynctst
want "MINCORE PASS"           mincoretst
want "BIGARGV PASS"           bigargv
want "PTRACEPOKE-RESULT PASS" ptracepoke
want "BMAPTEST-RESULT PASS"   bmaptest
want "DEVMAPTEST-RESULT PASS" devmaptest
want "EXECTEST-RESULT PASS"   exectest
want "MUL64-RESULT PASS"      mul64test
want "PROTFAULT-RESULT PASS"  protfault
if [ $bad -eq 0 ]; then
	echo "BATTERY-RESULT PASS"
else
	echo "BATTERY-RESULT FAIL ($bad missing)"
fi
