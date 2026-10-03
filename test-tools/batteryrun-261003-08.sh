# batteryrun-261003-08.sh -- GENERATED, do not edit by hand.
#   sh tools/gen-battery.sh build/unix-040-rtg 0x08000000 > test-tools/batteryrun-261003-08.sh
#
#   artifact   build/unix-040-rtg
#   build id   68040-261003-08
#   sha256     7f335b5774fe8d6cfd9f835ebd1b1b3f5c26ee3072d76d39220a9e66e52c0471
#   load base  0x08000000   <- from the loader's boot output, not assumed
#   text       1047532 (0xffbec)
#
# Relinking bumps the build id and the sha256 every time, and moves these addresses whenever a
# counter block is added, removed or resized.  Regenerate rather than edit: `uname -m` on the
# guest must print the build id above, and the magic check below is what proves the addresses
# belong to the kernel that is actually running.
#
# 40 BLOCKS, 40 CHECKS.  A block whose magic does not read back aborts the run: every
# other number taken from a wrong address is plausible, and none of it is a measurement.
#
#   (nohup sh -c "sh /tmp/batteryrun-261003-08.sh /tmp/battery.log > /tmp/battery.log 2>&1" &)
K=/kpeek

LKX=081185EC            # the block is not contiguous: 2 reads
LKX_R1=081185EC
LKX_N1=17               # 17 longwords
LKX_R2=0811894C
LKX_N2=6                # 6 longwords
A3D=08118CEC
A3D_R1=08118CEC
A3D_N1=21               # 21 longwords
A3P=08118D40
A3P_R1=08118D40
A3P_N1=79               # 79 longwords
A3W=08118EC4
A3W_R1=08118EC4
A3W_N1=25               # 25 longwords
BT=08119160
BT_R1=08119160
BT_N1=9                 # 9 longwords
CMF=08117EEC
CMF_R1=08117EEC
CMF_N1=5                # 5 longwords
DMA=08118988            # the block is not contiguous: 2 reads
DMA_R1=08118988
DMA_N1=16               # 16 longwords
DMA_R2=0811E338
DMA_N2=1                # 1 longwords
F60=08119DC4
F60_R1=08119DC4
F60_N1=32               # 32 longwords
FPC=08118428
FPC_R1=08118428
FPC_N1=16               # 16 longwords
FPI=08118468
FPI_R1=08118468
FPI_N1=17               # 17 longwords
HBU=081185D4
HBU_R1=081185D4
HBU_N1=6                # 6 longwords
HG=08119294
HG_R1=08119294
HG_N1=16                # 16 longwords
I10=081192D4
I10_R1=081192D4
I10_N1=6                # 6 longwords
I10A=081199D8
I10A_R1=081199D8
I10A_N1=31              # 31 longwords
I10B=08119A54
I10B_R1=08119A54
I10B_N1=23              # 23 longwords
I10C=08119AB0
I10C_R1=08119AB0
I10C_N1=37              # 37 longwords
I10D=08119B44
I10D_R1=08119B44
I10D_N1=14              # 14 longwords
I10G=0811950C
I10G_R1=0811950C
I10G_N1=132             # 132 longwords
I10P=081192EC
I10P_R1=081192EC
I10P_N1=77              # 77 longwords
I10R=081197E4
I10R_R1=081197E4
I10R_N1=79              # 79 longwords
I10S=08119920
I10S_R1=08119920
I10S_N1=46              # 46 longwords
I10T=0811971C
I10T_R1=0811971C
I10T_N1=50              # 50 longwords
I10W=08119420
I10W_R1=08119420
I10W_N1=59              # 59 longwords
I39=08118FD4
I39_R1=08118FD4
I39_N1=14               # 14 longwords
I40=0811900C
I40_R1=0811900C
I40_N1=13               # 13 longwords
INI=08119238
INI_R1=08119238
INI_N1=7                # 7 longwords
ISP61=081183EC
ISP61_R1=081183EC
ISP61_N1=15             # 15 longwords
IUR=08119254
IUR_R1=08119254
IUR_N1=16               # 16 longwords
KVP=081184B4
KVP_R1=081184B4
KVP_N1=9                # 9 longwords
PGZ=08119080
PGZ_R1=08119080
PGZ_N1=12               # 12 longwords
PTD=08119040
PTD_R1=08119040
PTD_N1=11               # 11 longwords
SCRFIX=08118F4C
SCRFIX_R1=08118F4C
SCRFIX_N1=15            # 15 longwords
SDC=08118F28
SDC_R1=08118F28
SDC_N1=9                # 9 longwords
SEGVN_PROT=08118380
SEGVN_PROT_R1=08118380
SEGVN_PROT_N1=5         # 5 longwords
SMU=081190B0
SMU_R1=081190B0
SMU_N1=44               # 44 longwords
SRG=081191AC
SRG_R1=081191AC
SRG_N1=17               # 17 longwords
SYNCG=0811906C
SYNCG_R1=0811906C
SYNCG_N1=5              # 5 longwords
UNT=08119184
UNT_R1=08119184
UNT_N1=10               # 10 longwords
WBF=08118240
WBF_R1=08118240
WBF_N1=35               # 35 longwords
WBN=08118244
WBN_R1=08118244
WBN_N1=8                # 8 longwords

echo "=== IDENTITY ==="
uname -m
echo "=== MAGIC CHECK (40 blocks, 40 checks) ==="
chk() {
	m=`$K $1 1 | sed "s/.*= //;s/ .*//"`
	if [ "$m" != "$2" ]; then
		echo "ABORT: $3 = $m, expected $2"; exit 1
	fi
}
chk $LKX            4c4b5821 Lkx_magic
chk $A3D            41334421 a3d_magic
chk $A3P            41335021 a3p_magic
chk $A3W            41335721 a3w_magic
chk $BT             42545721 bt_magic
chk $CMF            434d4642 cmf_magic
chk $DMA            444d4121 dma_magic
chk $F60            46503630 f60_magic
chk $FPC            46504321 fpc_magic
chk $FPI            46504921 fpi_magic
chk $HBU            48425521 hbu_magic
chk $HG             48474621 hg_magic
chk $I10            49313021 i10_magic
chk $I10A           49314121 i10a_magic
chk $I10B           49314221 i10b_magic
chk $I10C           49314321 i10c_magic
chk $I10D           49314421 i10d_magic
chk $I10G           49314721 i10g_magic
chk $I10P           49313050 i10p_magic
chk $I10R           49315221 i10r_magic
chk $I10S           49315321 i10s_magic
chk $I10T           49315421 i10t_magic
chk $I10W           49315721 i10w_magic
chk $I39            49333921 i39_magic
chk $I40            49343021 i40_magic
chk $INI            494e5421 ini_magic
chk $ISP61          49363121 isp61_magic
chk $IUR            49555221 iur_magic
chk $KVP            4b565021 kvp_magic
chk $PGZ            50475a21 pgz_magic
chk $PTD            50544421 ptd_magic
chk $SCRFIX         53434621 scrfix_magic
chk $SDC            53444321 sdc_magic
chk $SEGVN_PROT     53564e21 segvn_prot_magic
chk $SMU            534d5521 smu_magic
chk $SRG            53524721 srg_magic
chk $SYNCG          53594e47 syncg_magic
chk $UNT            554e5421 unt_magic
chk $WBF            57424621 wbf_magic
chk $WBN            57424e21 wbn_magic
echo "all 40 magics OK"

dump() {
	echo "Lkx:            " ; $K $LKX_R1 $LKX_N1
	echo "Lkx (cont):     " ; $K $LKX_R2 $LKX_N2
	echo "a3d:            " ; $K $A3D_R1 $A3D_N1
	echo "a3p:            " ; $K $A3P_R1 $A3P_N1
	echo "a3w:            " ; $K $A3W_R1 $A3W_N1
	echo "bt:             " ; $K $BT_R1 $BT_N1
	echo "cmf:            " ; $K $CMF_R1 $CMF_N1
	echo "dma:            " ; $K $DMA_R1 $DMA_N1
	echo "dma (cont):     " ; $K $DMA_R2 $DMA_N2
	echo "f60:            " ; $K $F60_R1 $F60_N1
	echo "fpc:            " ; $K $FPC_R1 $FPC_N1
	echo "fpi:            " ; $K $FPI_R1 $FPI_N1
	echo "hbu:            " ; $K $HBU_R1 $HBU_N1
	echo "hg:             " ; $K $HG_R1 $HG_N1
	echo "i10:            " ; $K $I10_R1 $I10_N1
	echo "i10a:           " ; $K $I10A_R1 $I10A_N1
	echo "i10b:           " ; $K $I10B_R1 $I10B_N1
	echo "i10c:           " ; $K $I10C_R1 $I10C_N1
	echo "i10d:           " ; $K $I10D_R1 $I10D_N1
	echo "i10g:           " ; $K $I10G_R1 $I10G_N1
	echo "i10p:           " ; $K $I10P_R1 $I10P_N1
	echo "i10r:           " ; $K $I10R_R1 $I10R_N1
	echo "i10s:           " ; $K $I10S_R1 $I10S_N1
	echo "i10t:           " ; $K $I10T_R1 $I10T_N1
	echo "i10w:           " ; $K $I10W_R1 $I10W_N1
	echo "i39:            " ; $K $I39_R1 $I39_N1
	echo "i40:            " ; $K $I40_R1 $I40_N1
	echo "ini:            " ; $K $INI_R1 $INI_N1
	echo "isp61:          " ; $K $ISP61_R1 $ISP61_N1
	echo "iur:            " ; $K $IUR_R1 $IUR_N1
	echo "kvp:            " ; $K $KVP_R1 $KVP_N1
	echo "pgz:            " ; $K $PGZ_R1 $PGZ_N1
	echo "ptd:            " ; $K $PTD_R1 $PTD_N1
	echo "scrfix:         " ; $K $SCRFIX_R1 $SCRFIX_N1
	echo "sdc:            " ; $K $SDC_R1 $SDC_N1
	echo "segvn_prot:     " ; $K $SEGVN_PROT_R1 $SEGVN_PROT_N1
	echo "smu:            " ; $K $SMU_R1 $SMU_N1
	echo "srg:            " ; $K $SRG_R1 $SRG_N1
	echo "syncg:          " ; $K $SYNCG_R1 $SYNCG_N1
	echo "unt:            " ; $K $UNT_R1 $UNT_N1
	echo "wbf:            " ; $K $WBF_R1 $WBF_N1
	echo "wbn:            " ; $K $WBN_R1 $WBN_N1
}

echo "=== COUNTERS BEFORE ==="
dump
echo "=== BATTERY ==="
cd /tmp
echo "---- proctest"; ./proctest
echo "---- fputest"; ./fputest
echo "---- mlocktest"; ./mlocktest
echo "---- msynctst"; ./msynctst
echo "---- mincoretst"; ./mincoretst
echo "---- bigargv"; ./bigargv
echo "---- ptracepoke"; ./ptracepoke
echo "---- bmaptest"; ./bmaptest
echo "---- devmaptest"; ./devmaptest
echo "---- exectest 20"; ./exectest 20
echo "---- mul64test"; ./mul64test
echo "---- protfault a"; ./protfault a
echo "---- protfault b"; ./protfault b
echo "=== COUNTERS AFTER ==="
dump

echo "=== VERDICT ==="
# The verdict greps the log this run is being written to.  Passing the path as $1 lets the
# caller redirect anywhere; if that file does not exist the check ABORTS rather than
# reporting twelve MISSING, which is what it did on 2026-08-27 when the run was redirected
# to one name while this line still said another.  A check that reads nothing must not be
# able to print a verdict.
L=${1:-/tmp/battery.log}
if [ ! -f "$L" ]; then
	echo "ABORT: verdict log $L does not exist -- pass the log path as \$1"
	exit 1
fi
bad=0
want() {
	if grep "$1" $L > /dev/null 2>&1; then
		echo "  ok      $2"
	else
		echo "  MISSING $2   (expected: $1)"; bad=`expr $bad + 1`
	fi
}
want "PROCTEST-RESULT PASS" proctest
want "FPUTEST Test A PASS" fputest
want "MLOCKTEST-RESULT PASS" mlocktest
want "MSYNC-OK" msynctst
want "MINCORE PASS" mincoretst
want "BIGARGV PASS" bigargv
want "PTRACEPOKE-RESULT PASS" ptracepoke
want "BMAPTEST-RESULT PASS" bmaptest
want "DEVMAPTEST-RESULT PASS" devmaptest
want "EXECTEST-RESULT PASS" exectest
want "MUL64-RESULT PASS" mul64test
want "PROTFAULT-RESULT PASS" protfault
if [ $bad -eq 0 ]; then
	echo "BATTERY-RESULT PASS"
else
	echo "BATTERY-RESULT FAIL ($bad missing)"
fi

# Must-stay-zero readings, taken from the device rather than from the log so that no pattern
# in this file can match a line this file printed.  Addresses are spelled out because AMIX
# `expr` cannot do hex arithmetic, and they carry a Z_ prefix so that no counter address can
# collide with a block length above.
Z_A3W_NODEV=08118ED4
Z_A3W_OTHER=08118EEC
Z_A3W_DEAD_N=08118F10
Z_A3D_N=08118CF4
Z_A3W_CALLS=08118ED0
Z_A3W_OWN=08118EDC
Z_A3W_EINT_ONLY=08118EE8
Z_A3W_EINT_ACKED=08118EF0
Z_A3P_D_QUAR=08118E58
Z_A3P_D_BADPHASE=08118E5C
Z_A3P_D_BADSTAT=08118E60
Z_A3P_D_NOTOWNER=08118E64
Z_A3P_D_TRY=08118E28
Z_A3P_D_BYTES=08118E3C
Z_A3P_D_SENT=08118E40
Z_A3P_D_BUSFREE=08118E4C
Z_A3P_D_FAILED=08118E54
Z_A3W_RAN=08118EC8

peek1() { $K $1 1 | sed "s/.*= //;s/ .*//"; }
zbad=0
iszero() {
	v=`peek1 $1`
	if [ "$v" != "00000000" ]; then
		echo "  NONZERO $2 = $v"; zbad=`expr $zbad + 1`
	else
		echo "  zero    $2"
	fi
}

echo "=== ISSUE-53 A3091 SOURCE CLASSIFIER ==="
r=`peek1 $Z_A3W_RAN`
if [ "$r" = "41335752" ]; then
	echo "  ran     a3w_ran = $r"
else
	echo "  NOT-RUN a3w_ran = $r, expected 41335752"; zbad=`expr $zbad + 1`
fi
echo "  READING a3w_calls        = `peek1 $Z_A3W_CALLS`   (every level-2 interrupt)"
echo "  READING a3w_own          = `peek1 $Z_A3W_OWN`   (INT_P set at entry)"
echo "  READING a3w_eint_only    = `peek1 $Z_A3W_EINT_ONLY`   (pure SDMAC events -- ISSUE-53 closes when this is nonzero)"
echo "  READING a3w_eint_acked   = `peek1 $Z_A3W_EINT_ACKED`   (CINT strobes issued)"
iszero $Z_A3W_NODEV        a3w_nodev
iszero $Z_A3W_OTHER        a3w_other
iszero $Z_A3W_DEAD_N       a3w_dead_n
iszero $Z_A3D_N            a3d_n

echo "=== ISSUE-54 STAGE D DRAIN ==="
echo "  READING a3p_d_try        = `peek1 $Z_A3P_D_TRY`   (drains attempted)"
echo "  READING a3p_d_bytes      = `peek1 $Z_A3P_D_BYTES`   (bytes discarded)"
echo "  READING a3p_d_sent       = `peek1 $Z_A3P_D_SENT`   (ABORT messages sent)"
echo "  READING a3p_d_busfree    = `peek1 $Z_A3P_D_BUSFREE`   (clean bus-free seen)"
echo "  READING a3p_d_failed     = `peek1 $Z_A3P_D_FAILED`   (requests retired EIO)"
iszero $Z_A3P_D_QUAR       a3p_d_quar
iszero $Z_A3P_D_BADPHASE   a3p_d_badphase
iszero $Z_A3P_D_BADSTAT    a3p_d_badstat
iszero $Z_A3P_D_NOTOWNER   a3p_d_notowner

if [ $zbad -eq 0 ]; then
	echo "MUST-STAY-ZERO-OK"
else
	echo "MUST-STAY-ZERO-BAD ($zbad wrong)"
fi
