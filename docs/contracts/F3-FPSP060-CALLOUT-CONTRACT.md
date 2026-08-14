# M68060 FPSP Call-out Contract

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/F3-FPSP060-CALLOUT-CONTRACT.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

## Scope

This note answers the five static questions in
`kernelsupport/F3-CALLOUT-CONTRACT-CODEX-TASK.md`. It covers Motorola's full
and partial M68060 FPSP images, the Motorola example call-outs, NetBSD's real
OS adaptation, and the AMIX trap/return ABI. It does not change kernel code
and does not claim runtime acceptance.

The most important correction is immediate:

> A terminal `_060_real_*` call-out is entered with the package locals gone
> and a valid raw exception frame at `(sp)`. The package's table stub is a
> tail-transfer shim, not a normal outstanding subroutine call. Therefore a
> state-preserving jump to AMIX `nullvect` is structurally valid for the
> exception exits whose package frame already names the desired vector.

The M2a panic has a different static explanation. The deliberately failing
`_060_imem_read_long` stub returns `d0=0,d1=1`, but the full package does not
test `d1` after its first mandatory instruction fetch. It decodes the zero
opword and jumps into `tbl_trans` as code. The measured PC is exactly inside
that table.

## Executive decisions

| Question | Verdict |
|---|---|
| Q1, terminal state | Every `_060_real_*` is a terminal tail transfer. The package has restored D0-D1/A0-A1 and any FP temporaries it used, removed its A6 locals, and left a CPU-consumable exception frame at `(sp)`. There is no package return address and the OS call-out must not use `rts`. |
| Q1, permitted exits | `rte` is architecturally possible only when the call-out has completed the class-specific policy. Normal completion may `rte`; enabled FP exits need pending-state handling; illegal F-line, trace, trap, and access exits must not simply ignore the event. A tail jump into the OS vector handler is the normal integration shape. |
| Q2, access | The package itself synthesizes a 16-byte format-4 vector-2 access-error frame. NetBSD jumps directly to `buserr60`; it does not build another frame. AMIX should preserve registers and tail-jump to `nullvect`, which then reaches the existing 060 memory-fault and signal path. |
| Q3, SVR4 routing | Use the package-provided raw frame and enter `nullvect`; do not call `u_trap` directly and do not return to the package. `_060_fpsp_done` is the exception: the instruction is complete, so use the same AMIX `ureturn` reconstruction as the accepted 040 glue without calling `u_trap`. |
| Q4, entry setup | The package constructs A6 itself with `link.w %a6,#-192`; `a6@(4)` is the original stacked SR. The caller owes no A6 frame. The 060 vector wrapper does owe the same `sup_cacr` installation as the 040 wrapper, followed by an AMIX user-return path that restores the user CACR. |
| Q5, package choice | Use full `fpsp.sa`. `pfpsp.sa` explicitly omits FP-unimplemented-instruction emulation: its F-line entry routes such instructions to `_060_real_fline`, and its `smovcr` is a self-branch placeholder. It does not provide `fmovecr` or the transcendentals required by `fp060probe`. |

## Pinned provenance

Kernel repository:

```text
HEAD 8d053a975f901e496f7366f1ed0996ffa57b34aa
task SHA256 aed01e6d6e3d1f2544cbbf35fa8e1db67b7176f568fdf079d98bac69449ac5d7
build/unix-040 SHA256 8f0f743d2d7cb5479fc2444004bee9a13d0567bcfdf797c084041e0f88b1c568
build/fpsp060_pkg.o SHA256 1b0429d20ae39e28893a1d7a64bf2bb5c7c79f0372906348316677184598ec9a
```

Motorola/NetBSD source inputs extracted by `build-fpsp060.sh` from
`netbsd/syssrc.tgz`:

| File | SHA256 | Role |
|---|---|---|
| `060sp/dist/fskeletn.s` | `62b2eec95e57b2acee1e8f3daba90573d941d51fdf7b45ab48305243df4c7c7a` | Motorola example terminal call-outs |
| `060sp/fnetbsd.S` | `13f6536720bf7016fd30c0bf8f39fb501874ec76a87fdb7d938351560848e4ad` | NetBSD FP exception exits |
| `060sp/netbsd060sp.S` | `b3a9376ff38d28a3942b5878310f2e1cf17baf26e221d0f0e0550923a9af2881` | NetBSD memory, trace, and access call-outs |
| `060sp/dist/fpsp.s` | `78df357f3362072a288eb04bd463858c8e75b9ca162ddac7171cf1fd25e581a5` | Full package source |
| `060sp/dist/pfpsp.s` | `b6ff86b0c341d34d97585c43f847920ea3abb486dc03c43c781a3cea5a26861b` | Partial package source |
| `060sp/dist/fpsp.sa` | `4b43e1f0f9a370148425d716b4021570f0d97017febf89019856753b251e8072` | Full release image |
| `060sp/dist/pfpsp.sa` | `47a4158ea8e36094f89c300134e8c55ce328471e2e34446e7da62ccb08169261` | Partial release image |

The line references below are to the extracted readable `.s`/`.S` sources.
The package-object offsets are independently decoded from the pinned
`build/fpsp060_pkg.o`.

## The call-out transfer mechanism

The package does not link directly to an OS symbol. Each internal stub loads
the relative target from the 128-byte table and executes this sequence
(`fpsp.s:104-207`):

```text
save d0
load table-relative OS target into d0
pea target
restore d0 from sp+4
rtd #4
```

`rtd #4` pops the address made by `pea`, transfers to it, and drops the saved
D0. This has two distinct effects depending on how the package reached the
stub:

1. Memory helpers use `bsr _imem_read...` or `bsr _dmem...`. Their package
   return address remains at `(sp)` when the OS accessor starts, so the OS
   accessor returns with `rts`.
2. Terminal exits use `bra _real_*` or `bra _fpsp_done`. No package return
   address exists. The OS exit starts with exactly the exception frame that
   the package left at `(sp)` and must terminate with `rte` or a tail jump to
   an OS exception handler.

The shim preserves D0 itself. This is why an OS exit may not infer that D0 is
scratch. The current M2a `Lco_stock` overwrites restored user D0 with a slot
number before entering `nullvect`; that instrumentation violates the exit
contract. A counted exit must restore every register and the exact entry SP
before the final jump. Memory-only increments may change live CCR because
the user SR is in the raw frame, but scratch registers still need explicit
save/restore.

## Q1: per-call-out terminal state

Motorola's skeleton and package source use `word` to mean 16 bits. Thus a
four-word frame is 8 bytes, a six-word frame 12 bytes, and an eight-word frame
16 bytes.

| Call-out | Frame at `(sp)` | Package state on entry | Correct terminal choices |
|---|---|---|---|
| `_060_fpsp_done` | Returnable frame for the original exception, with the completed instruction's resume PC | Integer/FP temporaries restored, A6 locals removed | Bare `rte` is allowed by Motorola. On AMIX user origin, reconstruct the normal saved-register shape and enter `ureturn`; supervisor origin may `rte`. |
| `_060_real_ovfl` | Valid overflow exception frame, unchanged as a system frame | Exceptional operand remains represented in the FP state; package registers/locals restored | Normalize the pending FP state, then tail to the OS FP handler; skeleton instead clears status and `rte`s. Do not enter the generic handler before the pending-state operation. |
| `_060_real_unfl` | Valid underflow exception frame | Same contract as overflow | Same choices as overflow. |
| `_060_real_operr` | Valid operand-error exception frame | FP state holds the source operand | Same choices as overflow. |
| `_060_real_snan` | Valid signaling-NaN exception frame | FP state holds the source operand | Same choices as overflow. |
| `_060_real_dz` | Valid divide-by-zero exception frame | FP state holds the source operand | Same choices as overflow. |
| `_060_real_inex` | Valid inexact exception frame | FP state holds the exceptional/source state prepared by the package | Same choices as overflow. |
| `_060_real_bsun` | Valid vector-48 BSUN frame. The emulated-instruction path explicitly constructs format 0 / vector offset `0x0c0`. | Registers and package locals restored; BSUN state has been restored into the FPU | Clear/consume the pending BSUN state and route to the OS FP handler, or apply Motorola's explicit clear-and-restart policy. An unchanged `rte` is not sufficient. |
| `_060_real_fline` | Valid F-line frame. The ordinary illegal-F-line case is the original four-word frame. | Package locals removed and original registers restored | Tail to vector-11 policy. `rte` without changing state would execute the illegal instruction again. |
| `_060_real_fpu_disabled` | Eight-word format-4 vector-11 frame (`fmt/vector=0x402c`) with current PC, next PC, and EA fields | No package return address; frame is ready for OS policy | Motorola's sample clears PCR disable, copies current PC from `sp+0xc` to stacked PC at `sp+2`, then `rte`s. Otherwise tail to explicit disabled-FPU policy. Do not plain-`rte` the unchanged frame. |
| `_060_real_trap` | Six-word format-2 vector-7 frame (`0x201c`), synthesized from the unimplemented-FP frame | Current and next PCs are already in the frame; registers restored | Tail to vector-7 trap policy. Motorola/NetBSD's sample `rte` deliberately ignores the event and is not a Unix signal implementation. |
| `_060_real_trace` | Six-word format-2 vector-9 frame (`0x2024`), synthesized with current and next PCs | Registers/locals restored | Tail to the trace vector handler. NetBSD jumps directly to `trace`. Plain `rte` would discard the trace event. |
| `_060_real_access` | Eight-word format-4 vector-2 access frame (`0x4008`) | Registers/FP state restored; no A6 locals | Tail to the 68060 bus/MMU fault entry. It must not return to the incomplete emulation with `rte` or `rts`. |

For overflow, underflow, operand error, signaling NaN, divide-by-zero, and
inexact, Motorola's example performs:

```text
fsave -(sp)
write 0x6000 to saved-state word at sp+2
frestore (sp)+
rte
```

NetBSD performs the same three FP-state operations and then jumps to
`fpfault` instead of doing `rte` (`fnetbsd.S:91-194`). BSUN has its own
sequence: save state, clear the FPSR NaN condition, discard the 12-byte saved
state, then enter `fpfault` (`fnetbsd.S:210-218`). These are not incidental
sample instructions; they are the exception-specific prelude that prevents
the OS signal path from inheriting an unhandled pending FP condition.

The terminal call-outs are therefore not twelve interchangeable aliases.
They share the raw-frame ABI, but the seven FP-status exits need their own
prelude and the other exits name different OS events.

## Q2: `_060_real_access`

### What the package builds

Every checked instruction/data accessor failure is converted by the package
to this raw format-4 frame:

| Offset | Size | Field |
|---:|---:|---|
| `+0` | 2 | original SR |
| `+2` | 4 | current/faulting PC selected by the package |
| `+6` | 2 | format 4 plus vector offset 8: `0x4008` |
| `+8` | 4 | failed instruction/data effective address |
| `+12` | 4 | synthesized 68060 FSLW, including size, direction, and transfer mode |

The builders are visible in three families:

- unimplemented-effective-address instruction/data failures at
  `fpsp.s:3024-3071`;
- failed `fdbcc` displacement fetch at `fpsp.s:4983-5006`;
- general FP operand read/write failures at `fpsp.s:24591-24718`.

The builders also undo predecrement/postincrement address-register side
effects before exposing the access error (`fpsp.s:24722+`). They restore
D0-D1/A0-A1, FP0-FP1, FP control state as appropriate, unlink A6, and only
then branch to `_real_access`.

### NetBSD's contract proof

NetBSD's call-out is only:

```text
_060_real_access:
        jra buserr60
```

Its comment says the stack is an eight-word access-error frame
(`netbsd060sp.S:357-369`). `buserr60` immediately saves the register set and
reads FSLW at `FR_HW+12` and the fault address at `FR_HW+8`. That is an
independent consumer proof of the exact layout above.

### AMIX verdict

AMIX must not synthesize a second frame. Preserve all registers and the exact
SP, then tail-jump to `nullvect`. Its format/vector dispatch sees vector 2;
the existing 060 `u_trap -> usrxmemflt` path consumes the FSLW and EA and
chooses the user fault/signal result. This retains the current out-parameter
and `k_siginfo_t` policy instead of duplicating it in FPSP glue.

Supervisor-origin access failures take the same raw vector entry and let
AMIX's S-bit dispatch choose `k_trap`. They must not be mislabeled as a user
SIGSEGV in the call-out.

## The M2a panic is before `_060_real_access`

The current fail-closed design assumes every nonzero memory result is consumed
by a branch to `_060_real_access`. The full package disproves that assumption
for the first fetch in `_fpsp_unimp`.

Pinned object sequence:

```text
0x1c0c  _060_fpsp_fline target (image + 0x1b8c)
0x1cbe  full-package unimplemented-instruction body begins
0x1cfe  bsr _imem_read_long
0x1d04  store d0 as the opword, with no intervening test of d1
...
0x1d5e  fetch a 16-bit target offset from tbl_trans
0x1d64  jsr through that offset
0x2012  tbl_trans (image + 0x1f92), data rather than code
```

The M2a accessor at `Lco_* = 0xd5cc` returns `d0=0,d1=1`. With a zero decoded
operation/tag index, the first `tbl_trans` entry is itself a zero displacement,
so the indirect JSR enters the table at `0x2012`. Execution proceeds through
table words until the CHK encoding is reached. The measured panic PC is:

```text
fpsp060_image + 0x1fb6
  = tbl_trans + 0x24
```

This is a byte-exact match to the observed data execution. It explains why
the panic is inside a constant table and why changing the terminal
`Lco_access` route alone cannot fix M2a.

The full source does check `d1` at later fetches, for example the `fdbcc`
displacement read at `fpsp.s:4324-4329`, and those failures do build an access
frame. The initial four-byte decode fetch is instead an implicit package
precondition: for the CPU to have raised the FP-unimplemented exception, the
faulting instruction must be readable. A real AMIX `_060_imem_read_long`
must therefore perform the access rather than use the universal decline stub.

This does not mean access failures can be ignored. It means M2a's single
fail-all stub is not a supported way to exercise the package's access exit.
A later access-error test must use a package site that actually tests `d1`,
such as an extension-word or operand access.

## Q3: AMIX trap and signal routing

### Exception exits

The recommended shape is:

```text
Motorola package
  -> class-specific _060_real_* call-out
  -> optional FP pending-state prelude
  -> preserve all user registers and exact raw-frame SP
  -> nullvect
  -> user origin: utraps -> u_trap -> existing signal policy -> ureturn
  -> supervisor origin: ktraps -> k_trap -> existing kernel-fault policy
```

This is option (a) from the task only in the sense of re-entering through a
raw frame. The package has already retained or rebuilt that frame, so the OS
glue must not rebuild it again.

Calling `u_trap` directly is the wrong layer. It would bypass the assembly
prologue that:

- saves D0-D7/A0-A6;
- installs `sup_cacr`;
- records/restores USP;
- establishes the register frame consumed through `u.u_ar0`;
- reaches `ureturn` with the shape expected by stack-frame adjustment and
  signal delivery.

Returning into the package is impossible for `_060_real_*`: the table stub
tail-transferred and left no return address. Only memory call-outs are normal
subroutines.

### Normal completion

`_060_fpsp_done` is not an exception to be signaled. The package has completed
the instruction and prepared the resume PC. Entering `nullvect` would call
`u_trap` for an exception that no longer exists. A bare user `rte` would skip
STREAMS queue work, scheduler-class trap return, pending signals/rescheduling,
stack-frame cleanup, and CACR restoration.

Use the already established 040 shape:

```text
if user-origin frame:
        save D0-D7/A0-A6 in nullvect-compatible order
        establish the USP/u_ar0 pseudo-register state
        jump ureturn
else:
        rte
```

The 060 glue should have its own symbol/counters but the same AMIX exit ABI.

## Q4: A6 and CACR entry obligations

### A6 is package-owned

The full package defines `LOCAL_SIZE=192`, `EXC_SR=4`, and begins the
unimplemented-instruction handler with:

```text
link.w  a6,#-192
save d0-d1/a0-a1 and FP state in the local frame
test bit 5 at EXC_SR(a6)
```

`link` pushes the incoming A6 and makes the raw CPU SR appear at `a6+4`.
Thus the memory-call-out convention `a6@(4),bit5` is built by the package;
the vector wrapper must enter with the raw frame at `(sp)` and must not
manufacture an A6 frame.

NetBSD also records that the package's internal buffer addresses are
guaranteed to be on the stack, specifically so a user-memory page fault in a
copy call-out may sleep. This supports normal AMIX `copyin`/`copyout` rather
than direct unguarded user dereferences.

### CACR is OS-owned

The current 040 vector wrapper installs `sup_cacr` before entering its FPSP.
The current 060 branch jumps to `fpsp060_vec11` without doing so. Because it
bypasses `nullvect`, it also bypasses the common trap entry's CACR write.

The 060 path must install `sup_cacr` before its first package counter or
package memory access, while restoring D0 and SP exactly before the package
jump. This is paired with the previous `_060_fpsp_done -> ureturn` rule:
once the entry installs the supervisor CACR, a user-origin bare `rte` would
leave the supervisor cache policy live in user mode.

No additional A6, PCR, or FP-register setup is owed by the vector wrapper.
The package saves/restores the FP registers it uses. `_060_real_fpu_disabled`
is a terminal policy event, not an entry precondition hidden in the wrapper.

## Q5: full versus partial FPSP

Motorola's `readme` identifies `fpsp` as the full FP kernel module and
`pfpsp` as the partial module. The source says what partial means more
precisely.

`pfpsp.s:3817-3854` describes its `_fpsp_fline` as the reduced handler "that
does not emulate FP unimplemented instructions." It checks only for the
format-4 FPU-disabled frame; every other F-line case branches to
`_real_fline`. It contains no `_fpsp_unimp` front-end.

The full-only global surface includes these major groups:

- `_fpsp_unimp`, `_load_fop`, `_ftrapcc`, `_fdbcc`, and `_fscc`;
- the `tbl_trans` instruction/tag dispatch;
- the real `smovcr` implementation and ROM-constant loaders;
- `fsin`, `fcos`, `ftan`, `fsincos`, hyperbolic functions;
- exponential and logarithmic families;
- inverse trigonometric families;
- `fgetexp`, `fgetman`, `fmod`, `frem`, and `fscale` helpers.

Partial still contains the IEEE exception-correction, unsupported-data-type,
unimplemented-effective-address, packed-data, and basic arithmetic support
needed around operations implemented by the 68060 hardware. Its
`tbl_unsupp` deliberately maps the omitted unimplemented operations back to
the table, and its `smovcr` symbol is only:

```text
smovcr:
        bra.b smovcr
```

That placeholder exists so retained exception modules assemble; it is not
an `fmovecr` emulator.

Expected `fp060probe` result after correct glue:

| Instruction | Full `fpsp.sa` | Partial `pfpsp.sa` |
|---|---|---|
| `fsin` | emulated, reaches done unless it raises an enabled exception | `_060_real_fline` / existing unsupported signal |
| `fetox` | emulated | `_060_real_fline` / existing unsupported signal |
| `flogn` | emulated | `_060_real_fline` / existing unsupported signal |
| `fmovecr` | emulated by the full unimplemented-instruction path | `_060_real_fline`; partial's dummy `smovcr` is not a usable fallback |

The full image is therefore not merely the larger version to benchmark. It
is the only one of the pair that meets F3's functional target.

## Implementation review checklist

This is a specification checklist, not kernel code.

### Entry

- Keep the raw vector-11 frame byte-identical when entering the package.
- Install `sup_cacr` on the 060 branch before counters/package execution.
- Restore all temporary integer registers and SP before jumping to
  `TOP+128+0x30`.
- Do not build A6 in the wrapper.

### Memory call-outs

- Implement the real `imem`/`dmem` ABI before enabling the package.
- Return `d1=0` only after the requested bytes were transferred.
- Return nonzero only at a package call site that has a defined failure
  branch; do not use the current fail-all M2a stub as a package decline mode.
- Preserve the package's A6 and all registers outside the documented outputs.
- Allow normal fault/sleep behavior through existing guarded AMIX copy
  primitives.

### Terminal exits

- Do not use `rts`.
- Preserve D0-D7/A0-A6 and exact SP before `nullvect`; remove the current
  `moveq slot,d0` clobber or restore D0 after recording.
- Give the six arithmetic status exits and BSUN their Motorola/NetBSD
  pending-state preludes before signal dispatch.
- Route F-line, trap, trace, and access through their package-provided raw
  frames.
- Keep FPU-disabled behavior explicit. With eager Tier-1 enablement it is an
  invariant/fallback path, not an excuse to mutate PCR silently.
- Treat reserved slots as an invariant failure; do not assume they carry a
  documented signal frame.

### Completion

- Send user-origin `_060_fpsp_done` through AMIX `ureturn` without calling
  `u_trap`.
- Permit supervisor-origin completion to `rte`, with a counter if desired.
- Verify the user CACR is restored after every successful emulation.

## Static and runtime acceptance split

Static closure now established:

- table stub tail-transfer semantics;
- raw-frame ownership for every terminal family;
- access-frame producer/consumer layout;
- package-owned A6 frame;
- full/partial semantic difference;
- exact pre-`_real_access` explanation for the M2a CHK panic.

Runtime acceptance still required after implementation:

1. `fp060probe` executes all four instructions with four package entries,
   nonzero successful memory calls, four normal completions, and no terminal
   access/F-line exit.
2. No PC enters `tbl_trans` or another package data region.
3. A checked extension-word or data-operand fault reaches vector 2 and kills
   only the child, with unchanged non-output registers.
4. A genuine illegal F-line reaches vector 11 through `nullvect` rather than
   returning or looping.
5. Enabled FP exceptions reach their expected arithmetic vectors without a
   pending-exception retrap loop.
6. Trace and `ftrapcc` tests produce their normal AMIX vector behavior.
7. Fork, exec, signal delivery, and context switching preserve FP state.
8. 040 package counters remain unchanged on 060 and 060 counters remain zero
   on 040.

## Confidence and residual risk

The stack-transfer, access-frame, A6, partial-package, and panic-location
verdicts are **high confidence** because each is supported by both readable
source and the pinned object disassembly. The exact AMIX user signal selected
for each arithmetic vector remains the existing `u_trap` policy and is not
reimplemented here. The pending-state preludes should be copied semantically
from Motorola/NetBSD and then tested with enabled FPCR exception masks; the
current 040 glue itself still records that part as incomplete.
