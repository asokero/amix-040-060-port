| swapconf_dbg.s -- diagnostic override of swapconf (stock 0xb401e, GLOBAL T).
|
| THE PANIC THIS INSTRUMENT IS FOR.  swapconf's first act is
|
|     lookupname(swapfile.bo_name, UIO_SYSSPACE, FOLLOW, NULL, &swapfile.bo_vp)
|
| and on a non-zero return it calls cmn_err(CE_PANIC, ...) -- the guarded stock panic
|
|     PANIC: swapconf lookupname /dev/dsk/<node> failed - error <n>
|
| It is the FIRST namei path lookup of the boot, so every directory read on the path
| is being made for the first time, and a wrong byte anywhere along it lands here.
|
| TWO HISTORIES, TWO ERROR NUMBERS, ONE SITE.
|   error 2  ENOENT   -- the 68040 signature, root-caused to a bad directory read and
|                       closed by gen_strategy PFN<<11 -> <<12 (hat-040-port-worklist.md:21).
|                       A name that is not in a directory that WAS read as a directory.
|   error 20 ENOTDIR  -- the 2026-08-25 first-silicon 68LC060 signature.  Different
|                       failure: lookuppn/VOP_LOOKUP refuses because a component on the
|                       way in is not of type VDIR.  It is a TYPE that reads wrong, not a
|                       name that is missing -- so the discriminating measurement is which
|                       prefix first refuses, and what v_type the ones before it carry.
|
| WHAT THIS OVERRIDE DOES.  Two passes of the same five lookups, with a whole-data-cache
| push+invalidate between them, then a decision:
|
|   pass 1   "/", "/dev", "/dev/dsk", swapfile.bo_name, and the sibling node built from
|            bo_name with its last character replaced by '1' (the ROOT slice -- the node
|            the running system demonstrably reads, so it is the control for the leaf).
|            For every lookup that succeeds, v_type is read out of the returned vnode and
|            the vnode is VN_RELEd, so a continuing boot leaks no hold.
|   cpusha dc  push every dirty line and invalidate the data cache (0xf478, the
|            src/dma_cache040.s idiom).  On the 68060 the invalidate half is conditional on
|            CACR bit 28 DPI being CLEAR, so CACR is recorded (swd_cacr) rather than assumed.
|   pass 2   the same five, into a second set of slots.
|
|   verdict  if the pass-2 lookup of bo_name returns 0, the data is readable now, so
|            tail-jump to swapconf_orig and let the REAL swapconf configure swap -- the
|            boot then proceeds entirely normally, which is what unlocks a multiuser
|            session.  Otherwise skip swap, return 0, and say so loudly: the boot
|            continues into userland without swap, which is worth strictly more than the
|            panic it replaces.
|
| The prefix literals are card-independent; the leaf comes from swapfile.bo_name itself,
| so this instrument does not need to know whether the root is on card 0 or card 1.
|
| Structure offsets, from the AMIX headers, not from memory:
|   struct vnode   (sys/vnode.h):  v_flag 0, v_count 2, v_vfsmountedhere 4, v_op 8,
|                                  v_vfsp 12, v_stream 16, v_pages 20, v_type 24
|   struct vfs     (sys/vfs.h):    vfs_op 4
|   struct bootobj (sys/swap.h):   bo_fstype 0[16], bo_name 16[128], bo_flags 144,
|                                  bo_offset 148, bo_size 152, bo_vp 156
|                                  -- reproduced from stock swapconf's own relocations
|                                  (swapfile+0x9c = &bo_vp, swapfile+0x10 = bo_name).
|
| swapconf is GLOBAL T -> --weaken-symbol swapconf, plus
| --add-symbol swapconf_orig=.text:0xb401e,function,global for the tail jump.
| SVR4 gas syntax.  Assemble: m68k-cbm-sysv4-gcc -m68040 -c swapconf_dbg.s

| frame:  %fp@(-4) = compvp for lookupname
|         %fp@(-132) .. %fp@(-5) = 128-byte buffer for the sibling node name

	.text
	.globl	swapconf
swapconf:
	linkw	%fp,&-136
	moveml	%d2-%d3/%a2-%a4,%sp@-
	addql	&1,swd_n

	| --- record CACR: on a 68060 the CPUSHA invalidate depends on bit 28 (DPI) ---
	.word	0x4e7a,0x0002		| movec %cacr,%d0
	movel	%d0,swd_cacr

	| --- who is the root filesystem, and is its root vnode still a directory? ---
	moveal	rootvfs,%a0		| a0 = *rootvfs
	movel	%a0@(4),swd_vfsop	| vfs->vfs_op
	moveal	rootdir,%a0		| a0 = *rootdir
	movel	%a0@(8),swd_rootvop	| vnode->v_op
	movel	%a0@(24),swd_vt_root	| vnode->v_type   (VDIR = 2)

	| --- build the sibling name: bo_name with its last character replaced by '1' ---
	lea	swapfile+16,%a0		| swapfile.bo_name
	lea	%fp@(-132),%a1
	clrl	%d2			| d2 = length
Lsib_cp:
	moveb	%a0@+,%d0
	moveb	%d0,%a1@+
	beqw	Lsib_end
	addql	&1,%d2
	cmpil	&126,%d2
	bnew	Lsib_cp
	clrb	%a1@			| refuse to run off a name with no NUL
	addql	&1,%a1
Lsib_end:
	tstl	%d2
	beqw	Lsib_none		| empty name: no sibling to build
	subql	&2,%a1			| back over the NUL and the last character
	moveb	&0x31,%a1@		| ... which becomes '1' (the root slice)
Lsib_none:

	| ---------------------------------------------------------------- pass 1 ---
	lea	Lpath_root,%a2
	lea	swd_p1_root,%a3
	lea	swd_vt1_root,%a4
	bsrw	Lprobe
	lea	Lpath_dev,%a2
	lea	swd_p1_dev,%a3
	lea	swd_vt1_dev,%a4
	bsrw	Lprobe
	lea	Lpath_dsk,%a2
	lea	swd_p1_dsk,%a3
	lea	swd_vt1_dsk,%a4
	bsrw	Lprobe
	lea	%fp@(-132),%a2		| the sibling (root slice)
	lea	swd_p1_sib,%a3
	lea	swd_vt1_sib,%a4
	bsrw	Lprobe
	lea	swapfile+16,%a2		| the real swap node
	lea	swd_p1_swap,%a3
	lea	swd_vt1_swap,%a4
	bsrw	Lprobe

	| -------------------------------------------- push + invalidate the D cache ---
	.word	0xf478			| cpusha dc
	nop

	| ---------------------------------------------------------------- pass 2 ---
	lea	Lpath_root,%a2
	lea	swd_p2_root,%a3
	lea	swd_vt2_root,%a4
	bsrw	Lprobe
	lea	Lpath_dev,%a2
	lea	swd_p2_dev,%a3
	lea	swd_vt2_dev,%a4
	bsrw	Lprobe
	lea	Lpath_dsk,%a2
	lea	swd_p2_dsk,%a3
	lea	swd_vt2_dsk,%a4
	bsrw	Lprobe
	lea	%fp@(-132),%a2
	lea	swd_p2_sib,%a3
	lea	swd_vt2_sib,%a4
	bsrw	Lprobe
	lea	swapfile+16,%a2
	lea	swd_p2_swap,%a3
	lea	swd_vt2_swap,%a4
	bsrw	Lprobe

	| ------------------------------------------------------------------ report ---
	movel	swd_vt_root,%sp@-
	movel	swd_rootvop,%sp@-
	movel	swd_vfsop,%sp@-
	pea	rootfstype		| the fs-type NAME string itself
	pea	Lfmt_head
	pea	2
	jsr	cmn_err
	addaw	&24,%sp

	movel	swd_cacr,%sp@-
	pea	swapfile+16
	pea	Lfmt_swap
	pea	2
	jsr	cmn_err
	addaw	&16,%sp

	movel	swd_vt1_dsk,%sp@-
	movel	swd_p1_dsk,%sp@-
	movel	swd_vt1_dev,%sp@-
	movel	swd_p1_dev,%sp@-
	movel	swd_p1_root,%sp@-
	pea	Lfmt_pre1
	pea	2
	jsr	cmn_err
	addaw	&28,%sp

	movel	swd_p1_swap,%sp@-
	movel	swd_p1_sib,%sp@-
	pea	Lfmt_leaf1
	pea	2
	jsr	cmn_err
	addaw	&16,%sp

	movel	swd_vt2_dsk,%sp@-
	movel	swd_p2_dsk,%sp@-
	movel	swd_vt2_dev,%sp@-
	movel	swd_p2_dev,%sp@-
	movel	swd_p2_root,%sp@-
	pea	Lfmt_pre2
	pea	2
	jsr	cmn_err
	addaw	&28,%sp

	movel	swd_p2_swap,%sp@-
	movel	swd_p2_sib,%sp@-
	pea	Lfmt_leaf2
	pea	2
	jsr	cmn_err
	addaw	&16,%sp

	| ----------------------------------------------------------------- verdict ---
	tstl	swd_p2_swap
	bnew	Lskip

	movel	&1,swd_called
	pea	Lfmt_stock
	pea	2
	jsr	cmn_err
	addaw	&8,%sp
	moveml	%sp@+,%d2-%d3/%a2-%a4
	unlk	%fp
	jmp	swapconf_orig		| the real swapconf configures swap

Lskip:
	movel	&1,swd_skipped
	pea	Lfmt_skip
	pea	2
	jsr	cmn_err
	addaw	&8,%sp
	moveml	%sp@+,%d2-%d3/%a2-%a4
	clrl	%d0
	moveal	%d0,%a0
	unlk	%fp
	rts

| ---------------------------------------------------------------------------
| Lprobe -- one lookupname, recorded.
|   in   %a2 = path            %a3 = &errno slot        %a4 = &v_type slot
|   out  the two slots written; v_type slot = -1 when the lookup failed.
| Clobbers %d0/%a0.  The returned vnode is released.
| ---------------------------------------------------------------------------
Lprobe:
	clrl	%fp@(-4)
	pea	%fp@(-4)		| &compvp
	clrl	%sp@-			| dirvpp = NULL
	pea	1			| follow = FOLLOW
	pea	1			| seg    = UIO_SYSSPACE
	movel	%a2,%sp@-		| path
	jsr	lookupname
	addaw	&20,%sp
	movel	%d0,%a3@
	tstl	%d0
	bnew	Lprobe_bad
	moveal	%fp@(-4),%a0
	movel	%a0@(24),%a4@		| vnode->v_type
	movel	%a0,%sp@-
	jsr	vn_rele
	addql	&4,%sp
	rts
Lprobe_bad:
	movel	&-1,%a4@
	rts

	.balign	4			| pad .text to a 4-byte multiple

| ---------------------------------------------------------------------------
| The counter block.  swd_magic FIRST: read it before believing anything below it.
| Every slot is a contiguous .long so tools/status-facts.sh emits one kpeek for
| the whole block.  -1 means "this probe never ran".
| ---------------------------------------------------------------------------
	.data
	.globl	swd_magic
	.globl	swd_n, swd_cacr, swd_vfsop, swd_rootvop, swd_vt_root
	.globl	swd_p1_root, swd_p1_dev, swd_p1_dsk, swd_p1_sib, swd_p1_swap
	.globl	swd_vt1_root, swd_vt1_dev, swd_vt1_dsk, swd_vt1_sib, swd_vt1_swap
	.globl	swd_p2_root, swd_p2_dev, swd_p2_dsk, swd_p2_sib, swd_p2_swap
	.globl	swd_vt2_root, swd_vt2_dev, swd_vt2_dsk, swd_vt2_sib, swd_vt2_swap
	.globl	swd_called, swd_skipped
swd_magic:	.long	0x53574421	| 'SWD!'
swd_n:		.long	0
swd_cacr:	.long	0
swd_vfsop:	.long	0
swd_rootvop:	.long	0
swd_vt_root:	.long	-1
swd_p1_root:	.long	-1
swd_p1_dev:	.long	-1
swd_p1_dsk:	.long	-1
swd_p1_sib:	.long	-1
swd_p1_swap:	.long	-1
swd_vt1_root:	.long	-1
swd_vt1_dev:	.long	-1
swd_vt1_dsk:	.long	-1
swd_vt1_sib:	.long	-1
swd_vt1_swap:	.long	-1
swd_p2_root:	.long	-1
swd_p2_dev:	.long	-1
swd_p2_dsk:	.long	-1
swd_p2_sib:	.long	-1
swd_p2_swap:	.long	-1
swd_vt2_root:	.long	-1
swd_vt2_dev:	.long	-1
swd_vt2_dsk:	.long	-1
swd_vt2_sib:	.long	-1
swd_vt2_swap:	.long	-1
swd_called:	.long	0
swd_skipped:	.long	0

Lpath_root:
	.asciz	"/"
	.even
Lpath_dev:
	.asciz	"/dev"
	.even
Lpath_dsk:
	.asciz	"/dev/dsk"
	.even
Lfmt_head:
	.asciz	"DBG swapconf: fs=%s vfsop=%x rootvop=%x roottype=%x"
	.even
Lfmt_swap:
	.asciz	"DBG swapconf: swap=%s cacr=%x"
	.even
Lfmt_pre1:
	.asciz	"DBG p1: /=%x dev=%x,t%x dsk=%x,t%x"
	.even
Lfmt_leaf1:
	.asciz	"DBG p1: s1=%x s2=%x"
	.even
Lfmt_pre2:
	.asciz	"DBG p2: /=%x dev=%x,t%x dsk=%x,t%x"
	.even
Lfmt_leaf2:
	.asciz	"DBG p2: s1=%x s2=%x"
	.even
Lfmt_stock:
	.asciz	"DBG swapconf: lookup OK -> running the real swapconf"
	.even
Lfmt_skip:
	.asciz	"DBG swapconf: lookup STILL FAILING -> SWAP SKIPPED, boot continues"
	.even
	.balign	4			| pad .data to a 4-byte multiple
