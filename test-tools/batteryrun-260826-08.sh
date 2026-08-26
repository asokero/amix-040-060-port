# batteryrun-260826-08.sh -- battery driver for 68040/68060-260826-08
#   artifact sha256 c050e9afb967555d0e67432c6f76c940d83b4d37dcf1ba830a3ec3fc5b8283ea
#   loader: image checksum = 1100cc99 (277723 longs)
#   main with the ISSUE-49 paired-vpage bridge; load base 0x08000000
#
# 33 BLOCKS, 33 CHECKS.  Count them yourself.
#
# THIS IS THE FIRST DRIVER THAT CAN GO 12/12.  devmaptest has been the only miss in every
# run since it was written; the bridge makes its T1 pass.  If devmaptest is MISSING here,
# that is a regression and not the familiar red.
K=/kpeek
CMF=0810D8F4          ; CMF_N=5
WBF=0810DC48          ; WBF_N=27
SEGVN_PROT=0810DD68   ; SEGVN_PROT_N=5
ISP61=0810DDD4        ; ISP61_N=15
FPC=0810DE10          ; FPC_N=16
FPI=0810DE50          ; FPI_N=17
KVP=0810DE9C          ; KVP_N=9
A3D=0810E440          ; A3D_N=19
SDC=0810E48C          ; SDC_N=9
I39=0810E4FC          ; I39_N=14
I40=0810E534          ; I40_N=13
PTD=0810E568          ; PTD_N=11
SYNCG=0810E594        ; SYNCG_N=5
PGZ=0810E5A8          ; PGZ_N=12
SMU=0810E5D8          ; SMU_N=44
BT=0810E688           ; BT_N=9
UNT=0810E6AC          ; UNT_N=10
SRG=0810E6D4          ; SRG_N=17
INI=0810E760          ; INI_N=7
IUR=0810E77C          ; IUR_N=16
HG=0810E7BC           ; HG_N=16
I10=0810E7FC          ; I10_N=6
I10P=0810E814         ; I10P_N=77
I10W=0810E948         ; I10W_N=59
I10G=0810EA34         ; I10G_N=132
I10T=0810EC44         ; I10T_N=50
I10R=0810ED0C         ; I10R_N=79
I10S=0810EE48         ; I10S_N=46
I10A=0810EF00         ; I10A_N=31
I10B=0810EF7C         ; I10B_N=23
I10C=0810EFD8         ; I10C_N=37
I10D=0810F06C         ; I10D_N=14
F60=0810F2EC          ; F60_N=32

echo "=== IDENTITY ==="
uname -m
echo "=== MAGIC CHECK (33 blocks, 33 checks) ==="
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
chk $FPI          46504921 fpi_magic
chk $KVP          4b565021 kvp_magic
chk $A3D          41334421 a3d_magic
chk $SDC          53444321 sdc_magic
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
echo "all 33 magics OK"

dump() {
	echo "cmf:"           ; $K $CMF $CMF_N
	echo "wbf:"           ; $K $WBF $WBF_N
	echo "segvn_prot:"    ; $K $SEGVN_PROT $SEGVN_PROT_N
	echo "isp61:"         ; $K $ISP61 $ISP61_N
	echo "fpc:"           ; $K $FPC $FPC_N
	echo "fpi:"           ; $K $FPI $FPI_N
	echo "kvp:"           ; $K $KVP $KVP_N
	echo "a3d:"           ; $K $A3D $A3D_N
	echo "sdc:"           ; $K $SDC $SDC_N
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
