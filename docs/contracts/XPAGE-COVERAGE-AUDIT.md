# 68040/68060 crossing-page fault coverage audit

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/XPAGE-COVERAGE-AUDIT.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Current-state note (2026-08-14).** This document intentionally preserves
> the pinned pre-fix image and the route analysis that drove the repairs. The
> current status is: ISSUE-37's 040 crossing-page resolver is hardware-accepted;
> ISSUE-41's per-page protection check is accepted on both CPUs; ISSUE-22 was
> not an XPAGE defect and was closed by preserving DFC/SFC around write-back
> replay; and ISSUE-42's denied-replay propagation is accepted on 68040
> silicon. `STATUS.md` and the local acceptance reports are authoritative for
> those outcomes. Old-byte anchors below still apply only to their named image.

## Scope

This note answers `kernelsupport/XPAGE-COVERAGE-AUDIT-TASK.md` against the
brief-pinned linked 040 image. It enumerates the complete public access-error route
from the CPU frame to `as_fault`, classifies page-crossing handling by CPU,
trap origin, access kind, and `u_nofault`, and answers whether ISSUE-37 can
also explain ISSUE-22.

This is static analysis only. No kernel code is changed.

## Pinned input

```text
kernel task commit              d787e0d969af167a845c33f71a8bd45b4488ba8e
implementation commit in brief e17ab78
build/unix-040 build id         68040-260728-16
build/unix-040 SHA-256          b96dec1804d4731cea403e268331ab185e74a7fff2254cb2f6af3a57512942a0
.text size                      0x000e4058 (933976 bytes)
.text SHA-256                   b34befcdc60835e3dc4a5680f33886ba4012feed938e4e24398495b2a4db0730
```

The task commit adds only the brief. The image is the implementation state
described by `e17ab78`.

Canonical addresses below are ELF `.text` offsets. The image is ELF32
big-endian m68k `ET_REL`, so relocation records remain the authoritative call
targets.

### Post-pin drift

During final review the kernel repository advanced to
`064766bd918b9557e7157f23ebb5d4821a164cc6` and `build/unix-040` to build
`68040-260728-20` (SHA-256
`261d68436f5b791bca04f3efc5fd8f43a78f61702179cad2024d6f1eeaf89c36`).
The only resolver-source change after the task pin is an `xpage_on` test
before the new native kernel next-page block. Its enabled value preserves the
behavior audited here. It grows `.text` by eight bytes, however, so the
old-byte anchors in this note remain assertions for `260728-16`, not for
later images.

Commit `064766b` also records a clean 16-burst ISSUE-22 run and prepares an
enabled/disabled XPAGE A/B. That is valuable runtime attribution evidence but
does not change the static route verdict below. If disabling the kernel
helper reproduces ISSUE-22, the direct copyout explanation still needs
reconciliation with the proven `copyout -> usrxmemflt` route; an indirect
effect or a different faulting access would then be the leading distinction.

## Verdict

1. **040 scalar deferred write-backs are covered.** `wb040_replay` reissues
   each valid byte, word, or long write-back as individual `moves.b`
   operations. A byte on the far page therefore faults with its own exact
   address, and the private `u_nofault` guard lets the nested resolver map it
   before retry.
2. **The 040 read-side coverage is split.** Kernel reads now receive the
   ISSUE-37 next-page resolve in `krnxmemflt_orig`. Normal high user reads and
   instruction faults receive the older `hardbus` wrapper. Low user VAs below
   `0x80000000` are not covered by that 040 user helper.
3. **The ISSUE-22 equivalence hypothesis is statically refuted.**
   `u_nofault` does not turn a successful near-page resolve into EFAULT. It
   retries. More decisively, a guarded `copyin`/`copyout` MOVES fault has user
   transfer mode and is routed to `usrxmemflt`; today's ISSUE-37 change is in
   `krnxmemflt_orig` and is not reached. ISSUE-22 remains open.
4. **The 060 last-eight-byte heuristic is not architecture-complete.**
   `wb060_sswsynth` overwrites the FSLW half containing MA before
   `wb060_xpage` runs, and the helper never tests MA. The 68060 architecture
   supports 96-bit operands and reports an instruction-extension fault using
   the opword address. Either can begin earlier than page offset `0xff8`.
5. **The new kernel next-page block is not CPU-gated.** It runs for format 7
   and format 4. A successful 060 kernel fault in the last eight bytes
   therefore calls `as_fault(next)` once in `krnxmemflt_orig` and again in
   `wb060_xpage`. A high-user 060 fault can likewise call it first through
   `hardbus` and then through `wb060_xpage`.
6. **All three current next-page helpers retain the known negative-boundary
   flaw.** They either accept success from the already-valid near page or
   discard the far-page result. A permanently unmappable far page can still
   cause repeated retries.

## Byte provenance

The linked replacement blocks match their source objects byte-for-byte:

| Linked block | Address | Bytes | `.text` SHA-256 | Result |
|---|---:|---:|---|---|
| `get_fault` | `0xd9064` | 236 | `7d37c58d2b06cb76a95cbff95fe230c7c23d189de61f3ba6e366e2b619d9ce9a` | exact |
| `userspace` | `0xd9150` | 152 | `50d283d35099efb07f2966f0b932ea51ddc5bacdd7df5188f3a56555a18914f7` | exact |
| `wb040.o` wrappers/helpers | `0xd9390` | 616 | `3719e7bc946987b70f8e88ba86df045968b16655197ca84cd25f17ca8583d726` | exact |
| `runtime040.o` | `0xd9d4c` | 484 | `947c8567658cac97f5075cce57c45894c32b53df7f214793dec95f4a9e78f473` | exact |
| `krnxmemflt040.o` | `0xd9f30` | 392 | `100d2ff5517e693a63a40fa37857fe95a8c8f037b23d7cf325cbeb121d48b123` | exact |

The retained `k_trap`, `u_trap`, and `usrxmemflt_orig` provenance is already
established in `040-FAULT-RESOLVER-AUDIT.md`. The current public symbols are:

```text
sf_fault             0x000005f2
k_trap               0x0005a0e8
u_trap               0x0005a47e
usrxmemflt_orig       0x0005aede
hardbus_orig          0x0005b3c2
as_fault              0x000ae108
get_fault             0x000d9064
userspace             0x000d9150
usrxmemflt            0x000d9390
krnxmemflt            0x000d93da
wb060_sswsynth        0x000d941c
wb060_xpage           0x000d9458
wb040_replay          0x000d94a4
Lwb_do                0x000d9560
Lwb_loop              0x000d95a8
Lwb_fail              0x000d95bc
hardbus               0x000d9d62
krnxmemflt_orig       0x000d9f30
```

Useful old-byte anchors in this image:

| Site | Current bytes | Meaning |
|---:|---|---|
| `0xd942c` | `22 2a 00 4c` | read original format-4 FSLW |
| `0xd9452` | `35 40 00 4c` | overwrite FSLW bits 31..16 with synthetic 040 SSW |
| `0xd9474` | `0c 81 00 00 0f f8` | 060 `FA & 0xfff >= 0xff8` gate |
| `0xd9524` | `20 03 ... 0c 80 00 00 00 03` | skip line-sized WB2 |
| `0xd9572` | `23 fc ...` | arm `u+0x374 = Lwb_fail` |
| `0xd95aa` | `0e 1b 18 00` | `moves.b d1,(a3)+` |
| `0xd9d6e` | `0c 80 80 00 00 00` | `hardbus` high-user-VA gate |
| `0xd9d80` | `0c 81 00 00 0f f8` | `hardbus` last-eight gate |
| `0xda066` | `0c 81 00 00 0f f8` | native kernel last-eight gate |
| `0xda092` | `4e b9 00 00 00 00` | native kernel `as_fault(next)` relocation |

## Frame and route contract

### Frame decode

| Field | 040 format 7 | 060 format 4 |
|---|---|---|
| format/vector | frame `+70` | frame `+70` |
| fault address | frame `+84` | frame `+72` |
| status | SSW word at `+76` | FSLW long at `+76` |
| transfer mode | SSW bits 2..0 | FSLW bits 18..16 |
| crossing indicator | SSW MA | FSLW MA, bit 27 |
| restart model | pending writes in WB slots | instruction restart, no 040 WB slots |

`get_fault` selects the correct format-specific FA. `userspace` selects the
address space from transfer mode, not from saved SR and not from the numerical
VA. Thus a supervisor-mode `copyout` instruction can legitimately be a user
transfer.

### Public entry routes

| Entry/site | Condition | Resolver |
|---|---|---|
| `u_trap`, JSR/reloc `0x5a592/0x5a594` | CPU exception from user mode | `usrxmemflt` |
| `k_trap`, JSR/reloc `0x5a1e8/0x5a1ea` | `u_nofault` armed, TM=user | `usrxmemflt` |
| `k_trap`, JSR/reloc `0x5a1fc/0x5a1fe` | `u_nofault` armed, TM=supervisor | `krnxmemflt` |
| `k_trap`, JSR/reloc `0x5a230/0x5a232` | no `u_nofault` | `krnxmemflt`, irrespective of TM |

This produces four important reachability rules:

- `u_trap` does not consume `u_nofault`.
- normal `copyin`/`copyout` MOVES faults use the user resolver;
- guarded kernel-memory probes use the kernel resolver;
- an unguarded kernel MOVES to a user VA is treated as a kernel bug, not as a
  recoverable copy operation.

## Current crossing mechanisms

### 1. High-user `hardbus`

`hardbus @0xd9d62` activates for:

```text
FA >= 0x80000000
(FA & 0xfff) >= 0xff8
```

It calls:

```text
as_fault(p_as, page(FA),      4, F_INVAL, S_READ) @0xd9da8
as_fault(p_as, page(FA)+4096, 4, F_INVAL, S_READ) @0xd9dd0
```

It returns success if either call returns zero. This covers the normal AMIX
high user range, including the known instruction-fetch crossing. It does not
cover a possible low user mapping. It also cannot distinguish "near page was
already valid" from "near page was repaired", so the far-page error can be
masked.

### 2. Native kernel next-page block

After the ordinary `krnxmemflt_orig` `as_fault` returns zero, the block at
`0xda058` tests:

```text
(FA & 0xfff) >= 0xff8
```

and calls:

```text
as_fault(&kas, page(FA)+4096, 4, F_INVAL, S_READ) @0xda092
```

The far return is discarded and the original zero restored at `0xda09c`.
There is no format-7 test. The block therefore executes on both 040 and 060.

The block is enough for the measured ISSUE-37 read at offset `0xfff`, but it
is not an exact MA implementation:

- it can pre-fault a successor for a non-crossing byte access;
- it hardcodes `S_READ`, including for writes;
- it ignores a permanent far-page error;
- it duplicates the 060 wrapper's operation.

### 3. 060 wrapper

`wb060_sswsynth @0xd941c` first reads the original FSLW, synthesizes the
030/040-compatible ATC/RW/TM word, and stores it at frame `+76`.

Because m68k is big-endian, the word store at `0xd9452` replaces FSLW bits
31..16. That destroys at least:

- MA bit 27;
- LK and RW;
- SIZE;
- TT and TM.

The IO bit in the lower half remains in memory, but no current helper reads it
as part of an intact FSLW.

After the original resolver succeeds, `wb060_xpage @0xd9458` checks only:

```text
format == 4
(FA & 0xfff) >= 0xff8
```

and issues the same read/F_INVAL next-page call. It ignores the return.

For a kernel fault, this follows the ungated native block, so the 060 performs
the same next-page call twice.

### 4. 040 write-back replay

`wb040_replay @0xd94a4` is format-7 gated and processes WB1, WB2, and WB3.
For every valid byte, word, or long entry:

1. WB1 data is realigned according to its memory lanes;
2. `Lwb_do` executes `pflusha`;
3. the WB function code is installed in DFC;
4. the outer `u_nofault` value is saved;
5. `u+0x374` is armed with `Lwb_fail`;
6. one, two, or four separate `moves.b` stores are emitted.

If a byte is on the missing far page, its nested format-7 fault reports that
byte's exact address. The nested `k_trap` sees the private pad, selects
`usrxmemflt` or `krnxmemflt` from the byte transfer mode, maps the page, and
retries the one-byte store.

If that nested resolver returns nonzero, `k_trap` replaces the saved PC with
`Lwb_fail`. The helper restores the outer pad, logs, and skips the write-back.
This is an explicit lost-store-over-kernel-panic policy; it is not a claim
that an unmappable write completed.

Line-sized WB2 is deliberately skipped. Motorola and the NetBSD reference
both describe it as MOVE16 residue which must not be replayed as a scalar WB2.
The current AMIX helper does not separately copy PD0..PD3 for a true MOVE16
fault. MOVE16 itself is 16-byte aligned and cannot straddle a 4 KiB boundary,
so this is a general MOVE16 recovery gap rather than an XPAGE gap.

## Coverage matrix

Legend:

- **covered**: the normal mapped-far-page case is resolved and can advance;
- **partial**: common last-eight cases work, but architecture or error
  coverage is incomplete;
- **N/R**: not reachable for that frame/entry combination.

### 68040 format 7

| Trap origin / escape | Access | Resolver path | Crossing mechanism | Verdict |
|---|---|---|---|---|
| `u_trap`, plain | read/instruction, normal high user VA | `usrxmemflt -> hardbus` | `0xd9d62`, current+next | **covered**, with ignored/OR-result nonconvergence caveat |
| `u_trap`, plain | read/instruction, low user VA | `usrxmemflt -> hardbus_orig` | none | **not covered** by the 040 user helper |
| `u_trap`, plain | write | `usrxmemflt`, then replay | `0xd94a4 -> 0xd95aa` | **covered** for scalar WB slots |
| `u_trap`, plain | deferred WB | wrapper replay | private byte-wise replay | **covered** for byte/word/long; line WB2 excluded |
| `u_trap`, `u_nofault` | any | same as plain user entry | `u_trap` never consumes pad | **N/R as an escape** |
| `k_trap`, no pad | kernel read | `krnxmemflt_orig` | native `0xda058` block | **covered** for measured/common last-eight case |
| `k_trap`, no pad | kernel write | native resolver, next-page read, replay | `0xda058`, then `0xd94a4` | **covered** for scalar stores; extra page resolve is read-only |
| `k_trap`, no pad | deferred WB | `krnxmemflt`, then replay | byte-wise replay | **covered** for scalar WB slots |
| `k_trap`, pad, TM=user | copyin/copyout read | `usrxmemflt -> hardbus` | high-user helper | **covered** for normal high user buffers |
| `k_trap`, pad, TM=user | copyin/copyout write/WB | `usrxmemflt`, then replay | byte-wise replay | **covered** for scalar WB slots |
| `k_trap`, pad, TM=supervisor | guarded kernel read | `krnxmemflt_orig` | native `0xda058` block | **covered** for measured/common last-eight case |
| `k_trap`, pad, TM=supervisor | guarded kernel write/WB | kernel resolver, then replay | native block plus byte replay | **covered** for scalar WB slots |

The 040 "covered" read verdict does not remove the known permanent-far-page
retry flaw. It means the legal, mappable far page is requested and ISSUE-37's
measured loop advances.

### 68060 format 4

| Trap origin / escape | Access | Resolver path | Crossing mechanism | Verdict |
|---|---|---|---|---|
| `u_trap`, plain | high-user read | `usrxmemflt -> hardbus`, then `wb060_xpage` | two address-heuristic calls | **partial and duplicated** |
| `u_trap`, plain | low-user read | `usrxmemflt`, then `wb060_xpage` | wrapper address heuristic `0xd9458` | **partial** |
| `u_trap`, plain | write/RMW | synthesized write classification, possible `hardbus`, then restart | read-only heuristic next-page resolve | **partial**; may duplicate and need a second protection fault |
| `u_trap`, plain | deferred WB | none in format 4 restart model | none | **N/R** |
| `u_trap`, `u_nofault` | any | same as plain user entry | pad is not consumed | **N/R as an escape** |
| `k_trap`, no pad | kernel read/write | `krnxmemflt_orig`, then wrapper | native block plus `wb060_xpage` | **partial and duplicated** |
| `k_trap`, pad, TM=user | high-user copyin/copyout | `usrxmemflt -> hardbus`, then `wb060_xpage` | two address-heuristic calls | **partial and duplicated** |
| `k_trap`, pad, TM=user | low-user copyin/copyout | `usrxmemflt`, then `wb060_xpage` | one address-heuristic call | **partial** |
| `k_trap`, pad, TM=supervisor | guarded kernel access | `krnxmemflt_orig`, then wrapper | two address-heuristic calls | **partial and duplicated** |
| any format-4 route | deferred WB | 060 restarts instruction | no 040 WB slots | **N/R** |

The partial verdict applies even when the current last-eight case passes:
original MA is not consulted, starts before `0xff8` can be missed, and the
far result is not propagated.

## Q2: Does byte-wise replay cover a 040 crossing write-back?

**Yes, for valid scalar WB1/WB2/WB3 entries.**

The proof is mechanical:

```text
WB size byte -> 1 x moves.b
WB size word -> 2 x moves.b
WB size long -> 4 x moves.b
```

Every replay byte has an independent memory access and therefore an
independent fault address. No replay operation itself spans the boundary.
`u+0x374 = Lwb_fail` is active around the loop, so a legal missing page is
resolved and the exact byte retried. This remains true if the original
`k_trap` cleared an outer copyin/copyout pad while running the resolver.

Qualification:

- an unresolvable replay target is skipped, not completed;
- line-sized WB2 is not replayed;
- current AMIX does not implement the separate full MOVE16 PD0..PD3 path.

Those qualifications do not recreate ISSUE-37's scalar crossing loop.

## Q3: `u_nofault` and ISSUE-22

### What `k_trap` actually does

The exact armed sequence is:

```text
0x5a19e  test u+0x374
0x5a1b8  save landing pad in d3
0x5a1be  clear u+0x374
0x5a1c8  userspace(frame)
0x5a1e8  user TM -> usrxmemflt
0x5a1fc  supervisor TM -> krnxmemflt
0x5a206  restore u+0x374
0x5a20c  test resolver return
0x5a212  only on nonzero: replace saved PC with landing pad
0x5a21a  on zero: retry the faulting instruction
```

`sf_fault @0x5f2` clears the pad and returns `-1`. Copy helpers turn that
failure into the syscall's EFAULT result.

Thus an armed pad is **resolve first, escape only on failure**, not
"fault means EFAULT".

### Why the proposed equivalence does not hold

The old ISSUE-37 loop had:

```text
as_fault(near page) -> 0
instruction retry  -> same access error
```

With `u_nofault` armed, the same zero reaches `0x5a20c`, does not rewrite the
saved PC, and retries. It does not enter `sf_fault`.

There is a second, independent disproof for the recorded ISSUE-22 copyout
hypothesis:

```text
copyout/uiomove MOVES
  -> supervisor CPU exception, but TM=user
  -> k_trap armed branch
  -> usrxmemflt
```

Today's ISSUE-37 block is inside `krnxmemflt_orig` and uses `&kas`. It is not
on that route. The high-user `hardbus` helper and 040 scalar replay were
already the relevant copyout crossing mechanisms before today's change.

Finally, both new next-page implementations discard their far `as_fault`
result. A far-page failure is therefore not converted into the resolver's
nonzero result which would activate `sf_fault`; it can refault instead.

### ISSUE-22 verdict

**ISSUE-22 is not statically closed by the ISSUE-37 patch.**

The current all-V0 hardware pressure run is useful negative runtime evidence,
but it cannot establish attribution. ISSUE-22 still needs its own latch if it
reappears:

```text
faulting PC and FA
frame format
original SSW/FSLW
TM and selected resolver
u_nofault landing pad
primary as_fault return
next-page as_fault return, if any
```

If the selected resolver returns nonzero, the nofault mechanism can explain
EFAULT. The current static evidence does not show that crossing-page handling
produced that nonzero result.

## Q4: Is an eight-byte window sufficient?

### 68040

The 68040 manual states that SSW MA is set for an ATC fault on the second page
of a transfer spanning two pages, and that FA remains the first byte of a
misaligned transfer. Linux/m68k's 040 handler uses:

```text
if (SSW.MA)
    addr = (addr + 7) & -8
```

That is strong reference support for an eight-byte correction granule for
normal format-7 MA handling. Byte/word/long accesses are also covered by the
scalar replay when they are pending writes.

Specific wider instructions:

- **MOVEM:** format 7 carries CM and the saved effective address so MOVEM can
  continue/restart. The register list is not one indivisible wide WB slot.
- **MOVE16:** the transfer is line-aligned. A 16-byte line cannot cross a
  4096-byte boundary.
- **FPU extended/packed:** the 040 architecture does define 96-bit external
  formats. This makes the source comment "up to an FPU double" incomplete as
  a proof. The 040 bus and WB status expose byte/word/long/line transfers, and
  the established OS correction is still eight bytes, but a final native
  handler should use SSW MA and SIZE rather than rely on the comment.

Verdict: the last-eight heuristic is adequate for the currently proven 040
scalar cases, but MA-aware decode is the durable contract.

### 68060

Eight bytes is **not** a complete 060 contract.

The 68060 manual gives two direct counterclasses:

1. 96-bit operands are valid and are aligned on a 4-byte boundary. An operand
   can start at `page+0xff4` and extend into the next page.
2. For an instruction extension-word fault, FA points to the instruction
   opword, not the extension word which faulted. A sufficiently long
   instruction can therefore start before `page+0xff8` while an extension is
   fetched from the next page.

The FSLW distinguishes both using IO/MA. Linux/m68k does not use a last-eight
gate on 060; when MA is set it rounds FA directly to the next page:

```text
addr = (addr + PAGE_SIZE - 1) & PAGE_MASK
```

Current AMIX loses MA during SSW synthesis and cannot implement that rule
afterward.

## Minimal future closure unit

This task does not patch the kernel, but the static minimum is now clear:

1. Preserve the original format-4 FSLW before `wb060_sswsynth` overwrites its
   upper word.
2. On 060, use original MA to select `round_page(FA)` instead of
   `FA&0xfff >= 0xff8`; retain IO so instruction-extension and operand cases
   remain distinguishable.
3. Pass the original read/write/RMW classification to the far-page resolver
   instead of always using `S_READ`.
4. Propagate a permanent far-page failure through the existing user signal or
   kernel `u_nofault` contract. Do not restore a saved zero unconditionally.
5. Gate the native kernel helper by frame format or centralize the post-fault
   assist so 060 does not resolve the same page twice.
6. For 040, prefer SSW MA plus transfer-size semantics over a raw address
   window; retain byte-wise replay for scalar deferred WBs.

These six belong to one frame-aware resolver unit because changing only the
address threshold leaves original status loss and nofault nonconvergence
intact.

## Secondary: workload for the old NFS `pl[]` defect

The existing tail corpus cannot trigger the predicted list shape because its
raw `io_len` is 123 and the provider returns one page.

The target input is:

```text
server-created unique NFS file
at least one full interior 8192-byte filesystem block
both 4096-byte pages cold on the AMIX client
first fault/read aimed at that full block, not at EOF
pvn_kluster returns circular page list A <-> B
```

With the old `0x8b26c` countdown:

```text
capacity 4096:  A, B, NULL       count 2 > cap 1
capacity 16384: A, B, A, B, NULL
```

There is a detector detail which explains the negative run. `pvn_probe.s`
states two invariants:

```text
count <= ceil(plsz / 4096)
all returned pointers distinct
```

but its branch at `Lpv_viol` implements only the count comparison. Duplicate
pointers are printed only while the six normal samples remain. If boot
consumes those samples, `A,B,A,B` in a 16 KiB caller array has count 4 and
capacity 4, so it produces no line.

Two deterministic options follow.

### Preferred: add duplicate detection

Keep the current wrapper, treat any equal non-NULL pair among `p0..p3` as a
violation, and then:

1. create a uniquely named, patterned file on the NFS server;
2. make it at least 32 KiB and page/block aligned;
3. mmap it without touching EOF or earlier pages;
4. first-touch the first page of an interior full 8 KiB block;
5. run once with the pre-36 body and once with the converted body.

Expected old signature is `A,B,A,B`; expected fixed signature is `A,B`.

### Without changing the probe

Force a multi-page `VOP_GETPAGE` request with `len >= 8192`. Then
`pvn_getpages`' first non-final iteration gives the provider only 4096 bytes
of list capacity. The old provider returns two pointers and the current
`count > cap` branch fires.

A small kernel test shim calling the vnode's `VOP_GETPAGE` on a cold full
block is more deterministic than relying on ordinary sequential `read(2)`,
whose trap-driven faults are commonly one page at a time. `execmap` preread
does not provide a current black-box shortcut because `pgthresh` is zero and
the preread branch is inactive.

## Acceptance recommendations

### XPAGE

1. 040 user and kernel: unaligned read across a resident/missing boundary.
2. 040 scalar WB: byte, word, and long stores across the boundary.
3. 040 negative: readable near page plus unmapped/protected far page must
   terminate with one signal or nofault return, not retry indefinitely.
4. 060 operand: an MA access whose FA is before offset `0xff8`.
5. 060 instruction: a long-form instruction with opword before `0xff8` and a
   cold extension-word page.
6. Guarded MOVES: verify resolver failure reaches `sf_fault`, while a legal
   page-in retries and completes.
7. Instrument counts to prove a 060 kernel fault invokes one far-page resolve,
   not two.

### NFS page list

1. old body must produce either count-over-cap or duplicate-pointer evidence;
2. fixed body must return distinct pages within capacity;
3. holds and releases must balance for every returned page;
4. content checks remain regression coverage, not the list invariant.

## Sources

- Motorola/Freescale, *M68040 User's Manual*, sections 8.4.6.2-8.4.6.5:
  <https://www.nxp.com/docs/en/reference-manual/MC68040UM.pdf>
- Motorola, *M68060 User's Manual*, sections 8.4.4.2-8.4.4.3 and 10.2:
  <https://www.nxp.com/docs/en/data-sheet/MC68060UM.pdf>
- Linux/m68k current access-error reference:
  <https://codebrowser.dev/linux/linux/arch/m68k/kernel/traps.c.html>
- NetBSD m68k write-back reference:
  `netbsd/syssrc.tgz:usr/src/sys/arch/m68k/m68k/m68k_trap.c`
- Current linked sources:
  `kernelsupport/prototypes/getfault040.s`,
  `userspace040.s`, `wb040.s`, `runtime040.s`, and `krnxmemflt040.s`
- Existing local context:
  `040-FAULT-RESOLVER-AUDIT.md`,
  `HARDBUS-XPAGE-RETRY-AUDIT.md`,
  `SEGKMEM-KVSEG-MMREAD-FAULT-AUDIT.md`, and
  `NFS-READSIDE-ISSUE36-SITE.md`

## Confidence

High confidence:

- current image and linked replacement byte provenance;
- all four public resolver call sites;
- nofault save/clear/resolve/restore/escape order;
- exact 040 byte-wise replay behavior;
- the separation between copyout's user-TM route and the new kernel resolver;
- duplicate 060 kernel next-page calls;
- loss of FSLW MA before the current helper;
- the old NFS probe's missing duplicate-trigger branch.

Medium confidence:

- no currently observed 040 extended-FPU xpage failure exists; the current
  heuristic is supported by established 040 handling but should still be
  replaced by explicit MA/SIZE decode;
- the exact shortest AMIX user instruction which exposes the 060
  extension-word hole should be selected when the runtime test is assembled.
