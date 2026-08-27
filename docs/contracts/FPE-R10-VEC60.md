# FPE round 10 — the vector-60 SIGSYS: where it comes from, and the arm that closes it

Round 10's metal workload (2026-08-27, `Amix/tmp/2026-08-27-fpe-workload/RESULTS.md`) put
1,057,900 emulated instructions through the FPE kernel `68060-260827-61` on the real 68LC060 and
found **exactly two instruction forms that die**, both of them the same case twice:

```
fmove.x #<extended>,FPn      F23C 4800 + 12 bytes      SIGNAL 12 (SIGSYS)
fmove.p #<packed>,FPn        F23C 4C00 + 12 bytes      SIGNAL 12 (SIGSYS)
```

and the two neighbouring facts that make it a lane problem rather than a curiosity:

```
f60_entry_n   0 -> 3     f60_effadd_n  0 -> 3     f60_mem_n  0 -> 3
f60_real_n    0 -> 3     f60_fpudis_n  0 -> 3     f60_fpudis_nofpu_n  0 -> 3
f60_done_n    0 -> 0     f60_last_co   0x08

every fpe_* counter        UNMOVED
```

The handler was entered three times, completed zero times, and **no counter in the `fpe_*` block
recorded that a process had just died on a floating-point instruction.** Round 9 §6 predicted this
class as a coverage question and registered it as a read (P5); the read came back non-zero, so §6
is now a live decision. This document is that decision.

> **PROVENANCE.** §2 and §4 describe the behaviour of Motorola's M68060 support package in
> this document's own words, citing it by file and mechanism; where the NetBSD emulator's own
> source is discussed it is described the same way. No vendor text is reproduced.
> `THIRD_PARTY_NOTICES/MOTOROLA-M68060-SP.txt` and `THIRD_PARTY_NOTICES/NETBSD-M68K-FPE.txt`
> carry those packages' notices. Same class as `FPE-INTEGRATION-CONTRACT.md`,
> `FPE-R7-METAL.md` and `FPE-R9-ADVMISS.md`.

**Scope discipline, unchanged from rounds 1–9.** No file under `build/fpe-src/` is touched. The
`fpe_advmiss_n` rate question (28.1 % this round against round 8's 0.030 %) is **not** this
document's subject and nothing here is offered as an answer to it.

---

## ANSWER FIRST

**The SIGSYS is not a fall-through and not a failure inside the handler. It is
`src/fpsp060_glue.s:Lco_fpudis_nofpu` declining, deliberately and correctly, on a part it cannot
serve — written in F1 (2026-08-24) before this lane existed, and never told about it.**

The full path, and every step is either read out of source on this machine or forced by a counter
this round measured:

| # | where | what happens | counter |
|---|---|---|---|
| 1 | 68LC060 IU | the 12-byte immediate is an addressing mode the integer unit does not implement, so it raises **vector 60**, "FP unimplemented effective address", with a **four-word** exception frame whose PC field is the faulting instruction's own address | — |
| 2 | `src/fpsp_glue040.s:181` `fpsp_vec60` | `cputype == 60` → `fpsp060_vec60` | — |
| 3 | `src/fpsp060_glue.s:147` `fpsp060_vec60` | supervisor CACR in, jump to the package's effective-address entry | `f60_entry_n` +1, `f60_effadd_n` +1 |
| 4 | the package's `<ea>` entry | tests the PCR FPU-disable bit **first**, before it looks at the instruction at all. On this part the bit reads set, so it takes its FPU-disabled arm | — |
| 5 | that arm | reads the instruction longword back through the instruction-fetch call-out — `src/fpsp060_glue.s:532 Lco_imem_rl`, exactly one call per entry | `f60_mem_n` +1 |
| 6 | that arm | computes the total instruction length (16 bytes for an extended or packed immediate), rewrites the four-word frame into an **eight-word `0x402c` FP-disabled frame** — `+0xC` = the faulting PC, `+0x2` = faulting PC + 16 — and branches to the FPU-disabled call-out | — |
| 7 | `src/fpsp060_glue.s:406` `Lco_fpu_disabled` | the call-out lands here | `f60_real_n` +1, `f60_fpudis_n` +1, `f60_last_co` = 8 |
| 8 | `src/fpsp060_glue.s:419` `Lco_fpudis_nofpu` | `fpu_present == 0`: Motorola's self-healing policy would spin forever on a part with no unit, so this arm points the stacked PC at the faulting instruction and **`jmp nullvect`** | `f60_fpudis_nofpu_n` +1 |
| 9 | `nullvect` → `utraps` → `u_trap` | dispatches on the frame's own vector — 11, F-line — and the stock AMIX policy for an F-line instruction is **SIGSYS** | — |

**`f60_done_n` did not move because `_060_fpsp_done` was never reached.** The package left through
an exception call-out, not through its completion call-out. "Entered three times, completed zero
times" is the invariant `entry == done + the real_* exits` **holding**, not breaking: three
entries, zero completions, three `real_*` exits. The unit's own accounting was correct throughout
and said so; what nobody was reading was that a `real_*` exit on this part is a death.

**No `fpe_*` counter moved because the lane's only attach point is `M68Kvec[11]`**
(`src/patch_fpe_vec11.py`). Vector 60 is a different vector. Nothing in `src/fpe040.s` or
`src/fpe_glue.c` is anywhere on the path above.

**Two things this round's counters prove that were previously only inferred.**

1. **PCR bit 1 reads set on a 68LC060.** Within the package's effective-address entry there is
   exactly one branch to the FPU-disabled call-out, and it is inside the PCR test. `f60_fpudis_n`
   went to 3, so the test took its "disabled" arm three times out of three. This is measurement,
   not the datasheet.
2. **The package's frame model is the one the silicon produces.** `f60_mem_n` moved by exactly 3
   over 3 entries — one instruction-fetch call-out each, which is what the FPU-disabled arm issues
   and nothing else on that path does. A handler working from a wrong frame shape would not have
   produced that count.

---

## 1. The two forms, and why only these two

| form | opword | command word | immediate | 68060 |
|---|---|---|---|---|
| long int | `F23C` | `4000` | 4 B | computed by the IU → vector 11 |
| single | `F23C` | `4400` | 4 B | computed → vector 11 |
| **extended** | **`F23C`** | **`4800`** | **12 B** | **vector 60** |
| **packed decimal** | **`F23C`** | **`4C00`** | **12 B** | **vector 60** |
| word int | `F23C` | `5000` | 2 B | computed → vector 11 |
| double | `F23C` | `5400` | 8 B | computed → vector 11 |
| byte int | `F23C` | `5800` | 2 B | computed → vector 11 |

The five that work reach the emulator through the ordinary format-4 FPU-disabled frame at vector
11 and are emulated correctly; the metal round verified all five by value. **The double immediate
is the one to keep separate in one's head**: 8-byte operand, 12-byte instruction, vector 11 — it is
round 8's witness-latch case (`fpe_b_resume − fpe_b_pc = 12`) and round 9 §1 already decoded it as
the double. It is *not* affected by anything in this document and it is a registered regression
row below.

The 68060 raises vector 60 for **four** instruction classes, not two — Motorola's own handler lists
them, and round 9 §6 repeated the list:

1. an FP instruction with an **extended-precision** immediate operand;
2. an FP instruction with a **packed-decimal** immediate operand;
3. **`fmovem.x`** with a dynamic register list;
4. **`fmovem.l`** with two or three control registers (which, at this vector, means an immediate
   source: 2 registers → 8 bytes of immediate → 12-byte instruction, 3 → 16).

Classes 3 and 4 were not observed this round. They are in scope for the arm because they arrive at
the same vector and would take the same death.

---

## 2. What the 68060 stacks at vector 60

**A four-word frame**, format `$0`, vector offset `0xF0` (= 60 × 4), i.e. format/vector word
`0x00F0`. Three independent things say so and none of them is the User's Manual, which is still not
on this machine:

* Motorola's handler is explicit, in its own header comment, that it has to build the eight-word
  FPU-disabled frame out of the four-word frame it was entered on, and the code that does it reads
  the SR at frame `+0`, the PC at frame `+2` and the format/vector word at frame `+6` — an
  eight-byte frame, which is format `$0` by the architecture's own frame table.
* The same handler takes the **instruction address directly from the frame's PC field** — it copies
  that longword into its extension-word pointer and fetches the opword from it. So for this frame
  the stacked PC is the **faulting instruction**, not the next one.
* This port has printed it: `docs/REALHW-260807-11-ACCEPTANCE.md` §4b records `vector 0xF0,
  pc=0x80000CAC` from Motorola's own `ftest060` on hardware, and that PC disassembles to the
  `fmulx #-2.0,%fp0` that raised it — the faulting instruction, at the address the frame carried.

That is a materially *better* frame than the one the vector-11 arm works with, and it is worth
saying why. The format-4 frame's `+0x2` "Next PC" is the software-maintained advisory field round 9
took apart; the format-0 frame at vector 60 has no such field at all. Its PC **is** `f_pcfi`. The
emulator's format-4 special case (`fpu_emulate.c:108-125`, substitute `f_fslw` for `f_pc`) exists
precisely to reconstruct what a format-0 frame already carries, so a format-0 frame needs no
special case: `insn.is_pc = frame->f_pc`, decode, `frame->f_pc += insn.is_advance`, done.

---

## 3. The instruction length the frame cannot carry, and who computes it

Round 9's verdict was that the format-4 "Next PC" is software-maintained and that
**`#<data>` is the one addressing mode whose length is not derivable from the operation word** —
the byte count lives in the FP *command* word's source specifier. Vector 60 is that finding's
sharpest instance: the instruction is 16 bytes (opword 2 + command word 2 + operand 12), and 16 is
a number no field of the exception frame contains.

Two independent decoders produce it, and they agree:

* **Motorola's**, in the FPU-disabled arm, where a comment states the rule outright: the
  immediate case is a flat sixteen bytes, a separate arm gives 12 or 16 for `fmovem.l` with two or
  three control registers, and dynamic `fmovem.x` goes through its own EA calculator.
* **NetBSD's**, in the extracted tree: `fpu_emulate.c` starts every FP instruction at
  `is_advance = 4`; `fpu_emul_arith` reads the source specifier and sets `is_datasize = 12` for
  extended; `fetch_immed` (`fpu_calcea.c:552-609`) then walks 2 + 2 + 4 + 4 = **12** bytes and adds
  each step to `is_advance`. Total 16.

The arm below uses the second, because that is the decoder the lane already resumes on
(round 9 §2) and because it is the same field that selects the operand bytes — a misread would
consume the wrong bytes, not merely resume at the wrong address.

---

## 4. Why the package cannot be the fix here

Round 9 §6 sketched one candidate: *"route `Lco_fpudis_nofpu` into `fpe_vec11` instead of
`nullvect`, which would hand the emulator a Motorola-built frame whose Next PC is already
correct."* That is true about the frame and wrong about the wiring, for three reasons found while
implementing it:

1. **It is a loop.** `fpe_vec11` declines a frame that is not its business by jumping to whatever
   `M68Kvec[11]` named before the arm was installed, which is `fpsp_vec11` → the package's F-line
   dispatcher → an FPU-disabled frame → `_060_real_fpu_disabled` → `Lco_fpudis_nofpu` → `fpe_vec11`.
   Every decline becomes an unbreakable loop, and the first one is a supervisor-origin frame, i.e.
   exactly the case frozen decision 8 wants to stay loud.
2. **It fires for more than vector 60.** `Lco_fpudis_nofpu` is also where the *vector-11* declines
   land — supervisor origin above all. Routing it into the emulator would emulate kernel-mode FP on
   a part with no FPU, which is the one thing this lane has refused since decision 8.
3. **It requires the package.** An `FPSP=0` kernel has no `fpsp060_vec60` and no call-out to
   retarget; vector 60 would still be `nullvect`, still SIGSYS, and the fix would be invisible in
   the one configuration used to isolate the lane.

So the arm goes **ahead** of the package, at the vector, which is where this port installs a
handler in front of another and where the vector-11 arm already sits.

---

## 5. The fix — `fpe_vec60`, the mirror of `fpe_vec11`

`M68Kvec[60]` is retargeted to `fpe_vec60` by `src/patch_fpe_vec60.py`, and `fpe_decline60`'s own
relocation is retargeted to whatever the slot named before — `fpsp_vec60` on a normal build,
`nullvect` on an `FPSP=0` one. Two relocation retargets, the second making the first safe: exactly
the mechanism, and exactly the argument, of `src/patch_fpe_vec11.py`.

The arm, in order:

```
census        fpe_v60_n, and the format/vector word classified
gate 1        fpu_present != 0        -> decline   (a real FPU: the package handles it, as today)
gate 2        fpu_emul == 0           -> decline   (lane not armed)
gate 3        format/vector != 0x00F0 -> decline   (a shape this arm has not been shown)
gate 4        stacked SR S bit set    -> decline   (supervisor FP is a kernel defect; stay loud)
              otherwise               -> fpe_trap, through the vector-11 arm's own body
```

Every decline reaches `fpe_decline60` and therefore takes the pre-arm path **instruction for
instruction**: on an FPU-present rig nothing about vector 60 changes, and on an LC060 a declined
event still dies exactly as it does today — but now `fpe_v60_decl_n` says so.

**The frame body is shared, not copied.** `fpe_vec60` branches into `Lfpe_user`, the same
register-push / `u_ar0` / `fpe_trap` / `ureturn` sequence the vector-11 arm uses. It is the
delicate part of the file and there is no reason for a second copy of it: `fpe_trap` already reads
the format and vector out of the frame it is handed, so it can tell the two arms apart without
being told.

### 5.1 What `fpe_trap` does differently for a vector-60 frame

* **The format-4 tail is read only from a format-4 frame.** A four-word frame ends at `+8`; the
  shim used to read `+8` and `+12` unconditionally, which on a format-0 frame would have picked up
  whatever the supervisor stack held above it. The faulting PC now comes from `f_pcfi` on a
  format-4 frame and from the stacked PC on a format-0 one, and `fpe_last_fault_pc` is that value
  for both arms.
* **The instruction-length instrument is format-4 only.** `fpe_advmiss_n` compares the CPU's
  advisory Next PC against the emulator's decode. A format-0 frame carries no Next PC — its PC
  field is the faulting instruction — so the comparison would report a "miss" on every single
  vector-60 event and mean nothing by it. The instrument is now gated on `f_format == 4`, which is
  the only shape it was ever about. **This does not change what the vector-11 path counts.**
* **The form gate.** Before the emulator runs, the opword and the FP command word are fetched from
  the faulting PC and the instruction is classified by the command word's top two bits — the same
  discriminator `fpu_emulate.c` itself dispatches on (`0xc000`/`0x8000`), and the same one-bit test
  Motorola's handler makes.

### 5.2 The form gate, and the one class that is refused

| command word | class | what the extracted emulator does | this arm |
|---|---|---|---|
| bit 15 = 0 | opclass 0/2/3: arithmetic or `fmove` with an immediate source | `fpu_emul_arith` sets `is_datasize` from the source specifier, `fetch_immed` reads 12 bytes, `fpu_explode(FTYPE_EXT)` converts | **emulate** |
| `& 0xc000 == 0xc000` | `fmovem.x` register list, static **or dynamic** | `fpu_emul_fmovm` reads a dynamic list out of `frame->f_regs` (`fpu_emulate.c:439-441`) and walks the registers | **emulate** |
| `& 0xc000 == 0x8000` | `fmovem.l` to/from control registers | `fpu_emul_fmovmcr` sets `is_datasize = 4` and calls `fpu_decode_ea` **once**, then loads every selected control register from that one longword | **REFUSE — SIGILL** |

The third row is the reason the gate exists at all. With two or three control registers and an
immediate source the instruction carries 8 or 12 bytes of operand and the emulator would consume 4,
load all of the registers from the same longword, and resume 4 or 8 bytes short — **a silently
wrong result and a resume address inside the operand.** Dying loudly is better than that, so this
class is refused with `SIGILL`/`ILL_ILLOPC` at the faulting instruction, `fpe_ea_fmovml_n` counted,
and the PC left naming the instruction that did not execute. It is an upstream limitation of the
vendored emulator, it is stated here rather than worked around, and fixing it would mean editing
`build/fpe-src/`, which this lane does not do.

### 5.3 Packed decimal: the gap, stated

**The NetBSD emulator has no packed-decimal support at all.** Two places say so and they agree:

* `fpu_emul_arith` (`fpu_emulate.c:599-610`) maps the source specifier to a datasize for double,
  single, long, word, byte and extended, and its `else` arm — which `FTYPE_BCD` (3) falls into —
  returns `SIGFPE` before an effective address is ever decoded;
* `fpu_explode` (`fpu_explode.c:232-256`) has cases for `FTYPE_BYT/WRD/LNG/SNG/DBL/EXT` and a
  `default: panic("fpu_explode")`. There is no `FTYPE_BCD` case.

So `fmove.p #<packed>,FPn` is **not** made to work by this round, and no claim is made that it is.
What changes is that it stops being invisible and stops being a SIGSYS:

* the arm accepts it (it is a bit-15-clear immediate form) and hands it to the emulator;
* the emulator refuses it with `SIGFPE` and an empty enabled-and-raised set;
* `fpe_glue.c`'s existing frozen-decision-8 fallback turns that into `SIGILL`/`ILL_ILLOPC` with
  `fpe_undecoded_n` counted — which is the honest answer, because a packed immediate on this kernel
  genuinely is an instruction the machine cannot execute;
* `fpe_ea_pack_n` counts it as an observer, so "how often does anyone actually do this" is a number
  rather than a guess.

Implementing packed→extended conversion would mean a first-party decimal-to-binary converter with
17 significant digits and a ±9999 decimal exponent, built on the emulator's `fpn` arithmetic, and
it would have to serve `fmove.p` **from memory** as well to be coherent — that form is equally
unsupported today and does not involve vector 60 at all. It is a round of its own, and the metal
evidence says it is not urgent: the round-10 disassembly of the box's own `libc.so.1`, its `libm.a`
and everything gcc 2.7.2.3 emitted found **zero** packed immediates and zero extended ones.

### 5.4 One correction on the way out: restart semantics for an instruction that never ran

`fpu_emulate.c:217-218` advances the PC when the emulator returns `0` **or `SIGFPE`**, and the
vendor's comment says outright that it is not clear this is right. For a genuine arithmetic
exception it is: the instruction completed and produced an exceptional result. For the
unsupported-operand-format refusals — packed above all — it is not: nothing executed, and a handler
that returns would resume 4 bytes into a 16-byte instruction.

The glue already recognises that class exactly, because it is the one where no exception is both
enabled and raised and no SVR4 `si_code` can be derived (`fpe_undecoded_n`, frozen decision 8's
`SIGILL` fallback). In that arm, and only there, the PC is now rewound to the faulting instruction
and `fpe_rewind_n` counts it. `fpe_undecoded_n` has read **0** on every boot of every round, so
this changes nothing that has ever been measured; it changes what happens the first time it is not
0.

---

## 6. Counters — the whole point of the round

The round-10 failure mode was not the death. It was that **a process died on an FP instruction and
the lane's own instrumentation could not tell.** So the accounting is the deliverable, and it
closes:

```
fpe_v60_n  ==  fpe_ea_n  +  fpe_v60_decl_n            every vector-60 event is accounted
fpe_ea_n   ==  fpe_ea_done_n + fpe_ea_sig_n           every accepted event has an outcome
```

**Pre-gate observers** — counted ahead of `fpu_present`/`fpu_emul`, so they move on any 68060
including FPU-present ones, exactly as the `fpe_v11_*` family does. Explicitly outside the
never-engage bar.

| symbol | meaning |
|---|---|
| `fpe_v60_n` | every vector-60 event: armed or not, user or supervisor |
| `fpe_v60_fmt0_n` | `0x00f0` — the four-word frame §2 establishes |
| `fpe_v60_fmtx_n` | any other shape. **Must stay 0**; non-zero refutes §2 |
| `fpe_v60_last_fmtvec` | ... and its format/vector word, low half. Sentinel `0xFFFFFFFF` |
| `fpe_v60_decl_n` | events the arm declined. On a part with no FPU these are the ones that **still die SIGSYS** — the residual-death counter, and the one to watch |

**The arm** — behind both gates. Part of the never-engage bar: **0 on every FPU-present rig.**

| symbol | meaning |
|---|---|
| `fpe_ea_n` | vector-60 events handed to `fpe_trap` |
| `fpe_ea_super_n` | supervisor origin: declined. **Must stay 0** — a kernel defect if not |
| `fpe_ea_imm_n` | ... classified as an immediate-source arithmetic/`fmove` form |
| `fpe_ea_pack_n` | ... of which the source specifier was packed decimal. Observer only; see §5.3 |
| `fpe_ea_fmovmx_n` | ... classified as `fmovem.x` with a register list |
| `fpe_ea_fmovml_n` | ... classified as `fmovem.l` control registers: **refused**, SIGILL. See §5.2 |
| `fpe_ea_fetchfail_n` | ... the instruction words could not be fetched: SIGSEGV, nothing emulated |
| `fpe_ea_done_n` | vector-60 entries the emulator completed and resumed |
| `fpe_ea_sig_n` | vector-60 entries that ended in a signal, all classes |
| `fpe_ea_last_op` | the last vector-60 entry's opword and command word, as one longword. Sentinel |
| `fpe_rewind_n` | undecodable-`SIGFPE` aborts whose PC was rewound to the faulting instruction (§5.4) |

**Every registered row and identity of rounds 3–9 survives verbatim, and that is deliberate.**
`fpe_entry_n`, `fpe_done_n`, `fpe_sig_n`, `fpe_user_n`, the four `fpe_sig*_n` classes and the three
`fpe_adv*_n` counters stay **vector-11 only**. In particular round 10's p7
(`fpe_v11_n == fpe_entry_n`) and p8 (`fpe_entry_n − fpe_done_n == fpe_sig_n`) mean in a round-11
dump exactly what they meant in a round-10 one. What is shared between the arms is latches
(`fpe_last_signo`, `fpe_last_code`, `fpe_last_si_addr`, `fpe_last_fault_pc`), the abort family
(`fpe_panic_n`, `fpe_copyfail_n`, `fpe_ufetch_n`, `fpe_undecoded_n`) and the entry lock — none of
which carries an invariant that the split would break.

**Why the fix is not "make `f60_done_n` advance with `f60_entry_n`", which is the obvious reading
of round 10's `3 / 0`.** Those two counters belong to the 68060 support package's unit, and their
invariant is `f60_entry_n == f60_done_n + the f60_real_* exits` — which **held** through round 10:
three entries, zero completions, three `real_*` exits. Making `done` advance with `entry` would
have broken a correct invariant to make a number look better. What the round actually needed was
for the event not to reach the package at all, which is what an arm in front of the vector
achieves — the same way the vector-11 arm keeps `f60_entry_n` at 0 across 1,057,900 emulated
instructions today. So the registered row is **`f60_entry_n = f60_effadd_n = f60_fpudis_n =
f60_fpudis_nofpu_n = 0` for a whole session**, and any non-zero reading means an event was
declined and `fpe_v60_decl_n` says how many. That is a stronger statement than `entry == done`,
because it is falsifiable by a single number rather than by a pair moving together.

**The monitoring recommendation this amends.** The opportunistic round said to watch `fpe_sig*` and
`fpe_undecoded_n`; round 10 found a death class that moves none of them. The list is now:

> `fpe_sig_n`, `fpe_undecoded_n`, `fpe_panic_n`, **`fpe_ea_sig_n`** and **`fpe_v60_decl_n`**. The
> last of these is the one that says a process died on an FP instruction the lane never saw.

---

## 7. What does not change

* **The vector-11 path.** No instruction of `fpe_vec11` is edited except the two-line split that
  gives `fpe_user_n` back to the vector-11 arm alone. The `0x402c` / `0x202c` / `0x002c` census,
  both gates, the format-0 SIGSYS refusal, the supervisor decline and `Lfpe_user` itself are
  untouched.
* **`fmove.d #<double>,FPn` and the other four working immediates.** They never take vector 60,
  they arrive on the format-4 frame at vector 11, and nothing on that path moves. Registered as a
  regression row in §8.
* **FPU-present rigs.** `fpu_present != 0` is the arm's first gate, so vector 60 reaches
  `fpsp_vec60` and the package as it does today. `fpe_ea_*` stays at 0.
* **`src/fpsp060_glue.s`.** Not edited. `Lco_fpudis_nofpu` keeps its F1 behaviour byte for byte; it
  is simply no longer the first thing a vector-60 event meets on an armed FPE kernel.
* **`build/fpe-src/`.** Not edited, and the freshness gate in `src/extract_fpe.sh` still proves it.

---

## 8. Registered expectations — for the bench where it can be taken, for metal where it cannot

`fpe_v60_n` moves only when something executes one of the four forms, so every row below is
conditional on a probe that does. The probe set is the round-10 `fpimm` family plus two new cases.

| # | row | reading that confirms | reading that refutes |
|---|---|---|---|
| v1 | the frame is the four-word one | `fpe_v60_fmt0_n == fpe_v60_n`, `fpe_v60_fmtx_n = 0` | `fpe_v60_fmtx_n > 0`, and `fpe_v60_last_fmtvec` names the shape — §2 is then wrong |
| v2 | **`fmove.x #<ext>,FPn` produces the right number** | the probe prints the constant exactly, exit 0 | any other value, or any signal |
| v3 | the accounting closes | `fpe_v60_n == fpe_ea_n + fpe_v60_decl_n` and `fpe_ea_n == fpe_ea_done_n + fpe_ea_sig_n` | any imbalance |
| v4 | an extended immediate costs no signal | `fpe_ea_sig_n = 0` across a run of only class-1 forms | non-zero |
| v5 | supervisor FP stays a defect | `fpe_ea_super_n = 0` | non-zero — investigate, do not tolerate |
| v6 | **the double immediate is unaffected** | `fmove.d #3.5,FPn` still prints `3.5`; `fpe_v60_n` unmoved by it; `fpe_entry_n`/`fpe_done_n` move by exactly one each | `fpe_v60_n` moves, or the value changes |
| v7 | the other four working immediates are unaffected | long/single/word/byte immediates print their values, `fpe_v60_n` unmoved | as v6 |
| v8 | packed is refused, visibly | `fmove.p` → SIGILL (4), `fpe_ea_pack_n` +1, `fpe_undecoded_n` +1, `fpe_rewind_n` +1 | SIGSYS (12) — the arm did not engage; or SIGFPE — the derivation changed |
| v9 | `fmovem.x` dynamic is emulated | `fpe_ea_fmovmx_n` +1, `fpe_ea_done_n` +1, registers correct | a signal |
| v10 | `fmovem.l #imm,fpcr/fpsr` is refused loudly | SIGILL, `fpe_ea_fmovml_n` +1, `fpe_ea_sig_n` +1 | a wrong control-register value, i.e. it was emulated |
| v11 | the never-engage bar holds | on any FPU-present rig: `fpe_ea_n = 0` and every `fpe_ea_*` at its initialiser, with `fpe_v60_*` excepted by name | any `fpe_ea_*` non-zero |
| v12 | nothing at vector 11 moved | `fpe_advnofetch_n = 0`, `fpe_fmt2_n = fpe_fmt0_n = fpe_fmtx_n = fpe_super_n = 0`, and the p7/p8 identities hold | any of them changed character |
| v13 | **the arm sits ahead of the package** | `f60_entry_n = f60_effadd_n = f60_fpudis_n = f60_fpudis_nofpu_n = 0` for the whole session, where round 10 read 3 / 3 / 3 / 3 | any non-zero — an event was declined, and `fpe_v60_decl_n` says how many and `fpe_v60_last_fmtvec` why |

### 8.1 The bench cannot raise vector 60, and the reason is one `&&` term

Round 9 §5 established that Amiberry stacks a fully-decoded Next PC and so cannot exercise the
length law. Round 10 asked the sharper question — can it raise vector 60 at all? — and the answer
is **no, structurally, on exactly the configuration this lane benches on.**

Amiberry has one and only one `Exception(60)` call site, in `fault_if_60()` (`src/fpp.cpp:1378`),
and its guard is

```
currprefs.cpu_model == 68060 && currprefs.fpu_model && currprefs.fpu_no_unimplemented
```

The middle term is the whole story: on every LC060 rig this lane uses — `amix-060-lc.uae`,
`f1m3-rigA*-060lc*.uae`, all of which set `fpu_model=0` — that term is false, so `fault_if_60()`
returns without raising anything. The immediate operand is then consumed
(`src/fpp.cpp:1638-1646`, sized from the same `sz1[8] = { 4, 4, 12, 12, 2, 8, 1, 0 }` table the
emulator's source specifier selects), `fault_if_no_fpu()` runs, and the chain
`fpu_op_illg()` → `fp_unimp_instruction_exception_pending()` ends at `Exception(11)`
(`src/fpp.cpp:415`) with a format-`$4` frame built at `src/newcpu_common.cpp:1639-1643`.

**This is a bench-fidelity gap, not a modelling choice that happens to differ.** Real 68LC060
silicon raised vector 60 for these forms three times out of three this round, and Motorola's own
package is written for exactly that: its effective-address handler opens by testing the PCR,
under a comment recording that the FPU may be disabled on entry there, and it carries a whole arm
for the disabled case. An argument that vector 11 is the architecturally correct trap for an
FPU-less part is refuted by the metal measurement and by the existence of that arm. Amiberry's frame builder
already has the format-`$0`-with-arbitrary-vector path this would need
(`src/newcpu_common.cpp:1623-1624`, `nr == 60 || nr == 61` → format `0x0`, giving `0x00F0`), so
closing it is a trigger-condition change, not new frame code — but `fault_if_60()` is shared with
two `fmovem` call sites, so it wants a narrowed check rather than a loosened shared one. That is a
change to another repository and a decision for whoever owns that lane; it is recorded here, not
proposed.

**What follows for this round's verification.** The bed delivers the two 12-byte forms as ordinary
format-4 vector-11 frames, so it exercises the *emulation* half of the fix — v2, v6, v7, v8 and
v12: does the extended immediate produce the right number, does the packed one get refused
visibly, do the five working immediates still work — and it is **structurally unable** to exercise
the *routing* half — v1, v3, v4, v5, v9, v10 — which needs a vector-60 frame it does not produce.
Those are metal rows, and they are why §10's artifact and deploy plan exist rather than a bench
verdict.

The emulation half is additionally taken here without any Amiga at all: see §9.

---

## 9. The emulation half, measured — a host harness, no Amiga in the loop

`test-tools/fpe-harness/` builds the **extracted emulator, unmodified**, for big-endian m68k with
`m68k-linux-gnu-gcc` and drives it under `qemu-m68k` over synthesized exception frames. It links
`build/fpe-src/` behind the same freshness gate the kernel build runs and supplies the same four
primitives the kernel supplies — `ufetch_short`, `copyin`, `copyout`, `panic` — so what it exercises
is the code the kernel ships, on the right endianness and the right pointer width.

It answers the half of this round the bench cannot: *given this frame and these instruction bytes,
what comes out.* It says **nothing** about `src/fpe040.s`, the vector table, the frame the 68060
actually stacks, or AMIX's signal path.

Its first line is the run-time form of the six layout assertions `src/fpe_glue.c` makes at compile
time, because none of the rest means anything if the harness's `struct frame` is not the kernel's:

```
struct frame: tf_sr@68 tf_pc@70 F_u@76 regs[15]@60 fmt4.f_fa@76 fmt4.f_fslw@80
```

**All nine cases matched their registered expectation.**

| case | frame | instruction | ret | advance | result |
|---|---|---|---|---|---|
| T1 | fmt 0, v60 | `fmove.x #1.0,fp0` | 0 | **16** | `fp0 = 3fff0000 80000000 00000000` — exact |
| T2 | fmt 0, v60 | `fadd.x #2.0,fp0` with `fp0 = 1.0` | 0 | **16** | `fp0 = 40000000 c0000000 00000000` = 3.0 — the operand is *used*, not copied |
| T3 | fmt 0, v60 | `fmove.x #pi,fp0` | 0 | **16** | `fp0 = 40000000 c90fdaa2 2168c235` — all 64 mantissa bits exact |
| T4 | fmt 0, v60 | `fmove.p #<packed>,fp0` | −1 | 4 | `ksi_signo = 8`, `ksi_code = 0`, **enabled-and-raised = 0** — the undecodable class, and a 4-byte advance on a 16-byte instruction |
| T5 | fmt 0, v60 | `fmovem.x (a0)+,<dyn list in d1>` | 0 | 4 | `fp0` loaded, `a0` advanced by 12 — supported |
| T6 | fmt 0, v60 | `fmovem.l #imm,fpcr/fpsr` | 0 | **8** | `FPCR = 0x1000` from the *first* longword, **`FPSR = 0`** — the second operand never arrives, and the instruction is 12 bytes |
| T7 | fmt 4, v11 | `fmove.d #3.5,fp0` | 0 | 12 | `fp0 = 40000000 e0000000 00000000` = 3.5 — **the regression row** |
| T8 | fmt 4, v11 | `fmove.x #pi,fp0` | 0 | 16 | exact — this is what the Amiberry bed will deliver (§8.1) |
| T9 | fmt 4, v11 | `fmove.l #1234567,fp0` | 0 | 8 | `fp0 = 40130000 96b43800 00000000` — control |

Five things follow, and each is a claim this document made before the harness existed:

1. **§2 is usable.** A format-0 frame whose PC is the faulting instruction is decoded correctly by
   the emulator with no special case at all — `insn.is_pc = frame->f_pc`, and the resume PC comes
   out of its own decode.
2. **§3's 16 is the emulator's number too.** T1–T3 advance by exactly 16 on the four-word frame,
   independently of Motorola's computation, which is what makes the arm's correctness not depend on
   the package being in the image.
3. **§5.3's packed gap is real and its signature is exactly as described.** T4 aborts with SIGFPE
   and an empty enabled-and-raised set — the input to `fpe_glue.c`'s frozen-decision-8 fallback, so
   the delivered signal will be SIGILL/`ILL_ILLOPC` with `fpe_undecoded_n` counted.
4. **§5.4's rewind is needed, and T4 is the measurement that says so.** The emulator advanced the PC
   by 4 on a 16-byte instruction it never executed. Without the rewind a returning handler resumes
   twelve bytes inside a constant.
5. **§5.2's refusal is justified by measurement, not by reading.** T6 is worse than predicted: not
   only is the advance 8 against a 12-byte instruction, the second control register is not written
   at all — `fpu_upd_excp` runs afterwards and writes back the FPSR it captured on entry. Passing
   that class to the emulator would return success and a wrong FPU state. The arm refuses it.

Run it with `sh test-tools/fpe-harness/run.sh`. It is not part of any kernel build and links
nothing into any kernel.

---

## 10. The artifact, and the deploy/verify plan for the metal session

Built after §1–§9 were committed, on the **same base as the round-7/8/10 lineage**, so the only
thing that differs from the kernel that produced the round-10 deaths is this round's change.

```
sh relink-040-fpe.sh build/unix-040-f7vs build/unix-040-fpe-v60
python3 tools/stamp-card1.py   build/unix-040-fpe-v60 build/unix-040-fpe-v60-CARD1-ced0s1
python3 tools/stamp-cputype.py build/unix-040-fpe-v60-CARD1-ced0s1 \
                               build/unix-060-fpe-v60-CARD1-ced0s1 --set 60
```

| artifact | size | sha256 |
|---|---:|---|
| `build/unix-040-f7vs` *(the base, unchanged since round 7)* | 1,878,585 | `d43a59ccb7df2ebcdf611a7fa322dd84a4c2166fa9d491078025ef4f9e0fa889` |
| `build/unix-040-fpe-v60` | 1,933,225 | `828f6a125855f29a815596d17363e26978e03d8b4d0e4ecff21fe77c5467e9eb` |
| `build/unix-040-fpe-v60-CARD1-ced0s1` | 1,933,225 | `42994d84198333bfc30fe4f888a3dd5af8d99b43cbca3efdcc463c4d9a2097be` |
| **`build/unix-060-fpe-v60-CARD1-ced0s1`** *(stage this)* | 1,933,225 | `17ec956de340b3b9c1bb1b7427f99e2821e537a10dfa15da86edd850b06e6a0d` |
| `build/unix-060-fpe-metal-CARD1-ced0s1` *(the A/B control: the kernel that DIED)* | 1,931,791 | `b34408152d4f5d405bc6f3d47573e203da4d8626b55e424538592886779251e7` |

`buildid` is `" 68040-260827-64"`, announced as **`68060-260827-64`** at `cputype` 60 — one digit
from the round-10 kernel's `68060-260827-61`, so the console line alone says which is booted.

**The A/B control is the round-10 kernel itself**, which is the best control this change could
have: it is the image that produced the three SIGSYS deaths, on the same rig, from the same base.
Round 7's `unix-060-f7vs-CARD1-ced0s1` (`7202172e…`) remains available as the no-FPE control.

### 10.1 Lineage, checked on the artifacts rather than argued from the recipe

```
unix-060-f7vs-CARD1 (base)  ->  unix-060-fpe-v60-CARD1        .text prefix 1,014,192   0 diffs
unix-060-f7vs-CARD1 (base)  ->  unix-060-fpe-metal-CARD1 (r10) .text prefix 1,014,192   0 diffs
unix-060-fpe-metal-CARD1 (r10) -> unix-060-fpe-v60-CARD1
        first .text difference at 0xfe5fd, inside fpe_trap+0x3;  .text 1,043,528 -> 1,043,964
```

Three things follow. The **base kernel is byte-identical** in the deployed round-10 image and in
this candidate — same root-storage family, same Z3660 driver, same campaign instruments. The
**twenty extracted emulator objects are byte-identical too**: they are linked between the base and
the glue, and the first difference of any kind is inside `fpe_trap`. So the entire delta between
"the kernel that died" and "the kernel to boot" is `src/fpe_glue.c` plus `src/fpe040.s` plus two
vector-table relocations — 436 bytes of `.text` and 64 bytes of `.data`.

**No published counter address moved.** Every `fpe_*` `.data` symbol that existed in the round-7
artifact is at the same `.data` offset in this one; the new block is appended after
`fpe_exec_setup_n`, which is the rule `src/fpsp060_glue.s` established for its own M3 and M4
additions. A round-11 dump can reuse every address a round-10 dump used.

### 10.2 Build gates that passed on this artifact

Tarball integrity and the tail-only `fpframe` check; 20/20 emulator objects with `.bss` exactly
396 B; all seven overrides with exactly one strong definition past the base's `.text` end; no
unresolved symbols; `ucp_magic` absent; **`M68Kvec[11] → fpe_vec11` with `fpe_decline → fpsp_vec11`
and `M68Kvec[60] → fpe_vec60` with `fpe_decline60 → fpsp_vec60`**; text/data contiguous; both
section sizes 4-aligned; `check_relink_relocs.py` 0 complaints; `check_fpe_relocs.py` all nine
assertions; the artifact's root-storage family unchanged by the FPE pass.

`FPE=0 sh relink-040-fpe.sh build/unix-040-f7vs …` reproduces the base **byte for byte** — the
script's own sha gate and an independent `cmp` both agree — so the second pass still adds only
what it says it adds.

### 10.3 The probe

`test-tools/fpimm60.c`, the successor to round 10's `fpimm`, which found the defect. Nine forms,
one per invocation, named by `argv[1]` so a refusal names itself:

```
m68k-cbm-sysv4-gcc -O0 -o fpimm60 test-tools/fpimm60.c     # -O0 is mandatory: this compiler
                                                           # constant-folds FP at any -O
```

It has been compiled with the AMIX cross toolchain and disassembled: `f23c 4800` for `x`/`X`,
`f23c 4c00` for `p`, `f218 d810` for `m`, `f23c 9800` for `c`, and the round-10 five unchanged.

| arg | instruction | expected under this kernel | round 10 gave |
|---|---|---|---|
| `l` `s` `w` `d` `b` | the five computable immediates | values, exit 0 — **the regression set** | values, exit 0 |
| `x` | `fmove.x #1.0,fp0` | `1` , exit 0 | **SIGSYS** |
| `X` | `fmove.x #pi,fp0` | `3.1415926535897932`, exit 0 | not run |
| `p` | `fmove.p #2.5,fp0` | **SIGILL (4)** — honest refusal, §5.3 | **SIGSYS** |
| `m` | `fmovem.x (a0)+,dyn(d1)` | `1`, exit 0 | not run |
| `c` | `fmovem.l #imm,fpcr/fpsr` | **SIGILL (4)** — deliberate refusal, §5.2 | not run |

### 10.4 Counters to read, at this artifact's addresses

`load base 0x08000000 + .text size 0xfedfc`, so `.data` begins at `0x080fedfc`. Check
`fpe_magic` = `"FPE!"` and `f60_magic` = `"FP60"` before trusting anything else.

| symbol | `/kpeek` | symbol | `/kpeek` |
|---|---|---|---|
| `fpe_magic` | `0x0811bef4` | `fpe_v60_n` | `0x0811c024` |
| `f60_magic` | `0x081189b0` | `fpe_v60_fmt0_n` | `0x0811c028` |
| `fpe_entry_n` | `0x0811bf34` | `fpe_v60_fmtx_n` | `0x0811c02c` |
| `fpe_done_n` | `0x0811bf54` | `fpe_v60_last_fmtvec` | `0x0811c030` |
| `fpe_sig_n` | `0x0811bf58` | `fpe_v60_decl_n` | `0x0811c034` |
| `fpe_undecoded_n` | `0x0811bf80` | `fpe_ea_n` | `0x0811c038` |
| `fpe_advmiss_n` | `0x0811bfe4` | `fpe_ea_super_n` | `0x0811c03c` |
| `fpe_advnofetch_n` | `0x0811bfec` | `fpe_ea_imm_n` | `0x0811c040` |
| `fpe_super_n` | `0x0811bf4c` | `fpe_ea_pack_n` | `0x0811c044` |
| `fpe_user_n` | `0x0811bf50` | `fpe_ea_fmovmx_n` | `0x0811c048` |
| `fpe_last_signo` | `0x0811bf6c` | `fpe_ea_fmovml_n` | `0x0811c04c` |
| `fpe_last_code` | `0x0811bf70` | `fpe_ea_fetchfail_n` | `0x0811c050` |
| `fpe_last_fault_pc` | `0x0811bf7c` | `fpe_ea_done_n` | `0x0811c054` |
| `f60_entry_n` | `0x081189b4` | `fpe_ea_sig_n` | `0x0811c058` |
| `f60_effadd_n` | `0x081189f4` | `fpe_ea_last_op` | `0x0811c05c` |
| `f60_fpudis_nofpu_n` | `0x08118a2c` | `fpe_rewind_n` | `0x0811c060` |

### 10.5 The run, and the rows it settles

1. Sample every counter above **before** the probe set, at multiuser. Expect the whole
   `fpe_v60_*`/`fpe_ea_*` block at its initialiser and `f60_entry_n = 0`: nothing in the boot
   should execute one of these forms.
2. `fpimm60 d`, `fpimm60 l`, `fpimm60 s`, `fpimm60 w`, `fpimm60 b` — **the regression set, first**.
   Values correct, exit 0, `fpe_v60_n` **unmoved**, `fpe_entry_n`/`fpe_done_n` moving together.
   That is v6, v7 and v12.
3. `fpimm60 x`, `fpimm60 X` — the fix. Values correct, exit 0. `fpe_v60_n` +2, `fpe_v60_fmt0_n`
   +2, `fpe_ea_n` +2, `fpe_ea_imm_n` +2, `fpe_ea_done_n` +2, `fpe_ea_sig_n` **0**, `f60_entry_n`
   still **0** — the arm sits ahead of the package, so a handled event never reaches it. v1, v2,
   v3, v4.
4. `fpimm60 m` — `fpe_ea_fmovmx_n` +1, `fpe_ea_done_n` +1, value correct. v9.
5. `fpimm60 p` — **SIGILL, not SIGSYS**. `fpe_ea_pack_n` +1, `fpe_ea_sig_n` +1,
   `fpe_undecoded_n` +1, `fpe_rewind_n` +1, `fpe_last_signo` = 4, `fpe_last_code` = 1. v8.
6. `fpimm60 c` — **SIGILL**. `fpe_ea_fmovml_n` +1, `fpe_ea_sig_n` +1, and `fpe_undecoded_n`
   **unmoved** (this refusal is the glue's, not the emulator's). v10.
7. Re-read the whole block and check the two closing identities by arithmetic:
   `fpe_v60_n == fpe_ea_n + fpe_v60_decl_n` and `fpe_ea_n == fpe_ea_done_n + fpe_ea_sig_n`. v3.
8. Read `f60_entry_n`, `f60_effadd_n`, `f60_done_n`, `f60_fpudis_nofpu_n`. **All four should be
   0** for the whole session — that is the sharpest single statement this round can make, because
   round 10 read 3, 3, 0, 3 on exactly these probes.

**Falsification.** If `fpe_v60_fmtx_n` is non-zero, §2's frame claim is wrong and
`fpe_v60_last_fmtvec` names what the 68060 really stacks — the arm will have declined and the
box will behave exactly as it did in round 10, which is what makes that a survivable way to be
wrong. If `fpe_v60_n` stays 0 while the probes still die, the vector-table retarget did not take
and `check_fpe_relocs.py` assertion 8 was passed on a different image than the one booted.

---

## 11. Carried forward, and what this round deliberately did not do

* **Packed decimal is not implemented.** §5.3 says why, what it would cost, and what the metal
  evidence says about urgency. The gap is now counted rather than silent.
* **`fmovem.l` with 2 or 3 control registers is refused, not emulated.** §5.2. Fixing it means
  editing the vendored tree, which is out of bounds; the alternative — teaching the glue to
  pre-decode that one form — is a round of its own and would want a probe on metal first.
* **The `fpe_advmiss_n` rate question is untouched.** Round 10 measured 28.1 % against round 8's
  0.030 % and it is a workload property until someone measures it as a subject. The only change
  here is the format-4 gate that keeps the instrument meaning what it says once format-0 frames can
  reach `fpe_trap` at all.
* **No opword census was added.** `fpe_ea_last_op` latches the last one; the four class counters
  answer the question that matters, and a histogram would answer one nobody has.
* **The M68060 User's Manual is still not on this machine.** §2's frame claim rests on Motorola's
  own package source, on the emulator's header, and on a `vector 0xF0` this port printed from real
  silicon. If the manual is ever consulted, the sentence to look for is what it promises about the
  vector-60 frame's format nibble; `fpe_v60_fmtx_n` is the counter that would catch it being
  something else, and the arm declines rather than guesses in that case.
