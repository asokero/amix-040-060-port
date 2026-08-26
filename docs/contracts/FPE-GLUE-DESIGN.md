# NetBSD/m68k FPE glue — the design, pre-registered

Round 2 of the soft-FPU lane: **the glue and the build, and nothing that runs.** No bench run,
no metal, no boot — round 3 is the ladder. The finish line here is a kernel that links green
with every assertion passing, and a written argument for each mechanism that is strong enough
to be attacked in round 3 rather than discovered there.

This document is committed **before** any glue code. Where it says a number, the number is
measured in this round against `build/unix-040` and the pinned tarball; where it predicts one,
it says so and names the round-3 reading that will confirm or refute it.

> **PROVENANCE.** Sections 4, 5, 6 and 7 are structural analysis of the stock AMIX kernel image
> this port patches — disassembled bodies, u-area offsets, per-site relocation censuses —
> measured from `build/unix-040` and cited by address. The NetBSD emulator is described by file,
> line and mechanism; no vendor text is reproduced. Same class as
> `docs/contracts/FPE-INTEGRATION-CONTRACT.md` and the ATT7/ATT8 results.

The normative inputs are `docs/contracts/FPE-INTEGRATION-CONTRACT.md` (round 1: the AMIX side
of the seam, measured) and `docs/contracts/FPSP-INTEGRATION-PLAN.md` (the ureturn recipe, the
memory-access ABI, and the mandatory copy-error rule). Where this document differs from the
contract it says so out loud, in §3, with the measurement.

---

## 1. The frozen decisions this implements

Grilled 2026-08-26 and recorded in the contract's preamble; restated here only as a checklist,
with the section that discharges each.

| | Decision | Discharged in |
|---|---|---|
| 1 | Full transparent in-kernel emulation | §4.4, §5 |
| 2 | Full SIGFPE wiring with derived SVR4 si_codes | §5.2 |
| 3 | Cross-built `.o` artifacts | §8 |
| 4 | Contract / **glue** / bench ladder | this document is round 2 |
| 5 | Extracted at build time from the pinned tarball; nothing third-party checked in | §2, §8.5 |
| 6 | Three-armed dispatch; the full-060 060SP arm stays a never-engage stub | §4.5 |
| 7 | Regression bar = behavioural + `fpe_entry_n == 0` wherever an FPU exists | §9 |
| 8 | Never panic for userland: SIGILL + latched counter; supervisor F-line loud | §4.2 |
| 9 | `fpu_emul` as a second flag; full presentation; 68881-idle shape | §6 |
| 10 | Attach at the top of `fpsp_vec11`, format nibble first | §4.5 |

---

## 2. What is built, and the boundary that must not move

```text
build/fpe-src/               EXTRACTED, never checked in.  25 files + 4 machine-ABI headers
                             out of the pinned tarball, byte-identical to it, and
                             src/extract_fpe.sh proves that on every build by diffing against
                             a second fresh extraction.
build/fpe-src/include/m68k/  cpuframe.h, fpreg.h, ieee.h        } the machine-ABI set, same
build/fpe-src/include/sys/   ieee754.h                          } tarball, same gate
src/fpe-compat/              FIRST-PARTY.  Everything AMIX does not have, and the two places
                             NetBSD's headers collide with AMIX's.  Never mixed into the
                             extracted tree.
src/fpe_glue.c               FIRST-PARTY.  Frame shim, entry lock, interposed panic/copy,
                             si_code derivation, signal delivery.
src/fpe040.s                 FIRST-PARTY.  The vector-11 arm, the FP-state presentation, the
                             non-local exit, the counters — and the .balign 4 that closes the
                             link, which is why it is linked LAST.
relink-040-fpe.sh            The build, as a second pass over relink-040.sh's finished output.
src/patch_fpe_vec11.py       Two relocation retargets: the vector, and the arm's own decline.
src/extract_fpe.sh           Extraction, the freshness gate, and the fpframe tail-only gate.
src/check_fpe_relocs.py      The lane's relink assertions.
src/mk_fpe_cc.py             The temporary toolchain duplication (§8.2).
```

**The include order is forced, not chosen.** The cross-gcc wrapper prepends
`-I$sysroot/usr/include` ahead of every command-line `-I` (`src/mk_modelb_sysroot.sh:5-9`), so a
shim can never shadow an AMIX header. Every MI header the emulator includes — `sys/types.h`,
`sys/param.h`, `sys/systm.h`, `sys/signal.h`, `sys/siginfo.h`, `sys/time.h`, `float.h`,
`stdio.h`, `stdlib.h`, `string.h` — is **AMIX's own**, and there is no way to make it otherwise.
What the two `-I` directories add is only what AMIX lacks, with `src/fpe-compat` **first** so
that its `m68k/m68k.h` shadows the NetBSD one (§4.3).

**The boundary rule.** A first-party stub that drifts into `build/fpe-src/` is how a "never
edited" tree quietly stops being one, so `extract_fpe.sh` fails on a file present on only one
side exactly as it fails on an edited one, and separately refuses any non-tarball file under
`build/fpe-src/include/`.

---

## 3. Three corrections this round produced

The contract governs where it and older documents disagree. These are places where **this
round's measurements correct the contract**, and each changes something.

### 3.1 `fpu_calcea.c`'s `cputype` read is dead code, and so is the whole frame-EA path

Contract §3.7 item 3 and §7.2 class C treat `fpu_calcea.c:118`'s `cputype == CPU_68060` as a
live read, and §3.7 item 3 concludes that "on an LC060 that is the normal path, so
`f_fmt4.f_fa` (+8) is live and must not be clobbered before `fpu_emulate()` runs."

Measured: `fpu_calcea.c:103` opens `#if 0 /* XXX */` and `:125` closes it. **Everything between
is compiled out** — the `EA_FRAME_EA` assignment at `:106`, the `ea_fea` load from
`frame->f_fmt4.f_fa` at `:107`, and the `cputype` comparison at `:118`. `EA_FRAME_EA` is
therefore never *set*; the two places that test it (`:319`, `:464`) can never be true; and
`f_fmt4.f_fa` is never read by the emulator at all. The only format-4 field the emulator
consumes is `f_fslw` at +12, at `fpu_emulate.c:124`.

Three consequences:

* the effective address is always decoded from the instruction stream, including the
  postincrement and predecrement writebacks, which for a format-4 frame is correct because the
  faulting instruction did not execute and has no partial side effects;
* `f_fea` (+8) is carried across the shim anyway (§4.4) because carrying it costs one move and
  a future vendor import may enable that block, but nothing depends on it today;
* **the semantic half of the `cputype` collision is not reachable.** The compile failure the
  contract found is real and is entirely the *declaration* clash between NetBSD's
  `extern int cputype` and AMIX's `extern short cputype`. §4.3 fixes both halves anyway, and
  says why.

### 3.2 `_exop[3]` is not an opportunity; it is not in the structure the kernel carries

Contract §3.3 records `sys/siginfo.h:132`'s `long _exop[3]` as available and unpopulated, "the
natural place" for the exceptional operand, and the dispatch calls populating it optional.

Measured: `_exop[3]` is a member of the **user-visible** `siginfo_t` (`sys/siginfo.h:132`). The
kernel-side `k_siginfo_t` at `:150-183` — the 28-byte structure `u_trap` builds, `trapsig`
queues and this glue must produce — has `_fault { caddr_t _addr; }` and **no `_exop` at all**.
There is nowhere in the kernel's own structure to put it, so this is not a cheap addition but a
structure change, and it is dropped rather than deferred. (Independently, the exceptional
operand lives in `fpu_emulate.c`'s file-static `fe`, which the emulator code does not export
and which may not be edited to make it do so.)

### 3.3 The mandatory copy-error rule cannot be satisfied inside the emulator code

`FPSP-INTEGRATION-PLAN.md:350-367` requires that a nonzero `copyin`/`copyout` never be ignored.
Measured: `fpu_calcea.c` calls them six times — `:330`, `:378`, `:413`, `:475`, `:491`, `:533` —
and **ignores the return at every one**. Since no extracted byte may change, the rule can only be
kept on the glue's side of the call, and the check has to be followed by a **non-local** abort
because the caller is about to use the buffer regardless. §4.2's unwind is what makes that
possible; it is the same mechanism the panic interposition needs, which is why there is one
mechanism and not two.

---

## 4. The four mechanisms

### 4.1 Reentrancy — DECIDED: serialise entry to `fpu_emulate()` with a sleep-lock

**The hazard, stated exactly.** `fpu_emulate()` keeps its per-invocation state in `static`
objects rather than on the stack (`fpu_emulate.c:89-90` gives its one `instruction` object and
its one `fpemu` object `static` storage). A `copyin` inside `fpu_load_ea` may sleep; `swtch` may
then run another process; a second vector-11 entry overwrites the first process's emulator
state; the
first process resumes and finishes an instruction using another process's operands.
`FPSP-INTEGRATION-PLAN.md:369-380` spells the ownership boundary out for the FPSP, and the
contract's §7.3 notes it applies *more* sharply here because here the shared state has no owner
at all.

**The measurement that decides it.** The dispatch asks first what `fpu_log`'s 188 bytes and
`fpu_rem`'s 60 bytes of `.bss` actually are — because lazily-built constant tables would have
different lifetime needs from `insn`/`fe`. They are not tables:

| File | `.bss` | What it is |
|---|---:|---|
| `fpu_emulate.c` | 148 | one `instruction` and one `fpemu` object, both `static`, at `:89-90` |
| `fpu_log.c` | 188 | six `static` `fpn` objects at `:199`, **inside `__fpu_logn`** |
| `fpu_rem.c` | 60 | two `static` `fpn` objects at `:105`, **inside `__fpu_modrem`** |

All three are function-local statics holding **live intermediate values of the computation in
progress**. `fpu_log.c`'s constant tables are the `logA*`/`logB*` arrays at `:42-53`, which are
initialised and therefore in `.data` (1,624 bytes), not `.bss`. So the hazard is not 148 bytes;
it is all 396, spread over three files, and it is per-invocation state in every one.

**Why the other two candidate shapes are refused.**

* *Per-file `-D` tricks to relocate the static state.* There is nothing to relocate to. The
  objects are **function-local** statics: `-Dinsn=<anything>` rewrites the declaration
  `static struct instruction insn;` into a syntax error, and there is no declaration-free
  spelling that gives them per-process storage without editing the file.
* *Glue-level save/restore of the state around possible sleeps.* The sleeps are **inside** the
  emulator, so the glue can only bracket the whole call — and that is provably insufficient.
  Save-on-entry/restore-on-exit is correct only if the interleaving is strictly LIFO in
  *resumption* order, and it is not: A sleeps holding state S(A); B enters, saves S(A) to B's
  kernel stack, works, sleeps holding S(B); A wakes and continues over S(B). A's state was
  saved, but by B, and A has no way to get it back. The trick that works for a nested
  interrupt does not work for two sleepers.

**The decision.** One process at a time inside `fpu_emulate()`, enforced by a binary lock in
`.data` (`fpe_busy`) with `sleep`/`wakeup`:

```c
	while (fpe_busy) { fpe_lock_wait_n++; sleep((caddr_t)&fpe_busy, 25); }
	fpe_busy = 1;
	... fpu_emulate() ...
	fpe_busy = 0;  wakeup((caddr_t)&fpe_busy);
```

Test-then-sleep is atomic enough here because this kernel is uniprocessor and non-preemptive
between sleep points, and nothing between the test and the `sleep` can sleep — the classic SVR4
shape. The priority is **25**, measured rather than assumed: `sleep`'s own body at `0x4868c`
reads `moveq #127,%d0 / andl %d5,%d0 / moveq #25,%d1 / cmpl %d0,%d1 / bge <no signal catch>`, so
PZERO is 25 and a priority whose low seven bits are ≤ 25 sleeps uninterruptibly. Uninterruptible
is what this lock wants: the wait is bounded by one emulated instruction in another process, and
a sleep that could return early would need an unwind path for a lock already held.

**The three things the lock also buys**, which is why it is the *cheapest* answer and not merely
the correct one: the abort state in `fpe_glue.c` (`fpe_abort_signo/code/addr`, `fpe_cur`) and the
`jmp_buf` in `fpe040.s` are reachable only from inside the emulator, so the same lock makes them
safe as statics; and the supervisor arm declines outright (§4.5), so the lock can never be taken
from interrupt context and cannot deadlock against one.

**The one thing it costs.** "FP traps are rare" is *false in this lane* — under full emulation
every FP instruction traps — so the uncontended acquire/release is on the hot path. It is two
memory accesses. Contention is the interesting number and it is instrumented rather than
argued: `fpe_lock_wait_n` counts entries that actually had to sleep.

**Round-3 verification.** `fpe_lock_wait_n` over a multi-process FP load. The registered
reading is that it is small but **non-zero** under a workload with paged-out operands, and that
`fpe_busy` is 0 at every quiescent observation. A `fpe_lock_wait_n` of exactly 0 across a
deliberately concurrent run does not vindicate the lock — it means the sleeping path was not
exercised and the test needs a page-out, which is the ladder rung the contract's §7.3 already
asks for ("private the state per process, serialise entry, or prove the sleeping path
unreachable" — this is the middle option, and the counter is what stops it being the third by
accident).

### 4.2 Panic interposition — DECIDED: `-Dpanic=fpe_panic`, unwinding through a private setjmp

**The surface.** Eleven `panic()` call sites in the extracted tree — `fpu_add.c:192`,
`fpu_calcea.c:78/:308/:449`, `fpu_explode.c:255`, `fpu_fmovecr.c:81`, `fpu_fscale.c:319`,
`fpu_implode.c:301/:482`, `fpu_subr.c:91/:102` — three of which use `__func__` with `%s`
formatting. Frozen decision 8: user-process origin becomes SIGILL plus a latched counter and one
console line, never a kernel panic; supervisor-origin F-line stays loud.

**The mechanism.** The emulator files are compiled with `-Dpanic=fpe_panic`. This is a
per-compilation `-D` rather than a link-time trick because `panic` is a name the whole kernel
shares: a strong override would redirect every panic in the system.

**The hard part is the return, and it is designed rather than hoped for.** Emulator code calls
`panic()` as a no-return primitive — `fpu_subr.c:91` and `:102` fall off the end of a `switch`
afterwards, `fpu_calcea.c:78` likewise — so returning normally would resume that code with an
undefined result and no diagnostic. The kernel exports no `setjmp`, so the glue carries its own:
`fpe_setjmp`/`fpe_longjmp` in `src/fpe040.s`, a 13-longword buffer holding the return address,
the entry SP, and `d2-d7/a2-a6`. That is exactly the callee-saved set of this ABI, which is what
makes it safe for the C caller: any local that is not in one of those registers is already
reloaded from a stack slot across an ordinary call, and no local in `fpe_trap` is written between
the `fpe_setjmp` and a possible `fpe_longjmp`.

`fpe_trap` establishes the target immediately around the emulator call and takes it down again
straight after, and `fpe_jb_active` says whether it is live:

```c
	if (fpe_setjmp(fpe_jb) == 0) { fpe_jb_active = 1; r = fpu_emulate(&f, fpf, &ksi); }
	else                         { r = -1; ksi <- the abort verdict; }
	fpe_jb_active = 0;
```

`fpe_panic` therefore has a defined behaviour in both worlds, and the second one is decision 8's
"supervisor F-line stays loud" expressed as code rather than as a rule: **if `fpe_jb_active` is
0 the call did not come from inside the emulator, so decision 8 does not apply and the kernel's
own `panic` runs**, with `fpe_panic_hard_n` recording that it did.

The message is a real format string with real arguments (three sites need it), passed through as
four longs — K&R varargs on m68k SysV puts every argument on the stack, so four covers every
site. **One console line, not one per event**: this path is reachable once per emulated
instruction, and an unthrottled `printf` would bury the console and change the timing of the very
thing being measured. `fpe_panic_n` counts the rest.

**The same mechanism discharges §3.3.** `-Dcopyin=fpe_copyin` / `-Dcopyout=fpe_copyout` wrap the
six unchecked calls; on failure the wrapper latches the address, counts it, and unwinds with a
SIGSEGV/`SEGV_ACCERR` verdict. That satisfies all five clauses of
`FPSP-INTEGRATION-PLAN.md:350-367` together, including the last one — "does not advance the
emulated PC as if the instruction succeeded" — because the advance at `fpu_emulate.c:217-218` is
simply never reached.

`ufetch_short` deliberately does **not** unwind: all sixteen of its callers already test the
return and abort correctly (`fpu_emulate.c:128`, `:147`, with `SIGSEGV`/`SEGV_ACCERR`). Where the
emulator code is already right, the glue stays out of its way and only counts.

**Round-3 verification.** `fpe_panic_n` and `fpe_panic_hard_n` must both read 0 on every clean
run — a panic site in the emulator is an inconsistency, not an expected event. The path is
exercised deliberately instead: a test that hands the emulator an operand address in an unmapped
page must produce `fpe_copyfail_n` +1, one SIGSEGV with `si_code` `SEGV_ACCERR`, `fpe_fault_addr`
equal to the address used, and **no PC advance** — the process must fault on the same instruction
if the handler returns.

### 4.3 The `cputype` collision — DECIDED: a shadow header plus a glue-owned `int`

**The compile half.** NetBSD `m68k/m68k.h:60` declares `extern int cputype`; AMIX
`sys/systm.h:18` declares `extern short cputype`; `fpu_calcea.c` includes `<sys/systm.h>` at
`:40` and `<m68k/m68k.h>` at `:42`. gcc reports `conflicting types for 'cputype'` and this is the
only hard compile failure in the package.

**The fix, and why not `-Dcputype=fpe_cputype`.** A command-line `-D` rewrites the token in
*every* translation unit, AMIX's own `<sys/systm.h>` declaration included, which turns the
collision into `extern short fpe_cputype` versus `extern int fpe_cputype` and merely moves the
failure. So the redirection lives in `src/fpe-compat/m68k/m68k.h`, a **first-party header that
shadows** the NetBSD one (it is earlier on the include path) and supplies only the two things
`fpu_calcea.c` takes from that file:

```c
	extern int fpe_cputype;
	#define cputype fpe_cputype
	#define CPU_68020 0 ... #define CPU_68060 3
```

That confines the rewrite to the one file that includes it, and to the point *after*
`<sys/systm.h>` has already been parsed. It also means NetBSD's `m68k/m68k.h` is not used at
all — it would be dead weight with a live trap in it.

**The semantic half, explicitly.** `fpe_cputype` is a glue-owned `long` in `src/fpe040.s`
carrying **NetBSD's** encoding: `CPU_68040` = 2, `CPU_68060` = 3, against AMIX's 40 and 60. It is
written in two places — `fpuinit` sets it when the lane arms, and `fpe_trap` refreshes it on
every entry from AMIX's `cputype`, which costs three instructions and removes any question about
a boot-time write staying true.

**And it is maintained even though §3.1 shows the read is dead code.** "The compiler cannot
reach it today" is not a property to build on: the block is `#if 0`, not deleted, and a future
vendor import or a decision to enable the frame-EA path would make it live in a single line. A
lane whose correctness depends on a `#if 0` staying closed is one edit from a plausible wrong
answer, which is the failure class this port has paid for repeatedly.

**Round-3 verification.** Read `fpe_cputype` from the booted image: 3 on the LC060 rig, 2 on the
040 rig — and on the 040 rig it must be 2 *only if the lane armed*, which it will not, so the
real reading is that `fpe_cputype` keeps its initialiser and `fpe_armed` is 0.

### 4.4 The `struct frame` shim — DECIDED: build a NetBSD-shaped frame in C, with the layout asserted at compile time

**The difference.** AMIX's trap block is **fifteen** registers — D0-D7 then A0-A6 — with A7
living outside it as the USP pseudo-register at `u_ar0` (contract §3.1; `src/fpsp_glue040.s:209-213`
builds it from the other side). NetBSD's `tf_regs[16]` wants A7 at index 15. A `struct frame *`
handed to `fpu_emulate()` therefore cannot point at the AMIX block: `f_regs[15]` would read the
exception SR.

**The decision, and why it is C.** The glue builds a `struct frame` on its own kernel stack and
splices the USP into `f_regs[15]`. The layout is NetBSD's `__attribute__((packed))` trapframe: a
2-byte-aligned `tf_pc` at offset **70** and a 4-bit/12-bit bitfield at **74**. Hand-computed
offsets for that are a defect waiting to happen and the offsets are exactly what the compiler
already knows, so the shim is expressed as the struct it is — which is also the only reason there
is any C in this lane at all. The machine-level work stays in `src/fpe040.s`.

**What is asserted rather than assumed.** If this gcc silently ignored `packed`, `tf_pc` would
land at 72 and every field written after it would be two bytes out, with no diagnostic anywhere.
So `src/fpe_glue.c` carries negative-array-size assertions in the idiom
`src/modelb_geom_probe.c` already uses on this compiler:

```text
	F_t.tf_sr == 68     F_t.tf_pc == 70     F_u == 76     F_t.tf_regs[15] == 60
	F_u.F_fmt4.f_fa == 76                   F_u.F_fmt4.f_fslw == 80
	fpf_fpcr - fpf_regs == 96   fpf_fpsr - fpf_regs == 100   fpf_fpiar - fpf_regs == 104
	sizeof(fpu_t) == 108        fpu_info.regs == 4           fpu_info.fsave == 112
	sizeof(k_siginfo_t) == 28
```

The instrument is verified, not just written: changing the `tf_pc` assertion to 72 makes the
compile fail with `size of array 'fpe_as_tfpc' is negative` and the line number.

**Carried across, both ways.** SR, the format/vector word and the format-4 tail (`f_fea` at +8,
`f_pcfi` at +12) are read into the shim and the tail is left **unclobbered** in the real frame.
`f_pcfi` is what `fpu_emulate.c:108-125` takes the faulting instruction's address from, and it is
the whole reason the arm sits at the top of the vector (contract §6.3). `f_fea` is carried
although §3.1 shows nothing reads it — one move, and the alternative is a shim that silently
stops being faithful the day that block is enabled.

**Written back:** the fifteen registers, A7 through the pseudo-register slot, and the final PC.
**No second PC adjustment**, and this is the one place where doing the obvious thing twice is the
bug: the emulator advances `f_pc` itself, including its own one-shot format-4 reconstruction from
`f_pcfi`, and the top-of-vector attach point guarantees that runs exactly once. SR is not written
back because no FP instruction writes the integer condition codes — and the extracted tree touches
neither `f_sr` nor `f_stackadj`, which is checked by grep rather than assumed. The frame stays an
eight-word format-4 frame and the RTE at the end of `ureturn` pops sixteen bytes.

**A free consistency check falls out of the shim, and it is the most valuable instrument in the
round.** On a format-4 frame the CPU stacks the PC of the instruction *after* the faulting one,
while the emulator independently computes `f_pcfi + insn.is_advance`. **The two must be equal.**
Contract §6.3 names a wrong `is_advance` as the sharpest standing risk in the package — NetBSD's
own comment calls the format-4 path a hack, because it presumes the emulator knows the length of
every instruction it will meet, and on an LC060 that is not a corner case but the only path. The
shim compares them on every emulated instruction for the cost of one compare, counts
`fpe_advmiss_n`, and latches the first disagreement as (`fpe_b_pc`, `fpe_b_stacked`,
`fpe_b_resume`). **Nothing is acted on**: the emulator's PC is used either way, so the instrument
cannot change what the lane does. This turns the contract's "round 3 must test instruction-length
correctness directly" from a test to design into a number the first boot already carries.

**Round-3 verification.** `fpe_advmiss_n == 0` over a full FP workload, and if it is not, the
latch names the exact instruction. This is the primary acceptance number of round 3 alongside
correctness of results.

### 4.5 The arm itself — attach point, dispatch and decline

Frozen decision 10 puts the `fpu_present` test at the **top of vector 11, before any `cputype`
test**, and the contract's §6.1 makes that a measurement rather than an argument: on real A4000 +
Z3660 68LC060 silicon, `f60_entry_n = f60_fpudis_n = f60_fpudis_nofpu_n = 5,406` with
`f60_fline_n = 0` (`ATT5:252`). Every vector-11 event took the FP-disabled arm; an arm placed on
the stock 040 path or at `Lco_fline` would never execute.

**Installed as a vector retarget, not as a source edit.** `M68Kvec[11]` is retargeted from
`fpsp_vec11` to `fpe_vec11`, which is the mechanism `src/patch_fpsp_vec11.py` already uses one
layer in. So `relink-040.sh` does not move, `src/fpsp_glue040.s` does not move, and an FPE kernel
is one extra pass over a normal one rather than a second configuration of the first.

**Declining means the byte-for-byte prior path.** `fpe_decline` is a single `jmp nullvect` whose
own relocation `patch_fpe_vec11.py` retargets to whatever `M68Kvec[11]` held — `fpsp_vec11`
normally, `nullvect` on an `FPSP=0` base. `src/fpe040.s` cannot name either without risking a
jump to a symbol that is not linked (the hazard `src/fpsp_glue040.s:51-56` records for the 060
branch), so it names the always-resolvable one and the patcher points it at the truth. The
patcher applies the two retargets in that order, so a half-applied patch leaves a kernel that
still works rather than one whose decline path is a lie, and `check_fpe_relocs.py` refuses a
`fpe_decline` that names `fpe_vec11` — a decline that looped back into the arm would be an
unbreakable loop on the first bad F-line word in the system.

**Format nibble first.** Three frame shapes reach vector 11 and the nibble is the only thing that
separates them (contract §6.2):

| fmt/vec word | shape | disposition |
|---|---|---|
| `0x402c` | eight-word format 4, 68060 FP disabled | **ours.** Every real LC060 event. |
| `0x202c` | six-word format 2, 68040 unimplemented FP | counted, declined. The documented third arm; not implemented this round. |
| `0x002c` | four-word format 0, genuine bad F-line word | counted, declined. **SIGSYS, unchanged.** |
| anything else | — | counted with its word latched, declined. Must stay 0. |

Format 0 is the one that has to be argued rather than merely coded. Handing it to the emulator
would *work* — the emulator would fetch the opword from the stacked PC, which is correct for a
format-0 frame, and abort with `SIGILL`/`ILL_ILLOPC` — and would thereby convert SIGSYS to SIGILL
for **every bad F-line word in the system**. That is a user-visible ABI change and
`FPSP-INTEGRATION-PLAN.md:243-248` forbids it. It is refused here, not merely avoided.

Format 2 is decision 6's third arm and stays a documented never-engage case this round. Contract
§8 item 2 is honest that the format-2/`0x202c` pairing rests on Motorola's `x_fline.sa` and has
not been latched from a real 68040 frame in this tree; `fpe_fmt2_n` is the counter that will latch
it the first time an 040 rig runs this kernel, which is a cheaper way to close that gap than
building the arm before anything has been seen.

**Supervisor origin declines.** The S bit of the stacked SR is tested before anything is pushed;
a supervisor-origin FP instruction on a part with no FPU is a kernel defect, and frozen decision 8
keeps it loud — it takes the same decline, the same S-bit dispatch and the same `k_trap` it takes
today. `fpe_super_n` must stay 0. This also removes the emulator from interrupt context entirely,
which is what makes §4.1's lock deadlock-free.

**Register discipline.** Everything before the user arm is memory-to-memory or memory-immediate:
CCR is the only thing any of it changes, and both `nullvect` and `rte` reload SR from the frame.
This is the rule `src/fpsp060_glue.s` records at length after M2a broke it by writing a slot id
into `%d0`.

**Completion reproduces the `ureturn` recipe** (`FPSP-INTEGRATION-PLAN.md:281-324`), in the shape
`src/fpsp_glue040.s:202-219` and `src/fpsp060_glue.s:216-235` already use and hardware has already
accepted: push the 60-byte block exactly as `nullvect` does, install `sup_cacr`, push USP as the
pseudo-register, set `u.u_ar0` to it, then — after the emulation — reload USP from the slot and
`jmp ureturn`. `u_ar0` is set **before** the call, not after, because the emulation may sleep and
be context-switched, and anything that looks at this process while it is off the CPU must find it
already correct.

---

## 5. Signal delivery

### 5.1 The shape: the glue builds the `k_siginfo_t`

Contract §5.3 lays out the choice. The cheap wiring — leave the raw frame alone and `jmp
nullvect`, letting `u_trap`'s own arm build the structure from the frame's vector — costs nothing
and cannot drift from stock policy, but it cannot express what the emulator knows: on an LC060 the
exception did not *arrive* on vectors 48-55 at all, it arrived on vector 11, whose arm is SIGSYS.

So frozen decision 2 forces the other shape, and this is the one implemented:
`src/wb040.s:449-472` (`Lu_siginfo`) is the in-repo template for the field layout, and `trapsig`
is the entry point into the existing policy. The 28-byte kernel structure and its offsets are
`u_trap`'s own, read out of the binary: `si_signo` +0, `si_code` +4, `si_errno` +8, `si_addr` +12,
with `bzero(&si, 28)` first exactly as `u_trap` does at `0x5a4a2`. The process pointer is
`curproc`, and `trapsig` is file-local in stock (`t` at `0x59f7a`), so the build globalizes it.

### 5.2 The derivation, and what it is finer than

The emulator emits **`si_code` 0 for every arithmetic signal** (`fpu_emulate.c:237-238`),
so the code is derived from the state `fpu_upd_excp()` left behind: it wrote the final FPSR back
into `fpf_fpsr` and returned SIGFPE precisely because `(fpsr & fpcr & FPSR_EXCP)` was non-empty,
so the enabled-and-raised set is still there when the glue regains control.

| FPSR bit | SVR4 `si_code` |
|---|---|
| `FPSR_BSUN` / `FPSR_SNAN` / `FPSR_OPERR` | `FPE_FLTINV` 7 |
| `FPSR_OVFL` | `FPE_FLTOVF` 4 |
| `FPSR_UNFL` | `FPE_FLTUND` 5 |
| `FPSR_DZ` | `FPE_FLTDIV` 3 |
| `FPSR_INEX1` / `FPSR_INEX2` | `FPE_FLTRES` 6 |

Tested in that order, which is Motorola's exception priority, highest first: more than one bit can
be set at once and only one code can be delivered.

**Stated precisely, because the contract's wording invites a stronger claim than the facts
support.** This derivation is *not* finer in its code set than stock: `u_trap`'s own table
(contract §5.2) reaches exactly these five codes, and its vectors 48, 52, 54 and 55 all share one
arm and `FPE_FLTINV` because **SVR4 has no finer name for an invalid operation**. What is finer
is *which events get a code at all*: on a 68LC060 none of vectors 48-55 is ever raised, every FP
exception arrives on vector 11, and stock's answer there is SIGSYS/4. Deriving the code is what
turns that into the SIGFPE a program expects. The divergence from stock is therefore deliberate
and total — SIGSYS becomes SIGFPE — rather than a matter of granularity, and §9 registers the
behavioural comparison that has to be run against a real-FPU rig to prove the codes agree.

`si_addr` needs no special handling and that is worth recording: the emulator sets
`ksi_addr = frame->f_pc`, and at the SIGFPE abort (`:238`) that is *after* the PC advance at
`:217-218`, i.e. the instruction after the faulting one — which is exactly what `u_trap` produces
on a real FPU, where it presets `si_addr` to the stacked PC and a real FP exception frame also
carries the next instruction. The two agree without being made to.

**Undecodable is decision 8's fallback, not a guess.** A SIGFPE whose enabled-and-raised set is
empty has no honest SVR4 code; inventing one would be worse than saying so. It becomes SIGILL /
`ILL_ILLOPC` with `fpe_undecoded_n` counting it.

### 5.3 What policy is reached, and what is not — registered as divergence

`u_trap`'s tail, decoded from `0x5a89a` onward, is: a three-condition gate on the proc structure,
then `if (issig(0)) psig();`, then `ev_istrap`/`ev_traptousr`, then `addupc`. Before it, at
`0x5a7f8`, `stop_on_fault` runs when the /proc fault class is non-zero and the signal is not
SIGKILL.

`s_trap` — which `ureturn` calls on the way out (`0x124c`) — was decoded for this document and
**has no `issig`/`psig` loop**: its relocations are `u_procp`, `runrun`, `preempt`, `u+379`,
`u+874`, `u+864` and `addupc` (×2). So:

| `u_trap` tail step | reached on this path? | why |
|---|---|---|
| `trapsig` | yes | the glue calls it |
| `runrun` / `preempt` | yes | `s_trap` does it |
| `issig` / `psig` | **yes — the glue calls it** | see below |
| `addupc` | yes | `s_trap` does it (twice) |
| `stop_on_fault` | **no** | file-local, and it needs `u_trap`'s /proc fault class |
| `ev_istrap` / `ev_traptousr` | **no** | event tracing |

The `issig`/`psig` pair is called by the glue and is not decoration. Without it a queued signal
would wait for the process's next syscall or trap — and under full emulation an FP-only loop makes
no syscalls: its next trap is another FP instruction, straight back into this same path. A SIGFPE
that arrives only if the program happens to call `write()` is not a signal. `u_trap`'s
three-condition gate in front of it is an optimisation whose proc-structure offsets would have to
be copied blind, so the call is unconditional on the signal path only, where it runs at most once
per delivered signal.

**The two omissions are registered rather than absorbed.** `stop_on_fault` means a debugger
watching `FLTFPE` through /proc will not stop on an emulated FP exception; the /proc fault class
word is `u_trap`'s own local and is not produced. Both are round-3 items (§9, item 5), and both
are strictly better than the status quo, in which the same events are SIGSYS.

---

## 6. The state ABI

### 6.1 `fpu_emul`, and why it is a second flag

Frozen decision 9. `fpu_present` keeps meaning **"real silicon"** and this lane never writes it;
`fpu_emul` is a separate global in `.data`, set in exactly one place — `fpuinit`, and only after
the accepted probe has answered "no FPU". `src/check_fpe_relocs.py` asserts both are global
objects and that they are not the same object.

`prhasfp` is weakened and replaced with a body that answers for the pair
(`fpu_present ? fpu_present : fpu_emul`, returned in both `%d0` and `%a0` as the stock body does).
That single replacement is what makes the whole presentation work without editing a stock reader:
`savecontext` and `restorecontext` reach `fpu_present` through `jsr prhasfp`, which is a *call*
and not a relocation — the fact that made a relocation-predicated census miss it once already
(`src/fpuinit060.s`'s own correction, 2026-08-24).

### 6.2 The presented FP state

Under emulation the programmer's model **is** the u-area image: `fpe_glue.c` hands the emulator a
`struct fpframe *` computed as a fixed bias off `fpu_ptr`, so `fpf_regs` lands exactly on
`fpu_info.regs` and the emulator reads and writes fp0-fp7/FPCR/FPSR/FPIAR in place, with no copy
and no transposition. That is the cheapest seam in the contract (§3.1) and it is legitimate only
while two things hold, so both are enforced rather than believed: the offset relations are
asserted at compile time (§4.4), and `extract_fpe.sh` fails the build if the emulator ever
references a `struct fpframe` member outside `fpf_regs`/`fpf_fpcr`/`fpf_fpsr`/`fpf_fpiar` — the
216-byte FSAVE union in front of the tail is memory this pointer does not address.

**Never to be confused with `fpregset_t`** (`sys/regset.h:42-47`), which is control-words-**first**
and is what `prgetfpregs` transposes to. Confusing the two writes every FP register three
longwords out of place; the assertions are what make that impossible rather than unlikely.

So `fpu_save` and `fpu_restore` have no register traffic to do. What they owe is a **coherent
FSAVE frame**, because `savecontext` reads `fpu_info.fsave[0]` directly and `prgetfpstate` copies
all 216 bytes of it to userland:

* `fpu_save` writes `0x1f180000` into `fsave[0]` unless UFPRWRT is set;
* `fpu_restore` consumes UFPRWRT and does nothing else — and above all does **not** `frestore`,
  which on a part with no unit is an F-line exception taken in supervisor mode;
* `fpu_setup` installs the same frame, copies the 108-byte `reset_fregs` image over the model and
  clears `ustate`.

`0x1f180000` is `FIDLE881` (`0x180000`, `sys/fpu.h:72`) with a non-zero version byte. Both halves
matter: byte 1 is the format byte `savecontext` masks with `FRMTMASK 0xff0000`, and byte 0 is the
version byte stock `fpu_save`/`fpu_restore` test to decide "this process has live FP state" — a
bare `0x00180000` would read as a *null* frame. The 881 shape is decision 9's and it is also the
only one that avoids stock `savecontext`'s BIU poke at `u+324`, which is written for real 68882
silicon and fires on `FIDLE882` (contract §4.3).

`reset_fregs` is the inherited COMMON symbol and on a part with no FPU the probe never populated
it from hardware, so it is all zeros — FPCR 0 is round-to-nearest, extended precision, every
exception masked, which is the correct reset state for an emulated unit. That is stated here
because "it happens to be zero" is not a design.

### 6.3 The `fpu_present` census, per site

Contract §8.7 counts 24 references in 20 functions. Re-measured against `build/unix-040` for this
document, with the containing function resolved from the symbol table:

| Site | Disposition under emulation |
|---|---|
| `chk_fpu+0x6` | stock reader, `fpu_present` = 0 → unchanged |
| `contnu+0x6`, `contnu+0x16` | unchanged |
| `grabtrap+0x2` | unchanged |
| `fpuinit_orig+0x1a` | unchanged — it is the probe, and it runs first |
| `setuctxt+0xe` | unchanged (gates `fpu_save`) |
| `procxmt+0x21a` | unchanged. **Old ptrace's FP-register write stays gated off**, so UFPRWRT keeps its one originating setter and keeps not firing. |
| `setregs_orig+0xc8` | unchanged — and this is the one **behavioural gap**, see below |
| `prhasfp+0x6` | **replaced.** The body is overridden; this reference stays in the image and is unreachable. |
| `coffcore+0x82`, `elfcore+0x6e/+0xe8/+0x22e` | unchanged: **core dumps carry no FP register area under emulation.** Accepted; a dump that lied would be worse. |
| `elfexec+0x324` | unchanged |
| `getelfhead+0x82` | unchanged — **keeps refusing FP-required ELFs.** Adopted deliberately, see below. |
| `swtch+0x2a` (gates `fpu_restore`), `swtch+0x1d6` (gates `fpu_save`) | unchanged, and **correct by construction**: the emulated state lives in the u-area, which is switched with the process, so there is nothing for a context switch to save or restore. Our arms are therefore almost never entered from here. |
| `fpu_save+0x10`, `fpu_restore+0x10`, `fpu_setup+0x10` | this port's own gates, now preceded by ours |
| `fpuinit+0x16`, `Lfi_yes+0x6` | the probe's own |
| `fpu_setup_gated+0x10` | this port's own sendsig gate — see the gap below |
| `Lco_fpu_disabled+0x18` | the 060 package's no-FPU arm; unreachable once the vector is ours |

**`getelfhead`, adopted on purpose.** Decision 9 keeps `fpu_present` meaning real silicon, so
`getelfhead` will keep refusing FP-marked ELF binaries even under full working emulation. That is
harmless today and it is measured: contract §8 item 1 re-ran `tools/fpelf-census.py` against
`gcc-cross-amix/build/sysroot-preserved/amixroot` and found **262 m68k ELF objects, all with
`e_flags == 0`, none FP-required**. It is adopted in writing rather than inherited by omission,
and the census's own gap — `/bin`, `/sbin`, `sh`, `awk`, `ls`, `init`, `pkgadd` from a complete
installed root — remains unmeasured and out of scope this round.

**The one behavioural gap the census found, and it is a real one.** Two sites gate `fpu_setup` on
`fpu_present` and therefore skip it under emulation:

```text
	setregs_orig+0xc8:  tstl fpu_present ; beqw +0x8 ; jsr fpu_setup     (exec)
	fpu_setup_gated+0x10 (src/fpuinit060.s):  tstl fpu_present ; bne ... ; rts   (sendsig)
```

Both verified by disassembly for this document. Consequence: **a freshly exec'd image and a
signal handler inherit the previous programmer's model**, FPCR included — so a program that
enabled FP traps and then exec'd would leave them enabled for the new image, and fp0-fp7 carry
over between exec'd programs in the same process. Today, with `prhasfp()` false, that state is
stale but unreadable; under emulation it becomes live.

It is **documented and not fixed this round**, deliberately: the fix touches a stock body's gate
or adds a third override whose presence depends on whether `src/fpuinit060.s` was linked, and
neither belongs in a round whose finish line is a green link. Registered as §9 item 1 with two
candidate shapes.

---

## 7. `src/ucz_dbg.s` — GATED AT THE LINK, and why not merely left alone

`src/ucz_dbg.s` (BLIZZARD F4 round 8, ARM II) zeroes `mc_state[4..199]` at `savecontext` and
re-stamps the checksum. Its own safety gate reads `uc_flags` bit 3 and declines when an FPU is
present, "because on such a part `prgetfpstate` writes the FP machine state from `mc_state[23]`
onward and zeroing it would destroy real state" — its words.

Under this lane that gate **happens to do the right thing**: `prhasfp()` becomes true, so
`savecontext` keeps `UC_FPU` set in `uc_flags`, so the arm declines and `ucp_z_fpu_n` counts it.
And the reason it must decline is exactly the one it already names, now with a number on it:
contract §4.4 establishes that with `fpu_emul` making `prhasfp()` true, `prgetfpstate` fills
`mc_state[23..76]` — **216 genuinely written bytes** the zeroing would destroy.

"Declines by luck" is not the property to ship. The decision is therefore **the link**:
`relink-040-fpe.sh` refuses to produce an FPE kernel containing `ucp_magic`, so the two units
cannot coexist in one image regardless of what either file's internal gates do. The file is left
on the branch untouched — it is a campaign artifact, `relink-040-f8.sh` still builds with it, and
deleting it would break a build line that has nothing to do with this lane.

The second half of the dispatch's concern — that the unit's `mc_state` zeroing and its FPU-decline
logic are wrong once `prgetfpstate` genuinely writes — is answered the same way: both are wrong
*for an FPE kernel*, and an FPE kernel is exactly what the link gate forbids them from being in.

---

## 8. Build integration

### 8.1 Where it runs, and the rollback

`relink-040-fpe.sh` is a **second pass over `relink-040.sh`'s finished output**, not a variant of
it. The arm is installed by retargeting `M68Kvec[11]`, which needs no source change to
`src/fpsp_glue040.s` and no new configuration inside the 83 KB main relink. So "without the FPE"
is the base image itself.

`FPE=0` therefore does not mean "skip some steps": it copies the base to the output and
**compares sha256 both ways**, failing if they differ. A rollback that is only believed is not a
rollback. There is a second, finer control at run time: `fpe_enable` is a one-word `.data` cell
`fpuinit` tests, so a boot can be taken with the lane off without a different kernel.

Every build step goes through `run_step` from `tools/build-step.sh`; nothing runs behind a pipe.
All scratch lives under the gitignored `build/`.

### 8.2 The flags, and one temporary duplication

`AMIX_KERNEL_CFLAGS` via `tools/config-load.sh`, `AMIX_SYSROOT=build/sysroot-modelb` (the Model-B
mirror), and the `-m68020` → `-m68040` swap — the recipe `relink-040-z3660.sh:33-42/61`
establishes and contract §7 measured 20/20 against. Note `-traditional`: this is K&R-mode gcc
2.7.2.3, which is why the compat header spells `int8_t` as plain `char` (`signed char` is
rejected) and why every glue function is K&R.

The one thing that is not upstream yet: gcc 2.7.2.3 emits the SGS bit-field operand
`bfffo %d3{#0:#32},%d2` and GNU as 2.8.1 rejects it, which stops `fpu_subr.c` and nothing
else. `src/mk_fpe_cc.py` generates a compiler that repairs it.

**This is marked as a temporary duplication of a toolchain fix and it should not survive.** The
repair belongs in `gcc-cross-amix`'s wrapper, in the same `fix_asm` chain that already handles
`.swbeg`, `tdivs`/`tdivu`, `fsgldiv`/`fsglmul` and the SGS compare operand order; it is not
FPE-specific and affects any C reaching that codegen pattern. The generator detects a wrapper that
already has the line and steps aside, so the day it lands upstream this stops adding a second copy.

**The obvious cheaper shape is wrong and the script says so.** "Compile `-S`, apply the
substitution, assemble" loses the other four repairs: the wrapper does **not** run `fix_asm` when
given `-S` — it execs the real compiler and returns raw SGS assembly. A pipeline outside the
wrapper would therefore silently drop `.swbeg`, whose absence misdispatches every switch
statement. Hence a wrapper copy with one line added, not a post-process.

### 8.3 The link order, and the assertion that actually checks it

Contract §7.3: seven of the twenty emulator objects have a `.text` size that is `≡ 2 (mod 4)` —
`fpu_exp` 1558, `fpu_int` 234, `fpu_log` 4902, `fpu_mul` 938, `fpu_rem` 770, `fpu_subr` 402,
`fpu_trig` 3070 — the compiler pads to 2, and `BUILDING.md:249-250` records why that matters: the
loader copies text and data as one block and places `.bss` at `data_end` **unaligned**. A compiled
object cannot end its own section with `.balign 4`; `src/fpe040.s` does, so it is linked **last**.

The comment is not the check. Three guards after the link are: text/data contiguity, `.data` size
4-aligned (both standard in this tree) and — new here — **`.text` size 4-aligned**, which is the
direct expression of the law. The instrument is verified rather than trusted: relinking with
`fpe040.o` out of last place produces `.text` `0xfc42e` and `.data` `0x1a92e`, both `≡ 2 (mod 4)`,
and both guards fire.

### 8.4 The override surface

Five strong symbols are replaced and one file-local symbol is exposed:

```text
	prhasfp                     answers for the pair.  No *_orig: one instruction, fully replaced.
	fpuinit                     runs the accepted probe first, arms only on its no-FPU answer
	fpu_save / fpu_restore / fpu_setup    present an idle 68881 frame instead of touching hardware
	trapsig                     file-local in stock; globalized
```

Addresses for the `*_fpe_orig` aliases come from `nm` of **that** base, never from a note:
whichever of those bodies is already an override from `relink-040.sh` (`src/fpu060.s`,
`src/fpuinit060.s`) is what the alias must reach, and those move with every build. The chain is
therefore ours → this port's 060 arm → the stock 040 body, intact.

`ld -r` does not fail when an override definition is dropped — it leaves the stock body strong and
links cleanly, which is the failure this port has paid for (`BUILDING.md:252-255`). So the build
asserts, for each of the five, that there is **exactly one** strong definition and that it lies
past the base image's `.text` end.

### 8.5 The assertions, in one list

| Check | Where |
|---|---|
| tarball sha256 = the pinned one | `extract_fpe.sh` |
| all 25 extracted files + 4 headers byte-identical to a fresh extraction; nothing extra under `build/fpe-src/` | `extract_fpe.sh` |
| the emulator references only the four `fpframe` tail members | `extract_fpe.sh` |
| 20 objects compile; total `.bss` is exactly 396 bytes | `relink-040-fpe.sh` |
| struct-layout assertions (13 of them) | `src/fpe_glue.c`, at compile time |
| every `fpe_*`/`fpu_*` symbol defined; **no** unresolved symbols | `relink-040-fpe.sh`, `nm` |
| each of the five overrides has one strong definition, past the base | `relink-040-fpe.sh` |
| `ucp_magic` absent | `relink-040-fpe.sh` |
| `.text` / `.data` sizes 4-aligned; text/data contiguous | `relink-040-fpe.sh` |
| `fpu_present` and `fpu_emul` are distinct global objects | `check_fpe_relocs.py` |
| `fpu_ptr` still `u + 0x9c` | `check_fpe_relocs.py` |
| `M68Kvec[11]` → `fpe_vec11`; `fpe_decline` → the displaced handler and not the arm | `check_fpe_relocs.py` |
| `init_tbl+0` → `fpuinit`, and nothing else in `.data` reaches it | `check_fpe_relocs.py` |
| the AMIX loader simulation | `src/check_relink_relocs.py` |

The 396-byte `.bss` assertion deserves its line: a vendor import that grew a new file-static
would otherwise pass silently through a lock designed for three specific files (§4.1).

---

## 9. What round 3 must measure

One row per thing this document decided. A row with no number against it is a decision that was
argued and never tested.

1. **The exec/sendsig `fpu_setup` gap (§6.3).** Highest-value follow-up. Reading: exec a program
   that sets a distinctive FPCR and fp0 pattern, exec another, read `fpu_info` through /proc. The
   registered prediction is that the pattern survives. Two candidate fixes: extend the two gates to
   `fpu_present || fpu_emul`, or reset the model from the glue at the first FP trap after exec.
2. **`fpe_advmiss_n == 0` (§4.4).** The instruction-length check. Non-zero is a finding with the
   offending instruction already latched, and it is the contract's sharpest standing risk.
3. **`fpe_entry_n == 0` and `fpu_emul == 0` on every FPU-present rig (decision 7).** The
   never-engage bar, readable from the first boot.
4. **si_code agreement (§5.2).** The same enabled-exception test run on a real-FPU 040/060 rig and
   on the LC060: same signal, same `si_code`, same `si_addr`. This is the only way to show the
   derivation matches what stock would have said, since on the LC060 stock says SIGSYS.
5. **Signal-delivery latency and the two omissions (§5.3).** A SIGALRM into a pure-FP loop must
   arrive; `stop_on_fault` and the /proc fault class do not run and a /proc `FLTFPE` watcher will
   not stop.
6. **`fpe_lock_wait_n` (§4.1).** Non-zero under a concurrent load with paged-out operands, and
   zero is a reason to strengthen the test, not to relax the lock.
7. **`fpe_panic_n`, `fpe_panic_hard_n`, `fpe_fmtx_n`, `fpe_super_n` all 0** on every clean run;
   the copy-fault path exercised deliberately (§4.2).
8. **The boot line.** On a 68LC060: `no fpu detected` followed by `fpu emulation enabled`. On an
   FPU part: neither, and every counter in `src/fpe040.s` at its initialiser.
9. **`ucp_magic` absent** from every kernel this lane produces (§7).
10. **`fpe_fmt2_n`** on an 040 rig, which is how the format-2 frame finally gets latched (contract
    §8 item 2) without building its arm first.

---

## 10. Carried forward, unresolved

* The format-2 arm (68040 unimplemented FP) is documented and not implemented — decision 6's third
  arm, and §9 item 10 is how the evidence for it gets collected.
* The `fpelf-census.py` gap against a complete installed root (contract §8 item 1) is unchanged and
  out of scope.
* The `bfffo` repair is duplicated in this repository and belongs in `gcc-cross-amix` (§8.2).
* Core dumps carry no FP register area under emulation (§6.3), and old ptrace cannot write FP
  registers. Both follow from decision 9 and neither has been argued as *desirable*, only as
  consistent.
* 568 of the 784 never-written `mc_state` bytes remain uninitialised kernel stack copied to
  userland on every signal (contract §4.4). This lane shrinks the region by 216 bytes and closes
  nothing.
