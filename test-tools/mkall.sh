# mkall.sh -- compile every test binary this session needs, in one detached run.
# /tmp is empty after a boot, and one cc per driver call would be 13 round trips
# that each risk a timeout mid-compile.  Detached, so neither happens:
#     nohup sh /tmp/mkall.sh > /tmp/mkall.log 2>&1 &
cd /tmp
for t in memwatch leaktest kpoke exectest devmaptest proctest fputest mlocktest \
         msynctst mincoretst bigargv ptracepoke bmaptest
do
	echo "==== cc $t ===="
	cc -o $t $t.c 2>&1 | tail -3
	ls -l $t 2>&1
done
echo MKALL-DONE
