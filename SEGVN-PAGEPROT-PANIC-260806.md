# Finding — per-page `mprotect` + a denied write panics the kernel, on both CPUs

**2026-08-06, emulated 68040, kernel `68040-260806-02` — the image accepted on hardware today.**
Predicted statically by Codex (`amix-kernel-analysis/vm-map/XPAGE-FPROT-CONTRACT.md`, 0a3aab3),
confirmed by `test-tools/protfault.c` on the first run.

## The measurement

Three cases, each in its own child, on the **68040**:

```text
A  one page, whole mapping mprotect(PROT_READ), aligned write     PASS -- child died of SIGSEGV
B  two pages, ONLY page 2 protected, aligned write inside page 2  PANIC
C  same as B but a crossing write                                 not run (machine already down)
```

Case B's panic:

```text
PANIC: KERNEL FAULT psw=0x2000, pc=0x80AE1D4, fmt=0x7, vector=0x2 (Bus Error)
Backtrace: 80011D2 -> 8005A0E8   (ktraps -> k_trap)
           8005A1E8 -> 800D9598  (k_trap -> usrxmemflt)
           ... the pair repeating for the entire kernel stack, ~90 frames
```

`0x80AE1D4` is `as_fault+0xcc`. Vector 2 with a full stack of one repeating pair is a
fault-inside-fault recursion that ran the kernel stack out.

## Why this is not an XPAGE problem

Every mitigating explanation is excluded by the case itself:

* **Case B contains no page crossing.** The store is aligned and lies wholly inside page 2.
* **It ran on a 68040**, which never produces a format-4 frame, so `wb060_xpage` — the helper
  this whole investigation started from — cannot execute a single instruction.
* **The kernel is `68040-260806-02`**, the image accepted on real hardware this morning. It does
  not contain the `Lwx_callp`/`Lwx_prot` work at all.
* **Case A passes on the same kernel, in the same run**, so protection faults per se are handled.

The only difference between A and B is `svd->pageprot`: A protects a whole segment, B protects
one page of two.

## The mechanism, read from the linked kernel

`segvn_fault@0xac46a` handles the segment-wide case correctly:

```text
ac46a: tstb %a3@(2)          svd->pageprot == 0 ?
ac474: cmpl %fp@(20),%d3     type == F_PROT (1)
ac47e: cmpl %fp@(24),%d3     rw   == S_WRITE (2)
ac486: moveb %a3@(3),%d0 / andib #3 / cmpib #1   svd->prot == PROT_READ
ac496: moveq #4,%d0          -> FC_PROT
```

`segvn_faultpage@0xac01a` — the per-page path — does not:

```text
ac042: tstb %a4@(2)          svd->pageprot ?
ac04a: dispatch on rw
ac06a: bfextu %a1@,0,4,%d2   load vpage->vp_prot
ac070: braw ac07a            -> straight into the fault body
```

There is no `protchk`, no `prot & protchk` test, and no `FC_PROT` return between loading
`vp_prot` and entering the body. Every SVR4 reference performs exactly that rejection here
(3B2 `seg_vn.c:1074-1095`; USL SVR4.2 `seg_vn.c:1169-1190`). So the denied write enters the
COW/revalidation body, the mapping is reloaded **read-only**, and `as_fault` returns 0 — which
is precisely the pair of numbers measured on the 060 earlier today
(`x60_last_afret` = 0, `x60_last_psr2` = 0x800). The instruction restarts, faults again, and
on the 040 the retry recurses until the kernel stack is gone.

Codex reports the first `0x60` bytes of this function are byte-identical between our image and
vanilla `stand/unix`, i.e. **this is a stock AMIX omission, not something the 040/060 port
introduced.**

## What this changes

* `XPAGE-FPROT-FINDING-260806.md`'s framing was wrong twice over: the hardcoded `F_INVAL` was
  a real defect but not the cause of the hang, and the problem is neither 060-specific nor
  crossing-specific. This document supersedes its causal claim; the counters and the
  measurements in it stand.
* The fix is generic VM work — restore the `segvn_faultpage` permission check — plus, separately,
  the user-path `faultcode_t -> k_siginfo_t` translation the 060 far-page helper still needs
  (`u_trap` selects its signal from `usrxmemflt`'s `k_siginfo_t` out-parameter, and `trapsig`
  queues nothing while `si_signo == 0`; that is why returning nonzero alone never signalled).
* **Any AMIX program that `mprotect`s part of a mapping read-only and then writes it takes the
  kernel down.** That is a much larger statement than the XPAGE finding it came from, and it is
  worth checking whether anything in the installed system does this — X11, the linker's GOT
  handling and `malloc` guard pages are the obvious candidates.

## Instrument note

`test-tools/protfault.c` replaces `xpagetest`'s T3, which conflated all three cases and could
not distinguish them. Each case is a fresh child with no handler and no `setjmp`: the child is
meant to die, and the manner of its death is the result. A parent deadline classifies a retry
loop; it cannot contain a panic, so the host timeout on the emulator remains mandatory. The
first run proved the point of the split immediately — A and B differ, and only B is a defect.

**T3 in `xpagetest` should not be used again.** Use `protfault` a/b/c.

## Artifacts

```text
test-tools/protfault.c                             the split test
amix-kernel-analysis/vm-map/XPAGE-FPROT-CONTRACT.md   Codex's static contract analysis (0a3aab3)
kernel 68040-260806-02                             the accepted image that panics
```
