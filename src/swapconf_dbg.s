| swapconf_dbg.s -- diagnostic override of swapconf (0xb401e, GLOBAL T).
|
| swapconf panics (CE_PANIC) when lookupname("/dev/dsk/c6d0s2") returns ENOENT.
| On 040 (same disk that reaches login on 030) this is the FIRST namei path lookup
| of the boot.  This override turns swapconf into a NAMEI PREFIX-PROBE: it calls
| lookupname on each prefix of the failing path and prints the return code, so we
| can see exactly WHICH path component first returns ENOENT (= which directory read
| produced wrong/empty data on 040).  It also prints rootfstype (s5 vs ufs -> which
| dir-read path: bread vs fbread/segmap).  After probing it SKIPS swap (return 0) so
| the boot continues.
|
| lookupname(path, seg=1 SYSSPACE, follow=1, dirvpp=NULL, &compvpp) -- copied from the
| real swapconf call site.  rootfstype (0x9970) is the fs-type NAME string itself.
|
| swapconf GLOBAL T -> --weaken-symbol.  SVR4 gas syntax.

	.text
	.globl	swapconf
swapconf:
	linkw	%fp,&-8

	| --- print rootfstype name (s5 / ufs) ---
	pea	rootfstype
	pea	Lrootfmt
	pea	2
	jsr	cmn_err
	addaw	&12,%sp

	| --- identify root fs: rootvfs->vfs_op (s5vfsops=7fb0 / ufs_vfsops=84ec) ---
	moveal	rootvfs,%a0		| a0 = *rootvfs = vfs ptr
	movel	%a0@(4),%sp@-		| vfs->vfs_op
	pea	Lvfsfmt
	pea	2
	jsr	cmn_err
	addaw	&12,%sp

	| --- rootdir->v_op (s5vnodeops=7ff0 / ufs_vnodeops=8530) ---
	moveal	rootdir,%a0		| a0 = *rootdir = root vnode
	movel	%a0@(8),%sp@-		| vnode->v_op
	pea	Lvopfmt
	pea	2
	jsr	cmn_err
	addaw	&12,%sp

	| --- probe "/" ---
	clrl	%fp@(-4)
	pea	%fp@(-4)
	clrl	%sp@-
	pea	1
	pea	1
	pea	Lpath0
	jsr	lookupname
	addaw	&20,%sp
	movel	%d0,%sp@-
	pea	Lpath0
	pea	Lfmt
	pea	2
	jsr	cmn_err
	addaw	&16,%sp

	| --- probe "/dev" ---
	clrl	%fp@(-4)
	pea	%fp@(-4)
	clrl	%sp@-
	pea	1
	pea	1
	pea	Lpath1
	jsr	lookupname
	addaw	&20,%sp
	movel	%d0,%sp@-
	pea	Lpath1
	pea	Lfmt
	pea	2
	jsr	cmn_err
	addaw	&16,%sp

	| --- probe "/dev/dsk" ---
	clrl	%fp@(-4)
	pea	%fp@(-4)
	clrl	%sp@-
	pea	1
	pea	1
	pea	Lpath2
	jsr	lookupname
	addaw	&20,%sp
	movel	%d0,%sp@-
	pea	Lpath2
	pea	Lfmt
	pea	2
	jsr	cmn_err
	addaw	&16,%sp

	| --- probe "/dev/dsk/c6d0s2" ---
	clrl	%fp@(-4)
	pea	%fp@(-4)
	clrl	%sp@-
	pea	1
	pea	1
	pea	Lpath3
	jsr	lookupname
	addaw	&20,%sp
	movel	%d0,%sp@-
	pea	Lpath3
	pea	Lfmt
	pea	2
	jsr	cmn_err
	addaw	&16,%sp

	| --- skip swap, return 0 so boot continues ---
	clrl	%d0
	moveal	%d0,%a0
	unlk	%fp
	rts
	nop				| pad .text to a 4-byte multiple

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
Lrootfmt:
	.asciz	"DBG namei-probe: rootfstype=%s"
	.even
Lvfsfmt:
	.asciz	"DBG namei-probe: rootvfs->vfs_op=%x (s5=7fb0 ufs=84ec)"
	.even
Lvopfmt:
	.asciz	"DBG namei-probe: rootdir->v_op=%x (s5=7ff0 ufs=8530)"
	.even
Lfmt:
	.asciz	"DBG namei-probe: %s -> r=%x"
	.even
Lpath0:
	.asciz	"/"
	.even
Lpath1:
	.asciz	"/dev"
	.even
Lpath2:
	.asciz	"/dev/dsk"
	.even
Lpath3:
	.asciz	"/dev/dsk/c6d0s2"
	.even
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
