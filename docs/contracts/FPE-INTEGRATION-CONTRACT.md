# NetBSD/m68k FPE integration contract — the AMIX side of the seam

Round 1 of the soft-FPU lane: **the contract and the vendor import only.** No glue, no
relink change, no edit to an extracted file. Everything below is measured from this tree, from
the pinned NetBSD tarball, and from `build/unix-040`; where something is inferred rather than
measured it says so in the same sentence.

> **PROVENANCE.** Sections 3–6 are structural analysis of the stock AMIX kernel image this
> port patches — disassembled bodies, u-area offsets, jump-table contents — measured from
> `build/unix-040` and cited by address. Where the NetBSD emulator or Motorola's support
> packages are discussed they are described by file, line and mechanism; no vendor text is
> reproduced. Same class as `docs/060-F4-M2-ATT7-RESULTS-260825.md` and the ATT8 results.

The normative precedent is `docs/contracts/FPSP-INTEGRATION-PLAN.md`. That plan recommends
*against* the FPE as the 040 path and it is still right about the 040. This lane exists for the
case it explicitly reserves the FPE for — `:157-161`, "68LC040 or another genuinely absent-FPU
target" — which is the 68LC060 this port now runs on.

---

## 1. Evidence base

| Artifact | Identity |
|---|---|
| Vendor source | `usr/src/sys/arch/m68k/fpe/` from NetBSD **10.1** `syssrc.tgz`, sha256 `76a600e703d2e964753323e264d3ec07d0c6cbe134648fc8f0f13ed9faaa1be4`, verified before extraction (`src/extract_fpe.sh`). Rounds ≤12 used NetBSD 9.4, sha256 `5e1f101748d8ff04a37aba845133e0f5804d1ca9b995c99f05cc39874ab3120b`; the move and its equivalence proof are `FPE-R10-VEC60.md` §13 |
| Extracted copy | `build/fpe-src/`, 25 files, byte-identical to a fresh extraction; gitignored, never checked in |
| Kernel image read | `build/unix-040`, sha256 `b1351544c151dc0d33715fe0bb42c86f119dc60e48b0c0d4d2be108826fc9fe4`, ELF 32-bit MSB relocatable m68k |
| Headers read | `build/sysroot-modelb/usr/include/` (the Model-B mirror sysroot, `src/mk_modelb_sysroot.sh`) |
| Toolchain | `m68k-cbm-sysv4-gcc` = gcc 2.7.2.3 / GNU as 2.8.1, `AMIX_KERNEL_CFLAGS` from `gcc-cross-amix/build/env.sh:8` |

**`build/unix-040` is not the image `FPSP-INTEGRATION-PLAN.md:19-25` pins** (`5bd37386…`). It is a
later link of the same stock bodies with this port's overrides on top; every stock address quoted
below was checked against its own relocation rather than carried over from that plan.

**The kernels this lane links are NOT sha-reproducible, and an expect-sha gate must not pin a file
offset.** `src/stamp_buildid.py` stamps a 16-byte `buildid` field carrying a per-day, per-machine
incrementing sequence, so two links of byte-identical *code* differ in those bytes and nowhere
else — round 5's identity check against the round-4 artifact found the two images the same 1,897,862
bytes long and differing in exactly **2 bytes**, the sequence digits inside that field. The trap is
that the field's **file offset moves with `.data`**: it was `0x114c04` in rounds 2–3 and `0x114dd4`
in round 5, because round 4's new counters grew the section ahead of it, and the next counter will
move it again. So any gate of the "expect sha X" kind must **derive the field's offset from the
symbol table, or compare modulo the field — never pin the offset numerically.**
(`Amix/tmp/2026-08-27-fpe-r5/RESULTS.md`, artifact gate; the build-side change belongs to the
shared build tooling, not to this lane.)

---

## 2. What the package actually is

`files.fpe` is the whole build unit: **20 plain C compilations, no assembly, no MD
files.** `README:45-49` states the coverage gap in the vendor's own words — everything
except packed BCD, `FSAVE` and `FRESTORE`. `README:113-115` gives the per-instruction contract
(`struct fpn *fpu_op(struct fpemu *fe)`).

The single entry point is

```c
int fpu_emulate(struct frame *, struct fpframe *, ksiginfo_t *);      /* fpu_emulate.h:246 */
```

with a two-valued return: **0 = the instruction was emulated and the frame's PC advanced;
-1 = a signal is requested and has been written into the `ksiginfo_t`** (`fpu_emulate.c:54-59`,
the `fpe_abort` macro, and `:238`, where a non-zero `sig` is handed to `fpe_abort` together with
the frame, the `ksiginfo_t` and a zero code).

Two properties of the body are load-bearing and neither is obvious from the file list:

* **`fpu_emulate()` holds its state in `static` objects, not on the stack** —
  `fpu_emulate.c:89-90` gives its one `instruction` object and its one `fpemu` object `static`
  storage rather than automatic. That is the 148 bytes of `.bss` the compile probe measures in
  `fpu_emulate.o`. **The emulator is not re-entrant.** See §7.3; this is the sharpest round-2
  risk in the package.
* **`fpu_emulate()` contains its own format-4 arm** — `fpu_emulate.c:108-125`. When
  `frame->f_format == 4` it takes the faulting instruction's address out of
  `frame->f_fmt4.f_fslw` and writes it back into `frame->f_pc` before decoding. That is the
  same field, and the same fix-up, that `src/fpsp060_glue.s:422` performs. It decides the
  attach point (§6).

---

## 3. The seven seam classes

`FPSP-INTEGRATION-PLAN.md:139-154` lists seven reasons the FPE is not drop-in. Each is answered
here with the AMIX-side fact and its evidence.

### 3.1 `struct frame` and `struct fpframe`

**`struct frame`** (NetBSD `m68k/cpuframe.h:34-45` in the pinned tarball) is
`{ int tf_regs[16]; short tf_pad, tf_stackadj; u_short tf_sr; u_int tf_pc; u_short tf_format:4, tf_vector:12; }`
plus a union of the per-format tails, with `f_regs`/`f_pc`/`f_format`/`f_vector`/`f_fmt4`
supplied as `#define`s at `cpuframe.h:130-143`.

AMIX's equivalent is not a struct; it is the layout `nullvect` builds and `u_trap` reads, and it
was decoded out of `build/unix-040` for this document:

```text
u_trap's frame, relative to its own %fp (u_trap = 0x5a47e, linkw %fp,#-48)
    %fp@(8)        u.u_ar0  <- the USP pseudo-register           (0x5a48c-0x5a492)
    %fp@(12..71)   the 60-byte D0-D7/A0-A6 block nullvect pushed
    %fp@(72)       exception SR       (word)
    %fp@(74)       exception PC       (long)
    %fp@(78)       format/vector word (format nibble in bits 0-3, vector offset in bits 4-15)
```

8 + 4 + 60 = 72 closes the arithmetic, and `src/fpsp_glue040.s:206-214` builds exactly this
block from the other side. `u_trap` reads the vector with
`bfextu %fp@(78),4,12,%d0 / asrl #2,%d0` (`0x5a4ba`) and the **format nibble separately** with
`bfextu %fp@(78),0,4,%d0` (`0x5a658`), so both fields are live on the AMIX side too.

**Mapping verdict.** NetBSD's `tf_regs[16]` is D0-D7 then A0-A6 then A7, in that order; AMIX's
60-byte block is D0-D7 then A0-A6 — **fifteen registers, not sixteen**, with A7 living
separately as the USP pseudo-register at `u_ar0` (`src/fpsp_glue040.s:209-213`). A `struct frame *`
handed to `fpu_emulate()` therefore cannot simply point at the AMIX block: `f_regs[15]` would
read the exception SR. The glue must either build a `struct frame` shim or splice the USP in.
This is the single largest structural difference in the seven classes.

**`struct fpframe`** (NetBSD `m68k/cpuframe.h:149-179`) is the FSAVE state union *followed by*
`fpf_regs[8*3]`, `fpf_fpcr`, `fpf_fpsr`, `fpf_fpiar`. The FPE touches **only that tail** — the
whole extracted tree references `fpf_regs`, `fpf_fpcr`, `fpf_fpsr`, `fpf_fpiar` and nothing else
from the union.

AMIX's `fpu_info` (`sys/fpu.h:57-65`, offsets confirmed in `src/fpu060.s:102-108` and again by
`fpu_ptr`'s own relocation, below) is:

```text
    fpu_info @ u + 0x9c = u + 156         fpu_ptr's .data value is a reloc "u + 9c"
      +0    long  ustate                  (bit 0 = UFPRWRT)
      +4    fpu_t regs   = fpu_reg[8][3] at +4..+99, fpu_control +100, fpu_status +104,
                           fpu_iaddr +108          -> absolute u+160 .. u+267, 108 bytes
      +112  int   fsave[FSAVEMAX=54]                -> absolute u+268 .. u+483, 216 bytes
```

**`fpu_info.regs` is field-for-field AND order-for-order the tail of NetBSD's `struct fpframe`:
eight 12-byte registers, then control, then status, then IAR.** That is the cheapest seam in the
whole document — an `fpf_*` pointer can be a fixed bias off `fpu_ptr`, with no transposition.

The trap is one layer out: **AMIX has a *second*, differently ordered, 108-byte FP register
layout.** `fpregset_t` (`sys/regset.h:42-47`) is `f_pcr, f_psr, f_fpiaddr, f_fpregs[8][3]` —
control words **first**. `prgetfpregs` exists precisely to transpose between them, and §4.2
shows it doing so instruction by instruction. Any glue that confuses the two writes the FP
registers three longwords out of place.

### 3.2 Machine register numbering and saved-register offsets

| | NetBSD | AMIX |
|---|---|---|
| Integer file | `tf_regs[16]`, D0-D7 = 0-7, A0-A7 = 8-15 | `gregset_t[NGREG=18]`, `R_D0..R_D7` 0-7, `R_A0..R_A7` 8-15, `R_PC` 16, `R_PS` 17 (`sys/regset.h:16-39`) |
| In the trap frame | A7 is `tf_regs[15]` | A7 is the USP pseudo-register at `u_ar0`, outside the 60-byte block |
| FP file | `fpf_regs[8*3]`, regs first | two layouts: `fpu_t` regs-first, `fpregset_t` control-first (§3.1) |

The register **numbering** agrees (D0-D7 = 0-7, A0-A7 = 8-15); the **offsets** do not, on both
the integer side (A7) and the FP side (control-word position). Numbering agreement is what makes
`fpu_calcea.c`'s `ea_regnum` usable unchanged; offset disagreement is what the shim must absorb.

### 3.3 `ksiginfo_t` and signal-code construction

AMIX has no `ksiginfo_t`. Its kernel-side structure is **`k_siginfo_t`** (`sys/siginfo.h:150-183`),
and `u_trap` builds one on its own stack: `bzero(&%fp@(-40), 28)` at `0x5a4a2-0x5a4ac`, so the
kernel part is **28 bytes** with the field offsets `src/wb040.s:443` already records —
`si_signo +0`, `si_code +4`, `si_errno +8`, `_fault._addr +12`.

Field-by-field the FPE's use maps cleanly:

| FPE (`fpu_emulate.c:54-59`) | AMIX |
|---|---|
| `ksi_signo` | `si_signo`, `%fp@(-40)` |
| `ksi_code` | `si_code`, `%fp@(-36)` |
| `ksi_addr = frame->f_pc` | `si_addr`, `%fp@(-28)` — and `u_trap` already presets it to the stacked PC at `0x5a4b2` (`movel %fp@(74),%fp@(-28)`) |

**But the codes do not map, because the FPE does not produce them.** `fpu_emulate.c:237-238`
hands a non-zero `sig` to `fpe_abort` with a **code argument of 0** — si_code 0 for every
arithmetic signal. Only the
four early aborts carry real codes (`SIGSEGV`/`SEGV_ACCERR` at `:130` and `:149`;
`SIGILL`/`ILL_ILLOPC` at `:136` and `:141`), and those spellings happen to be AMIX's too
(`sys/siginfo.h:29-31`, `:57-58`).

So **frozen decision (2) cannot be satisfied by the emulator code; the glue must derive the
si_code itself.** The material is available and exact: `fpu_upd_excp()` (`fpu_emulate.c:243-272`)
writes the final FPSR back to `fe->fe_fpframe->fpf_fpsr` and returns `SIGFPE` iff
`(fpsr & fpcr & FPSR_EXCP)`. The enabled-and-raised bits are therefore still in `fpf_fpsr` when
the glue regains control, and the mapping to SVR4 is one table:

| FPSR bit (`m68k/fpreg.h`) | SVR4 si_code (`sys/siginfo.h:43-50`) |
|---|---|
| `FPSR_DZ` | `FPE_FLTDIV` 3 |
| `FPSR_OVFL` | `FPE_FLTOVF` 4 |
| `FPSR_UNFL` | `FPE_FLTUND` 5 |
| `FPSR_INEX1`/`FPSR_INEX2` | `FPE_FLTRES` 6 |
| `FPSR_BSUN`/`FPSR_SNAN`/`FPSR_OPERR` | `FPE_FLTINV` 7 |

That table is finer than what the stock kernel itself produces on the same events (§5.3), which
is a decision the glue round has to take deliberately rather than inherit.

`sys/siginfo.h:132` carries `long _exop[3]` — "SIGFPE, contains the exceptional operand" — and
**`u_trap` never writes it** (no arm in §5.2 touches beyond `%fp@(-28)`). The FPE has the
exceptional operand in `fe.fe_f1`/`fe.fe_f2`. The slot is available and is the natural place for
it; recorded here as an opportunity, not a requirement.

### 3.4 NetBSD IEEE representation headers

`machine/ieee.h` and `sys/ieee754.h` supply `SNG_/DBL_/EXT_` widths, biases, masks and shifts —
24 distinct names across `fpu_explode.c`, `fpu_implode.c`, `fpu_cordic.c`, `fpu_exp.c`,
`fpu_hyperb.c`. **AMIX has no equivalent header at all.** `sys/fpu.h` describes the *hardware*
programmer's model (FPCR/FPSR bits, frame formats) and says nothing about IEEE field widths.

This class is pure arithmetic description with no AMIX counterpart to disagree with, so it is
the cheapest of the seven to satisfy: the two headers can be carried in as-is, or their contents
restated. The compile probe (§7) carried them in and all files that need them compiled.

### 3.5 `ufetch_*` helpers and user-memory semantics

The extracted tree calls exactly one such helper — **`ufetch_short`, 16 times**: 12 in
`fpu_calcea.c`, 4 in `fpu_emulate.c`. NetBSD's contract is `int ufetch_short(const void *, u_short *)`,
0 on success, error otherwise; the value is delivered through the out-parameter so it is never
confused with a failure code.

AMIX exports `fubyte 0x3dc`, `fuword 0x420`, `subyte 0x462`, `suword 0x4ae`, `copyin 0x4fa`,
`copyout 0xdb3dc` (`nm build/unix-040`). **There is no 16-bit fetch**, and `fubyte`/`fuword`
return -1 on fault, which is indistinguishable from a legitimate all-ones datum — precisely the
confusion `ufetch_short` avoids.

The in-repo precedent is already written and hardware-accepted: `src/fpsp060_glue.s:504-530`
(`Lco_imem_rw`) implements a two-byte user fetch as `copyin(user_src, stack_landing, 2)` with the
failure reported separately and `d0` left defined on failure, and `:66-71` records why `copyin`
was chosen over `moves` under a nofault pad. `ufetch_short` maps onto that shape one-to-one.

`fpu_calcea.c` also calls `copyin` and `copyout` three times each, with SVR4's own 3-argument
shape. `src/fpsp_glue040.s:240-253` already calls both. That part of the seam is free.

### 3.6 `copyin`, `copyout` and `panic` interfaces

`copyin`/`copyout`: as above, shape-compatible, already used by this port's own glue.
**`FPSP-INTEGRATION-PLAN.md:350-367`'s mandatory error rule applies unchanged** — a nonzero
return must not be ignored, and `:370-380`'s sleeping-copyin/`swtch` ownership hazard applies
*more* sharply here than it does to the FPSP, because of the static state in §2 and §7.3.

`panic`: **11 call sites in the extracted tree**, and they are the whole of frozen decision (8)'s
surface:

```text
fpu_add.c:192      fpu_calcea.c:78, :308, :449      fpu_explode.c:255
fpu_fmovecr.c:81   fpu_fscale.c:319                 fpu_implode.c:301, :482
fpu_subr.c:91, :102
```

AMIX's `panic` is reachable (`src/fpsp_glue040.s:323` calls it), so the interface is not the
problem — the **policy** is. Decision (8) says a user-process inconsistency becomes SIGILL plus a
latched counter and one console line, never a panic. Since no emulator file may be edited, the
only conforming implementation is a `panic` **provided by the glue** and linked ahead of the
kernel's, which classifies on origin. That is a name the whole kernel shares, so it cannot be a
plain strong override: it has to be a differently-named symbol reached by compiling the FPE with
`-Dpanic=fpe_panic`, or the equivalent. **Registered as a round-2 design item; not decided here.**

Note also that three of the eleven use `__func__` and printf-style `%s` formatting
(`fpu_calcea.c:78`, `:308`, `:449`). AMIX's `panic` takes a plain string in this port's usage;
`__func__` is a gcc 2.7 extension that the probe accepted, but the format handling is a second
thing the replacement must get right.

### 3.7 Trap-PC adjustment and effective-address conventions

Three conventions, all measured:

1. **PC advance on success.** `fpu_emulate.c:217-218` adds `insn.is_advance` to the frame's PC
   on two outcomes: no signal at all, and `SIGFPE`.
   The emulator advances the PC *itself*, including on SIGFPE — with the vendor's own comment
   saying the SIGFPE case is not clearly right and is kept because the signalling regression
   tests need it. AMIX's `ureturn` path expects the frame's PC to be final
   (`FPSP-INTEGRATION-PLAN.md:281-324`), so no second adjustment may be applied.
2. **Format-4 PC reconstruction.** `fpu_emulate.c:108-125` — the faulting address comes from
   `f_fmt4.f_fslw` (+12 in the frame), not from the stacked PC. §6 is entirely about this.
3. **Effective address.** `fpu_calcea.c` decodes the EA from the instruction stream, except in
   the format-4 case where it takes the CPU's precalculated EA out of the frame
   (`fpu_emulate.h:177-178`, `EA_FRAME_EA`; `fpu_calcea.c:105-108`). On an LC060 that is the
   normal path, so `f_fmt4.f_fa` (+8) is live and must not be clobbered before `fpu_emulate()`
   runs.

**An eighth item the plan's list does not name, found by the probe:** `fpu_calcea.c:118` reads
the global **`cputype`** and compares it against `CPU_68060`. NetBSD's encoding
(`m68k/m68k.h:66-71`) is `CPU_68020 = 0 … CPU_68060 = 3` on an `extern int`. AMIX declares
`extern short cputype` with values 40/45/70/780 (`sys/systm.h:18`). **Same name, different type,
different encoding** — the compiler catches it (§7.2) and it is the only hard compile failure in
the whole package. It is also the only place a silent wrong answer could have got through if the
types had happened to agree.

---

## 4. `prgetfpstate` and `prsetfpstate`, decoded

Both bodies decoded from `build/unix-040` for the first time. Call sites were already recorded at
`docs/060-F4-M2-ATT7-RESULTS-260825.md:286-291`; the bodies were not.

### 4.1 The two functions

```text
prgetfpstate (0x63874, 54 bytes):        prsetfpstate (0x638aa, 54 bytes):
    a0 = prumap(arg0)                        a0 = prumap(arg0)
    bcopy(a0 + 268, arg1, 216)               bcopy(arg1, a0 + 268, 216)
    prunmap(arg0)                            prunmap(arg0)
```

Argument order read off the push order (m68k SysV pushes right to left): `prgetfpstate` pushes
`#216`, then `%fp@(12)`, then `%a0@(268)`, so the `bcopy` is `(src = uarea+268, dst = caller, n = 216)`;
`prsetfpstate` pushes `#216`, then `%a0@(268)`, then `%fp@(12)`, i.e. the mirror. Relocations at
`0x63882`/`0x63894`/`0x6389c` and `0x638b8`/`0x638ca`/`0x638d2` name `prumap`, `bcopy`, `prunmap`.

**They are a verbatim 216-byte copy of `fpu_info.fsave[54]` and nothing else.** The arithmetic
closes three independent ways: `216 = FSAVEMAX(54) × 4` (`sys/fpu.h:57`); `268 = 156 + 112` =
`fpu_ptr + FP_FSAVE` (`src/fpu060.s:107`); and `fpu_ptr`'s own `.data` word at `0x4fe0` carries
the relocation `u + 9c`, i.e. 156. Neither function touches the programmer's model, and neither
reorders anything.

### 4.2 The transposition lives next door, in `prgetfpregs`

`prgetfpregs` (`0x63318`) is the function that *does* reorder, and it is worth reading beside the
pair above because a glue author will otherwise assume the FP state is one shape:

```text
    a0 = prumap(arg0);  a3 = a0 + 160            /* = u + 156 + 4 = fpu_info.regs */
    dst[0] = a3[96]     /* fpu_control -> f_pcr     */
    dst[4] = a3[100]    /* fpu_status  -> f_psr     */
    dst[8] = a3[104]    /* fpu_iaddr   -> f_fpiaddr */
    for (i = 0; i <= 2; i++) for (r = 0; r <= 7; r++)
        ((long *)(dst + 12 + r*12))[i] = ((long *)(a3 + r*12))[i]
```

`a3 = u + 160` is `fpu_info + FP_REGS`, which confirms `fpu_info @ u+156` a fourth time. The
control triple moves from offsets 96/100/104 to 0/4/8 and the 8×3 file moves from 0 to 12 — the
`fpu_t` ↔ `fpregset_t` transposition of §3.1, byte-exact.

### 4.3 What `savecontext` does with them, and why the frozen 68881 choice is right

`savecontext` (FP block at `0x58f74-0x58fe0`, relocations naming every callee):

```text
    prgetstate(u_ar0, ucp+216)                       /* mc_state <- the exception frame */
    if (prhasfp() == 0) { ucp->uc_flags &= ~UC_FPU; goto out; }   /* 0x58fdc-0x58fe0 */
    fpu_save()
    if ((*(long *)(u + 0x10c) & 0x00ff0000) == 0x380000)          /* 0x58f90-0x58fa2 */
            bset #3, (u + 0x144)                                   /* 0x58fa6 */
    prgetfpregs(_, ucp+108)
    prgetfpstate(_, ucp+308)
    fpu_restore()
```

The two magic addresses resolve, and they resolve to `sys/fpu.h`:

* `u + 0x10c = u + 268 = fsave[0]`, masked with `FRMTMASK 0xff0000` and compared against
  **`FIDLE882 = 0x380000`** (`sys/fpu.h:73`);
* `u + 0x144 = u + 324 = fsave[14]`, and **`BIUFLG882 = 14`** (`sys/fpu.h:84`).

So stock `savecontext`, on seeing a **68882 idle** frame, pokes bit 3 of the BIU-flags longword
before shipping the state to userland.

**This is direct evidence for frozen decision (9)'s "68881-idle-frame shape".** `FIDLE881` is
`0x180000` (`sys/fpu.h:72`), which does not match the `0x380000` test, so an emulated frame
presented as a 68881 idle frame **skips the BIU poke entirely**. Presenting a 68882 idle frame
would walk straight into a fix-up written for real 68882 silicon. The decision was taken on other
grounds; it also happens to be the only one of the two that avoids this branch.

`restorecontext` is the mirror (`0x58e84-0x58ecc`): `prsetstate`, then a `uc_flags & UC_FPU` test
(`0x58e8c`, `moveq #8 / andl (%a2)`), then `prhasfp()`, then `fpu_save()` — *save* before set, to
take ownership of the u-area image — then `prsetfpregs(ucp+108)`, `prsetfpstate(ucp+308)`,
`fpu_restore()`.

### 4.4 Correction to frozen decision (9)'s "784-byte" wording

`ATT7 §7.3` establishes that `mc_state[4..199]` — 196 longwords, **784 bytes** — is never written
and is nevertheless checksummed and copied to userland on every signal, because `prhasfp()` is 0
on the LC060 and the whole FP branch is skipped.

With `fpu_emul` making `prhasfp()` true, `prgetfpstate` writes **216 bytes starting at `ucp+308`**.
`(308 − 216)/4 = 23`, and `216/4 = 54`, so it fills exactly `mc_state[23..76]`.

**So the frozen decision's "the 784-byte never-written `mc_state` field becomes genuinely
written" is true of 216 of those 784 bytes, not of all of them.** The residue is
`mc_state[4..22]` (19 longwords, 76 bytes) plus `mc_state[77..199]` (123 longwords, 492 bytes)
= **568 bytes still uninitialised kernel stack**, still checksummed, still copied out. That is
not a reason to change the decision — it is a reason not to record the leak as closed by this
lane. It also confirms `ATT7 §7.3`'s predicted bench row ("Rig B should show a materially smaller
never-written region") and puts a number on it: 216 bytes smaller, exactly.

Incidentally this also names the origin of the `mc_state[77]` figure `ATT5 §2.5` carried:
`23 + 54 = 77` is the **end** of the FP state area, not its start. `ATT7` called it an
off-by-a-base from `308/4`; both readings land on 77 and the correct start is 23.

---

## 5. The `u_trap` vector→signal jump table, re-verified

Re-derived from `build/unix-040` rather than cited. The dispatch's figures were treated as
hypotheses; two of them needed correcting.

### 5.1 The dispatch mechanism

```text
0x5a47e  u_trap:  linkw %fp,#-48
0x5a4a2           bzero(&%fp@(-40), 28)              <- the local k_siginfo_t, 28 bytes
0x5a4b2           %fp@(-28) = %fp@(74)               <- si_addr = the stacked PC, always
0x5a4ba           bfextu %fp@(78),4,12,%d0 ; asrl #2 <- vector NUMBER from the fmt/vec word
0x5a4c8           cmpl #55,%d0 ; bhiw 0x5a7bc        <- > 55 goes to the default arm
0x5a4ce           movew %pc@(0x5a4de,%d0:l:2),%d0
0x5a4d6           jmp   %pc@(0x5a4de,%d0:w)
0x5a4da           (4 bytes of .swbeg filler)
0x5a4de           the table: 56 signed 16-bit displacements from 0x5a4de
```

**56 entries, 16-bit, based at `0x5a4de`, dispatching on vector 0–55** — confirmed exactly as
hypothesised. The 4-byte gap at `0x5a4da` is the SGS `.swbeg` filler the cross-gcc wrapper
already knows about.

### 5.2 The decoded table

Every arm writes `si_signo` to `%fp@(-40)`, `si_code` to `%fp@(-36)` and the /proc fault class to
`%fp@(-4)` — confirmed, all three, in every arm below.

| Vectors | Arm | si_signo | si_code | /proc class (`sys/fault.h`) |
|---|---|---|---|---|
| 0 | `0x5a57c` | — | — | — (tail-calls `preempt`) |
| 2 | `0x5a586` | from `usrxmemflt` | from `usrxmemflt` | selected at `0x5a5a2` from si_signo: 11→6, 10 or 7→5, 8→9, else 1 |
| 3 | `0x5a676` | 10 SIGBUS | 1 `BUS_ADRALN` | 5 `FLTACCESS` |
| 4 | `0x5a68c` | 4 SIGILL | 1 `ILL_ILLOPC` | 1 `FLTILL` |
| 5 | `0x5a6cc` | 8 SIGFPE | 1 `FPE_INTDIV` | 8 `FLTIZDIV` |
| 6 | `0x5a6e2` | 8 SIGFPE | 2 `FPE_INTOVF` | 5 `FLTACCESS` |
| 7 | `0x5a6f8` | 8 SIGFPE | 2 `FPE_INTOVF` | 7 `FLTIOVF` |
| 8 | `0x5a6a0` | 4 SIGILL | 5 `ILL_PRVOPC` | 2 `FLTPRIV` |
| 9 | `0x5a70e` | 5 SIGTRAP | 2 | 4 `FLTTRACE` |
| **10, 11, 34-41, 43-47** | **`0x5a6b6`** | **12 SIGSYS** | **4** | **1 `FLTILL`** |
| 15, 24 | `0x5a7b2` | — | — | — (tail-calls `intnull`) |
| 32, 42 | `0x5a54e` | 5 SIGTRAP (trace only) | 2 | 4 `FLTTRACE` (tail-calls `systrap`) |
| 33 | `0x5a72a` | 5 SIGTRAP | 1 | 3 `FLTBPT` — and backs the PC up 2 (`subql #2,%fp@(74)`) |
| 49 | `0x5a744` | 8 SIGFPE | 6 `FPE_FLTRES` | 9 `FLTFPE` |
| 50 | `0x5a75a` | 8 SIGFPE | 3 `FPE_FLTDIV` | 9 `FLTFPE` |
| 51 | `0x5a770` | 8 SIGFPE | 5 `FPE_FLTUND` | 9 `FLTFPE` |
| 53 | `0x5a786` | 8 SIGFPE | 4 `FPE_FLTOVF` | 9 `FLTFPE` |
| **48, 52, 54, 55** | **`0x5a79c`** | **8 SIGFPE** | **7 `FPE_FLTINV`** | **9 `FLTFPE`** |
| 1, 12-14, 16-23, 25-31 | `0x5a7bc` | 9 SIGKILL | — | — (fault class left 0) |

**Two corrections to the prior finding.**

* **Vector 42 is *not* on the SIGSYS arm.** The prior note said "A-line and unassigned traps
  34-47". Measured, the SIGSYS arm carries 10, 11, 34-41 and 43-47; **42 shares the vector-32 arm
  and tail-calls `systrap`.** The claim is right for thirteen of the fourteen vectors it named.
* **Vectors 48-55 do *not* each carry their own `FPE_FLT*` code.** Four of them —
  **48 BSUN, 52 OPERR, 54 SNAN, 55 unsupported-data-type — share one arm and one code,
  `FPE_FLTINV`.** Only 49, 50, 51 and 53 have distinct arms. The prior claim ("vectors 48-55
  already carry correct SVR4 `FPE_FLT*` si_codes") is true but coarser than it sounds, and §5.3
  is the consequence.

Everything else in the prior finding is confirmed: `u_trap` at `0x5a47e`, the 56-entry 16-bit
table based at `0x5a4de`, the SIGSYS arm at `0x5a6b6` shared by vector 11 with A-line, and the
three destination offsets `-40`/`-36`/`-4`.

**The default arm is the console message this port has quoted for months.** `0x5a7bc` pushes the
stacked PC and the **vector *offset*** (`bfextu %fp@(78),4,12` with *no* `asrl`), then
`printf("u_trap WARNING: SIGKILL sent to pid %d (%s) because of vector 0x%x, pc=0x%x\n", …)`
(string at `0x5a430`, reloc to `printf` at `0x5a7e6`), then sets si_signo = 9. That is why
`src/fpsp060_glue.s:126-127` reads `vector 0xF0` for vector 60: the kernel prints 60 × 4.

**The tail.** `0x5a7f8` skips the /proc stop machinery when the fault class is 0 or si_signo is 9;
otherwise `stop_on_fault`. Then, unconditionally, `trapsig(p, &%fp@(-40))` at `0x5a884`, then
`runrun`/`preempt`, `issig`/`psig`, `ev_istrap`/`ev_traptousr`, `addupc`.

### 5.3 What this means for the fpe arm

The cheapest correct wiring is the one this port already uses for the FPSP: leave the raw frame
alone and `jmp nullvect`, letting `u_trap`'s own arm build the `k_siginfo_t` from the frame's
vector. It costs nothing and it cannot drift from stock policy.

**It also cannot express what the emulator knows.** An FPE that has determined the exception is
`FPSR_SNAN` rather than `FPSR_OPERR` has no vector to encode that in: 52 and 54 land on the same
arm and the same `FPE_FLTINV`. And on an LC060 the exception did not *arrive* on vectors 48-55 at
all — it arrived on vector 11 (§6), whose arm is SIGSYS.

So frozen decision (2) forces the other shape: the glue **builds the `k_siginfo_t` itself** —
`src/wb040.s:449-472` (`Lu_siginfo`) is the in-repo template for doing that and for reaching the
existing policy — using the §3.3 FPSR→si_code table. Registered as the round-2 design choice it
is, with the `u_trap` table above as the definition of "what stock would have said" so that any
divergence is deliberate.

---

## 6. Attach point and frame-format survey

Frozen decision (10) puts the `fpu_present` test at the **top of `fpsp_vec11`
(`src/fpsp_glue040.s:37`), before the `cputype` test.** This section is the evidence for what
the fpe entry will actually be looking at there.

### 6.1 Why the stock path alone would be dead

`fpsp_vec11` gates `cputype == 40` first (`:38-39`) and everything else falls to `Lv11_stock`
(`:45`), which on a 68060 jumps into the 060 package (`:57-61`). On a part with no FPU the
package's F-line dispatcher classifies the exception as *FP disabled* and exits through
`_060_real_fpu_disabled` → `Lco_fpu_disabled` (`src/fpsp060_glue.s:406`) → the no-FPU arm
`Lco_fpudis_nofpu` (`:419-423`) → `nullvect`.

This is measured on **real silicon**, not inferred from the bench:
`docs/060-F4-M2-ATT5-RESULTS-260825.md:252` — real A4000 + Z3660, socketed 68LC060 at 50 MHz —
records `f60_entry_n = f60_real_n = f60_fpudis_n = f60_fpudis_nofpu_n = 5,406`. Since the
standing invariant is `f60_entry_n == f60_fpudis_n + f60_fline_n`
(`docs/PLATFORM-LC060-Z3660.md:296`), `f60_fline_n` was **0**: every one of 5,406 vector-11 events
on real LC060 silicon took the FP-disabled arm, and `Lco_fline` never fired.

So an arm placed only on the stock 040 path would never execute, and one placed at `Lco_fline`
would never execute either. Decision (10) is correct, and the reason is a measured 5,406-to-0
split rather than an argument.

### 6.2 The three frame shapes at the top of `fpsp_vec11`

Vector 11 is reached with three materially different frames, and **the format nibble is the only
thing that distinguishes them**:

| Cause | Frame | fmt nibble | fmt/vec word | size | extra fields |
|---|---|---|---|---|---|
| genuine line-F (non-FP opcode), any CPU | four-word, format 0 | 0 | `0x002c` | 8 bytes | — |
| 68040 unimplemented FP instruction | six-word, format 2 | 2 | `0x202c` | 12 bytes | +8 **operand effective address** (0 when the operand is a register) — corrected below |
| 68060 FP disabled (incl. every LC060 event) | eight-word, format 4 | 4 | `0x402c` | 16 bytes | +8 `f_fea`, +12 `f_pcfi` |

Evidence: the format-2/`0x202c` pairing is Motorola's own, from the FPSP source in the pinned
tarball — `usr/src/sys/arch/m68k/fpsp/x_fline.sa` compares `EXC_VEC-4(a7)` against `UNIMP_VEC`
and, in the `fmovecr` fix-up, writes the word `0x202c` into the frame's format/vector slot to
re-badge it as the unimplemented-instruction exception, the comment at that site describing the
conversion as being between the six-word (unimp) and four-word frames. The format-4 shape is
NetBSD `m68k/cpuframe.h:60-68`, a two-longword `struct fmt4` — `f_fa` and `f_fslw`, aliased by
macro to `f_fea` and `f_pcfi`, the comment there recording those as the 060 FPU-disabled type-4
names — and is corroborated by `src/fpsp060_glue.s:417`/`:422` reading `%sp@(0xc)` — the +12
longword — which only exists in a 16-byte frame.

**Round 5 measured the format-2 row instead of citing it, and corrected half of it**
(`Amix/tmp/2026-08-27-fpe-r5/RESULTS.md` item 6). The pairing holds: `fpe_v11_fmt2_word` latched
`0x202c` off **2,057 genuine 68040 vector-11 frames** on an FPU-present 040 rig, every event on
that rig was format 2, and no other shape appeared — with `fpe_entry_n` still 0 and the FPSP's own
transcendental answers still exact to 15 digits, so the census perturbs nothing. See §8 item 2,
now closed.

**The `+8` longword is the OPERAND EFFECTIVE ADDRESS, not the instruction address.** Rounds 1–4 of
this table said "instruction address", and so did the matching comment in `src/fpe040.s`. Round 5
discriminated the two readings rather than arguing them: 2,007 frames taken by a register-to-
register `fsin` latched **0**, which no instruction-address reading permits; a second probe running
`fsin.d (%a0),%fp0` — a **memory** source operand — latched **exactly `0x800025a8`, the operand's
own data address**. The 68040 stacks the effective address of the instruction's memory operand
there, and 0 when there is none. Nothing in this tree consumes the field, so the correction changes
no behaviour and none of the census's scored readings; it changes what the field may be built on
later. The symbol keeps its round-4 name `fpe_v11_fmt2_ia` — renaming it is a code change for a
comment-level fact — and `src/fpe040.s` says so at both the store and the reservation.

**Consequence, and it is the first thing the fpe entry must do:** dispatch on the format nibble.
A format-0 frame at vector 11 is a genuinely illegal F-line word and must become SIGSYS
unchanged — `FPSP-INTEGRATION-PLAN.md:243-248` requires exactly this, and the emulator
enforces its half of it too (`fpu_emulate.c:133-141` aborts with `SIGILL`/`ILL_ILLOPC` when the
opword is not coprocessor-1 F-line). Handing the emulator a format-0 frame would make it fetch
the opword from the *stacked* PC, which for a format-0 frame is correct, so this is a policy
choice rather than a crash — but it converts SIGSYS to SIGILL for every bad F-line word in the
system, which is a user-visible ABI change and must not happen by accident.

### 6.3 The PC fix-up is already in the emulator code — do not do it twice

`Lco_fpudis_nofpu` (`src/fpsp060_glue.s:422`) does `movel %sp@(0xc),%sp@(0x2)`: stacked PC :=
`f_pcfi`, so that the frame nullvect receives names the faulting instruction.

`fpu_emulate()` does **the same thing, from the same field**, at `fpu_emulate.c:108-125`: on a
frame whose format is 4 it sets both `insn.is_pc` and the frame's own PC field from
`f_fmt4.f_fslw`, before any decoding happens.

At the **top of `fpsp_vec11`** the frame is untouched, `f_format` is 4, and the emulator's own arm
performs the fix-up exactly once. That is the shape the vendor code was written for.

At **`Lco_fpudis_nofpu`** the stacked PC has already been rewritten, and the emulator would then
rewrite it again *from the same field to the same value* — idempotent, therefore harmless, but
only by luck. It also means the package has already run and left its own `link`/`unlk` traces on
the way, for no benefit to a path that never wanted the package.

So decision (10) is not merely the arm that executes; **it is the arm the emulator code assumes.**

**The standing risk this exposes, and it is the sharpest one in the lane.** Both `#if 0` blocks
around that fix-up (`fpu_emulate.c:121-123` and `:226-232`) show NetBSD abandoned the idea of
restoring the "next PC": the format-4 path **discards it and relies entirely on
`insn.is_advance`**, i.e. on the emulator having decoded the instruction's length correctly. The
vendor's own comment calls that reliance a hack, on the grounds that it presumes the emulator
knows the length of every instruction it will meet. On an LC060 this is not a corner — **it is
the only path**, because every event is
format 4. A wrong `is_advance` resumes the process mid-instruction. Round 3's bench ladder must
test instruction-length correctness directly and not only result correctness.

---

## 7. Compile-feasibility probe

Evidence only. **No emulator file was modified and no compat header is committed.** The probe
tree was built under the gitignored `build/fpe-probe/` and is deliberately not part of this
commit — round 1 produces findings, not a compat layer. The method below is the whole recipe, so
it can be rebuilt from this section alone.

Method: `AMIX_KERNEL_CFLAGS` sourced the way `relink-040-z3660.sh:33-42` does — `tools/config-load.sh`,
then `AMIX_SYSROOT=build/sysroot-modelb` (the Model-B mirror), then the `-m68020` → `-m68040` swap
of `:61`. Note the flags include **`-traditional`**, so this is K&R-mode gcc 2.7.2.3.

The compat layer supplies only headers the AMIX sysroot does **not** have — which is forced, not
chosen: the cross-gcc wrapper prepends `-I$sysroot/usr/include` ahead of every command-line `-I`
(`src/mk_modelb_sysroot.sh:5-9`), so a shim can never shadow an AMIX header. Every MI header
(`sys/types.h`, `sys/param.h`, `sys/systm.h`, `sys/signal.h`, `sys/siginfo.h`, `sys/time.h`,
`float.h`, `stdio.h`, `stdlib.h`, `string.h`) is therefore **AMIX's own**. The shim carries
NetBSD's five m68k machine-ABI headers verbatim from the pinned tarball, plus stubs for
`sys/cdefs.h`, `sys/signalvar.h`, `sys/featuretest.h`, `machine/endian.h`, `machine/trap.h` and
an empty `opt_m68k_arch.h`.

### 7.1 Result

**Pass 1 (no compat layer): 0/20.** All twenty stop on the first `#include`; nineteen on
`sys/cdefs.h`, `fpu_calcea.c` on `opt_m68k_arch.h`. Uninformative, recorded for completeness.

**Pass 2 (compat layer): 19/20 compile; 20/20 with one further toolchain fix and one header
collision removed.**

| File | Result | Error class if not clean |
|---|---|---|
| `fpu_add.c` | PASS | — |
| `fpu_calcea.c` | **FAIL** | **C: `cputype` redeclared** (§7.2 class C) |
| `fpu_cordic.c` | PASS | — |
| `fpu_div.c` | PASS | — |
| `fpu_emulate.c` | PASS | — |
| `fpu_exp.c` | PASS | — |
| `fpu_explode.c` | PASS | — |
| `fpu_fmovecr.c` | PASS | — |
| `fpu_fscale.c` | PASS | — |
| `fpu_fstore.c` | PASS | — |
| `fpu_getexp.c` | PASS | — |
| `fpu_hyperb.c` | PASS | — |
| `fpu_implode.c` | PASS | — |
| `fpu_int.c` | PASS | — |
| `fpu_log.c` | PASS | — |
| `fpu_mul.c` | PASS | — |
| `fpu_rem.c` | PASS | — |
| `fpu_sqrt.c` | PASS | — |
| `fpu_subr.c` | PASS *(after class B fix)* | **B: assembler rejects `bfffo`** |
| `fpu_trig.c` | PASS *(after class A fix)* | **A: `struct fpframe` incomplete** |

### 7.2 The error classes

**Class T — types (11 files, resolved by the shim, but a real port cost).** AMIX SVR4
`<sys/types.h>` has **neither** the C99 `uint32_t`/`uint64_t` **nor** the BSD short names
`u_char`/`u_short`/`u_int`/`u_long`. It spells them `uchar_t`/`ushort_t`/`uint_t`/`ulong_t`
(`sys/types.h:19-22`). `uint32_t` alone is used throughout the package (`fpu_emulate.h:84` is
where every file stops). This is a compat header, not a source change, and it is unavoidable.
One incidental finding while writing it: **`-traditional` rejects `signed char`**, so the compat
header cannot use it.

**Class A — `fpu_trig.c` reaches `struct fpframe` only through NetBSD's signal-header chain.**
Six files dereference `fe_fpframe->`; five of them include `<machine/frame.h>` (which reaches
`m68k/cpuframe.h`). `fpu_trig.c` includes only `<sys/cdefs.h>` and `"fpu_emulate.h"`, and gets
the type via `fpu_emulate.h:40` → NetBSD `<sys/signalvar.h>` → `<sys/siginfo.h>` →
`<machine/signal.h>` (= `m68k/signal.h`), whose `:81` includes `m68k/cpuframe.h`, where
`struct fpframe` is defined at `:149`. On AMIX that chain does not exist, because AMIX's own
`<sys/siginfo.h>` is used instead. **Fix is one `#include` in the port's compat header, not an
edit to `fpu_trig.c`** — confirmed by adding it and watching the file compile.

**Class B — the assembler, not the compiler: `bfffo`.** `fpu_subr.c` compiles cleanly; GNU as
2.8.1 then rejects gcc 2.7.2.3's SGS spelling of the bit-field operand:

```text
fpu_subr.c -> bfffo %d3{#0:#32},%d2
GNU as     -> Error: Missing operand
              Error: operands mismatch -- statement `bfffo %d3{' ignored
```

The `#` prefixes on the bit-field offset and width are SGS-isms; GNU as wants `{0:32}`. This is
the **same class** as the `.swbeg`, `tdivs`/`tdivu` and `fsgldiv.s` defects the cross-gcc wrapper
already repairs in its `fix_asm` pass — and the wrapper has **no bit-field rewrite** (checked;
its only `{#` matches are bash array-length idioms).

Verified end to end: a scratch copy of the wrapper with one line added,

```perl
perl -pi -e 's/\{#(\d+):#(\d+)\}/{$1:$2}/g' "$1"
```

placed in the same `fix_asm` chain, makes `fpu_subr.c` compile and assemble. The emitted
instruction disassembles as `bfffo`. **This fix belongs in `gcc-cross-amix`, not here** — it is a
toolchain defect that affects any C using that codegen pattern, not something specific to the FPE.

**Class C — `cputype` collides (the only hard failure).** Covered in §3.7. NetBSD
`m68k/m68k.h:60` `extern int cputype` vs AMIX `sys/systm.h:18` `extern short cputype`; gcc reports
`conflicting types for 'cputype'`. Removing just those two externs (`cputype`, `fputype`) from the
scratch copy of `m68k/m68k.h` takes the package to **20/20**. The *semantic* half of the collision
— `CPU_68060 == 3` vs AMIX's `60` — survives the compile fix and is the thing that must actually
be resolved.

Two further diagnostics were shim artefacts and are recorded so nobody re-finds them: NetBSD's
`m68k/m68k.h:127` uses `vaddr_t` (a NetBSD MI type) in an unrelated prototype, and
`machine/frame.h`'s `#if defined(_KERNEL)` block pulls in NetBSD's `sigframe_siginfo` machinery
(NetBSD `siginfo_t`, `ucontext_t`) that this port will never use — `sendsig` is AMIX's.

### 7.3 Object inventory, and what it implies for the relink

Measured on the 20 objects from the 20/20 run:

```text
    .text  26,986      .data  3,060      .bss  396      total 30,442 bytes
```

Two build facts follow, both already law in this tree:

* **Seven of the twenty objects have a `.text` size that is not a multiple of 4** — `fpu_exp`
  1558, `fpu_int` 234, `fpu_log` 4902, `fpu_mul` 938, `fpu_rem` 770, `fpu_subr` 402, `fpu_trig`
  3070, every one of them `≡ 2 (mod 4)`. `BUILDING.md:229-249` and `relink-040-z3660.sh:100-106`
  both record why this matters: the loader copies text+data as one block and places `.bss` at
  `data_end` unaligned, so a compiled object — which cannot end its own section with `.balign 4`
  — must be followed in the link by a hand-written glue object that does. The FPE link must put
  its glue **last**, exactly as `relink-040-z3660.sh:107-109` does.
* **396 bytes of `.bss`** (`fpu_emulate` 148, `fpu_log` 188, `fpu_rem` 60). The 148 is the static
  `insn`/`fe` of §2 — so the non-reentrancy is not an abstract worry, it is a measurable object
  section. Cross-reference `FPSP-INTEGRATION-PLAN.md:370-380`: a `copyin` inside
  `fpu_load_ea` may sleep, `swtch` may then run another process, and a second vector-11 entry
  will **overwrite the first process's emulator state**. On the FPSP that hazard was about the
  hardware's temporary state; here it is about 148 bytes of shared `.bss` with no owner. Round 2
  must decide this before any bench run: private the state per process, serialise entry, or prove
  the sleeping path unreachable.

---

## 8. Open items

1. **`tools/fpelf-census.py` against a complete installed root — still open.**
   `docs/060-F1-FPELF-CENSUS-260824.md:59-66` asks for it. Re-run here against
   `gcc-cross-amix/build/sysroot-preserved/amixroot`: **262 m68k ELF objects (123 `ET_REL`,
   130 `ET_EXEC`, 9 `ET_DYN`), all `e_flags == 0`, 0 FP-required.** The count is identical to the
   earlier census, which **identifies that census's tree as this sysroot** — so this is a
   reproduction, not a widening. No complete installed root exists on disk outside the `.hdf`
   images, and extracting one needs image tooling that is out of scope for this round. The
   caveat's specific gap — `/bin`, `/sbin`, `sh`, `awk`, `ls`, `init`, `pkgadd` — remains
   unmeasured.
2. **The 68040 format-2 frame was cited, not measured — CLOSED in round 5.** §6.2's
   format-2/`0x202c` row rested on Motorola's `x_fline.sa` and on `FPSP-INTEGRATION-PLAN.md:233`
   through rounds 1–4, and no 68040 vector-11 frame had ever been latched in this tree. Round 4
   moved the format census **ahead of** the `fpu_present` decline (which is why it had been
   unreachable: every 040 available has an FPU, so the lane never armed on one), and round 5
   latched **`fpe_v11_fmt2_word = 0x202c` off 2,057 genuine 68040 frames** with `fpe_entry_n`
   still 0 and the FPSP's results still correct to 15 digits
   (`Amix/tmp/2026-08-27-fpe-r5/RESULTS.md` item 6). The same measurement corrected the row's
   `+8` field to the **operand effective address** — §6.2.
3. **`ufetch_short`'s failure semantics on a sleeping fault** are inherited from the `copyin`
   shape (§3.5) and share the ownership hazard of §7.3.
4. **`panic` interposition** (§3.6) has no decided mechanism.
5. **`si_code` policy** (§3.3, §5.3): finer than stock, therefore a deliberate divergence.
6. **`_exop[3]`** (§3.3) is available and unpopulated.
7. **`fpu_present` consumers.** Full relocation census of `build/unix-040`: **24 references in 20
   functions.** Stock: `chk_fpu`, `contnu`, `grabtrap`, `fpuinit_orig`, `setuctxt`, `procxmt`,
   `setregs_orig`, `prhasfp`, `coffcore`, `elfexec`, `getelfhead`, `elfcore` (×3), `swtch` (×2) —
   13 functions, 17 references. This port's own: `fpu_save`, `fpu_restore`, `fpu_setup`,
   `fpuinit`, `Lfi_yes`, `fpu_setup_gated`, `Lco_fpu_disabled` — 7 references. `prhasfp` itself is
   referenced 4 times. **This is a wider set than the eleven call sites
   `docs/060-F1-M2-GATE-CENSUS-260824.md:76-88` enumerates** (that table counts sites reaching
   `fpu_save`/`fpu_restore`/`fpu_setup`, which is a different question) and it names three
   consumers the FP-state discussion has not covered: `getelfhead` (the FP-required exec gate),
   `elfexec` and `elfcore`. Frozen decision (9) keeps `fpu_present` meaning "real silicon", so all
   17 stock references keep their current behaviour by construction — **including
   `getelfhead`, which will therefore keep refusing FP-required binaries even under full working
   emulation.** That is a defensible default and it is also a policy the glue round should adopt
   on purpose rather than inherit by omission.

---

## 9. Summary of corrections this round produced

| Claim as received | Measured |
|---|---|
| `u_trap` SIGSYS arm shared by vector 11, A-line and traps 34-47 | Correct except **42**, which shares the vector-32 `systrap` arm |
| Vectors 48-55 already carry correct SVR4 `FPE_FLT*` si_codes | True but coarse: **48/52/54/55 share one arm and one code, `FPE_FLTINV`** |
| The 784-byte never-written `mc_state` field becomes genuinely written | **216 of the 784** (`mc_state[23..76]`); 568 bytes remain uninitialised |
| Attach at the top of `fpsp_vec11`; the stock path would be dead | Confirmed, and by metal: **5,406 vs 0** on the real LC060 (`ATT5:252`) |
| `Lv11_stock` sees the raw four-word F-line frame | Only for a genuine line-F. **Three shapes reach vector 11**; on an LC060 it is always the eight-word format-4 frame |
| Ken Nakata 3-clause (licence families) | Also a **2-clause** Nakata variant on `fpu_fstore.c` and `fpu_int.c` |
| Full SIGFPE wiring with SVR4 si_codes | The emulator emits **si_code 0** for arithmetic signals; the glue must derive them from `fpf_fpsr & fpf_fpcr` |
