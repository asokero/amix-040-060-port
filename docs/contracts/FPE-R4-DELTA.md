# FPE round 4 — the design delta, pre-registered

Round 3 booted the soft-FPU lane for the first time and the lane works: on the FPU-less 68LC060
every rung of the acceptance ladder produces correct, value-checked output across 29.5 million
emulated instructions, with zero panics, zero format surprises and zero supervisor entries
(`Amix/tmp/2026-08-26-fpe-r3/RESULTS.md`). It also produced **three defects and two broken
instruments**, one of the defects severe enough that three processes had to be power-cut.

This document is committed **before** any round-4 code. Each fix states its mechanism, the
evidence it rests on, what it costs on the hot path, and the round-5 reading that will confirm
or refute it. Where round 3's measurements contradict the round-2 design document
(`FPE-GLUE-DESIGN.md`) or the dispatch that ordered this round, that is said out loud in §7
with the measurement rather than absorbed quietly.

> **PROVENANCE.** Sections 1, 4 and 7 are structural analysis of the stock AMIX kernel image
> this port patches — a disassembled `u_trap` tail, proc-structure offsets, per-site gate
> decodes — measured from `build/unix-040` and cited by address. No vendor source text is
> reproduced. Same class as `docs/contracts/FPE-INTEGRATION-CONTRACT.md`,
> `docs/contracts/FPE-GLUE-DESIGN.md` and the ATT7/ATT8 results.

The normative inputs are `FPE-INTEGRATION-CONTRACT.md` (round 1, the AMIX side of the seam),
`FPE-GLUE-DESIGN.md` (round 2, the glue design) and round 3's `RESULTS.md`. Where this document
differs from the round-2 design it says so in §7.

**Scope discipline, unchanged from rounds 1–3.** No file under `build/fpe-src/` is touched — the
extracted tree stays byte-identical to the pinned tarball and `src/extract_fpe.sh` proves it
on every build. Everything below is in `src/fpe_glue.c`, `src/fpe040.s`, `relink-040-fpe.sh` and
`src/check_fpe_relocs.py`.

**One property this round deliberately keeps: the base kernel does not move.** Every fix lives
inside the FPE lane, so `build/unix-040` is byte-for-byte what round 3 booted and `FPE=0` still
reproduces it under the script's own sha gate. That matters for §2 in particular, where the
obvious place to put the fix is `src/fpuinit060.s` — a file every 040 kernel on this branch
links — and where an override costs nothing and keeps the blast radius at zero.

---

## 1. FIX 1 — a pure-FP loop cannot be signalled, not even with SIGKILL

**The defect.** `issig`/`psig` are reached only from `fpe_signal()` (`src/fpe_glue.c:346-348`),
i.e. only when the *emulator itself* raised a signal. The successful path is
`fpe_done_n++; return 0;` (`:507-508`), which returns through `ureturn` → `s_trap`, and `s_trap`
has no `issig`/`psig` loop — round 2 decoded its whole relocation set and
`FPE-GLUE-DESIGN.md:507-517` says so in its own table. So a process whose only traps are
*successful* FP emulations never looks at its pending-signal state. Measured single-variable
against the FPU rig, where the same `alrm` binary's alarm fires on time: on the LC bed `alarm(2)`
never fired, the process spun for four to five minutes, and `kill -9` returned success on two of
them while both kept accumulating CPU time. Three such processes could not be removed and the rig
was power-cut.

The round-2 source comment states the correct rationale — *"under full emulation an FP-only loop
makes no syscalls: its next trap is another FP instruction, straight back into this same path"* —
and then places the call on the path that is **not** taken for a successful emulation. Design
intent and implementation disagree, and §9 item 5 is the row that caught it.

**Why the gate is now mandatory rather than optional.** `FPE-GLUE-DESIGN.md:520-524` skipped
`u_trap`'s three-condition gate because "its proc-structure offsets would have to be copied
blind". That was defensible while the call ran at most once per delivered signal. It is not
defensible on the success path, which is **the hot path**: one entry per emulated FP instruction,
29.5 M of them in one round-3 session. So the gate is decoded properly here, and it is not blind.

### 1.1 `u_trap`'s gate, decoded

`build/unix-040`, `u_trap` at `0x5a47e`. Two facts from the prologue fix the addressing:

```text
0x5a486   lea    <reloc>,%a2          %a2 = u
0x5a490   movel  %d4,%a2@(0x864)      u.u_ar0 = %fp+8   <- the slot src/fpe040.s already uses
0x5a496   moveal %a2@(0x730),%a3      %a3 = u.u_procp   <- the proc pointer for the rest of u_trap
```

`u + 0x864 = u_ar0` is this port's own `U_AR0` constant (`src/fpe040.s:50`), independently
hardware-accepted, which is what identifies `%a2` as `u` and therefore `%a3` as `u.u_procp`.

The gate itself, at `0x5a89a`, immediately after `trapsig` and the `runrun`/`preempt` pair:

```text
0x5a89a   tstb  %a3@(134)      ; bnew 0x5a8be      -> take the issig path
0x5a8a2   tstl  %a3@(156)      ; bnew 0x5a8be
0x5a8aa   movel %a3@(4),%d0 ; andil #0x100,%d0 ; tstl %d0 ; bnew 0x5a8be
0x5a8ba   braw  0x5a8da                            -> skip issig entirely
0x5a8be   clrl %sp@- ; jsr issig ; addqw #4,%sp ; tstl %d0 ; beqw 0x5a8da
0x5a8d0   jsr  psig
```

**The three fields, named.** `sys/proc.h`'s `proc_t` walked with `USIZE = 4`
(`sys/param.h:65`) reproduces all three offsets exactly:

| Offset | Field | Type | Meaning |
|---:|---|---|---|
| +4 | `p_flag` | `u_int` | tested against `SPRSTOP` `0x00000100` — the flag the header documents as marking a process being stopped through `/proc` |
| +134 | `p_cursig` | `u_char` | the signal currently being delivered |
| +156 | `p_sig` | `k_sigset_t` | signals pending to this process |

So the gate is `if (p->p_cursig || p->p_sig || (p->p_flag & SPRSTOP))`.

**Four independent confirmations that the walk is right**, because a wrong offset here is a gate
that silently never fires and the severe defect comes straight back:

1. `p_stkbase` at +60 and `p_stksize` at +64 — the same walk, and this repository already reads
   them at those offsets in `src/hatalloc_dbg.s:641`.
2. `p_sysid` at +140 — `src/assegat_dbg.s:309` reads `a0@(140)` off `*(u+0x730)` as copyout's
   local/remote path selector, which is exactly what `p_sysid` is.
3. `k_sigset_t` is `ulong_t` (`sys/types.h:40`), **four bytes** — so `u_trap`'s single `tstl`
   covers the entire pending set and there is no second word for our copy to miss.
4. The `0x100` mask has exactly one name in `sys/proc.h`: `SPRSTOP`.

### 1.2 The fix

`fpe_sigpend()` in `src/fpe040.s` reproduces those three tests over `u.u_procp`, reading the same
pointer `u_trap` reads rather than the glue's `curproc` — the two are the same pointer, but
reading `u+0x730` removes the question instead of arguing it. `src/fpe_glue.c`'s success path
becomes:

```c
	fpe_done_n++;
	if (fpe_sigpend()) {
		fpe_sigpend_n++;
		if (issig(0)) { fpe_sigdeliv_n++; psig(); }
	}
	return 0;
```

**Where it sits, and why that is the right instant.** The register writeback, the USP splice and
the final PC are all already written into the supervisor-stack block by the time this runs
(`fpe_glue.c:479-482`), `u.u_ar0` was set before the emulator was called (`fpe040.s:147`), and the
entry lock has already been released. That is precisely the state `u_trap` is in when it runs the
same two calls — so `sendsig`, reaching through `u_ar0`, finds the post-emulation registers and
the post-emulation PC, which is what a handler must resume on. `psig()` may not return (a fatal
signal exits); so may `u_trap`'s, and `fpe_done_n` is incremented first either way.

`fpe_signal()`'s existing unconditional `issig`/`psig` is left alone. It runs at most once per
delivered signal, `trapsig` has just made the gate true by construction, and round 3 proved that
path delivers correctly (`si_code` 3 and 4, `SIGSEGV`/`SEGV_ACCERR`). A proven path is not
rewritten for symmetry.

### 1.3 The cost, stated and bounded

Sixteen instructions and four memory reads per emulated instruction: one indirect load of
`u.u_procp`, three proc-field reads, and no writes at all when nothing is pending. For scale,
round 3 measured `fpe_ufetch_n / fpe_entry_n ≈ 8.6` — the gate is **cheaper than one of the 8.6
user-memory fetches the emulator already makes per instruction**, and the observed trap rate of
~24 k/s on the bench puts the whole per-instruction budget around 42 µs. The gate is bounded
above by 0.1 % of that and does not scale with anything.

### 1.4 Predicted round-5 readings

* `alrm` on the LC bed: **SIGALRM arrives**, at t0+2 as it does on the FPU rig.
* `kill -9` on a pure-FP spinner: **the process dies**, and no unkillable process accumulates.
* `fpe_sigpend_n > 0` and `fpe_sigdeliv_n > 0` after such a test; both **0** on a boot with no
  signals into FP code.
* `fpe_sigpend_n ≪ fpe_done_n` — the gate refuses the overwhelming majority of entries, which is
  the whole reason it exists.

---

## 2. FIX 2 — the exec/sendsig `fpu_setup` gap, candidate 1

**The defect, and the A/B that makes it proof.** Identical binaries, identical kernel (one byte
apart — the `cputype` stamp), only `fpu_model` differing:

| | Rig A — LC060, emulated | Rig B — 68060 + FPU |
|---|---|---|
| `execa` sets | `fpcr=0x1400 fp0=12345.678` | `fpcr=0x1400 fp0=12345.678` |
| `execb` reads after `exec` | **SURVIVED** | **RESET** (`fpcr=0x0000 fp0=inf`) |

`0x1400` is OVFL **and** DZ enabled. A program that enables FP traps and then execs leaves the
next image taking SIGFPE where it would have had a quiet infinity. Corroborated by the counters:
`fpe_setup_n == 1` across a whole multiuser boot with dozens of execs, and `fpi_ss_skip_n == 33`
sendsig refusals.

**Candidate 1 is adopted** — extend the two gates to the pair `(fpu_present || fpu_emul)`.
`FPE-GLUE-DESIGN.md:630-635` deferred it on the grounds that the fix "touches a stock body's gate
or adds a third override"; round 3 retired that objection by measurement (`setregs` is *already*
overridden in this port, and `fpu_setup_gated` is this port's own file), and the machinery that
produces the correct reset already exists and is already this lane's own: `fpu_setup`'s emulation
arm installs the idle 68881 frame, copies `reset_fregs` over the model and clears `ustate`
(§6.2). Only the gates were wrong.

**Both halves are implemented as FPE-lane symbol overrides**, which is the mechanism the lane
already uses five times, and which keeps the base kernel byte-identical:

```text
	fpu_setup_gated     ours -> fpu_setup when (fpu_present || fpu_emul); otherwise
	                    a tail jump to fpu_setup_gated_fpe_orig, byte for byte.
	setregs             ours -> setregs_fpe_orig (which is srgtrap.s's wrapper, which is
	                    stock's body), then fpu_setup when emulating.
```

The stock `setregs` gate cannot be reached any other way: it is `tstl fpu_present ; beqw ; jsr
fpu_setup` **inside** the stock body at `setregs_orig+0xc8`. Calling `fpu_setup` after the body
returns is equivalent, because `fpu_setup` writes only `fpu_info.regs`, `fpu_info.fsave[0]` and
`fpu_info.ustate`, and nothing in the remainder of `setregs` reads or writes any of them.

**The `setregs` calling convention is not assumed.** One argument at `%fp@(8)`, an `int` returned
in `%d0` and mirrored into `%a0` — the shape **two** independent in-repo wrappers already use and
one of which is in the booting base image: `src/srgtrap.s:155-186` and `src/execmark.s:585-591`.
The return value is load-bearing: `exece` answers a non-zero `setregs` with a silent
`psignal(p,9)`, so the wrapper preserves `%d0` through `%d2` exactly as both precedents do.

The `fpu_setup_gated` override's `%d0`/`%a0` clobber is safe at its one caller: `sendsig+0x1f8`
overwrites `%d0` with `moveq #1,%d0` four instructions later (`0x59228`) and `%a0` was already
dead.

### 2.1 Predicted round-5 readings

* `execa`/`execb` on the LC bed: **`fpcr=0x0000 fp0=0.000` after exec** — the LC row becomes the
  FPU row.
* `fpe_setup_n` tracks execs instead of standing at 1 — order hundreds over a multiuser boot.
* `fpi_ss_skip_n` falls to **0**; `fpe_ss_setup_n` takes its place with a comparable count
  (round 3 saw 33 refusals on a boot).
* `fpe_exec_setup_n > 0`, one per exec.
* The never-engage bar is untouched on FPU rigs: `fpe_entry_n == 0`, `fpu_emul == 0`,
  `fpe_ss_setup_n == 0`, `fpe_exec_setup_n == 0`, and `fpi_ss_pass_n` unchanged.

**Cost.** One extra `fpu_setup` call per exec and per signal delivery on an emulated part —
a 27-longword copy and two stores, some tens of instructions against an exec.

---

## 3. FIX 3 — `fpe_cputype` reads the wrong half-word

**The defect.** `fpe_cputype` read **2** (`CPU_68040`) on a rig whose AMIX `cputype` is 60.
`src/cputype060.s:21` defines the symbol as **`.long 40`**; AMIX's `sys/systm.h:18` declares
`extern short cputype`, and §4.3 took that declaration at face value. The FPE lane therefore read
only the high half-word of a big-endian long, which is `0x0000` and never 60:

```text
	src/fpe040.s:325     cmpiw &60,cputype
	src/fpe_glue.c:34    extern short cputype;      ... :398  (cputype == 60)
```

**It is FPE-lane-local.** Every other reader in the port uses the 32-bit form — `inituname040.s`,
`hgfault040.s`, `fpsp_glue040.s` (×9), `isp61_060.s`, `fpu060.s` (×3), `fpuinit060.s` (×2) all
`cmpil`/`movel`; `ptest040.s` and `pstart040.s` `movel`; `kernel-cputype-stamp.py` treats the site
as a long. The FPE lane is the only place that used `cmpiw`/`short`.

**Impact today is nil and that is exactly why it is fixed.** §3.1 proved the only consumer,
`fpu_calcea.c:118`, is inside a `#if 0` block. §4.3 wrote itself against precisely this: *"a lane
whose correctness depends on a `#if 0` staying closed is one edit from a plausible wrong answer."*

**The fix.** `cmpil &60,cputype` in the assembly, `extern long cputype` in the glue, and the
mapping made total rather than defaulted:

```c
	if (cputype == 60)      fpe_cputype = NB_CPU_68060;   /* 3 */
	else if (cputype == 40) fpe_cputype = NB_CPU_68040;   /* 2 */
	else { fpe_cputype_bad_n++; fpe_cputype = NB_CPU_68040; }
	fpe_cputype_amix = cputype;
```

**The assertion the dispatch asks for is `fpe_cputype_amix`**, a latch carrying the raw AMIX
`cputype` long exactly as the FPE lane reads it, written by `fpuinit` when the lane arms and
refreshed on every entry. It is the reading that distinguishes the bug from the fix: with the
width defect present the latch reads `0`; with it fixed it reads **60** (`0x3c`) on an LC060, and
`fpe_cputype` reads **3**. `fpe_cputype_bad_n` catches a future regression at run time rather than
at boot only. Both keep the `0xffffffff` / `0` initialiser on an FPU-present rig, where the lane
never arms — the sentinel law of `src/fpe040.s` is not weakened.

### 3.1 Predicted round-5 readings

* LC060: `fpe_cputype_amix = 60`, `fpe_cputype = 3`, `fpe_cputype_bad_n = 0`.
* 68040 rigs, FPU present: both at their initialisers (`0xffffffff` and `2`), as round 3 recorded.

---

## 4. FIX 4 — `fpe_advmiss_n` was measuring the wrong thing

**The defect.** `fpe_advmiss_n` reached **7,909,400** over the round-3 session, and the latch
named the instruction exactly — an FP conditional branch in libc's `_doprnt`:

```text
17f5e:  f2ce 0000 000a   fbnel 17f6a      <- fpe_b_pc      = 0xc1017f5e
17f64:  7c01             moveq #1,%d6     <- fpe_b_stacked = 0xc1017f64  (fall-through)
17f6a:  2407             movel %d7,%d2    <- fpe_b_resume  = 0xc1017f6a  (branch target)
```

The emulator **took** the branch; the CPU stacks the fall-through, as it always does for an
instruction it never executed. `FPE-GLUE-DESIGN.md:364`'s claim — *"the two must be equal"* — is
false for that class, and its reasoning silently assumed every emulated instruction falls through.
Controlled proof: 100 × `printf "%f"` moved the counter by exactly 102, and it read 0 across two
complete boots that printed no floats.

**The consequence is the honest reading of round 3 row 2: instruction-length correctness was
never actually tested**, because the counter that was supposed to test it is saturated by a benign
class. That is the contract's sharpest standing risk (`FPE-INTEGRATION-CONTRACT.md:544-551`) and
it is still open.

### 4.1 The exclusion set, taken from the emulator decoder's own classification

`fpu_emulate.c:145` computes `optype = (sval & 0x01C0)` and dispatches on it at `:162`, `:191`,
`:196`. That is the emulator's own instruction taxonomy, so it is the one the instrument uses:

| `optype` | Class | Can the emulator move the PC off the straight line? |
|---|---|---|
| `0x0000` | type 0 — arithmetic, `fmovm`, `fstore`, `fmovecr`, `fscale` | no |
| `0x0040` | type 1 — `FDBcc` / `FScc` / `FTRAPcc` | **`FDBcc` only** |
| `0x0080`, `0x00C0` | types 2/3 — `FBcc`, word and long displacement | **yes** |
| anything else | types 4–7 — `fsave`/`frestore`/reserved | never reaches the success path (`sig = SIGILL`) |

Type 1 is split rather than excluded wholesale, because `fpu_emul_type1` is explicit about which
of its three instructions moves control flow: `FDBcc` (`insn->is_opcode & 070 == 010`) computes a
taken branch as `insn->is_advance += displ` (`fpu_emulate.c:1030`), whereas `FTRAPcc` either
advances by 4/6/8 or raises SIGFPE (`:1044-1068`), and `FScc` always advances (`:1073-1075`).
`FScc` and `FTRAPcc` therefore stay **under test**, which keeps the instrument sharper than the
minimum the finding required.

So the exclusion predicate is exactly two lines:

```c
	optype = opw & 0x01C0;
	ctl = (optype == 0x0080 || optype == 0x00C0)		/* FBcc  */
	   || (optype == 0x0040 && (opw & 0070) == 0010);	/* FDBcc */
```

**The predicate is verified against round 3's own latch, not just written.** `fpe_b_pc` named
`0xc1017f5e`, whose opword is `0xf2ce`: `0xf2ce & 0xf000 == 0xf000` (F-line), `& 0x0E00 == 0x0200`
(coprocessor 1), `& 0x01C0 == 0x00C0` — type 3, `FBcc` long. The instrument classifies the exact
instruction that broke it.

### 4.2 The fetch, and where it does not cost anything

The opword is read from the faulting PC — `f_fmt4.f_fslw`, the field the existing latch already
uses and which round 3 proved names the right instruction to the byte — **only when the two PCs
disagree**. Agreements, which were 73 % of round 3's population, cost nothing at all. The fetch is
a direct two-byte `copyin` rather than `ufetch_short`, so the emulator's own fetch census
(`fpe_ufetch_n`, `fpe_ufetchfail_n`, `fpe_fault_addr`) is not perturbed by the instrument
measuring it.

**Cost:** 0.268 extra two-byte `copyin` per emulated instruction at round 3's mix, against the
8.6 the emulator already makes — **+3.1 % user-memory fetches**, and 0 % on any workload whose FP
code does not branch.

### 4.3 The counters, re-registered

| Counter | Meaning | Registered reading |
|---|---|---|
| `fpe_advmiss_n` | a **straight-line** advance disagreed with the CPU's stacked next-PC | **0** across a full bench session |
| `fpe_advctl_n` | the disagreement was an `FBcc`/`FDBcc` that the emulator took | free to be large — round 3's 7.9 M lands here |
| `fpe_advnofetch_n` | the opword could not be fetched, so the class is unknown | **0** |
| `fpe_b_pc`/`_stacked`/`_resume`/`_opword` | first true miss, with its opword so the class is provable | sentinels |
| `fpe_c_pc`/`_opword` | first excluded control-flow event, so the exclusion is provably firing | non-sentinel once floats are printed |

`fpe_advmiss_n == 0` becomes, for the first time, a real test of `is_advance`.

**Residual gap, stated rather than buried.** A wrong `is_advance` inside the `FBcc`/`FDBcc`
classes is still invisible: an untaken branch with a wrong length is indistinguishable from a
taken one from the glue's side. Round 3's weaker corroboration stands — 29.5 M instructions with
correct awk/printf/df/dhrystone output and zero unintended signals — and it now covers a strictly
smaller residue.

---

## 5. FIX 5 — `fpe_fmt2_n` is structurally unreachable

**The defect.** `src/fpe040.s:81-85` declines on `fpu_present` **before** the format census, so on
every FPU-present 040 in this workspace's fleet the lane never arms and `fpe_fmt2_n` can never
move. §9 item 10's stated intent — *"the counter that will latch it the first time an 040 rig runs
this kernel"* — cannot be discharged on an FPU-present 040 at all, which is the only kind of 040
available. Contract §8 item 2's standing gap (the format-2/`0x202c` pairing rests on Motorola's
`x_fline.sa` and has never been latched from a real 68040 frame in this tree) therefore stayed
open through a round that booted two 040 rigs.

**The fix.** A census **ahead of** the `fpu_present` decline, counting all three formats plus the
fourth-shape case, and latching the format-2 frame's own words. `fpe_entry_n` stays exactly where
it is, behind both gates, so the never-engage bar is untouched.

```text
	fpe_v11_n            every vector-11 event, armed or not, user or supervisor
	fpe_v11_fmt4_n       0x402c   eight-word, 68060 FP disabled
	fpe_v11_fmt2_n       0x202c   six-word, 68040 unimplemented FP
	fpe_v11_fmt0_n       0x002c   four-word, a genuine bad F-line word
	fpe_v11_fmtx_n       anything else            + fpe_v11_last_fmtvec
	fpe_v11_fmt2_word    the format/vector word of the last format-2 frame
	fpe_v11_fmt2_ia      ... and its +8 instruction address
```

The census is memory-to-memory and memory-immediate throughout, so it changes CCR and nothing
else — the register discipline `src/fpsp060_glue.s` records at length after M2a broke it, and the
rule the rest of `fpe_vec11` already keeps. The decline path itself is unchanged: same single
`jmp` with the same patchable relocation, so a declined exception still takes the pre-FPE path
instruction for instruction.

**The never-engage bar is re-registered, not weakened.** The bar is `fpe_entry_n == 0` and
`fpu_emul == 0` plus every *behavioural* counter at its initialiser. The `fpe_v11_*` family are
pre-gate observers and are **expected to move on FPU-present rigs** — that is their entire
purpose. Any future reading of the bar must exclude them by name.

### 5.1 Predicted round-5 readings

* Rig C (68040 + FPU): `fpe_v11_n > 0` and `fpe_v11_fmt2_n > 0` — the FPSP's unimplemented-FP
  traps are format-2 events at vector 11 — with `fpe_v11_fmt2_word = 0x202c` **confirming or
  refuting Motorola's `x_fline.sa` pairing on real frames for the first time in this tree**, and
  `fpe_v11_fmt2_ia` naming a plausible text address in the faulting binary.
* Rig C: `fpe_entry_n` still **0**, `fpu_emul` still **0**.
* Rig A (LC060): `fpe_v11_n == fpe_v11_fmt4_n == fpe_entry_n + (declines)`, and
  `fpe_v11_fmtx_n == 0`.
* Cost: three to five instructions per vector-11 event, on every rig.

---

## 6. FIX 6 — the si_code A/B: what agreed, what did not, and what the divergence actually is

The dispatch asked for the si_code derivation to be fixed so the emulated code matches the
real-FPU rig, on the reading that "FLTDIV agreed, FLTOVF did not". **Round 3's own table says the
codes agreed on both rows.** `RESULTS.md` item 4:

| case | Rig A — emulated | Rig B — real FPU | agreement |
|---|---|---|---|
| div-zero, DZ enabled | `signo 8, si_code 3, si_addr 0x800006f0` | `signo 8, si_code 3, si_addr 0x800006f0` | **identical** |
| overflow, OVFL enabled | `signo 8, si_code 4, si_addr 0x8000068c` | `signo 8, si_code 4, si_addr 0x80000688` | signal + code identical; **si_addr differs by 4** |

`si_code` is 3 on both sides of the first row and 4 on both sides of the second. The divergence is
**`si_addr`**, and no change to the FPSR→si_code derivation can address it. §6.2 audits the
derivation anyway, because the dispatch was right to ask; §6.1 establishes what the real
divergence is.

### 6.1 The mechanism, proven from the two probe binaries

Disassembling both probes — they are preserved beside the round-3 results — makes one rule explain
both rows, and refutes each competing rule with the other row:

```text
ovf:                                     dz:
  80000688:  fmulx %fp1,%fp0   <- faults   800006ec:  fdivx %fp3,%fp2   <- faults
  8000068c:  addql #1,%d0                  800006f0:  fmoved %fp2,%sp@-  <- the next FP instruction
  8000068e:  moveq #19,%d1
  80000690:  cmpl %d0,%d1
  80000692:  bgew 80000688     <- back to the fmulx
```

* **"si_addr is the faulting instruction"** — refuted by `dz`: the real FPU reported `0x6f0`, and
  the faulting `fdivx` is at `0x6ec`.
* **"si_addr is the next instruction"** — refuted by `ovf`: the real FPU reported `0x688`, and the
  next instruction is at `0x68c`.
* **"si_addr is the next *floating-point* instruction"** — fits both. In `dz` that is the
  `fmoved` at `0x6f0`; in `ovf` the loop's only FP instruction is the `fmulx` itself, so the next
  one encountered is the same address, `0x688`.

That is Motorola's deferred (pre-instruction) reporting model for enabled FP arithmetic
exceptions: the exception raised by instruction *N* is reported when the next FP instruction is
encountered, and the frame carries *that* instruction's PC. The glue reports synchronously,
because `fpe_abort` sets `ksi_addr = frame->f_pc` (`fpu_emulate.c:54-59`) after the PC advance at
`:217-218`. **The two coincide exactly when the next instruction is itself an FP instruction**,
which is the common case and is why `dz` agreed.

So `FPE-GLUE-DESIGN.md:488-492`'s *"the two agree without being made to"* is not a property; it is
a coincidence that holds for a large class of code and fails for the rest.

**Why this round does not "fix" it.** Matching hardware exactly means implementing deferred
reporting — complete the instruction, commit the default result, record the pending exception, and
raise it at the next FP trap. Under full emulation that is mechanically available, because every
FP instruction traps, so "the next FP instruction" *is* "the next `fpe_vec11` format-4 entry for
this process". But it needs new per-process pending state that the u-area does not carry and that
must be maintained across fork/exec/signal — the exact objection that eliminated candidate 2 in
§9 item 1 — and it changes which value is committed to `fp0-fp7`. That is a design decision, not a
bug fix, and it belongs to a round that can bench it as its subject rather than as a rider.

The two alternatives available *without* deferred reporting were both weighed and both are worse
than the status quo: reporting `f_pcfi` (the faulting instruction) matches `ovf` and **breaks the
`dz` row that currently agrees**, converting one measured agreement into a new measured
disagreement; and reporting `f_pcfi` only for some exception classes has no rule to key on,
because the divergence is a property of the *following code*, not of the exception.

**So FIX 6 delivers an instrument and a correction, not a behaviour change**, and registers the
decision for round 5 to take deliberately. `fpe_last_fault_pc` latches the faulting instruction's
address alongside the `si_addr` actually delivered, so the next A/B can state both without a
disassembler in the loop.

### 6.2 The derivation order, audited as asked

Order in `fpe_fltcode`: `(BSUN|SNAN|OPERR)` → `OVFL` → `UNFL` → `DZ` → `(INEX1|INEX2)`. That is
Motorola's exception priority, highest first, with members grouped only where SVR4 gives them the
same code — the grouping the emulator itself uses when it sets the accrued bits
(`fpu_emulate.c:255-257`, `FPSR_BSUN|FPSR_SNAN|FPSR_OPERR` → `FPSR_AIOP`). No change.

The dispatch's specific concern — an overflow raises OVFL and INEX2 together, so the order decides
which code wins — is answered by round 3's own bonus validation rather than by argument. After the
overflow, `fpe_last_fpsr = 0x000032c8`: OPERR **and** OVFL **and** INEX2 all raised, with only
OVFL enabled in FPCR (`0x1000`). An unmasked derivation would have tested OPERR first and returned
`FPE_FLTINV` (7). It returned **4**. So `raised = fpsr & fpcr & FPSR_EXCP` masks correctly before
the priority ladder runs, which is exactly the property the ordering depends on.

The mask is also right by inspection and worth recording, because it is the one place a stray bit
could get in: `FPSR_EXCP` is `0x0000ff00` (`m68k/fpreg.h:51`), while FPCR's low byte carries the
rounding/precision **mode** bits (`FPCR_MODE 0x000000ff`, `:79`) and FPSR's low byte carries the
**accrued** exception byte (`FPSR_AEX 0x000000f8`, `:61`). Without the `FPSR_EXCP` term,
`fpsr & fpcr` could set bits from those two unrelated bytes. The term is present.

### 6.3 Registered readings and standing limits

* `si_code` agreement holds: **3** for div-zero and **4** for overflow on both beds.
* `si_addr` agrees whenever the instruction after the faulting one is itself an FP instruction,
  and differs otherwise. `fpe_last_fault_pc` names the faulting instruction on the emulated side
  so the difference is readable directly.
* Limits unchanged from round 3, and neither is closed here: the reference side is Amiberry's
  softfloat model of the 68060 FPU, not silicon (the definitive A/B still wants a Mercury or
  A3640); and only two of the six enabled-exception classes have been compared.

---

## 7. Corrections to the earlier documents

Round 3 contradicted four claims. They are corrected here rather than edited into the round-2
document, which stays the round-2 record.

| Document | Claim | Corrected to |
|---|---|---|
| `FPE-GLUE-DESIGN.md:364` (§4.4) | "the two must be equal" | False for `FBcc`/`FDBcc`, whose taken branch legitimately moves the PC off the straight line. §4 above restates the instrument. |
| `FPE-GLUE-DESIGN.md:488-492` (§5.2) | `si_addr` — "the two agree without being made to" | A coincidence, not a property: they agree iff the instruction after the faulting one is itself an FP instruction. §6.1. |
| `FPE-GLUE-DESIGN.md:790-791` (§9 item 10) | `fpe_fmt2_n` latches the format-2 frame on an 040 rig | Structurally unreachable as designed — the decline runs first. §5. |
| `FPE-GLUE-DESIGN.md:276-283` (§4.3) | AMIX's `cputype` is a `short`, per `sys/systm.h:18` | The declaration says `short`; **this port's own definition is `.long`** (`src/cputype060.s:21`) and every other reader in the port treats it as one. §3. |
| dispatch (round 4, FIX 6) | "FLTDIV agreed, FLTOVF did not" | Both `si_code`s agreed. The FLTOVF row's divergence is `si_addr`. §6. |

---

## 8. Parked — named so they are not read as covered

**In this repository, out of this lane**

* **`uptime`'s load averages are garbage** (6.4 million). The FP *rendering* is correct — the
  fractional part prints and the format is right — so the failure is in the input: `uptime` reads
  `avenrun[]` out of kernel memory and the value it reads is wrong. A pre-existing AMIX defect the
  FPE lane un-masked, because on a stock LC kernel `uptime` cannot run at all. **Not an FP defect
  and not fixed here.** Needs an owner; the cross-check on an FPU rig is a one-liner and was not
  run (`/usr/bin/uptime` is absent there).
* **The FPE kernel is not sha-reproducible by construction.** `src/stamp_buildid.py` writes a
  per-day, per-machine incrementing sequence into a 16-byte `buildid` field at file offset
  `0x114c04`; round 3's "wrong" hash was seq 51 versus seq 52 with all other 1,844,626 bytes
  identical. Any future "expect sha X" gate must pin the sequence or compare modulo that field.
  Recorded here; the build-side change belongs to the shared build tooling.

**Not in this repository**

* The `bfffo` SGS bit-field repair is still duplicated in `src/mk_fpe_cc.py` and belongs upstream
  in the cross-compiler wrapper's own `fix_asm` chain (§8.2, carried forward unchanged).
* The default 060-poc bench rig cannot serve as a real-FPU reference for IEEE exceptions: its FPU
  implements neither the exception status bits nor the FPCR trap enables (FPSR came back
  `0x02000000` — condition-code byte set, exception byte `0x00`). `fpu_softfloat=true` +
  `fpu_strict=true` does model them and is what round 3's A/B ran on.

**Round-5 bench items that are not kernel fixes**

* **The dirty-root cure was never tested.** Rig A was power-cut and came back clean, so the root
  was never dirtied. Round 5 should dirty it deliberately (heavy I/O, then cut) and confirm the
  16-second reboot loop is broken.
* Deferred si_addr reporting (§6.1) — a decision to take, with the mechanism now fully written
  down.

---

## 9. What round 5 must measure — one row per fix

| # | Fix | Registered reading |
|---|---|---|
| 1 | signal delivery from the success path | SIGALRM arrives into a pure-FP loop; `kill -9` works; `fpe_sigpend_n` and `fpe_sigdeliv_n` > 0 after the test, 0 on a quiet boot; `fpe_sigpend_n ≪ fpe_done_n` |
| 2 | exec/sendsig gates | `execb` reads `fpcr=0x0000 fp0=0.000`; `fpi_ss_skip_n = 0`; `fpe_ss_setup_n` and `fpe_exec_setup_n` > 0; both 0 on FPU rigs |
| 3 | `cputype` width | `fpe_cputype_amix = 60`, `fpe_cputype = 3`, `fpe_cputype_bad_n = 0` on the LC bed; initialisers on FPU rigs |
| 4 | the length instrument | `fpe_advmiss_n = 0` and `fpe_advnofetch_n = 0` across a full session; `fpe_advctl_n` large; `fpe_c_opword` a real `FBcc` |
| 5 | the format census | `fpe_v11_fmt2_n > 0` and `fpe_v11_fmt2_word = 0x202c` on a 68040 rig, with `fpe_entry_n` still 0 |
| 6 | si_code / si_addr | codes agree (3, 4); `fpe_last_fault_pc` names the faulting instruction; the si_addr rule of §6.1 reproduces |
| — | the bar | every behavioural `fpe_*` counter at its initialiser on both FPU rigs, `fpe_v11_*` excepted by name |
