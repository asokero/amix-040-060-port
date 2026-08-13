# Follow-up questions for Codex — implementing the ISSUE-40 fix

Your `AVAILRMEM-ACCOUNTING-AUDIT.md` (d27a303) is confirmed on hardware. The pre-registered
counter signature came out exactly as predicted:

```text
300 x fork        availrmem   +8   availsmem  +123   pages_pp_kernel   -8    sum 0
300 x fork+exec   availrmem -319   availsmem  -319   pages_pp_kernel +319    sum 0
300 x fork+exec   availrmem -308   availsmem  -308   pages_pp_kernel +308    sum 0
300 x fork        availrmem   -8   availsmem    -8   pages_pp_kernel   +8    sum 0
```

`availrmem + pages_pp_kernel` conserved in every phase, fork control flat. Your point that
`freemem` recovery does not refute a physical leak was correct and corrected us: a real page is
retained, so a naked credit is off the table. `pages_pp_kernel` runtime address `0x080EFAB0` was
recomputed independently before use and matched yours.

What follows is only what the **implementation** needs. Nothing here asks you to design the patch
— we write the `.s` — but these five decide whether it is correct or merely plausible.

## Blocking

**Q1 — Where in the teardown does the edge belong, and what must still be alive?**
Stock `hat_free` calls `hat_growsdt(hatp, section, 0)` (`vm/vm_hat.c:356`). Our `hat_free040`
(`0x000d82bc`) does a native 040 A/B/C walk and ends with `kmem_free(root, 0x1000)` at
`0x000d858a..0x000d85a2`. Which state does `hat_growsdt(..., 0)` read, and does our walk destroy
any of it before the point where we would insert the call? If the answer is "insert before the
A/B/C walk", say so explicitly — the ordering is the whole risk here.

**Q2 — Which sections, and is `hat_growsdt(..., 0)` callable at all in the port's state?**
You name section 3 (130 entries, the libc mapping at `UVSHM`). Is the correct edge a single
`hat_growsdt(hatp, 3, 0)`, or a loop over every section carrying a legacy SDT? And does
`hat_growsdt` in this binary touch any structure the 040 port has retired — i.e. is calling it
safe, or must we call `hat_sdtfree(base, n)` directly?

**Q3 — If direct `hat_sdtfree` is the safer route, where are `base` and `n` recoverable from?**
Name the field and offset in the `hat`/`as` structure that holds the legacy SDT pointer and its
unit count in **this image**, since we work from the binary rather than source. If the count is
not stored and must be recomputed from the section's entry count, give that arithmetic.

## Useful, not blocking

**Q4 — Ordering against copyback.** With `hat_cm_ram = 0x20`, does the credit path need any
`cpusha`/`cinva` or ATC flush relative to the A/B/C teardown, or is the existing teardown's
flushing sufficient? We would rather not add a whole-cache op on a per-exit path without reason.

**Q5 — Scope confirmation.** We intend this unit to fix **only** the legacy-SDT lifetime, leaving
(a) the `ptdat` metadata leak in `hat_ptfree` and (b) the `USIZE = 4`-as-4-KiB-page-count question
to separate units, per your note that the global `USIZE` must not be changed to 2. Confirm that
fixing the SDT lifetime alone cannot change `ptdat` behaviour in a way that needs them landed
together.

## Not needed

Your exact allocation-site probe (`n`, returned PFN, net debits at `0xb6464`) is **not** a
precondition — the acceptance criterion is behavioural and already measured. It stays on the shelf
as the diagnostic if the fix does not fully flatten the counters.
