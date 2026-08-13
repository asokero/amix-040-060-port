| kmem_validate.s -- kmem free-list VALIDATOR wrapper around kmem_alloc (0x41fa8, GLOBAL T).
| On every kmem_alloc entry, scan the 9 Km_FreeLists bins (heads at Km_FreeLists+0x14,
| stride 0x14; circular doubly-linked, next@0/prev@4, empty bin <=> head->next == head)
| and, the FIRST time a corrupt forward link is found, dump the details via cmn_err(CE_WARN)
| then continue into the original kmem_alloc unchanged.
|
| WHY: ISSUE-5 heap-corruption hunt.  A free block's `next` (offset 0) gets overwritten
| with garbage and kmem_alloc's unlink dereferences it -> Bus Error at kmem_alloc+0x174.
| Catching the garbage VALUE at the first alloc after the stomp names the corruptor.
|
| Validity rule: a `next` pointer is EITHER its own bin head OR an even address inside
| the kernel heap [0x40040000, 0x40440000) (syssegs..kvsegmap).  Everything else = CORRUPT.
| Every deref is guarded by that range+alignment check first, so this instrument can
| NEVER itself fault.  The only memory the wrapper writes is the Lkv_n latch (cap 4
| firings; after 4 the scan is skipped entirely).
|
| Mechanism (same as ktrap_latch.s): objcopy --add-symbol kmem_alloc_orig=.text:0x41fa8
| + --weaken-symbol kmem_alloc; this strong wrapper scans then TAIL-JMPs to
| kmem_alloc_orig with the stack restored to the original `jsr kmem_alloc` state, so
| the caller's args (size at sp@(4), flags at sp@(8)) and return path are untouched.
| Km_FreeLists is file-local in the stock kernel -> --globalize-symbol so our GLOBAL
| ref binds (ld -r cannot bind GLOBAL refs to FILE-LOCAL symbols).

	.text
	.globl	kmem_alloc
kmem_alloc:
	linkw	%fp,&0
	movel	%a2,%sp@-		| save regs we clobber (cmn_err only clobbers
	movel	%a3,%sp@-		| d0/d1/a0/a1, so these survive the report too)
	movel	%a4,%sp@-
	movel	%d3,%sp@-
| --- latch: after 4 firings skip the scan entirely ---
	movel	Lkv_n,%d0
	cmpil	&4,%d0
	bccw	Lkv_done
| --- scan the 9 bins ---
	lea	Km_FreeLists+0x14,%a2	| a2 = first bin head
	movel	&9,%d3			| d3 = bin count
Lkv_loop:
	moveal	%a2@(0),%a3		| a3 = head->next = first block (head addr is valid)
	cmpal	%a2,%a3
	beqb	Lkv_next		| next == head -> empty bin
| validate a3 (first block ptr) BEFORE dereferencing it
	movel	%a3,%d0
	btst	&0,%d0
	bnew	Lkv_badhead		| misaligned
	cmpil	&0x40040000,%d0
	bcsw	Lkv_badhead		| below heap
	cmpil	&0x40440000,%d0
	bccw	Lkv_badhead		| at/above heap end
| a3 is in-heap and aligned -> safe to deref its next (THE field that crashes kmem_alloc)
	moveal	%a3@(0),%a4		| a4 = block->next
	cmpal	%a2,%a4
	beqb	Lkv_next		| points back to head (length-1 list) = OK
	movel	%a4,%d0
	btst	&0,%d0
	bnew	Lkv_badnext
	cmpil	&0x40040000,%d0
	bcsw	Lkv_badnext
	cmpil	&0x40440000,%d0
	bccw	Lkv_badnext
Lkv_next:
	lea	%a2@(0x14),%a2		| next bin head
	subql	&1,%d3
	bnew	Lkv_loop
	braw	Lkv_done
| --- CORRUPT: the bin head's own next is garbage (a3 never dereferenced) ---
Lkv_badhead:
	addql	&1,Lkv_n
	movel	%fp@(8),%sp@-		| size  = caller's first arg
	movel	%fp@(4),%sp@-		| caller = return address into immediate caller
	clrl	%sp@-			| prev  = 0 (a3 not safe to deref)
	movel	%a3,%sp@-		| next  = a3 (the garbage value itself)
	movel	%a3,%sp@-		| blk   = a3
	movel	%a2,%sp@-		| bin   = bin head address
	pea	Lkv_m1
	pea	2
	jsr	cmn_err
	lea	%sp@(32),%sp
	braw	Lkv_done		| break after first report (latch bounds reruns)
| --- CORRUPT: first block's forward link is garbage ---
Lkv_badnext:
	addql	&1,Lkv_n
	movel	%fp@(8),%sp@-		| size
	movel	%fp@(4),%sp@-		| caller
	movel	%a3@(4),%sp@-		| prev = block's back link (a3 in-heap: safe)
	movel	%a4,%sp@-		| next = the garbage forward link (the key value)
	movel	%a3,%sp@-		| blk  = the block whose next is stomped
	movel	%a2,%sp@-		| bin  = bin head address
	pea	Lkv_m1
	pea	2
	jsr	cmn_err
	lea	%sp@(32),%sp
	braw	Lkv_done
Lkv_done:
	movel	%sp@+,%d3		| restore regs
	moveal	%sp@+,%a4
	moveal	%sp@+,%a3
	moveal	%sp@+,%a2
	unlk	%fp			| sp -> [retaddr][size][flags]: original jsr state
	jmp	kmem_alloc_orig		| tail-call: original runs as if called directly

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even
Lkv_m1:
	.asciz	"DBG KMEMCORRUPT bin=%x blk=%x next=%x prev=%x caller=%x size=%x"
	.even
Lkv_n:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
