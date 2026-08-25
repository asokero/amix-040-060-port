# batteryrun-260825-02.sh -- battery driver for image 68040/68060-260825-02
#   artifact sha256 35203427648337dd55f756d6039c7a209887355e7e58982efbde449f1edc7e3c
#   built from main at the z3660 merge; load base 0x08000000 (Mercury)
#
# Addresses come from `sh tools/status-facts.sh` on the host and are image- AND
# load-base-specific: an A3640 binds 16 MiB lower and EVERY address here is then
# wrong.  Do not reuse this file for another image.
#
# 30 BLOCKS, 30 CHECKS.  The previous driver read ten because the tree had ten; the
# z3660 merge brought that to 30, and a driver that checks the old ten would report a
# green battery while twenty blocks went unverified.  Count them yourself.
#
# VERIFY THE ARTIFACT FIRST.  The banner reports the CPU, not the image, so two
# different kernels can both say 68060-260825-02.  The sha256 above is the identity:
#     sum -r /unix   (or cksum) against the host's value before trusting anything below.
#
#   (nohup sh -c "sh /tmp/batteryrun-260825-02.sh > /tmp/battery.log 2>&1" &)
K=/kpeek
CMF         =0810D548 ; CMF_N=5
WBF         =0810D89C ; WBF_N=27
SEGVN_PROT  =0810D9BC ; SEGVN_PROT_N=5
ISP61       =0810DA28 ; ISP61_N=15
FPC         =0810DA64 ; FPC_N=13
KVP         =0810DA98 ; KVP_N=9
I39         =0810DFD8 ; I39_N=14
I40         =0810E010 ; I40_N=13
PTD         =0810E044 ; PTD_N=11
SYNCG       =0810E070 ; SYNCG_N=5
PGZ         =0810E084 ; PGZ_N=12
SMU         =0810E0B4 ; SMU_N=44
BT          =0810E164 ; BT_N=7
UNT         =0810E180 ; UNT_N=10
SRG         =0810E1A8 ; SRG_N=17
INI         =0810E234 ; INI_N=7
IUR         =0810E250 ; IUR_N=16
HG          =0810E290 ; HG_N=16
I10         =0810E2D0 ; I10_N=6
I10P        =0810E2E8 ; I10P_N=77
I10W        =0810E41C ; I10W_N=59
I10G        =0810E508 ; I10G_N=132
I10T        =0810E718 ; I10T_N=50
I10R        =0810E7E0 ; I10R_N=79
I10S        =0810E91C ; I10S_N=46
I10A        =0810E9D4 ; I10A_N=31
I10B        =0810EA50 ; I10B_N=23
I10C        =0810EAAC ; I10C_N=37
I10D        =0810EB40 ; I10D_N=14
F60         =0810EDC0 ; F60_N=31

echo "=== IDENTITY ==="
uname -m

echo "=== MAGIC CHECK (30 blocks, 30 checks) ==="
chk() {
	m=`$K $1 1 | sed "s/.*= //;s/ .*//"`
	if [ "$m" != "$2" ]; then
		echo "ABORT: $3 = $m, expected $2"; exit 1
	fi
}
chk $CMF          434d4642 cmf_magic
chk $WBF          57424621 wbf_magic
chk $SEGVN_PROT   53564e21 segvn_prot_magic
chk $ISP61        49363121 isp61_magic
chk $FPC          46504321 fpc_magic
chk $KVP          4b565021 kvp_magic
chk $I39          49333921 i39_magic
chk $I40          49343021 i40_magic
chk $PTD          50544421 ptd_magic
chk $SYNCG        53594e47 syncg_magic
chk $PGZ          50475a21 pgz_magic
chk $SMU          534d5521 smu_magic
chk $BT           42545721 bt_magic
chk $UNT          554e5421 unt_magic
chk $SRG          53524721 srg_magic
chk $INI          494e5421 ini_magic
chk $IUR          49555221 iur_magic
chk $HG           48474621 hg_magic
chk $I10          49313021 i10_magic
chk $I10P         49313050 i10p_magic
chk $I10W         49315721 i10w_magic
chk $I10G         49314721 i10g_magic
chk $I10T         49315421 i10t_magic
chk $I10R         49315221 i10r_magic
chk $I10S         49315321 i10s_magic
chk $I10A         49314121 i10a_magic
chk $I10B         49314221 i10b_magic
chk $I10C         49314321 i10c_magic
chk $I10D         49314421 i10d_magic
chk $F60          46503630 f60_magic
echo "all 30 magics OK"

dump() {
	echo "cmf:"           ; $K $CMF $CMF_N
	echo "wbf:"           ; $K $WBF $WBF_N
	echo "segvn_prot:"    ; $K $SEGVN_PROT $SEGVN_PROT_N
	echo "isp61:"         ; $K $ISP61 $ISP61_N
	echo "fpc:"           ; $K $FPC $FPC_N
	echo "kvp:"           ; $K $KVP $KVP_N
	echo "i39:"           ; $K $I39 $I39_N
	echo "i40:"           ; $K $I40 $I40_N
	echo "ptd:"           ; $K $PTD $PTD_N
	echo "syncg:"         ; $K $SYNCG $SYNCG_N
	echo "pgz:"           ; $K $PGZ $PGZ_N
	echo "smu:"           ; $K $SMU $SMU_N
	echo "bt:"            ; $K $BT $BT_N
	echo "unt:"           ; $K $UNT $UNT_N
	echo "srg:"           ; $K $SRG $SRG_N
	echo "ini:"           ; $K $INI $INI_N
	echo "iur:"           ; $K $IUR $IUR_N
	echo "hg:"            ; $K $HG $HG_N
	echo "i10:"           ; $K $I10 $I10_N
	echo "i10p:"          ; $K $I10P $I10P_N
	echo "i10w:"          ; $K $I10W $I10W_N
	echo "i10g:"          ; $K $I10G $I10G_N
	echo "i10t:"          ; $K $I10T $I10T_N
	echo "i10r:"          ; $K $I10R $I10R_N
	echo "i10s:"          ; $K $I10S $I10S_N
	echo "i10a:"          ; $K $I10A $I10A_N
	echo "i10b:"          ; $K $I10B $I10B_N
	echo "i10c:"          ; $K $I10C $I10C_N
	echo "i10d:"          ; $K $I10D $I10D_N
	echo "f60:"           ; $K $F60 $F60_N
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
