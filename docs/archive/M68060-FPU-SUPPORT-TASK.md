# TASK for Codex: 68060 FP/integer support — five questions before we buy into 060SP

Requested deliverable: an analysis note in `amix-kernel-analysis/vm-map/`, suggested name
`M68060-SUPPORT-LANDSCAPE.md`. **Do not patch the kernel.** All five questions are answerable
statically, from the binary plus reference material — none needs hardware or emulator time.
Implementation is deferred until after the pending hardware session regardless of the answers.

## Provenance

```text
kernel HEAD      1771890 (this brief)         analysed image: build/unix-040
build/unix-040   68040-260726-01
                 sha256 767ea9a0b904752701f3d49d8df9bba55fe46bbadbc70da95c8001b0e22540fb
.text            sha256 9b49c77a59d3b77effab6c1847a0f6633200f7ce0f0600d3f696e6ce41ac4111
dbg overlay      68040-260727-01 (adds the sigtoproc probe; base unchanged)
```

## Why this is being asked now, and what the real goal is

Two 68060 defects were root-caused on 2026-07-27 (`KNOWN-ISSUES.md` ISSUE-34a/34b, evidence
`test-tools/issue34-060-unimpl-integer-260727.txt`):

- **34a, PROVEN.** gcc emits `muls.l <ea>,Dh:Dl` (64-bit result) for division by a constant.
  The 68040 implements it in hardware, the 68060 does not, `M68Kvec[61]` points at `nullvect`,
  and the process is killed. One-instruction repro (`test-tools/mul64test.c`): emu-040 PASS
  exit 0, emu-060 `Killed` exit 137. Correlation across our test suite was 6/6 — zero such
  instructions and it works on 060, one or more and it dies.
- **34b, resolved same day.** `cc1` dies with SIGSYS (12) on the 060 while working on the 040.
  We disassembled the whole guest toolchain out of the read-only vanilla tree — gcc, cc1
  (666 KB), cpp, gnulib, libc.so.1, libc.a, ld.so.1 — and **all are clean** of 68060-
  unimplemented instructions, so 34a is not the cause. The probe named it: `sig=12`,
  `psargs=gcc-cc1 … fputest.c`, `fu=0` (kernel-raised), `kcaller=0x0804858C` = `sigaddq+0xaa`.
  And `test-tools/fputest.c`'s own header, written during the FPU Tier-1 work, already said it:
  *"the AMIX native cc1 itself crashes with SIGSYS on this FPU-less 040 kernel (it uses an
  unimplemented transcendental)"*. The 040 FPSP fixed that on the 040; the 68060 has no FP
  support package at all, because `fpsp_glue040.s` gates every entry on `cmpl #40,cputype`.

So the 68060 needs **both** halves of Motorola's 68060SP: ISP for 34a, FPSP for 34b.

**The goal is wider than our own machine, and that changes the priority of one question.** A
full 68060 costs around 300 EUR; a **68LC060** — same core, no FPU — costs around 50 EUR and
many Amiga hobbyists already have one. This port is not being done for one Mercury 040. If
LC060 can be supported, the audience for a working 68060 AMIX is several times larger. That is
why Q1 is first.

---

## Q1 (highest value): can 68060SP's FPSP emulate a MISSING FPU, or does it need one?

This single answer decides whether 68LC060 support is nearly free or a separate project.

The 040 FPSP **cannot** serve an FPU-less part: it completes *unimplemented* instructions by
decomposing them into sequences of *implemented* FPU operations, so its own body executes FP
instructions. On a part with no FPU it would trap inside itself.

Our understanding — **unverified, please confirm or refute from the package documentation** — is
that Motorola's 68060SP FPSP is documented as providing full floating-point *emulation* for the
68LC060 and 68EC060, precisely because those parts were common. If that is right, LC060 support
comes almost free once 060SP is in, and the SoftIEEE-style route is unnecessary.

Please answer specifically:

1. Does 060SP's FPSP provide **full FPU emulation** (no FPU present), **completion only** (FPU
   present but incomplete), or **both as separate configurations/entry points**?
2. If both: what selects between them at build or run time, and does it need a `cputype`-style
   gate of the kind `fpsp_glue040.s` already uses, or a distinct one for LC/EC detection?
3. What does it need from the OS that the 040 FPSP did not — different exception frame handling,
   a different call-out table, extra memory, an FPU-state area that must exist even with no FPU?
4. If 060SP does **not** do full emulation, say so plainly and state what a from-scratch
   soft-float would actually need. Our own assessment is that the arithmetic is the small part
   and the glue is the project: an FP instruction decoder covering all addressing modes and
   `fmovem`, operand fetch from user space under the `u_nofault` discipline, 96-bit extended
   precision with rounding modes, FPSR condition codes and exception flags, and correct FP frame
   restore. Confirm or correct that list — and note that `src/lmul060.s` shows the
   pattern of what we can already do well (a validated replacement algorithm, 202500
   random+edge cases, 0 diffs against a reference model).

## Q2 (the risk we have not checked): would an LC060 die inside the KERNEL?

Before any user-space FP question matters: **does the kernel itself execute FP instructions
unconditionally?** If context switch, trap entry/exit or signal delivery does `fsave` /
`frestore` / `fmovem` without checking, an FPU-less part faults in supervisor state at the first
switch and never reaches user code.

What we know: `fpu_present` @0x4fdc and `fpu_ptr` @0x4fe0 exist, **19 relocations** reference
them, and our own overrides (`runtime040.s`, `wb040.s`, `wb060.s`) contain **no FP instructions
at all** — so the save/restore lives in stock kernel code gated by those 19 sites. Nineteen is
enough that one unguarded path is plausible, and an unguarded path is exactly the
producer/consumer shape that has bitten this project repeatedly.

1. Enumerate every kernel site that executes an FP instruction, and state for each whether it is
   gated on `fpu_present` (or equivalent) **on every path**, including error and signal paths.
2. Name any site that is **not** gated. That is the blocker for LC060 and it is ours to fix
   regardless of which Motorola package we obtain.
3. Does `fpu_present` get set correctly for an FPU-less part? It derives from AmigaOS
   `AttnFlags` via the loader (`cputype` is poked the same way, see `src/cputype060.s`).
   State which AttnFlags bit distinguishes 68060 from 68LC060 and whether the current derivation
   would report `fpu_present=1` on an LC060 — a false positive there would be worse than no
   detection at all.

## Q3 (the number that decides whether the 060 is usable at all)

`src/lmul060.s`'s header records a 2026-07-09 census concluding that `lmul`'s three
sites are *"the ONLY such sites in the whole kernel"*. That census was correct and the fix was
correct — but it was **scoped to the kernel**, which is why ISSUE-34a existed: user space was
never counted and vector 61 was never wired.

So: **census the installed userland.** How many of `/usr/bin`, `/bin`, `/usr/lib`,
`/usr/public/lib`, `/usr/X/bin` and the shared libraries contain 68060-unimplemented
instructions, split by class?

- integer: 64-bit-result `muls.l`/`mulu.l`/`divs.l`/`divu.l`, `movep`, `cas`/`cas2`,
  `cmp2`/`chk2`, plus any misaligned-access forms the 060 traps
- floating point: whatever the 68060 FPU does not implement (see Q4)

The distinction that matters for the decision: **is it a handful of binaries or is it pervasive?**
If a handful, targeted vector handlers are enough to make the 060 usable while 060SP is being
obtained. If pervasive, the ISP is mandatory before the 060 is usable for anything and there is
no interim.

Note our read-only vanilla mount is root-owned and left **76 program files unreadable** in your
COFF work; the same gap applies here. State the coverage you achieved and what was excluded —
we can close the gap on the live machine with your `scan_exec_formats.py` approach.

## Q4: exact 68060 unimplemented set, and the vector map

We need this to design the dispatch, and we should not be guessing at it.

1. **Integer:** the exact list of instructions and *forms* the 68060 does not implement in
   hardware. Our 34a case is specifically the 64-bit-result form — the extension word's size bit
   (`ext & 0x0400`) distinguishes it from the 32-bit form the 060 does implement. Confirm and
   complete the list.
2. **Floating point:** what the 68060 FPU implements in hardware versus the 68040. Our working
   assumption is that the 060 lacks the transcendentals entirely and also `fintrz`, `fmovecr`,
   `frem`, `fscale`, `fgetexp`, `fgetman` and packed-decimal — please verify, because it decides
   how much of the FPSP is actually exercised.
3. **Vector assignments.** Which vectors do the ISP and FPSP each need on the 68060? We have
   already byte-patched vector 11 and 48/51/52/53/54/55 to the 040 FPSP (49/50 deliberately left
   on `nullvect` — the 040 completes inexact and divide-by-zero in hardware). Enumerate the
   collisions, and confirm that the shim pattern is the right answer: retarget each shared vector
   to a stub that branches on `cputype` and dispatches to the 040 FPSP or the 060 package. Note
   `patch_fpsp_vec11.py` / `patch_fpsp_vectors.py` currently **assert the target is `nullvect`**,
   so they will need to become shim-aware.

## Q5 (cheap, correct, and independent of any Motorola package): make the 060 fail honestly

Even with no support package at all, the current failures are **mislabelled**, and that
mislabelling cost a day of diagnosis:

- unimplemented **integer** instruction → process **SIGKILL**ed (exit 137)
- unimplemented **FP** instruction → **SIGSYS** (12), "bad system call"

Neither is right. An unimplemented instruction is `SIGILL`, and an FP one arguably `SIGFPE`.
SIGSYS in particular sent us looking at the syscall path for a day, and SIGKILL gives the user no
information at all.

1. Trace `u_trap`'s vector→signal mapping and state what each 68060-relevant vector (11, 48–55,
   60, 61) currently produces, and why 61 yields SIGKILL while the FP path yields SIGSYS.
2. What *should* each produce, per the SVR4 contract?
3. Is this a bounded byte patch — a mapping table entry or a default case — or does it need code?
   If it is bounded, we would like to land it **before** any support package: it converts silent
   or misleading death into a self-documenting one, and it makes every subsequent 060 diagnosis
   cheaper. It is also the only item here with no dependency on obtaining anything from Motorola.

---

## What makes a good answer

1. **Q1 answered from documentation, not inference.** If the LC060 emulation claim cannot be
   confirmed from the package material, say that — "unknown" is actionable, a guess is not.
2. **Q2's unguarded sites named individually**, with addresses. A summary count is not usable.
3. **Q3 as a coverage-honest number**, with what was excluded.
4. **Classification, not matching.** The extension-word size bit is the whole difference between
   a 32-bit `muls.l` the 060 runs happily and the 64-bit form that kills the process; a raw
   mnemonic scan cannot tell them apart. The same discipline that found `IINACTIVE`, `STYP_LIB`,
   26× `IMODTIME`, `NDADDR-1` and four errno constants applies here.
5. **Say when something is not worth doing.** If Q5's mapping fix turns out to need real code, or
   if the userland census in Q3 says the 060 is unusable without the full ISP, those are useful
   answers that stop us building an interim that has no value.

## Context

- Implementation of anything here waits until after the hardware session
  (`docs/REALHW-VERIFY-260725.md`), which validates a large 040 delta on real silicon. The 060 has no
  hardware in this project at all, so 060 work can only ever be emulator-verified for now — one
  more reason to know what we are buying before we build it.
- Adding 060SP would grow the base image by roughly 350 KB on top of the FPSP already in it. The
  loader margin was quantified on 2026-07-27 and is not a constraint (29.2 MiB of headroom;
  overlap would need a ~16 MiB kernel file), so size is not a blocker — but it does mean the
  loader's copyit path should be re-checked at the new size rather than assumed.
- Amiberry models the 060 trap correctly: our one-instruction repro dies on emu-060 and passes on
  emu-040 with the same binary, so the emulator is a usable verification target for this work.
