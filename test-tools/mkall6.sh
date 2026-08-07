# mkall6.sh -- compile the battery in the guest with the AT&T SVR4 driver.
# gcc's own cpp/cc1 contain 64-bit muls.l which the 68060 does not implement (vector 61),
# so /usr/bin/cc is unusable there; /usr/ccs/bin/cc predates that optimization.
#     (nohup sh -c "sh /tmp/mkall6.sh > /tmp/mkall6.log 2>&1" &)
CC=/usr/ccs/bin/cc
cd /tmp
for t in exectest devmaptest proctest fputest mlocktest msynctst mincoretst bigargv \
         ptracepoke bmaptest mul64test protfault
do
	echo "==== $CC $t ===="
	$CC -o $t $t.c 2>&1 | tail -5
	ls -l $t 2>&1
done
echo MKALL6-DONE
