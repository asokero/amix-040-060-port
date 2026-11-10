# w82.sh -- ISSUE-82 controlled wakeup, 68040-261110-08 at load base 0x07000000 ONLY.
# sptmap 0715a1f4 = [slots, want, (size, addr)...]; Km_OsizeWanted 07129554;
# &Km_freepool read from its .text site 07042a28.  Runs alone in the background:
# a new telnet login may need a big pool while the arena is hidden.
#
# DO NOT RUN THIS FORM AGAIN ON HARDWARE.  On 040 HW, 2026-11-10 (KNOWN-ISSUES ISSUE-82), run 1
# had one filler: the sleeper formed, no pool retired, and the fallback woke it.  This form, with
# eight fillers, filled the big pools to 0x2c00 free bytes before the hide.  The script's own next
# kpeek (fork + exec) then needed a new big pool, found no 4-click run and slept, so the restore
# never ran.  Logins slept too, and the machine had to be reset.
H=/usr/local/hwt
K=/kpeek
L=$H/w82.log
SPT=0715a1f4
OW=07129554
rd() { $K $1 1 | awk '{print $4}'; }
mp() { $K $SPT 40 | awk 'NR>2 && NR%2==1 {z=$4} NR>2 && NR%2==0 {if (z=="00000000") exit; printf " %s:%s", z, $4}'; }
st() { T=`date +%H:%M:%S`; A=`rd $OW`; B=`rd $FPA`; C=`mp`; D=`/kpeek 07148f64 9 | awk 'NR==2||NR==5{printf " %s", $4}'`; echo "$T ow=$A fp=$B big:$D map:$C" >> $L; }
FPA=`rd 07042a28`
echo "W82 start `date` fpaddr=$FPA" > $L
sync
rm -f $H/w82fill.log
for i in 1 2 3 4 5 6 7 8
do
	$H/wake82 fill 30 4 >> $H/w82fill.log 2>&1 &
done
sleep 8
cat $H/w82fill.log >> $L
st
$K $SPT 40 | awk 'NR>2 && NR%2==1 {sa=$2; z=$4} NR>2 && NR%2==0 {if (z=="00000000") exit; if (z!="00000001") print sa, z, $4}' > $H/w82.hid
echo "HIDE `cat $H/w82.hid | wc -l` extents" >> $L
while read sa sz ad
do
	$H/kpoke $sa $sz 1 >> $L 2>&1
done < $H/w82.hid
st
$H/wake82 touch > $H/w82touch.log 2>&1 &
TPID=$!
sleep 5
cat $H/w82touch.log >> $L
st
if [ "`rd $OW`" != "00002000" ]
then
	echo "NO SLEEPER on 00002000" >> $L
fi
echo "RELEASE `date +%H:%M:%S`" >> $L
for p in `ps -ef | egrep "wake82 fill" | egrep -v egrep | awk '{print $2}'`
do
	kill -16 $p
done
n=0
while [ $n -lt 30 ]
do
	sleep 2
	st
	if egrep WOKE $H/w82touch.log > /dev/null
	then
		break
	fi
	n=`expr $n + 1`
done
cat $H/w82fill.log $H/w82touch.log >> $L
while read sa sz ad
do
	S=`$K $SPT 40 | awk 'NR>2 && NR%2==1 {sa=$2; z=$4} NR>2 && NR%2==0 {if ($4=="'$ad'") {print sa, z; exit}}'`
	echo "RESTORE $ad orig $sz now $S" >> $L
	set -- $S
	if [ "$2" = "00000001" ]
	then
		$H/kpoke $1 1 $sz >> $L 2>&1
	else
		echo "RESTORE-MANUAL $ad" >> $L
	fi
done < $H/w82.hid
st
if egrep WOKE $H/w82touch.log > /dev/null
then
	echo "RESULT WOKE" >> $L
else
	echo "RESULT NOT-WOKEN -- fallback: a second touch frees an 8192 buffer on exit" >> $L
	$H/wake82 touch >> $L 2>&1
	sleep 3
	cat $H/w82touch.log >> $L
	st
fi
echo "W82 end `date`" >> $L
sync
