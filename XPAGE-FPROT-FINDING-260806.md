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
