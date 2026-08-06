# mkall5.sh -- compile exactly what batteryrun5.sh calls, in one detached run.
# mkall.sh omits mul64test, protfault and kpeek; batteryrun5 needs all three, and a
# missing binary shows up as a test that silently prints nothing rather than as a FAIL.
#     (nohup sh -c "sh /tmp/mkall5.sh > /tmp/mkall5.log 2>&1" &)
cd /tmp
for t in kpeek proctest fputest mlocktest msynctst mincoretst bigargv ptracepoke \
         bmaptest devmaptest exectest mul64test protfault
do
	echo "==== cc $t ===="
	cc -o $t $t.c 2>&1 | tail -3
	ls -l $t 2>&1
done
echo MKALL5-DONE
