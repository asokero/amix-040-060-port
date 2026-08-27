# batteryrun-260827-06.sh -- battery driver for 68040/68060-260827-06
#   artifact sha256 c2fb10fcf7fc64a4dfdc8d2ab7203d5049592dd7af2a50857c47fa8085fae582
#   main with the ISSUE-53 A3091 interrupt-source demux; load base 0x08000000
#
# Relinking bumps the build id and the sha256 every time.  The ADDRESSES below only move
# when a counter block is added, removed or resized -- so if you rebuild, check the sha,
# and re-run `tools/status-facts.sh` and diff its block table before trusting them.
#
# 34 BLOCKS, 34 CHECKS.  Count them yourself.
#
# NEW BLOCK: a3w, the A3091 interrupt-source classifier (ISSUE-53).  It sits in int2_tbl's
# A3091 slot, so a3w_calls counts EVERY level-2 interrupt on the machine and is the
# denominator that proves the wrapper is in the table at all.  Four counters must read
# 00000000 and are checked directly rather than through the log, so no grep can match its
# own heading.  a3w_eint_only is the reading the whole unit exists to produce: non-zero
# means a pure SDMAC event really does arrive and really was being dispatched as a WD
# completion.  Reconcile the three invariants from the dump afterwards:
#     a3w_calls      = a3w_nodev + a3w_notours + a3w_own
#     a3w_own        = a3w_ints_only + a3w_ints_eint + a3w_eint_only + a3w_other
#     a3w_eint_acked = (a3w_eint_only - a3w_eint_deleg) + a3w_resid_eint
#
# a3d gained two counters on 2026-08-27 (a3d_devp, a3d_istr appended at the END), so
# A3D_N is 21 here where every earlier driver said 19.
#
# The ISSUE-49 bridge is still in: this driver can go 12/12.  If devmaptest is MISSING,
# that is a regression and not the familiar red.
#
#   (nohup sh -c "sh /tmp/batteryrun-260827-06.sh > /tmp/battery.log 2>&1" &)
K=/kpeek
CMF=0810DA78          ; CMF_N=5
WBF=0810DDCC          ; WBF_N=27
SEGVN_PROT=0810DEEC   ; SEGVN_PROT_N=5
ISP61=0810DF58        ; ISP61_N=15
FPC=0810DF94          ; FPC_N=16
FPI=0810DFD4          ; FPI_N=17
KVP=0810E020          ; KVP_N=9
A3D=0810E5E0          ; A3D_N=21
A3W=0810E658          ; A3W_N=21
SDC=0810E6AC          ; SDC_N=9
I39=0810E71C          ; I39_N=14
I40=0810E754          ; I40_N=13
PTD=0810E788          ; PTD_N=11
SYNCG=0810E7B4        ; SYNCG_N=5
PGZ=0810E7C8          ; PGZ_N=12
SMU=0810E7F8          ; SMU_N=44
BT=0810E8A8           ; BT_N=9
UNT=0810E8CC          ; UNT_N=10
SRG=0810E8F4          ; SRG_N=17
INI=0810E980          ; INI_N=7
IUR=0810E99C          ; IUR_N=16
HG=0810E9DC           ; HG_N=16
I10=0810EA1C          ; I10_N=6
I10P=0810EA34         ; I10P_N=77
I10W=0810EB68         ; I10W_N=59
I10G=0810EC54         ; I10G_N=132
I10T=0810EE64         ; I10T_N=50
I10R=0810EF2C         ; I10R_N=79
I10S=0810F068         ; I10S_N=46
I10A=0810F120         ; I10A_N=31
I10B=0810F19C         ; I10B_N=23
I10C=0810F1F8         ; I10C_N=37
I10D=0810F28C         ; I10D_N=14
F60=0810F50C          ; F60_N=32

echo "=== IDENTITY ==="
uname -m
echo "=== MAGIC CHECK (34 blocks, 34 checks) ==="
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
chk $A3W          41335721 a3w_magic
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
echo "all 34 magics OK"

dump() {
	echo "cmf:"           ; $K $CMF $CMF_N
	echo "wbf:"           ; $K $WBF $WBF_N
	echo "segvn_prot:"    ; $K $SEGVN_PROT $SEGVN_PROT_N
	echo "isp61:"         ; $K $ISP61 $ISP61_N
	echo "fpc:"           ; $K $FPC $FPC_N
	echo "fpi:"           ; $K $FPI $FPI_N
	echo "kvp:"           ; $K $KVP $KVP_N
	echo "a3d:"           ; $K $A3D $A3D_N
	echo "a3w:"           ; $K $A3W $A3W_N
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

# ISSUE-53 must-stay-zero readings.  Read from the device, not from the log, so that no
# pattern here can match a line this script itself printed -- the trap that bit five
# separate checks on 2026-08-26.  Addresses are spelled out because AMIX `expr` cannot do
# hex arithmetic, and a wrong offset here would read a plausible number from a neighbour.
A3W_RAN=0810E65C
A3W_CALLS=0810E664
A3W_NODEV=0810E668
A3W_OWN=0810E670
A3W_EINT_ONLY=0810E67C
A3W_OTHER=0810E680
A3W_EINT_ACKED=0810E684
A3W_DEAD_N=0810E6A4
A3D_N=0810E5E8

echo "=== ISSUE-53 A3091 SOURCE CLASSIFIER ==="
peek1() { $K $1 1 | sed "s/.*= //;s/ .*//"; }
a3wbad=0
iszero() {
	v=`peek1 $1`
	if [ "$v" != "00000000" ]; then
		echo "  NONZERO $2 = $v"; a3wbad=`expr $a3wbad + 1`
	else
		echo "  zero    $2"
	fi
}
r=`peek1 $A3W_RAN`
if [ "$r" = "41335752" ]; then
	echo "  ran     a3w_ran = $r"
else
	echo "  NOT-RUN a3w_ran = $r, expected 41335752"; a3wbad=`expr $a3wbad + 1`
fi
echo "  denom   a3w_calls      = `peek1 $A3W_CALLS`   (every level-2 interrupt)"
echo "  denom   a3w_own        = `peek1 $A3W_OWN`   (INT_P set at entry)"
echo "  READING a3w_eint_only  = `peek1 $A3W_EINT_ONLY`   (pure SDMAC events)"
echo "  READING a3w_eint_acked = `peek1 $A3W_EINT_ACKED`   (CINT strobes issued)"
iszero $A3W_NODEV  a3w_nodev
iszero $A3W_OTHER  a3w_other
iszero $A3W_DEAD_N a3w_dead_n
iszero $A3D_N      a3d_n
if [ $a3wbad -eq 0 ]; then
	echo "A3W-ZEROS-OK"
else
	echo "A3W-ZEROS-BAD ($a3wbad nonzero)"
fi
