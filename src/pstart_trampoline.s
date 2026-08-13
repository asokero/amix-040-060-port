| pstart_trampoline.s
|
| Validation object for the relink pipeline.  Defines a replacement `pstart`
| that simply tail-jumps to the renamed original `pstart_030`, so the relinked
| kernel behaves EXACTLY like the stock kernel.  Used to prove the
| objcopy --redefine-sym + ld -r override mechanism end-to-end (the same
| mechanism Draft 2's real 040 pstart will use) without changing behaviour.
|
| Boots fully on 030; on 040 it reaches the original pstart's `pmove` and traps
| at bind_base+0xfd6 -- identical to the stock kernel -> proves the relink is
| behaviour-preserving.

	.text
	.globl	pstart
pstart:
	jmp	pstart_030
	nop			| pad: keep this .text contribution a multiple of
				| 4 bytes so ld doesn't insert alignment padding
				| between merged .text and .data (unix_boot/copyit
				| require text and data contiguous in the file).
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
