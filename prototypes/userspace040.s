| userspace040.s -- override userspace() (0x5b5f0, GLOBAL T) to recognize the 68040
| format-7 access-error frame.
|
| Stock userspace() decides whether a fault was a USER-space access (-> usrxmemflt ->
| as_fault(curproc->p_as)) or a kernel access (-> krnxmemflt -> as_fault(&kas)).  It
| handles ONLY 030 bus-error frames (format 0xA / 0xB) and reads the function code from
| the 030 SSW at frame+72.  On the 68040 the CPU pushes a format-7 access-error frame, so
| stock userspace falls through to its "userspace called for non-bus error exception"
| warning and returns 0 (kernel).  Effect: a supervisor `moves` to user space (copyin/
| copyout) that page-faults is mis-classified as a kernel fault -> as_fault(&kas, useraddr)
| -> as_segat -> NULL -> EFAULT.  This is exactly why main()'s copyout(icode, 0x80800000)
| "failed": the segment lives in proc 1's p_as (401AA400), but the fault was routed to &kas.
|
| Empirical 68040 access-error frame (from the ktrap raw-window dump; `frame` = the
| get_fault-style pointer, i.e. &USP slot, with the CPU frame at frame+64):
|     frame+64 SR              frame+66 PC          frame+70 format/vector (0x7008)
|     frame+76 SSW             frame+84 Fault Address
| Observed SSW for the copyout write fault = 0x0401 = ATC fault (bit10), RW=0 (write),
| TM=001 (user data).  The SSW TM field (bits 2-0) is the function code, with the SAME
| user/supervisor encoding as the 030 (1=user data, 2=user code, 5=super data, 6=super
| code).  This +4 offset shift (SSW at +76 not the textbook +72; FA at +84 not +80) is
| consistent with the already-working get_fault 040 port, which reads FA at frame+84.
|
| The 030 paths are reproduced verbatim (read FC from frame+72); only the format-7 case is
| added.  GLOBAL T -> --weaken-symbol userspace makes k_trap's `jsr userspace` resolve here.

	.text
	.globl	userspace
userspace:
	linkw	%fp,&-8
	moveal	%fp@(8),%a0		| a0 = frame
	moveq	&0,%d0
	moveb	%a0@(70),%d0		| high byte of format/vector word
	lsrb	&4,%d0			| format nibble
	cmpiw	&10,%d0			| 030 format 0xA (short bus error)
	beqw	Lus_ssw030
	cmpiw	&11,%d0			| 030 format 0xB (long bus error)
	beqw	Lus_ssw030
	cmpiw	&7,%d0			| 040 format 7 (access error)  -- NEW
	beqw	Lus_ssw040
	braw	Lus_complain
Lus_ssw030:
	moveq	&7,%d1
	andl	%a0@(72),%d1		| 030 SSW function code (stock behavior, verbatim)
	braw	Lus_fc
Lus_ssw040:
	moveq	&0,%d1
	movew	%a0@(76),%d1		| 040 SSW word
	andl	&7,%d1			| TM = function code (bits 2-0)
Lus_fc:
	movel	%d1,%fp@(-4)
	cmpil	&1,%d1			| FC=1 user data
	beqw	Lus_user
	cmpil	&2,%d1			| FC=2 user code
	beqw	Lus_user
	clrl	%d0			| else supervisor/kernel
	braw	Lus_ret
Lus_user:
	moveq	&1,%d0
	braw	Lus_ret
Lus_complain:
	pea	Lus_msg
	pea	2
	jsr	cmn_err
	addqw	&8,%sp
	clrl	%d0
Lus_ret:
	moveal	%d0,%a0			| stock returns the value in both d0 and a0
	unlk	%fp
	rts

	.data
	.even
Lus_msg:
	.asciz	"userspace called for non-bus error exception"
