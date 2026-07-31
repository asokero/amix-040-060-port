/* ptracepoke.c -- exercise the ptrace POKETEXT path (procxmt -> suword) so the
 * DBG-TEXT-PUBLISH wrapper (dbg_suword_publish) actually runs on hardware.
 *
 * The child forks (so its text VA matches ours), TRACEMEs and stops.  The parent
 * PEEKTEXTs a word of the child's text, POKETEXTs the SAME value back -- harmless,
 * but it drives both procxmt store paths (already-writable and the as_setprot
 * temporarily-writable one) through suword -- then reads it back and continues.
 *
 * K&R C for the native AMIX cc: no ANSI prototypes, declarations at block top.
 * Build on the machine:  cc -o ptracepoke ptracepoke.c
 */

#include	<stdio.h>
#include	<signal.h>
#include	<sys/types.h>

#define	PT_TRACEME	0
#define	PT_PEEKTEXT	1
#define	PT_POKETEXT	4
#define	PT_CONT		7
#define	PT_KILL		8

int
marker()
{
	return 0x12345678;
}

main(argc, argv)
int	argc;
char	**argv;
{
	int	pid, st, n, fails;
	long	addr, orig, back;

	addr  = (long)marker;
	fails = 0;

	pid = fork();
	if (pid < 0) {
		printf("PTRACEPOKE: fork failed\n");
		exit(1);
	}
	if (pid == 0) {
		ptrace(PT_TRACEME, 0, 0, 0);
		kill(getpid(), SIGSTOP);	/* stop so the parent can poke */
		_exit(0);
	}

	wait(&st);				/* child is stopped */

	for (n = 0; n < 4; n++) {
		orig = ptrace(PT_PEEKTEXT, pid, addr, 0);
		ptrace(PT_POKETEXT, pid, addr, orig);	/* same value back */
		back = ptrace(PT_PEEKTEXT, pid, addr, 0);
		if (back != orig) {
			printf("  poke %d: read back 0x%lx, expected 0x%lx\n", n, back, orig);
			fails++;
		}
	}

	ptrace(PT_CONT, pid, 1, 0);
	wait(&st);

	printf("PTRACEPOKE addr=0x%lx word=0x%lx pokes=4 fails=%d\n", addr, orig, fails);
	printf("PTRACEPOKE-RESULT %s\n", fails ? "FAIL" : "PASS");
	exit(fails ? 1 : 0);
}
