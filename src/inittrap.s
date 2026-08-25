| inittrap.s -- ISSUE-106 round 3: capture the value _start hands to the initial
| `rte`, because PID 1 never reached its first intended instruction.  (2026-08-21)
|
| WHAT ROUND 2 SETTLED, and it killed both of its own registered forks.
|
| `u_trap` has EXACTLY ONE reference in the unpatched stock image (0x11f0, the
| `jsr` inside `utraps`), so every user trap -- syscall and fault alike -- routes
| through the round-2 hook.  `srg_ut_n = 1` therefore means **one user trap in the
| entire boot**, and since the NOTICE is printed from `u_trap`'s fault path, that
| one trap IS the fault.
|
|   => the icode's `trap #0` NEVER EXECUTED.  exec never ran.  setregs never ran
|      (`srg_n = 0`, no PRE!, no PST!).  `u_comm = 0` follows for free: exec is
|      what would have written it.
|
| So the question is no longer anywhere inside exec.  PID 1 faulted on its FIRST
| user instruction.
|
| THE HANDOFF, read out of `_start`:
|
|     44:  jsr   main            ; d0 = the user PC main computed
|     4a:  movew #0,%d1
|     4e:  movew %d1,%sp@-       ; format word 0x0000 (4-word frame, vector 0)
|     50:  movel %d0,%sp@-       ; PC
|     52:  bmis  5c              ; d0 negative -> the user-mode arm
|     54:  movew #0x2000,%d1     ; supervisor SR
|     58:  movew %d1,%sp@-
|     5a:  rte
|     5c:  movew %d1,%sp@-       ; SR = 0x0000 -- USER mode
|     5e:  rte
|
| `movel %d0,%sp@-` sets N from d0, and the intended entry `0x80800000` is
| negative, so the `bmis` arm is taken and the frame is SR=0 / PC=d0 / format=0 --
| a correct format-0 frame, and correct on the 68040.
|
| `main` maps and copies the icode to **0x80800000** (`as_map` and `copyout` both
| take that address, 0x59972 / 0x5998a) and returns it in d0 (`movel #0x80800000,%d0`
| at 0x599d2).  The initial user stack is `as_map(0xC07FF800, 0x800)`, whose top is
| `0xC0800000` -- exactly the `pcb0` value already read on metal.
|
| **The observed fault was PC 0x80000012, not 0x80800000.** The `rte` did not
| deliver the entry main computed, so the icode's first instruction --
| `lea %pc@(L%stack),%sp`, the one that establishes the user stack -- never ran,
| which is why USP was garbage (0xCB7C0002) rather than 0xC0800000.  The garbage
| USP is a CONSEQUENCE, not the cause; round 1 and round 2 both chased it as if it
| were the cause.
|
| THE ONE QUESTION LEFT: does `main` return the right value?
|
| This unit retargets the `jsr main` relocation at 0x46 to `ini_main`, which calls
| the real `main`, latches what it returned, and hands that value back unchanged in
| d0 so `_start`'s `bmis` and frame build are bit-identical.
|
| PRE-REGISTERED FORK:
|   ini_ret == 0x80800000  main is correct and the corruption is in the `rte` or
|                          the frame it reads -- a 68040 frame/format question, and
|                          the search moves to the three words on the stack.
|   ini_ret == 0x80000012  main itself computed the wrong entry, and the search
|                          moves into main's icode setup (note 0x80800000 with bit
|                          23 cleared is 0x80000000; the +0x12 would then need its
|                          own explanation).
|   anything else          a third story, and the value names it.
|
| Also latched: the u-area's saved SP word (u+0, already known to read 0xC0800000)
| and the stack-map base, so one readout carries the whole handoff.
|
| NOTE FOR THE NEXT PASS, not acted on here: that stack mapping is 2 KiB-shaped --
| base 0xC07FF800 is NOT 4 KiB-aligned and the size is 0x800.  Under Model B the
| region wants to be one 4 KiB page.  `as_map` rounds to page boundaries so it
| probably still covers [0xC07FF000, 0xC0800000), but it is a Model-B conversion
| that nothing in the patch tables appears to own, and it is worth a look once the
| entry-point question is answered.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c inittrap.s -o build/inittrap.o
| Wire:     patch_inittrap.py (relocation retarget of _start's jsr main).
| ============================================================================

	.text
	.globl	ini_main
ini_main:
	movel	&0x494e4921,ini_stamp1	| "INI!" -- reached the wrapper
	addql	&1,ini_n
	jsr	main
	movel	&0x52455421,ini_stamp2	| "RET!" -- main returned
	movel	%d0,ini_ret		| THE VALUE _start hands to the rte
	movel	u,ini_pcb0		| u.u_pcb.regsave[0] (expect 0xC0800000)
	movel	u+0x864,ini_uar0
| d0 is returned untouched: _start's bmis and frame build must be bit-identical.
	rts
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)

	.data
	.even
	.globl	ini_magic
ini_magic:
	.long	0x494e5421		| "INT!"
	.globl	ini_stamp1
ini_stamp1:
	.long	0
	.globl	ini_stamp2
ini_stamp2:
	.long	0
	.globl	ini_n
ini_n:
	.long	0
| The user PC main computed -- the whole point of this round.
	.globl	ini_ret
ini_ret:
	.long	0
	.globl	ini_pcb0
ini_pcb0:
	.long	0
	.globl	ini_uar0
ini_uar0:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
