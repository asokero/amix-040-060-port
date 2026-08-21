# The physical address map this port works in — every line with its source

2026-08-20. Written because a plausible-looking sketch of this map had addresses wrong and was not
monotonic, and because a wrong memory map is the kind of document that gets believed. Reviewed
before it was committed, which changed four rows and sharpened a fifth — the review notes are
folded in below rather than kept separately.

**Every row is labelled with where it comes from.**

| tag | meaning |
|---|---|
| `[measured]` | this machine printed it during a boot recorded in this repository |
| `[AMIX]` | a definition in AMIX's own sources |
| `[firmware]` | an address decoder in a card's HDL |
| `[ours]` | this port's own source |
| `[external]` | an authoritative published specification, cited but not held in this repository |
| `[inferred]` | derived from the rows around it rather than stated anywhere — **the weakest class** |

`[external]` is not weak evidence. For a question about what the *hardware decodes*, a bus
specification outranks both kernel source and a single machine's observation; kernel source tells
you what one operating system does with the decode, and a measurement tells you where one board
landed on one day. `[inferred]` is the class to challenge first.

The machine is **solon**: Amiga 3000, Mercury 68060 @ 66 MHz, 32 MB accelerator RAM, 16 MB
motherboard Fast RAM, A2065 Ethernet, ACT Prelude, MNT VA2000 and a Piccolo.

## Physical address space

```
  0x00000000  +----------------------------------------------+
              | Chip RAM                              2 MiB  |  [AMIX] amiga.h ACRTOP = 0x200000
              |                                               |         is the top of chip RAM
              |                                               |  [measured] mem[2] 00004020-00200000
  0x00200000  +----------------------------------------------+
              | Zorro II expansion MEMORY space               |  [external] the Zorro II space runs
              | autoconfigured card RAM and apertures         |             0x00200000-0x009FFFFF
              |                                               |  [measured] the VA2000 sat at
              |                                               |             00200000, 4 MiB, in
              |                                               |             Zorro II mode
  0x00A00000  +----------------------------------------------+
              | Custom chip / CIA / I-O region                |  [AMIX] amiga.h AHWBOT = 0xa00000,
              |   0x00BFD000  CIA-B                           |         AHWTOP = 0xe00000 bracket it
              |   0x00BFE001  CIA-A                           |  [AMIX] amigahr.h ACIAB
              |   0x00DFF000  custom chip registers           |  [AMIX] amigahr.h ACIAA, AMIGA
  0x00E00000  +----------------------------------------------+
              |   0x00E80000  Zorro II AutoConfig    64 KiB  |  [external] the reserved window is
              |               0x00E80000-0x00E8FFFF           |             0x00E80000-0x00E8FFFF
              |               a board decodes the first 128 B |  [firmware] va2000.v autoconf_low
              |                                               |             = 0xe80000, autoconf_high
              |                                               |             = 0xe80080 -- what THIS
              |                                               |             card decodes, not the
              |                                               |             size of the window
              |   0x00E90000  Zorro II I-O space              |  [measured] A2065 00e90000,
              |               0x00E90000-0x00EFFFFF           |             Prelude 00ea0000,
              |                                               |             Piccolo regs 00eb0000
  0x00F80000  +----------------------------------------------+
              | Kickstart ROM                                 |  [AMIX] servant.s jumps ([0xF80028]),
              |                                               |         so the ROM contains that
              |                                               |         vector; the extent of the
              |                                               |         ROM image is [inferred]
  0x01000000  +----------------------------------------------+
              | nothing reported on this machine              |  [measured] no board and no memory
              |                                               |             region in this range --
              |                                               |             an absence of a report,
              |                                               |             not a decode fact
  0x07000000  +----------------------------------------------+
              | A3000 motherboard Fast RAM           16 MiB  |  [measured] mem[1] 07000020-08000000
  0x08000000  +----------------------------------------------+
              | Accelerator RAM (Mercury)            32 MiB  |  [measured] mem[0] 08000020-0a000000
              | THE KERNEL IS LOADED HERE, at 0x08000000      |  [measured] loader: entry=08000000
  0x0A000000  +----------------------------------------------+
              | nothing reported on this machine              |  [measured] as above -- absence of a
              |                                               |             report, not a decode fact
  0x10000000  +----------------------------------------------+
              | Zorro III expansion space (hardware decode)   |  [external] the A3000 hardware map
              |                                               |             gives 0x10000000-0x7FFFFFFF
  0x40000000  +----------------------------------------------+
              | ... where AmigaOS actually ALLOCATES Zorro III|  [external] EZ3_CONFIGAREA
              | boards, and therefore where they are found    |  [measured] Piccolo RAM 40000000,
              |   0x40000000  Piccolo RAM            16 MiB  |             16 MiB
              |   0x42000000  VA2000                 32 MiB  |  [measured] VA2000 42000000, 32 MiB,
              |                                               |             Zorro III firmware
  0x80000000  +----------------------------------------------+
              | nothing reported on this machine              |  [measured] same caveat as above
  0xFF000000  +----------------------------------------------+
              | Zorro III AutoConfig            64 KiB       |  [firmware] va2000.v decodes
              | 0xFF000000-0xFF00FFFF                         |             z3addr[31:16] == 'hff00,
              |                                               |             which is exactly 64 KiB
  0xFF010000  +----------------------------------------------+
              | nothing reported on this machine              |  [measured] same caveat as above
  0xFFFFFFFF  +----------------------------------------------+
```

**The distinction at `0x10000000` versus `0x40000000` matters and is easy to lose.** The hardware
decodes a large Zorro III region; AmigaOS *allocates* boards from `0x40000000` upward. A sketch
that gives only `0x10000000` is not wrong about the bus, but it will not match any board this
machine has ever reported — and a sketch that gives only `0x40000000`, as an earlier draft of this
document did, mislabels an allocation policy as an address space.

## AMIX virtual / MMU overlay — NOT physical addresses

Drawn separately because the previous version drew these in the same column as physical regions,
which is the last interpretation trap in a map like this. Nothing below is a physical address.

```
  VA 0x00000000-0x3FFFFFFF   DTT0 = 0x003fc060, identity, noncacheable        [ours] pstart040.s
  VA 0x40000000              THE FIXED U-AREA                                 [ours] pstart040.s:245
                             ("leaf page table for the u-area (VA 0x40000000)")       fpsp_glue040.s:21
  VA 0x40000000-0x7FFFFFFF   kernel virtual region 1: kvseg / segmap / sptmap [ours] prfastmap040.s:33
  VA 0x40040000              syssegs; kvseg.s_base is initialised to this      [ours] kvm040.s:21
                             (kvseg is a struct seg; syssegs is the VA symbol) [measured] nm: syssegs
  VA 0x40440000              kvsegmap                                         [measured] nm: kvsegmap
  VA 0x48440000              kvsegu                                           [measured] nm: kvsegu
  VA 0x80000000-0xFFFFFFFF   DTT1 = 0x807fa060, identity, SUPERVISOR-ONLY     [ours] pstart040.s
```

## Why the overlay is the point of this document

**Zorro III boards are allocated from `0x40000000`, and AMIX's kernel virtual region 1 begins at
exactly the same number.** They are different address spaces, but a driver cannot tell them apart:
drivers dereference the AutoConfig board address directly as a kernel address. Commodore's own TIGA
driver does it (`amix-src` `sys/amiga/driver/tiga.c:45`), so the pattern is theirs.

In Zorro II that is harmless, because the physical address falls inside DTT0's identity window and
the dereference reaches the board. In Zorro III the same dereference is interpreted as a kernel
virtual address and **reaches kernel memory instead of the device**. What it finds depends entirely
on which kernel address it collides with:

* at **`0x40000000` exactly** — where AmigaOS starts allocating, and where the Piccolo sits on this
  machine — it lands on **the fixed u-area**, i.e. the current process's u-block;
* elsewhere in region 1 it may hit an existing `kvseg`, `segmap` or `sptmap` mapping;
* an **unmapped** address in region 1 normally enters the kernel fault path and **fails** there;
* a write may corrupt whichever live mapping it found.

**"kvseg is fill-on-fault" is refuted, and this document is where that is recorded.** The belief
has been repeated in this repository for months. It does not survive reading the code:

```
segkmem_fault @ 0xa83d6   type = fp@(20)
    type == 2 (F_SOFTLOCK) or 3 (F_SOFTUNLOCK)  ->  return 0
    otherwise (F_INVAL = 0, F_PROT = 1)         ->  return -1
```

The enum ordering is not assumed — it is in the reader's own AMIX headers
(`vanilla/usr/include/vm/seg.h:69`) and in the 3B2 reference (`vm/seg.h:45-50`), which agree. And
the 3B2 `segkmem_fault` is `return (-1);` unconditionally, so AMIX's version is the *more* generous
of the two and still fails an ordinary invalid fault. There is no path there that allocates a
zero-filled page.

So the July 2026 observation of zeros through a Zorro III address has a better explanation than
the one it was given at the time, and it is the one above: **`0x40000000` is the fixed u-area.**
The read was serviced by a real, live kernel mapping — which is worse than a zero page, not
better.

The earlier phrasing "reads zeros" therefore described one observed case *and* attributed it to
the wrong mechanism.

Neither transparent-translation register covers Zorro III, and neither can be widened to: extending
DTT0 up or DTT1 down across `0x40000000` would swallow the kernel's own region 1
(`[ours]`, `src/prfastmap040.s:33`). A real page mapping is the only route, which is what
`dev_kvmap` exists for.

## Addresses move — two separate demonstrations, not one

Both are worth keeping, and the earlier version ran them together as though they were one event.

**A. A card's address changed because a *different* card's jumper moved.** The VA2000 was recorded
at `0x00600000` in older notes. When the Piccolo's RAM board was jumpered from Zorro II into Zorro
III it stopped occupying Zorro II memory space, and AutoConfig subsequently placed the VA2000 at
`0x00200000` — where this repository measured it on the morning of 2026-08-19.

**B. A card's address changed because its own firmware changed.** That evening the VA2000's own
firmware was swapped from Zorro II to Zorro III and it moved from `0x00200000` to `0x42000000` —
not to `0x40000000`, because the Piccolo already held the first 16 MiB of the allocation area.

So the placements in the Zorro rows of this map are properties of **one hardware and firmware
topology and the AutoConfig result it produces** — not of the machine, and not of the bus. On an
unchanged configuration they are normally deterministic and repeat across resets; they change when
a card, a jumper or a firmware does. The ranges are stable; the addresses inside them are assigned
at every reset. No driver may hardcode one — which is exactly what this port's change B removed.

## What is deliberately not claimed

* **The extent of the Kickstart ROM image.** A reboot vector at `0xF80028` proves the ROM contains
  that address, nothing more.
* **That the gap between `0x0A000000` and `0x10000000` decodes to nothing.** No board and no memory
  region was reported there. That is an absence of a report, not a decode fact.
* **DMA visibility of chip RAM.** `ACRTOP` gives the top of chip RAM; it says nothing about which
  agents can reach it. The earlier version asserted "DMA-visible" with `ACRTOP` cited beside it,
  which the citation did not support.
* **Anything about a machine other than this one.** Motherboard Fast RAM at `0x07000000` and
  accelerator RAM at `0x08000000` are what *this* A3000 reports; the load base alone differs by
  16 MiB between the Mercury and an A3640 (`STATUS.md` §2).

## Sources, so the next reader can re-check rather than re-derive

| what | where |
|---|---|
| Chip RAM top, custom-chip region bounds | `amix-src` `sys/amiga/inc/amiga.h` — `ACRTOP`, `AHWBOT`, `AHWTOP` |
| CIA-A, CIA-B, custom chip base | `amix-src` `sys/amiga/inc/amigahr.h` — `ACIAA`, `ACIAB`, `AMIGA` |
| Kickstart reboot vector | `amix-src` `sys/amiga/kernel/servant.s` — `jmp ([0xF80028])` |
| what a card decodes for Zorro II AutoConfig | VA2000 firmware `va2000.v` — `autoconf_low`, `autoconf_high` |
| Zorro III AutoConfig window | VA2000 firmware `va2000.v` — `z3addr[31:16] == 'hff00` |
| every board and memory region on this machine | the loader's board dump, in the boot logs behind `docs/REALHW-Z3-VA2000-ACCEPTANCE-260819.md` |
| DTT0, DTT1, the fixed u-area | `src/pstart040.s`; `src/fpsp_glue040.s` |
| kernel virtual region 1, kvseg base | `src/prfastmap040.s`, `src/kvm040.s` |
| Zorro II / Zorro III space bounds | *The Zorro III Bus Specification*, revision 1.10 — Figure 1-1, §2.1.2, §8.1 |
| A3000 physical decode ranges | *A3000 Hardware Manual*, "A3000 Memory Map" |
| `EZ3_CONFIGAREA` / `EZ3_CONFIGAREAEND` | AmigaOS `libraries/configregs.h` |
| | **The three rows above are `[external]`. They were supplied by review, are not held in this repository, and were not opened here — cite them onward as second-hand until someone checks them.** |
| why the Zorro III collision matters | `docs/REALHW-Z3-VA2000-ACCEPTANCE-260819.md`, `STATUS.md` "Zorro III" |
