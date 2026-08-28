# FPE round 9 — `fpe_advmiss_n = 201`: the stacked "Next PC" is not the instruction length

Round 8 gave the length law its first **non-vacuous** metal reading and it failed the registered
row: `fpe_advmiss_n = 201` over 662,248 emulated instructions (`fpe_advctl_n = 220,593`,
`fpe_advnofetch_n = 0`), against the round-5 bench claim of **0 over 11,655,653**. Every FP
result in the same session was exact. The metal record is
`Amix/tmp/2026-08-27-fpe-metal-r8/RESULTS.md`, Finding 1.

This document settles defect-versus-designed-fallback by **static analysis only**. No boot, no
bench run, no behavioural change: it answers the four questions, gives the verdict, and registers
what round 9 must measure. Everything it asserts is traced to source that is on this machine —
this port's own files, the NetBSD emulator as the build extracts it, Motorola's 68060 support
package as `build-fpsp060.sh` extracts it from the same pinned tarball, and Amiberry's CPU core.

> **PROVENANCE.** §3 and §4 describe the behaviour of Motorola's M68060 support package — by
> file, entry point and mechanism, in this document's own words. No vendor text is reproduced;
> `THIRD_PARTY_NOTICES/MOTOROLA-M68060-SP.txt` carries that package's notice. Same class as
> `FPE-INTEGRATION-CONTRACT.md` and `FPE-R7-METAL.md`.

**Scope discipline, unchanged from rounds 1–8.** No file under `build/fpe-src/` is touched, and
this round touches no code at all.

---

## ANSWER FIRST

**Designed fallback, not a defect. The lane is not exposed, and the registered row was wrong.**

* **(a)** The lane resumes on **its own computed advance**. `fpu_emulate.c:124-125` overwrites
  `f_pc` with `f_pcfi` (the format-4 frame's PC-of-faulted-instruction) on entry, `:217-218` adds
  `insn.is_advance`, and `fpe_glue.c` writes that value back over the frame's PC field
  **unconditionally**, before any other work. The CPU's stacked value survives only in a C local
  named `stacked_pc`, whose sole readers are the counter and the witness latch.
* **(b)** The format-4 (`0x402c`) FPU-disabled frame's "Next PC" is, in Motorola's own model, a
  **software-maintained** field. Motorola's 060 package computes that field itself, from the
  instruction's decoded length, whenever the length is not trivially derivable — and leaves the
  `<ea>` field explicitly undefined while doing it. A value that is short for a 12-byte
  immediate-operand instruction is that field behaving as specified, not silicon misbehaving.
* **(c)** **No.** Three paths can reach an RTE with this frame, and **all three overwrite the
  stacked PC before the RTE**: the emulated path (the glue), and both decline paths, which land
  in `src/fpsp060_glue.s:Lco_fpudis_nofpu` and copy `+0xC` over `+0x2` by hand. The short value
  is instrument-only and cannot become a resume address.
* **(d)** The bench read 0 because **Amiberry's frame synthesis cannot produce a disagreement**.
  UAE consumes every extension word — the immediate operand included — *before* it raises the
  exception, then stacks `m68k_getpc()` as the Next PC. That is `PCFI + true length` by
  construction, so the instrument compared NetBSD's decoder against UAE's decoder and found them
  to agree. Round 5's 0-over-11.6 M measured the emulator bed, not the emulator.

**The one thing that IS wrong is the registered expectation.** `FPE-GLUE-DESIGN.md` §4.4 says of
the stacked PC and the computed advance: *"The two must be equal."* On real 68060 silicon they are
not required to be, for one identifiable class of instruction. §7 registers the replacement row.

**A separate finding fell out of the trace and is NOT about `advmiss`:** on an FPU-less 68060 the
extended-precision and packed immediate forms, and two `fmovm` forms, take **vector 60** before
vector 11, and this port routes them to SIGSYS rather than to the emulator. §6.

---

## 1. What was measured, and what the witness says

```
fpe_entry_n     662,248     fpe_fmt4_n      662,248     fpe_v11_fmt4_n  662,248
fpe_advctl_n    220,593     fpe_advmiss_n       201     fpe_advnofetch_n      0
fpe_b_pc     0x80003206   fpe_b_stacked 0x8000320C   fpe_b_resume 0x80003212
fpe_b_opword     0xF23C
```

Every entry was a format-4 frame; `fpe_fmt2_n`, `fpe_fmt0_n`, `fpe_fmtx_n`, `fpe_super_n` were 0.

**The witness decodes cleanly.** `fpe_b_pc` is `f_pcfi`, the frame's `+0xC` longword, and the
counter reads the opword from exactly that address (`fpe_glue.c`, the `copyin` in the
disagreement arm). `0xF23C` is `1111 001 000 111 100`: F-line, coprocessor id 1, **type 0**
(general — so not FBcc, not FDBcc, not FTRAPcc, and correctly excluded from the benign class),
and mode/register `7/4` — **immediate data**.

The two PCs, as offsets from the faulting instruction:

| | value | = `f_pcfi` + |
|---|---|---|
| CPU's stacked "Next PC" | `0x8000320C` | **6** |
| emulator's resume PC | `0x80003212` | **12** |

**12 identifies the operand size, and only one size gives 12.** `fpu_emulate.c` sets
`insn.is_advance = 4` for every FP instruction, then `fetch_immed` (`fpu_calcea.c:552-609`) adds
the immediate: `is_datasize` 1 or 2 → +2, 4 → +4, 8 → +8, 12 → +12. So a total of 12 means
`is_datasize = 8` — an IEEE **double** immediate, `f<op>.d #<8 bytes>,%fpN`, 12 bytes long. The
CPU stacked 4 + 2: it sized that operand as a single word.

**The emulator's 12 is the right number, and three independent things say so.**

1. `is_datasize` comes from the FP command word's source-specifier field
   (`fpu_emulate.c:597-607`), and the *same* field drives the operand load. Had it been misread,
   the emulator would have consumed the wrong bytes as the operand. 201 such events occurred
   inside a session whose `awk`, `printf %f|%e|%g`, `df -k` and full Dhrystone correctness block
   were all exact, and whose FP-Dhrystone was bit-identical across three runs.
2. The advance machinery is independently confirmed on this silicon by the `dz0` probe:
   `fpe_last_fault_pc = 0x8000063E` is the disassembled address of `f22e 5420 ffd0`
   (`fdivd %fp@(-48),%fp0`, 6 bytes) and `fpe_last_si_addr = 0x80000644` is exactly `+6`.
3. Resuming at `f_pcfi + 6` would have executed the last six bytes of a double constant as
   instructions, 201 times. Nothing in the session behaved that way — because nothing resumed
   there (§4).

**Immediate is the only F-line addressing mode whose instruction length is not carried in the
operation word.** For every other mode the extension-word count follows from the mode/register
field alone (or from a self-describing full-format extension word). For `#<data>` the byte count
lives in the **FP command word's** source specifier — the one field a disabled FPU has no reason
to decode. That is the structural reason the miss class exists, and it predicts that every one of
the 201 carries an opword with `(opword & 0x3F) == 0x3C`. One witness is consistent with that;
201 are not yet measured. §7 P1 registers the discriminator.

---

## 2. (a) The resume PC is the emulator's, and the stacked one is never written back

Traced end to end:

| step | file:line | what happens to the PC |
|---|---|---|
| 1 | `fpe_glue.c` frame shim | `stacked_pc = *(unsigned int *)(xf + 2)`; `f.f_pc = stacked_pc` |
| 2 | `fpe_glue.c` frame shim | `f.f_fmt4.f_fslw = *(unsigned int *)(xf + 12)` — the tail is carried unclobbered |
| 3 | `fpu_emulate.c:108-125` | on a format-4 frame, sets both `insn.is_pc` and the frame's PC field from `f_fmt4.f_fslw` — **the stacked value is discarded here** |
| 4 | `fpu_calcea.c` / `fpu_emul_*` | `is_advance` accumulates from the decode, 4 plus extension words |
| 5 | `fpu_emulate.c:217-218` | adds `insn.is_advance` to the frame's PC, on the no-signal outcome and on `SIGFPE` alike |
| 6 | `fpe_glue.c` write-back | `*(unsigned int *)(xf + 2) = f.f_pc;` — **unconditional**, ahead of the `r == 0` block |
| 7 | `src/fpe040.s` | `ureturn`'s RTE pops the sixteen-byte frame |

Step 6 is outside the success arm on purpose, so the abort path gets it too: on a SIGILL or
SIGSEGV abort the emulator did **not** advance (step 5's guard), so `f_pc` is still `f_pcfi` and
the frame names the faulting instruction — restart semantics, which is what a signal wants.

`insn.is_nextpc` is the only other candidate resume value in the package. It is written in
exactly two places: `fpu_emulate.c:121-123`, inside a `#if 0`, and `:1140` for FBcc/FDBcc, where
it is computed as `is_pc + is_advance`, not taken from the frame. The block that would restore
it (`:226-231`) is `#if 0`'d under a vendor comment flagging that block as suspect. There is no live
path from the stacked value to a PC.

`ksi_addr` — and therefore `si_addr` in the delivered signal — is `frame->f_pc` after step 5
(the `fpe_abort` macro, `fpu_emulate.c:54-60`). Also the computed value, never the stacked one;
round 4's FIX 6 already settled its semantics.

---

## 3. (b) What the format-4 "Next PC" is, in Motorola's own model

The frame this lane sees is the one Motorola names, and its layout is not in dispute. The
68060's F-line vector carries three shapes, discriminated by the format/vector word, and
Motorola's own dispatcher spells all three out: a six-word frame (`0x202c`) for **FPU
unimplemented instruction**, an **eight-word frame (`0x402c`) for FPU disabled**, and a four-word
frame (`0x002c`) for a genuine F-line illegal. `src/fpe040.s` keys on exactly those three
constants, and the round-8 census says every one of the 662,248 entries was `0x402c`.

The eight-word FPU-disabled frame's fields, as NetBSD names them in the machine-ABI header the
build extracts (`m68k/cpuframe.h`, `struct fmt4`, whose comment records that these two names are
the 060-FPU-disabled type-4 spellings of the longwords): `f_fea` at `+0x8` — the faulted
effective address — and `f_pcfi` at `+0xC` — the PC of the faulted instruction. The stacked PC
at `+0x2` is the **"Next PC"**.

**Motorola computes that Next PC in software, and says so.** In the 060 package's
unimplemented-effective-address handler (`060sp/dist/fpsp.s`, entry `_fpsp_effadd`, and the
disabled-FPU arm below it) there is a branch taken when the PCR says the FPU is disabled. The
handler's own header comment gives the reason: the hardware raises the unimplemented-`<ea>`
fault first, even though FPU-disabled outranks it in priority, so the handler has to manufacture
the FPU-disabled frame itself. What it does there is the whole answer:

* it reads the instruction longword back out of memory through its own instruction-fetch callout
  — it does not trust anything the CPU stacked about the instruction's shape;
* it then **computes the total instruction length** in three arms, each of which a comment at the
  site names: a flat 16 bytes when the instruction carries an extended-precision immediate
  operand; 12 or 16 bytes for `fmovm.l`, according to whether the register-list field selects two
  or three control registers; and, for dynamic `fmovm.x`, a call into its own EA calculator, the
  length being recovered afterwards from the distance the extension-word pointer travelled —
  which the comment there presents as a by-product of the EA calculation rather than a decode of
  its own;
* and it builds the eight-word frame by copying the Current PC to `+0xC` and writing
  **Current PC + that computed length** to `+0x2`. The comment at that site describes the value
  it is writing as additional information carried on the synthesised frame, and records that the
  `+0x8` slot is left undefined.

The same package does the same thing on the way out of every emulation it performs: it maintains
its own extension-word pointer as it consumes operands and then stores that pointer over the
frame's PC field before returning, under a comment naming that store as the one that sets the
frame's Next PC.

Two things follow, and they are the citation this round needed.

1. **`+0x2` is advisory information the software maintains, not an architectural guarantee.**
   Motorola's reference software
   writes it, re-writes it, and treats `+0xC` as the authority. NetBSD's emulator makes the same
   choice — `f_pcfi` in, computed advance out — and so does this lane.
2. **The classes Motorola bothers to fix up are exactly the length-ambiguous ones**: immediate
   operands and the `fmovm` forms. It does not fix up anything else, which is the same statement
   as "the hardware's Next PC is already right for every mode whose length the operation word
   determines". Round 8's 441,454 agreements and 201 disagreements sit on exactly that line.

**Standing limit, stated rather than papered over.** The M68060 User's Manual (§8.2 stack frame
formats, §8.4 exception descriptions) is the normative document, and it was **not re-read this
round** — there is no copy on this machine. Everything above is from Motorola's own 060SP source
and NetBSD's header, both extracted from the pinned tarball, plus this port's measurements. If the
manual is ever consulted, the sentence to look for is what it promises about `+0x2` for the
FPU-disabled frame; nothing in this verdict depends on it saying more than the package does.

---

## 4. (c) Can the short PC ever be consumed? Three paths, and all three overwrite it

| path | when | what it does to `+0x2` |
|---|---|---|
| emulated | user-origin format-4, lane armed | `fpe_glue.c` writes the computed PC over it (§2 step 6) |
| decline, supervisor-origin | `fpe_super_n`, 0 on metal | `fpe_decline` → `fpsp_vec11` → `fpsp060_vec11` → Motorola's F-line dispatcher → `_real_fpu_disabled` → `src/fpsp060_glue.s:Lco_fpudis_nofpu`, which does `movel %sp@(0xc),%sp@(0x2)` — PCFI over Next PC — then `jmp nullvect` |
| decline, FPU present | never on an LC060 (`fpu_present` gate) | same callout, `Lco_fpu_disabled`'s other arm, which also does `movel %sp@(0xc),%sp@(0x2)` before its RTE |

`Lco_fpudis_nofpu` predates this lane and was written for a different reason — its comment says
the copy is *"what makes the stacked PC name the faulting instruction, which is what the F-line
frame `nullvect` expects would have carried anyway"* — but the effect is the one that matters
here: **no RTE in this kernel returns to a PC the CPU stacked in a format-4 FPU-disabled frame.**

Two more would-be consumers, closed:

* **A format-2 frame reaching the emulator** would be a real hazard: `fpu_emulate.c:108` only
  performs the `f_pcfi` substitution when `f_format == 4`, so a format-2 frame would be decoded
  from its *next*-instruction PC. It cannot happen — `src/fpe040.s`'s `Lfpe_fmt2` declines before
  `fpe_trap` is called, and round 8 measured `fpe_fmt2_n = 0` on the LC060 anyway.
* **`ptrace`/core-dump readers** see the same supervisor-stack bytes the RTE will, after the
  write-back. There is no second copy of the pre-emulation value anywhere.

So `fpe_advmiss_n` is what its own comment already claims to be — *"MEASURED, NOT ACTED ON"* — and
round 8's 201 cost the session nothing.

---

## 5. (d) Why the bench read 0: Amiberry stacks a decoded Next PC

Amiberry builds this frame in software, and the construction is visible.

`src/fpp.cpp`'s `get_fp_value()` decodes the source operand. For mode 7 / register 4 —
`#<data>` — it fetches the immediate first, sized from the same source-specifier field the
emulator uses (`sz1[8] = { 4, 4, 12, 12, 2, 8, 1, 0 }`; the double arm reads two long words) —
and only **after** that does it call `fault_if_no_fpu()`, which for a 68040 or 68060 with no FPU
reaches `fpu_op_illg()` → `fp_unimp_instruction_exception_pending()` → `Exception(11)`.

`Exception_normal()` (`src/newcpu.cpp`) opens with `uae_u32 currpc = m68k_getpc();` — the emulated
PC *as it stands after that fetch*. `Exception_build_stack_frame_common()`
(`src/newcpu_common.cpp`) then, for `nr == 11 && regs.fp_unimp_ins` on an FPU-less 040/060, calls
`Exception_build_stack_frame` with `regs.fp_ea`, `currpc`, `regs.instruction_pc`, the vector
number and format `0x4`; the `case 0x4` arm — the one its own comment marks as the
floating-point-unimplemented frame of the FPU-less 040 parts — lands `regs.instruction_pc` at
`+0xC`, `regs.fp_ea` at `+0x8`, and `currpc` at `+0x2`.

So on the bench: `+0xC` = instruction PC, `+0x2` = the PC after a **complete** decode of the
instruction, immediate included. `+0x2 - +0xC` is the true length, always, for every addressing
mode. The instrument's test — "does `f_pcfi + is_advance` equal the stacked PC?" — reduces on that
bed to "does NetBSD's length decode agree with UAE's length decode?", and both read the same
source-specifier field. **A disagreement is not constructible.** The round-5 reading of 0 over
11,655,653 instructions is true and carries no information about silicon.

This is a bench-fidelity gap of the useful kind: it is one line of behaviour, it is now located,
and it explains a metal-versus-bench divergence completely. It is **not** an Amiberry bug in any
ordinary sense — a decoded Next PC is a legitimate value for a field Motorola's own software fills
in — but it does mean this rig cannot be used to test the length law. §7 P4.

---

## 6. Separate finding: the vector-60 classes never reach the emulator

Traced while answering (c), reported because it is a coverage question the lane has never asked.

On a 68060, four instruction forms take the **unimplemented effective address** exception, vector
60, in preference to the F-line vector: an FP instruction with an **extended-precision** immediate
operand, one with a **packed-decimal** immediate operand, `fmovm.x` with a dynamic register list,
and `fmovm.l` with two or three control registers. Motorola's package records that the hardware
raises this fault ahead of the FPU-disabled one, even though FPU-disabled is the higher-priority
exception, which is why its handler opens by testing the PCR.

This port wires vector 60 to that handler (`src/patch_fpsp_vectors.py`, `fpsp_vec60` →
`fpsp060_vec60` → the package's effective-address entry). With no FPU the package synthesises the
`0x402c` frame (§3) and calls out to `_real_fpu_disabled`, which is
`src/fpsp060_glue.s:Lco_fpu_disabled`. Its `fpu_present == 0` arm points the stacked PC at the
faulting instruction and jumps to `nullvect` — **SIGSYS for a user process**.

So on the FPE lane those four forms are **not emulated**; they are refused, and they never
increment a single `fpe_*` counter. Whether that matters is an empirical question this round
cannot answer: round 8 did not read `f60_effadd_n`, `f60_fpudis_n`, `f60_fpudis_nofpu_n` or
`f60_last_co`, and a session that reached multiuser and ran `awk`, `printf` and Dhrystone without a
single SIGSYS suggests the forms did not occur — gcc 2.7.2.3 has little reason to emit an
extended or packed immediate, and this lane presents FP state itself rather than letting libc
`fmovm.l` the control registers. **Registered as a read, not as a defect** (§7 P5). If those
counters are non-zero on real silicon, the lane has a silent hole and the fix is a decision, not a
patch: route `Lco_fpudis_nofpu` into `fpe_vec11` instead of `nullvect`, which would hand the
emulator a Motorola-built frame whose Next PC is already correct.

> **ANNOTATION (round 10, 2026-08-27).** *They were read, and they were non-zero.*
> `f60_effadd_n` 0 → 3 on real 68LC060 silicon, one per execution of the extended and packed
> immediates, each ending in SIGSYS with the whole `fpe_*` block unmoved
> (`Amix/tmp/2026-08-27-fpe-workload/RESULTS.md`, Finding 1). This section's "silent hole" is
> therefore measured rather than hypothetical, and round 10 closed it. **The candidate fix
> sketched above was tried and rejected** for three reasons found while implementing it: it is an
> unbreakable loop, because `fpe_vec11`'s own decline reaches `fpsp_vec11` → the package →
> `_real_fpu_disabled` → back here; that call-out is also where the vector-11 declines land,
> supervisor origin included; and an `FPSP=0` kernel has no such call-out at all. The arm went in
> front of the vector instead, as `fpe_vec11` does. `docs/contracts/FPE-R10-VEC60.md` is the
> replacement, and its §4 carries the rejection in full. The prediction in this paragraph that
> "gcc 2.7.2.3 has little reason to emit" these forms was **confirmed** — round 10 disassembled
> the box's own `libc.so.1`, its `libm.a` and everything the compiler emitted that session and
> found zero occurrences of either.

---

## 7. Registered proposals — none of them implemented this round

Every item below is a proposal. **No behavioural code change is made in round 9**, and none should
be made until the discriminator in P1 has been read on metal.

**P1 — split the counter by addressing mode, and latch the first non-immediate miss.**
The verdict predicts that all 201 misses are immediate-operand instructions. Make that
falsifiable rather than argued: in the disagreement arm of `fpe_glue.c`, after the existing
`copyin` of the opword, count `(opw & 0x3F) == 0x3C` into a new `fpe_advmiss_imm_n` and everything
else into `fpe_advmiss_other_n`, and add a second witness quadruple (`fpe_d_pc`, `fpe_d_stacked`,
`fpe_d_resume`, `fpe_d_opword`) latched on the **first non-immediate** miss. Cost: one mask, one
compare, two counters, four longwords of `.data`, all inside a branch that already runs only on
disagreement. Predicted reading: `fpe_advmiss_other_n = 0`. If it is not 0, the second latch names
the instruction and this verdict is wrong in a way that is immediately visible.

**P2 — replace the registered row.** `fpe_advmiss_n = 0` is not an acceptance condition and must
stop being written as one. The replacement, for the metal row table:

> `fpe_advmiss_other_n = 0` and `fpe_advnofetch_n = 0`, with `fpe_advmiss_n` small and its
> witness carrying an immediate-mode opword. `fpe_advmiss_n` counts the CPU's stacked Next PC
> disagreeing with the emulator's decode; on real 68060 silicon that is **expected** for
> immediate-operand instructions and is not acted on.

**P3 — correct `FPE-GLUE-DESIGN.md` §4.4.** Its sentence *"The two must be equal"* is the
assumption this round refutes, and its round-3 verification line (*"`fpe_advmiss_n == 0` over a
full FP workload"*) inherits the error. The section should say what the instrument actually
measures — the hardware's advisory Next PC against the emulator's authoritative decode — and cite
§3 for why the two are allowed to differ. The counter's name is now misleading and should be
documented rather than renamed: the symbol is in three documents and two evidence trees, and a
rename costs more than the ambiguity.

**P4 — record the bench limit where it will be read.** The bench-versus-metal fidelity list
should carry: *Amiberry stacks a fully-decoded Next PC in the format-4 FPU-disabled frame, so the
instruction-length instrument cannot disagree on that bed; the length law is metal-only.* A
change to Amiberry that truncated the Next PC the way silicon appears to would make the bed able
to reproduce this, and would be worth doing before any future advance-logic work — but that is a
change to another repository and a decision for whoever owns that lane, not something this
document proposes to do.

**P5 — read the vector-60 counters on the next metal session.** `f60_effadd_n`, `f60_fpudis_n`,
`f60_fpudis_nofpu_n`, `f60_last_co`, alongside the existing `fpe_*` dump. Zero cost: they are
already in the image. §6 is the decision that depends on them.

> *Round 10: TAKEN, and the reading was 3 / 3 / 3 / 0x08 — see the annotation on §6. This is the
> one registered proposal of the five that produced a code change, and it produced it in the round
> after the one that registered it.*

---

## 8. What round 9 must measure — one row per claim

| # | Claim | Reading that would confirm it | Reading that would refute it |
|---|---|---|---|
| a1 | every miss is an immediate-operand F-line | `fpe_advmiss_other_n = 0` (P1) | non-zero, and `fpe_d_opword` names the class |
| a2 | the miss rate is a property of the workload, not a drift | `fpe_advmiss_n / fpe_entry_n` stays near 3 × 10⁻⁴ across a comparable load | an order-of-magnitude change with no workload change |
| a3 | the lane is unexposed | correctness block, `awk`/`printf` ladder and FP-Dhrystone exact, as in round 8 | any wrong FP result, or a SIGILL/SIGSEGV with `fpe_last_fault_pc` inside an immediate |
| a4 | nothing else at vector 11 changed | `fpe_advnofetch_n = 0`, `fpe_fmt2_n = fpe_fmt0_n = fpe_fmtx_n = fpe_super_n = 0` | any of them non-zero |
| a5 | the vector-60 classes do not occur | `f60_effadd_n = 0` | non-zero → §6 becomes a live coverage decision |

---

## 9. Carried forward, and what this round deliberately did not do

* **The microarchitectural reason the 68060 sizes a double immediate as a word in this field is
  not established, and is not needed.** §3 shows the field is software-maintained by
  architectural design, which settles the verdict regardless of how the hardware fills it. Anyone
  wanting the mechanism should start from the M68060 User's Manual §8.2/§8.4 rather than from
  more counters.
* **No opword histogram was added.** P1's two counters answer the question that matters; a
  64-bucket census of the EA field would answer a question nobody has.
* **The 201 were not attributed to a binary.** `fpe_b_pc = 0x80003206` is a user virtual address
  in a process that no longer exists, and the first miss had already happened at `fpe_entry_n = 3`
  — before the acceptance ladder ran. Attribution would need a per-process latch, which is more
  instrument than the finding is worth.
* **`fpe_advctl_n = 220,593` is not re-examined here.** Round 4's FIX 4 exclusion set is taken
  from the emulator decoder's own `optype` classification and round 8's `fpe_c_opword = 0xF2CE`
  (FBcc, 32-bit displacement) latched identically to the round-5 bench value on completely
  different hardware. That half of the instrument is behaving.
