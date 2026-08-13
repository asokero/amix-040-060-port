# batteryrun10.sh -- battery on 68040-260812-06, A3640, LOAD BASE 0x07000000.
# Every address below was generated from nm for THIS image at THIS base, not substituted
# from an earlier run: the A3640 has no local RAM so the kernel binds 16 MiB lower than on
# every previous machine.  Each block's magic is checked before its counters are believed.
#   (nohup sh /tmp/batteryrun10.sh > /tmp/battery10.log 2>&1 &)
K=/kpeek
F60=0710B8B4 ; F60_N=31
FPC=0710B29C ; FPC_N=13
I39=0710B810 ; I39_N=14
I40=0710B848 ; I40_N=13
ISP61=0710B260 ; ISP61_N=15
KVP=0710B2D0 ; KVP_N=9
PTD=0710B87C ; PTD_N=11
SEGVN_PROT=0710B1F4 ; SEGVN_PROT_N=5
WBF=0710B128 ; WBF_N=25

echo "=== MAGIC CHECK ==="
m=`$K 0710B8B4 1 | sed "s/.*= //;s/ .*//"` ; if [ "$m" != "46503630" ]; then echo "ABORT: f60_magic = $m, expected 46503630"; exit 1; fi
m=`$K 0710B29C 1 | sed "s/.*= //;s/ .*//"` ; if [ "$m" != "46504321" ]; then echo "ABORT: fpc_magic = $m, expected 46504321"; exit 1; fi
m=`$K 0710B810 1 | sed "s/.*= //;s/ .*//"` ; if [ "$m" != "49333921" ]; then echo "ABORT: i39_magic = $m, expected 49333921"; exit 1; fi
m=`$K 0710B848 1 | sed "s/.*= //;s/ .*//"` ; if [ "$m" != "49343021" ]; then echo "ABORT: i40_magic = $m, expected 49343021"; exit 1; fi
m=`$K 0710B260 1 | sed "s/.*= //;s/ .*//"` ; if [ "$m" != "49363121" ]; then echo "ABORT: isp61_magic = $m, expected 49363121"; exit 1; fi
m=`$K 0710B2D0 1 | sed "s/.*= //;s/ .*//"` ; if [ "$m" != "4b565021" ]; then echo "ABORT: kvp_magic = $m, expected 4b565021"; exit 1; fi
m=`$K 0710B87C 1 | sed "s/.*= //;s/ .*//"` ; if [ "$m" != "50544421" ]; then echo "ABORT: ptd_magic = $m, expected 50544421"; exit 1; fi
m=`$K 0710B128 1 | sed "s/.*= //;s/ .*//"` ; if [ "$m" != "57424621" ]; then echo "ABORT: wbf_magic = $m, expected 57424621"; exit 1; fi
echo "all magics OK"

echo "=== BEFORE ==="
echo "f60:" ; $K 0710B8B4 31
echo "fpc:" ; $K 0710B29C 13
echo "i39:" ; $K 0710B810 14
echo "i40:" ; $K 0710B848 13
echo "isp61:" ; $K 0710B260 15
echo "kvp:" ; $K 0710B2D0 9
echo "ptd:" ; $K 0710B87C 11
echo "segvn_prot:" ; $K 0710B1F4 5
echo "wbf:" ; $K 0710B128 25

mkdir -p /pgc
for t in proctest fputest msynctst bigargv ptracepoke mul64test
do
	echo "======== $t ========" ; /tmp/$t 2>&1
done
echo "======== bmaptest /pgc ========" ; /tmp/bmaptest /pgc 2>&1
echo "======== exectest 20 ========"   ; /tmp/exectest 20 2>&1
echo "======== leaktest ========"      ; /tmp/leaktest 2>&1

echo "=== AFTER ==="
echo "f60:" ; $K 0710B8B4 31
echo "fpc:" ; $K 0710B29C 13
echo "i39:" ; $K 0710B810 14
echo "i40:" ; $K 0710B848 13
echo "isp61:" ; $K 0710B260 15
echo "kvp:" ; $K 0710B2D0 9
echo "ptd:" ; $K 0710B87C 11
echo "segvn_prot:" ; $K 0710B1F4 5
echo "wbf:" ; $K 0710B128 25
echo BATTERY10-DONE
