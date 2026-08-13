# Task — the protected-far-page fault contract: what does `u_trap` need, and why does `as_fault` lie?

**For Codex. Static analysis of stock SVR4 code; no hardware, no emulator, no new kernel.**
Written 2026-08-06, after three measured hypotheses were refuted in one evening. Every number
below was measured, not deduced; the point of this task is to stop guessing about a contract we
can read.

## The situation in one paragraph

On the 68060 a misaligned access that **crosses a page boundary** reports FA = the access's
*start* address with FSLW MA set, so the kernel must also resolve the *next* page. Our
`wb060_xpage` (`kernelsupport/src/wb040.s`) does that. When the far page is present but
**write-protected**, no formulation we have tried terminates the faulting process: the
instruction restarts forever. The fix is blocked on two contract questions about stock code.

## What is already measured — do not re-derive these

**M1. `as_fault` claims success and changes nothing.** Emulated 060, kernel `68040-260806-04`,
counters read after `xpagetest` T3 (write crossing into an `mprotect(PROT_READ)` page):

```text
x60_fprot_n       32 340    the F_PROT branch fires (ptest classified the page correctly)
x60_fprot_fail_n  32 340    our post-check declared every one of them permanent
x60_fprot_ok_n         0    none was genuinely resolved
x60_last_afret    0x00000000   <- as_fault's own return value: SUCCESS
x60_last_psr2     0x00000800   <- the same page, re-tested after that success: STILL W
```

The call we make is, in the stock convention `as_fault(as, addr, len, type, rw)`:

```text
as   = curproc->p_as      (u+0x730 -> +124, exactly as the pre-existing F_INVAL call does)
addr = round_page(FA + PAGE_SIZE - 1)      the far page base
len  = 4
type = F_PROT (1)
rw   = S_WRITE (2)
```

**M2. Propagating a failure does not terminate the process.** With the post-check above,
`x60_far_fail_n` moved 32 340 times — the wrapper *did* return nonzero out of `usrxmemflt` —
and the live-lock continued.

**M3. `u_trap` selects the signal from an out-parameter we never write.** Vanilla
`stand/unix`, `u_trap+0x108` @ `0x5a586`:

```text
5a586:  moveq #-40,%d0 / addl %fp,%d0 / movel %d0,%sp@-    arg2 = &fp@(-40)
5a590:  movel %d0,%sp@-                                     arg1 = frame
5a592:  jsr usrxmemflt
5a59c:  tstl %d0
5a59e:  beqw 5a64c                     0 -> resolved, return
5a5a2:  moveq #11,%d4 / cmpl %fp@(-40),%d4 -> signal 6
5a5b6:  moveq #10,%d4 / cmpl %fp@(-40),%d4 -> signal 5
5a5d8:  moveq  #8,%d4 / cmpl %fp@(-40),%d4 -> signal 9
5a5ec:                                     -> signal 1
5a5f2:  ... jsr get_fault @ 0x5a5f8, result >> 30 compared against 2 -> branch 0x5a648
```

`k_trap`'s call site is at `0x5a1ea` and takes the same two arguments.

**M4. The 68040 breaks too — so `wb060_xpage` is not the only cause.** `wb060_xpage` is gated on
a format-4 frame, which a 68040 never produces, yet on the emulated 040 `xpagetest` T3 hangs on
one kernel and panics on another:

```text
PANIC: usrxmemflt: no as allocated
Backtrace: a recursive pair repeating for the whole kernel stack:
    8005A1E8 -> 800D9598  and  80011D2 -> 8005A0E8   (x ~90 frames)
```

T1 and T2 pass 3/3 on the same 040 kernel, so this is specific to T3's protected-page case.

## The questions

**Q1 — the fault-code contract.** What are the values `u_trap` compares `*arg2` against (8, 10,
11), where are they defined, and **which one denotes a protection violation on a user address**?
`usrxmemflt` is `t`-local at `0x5aede`; the SVR4 3b2 source contract for the same function is the
place to start, per this project's source-first rule. If the codes are `FC_*` from `<vm/as.h>` /
`<vm/seg.h>`, say so and give the mapping to the signals 1/5/6/9 that `u_trap` picks.

**Q2 — is writing `*arg2` sufficient?** `get_fault` runs at `0x5a5f8` *after* the comparisons and
its result's top two bits are tested against 2. Does the termination path depend on `get_fault`
agreeing with `*arg2`, and if so, what does `get_fault` read — the frame, `u.u_code`, something
we would also have to set?

**Q3 — why does `as_fault(F_PROT, S_WRITE)` return 0 on an `mprotect`-ed page?** This is the
core question. Candidates, none of which I want to assume:
   * the call is malformed (is `len = 4` legal? must `addr` be page-aligned? is `rw` correct?);
   * `segvn_fault` on this port checks `svd->prot` and returns success for a *no-op* rather than
     `FC_PROT`;
   * `F_PROT` is only meaningful when the segment permits the access and the PTE does not (i.e.
     COW), and an `mprotect`-denied write is simply **not** an `as_fault` question at all — in
     which case the correct kernel behaviour is to signal directly without calling `as_fault`.
   If the third is right, say so plainly: it changes the fix from "ask a better question" to
   "do not ask, just terminate", and that is a much smaller change.

**Q4 — the 040 panic.** `usrxmemflt: no as allocated` means `p_as == NULL` at fault time. Which
code path can reach `usrxmemflt` with no address space during signal delivery or process
teardown, and is the recursive backtrace (`8005A1E8 <-> 800D9598`) a fault-inside-fault loop?
Identify those two addresses. This may well be a **pre-existing** stock defect rather than
anything of ours — the 040 executes none of the 060 code — and knowing that is worth as much as
a fix.

**Q5 — how should the test be built?** `test-tools/xpagetest.c` T3 currently wedges or panics
both CPUs, so it cannot be used to judge a kernel. What is the minimal, *safe* way to exercise a
protected far page — e.g. from a forked child with an alarm, so a live-lock costs one child and
not the machine? A short spec is enough; I will write the code.

## What is NOT being asked

* No kernel code, no `.s` file. The previous unit (ISP vector 61) came from a spec of exactly
  this shape and landed cleanly; same division of labour.
* No hardware. The Amiga runs `68060-260806-02` (F2, fully accepted) and must not be given
  `68040-260806-04`, which is emulator-only.
* Do not re-open ISSUE-40 or the 040 port; both are closed.

## Artifacts

```text
kernelsupport/XPAGE-FPROT-FINDING-260806.md   the finding + all three refutations, in order
kernelsupport/src/wb040.s              wb060_xpage, Lwx_callp, Lwx_prot (commit 0b359ab)
kernelsupport/test-tools/xpagetest.c          the test, T3 is the unsafe one
kernelsupport/REALHW-F2-ACCEPTANCE-260806.md  what the hardware currently guarantees
vanilla stand/unix                            u_trap 0x5a586, k_trap 0x5a1ea, usrxmemflt 0x5aede
amix-kernel-analysis/vm-map/M68060-XPAGE-ACCEPTANCE.md   its test 3 needs splitting: the
                                              protected case is a defect, the unmapped case
                                              is still untested
```
