# Task — ISSUE-42: the 68040 write-back replay completes a store into a protected page

**For Codex. Static analysis of the SVR4/68040 contract; no hardware, no emulator, no new kernel.**
Written 2026-08-07, the day `68060-260806-06` was accepted on hardware. Every number below was
measured. The question is a *contract* question — when may a pending write-back be re-issued —
and this project's rule is to read the contract rather than guess at it.

## The situation in one paragraph

The 68040 reports an access error *after* it has already performed part of the access internally,
and hands the kernel up to three pending write-backs in the format-7 frame. `wb040_replay`
re-issues them with `moves`. That machinery exists for good, hardware-proven reasons (ISSUE-7,
ISSUE-22). But nothing in the chain consults protection: a misaligned store that crosses into an
`mprotect(PROT_READ)` page **completes** on the 68040 instead of killing the process. The 68060
has no write-backs and does the right thing. So the replay hands us a protection bypass on one
CPU and not the other, and the fix depends on which of two contracts is the real one.

## What is already measured — do not re-derive these

**M1. The split by CPU is clean.** `protfault` (three cases, one child each, no handler):

```text
real 68060, 68060-260806-06   a PASS   b PASS   c PASS   (SIGSEGV, accepted on hardware 2026-08-07)
emulated 68040, 260806-05/-06 a PASS   b PASS   c FAIL   the protected store SUCCEEDED
```

Case c = two pages, page 2 `mprotect(PROT_READ)`, a misaligned write starting at `page_end - 2`
so it crosses from page 1 into page 2. Case b is the same protection with an *aligned* write
wholly inside page 2 — b passes on both CPUs, so the per-page permission check restored by
ISSUE-41 (`prototypes/segvn_prot040.s`) is present and working. Only the crossing case escapes.

On the 060 the same case c produced `x60_fprot_n=1`, `x60_fprot_ok_n=0`, `x60_fprot_fail_n=0`,
`x60_last_afret=4`, `x60_siginfo_n=1`, `x60_far_addr=0xC1016000`, `x60_last_fa=0xC1015FFE`.

**M2. The replay runs only on the path where the stock resolver said "resolved".**
`prototypes/wb040.s:83-87`:

```text
	jsr	usrxmemflt_orig
	movel	%d0,%d4		| 0 = demand-fault resolved
	tstl	%d4
	bnew	Lu_done		| nonzero -> skip the replay entirely
	moveal	%fp@(8),%a2
	bsrw	wb040_replay
```

This matters for how the question is posed: the replay is **not** currently on a "the fault is
fatal" branch at all. The stock resolver resolved the *near* page and returned 0; a pending
write-back may target the *far* page, which that call never examined.

**M3. The replay itself consults nothing.** `Lwb_do` (`wb040.s:603`): `pflusha`, then
`DFC = WBxS & 7`, then `moves.<size> d1 -> (a3)` for each valid WB. Instrumentation already in
place: `wb_replay_n` counts every replay, `wb_replay_odd` counts those aiming DFC somewhere other
than user data (FC != 1). There is a `u_nofault` landing pad around the loop (`Lwb_fail`) for an
*unresolvable* nested fault, added after a real-hardware panic — but a store that the MMU permits
never reaches it.

**M4. WB1 is emulator-inert.** Per this file's own verified-from-source comment, WinUAE/Amiberry
never set WB1S valid, so the WB1 path only ever runs on real silicon. The bypass observed on the
emulated 040 is therefore WB2 or WB3.

**M5. The 060 never enters this code.** `wb040_replay` (`wb040.s:520`) returns immediately unless
the frame's format is 7, which a 68060 does not produce. Consistent with c passing there.

**M6. Not a regression, and observable only now.** Before ISSUE-41 the kernel panicked before
reaching this state. The bypass was presumably always there.

**M7. There is no real-68040 datapoint.** The machine now has a 68060; ISSUE-42 has been seen on
the *emulated* 040 only. Given M4 — the emulator's write-back behaviour provably differs from real
silicon — "this is partly an emulator artifact" is a live hypothesis, not a dismissal.

## The questions

**Q1 — what does the reference contract say?** Where do the other implementations replay pending
write-backs relative to deciding the fault's outcome, and do any of them check permission first?
NetBSD's `m68040_writeback` and Linux m68k's `do_040writeback` are the two readable
implementations; the SVR4 3b2 source is the contract this port is supposed to follow. Per the
source-first rule: read those, then say what our code does differently.

**Q2 — the headline: check, or discard?** Should the replay consult protection before re-issuing
each write-back, or should pending write-backs be discarded once the access is known to be denied?
Please answer in the sharper form M2 forces: the resolver returned 0 for the near page, and a
write-back targets a far page it never looked at. Is the correct contract *"validate every WBxA
against the address space independently"*, or *"a write-back whose address the resolver did not
resolve must not be replayed at all"*? These differ in cost and in blast radius for ISSUE-7/22.

**Q3 — where is the permission actually lost?** After `mprotect(PROT_READ)` on page 2, what is the
state of the *hardware PTE* on this port — does `mprotect` clear the PTE's write permission, or
does it only change the segment's software protection, the thing ISSUE-41 restored the check for?
This decides which file the fix belongs in:
* PTE still writable ⇒ the `moves` succeeds for *any* privilege, no replay ordering can fix it,
  and the defect is in `mprotect`/hat, not in `wb040.s`;
* PTE correctly read-only ⇒ the store should have faulted, and Q4 becomes the question.

**Q4 — does the function code buy the replay a privilege it should not have?** `Lwb_do` sets
`DFC = WBxS & 7`, and `wb_replay_odd` exists precisely because that is sometimes not user data.
On the 68040, does a `moves` issued under a *supervisor* function code bypass a user page's write
protection, or does the descriptor's write-protect bit apply regardless of privilege? If
supervisor FC bypasses it, the bypass lives in the function code and not in a missing check, and
the fix is again somewhere else entirely.

**Q5 — how would we tell an emulator artifact from a real defect?** There is no 68040 in the
machine any more (M7), and M4 says the emulator's write-back generation is known-different. What
can be settled statically — from the frame layout Amiberry produces versus what a real 040 must
produce — and what would genuinely require silicon? A short answer is enough; I am not asking for
a test plan, only for the boundary between "answerable now" and "needs an 040".

## What is NOT being asked

* **No kernel code, no `.s` file.** The ISP vector-61 unit and ISSUE-41's fix both came from specs
  of exactly this shape and landed cleanly; same division of labour.
* **No hardware work.** The Amiga runs `68060-260806-06`, accepted 2026-08-07 across the full run
  list including a power cut (`REALHW-260806-06-ACCEPTANCE.md`). Do not propose anything that
  disturbs that baseline.
* **Do not propose removing or disabling the replay.** It exists for ISSUE-7 (the init hang) and
  ISSUE-22 (DFC corruption), both closed with hardware evidence. Any answer has to keep those.
* Do not re-open ISSUE-40, ISSUE-41 or the 040 port; all closed.

## Artifacts

```text
kernelsupport/prototypes/wb040.s                  usrxmemflt:65, replay call :87, wb040_replay:520,
                                                  Lwb_do:603, Lwb_fail landing pad
kernelsupport/prototypes/segvn_prot040.s          ISSUE-41's restored per-page check (case b passes)
kernelsupport/test-tools/protfault.c              the three cases; c is the one that fails on 040
kernelsupport/KNOWN-ISSUES.md                     ISSUE-42 entry (line ~3767)
kernelsupport/SIGINFO-TRANSLATION-260806.md       F4, and the "Still open" section that named this
kernelsupport/REALHW-260806-06-ACCEPTANCE.md      what the hardware now guarantees, incl. c on 060
amix-kernel-analysis/vm-map/XPAGE-FPROT-CONTRACT.md   the contract that produced protfault
vanilla stand/unix                                usrxmemflt 0x5aede, u_trap 0x5a586, k_trap 0x5a1ea
```
