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
|
| 2026-07-10 (060-B): added the 68060 format-4 access-error case.  The 060 pushes an 8-word
| frame: FA at CPU+8 (frame+72), FSLW at CPU+12 (frame+76).  The FSLW TM field (bits 18-16)
| carries the same user/supervisor function-code encoding (1=user data, 2=user code, 5/6 =
| super), so after extraction the shared classifier below applies unchanged.
|
| ===========================================================================================
| 2026-07-28, ISSUE-22.  MEASURED on real hardware (copyback, build 260728-36, burst 15 of a
| six-way copy load):
|     DBG krnxflt FAILEXIT w=2 va=800C96B0 rw=2 depth=1
| A copyout WRITE into b2verify's own freshly malloc'd 4 MiB heap buffer was classified as a
| KERNEL access, so k_trap called krnxmemflt, whose stock kas gate (as_segat(&kas, userVA),
| verbatim in the vanilla body at 0x5b19e) found no segment and returned unresolved -- with no
| as_fault call, which is why the as_fault FAIL logger stayed silent through every hit.  The
| process saw `read: Bad address`.  depth=1 refutes the recursion-cap hypothesis outright.
|
| The classifier is right ~99.999% of the time: the same run resolved ~90000 copyout page
| faults and misrouted ONE.  So the function code in the frame is USUALLY 1 (user data) and
| occasionally something else.
|
| RESOLVED 2026-07-29: the "something else" is 5, and it does not come from the CPU reporting
| anything unusual -- this function reads the frame CORRECTLY every time.  It comes from
| wb040.s leaving a stale DFC behind after a write-back replay, so the interrupted copy loop's
| next `movesl` genuinely IS a supervisor-data access to a user address.  The root cause is
| fixed there; see that file's header for the injection A/B that proved it.
|
| WHAT REMAINS HERE IS A REGRESSION DETECTOR, NOT A HUNT.  us_odd_user counts user-address
| misroutes and must stay 0 now that the function-code registers are preserved; us_odd_kern
| counts the legitimate supervisor-data faults on the kernel segmap source (thousands per copy
| workload -- that is the copy loop's `movel %a0@+` and it is fine).  Both are .globl so kpeek
| can read them from /dev/mem without the serial capture being alive.  The cmn_err lines are
| gated on btrace_on, so the base and quiet kernels are silent and only the DBG build prints.
|
| The reroute band-aid that briefly lived here is GONE (see Lus_oddfix).
| ===========================================================================================

	.text
	.globl	userspace
userspace:
	linkw	%fp,&-16		| -4 fc, -8 fa, -12 fmt, -16 ssw (the probe needs them
					| across cmn_err, which clobbers d0/d1/a0/a1)
	addql	&1,us_calls		| denominator: every copy-path fault classified here
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
	cmpiw	&4,%d0			| 060 format 4 (access error, FSLW)  -- NEW 2026-07-10
	beqw	Lus_fslw060
	braw	Lus_complain
Lus_ssw030:
	moveq	&7,%d1
	andl	%a0@(72),%d1		| 030 SSW function code (stock behavior, verbatim)
	braw	Lus_fc
Lus_ssw040:
	moveq	&0,%d1
	movew	%a0@(76),%d1		| 040 SSW word
	andl	&7,%d1			| TM = function code (bits 2-0)
	braw	Lus_fc
Lus_fslw060:
	movel	%a0@(76),%d1		| 060 FSLW long (CPU+0x0C = frame+76)
	swap	%d1			| TM = FSLW bits 18-16 -> low-word bits 2-0
	andl	&7,%d1			| same user/super encoding as the 030/040 FC
Lus_fc:
	movel	%d1,%fp@(-4)
	cmpil	&1,%d1			| FC=1 user data
	beqw	Lus_user
	cmpil	&2,%d1			| FC=2 user code
	beqw	Lus_user
| --- ISSUE-22 probe + reroute (see the header).  d0 still holds the format nibble. ---
	movel	%d0,%fp@(-12)		| fmt
	moveq	&0,%d1
	cmpiw	&7,%d0
	bnes	Lus_odd4
	movel	%a0@(84),%d1		| 040 format-7 fault address (get_fault's offset)
	bras	Lus_oddfa
Lus_odd4:
	cmpiw	&4,%d0
	bnes	Lus_oddfa
	movel	%a0@(72),%d1		| 060 format-4 fault address
Lus_oddfa:
	movel	%d1,%fp@(-8)		| fa (0 for an 030 frame: those keep the old behaviour)
	moveq	&0,%d0
	movew	%a0@(76),%d0		| raw SSW word (fmt-7); FSLW high word (fmt-4)
	movel	%d0,%fp@(-16)
	tstl	%d1
	bmiw	Lus_odduser		| fa >= 0x80000000 -> user space -> THE MISROUTE
| --- kernel-address case: a non-user function code at a kernel address is legitimate
|     (the kernel resolver owns it).  Counted, and the first few are logged for context:
|     if TM=000 pushes exist at all on this machine, this is where they show up first. ---
	addql	&1,us_odd_kern
	movel	Lus_ok_n,%d0
	cmpil	&4,%d0
	bccw	Lus_kern
	addql	&1,%d0
	movel	%d0,Lus_ok_n
	bsrw	Lus_dolog
	braw	Lus_kern
Lus_odduser:
	addql	&1,us_odd_user
	movel	Lus_ou_n,%d0
	cmpil	&8,%d0
	bccw	Lus_oddfix
	addql	&1,%d0
	movel	%d0,Lus_ou_n
	bsrw	Lus_dolog
Lus_oddfix:
| --- 2026-07-29: the reroute band-aid that used to sit here is GONE.  It sent user-address
|     misroutes to the user resolver, which treats the symptom and cannot work: with the root cause
|     (a leaked DFC, wb040.s) the ACCESS ITSELF is aimed at the wrong space, so as_fault resolves
|     the page, the retry re-faults identically, and that is an unkillable kernel loop -- the
|     ISSUE-37 shape.  The counters stay: us_odd_user must remain 0 now that DFC is preserved, so
|     it is a standing regression detector rather than diagnostics. ---
	braw	Lus_kern
Lus_dolog:
	tstl	btrace_on		| the DBG build sets this; base and quiet stay silent
	beqs	Lus_nolog
	movel	%fp@(-16),%sp@-		| ssw
	movel	%fp@(-8),%sp@-		| fa
	movel	%fp@(-4),%sp@-		| fc
	movel	%fp@(-12),%sp@-		| fmt
	pea	Lus_oddmsg
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
Lus_nolog:
	rts
Lus_kern:
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

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even
Lus_msg:
	.asciz	"userspace called for non-bus error exception"
	.even
Lus_oddmsg:
	.asciz	"DBG userspace ODD fmt=%d fc=%d fa=%x ssw=%x"
	.balign 4			| .even is only 2 -- these are longs read by addql/tstl and by
					| kpeek from userland, so align them properly
Lus_ou_n:				| print cap, user-address misroutes
	.long	0
Lus_ok_n:				| print cap, kernel-address oddities (context)
	.long	0
| --- .globl so kpeek/nm can read them without guessing an offset: these four numbers turn a
|     silent run into a measurement (how many classifications, how many odd, how many fixed). ---
	.globl	us_calls
us_calls:
	.long	0
	.globl	us_odd_user
us_odd_user:
	.long	0
	.globl	us_odd_kern
us_odd_kern:
	.long	0

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
