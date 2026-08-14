# User-code cache-publication ABI specification

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/USER-CODE-CACHE-ABI-SPEC.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** `src/codepub040.s` implements this ABI
> and ships enabled. A decisive real-68040 same-boot A/B showed stale generated
> code with publication disabled and correct execution with it enabled; the
> enabled path also passed the full regression load. See
> `docs/USER-CODE-PUBLISH-260801.md` and
> `docs/REALHW-ACCEPTANCE-260801.md`.

## Scope

This note defines the general publication boundary needed when user space
writes bytes that it later executes under 68040/68060 copyback caching. It
builds on `USER-EXECUTABLE-CACHE-PUBLICATION-CENSUS.md` and is separate from
the debugger-specific kernel writers.

The specification itself changes no kernel code.

## Pinned input

```text
kernel repository HEAD       df32af8
build/unix-040 build id      68040-260731-02
build/unix-040 SHA-256       572d8a0b58215d11bbed96dafb8b6aa56091486bd09faa4b9fc4e6ea6feffeca
mprotect                     0x58550, syscall 116
as_setprot                   0xae2ea
segvn_setprot                0xac9aa
hat_chgprot                  0xd8670
```

## Decision

Define the following AMIX port ABI:

> A successful `mprotect(addr, len, prot)` call with `PROT_EXEC` set is a
> user-code cache-publication barrier for all CPU stores completed before the
> call, even if the mapping already had exactly the requested protection.

Implement the rule with a strong `mprotect` wrapper around the retained stock
body. After the original syscall succeeds and the requested protection
contains `PROT_EXEC`, execute `cpusha bc` (`0xf4f8`) before returning.

This is the smallest usable ABI:

- it consumes no new syscall number;
- it uses an existing, natural write-to-execute boundary;
- it also supports legacy RWX mappings by allowing a same-protection
  `mprotect(..., PROT_READ|PROT_WRITE|PROT_EXEC)` publication call;
- it covers local user stores and kernel `copyout`/`read(2)` writes alike;
- whole-cache publication avoids user-VA translation and alias ambiguity.

## Why the current kernel is only partially sufficient

The live chain is:

```text
mprotect 0x58550
  -> as_setprot 0xae2ea
  -> segvn_setprot 0xac9aa
  -> hat_chgprot 0xd8670
  -> cpusha bc; pflusha at 0xd8818
```

For a real protection change, such as RW to RX, `segvn_setprot` reaches
`hat_chgprot`, whose current publication tail happens to push dirty user data
as well as page-table lines. That makes ordinary W-to-X publication work
today.

It is not a stable ABI, for two reasons:

1. `segvn_setprot` compares the requested protection with the current segment
   protection at `0xaca62`; an equal value returns success at `0xacbe4`
   without calling HAT. A legacy RWX generator therefore cannot force
   publication by repeating its current protection.
2. The HAT operation is documented as page-table coherency, not user-code
   publication. A later range optimization could correctly narrow the PTE
   flush and accidentally remove this incidental behavior.

The syscall wrapper makes publication explicit and independent of segment
implementation or whether protection bits changed.

## Wrapper ABI

The kernel's syscall function receives one pointer to the argument block, not
three direct C arguments. The current body reads:

```text
args+0  addr
args+4  len
args+8  prot
```

Implementation shape:

```asm
        .text
        .globl  mprotect
mprotect:
        linkw   %fp,&0
        movel   %fp@(8),%sp@-       | syscall argument block
        jsr     mprotect_orig
        addqw   &4,%sp
        tstl    %d0
        bnew    Lmp_out             | preserve every original error
        moveal  %fp@(8),%a0
        btst    &2,%a0@(11)         | PROT_EXEC == 0x4 in big-endian prot long
        beqw    Lmp_out
        .word   0xf4f8              | cpusha bc
        addql   &1,codepub_mprotect
Lmp_out:
        moveal  %d0,%a0
        unlk    %fp
        rts
```

Using `movel args@(8),d1; andil #4,d1` is clearer and less endian-sensitive
than the illustrative byte `btst`; either is valid if its assembled bytes are
asserted.

Relink mechanism:

```text
--add-symbol mprotect_orig=.text:0x58550,global,function
--weaken-symbol mprotect
link strong wrapper mprotect
```

The wrapper should contain an aligned counter and, during acceptance only, an
enabled-by-default A/B long. The production rule should not remain silently
optional.

## Publication semantics

`cpusha bc` is deliberately stronger than a D-cache push:

1. dirty copyback D-cache lines are written to RAM;
2. stale instruction-cache lines are invalidated before the syscall returns;
3. physical aliases and cross-process history do not need to be enumerated;
4. the operation cannot fault while walking a partly resident user range.

`cinva ic` alone is insufficient because the newest instruction bytes may
still exist only in dirty D-cache lines. `cinva dc` is forbidden because it
can discard those bytes. A context switch alone is also insufficient: the
current `resume040` invalidates I-cache but does not force the generating
process's dirty D lines to RAM before an immediate same-process branch.

## User contract

Preferred W-to-X sequence:

```c
/* page-aligned code range */
mprotect(code, length, PROT_READ | PROT_WRITE);
/* generate or copy instruction bytes */
mprotect(code, length, PROT_READ | PROT_EXEC);  /* publication barrier */
call_generated_code();
```

Legacy RWX sequence:

```c
/* mapping is already PROC_DATA / RWX */
/* generate or read instruction bytes */
mprotect(code, length, PROT_READ | PROT_WRITE | PROT_EXEC);
/* the same-protection success is still a publication barrier */
call_generated_code();
```

The port's libc or a small compatibility library should expose a helper such
as:

```c
int amix_code_publish(void *page_aligned_addr, size_t page_rounded_len,
                      int desired_prot)
{
        return mprotect(page_aligned_addr, page_rounded_len,
                        desired_prot | PROT_EXEC);
}
```

The caller supplies the desired final protection because AMIX exposes no
portable query for the current value. New code should prefer RX after
generation; the RWX form exists for old runtime linkers and generators.

## Alignment boundary

The current public `mprotect` front end still validates address alignment with
the historical `0x7ff` mask at `0x58572`, while `as_setprot` normalizes ranges
to 4 KiB. That is a separate Model-B public-ABI residual.

The publication wrapper remains correct for every range the original syscall
accepts because `cpusha bc` is global and does not use the supplied geometry.
User-facing helper code should nevertheless require 4-KiB alignment and
rounding. Do not combine a public mprotect alignment behavior change with the
cache-publication patch; they need separate compatibility tests.

## Relationship to known producers

| Producer | Owner |
|---|---|
| proc-1 bootstrap icode | existing `cb_icode040.s`; no user call possible |
| ptrace POKETEXT/POKEDATA | `DBG-TEXT-PUBLISH` wrapper unit |
| `/proc/<pid>` writes | `DBG-TEXT-PUBLISH` wrapper unit |
| runtime linker text relocation | runtime linker calls publication ABI after relocation batch |
| JIT/self-modifying local stores | generating process calls publication ABI before branch |
| `read(2)` into an executable buffer | receiving process calls publication ABI after read |

The kernel must not flush after every `copyout`. Publication belongs at an
explicit executable transition, not at ordinary data delivery.

## Acceptance program

Use one page recycled from prior activity so stale cache contents are
possible. Place a tiny m68k function in it, for example `moveq #N,d0; rts`,
and exercise both producers:

1. **Local store:** write function A, publish, call and verify A; execute it
   repeatedly to populate I-cache; overwrite with function B, call without
   publication in the A/B image, then publish and require B.
2. **Kernel copyout:** read function C from a file into the same page, publish,
   call and verify C.
3. **Same-protection path:** keep the mapping RWX and prove the wrapper counter
   advances even though `segvn_setprot` would short-circuit.
4. **W-to-X path:** use RW then RX and verify execution plus final write
   protection.
5. **Error path:** invalid address/range must retain the original errno and
   must not increment the publication counter.
6. Run on real 68040 copyback, emulated 040 and 060, and later real 68060.

The decisive A/B is one boot with publication disabled versus enabled while
all page mappings and generated bytes are identical. Functional success only
after the enabled barrier proves cache ownership rather than accidental
context-switch invalidation.

## Future range optimization

Whole-cache publication is acceptable for infrequent code generation and
linking. If measurements justify a range operation later, preserve this ABI
and change only its implementation:

- walk each resident target page through `uvatopte040`;
- derive physical addresses from PTE bits 31:12;
- align to 16-byte lines;
- push dirty D lines and invalidate matching I lines;
- handle aliases and page changes without faulting while the walk is active.

A skipped nonresident page is valid only if no CPU store could have dirtied
it. Any translation failure after a successful user write must fail the
publication call rather than silently return success. These complexities are
why the first implementation should remain `cpusha bc`.

## Confidence

High confidence in the current mprotect/HAT control flow, the same-protection
short circuit, and the whole-cache ABI. Medium confidence in real-68060
acceptance until that hardware milestone exists.
