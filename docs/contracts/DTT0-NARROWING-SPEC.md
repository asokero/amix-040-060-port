# 68040 DTT0 narrowing and Step-B enable specification

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/DTT0-NARROWING-SPEC.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** The key decision of this specification is
> still live: DTT0 remains `0x003fc060`; it was not narrowed as part of cache
> enablement. The B1 sequence was hardware-accepted and the port subsequently
> moved managed RAM to copyback after the separate page-lifecycle and A3091
> ownership gates landed. Copyback with retained DTT0 is the current accepted
> policy; the optional N1/N2 identity-map redesign below remains future work,
> not a publication blocker.

## Decision

For the first real-hardware 68040 B1 writethrough pilot:

```text
DTT0     keep 0x003fc060
DTT1     keep 0x807fa060
ITT0     keep 0x003fc000
RAM PTE  CM=00 writethrough
device   CM=10/11 NCS/NC according to the existing classifier
CACR     change 0x00008000 -> 0x80008000
```

Do **not** narrow or disable DTT0 in the same build as the first DC flip.

This is not a retreat from per-page CM. DTT0 matches only low logical data
addresses. The high PTE-backed kvseg/sysseg/segmap/user mappings already take
CM from their leaf entries and will become WT when CACR.DE is set. Keeping
DTT0 preserves NC access for direct physical page primitives and page-table
walkers while the high mappings exercise the B1 cache policy.

The original expected verdict, `DTT0 E=0`, is rejected for the pinned image:
the kernel SRP has no low identity map. A literal disable is an immediate
translation fault, not a cache-policy improvement.

## Preconditions for B1

The hardware pilot may proceed only when all of these are true in the linked
image being tested:

1. `hat_cm_ram == 0x00`; no live constructor emits copyback `0x20`.
2. segu/fixed-u mappings remain NC and unmanaged device mappings remain
   NCS/NC as recorded in `CM-PTE-WRITER-MATRIX.md`.
3. Every live descriptor writer has its B1 publication tail.
4. The A3091/SDMAC FROM_DEVICE stop wrapper is linked and its completion
   counter advances; no unhooked host-DMA controller is used in the session.
5. `hat_pagesync 0xd877c` matches the current accepted byte sequence described
   below.
6. The test is run on real 68040 hardware. Emulator success is regression
   evidence, not DC-coherency acceptance.

## Corrected DTT0 model

Current register decode:

| Register | Value | Logical match | Mode |
|---|---:|---|---|
| ITT0 | `0x003fc000` | instruction `0x00000000..0x3fffffff` | WT |
| DTT0 | `0x003fc060` | data `0x00000000..0x3fffffff`, user and supervisor | NC |
| DTT1 | `0x807fa060` | supervisor data `0x80000000..0xffffffff` | NC |

The TTR base/mask is a logical-address test. A load through `0x40326000`, for
example, does not match DTT0 even when its leaf PTE points to physical
`0x08000000`. Its data CM comes from that leaf PTE.

On the 68040, mixed high cacheable and low NC CPU aliases are kept coherent by
physical cache tags and the NC-access matching-line rule. The conservative
reason to retain DTT0 in B1 is therefore not to hide an unfixable incoherent
alias. It is to retain valid translations and keep direct page/table/MMIO
access noncacheable while the first hardware test changes only one major
variable.

External DMA remains non-snooping and is not covered by this rule.

## B1 CACR enable sequence

The current linked sequence is:

```text
0xd7560  f4 98                  cinva ic
0xd7562  20 3c 00 00 80 00     move.l #0x00008000,d0
0xd7568  23 c0 .... ....        move.l d0,cacr
0xd756e  23 c0 .... ....        move.l d0,sup_cacr
0xd7574  4e 7b 00 02           movec d0,cacr
```

Required B1 semantic sequence, executed at high IPL after MMU/table setup:

```text
assert hat_cm_ram == 0x00 and no live CM=01 mapping
cinva dc
cinva ic                    # preserve the current Step-A start-clean rule
d0 = 0x80008000             # DE + IE
cacr = d0
sup_cacr = d0
movec d0,cacr
restore interrupt level
```

The global stores must precede interrupt re-enablement so the trap machinery
cannot restore the old value. Source inspection corrects another inherited
shorthand: `p1int`, `p2int`, `p3int`, `p4int`, `p6int`, and `nullvect` load
`sup_cacr`; `p5int` does not. `p5int` also does not change CACR, so equal
user/supervisor B1 values make this harmless. Return-to-user loads `cacr`.

The old-byte anchor for the immediate is:

```text
0xd7562: 20 3c 00 00 80 00
target:  movel #0x80008000,d0
```

Adding `cinva dc` needs an assembled override or an explicitly sized patch;
do not shift the appended object by editing raw bytes without relocation and
layout assertions.

### Shutdown ordering

Current `haltsys 0xd9748` clears TC/ITT/DTT, executes `pflusha`, and only then
writes CACR=0. Before enabling DC, harden this ordering:

- B1 WT: `cinva dc` before disabling CACR/translation is conservative; there
  should be no dirty data lines.
- B2 CB: `cpusha dc` is mandatory before CACR or translation is disabled;
  invalidating dirty lines would lose data.

This is a cache-on acceptance item even though it is not needed to reach the
first login prompt.

## Why immediate DTT0 disable fails

The current pstart storage and root construction are:

```text
root040             512 bytes
kptr040             32 * 512 bytes, assigned only to root[32..63]
uarea_pt             256 bytes
root[0..31]          zero / invalid
```

Low kernel code/data/stack and direct physical pointers therefore have no SRP
translation fallback. The following live classes would fail with DTT0 E=0:

- low kernel static data, bootstrap stack, and `mmu040_buf`;
- `ppcopy`, `pagecopy`, and `pagezero` direct PFN addresses;
- `mlsetup` physical-memory clear;
- `hat_ptalloc` return values and all descriptor-derived child-table pointers;
- `vatosde`/`vatopte`, HAT walkers, `bp_map/out`, `resume`, and `prumap` table
  access;
- `/dev/mem`, `/dev/amiga`, `vtop` CPU consumers, and low device registers;
- chip-RAM Paula buffers and board apertures.

Changing only this immediate is therefore forbidden:

```text
old @0xd7532: 20 3c 00 3f c0 60 4e 7b 00 06
bad target:    20 3c 00 00 00 00 4e 7b 00 06
```

## Later DTT0 milestone

DTT0 removal should be implemented and accepted independently after B1. The
recommended sequence has two possible stages.

### N1: 16 MiB low NC compatibility window

A useful intermediate TTR value is:

```text
0x0000c060   low 16 MiB, user+supervisor, NC; preserves current FC behavior
0x0000a060   low 16 MiB, supervisor-only, NC; cleaner final policy
```

The minimum TTR block is 16 MiB. This range contains the linked low kernel,
chip RAM, custom chips, CIAs, and classic low motherboard registers. It does
not cover arbitrary fast-RAM PFNs.

For the first N1 experiment, `0x0000c060` minimizes semantic change. Moving to
`0x0000a060` should be a separate hardening step after proving that no supported
user ABI relies on transparent low addresses.

N1 still requires page-table-backed low identity mappings for every managed
RAM extent at or above 16 MiB. It is not a standalone immediate patch.

### N2: DTT0 disabled

The architecture-clean end state is:

```text
DTT0 = 0x00000000
```

It requires all of N1 plus explicit page mappings for low kernel/chip/MMIO
ranges and a replacement for arbitrary physical probing. It has no practical
advantage for the first B1 pilot.

## Required low identity-map design

Before N1 or N2, add a real low-map owner while broad DTT0 is still active.
The map must classify by actual physical extent, not map 0..1 GiB as cacheable.

| Physical class | Low identity leaf CM | Notes |
|---|---|---|
| managed ordinary RAM | B1 WT (`00`), later B2 policy | needed by direct PFN page primitives and `vtop` CPU consumers |
| page-table storage | preferably NC/NCS | dedicated table alias is safer than ordinary CB RAM |
| kernel image/static storage | WT for B1 | low 16 MiB TTR can defer this class in N1 |
| chip RAM | NC/NCS | Paula and display ownership invariant |
| custom/CIA/Ramsey/controller MMIO | NCS/NC | never ordinary RAM CM |
| unmapped physical holes | invalid | do not create speculative/cacheable bus accesses |
| arbitrary `/dev/mem` target | transient NCS mapping | not a permanent identity mapping |

Implementation geometry is the live 040 geometry:

```text
A = (pa >> 25) & 0x7f
B = (pa >> 18) & 0x7f
C = (pa >> 12) & 0x3f
```

The current static `kptr040` cannot back both roots 0..31 and 32..63. N1/N2
must allocate separate low pointer/leaf tables, put physical bases in the
descriptors, and retain software-accessible aliases for those tables.

Required construction order:

1. keep broad DTT0 active and DC disabled;
2. allocate/zero low pointer and leaf tables;
3. map real managed-RAM extents and explicit low device/chip ranges;
4. publish descriptor stores with `cpusha dc`, then `pflusha`;
5. validate representative low translations while DTT0 still provides a
   recovery path;
6. at high IPL, load the narrowed DTT0 value and `pflusha`;
7. validate with DC still disabled;
8. enable DC in a later, independently identifiable step.

DTT0 narrowing and CACR DC enable should not be one unobservable atomic patch.
Separating them makes a bad translation distinguishable from cache
coherency failure on real hardware.

## Direct-path conversion policy

With a complete low identity map, correct Model-B direct PFN users can remain
unchanged. Without one, each must move to a transient mapped copy window.

| Path class | Preferred N1/N2 policy |
|---|---|
| `ppcopy/pagecopy/pagezero` | managed-RAM identity PTEs for minimal code churn; copy-window alternative if alias policy demands it |
| HAT child-table walkers | dedicated NC table alias or NC low identity PTE; do not leave raw physical pointers unmapped |
| `gen_strategy/vtop` DMA address | retain physical value for hardware; do not confuse DMA address with CPU KVA |
| `ramstrategy`/tape CPU use of `vtop` | use identity PTE only for managed RAM, or convert returned physical address to a mapped KVA |
| `/dev/mem` | bounded transient NCS physmap window with teardown, fault guard, and range policy |
| `/dev/amiga`/low MMIO | explicit NCS PTE or retained 16 MiB TTR |
| RFS/procfs legacy sites | port their 4 KiB geometry first; DTT work must not legitimize wrong `<<11` addresses |

## Page-table coherency verdict

### B1 with DTT0 retained

Pass. Static and dynamic child tables are reached by software through the low
NC alias. The KVA-backed user root is WT and is published before URP exposure.
The current writer matrix plus `hat_pagesync` supplies post-write publication
and ATC invalidation.

### Later WT identity map

Functionally viable on 68040 if all writer-matrix guarantees remain complete:

- WT CPU stores reach external memory;
- publication remains before parent/root exposure;
- hardware U/M RMW cycles use CI behavior and dislodge matching cached lines;
- teardown pushes before physical table reuse and flushes the ATC.

Motorola nevertheless strongly recommends CI translation-table storage. A
dedicated NC software table alias is the preferred long-term design, especially
before extending the same policy to 68060.

### B2

Do not classify descriptor pages as ordinary copyback RAM. B2 needs either a
permanent NC table alias/class or a separately proved descriptor publication
and reclamation protocol. The B1 census is not acceptance for that change.

## `hat_pagesync040` gate closure

The requested latent `cpusha` check is already satisfied in the pinned image:

```text
hat_pagesync              0x000d877c
no-mapping exit           0x000d878e -> 0x000d87cc
U/M clear store           0x000d87bc: 22 80
reverse-map next          0x000d87be: pte + 0x100
publication tail          0x000d87c8: f4 f8 f5 18
                                      cpusha bc; pflusha
```

The cache-publication criterion passes. Existing acceptance caveats about
validating the entry's resident/PFN class and bounding a corrupt reverse-map
chain remain separate; they do not reopen the `cpusha` gap.

## Hardware acceptance plan

### B1 pilot, DTT0 unchanged

Record at minimum:

1. exact kernel hash and read-back `CACR=0x80008000`;
2. DTT0/DTT1 values unchanged;
3. representative kvseg RAM PTE CM=00 and segu/device PTE CM=NC/NCS;
4. A3091 completion counter advancing under disk reads;
5. repeated boot/login and fork/COW suite;
6. SCSI read/write checksums, swap pressure, NFS/local copies, and concurrent
   fork/network/disk load;
7. `/dev/mem` and low hardware smoke tests used by existing diagnostics;
8. clean halt/reboot after the shutdown cache-ordering fix.

Any failure should be reproduced once with CACR.DE clear and identical DTT/PTE
state. That separates cache exposure from an unrelated mapping regression.

### Later N1/N2 test

Test with DC disabled first:

- low kernel/static accesses;
- managed pages below and above the 16 MiB boundary;
- `ppcopy/pagezero`, COW, page-in/pageout, and swap;
- HAT allocation/free under pressure;
- `/dev/mem` valid RAM, valid MMIO, and invalid-hole behavior;
- chip audio/floppy/display and controller registers;
- halt/reboot translation teardown.

Only after this passes should the same image enable DC.

## Definition of done

The immediate Step-B gate is closed when:

```text
DTT0 remains 0x003fc060
B1 emits no copyback data mappings
the selected host-DMA controller has completion invalidation
hat_pagesync and all live descriptor writers publish correctly
CACR enable and shutdown ordering are old-byte asserted
the B1 matrix passes on real 68040 hardware
```

DTT0 narrowing itself is done only when a low identity-map/physmap owner has
replaced every dependency in `DTT0-PHYS-WINDOW-CENSUS.md` and the change passes
with DC disabled before any cache-on acceptance run.
