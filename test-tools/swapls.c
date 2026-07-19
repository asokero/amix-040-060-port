/* swapls.c - print raw swapctl(SC_LIST) page counts (Model-B slot check).
 * K&R C for AMIX SVR4 native cc.  Expected on 100MiB swap:
 *   Model-B (4K pages): pages 25600   (old 2K bug: 51199/51200 = FAIL)
 */
#include <sys/types.h>
#include <sys/swap.h>
#include <stdio.h>

char pathbuf[4][256];

struct mytab {
	int swt_n;
	struct swapent ent[4];
};

main()
{
	struct mytab tab;
	int n;
	int i;

	n = swapctl(SC_GETNSWP, (char *)0);
	printf("NSWP %d\n", n);
	tab.swt_n = 4;
	for (i = 0; i < 4; i++)
		tab.ent[i].ste_path = pathbuf[i];
	n = swapctl(SC_LIST, (char *)&tab);
	printf("LISTRC %d\n", n);
	for (i = 0; i < n && i < 4; i++)
		printf("%s start %ld len %ld PAGES %ld FREE %ld flags %lx\n",
		    tab.ent[i].ste_path,
		    tab.ent[i].ste_start, tab.ent[i].ste_length,
		    tab.ent[i].ste_pages, tab.ent[i].ste_free,
		    tab.ent[i].ste_flags);
	exit(0);
}
