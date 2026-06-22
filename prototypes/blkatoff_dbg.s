| blkatoff_dbg.s -- diagnostic override of blkatoff (0x7c026, LOCAL t -> globalize
| + weaken).  blkatoff is THE ufs directory-block reader (ufs_dirlook -> blkatoff ->
| fbread -> segmap/page-cache -> ufs_getpage -> hat_pteload, the 040-risky path).
|
| The "/dev" lookup returns ENOENT but NO blkatoff dump printed in the first run, so
| either blkatoff is never reached (ufs_dirlook returns early -- e.g. root inode read
| with i_size=0 -> scan loop runs 0 times) OR fbread fails / res==0.  This version adds
| THREE independently gated one-shot prints (first 6 of each):
|   ENTRY : "blkatoff ENTER off=%x isize=%x"   (proves blkatoff is called; shows i_size)
|   FAIL  : "blkatoff off=%x FBREAD FAILED r=%x"
|   DATA  : "blkatoff off=%x data=[%x %x %x %x]" (the actual directory bytes)
| If ENTRY never prints -> the bug is upstream in ufs_dirlook (bad inode read / dnlc).
|
| Verbatim transcription of stock blkatoff (same fs-field offsets, fbread args left on
| the stack -- unlk cleans them).  cmn_err clobbers d0/d1/a0/a1, preserves d2-d7/a2-a5.
| blkatoff LOCAL -> --globalize-symbol blkatoff --weaken-symbol blkatoff.  SVR4 gas.
| ip@(100)=i_fs fs@(80)=fs_bshift fs@(72)=fs_bmask fs@(48)=fs_bsize fs@(52)=fs_fsize
| fs@(76)=fs_fmask ip@(156)=i_size ip+8=&i_vnode fbp@(0)=fb_addr.

	.text
	.globl	blkatoff
blkatoff:
	linkw	%fp,&-8
	moveml	%d2/%a2-%a4,%sp@-
	moveal	%fp@(8),%a0		| ip
	movel	%fp@(12),%d2		| offset
	moveal	%fp@(16),%a3		| res
	moveal	%fp@(20),%a4		| fbpp

	| --- ENTRY marker (first 6) ---
	movel	Lba_en,%d0
	cmpl	&6,%d0
	bccw	Lba_noent
	addql	&1,%d0
	movel	%d0,Lba_en
	movel	%a0@(156),%sp@-		| i_size
	movel	%d2,%sp@-		| offset
	pea	Lba_efmt
	pea	2
	jsr	cmn_err
	lea	%sp@(16),%sp
	moveal	%fp@(8),%a0		| reload ip (cmn_err clobbered a0)
Lba_noent:

	moveal	%a0@(100),%a2		| fs
	movel	%d2,%d0
	movel	%a2@(80),%d1
	asrl	%d1,%d0			| lbn = offset >> bshift
	moveq	&11,%d1
	cmpl	%d0,%d1
	bltw	Lba_1
	addql	&1,%d0
	movel	%a2@(80),%d1
	asll	%d1,%d0
	cmpl	%a0@(156),%d0
	bgtw	Lba_2
Lba_1:
	movel	%a2@(48),%d0		| full block size
	braw	Lba_3
Lba_2:
	movel	%a2@(72),%d0
	notl	%d0
	andl	%a0@(156),%d0
	addl	%a2@(52),%d0
	subql	&1,%d0
	andl	%a2@(76),%d0
Lba_3:
	pea	%fp@(-4)
	clrl	%sp@-
	movel	%d0,%sp@-
	movel	%d2,%d1
	andl	%a2@(72),%d1
	movel	%d1,%sp@-
	pea	%a0@(8)
	jsr	fbread			| args left on stack (unlk cleans)
	tstl	%d0
	beqw	Lba_ok

	| --- FAIL marker (first 6) ---
	movel	Lba_fn,%d1
	cmpl	&6,%d1
	bccw	Lba_failskip
	addql	&1,%d1
	movel	%d1,Lba_fn
	movel	%d0,%sp@-		| fbread error
	movel	%d2,%sp@-		| offset
	pea	Lba_ffmt
	pea	2
	jsr	cmn_err
	lea	%sp@(16),%sp
Lba_failskip:
	clrl	%a4@			| *fbpp = 0
	braw	Lba_done
Lba_ok:
	| --- DATA dump (first 6): dump fbp->fb_addr contents (res may be NULL) ---
	movel	Lba_dn,%d1
	cmpl	&6,%d1
	bccw	Lba_afterdump
	addql	&1,%d1
	movel	%d1,Lba_dn
	moveal	%fp@(-4),%a0		| fbp
	moveal	%a0@,%a0			| fb_addr
	movel	%a0,%fp@(-8)		| stash fb_addr (free local slot)
	| dump #1: as the CPU sees it now (possibly stale 040 D-cache) ---
	movel	%a0@(12),%sp@-
	movel	%a0@(8),%sp@-
	movel	%a0@(4),%sp@-
	movel	%a0@,%sp@-
	movel	%d2,%sp@-		| offset
	pea	Lba_dfmt
	pea	2
	jsr	cmn_err
	lea	%sp@(28),%sp
	| dump #2: after invalidating the data cache -> reads PHYSICAL RAM ---
	.word	0xf458			| cinva %dc (68040: invalidate all data-cache, no push)
	nop
	moveal	%fp@(-8),%a0		| fb_addr
	movel	%a0@(12),%sp@-
	movel	%a0@(8),%sp@-
	movel	%a0@(4),%sp@-
	movel	%a0@,%sp@-
	movel	%d2,%sp@-		| offset
	pea	Lba_cfmt
	pea	2
	jsr	cmn_err
	lea	%sp@(28),%sp
	| --- READ-vs-MAP: find the canonical page-cache page for (vp, off) and read its
	| PHYSICAL RAM directly via the DTT0 identity map (phys<0x40000000, cache-inhibited).
	| If this shows real .'/'.. entries while the segmap window (dataCI) is zero -> the
	| read worked but segmap MAPPED THE WRONG PAGE.  If this is also zero -> READ never
	| happened.  vp=ip+8, off=d2 (d2 callee-saved, preserved).  pfn=(pp-*pages)/60+
	| *pages_base ; phys=pfn<<12  (matches hat_memload/hat_pteload). ---
	moveal	%fp@(8),%a0		| ip
	movel	%d2,%sp@-		| off
	pea	%a0@(8)			| vp = &ip->i_vnode
	jsr	page_find
	addqw	&8,%sp			| d0 = pp (page-cache page) or 0
	tstl	%d0
	beqw	Lba_nopage
	subl	pages,%d0		| pp - *pages
	moveq	&60,%d1
	divsll	%d1,%d0,%d0		| / 60 = page index
	addl	pages_base,%d0		| + *pages_base = pfn
	moveq	&12,%d1
	lsll	%d1,%d0			| phys = pfn << 12
	moveal	%d0,%a0			| a0 = phys (identity-mapped, cache-inhibited)
	movel	%a0@(12),%sp@-
	movel	%a0@(8),%sp@-
	movel	%a0@(4),%sp@-
	movel	%a0@,%sp@-
	movel	%d0,%sp@-		| phys
	pea	Lba_pfmt
	pea	2
	jsr	cmn_err
	lea	%sp@(28),%sp
	braw	Lba_afterdump
Lba_nopage:
	pea	Lba_npmsg
	pea	2
	jsr	cmn_err
	addqw	&8,%sp
Lba_afterdump:
	tstl	%a3
	beqw	Lba_setfbp
	moveal	%fp@(-4),%a0		| fbp
	movel	%a2@(72),%d0
	notl	%d0
	andl	%d2,%d0
	addl	%a0@,%d0		| fb_addr + (offset & ~bmask)
	movel	%d0,%a3@		| *res = data ptr
Lba_setfbp:
	movel	%fp@(-4),%a4@		| *fbpp = fbp
	clrl	%d0
Lba_done:
	moveml	%fp@(-24),%d2/%a2-%a4
	moveal	%d0,%a0
	unlk	%fp
	rts
	nop				| pad .text to a 4-byte multiple
	nop
	nop
	nop

	.data
Lba_efmt:
	.asciz	"DBG blkatoff ENTER off=%x isize=%x"
	.even
Lba_ffmt:
	.asciz	"DBG blkatoff off=%x FBREAD FAILED r=%x"
	.even
Lba_dfmt:
	.asciz	"DBG blkatoff off=%x data=[%x %x %x %x]"
	.even
Lba_cfmt:
	.asciz	"DBG blkatoff off=%x dataCI=[%x %x %x %x] (post-cinva=RAM)"
	.even
Lba_pfmt:
	.asciz	"DBG blkatoff PAGE phys=%x ram=[%x %x %x %x] (page_find via DTT0)"
	.even
Lba_npmsg:
	.asciz	"DBG blkatoff PAGE page_find -> NULL (no page-cache page)"
	.even
Lba_en:
	.long	0
Lba_fn:
	.long	0
Lba_dn:
	.long	0
