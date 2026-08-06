# Finding — `wb060_xpage` cannot resolve a PROTECTED far page: F_INVAL is hardcoded

**2026-08-06, emulated 68060, kernel `68040-260805-01` (banner `68060-260805-01`).**
Found by `test-tools/xpagetest.c`, written the same evening to exercise the one XPAGE path a boot
never reaches. This is the finding the F1 counters existed to make visible.

## What happened

`xpagetest` T3: two `/dev/zero` pages, both present, the **far** one turned read-only with
`mprotect`, then a misaligned long **write** starting at `page_end - 2` so the transfer spans into
the protected page.

```text
T1 write crossing at c1033ffe (far page absent)     PASS
T2 read  crossing at c1036ffe (far page absent)     PASS
T3 write crossing at c1039ffe into a PROTECTED far page
    (expect SIGSEGV/SIGBUS -- a HANG here is the failure this test looks for)
    ... never returned
```

Counters, sampled twice ten seconds apart afterwards (identical, so the loop had already ended):

```text
                 before      after
x60_fmt4_n         10669     408476      (+397 807)
x60_ma_n              14     397230      (+397 216)
x60_rw_write_n         0     397213      (+397 213)
x60_far_fail_n         0          0      (+0)          <-- the whole finding
x60_compat_n           4          4      (+0)
x60_last_fslw          -   0x08810200    MA set (bit 27), RW field 01 = write
```

So: the MA tier fired, classified the access as a write correctly, and resolved the far page
**successfully — 397 213 times in a row.** `x60_far_fail_n` never moved. The instruction restarted
after every one of them and faulted again. A textbook retry loop, and precisely the failure mode
the XPAGE unit was written to remove for *unmappable* far pages.

## Mechanism

`prototypes/wb040.s`, `Lwx_call` — the far-page resolve both tiers share:

```
Lwx_call:
	movel	%d1,%sp@-		| rw
	clrl	%sp@-			| type = F_INVAL      <-- hardcoded
	pea	4			| len
	movel	%d0,%sp@-		| addr = the far page
	movel	%a1,%sp@-		| as
	jsr	as_fault
```

`F_INVAL` means *"this page is not present"*. For a far page that **is** present but
write-protected, that is the wrong question: `as_fault` finds the page mapped, has nothing to
demand-fault, and returns 0 without ever consulting the protection. The near page was already fine,
so the wrapper sees success on both halves and returns 0 — and the 68060 restarts the instruction
into the same protection violation.

The correct question for that case is `F_PROT`, which is what the *near*-page path already asks:
`usrxmemflt` chooses between demand and protection handling from `ptest`'s 030-form PSR
(`ptest040.s` returns 0x400 = invalid, 0x800 = write-protected). The far page gets no such
classification — it is assumed absent.

## Why this was invisible until now

* A boot produces only **read** crossings into **absent** pages, where `F_INVAL` is exactly right.
  The emulator's own boot showed `x60_ma_n = 11`, all reads (`060-COUNTERS-UNIT-SPEC-260805.md`).
* Without `x60_far_fail_n` a hang here would have looked like "the machine wedged" with no way to
  tell a failed resolve from a *successful* one that changed nothing. The counter is what separates
  those two, and it read **zero** — which is the informative part.

## This contradicts a pre-registered acceptance reading

`M68060-XPAGE-ACCEPTANCE.md`, remaining test 3, expects:

> A protected or unmapped far page after a valid near page must terminate through the normal
> signal/nofault path — `x60_far_fail_n` > 0, no retry loop.

**On the protected variant, today's kernel does neither.** The unmapped variant is untested and may
well behave (there `F_INVAL` is the right type and a genuinely unmappable page should return an
error). So the acceptance document's test 3 needs splitting into two cases, and the protected case
is currently a known defect rather than an open question.

## Is this an emulator artefact?

No, and the reason matters. Amiberry's role here was only to produce a format-4 frame with MA set
for a write — which it did, verified in `x60_last_fslw`. Everything after that is our own kernel
code: `F_INVAL` is hardcoded in our source, and `as_fault` is stock SVR4. Nothing in the chain is
CPU-dependent once the frame is decoded. Campaign rule 4 says the emulator cannot be trusted for
MA *fidelity*; it says nothing against trusting it for what our own C-level logic does afterwards.

The honest caveat is the opposite one: **hardware has not yet run this test**, and it must not run
T3 until this is fixed — a live-lock burning a CPU is a poor use of a hardware session, and it
would need a power cycle to be sure of the state.

## Proposed fix (spec, not yet code)

Classify the far page before resolving it, exactly as the near-page path does:

1. Call `ptest` on the rounded-up far address (it already works on the 060 — `ptest040.s` walks the
   URP in software when `cputype == 60`).
2. PSR bit 10 set (invalid) → `F_INVAL`, as today.
3. PSR bit 11 set (write-protected) **and** `rw == S_WRITE` → `F_PROT`, so `as_fault` runs the
   protection path (COW or a genuine failure).
4. Propagate the result in the MA tier as it already does — with a real `F_PROT` failure,
   `x60_far_fail_n` finally moves and the signal path terminates the process.

Open questions I do not want to answer by assumption:

* Does the stock `as_fault`/`segvn_fault` contract on this port accept `F_PROT` for a page that is
  present-and-protected in the same way the near path relies on? The near path reaches it through
  the stock classifier, not through us.
* `ptest` costs a software table walk on the 060. On the MA tier that is once per crossing fault,
  which is rare — but it should be measured, not waved through.
* Should the compat tier get the same treatment? It discards its result deliberately, so a wrong
  type there is harmless today; changing it would change shipped behaviour and needs its own case.

## Artifacts

```text
test-tools/xpagetest.c          the test (T1/T2 pass, T3 is the finding)
prototypes/wb040.s              Lwx_call, the hardcoded F_INVAL
060-COUNTERS-UNIT-SPEC-260805.md  the counters that made this measurable
```

---

# Update, same evening: F_PROT was necessary but not sufficient — and the missing piece is named

Two kernels were built and measured on the emulated 060 after the fix above was written.
Both refuted a hypothesis, and the second one produced the diagnosis.

## Attempt 1 — classify the far page (`68040-260806-03`)

`Lwx_callp` runs `ptest` on the rounded-up far address and asks `as_fault` for `F_PROT` when
the page is resident, write-protected, and the access is a write. T1 and T2 were unaffected
(`x60_fprot_n` +0, as expected: their far pages are *absent*). **T3 still live-locked**, and
the new counter said exactly where:

```text
x60_fprot_n     590 422     the F_PROT branch DOES fire -- ptest classified it correctly
x60_rw_write_n  590 424     i.e. on essentially every iteration
x60_far_fail_n        0     ...and as_fault still returns success
x60_compat_n          5     (+0)
```

So the classification was right and the resolve was still a no-op. **Refuted: "the wrong
fault type is the whole problem."**

## Attempt 2 — verify the resolve, then declare it permanent (`68040-260806-04`)

`Lwx_prot` now re-runs `ptest` after `as_fault` and treats "still write-protected" as a
permanent failure, which the MA tier propagates. Two new counters record what each side
claimed. On the emulated 060, T3:

```text
x60_fprot_n       32 340     branch taken
x60_fprot_fail_n  32 340     every single one declared permanent
x60_fprot_ok_n         0     none genuinely resolved
x60_far_fail_n    32 340     and PROPAGATED to the wrapper (it was 0 before)
x60_last_afret    0x00000000  <- as_fault's own answer: "success"
x60_last_psr2     0x00000800  <- the page, after that success: STILL write-protected
```

Those last two numbers are the finding in its final form: **`as_fault(as, page, 4, F_PROT,
S_WRITE)` returns 0 on an `mprotect`-ed read-only page without making it writable.** That is
measured, on both attempts, and it is why no amount of retrying could ever have worked.

**T3 still live-locked** — which refutes the second hypothesis too: propagating a permanent
failure out of `wb060_xpage` is not enough on its own.

## Why propagation alone does not terminate the process

`u_trap`'s call site in the stock kernel (vanilla `stand/unix`, `0x5a586`):

```text
5a586:  moveq #-40,%d0 / addl %fp,%d0 / movel %d0,%sp@-   arg2 = &fp@(-40)
5a590:  movel %d0,%sp@-                                    arg1 = frame
5a592:  jsr usrxmemflt
5a59c:  tstl %d0
5a59e:  beqw 5a64c                    0 -> resolved, return
5a5a2:  moveq #11,%d4 / cmpl %fp@(-40),%d4 ...  -> signal 6
5a5b6:  moveq #10,%d4 / cmpl %fp@(-40),%d4 ...  -> signal 5
5a5d8:  moveq  #8,%d4 / cmpl %fp@(-40),%d4 ...  -> signal 9
5a5ec:                                          -> signal 1
```

`usrxmemflt`'s second argument is an **out-parameter**: a nonzero return says "not resolved",
and `*arg2` says *which* fault, which is what selects the signal. Our wrapper returns nonzero
but never writes that code — it still holds whatever the *successful* `usrxmemflt_orig` call
left there. So the termination path is entered with a fault code we did not set.

This is a read of the call site, not a deduction from behaviour: the disassembly above is the
evidence. What is **not** yet established is which value belongs in `*arg2` for this case
(the constants 8/10/11 have not been traced to their definitions), and whether writing it is
sufficient or `get_fault` at `0x5a5f8` also has to agree.

## State of the code

`prototypes/wb040.s` now contains the classification, the verification, and five counters
(`x60_fprot_n`, `x60_fprot_ok_n`, `x60_fprot_fail_n`, `x60_last_afret`, `x60_last_psr2`).
It does **not** fix T3. It is landed anyway, deliberately, for three reasons:

* it makes the defect diagnosable instead of a wedge — `far_fail_n` and `fprot_fail_n` now
  move, and `last_afret`/`last_psr2` name the cause in two words;
* the read path and the compat tier are byte-for-byte unchanged, and T1/T2 still pass with
  `x60_fprot_n` +0;
* the legitimate COW case is handled correctly by construction (`fprot_ok_n` separates it),
  so nothing that used to work has been made worse.

**T3 must still not be run on hardware.** The live-lock is unchanged in effect.

## Next step, stated as a question rather than a plan

The remaining work is a contract question about stock code, not about ours: *what fault code
does `u_trap` expect in `*arg2` for a protection violation, and does `get_fault` need to
agree?* That is a source/binary reading task — exactly the kind that belongs in an
`amix-kernel-analysis` audit rather than in another build-and-measure round.

## And a third refutation: T3 breaks the 68040 too

Running the same test on the **emulated 68040** — which never enters `wb060_xpage` at all, because
that helper is gated on a format-4 frame — produced:

```text
F2 kernel (68040-260806-02, no fix):   T1 PASS, T2 PASS, "T3 write crossing at c1039ffe", then hung
F4 kernel (68040-260806-04, with fix): T1 PASS, then PANIC "usrxmemflt: no as allocated"
                                       with a recursive kernel backtrace (8005A1E8->800D9598 x N)
```

Since the 040 cannot execute a single instruction of the code this finding is about, **T3 is not a
purely 060 problem, and `wb060_xpage` is not its only cause.** That refutes the framing of the
original finding above, which attributed the whole behaviour to the hardcoded `F_INVAL`.

The two 040 runs also differ from each other, and the difference is not yet separable from the
test's own instrumentation: `xpagetest` only `fflush`es *after* printing the T3 banner, so the F2
run reached that flush and the F4 run did not. That places the F4 panic somewhere in T3's setup
(`mmap` / `mprotect` / `signal` / `setjmp`) rather than in the crossing write — but it is one run
per kernel, and this project's own rule is that a one-boot bisect does not count
(`amix-260731-units-and-acceptance`). The F4 kernel's T1+T2 were then run **three times in a row on
the 040 and passed 3/3**, so whatever the panic was, it is not a deterministic regression in the
paths T1 and T2 exercise.

**Conclusion for now: `xpagetest` T3 is not a trustworthy instrument.** It wedges or panics the
machine on both CPUs, by at least two different mechanisms, and until it is rewritten to fail
cleanly it cannot be used to judge a kernel. T1 and T2 remain sound and are what the hardware
acceptance rests on.

## What is landed, and what it is worth

`prototypes/wb040.s` keeps the classification, the verification and the five counters. Verified:

* emulated 060 — T1/T2 PASS, `x60_fprot_n` +0 on those (their far pages are absent, so the new
  branch is correctly not taken), and T3 now reports its own diagnosis instead of wedging silently;
* emulated 040 — boots, T1/T2 PASS 3/3, `cputype` 0x28.

Not verified, and explicitly not claimed:

* that it fixes T3 — it does not, measured twice;
* that the 040 T3 panic is unrelated to it — one run each, unseparated from the test's own fault;
* anything at all on hardware. **This kernel has not been booted on the Amiga and should not be
  until T3 is a clean instrument and the `u_trap` fault-code contract is known.**
