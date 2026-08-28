# Hardware acceptance — `dma_*` and `Lkx_*` magic words, 2026-08-29

Kernel `68060-260829-05` (built here as `68040-260829-05`; the banner prefix is the CPU readout,
not the image). Amiga 3000, Mercury 68060. Read over telnet with `/kpeek`.

## The magics, and one control

    KPEEK 0810e2c4 = 4c4b5821   LKX!   new
    KPEEK 0810e660 = 444d4121   DMA!   new
    KPEEK 0810e7ec = 41335721   A3W!   control -- an existing block after the shift

The control matters as much as the two new ones. Adding a longword to the head of two `.data`
blocks moves every block after them, which is the failure this port has hit three times in two
days. `a3w_magic` reading correctly at its recomputed address says the shift was absorbed.

The loader's own numbers confirm the arithmetic independently: it printed `tsize=000f58fc`, and
`0x080F58FC + 0x18d64` is exactly the `0810E660` that `tools/status-facts.sh` computed for
`dma_magic` from `nm` alone.

## The `dma` block is internally consistent

    +0x00 dma_magic        444d4121   "DMA!"
    +0x04 dma_seg_pa       09ed1800
    +0x08 dma_seg_len      00000800   2048
    +0x0c dma_seg_seq      0000120f   4623
    +0x10 dma_seg_dir      00         TO_DEVICE
    +0x11 dma_seg_state    00         EMPTY
    +0x14 dma_prep_to      000007f0   2032
    +0x18 dma_prep_from    00000a1f   2591
    +0x1c dma_cmpl_to      000007f0   2032
    +0x20 dma_cmpl_from    00000a1f   2591
    +0x24 dma_zero_arm     00000000
    +0x28 dma_reconn_arm   00000000
    +0x2c dma_prep_owned   00000000   must stay 0
    +0x30 dma_cmpl_noprep  00000000   must stay 0
    +0x34 dma_range_ovf    00000000   must stay 0
    +0x38 dma_prep_whole   0000120f   4623
    +0x3c dma_cmpl_count   0000120f   4623

The block's own documented acceptance is `prep_to + prep_from == cmpl_to + cmpl_from`, and
2032 + 2591 = 4623 on both sides. `dma_cmpl_count` and `dma_seg_seq` agree with that total, and
all three must-stay-zero counters are zero.

This is what a magic buys. The same seventeen numbers read four bytes early would have been
seventeen different plausible numbers, and the pairing identity would have failed for a reason
that has nothing to do with DMA.

## The `Lkx` block

    Lkx_depth           0   nothing resolving at rest
    Lkx_fallback_depth  0
    Lkx_badslot         0   must stay 0
    Lkx_noproc          0
    Lkx_underflow       0   must stay 0
    Lkx_maxdepth        1
    Lkx_maxactive       2

`src/krnxmemflt040.s` says of `Lkx_maxactive`: *"if this exceeds 4 while maxdepth stays low, the
old global gate WOULD have produced a false EFAULT right there."* It reached 2 on this boot, so
the old gate would not have fired — consistent, and the counter is doing its stated job.

## Emulator run, same image, for comparison

Read over Amiberry IPC before the hardware boot: the same three magics, `dma_prep_to` 1127 ==
`dma_cmpl_to` 1127, `Lkx_badslot` 0. Both platforms agree; the hardware numbers are simply larger.

## Not covered

Nothing here exercises a *wrong* address on purpose. The magics are proven to read correctly at
the right address; that they would visibly fail at a wrong one follows from their being static
non-zero constants, and is not separately demonstrated on silicon.
