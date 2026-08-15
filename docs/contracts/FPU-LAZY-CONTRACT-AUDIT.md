# AMIX FPU software-write and 68060 frame contract

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/FPU-LAZY-CONTRACT-AUDIT.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

- Status: static audit and implementation recommendation; no kernel change
- Date: 2026-08-11
- Task pin: amix-040-060-port commit `552a0c8de03f04ea045e93b3b133711da8951b65`
- Task SHA-256: `a7ccee26e71acbbf7eeea70be809173d31450ad5351251658ed0d3b915c3ea93`
- Kernel: `amix-040-060-port/build/unix-040`
- Kernel SHA-256: `f963b1a317a0a469dc4fe5f19ced8463f71c61fa087f15de754c4782ebc63850`

## Verdict

`u + 0x9c` is `u.u_fpu.ustate`. Bit zero is `UFPRWRT`. It is not a
lazy-FPU owner bit and does not mean that a hardware save is pending. It says
that software has changed the programmer-model copy in the u-vector and that
this copy must be applied to the FPU before normal context-switch processing.

The current image has one originating setter: the old `ptrace` write path in
`procxmt` at `0x47fac`. Setting the bit prevents `fpu_save` from overwriting
the software-supplied values. `fpu_restore` consumes those values and clears
the bit. The inherited design otherwise saves and restores FPU state eagerly;
there is no lazy hardware-owner protocol and no intentional FPU-disable cycle.

The divide-by-zero diagnosis in the task has one decisive error. On a 68060,
the frame discriminator is at byte `frame + 2`, not at byte zero. The measured
words `0x7fff`, `0x4000`, and `0x0000` are the source operand's exponent word.
They are not null/non-null tags. Motorola writes the exception or idle status
at `2 + FP_SRC`, and NetBSD tests byte two for exactly this reason.

Consequently:

- DZ did not prove that FPSP left a null frame with live registers;
- the `7100` "null saves" counted with the inherited byte-zero test are not a
  true-null count and cannot support the stated 108-byte cost estimate;
- the glue's `tstw (%sp)` guard misclassifies a zero source operand;
- stock `fpu_save` and `fpu_restore` also use the wrong discriminator on every
  68060 state, not just DZ.

The minimal contract-correct unit is therefore a CPU-gated 68060 state path:

1. restore Motorola's three-instruction arithmetic call-out prelude for all
   six IEEE exits, including DZ;
2. make 68060 `fpu_save` and `fpu_restore` test byte `frame + 2` while retaining
   the inherited `UFPRWRT` semantics and ordering;
3. use a complete 12-byte 68060 reset frame in the 68060 `fpu_setup` path;
4. leave the accepted 68040 code byte-identical.

No new state bit and no special DZ-only signal convention are warranted.

## Provenance

### AMIX declarations

The mounted AMIX header is the primary source for the flag's meaning:

- `vanilla/usr/include/sys/fpu.h:40-47` defines `fpu_t`, the programmer model;
- `fpu.h:49-56` defines `UFPRWRT` and documents that it requests updating the
  programmer model from the u-vector before normal context switching;
- `fpu.h:58-69` defines `fpu_info` as `ustate`, `regs`, then `fsave`;
- `vanilla/usr/include/sys/user.h:83-90` embeds it as `u_fpu`.

In those declarations, `UFPRWRT` is bit value `1`. The embedded `fpu_info`
record consists, in order, of a long state word, the programmer-visible FPU
register model, and an `FSAVEMAX`-sized saved-frame array. `user_t` places this
record after its PCB. These ordering facts, rather than the header's spelling,
are the contract consumed below.

Header SHA-256 values:

| File | SHA-256 |
|---|---|
| `vanilla/usr/include/sys/fpu.h` | `8b8b92b81cadd213167c5e515644ba6f66ea7dd249799175e2f96b2ad11559f4` |
| `vanilla/usr/include/sys/user.h` | `ea222c0b5bdae9092f6830cdd106cf5b388d5b4a00bcfa92a9c353013e8c73bf` |

The 3B2 tree does not define this 68k FPU state machine. Generic SVR4 process,
signal, and `/proc` control flow remains useful, but the AMIX machine header
and the m68k binary are authoritative for `UFPRWRT`.

### Binary layout

`fpu_ptr` is the `.data` long at `.data + 0x4fe0`. Its relocation points to
`u + 0x9c`; only `fpu_save` and `fpu_restore` read it. The resulting layout is:

| u-area address | `fpu_info` offset | Field |
|---:|---:|---|
| `u + 0x09c` | `+0x00` | `u_fpu.ustate` |
| `u + 0x0a0` | `+0x04` | FP0-FP7, eight 12-byte values |
| `u + 0x100` | `+0x64` | FPCR |
| `u + 0x104` | `+0x68` | FPSR |
| `u + 0x108` | `+0x6c` | FPIAR |
| `u + 0x10c` | `+0x70` | raw FSAVE state |

The big-endian instruction `btst #0,3(a0)` at `0x138` and `0x180` addresses
bit zero of the 32-bit `ustate` long. This is not an unexplained byte flag.

### 68060 references

The local NetBSD archive has SHA-256
`76a600e703d2e964753323e264d3ec07d0c6cbe134648fc8f0f13ed9faaa1be4`.
Its references establish the 060 discriminator independently:

- `usr/src/sys/arch/m68k/include/frame.h:162-165` defines null `0x00`, idle
  `0x60`, and exception `0xe0` formats;
- `usr/src/sys/arch/m68k/m68k/switch_subr.s:123-129` tests `2(frame)` before
  saving FP registers on 060;
- `switch_subr.s:234-243` tests `2(frame)` before restore;
- standalone `m68881_save`/`m68881_restore` repeat the same 060 rule at
  `switch_subr.s:357-393`.

Motorola's package source has SHA-256
`78df357f3362072a288eb04bd463858c8e75b9ca162ddac7171cf1fd25e581a5`.
It repeatedly writes status words such as `0xe005`, `0xe003`, and `0xe001` to
`2 + FP_SRC`. Its sample enabled-exception call-outs in `fskeletn.s:77-186`
all use:

```asm
fsave      -(%sp)
mov.w      &0x6000,2(%sp)
frestore   (%sp)+
```

This includes `_060_real_dz` at `fskeletn.s:151-167` without a null guard.
The current AMIX glue has SHA-256
`b3ce7a7842be014fde9a8de9b316629acae6e816d4c6a48ddeb234a2c9fa6e92`;
its explanatory comments at `fpsp060_glue.s:276-318` are superseded by this
format-field proof.

## Q1: field name and meaning

The field is `u.u_fpu.ustate`; bit zero is `UFPRWRT`.

The source comment is stronger and narrower than "PCB copy authoritative":
it marks the need to update the 68881 programmer model from the u-vector
before normal context-switch processing. The operational contract in the
binary is:

- `UFPRWRT == 0`: hardware is the normal source for the next save;
- `UFPRWRT == 1`: the u-vector programmer-model image is newer than hardware;
- save must not overwrite that image while the bit is set;
- restore publishes the image to hardware and clears the bit.

It says nothing about ownership of the raw internal state and does not mean
that FP registers are dead. The word "lazy" only describes deferred
publication of software-written register values, not lazy FPU ownership.

## Q2: writer census

### Originating setter

There is exactly one proven originating setter in the pinned image:

| Function | Site | Gate | Operation | Verdict |
|---|---:|---|---|---|
| `procxmt` | `0x47fac` | `fpu_present` and `fpu_wrt_ok(address)` | `orl #1,u+0x9c`, then write the requested long | Old `ptrace` FP-register write publishes a software-newer image |

The bytes at the setter are:

```text
0x47faa  7c01                 moveq #1,d6
0x47fac  8db9 0000009c       orl d6,u+0x9c
0x47fb2  24b9 ...            move requested value to the approved address
```

`fpu_wrt_ok` at `0x19bf0` permits the FP0-FP7 longwords and FPCR/FPSR. It does
not accept arbitrary u-area memory.

### Consumers, clearers, and propagators

| Function | Site | Effect on `ustate` | Classification |
|---|---:|---|---|
| `fpu_save` | `0x138` | tests bit; set means return without saving | consumer, preserves pending software write |
| `fpu_restore` | `0x174`, `0x194` | clears bit after applying state | sole normal clearer |
| `fpu_setup` | `0x19b8a` | clears whole `ustate` | reset at boot, exec, and signal-handler setup |
| `setuctxt` | `0x41942` | copies the entire 8 KiB u-area | propagates existing state into a child; does not originate it |

The direct relocation census finds no second write to `u + 0x9c`. Inspection
of the mapped-u-area writers gives the following negative results:

| Candidate | Result |
|---|---|
| process creation/fork | no originating set; `setuctxt` snapshots then copies the u-area |
| exec | `setregs -> fpu_setup`; state and programmer model are reset |
| first FP use | no setter and no lazy-owner handoff |
| 060 FPU-disabled call-out | no setter; the current zero counter is consistent with an invariant trap |
| context switch | `fpu_save`/`fpu_restore` only; no setter |
| signal delivery | `savecontext` snapshots, then `sendsig+0x1f8` calls `fpu_setup`; no setter |
| signal return | paired raw-state and programmer-model restore; no setter |
| core dump | save only; no setter |

### `/proc` asymmetry

`prioctl` at `0x62c16-0x62c48` implements the FP-register set operation by
calling `prsetfpregs`. `prsetfpregs` at `0x63398` maps the target u-area and
writes `u + 0xa0...0x108`, but never sets `UFPRWRT`.

This is not the DZ root cause. It is, however, a latent contract gap when a
debugger writes programmer registers for a target whose saved raw frame is
truly null: the subsequent restore has no reason to load the new values.
With a non-null frame it happens to work because the normal restore path
always loads the programmer-model image. This deserves a separate `/proc`
acceptance probe before changing it.

`restorecontext` also calls `prsetfpregs`, but pairs it with `prsetfpstate` and
then immediately calls `fpu_restore`. A context produced by `savecontext`
therefore carries the raw-state decision with the programmer model; this is
not evidence for a second `UFPRWRT` owner.

## Q3: state and lifecycle contract

The complete inherited call-site set is:

| Caller | Save site | Restore site | Role |
|---|---:|---:|---|
| `setuctxt` | `0x4192e` | direct `frestore` at `0x41934` | snapshot before copying the complete u-area |
| `restorecontext` | `0x58ea4` | `0x58eca` | replace programmer and raw context, then resume it |
| `savecontext` | `0x58f8a` | `0x58fce` | snapshot a signal/ucontext and resume current hardware |
| `coffcore` | `0xb7ffa` | none | terminal core snapshot |
| `swtch` | `0xb920a` | `0xb905e` | eager outgoing/incoming process state |

### State table

The inherited state machine has two independent dimensions:

| Raw frame | `UFPRWRT` | Meaning before restore | Required action |
|---|---:|---|---|
| null | 0 | process has no active internal FP state | `FRESTORE` null; no programmer-model load |
| null | 1 | software supplied programmer registers without active raw state | reset via raw frame, load software image, clear bit |
| non-null | 0 | saved hardware state and programmer model form one snapshot | load programmer model, `FRESTORE` raw state, clear bit |
| non-null | 1 | software programmer model supersedes the previous hardware registers | save must have skipped; load software image, restore raw state, clear bit |

For 6888x/040, byte zero is the frame-format discriminator. For 060, byte two
is the discriminator. Only that test changes; `UFPRWRT` semantics do not.

### Routine invariants

#### `fpu_save` at `0x132`

Entry: the current process is still available through the fixed u-area and
the current hardware FPU state belongs to it.

- If `UFPRWRT` is set, return without modifying either u-vector component.
- Otherwise FSAVE the raw internal state.
- If that state is non-null, copy FP0-FP7 and FPCR/FPSR/FPIAR into `u_fpu`.
- Do not set or clear `UFPRWRT`.

The task's E3 phrase "both only clear it" is slightly inaccurate: only
`fpu_restore` contains the `andi.l #-2` clear. `fpu_save` only tests the bit.

#### `fpu_restore` at `0x158`

Entry: the desired process u-area is installed at the fixed address.

- A non-null raw frame causes programmer-model restore followed by FRESTORE.
- A null raw frame is restored first; programmer registers are then loaded
  only when `UFPRWRT` says software supplied them.
- Every path that consumes software-written state clears `UFPRWRT`.

The inherited ordering must remain intact. The port needs a 060-specific
discriminator, not a reinterpretation of this state machine.

#### Context switch at `swtch`

The outgoing process calls `fpu_save` at `0xb920a` before its fixed u-area is
replaced. The resumed process calls `fpu_restore` at `0xb905e` after `save()`
returns through its own context. This is eager per-process save/restore.

No FPU-owner pointer was found. `_060_real_fpu_disabled` is therefore an
unexpected-state hook, not the normal first-use mechanism. Its zero hardware
counter agrees with that conclusion but is not the basis for it.

#### `setuctxt` at `0x41918`

`setuctxt` calls `fpu_save` at `0x4192e`, directly FRESTOREs the current raw
state at `0x41934`, then copies all `0x2000` bytes of the parent u-area to the
child at `0x41942`. It propagates a coherent state, including a pending
`UFPRWRT` bit, but creates no new software-write state.

#### `savecontext` at `0x58f10`

When FP is present, it:

1. calls `fpu_save` at `0x58f8a`;
2. obtains the programmer model with `prgetfpregs` at `0x58fb6`;
3. obtains raw state with `prgetfpstate` at `0x58fc8`;
4. calls `fpu_restore` at `0x58fce`.

It snapshots and resumes one coherent machine state. Its old 68882-specific
format check at `0x58f90` is separate from the 060 frame-discriminator fix.

#### `restorecontext` at `0x58d76`

For a context with FP state it calls `fpu_save`, `prsetfpregs`,
`prsetfpstate`, then `fpu_restore` at `0x58ea4-0x58eca`. The raw frame and
programmer model come from the same saved context.

#### Signal delivery

`sendsig` calls `savecontext` at `0x5917c` and then `fpu_setup` at `0x5921a`.
The signal handler begins with reset FP state. Signal return passes the saved
programmer model and raw frame through `restorecontext`.

This explains why an incorrect format decision at either FPSP call-out or
`fpu_save` can survive until after a returning handler: the handler's clean
state is intentional; recovery depends entirely on the saved context.

#### `coffcore` at `0xb7f70`

`coffcore` calls `fpu_save` at `0xb7ffa` before writing the u-area. It needs a
correct snapshot but no paired restore because this is the terminating core
path. The task's `0xb920a` address is the `swtch` save call, not a second
`coffcore` site.

## The 68060 discriminator correction

The current glue at `prototypes/fpsp060_glue.s:275-318` does:

```asm
fsave   %sp@-
tstw    %sp@
beq     Lco_nullfr
movew   #0x6000,%sp@(2)
frestore %sp@+
```

In the 060 FPSP arithmetic exception frame at this call-out:

- word zero belongs to the extended source operand and includes its exponent;
- the status/format word is at offset two;
- its high byte is `0x00`, `0x60`, or `0xe0` for null, idle, or exception.

The hardware observations are therefore exactly what the operand predicts:

| Class | word zero | Meaning |
|---|---:|---|
| OPERR | `0x7fff` | NaN/infinity exponent pattern |
| INEX | `0x4000` | finite source exponent |
| DZ | `0x0000` | zero source operand exponent |

At `_fpsp_dz`, Motorola FSAVEs `FP_SRC`, adjusts the source operand, restores
FP0-FP1 and controls, then FRESTOREs `FP_SRC` before `_real_dz`
(`fpsp.s:3749-3813`). That sequence leaves a valid exception state. It does
not establish a null frame. Motorola's call-out then converts that state to
idle by writing `0x6000` at offset two and restoring it.

The current DZ branch instead discards the frame produced by FSAVE. FSAVE has
already removed the state from the FPU, so the following AMIX signal snapshot
sees null and cannot preserve the programmer registers. This accounts for the
measured reset without assigning a new meaning to `UFPRWRT`.

The same offset error exists in stock `fpu_save` at `0x144` and `fpu_restore`
at `0x15e`. The measured class correlation is explained by byte zero being
nonzero for the five passing operands and zero for DZ. That is a strong
mechanistic inference from the binary and the observed values, but the later
save frame itself was not captured byte-for-byte. Either way, byte zero is
not a valid 060 frame test, so the implementation decision does not depend on
that inference.

## Q4: change options

### A. Save programmer registers unconditionally on 060

Verdict: reject.

It replaces a format error with unconditional traffic and invents values for
genuinely null contexts. It also does not repair the glue path that discards
the frame after FSAVE. The previous attempt additionally set `UFPRWRT`, which
asserted that the u-vector was newer and made the next `fpu_save` skip. That is
the opposite of the measured hardware-live state.

The observed `7100` count was collected through the wrong byte-zero
predicate. It must be remeasured by byte two before it is used as a cost
estimate.

### B. Leave a non-null frame before entering AMIX signal handling

Verdict: required but insufficient alone.

Motorola already specifies the operation: FSAVE, write idle status `0x6000`
at offset two, FRESTORE. The glue should execute this for DZ exactly as it
does for the other arithmetic exits. A word-zero null guard has no place in
that sequence.

Stock `fpu_save` and `fpu_restore` would still make data-dependent decisions
from byte zero, so the context routines must also be corrected for 060.

### C. Change only the signal path

Verdict: reject.

`fpu_save` and `fpu_restore` are shared by context switches, fork setup,
ucontext, and core capture. A signal-only workaround would leave ordinary
060 idle-state context switches dependent on operand bytes.

### D. Contract-derived CPU-specific state implementation

Verdict: recommended.

#### 68060 `fpu_save`

```text
fp = fpu_ptr
if fp->ustate & UFPRWRT:
        return
FSAVE fp+0x70
if byte(fp+0x72) != FPF6_FMT_NULL:
        save FP0-FP7 to fp+0x04
        save FPCR, FPSR, FPIAR to fp+0x64..0x6c
return
```

Do not set or clear `UFPRWRT` here.

#### 68060 `fpu_restore`

Retain the inherited branch ordering, but test `fp + 0x72`:

```text
if byte(fp+0x72) != FPF6_FMT_NULL:
        load FP0-FP7 and FPCR/FPSR/FPIAR
        FRESTORE fp+0x70
        clear UFPRWRT
else:
        FRESTORE fp+0x70
        if fp->ustate & UFPRWRT:
                load FP0-FP7 and FPCR/FPSR/FPIAR
                clear UFPRWRT
return
```

Separate control-register moves are preferable on 060, as already specified
by `FPU-TIER1-ENABLE-SPEC.md` and demonstrated by NetBSD.

#### Arithmetic call-outs

For SNAN, OPERR, OVFL, UNFL, DZ, and INEX, restore the Motorola prelude
without the `tstw (%sp)` branch. If a diagnostic guard is retained, it must
inspect byte two; a true-null frame at an enabled arithmetic call-out is an
invariant failure to count and fail loudly, not a normal DZ case.

#### Reset path

The 68060 `fpu_setup` path must install a complete 12-byte reset frame. The
stock eight-byte `reset_fsave` copy remains correct only for the inherited
path. This requirement was already established in `FPU-TIER1-ENABLE-SPEC.md`.

#### Cost and preserved invariant

The fast path adds a CPU gate and correct byte-two test. Programmer-register
traffic remains conditional on a genuinely non-null 060 state; true-null
processes still skip it. The call-out executes Motorola's original three
instructions only on enabled IEEE exceptions. No per-process storage grows.

The preserved invariant is simple: hardware is authoritative unless
`UFPRWRT` explicitly marks a software-newer programmer model. Raw frame format
selects whether hardware has internal state; operand data never does.

## Q5: normal FPSP completion paths

The Motorola package contains 22 terminal transfers to `_fpsp_done` at:

```text
746, 821, 996, 1095, 1353, 1422, 1588, 1622, 1908, 1931, 2009,
2045, 2139, 2167, 2655, 2717, 2794, 2898, 2918, 4130, 4383, 4449
```

They split into two relevant classes:

- normal completed operations restore the package-saved FP0/FP1 and control
  registers, or write their target FP register, before `_fpsp_done`;
- enabled-exception paths synthesize an `0xe00x` status at `2 + FP_SRC` and
  FRESTORE it before calling the corresponding `_real_*` exit.

`fmovecr` follows `funimp_fmovcr -> smovcr -> funimp_fsave -> store_fpreg ->
funimp_gen_exit`; it rejoins a normal completion after publishing the result.

No inspected path deliberately reaches `_fpsp_done` with a true
`frame[2] == 0` state while leaving live programmer registers outside the
saved model. Motorola's skeleton permits `_060_fpsp_done` to execute `rte`
directly (`fskeletn.s:65-74`), which is consistent with that contract.

Thus Q5's proposed second "null frame with live registers" class is not
supported. There is nevertheless a broader present bug: any ordinary 060
idle/exception state for which byte zero is zero can be misclassified by the
stock AMIX routines. Correcting the discriminator closes that entire class;
special-casing DZ would not.

Because 22 package exits are too broad to prove solely from one hardware
class, a debug-only balanced FSAVE/FRESTORE probe at the AMIX `_fpsp_done`
call-out should classify byte two as null/idle/exception. This is validation
of the package invariant, not a proposed runtime mechanism.

## Acceptance gates for the later implementation

1. Keep `fpu_save`, `fpu_restore`, `fpu_setup`, and arithmetic call-out bytes
   unchanged on the 68040 path; all new counters remain zero on 040.
2. Count 060 post-FSAVE state by byte two: true null `0x00`, idle `0x60`,
   exception `0xe0`, and unexpected values. Retire byte-zero counters from
   semantic use.
3. Require all six enabled IEEE fixtures to preserve bit-exact FP0, FPSR, and
   FPIAR across a returning signal handler.
4. Add a forced context switch between FPSP completion and result checking,
   including `fmovecr` and one ordinary non-exceptional FP operation.
5. Run the existing `fputest060` fork/context suite.
6. Exercise old `ptrace` FP-register writes and prove `UFPRWRT` is set once,
   suppresses the next save, is consumed by restore, and returns to zero.
7. Separately probe `/proc` FP-register writes against a target with a true
   null raw frame before deciding whether `prsetfpregs` needs a setter.
8. Count true-null frames entering each enabled arithmetic call-out; the
   expected accepted value is zero.
9. Require `_060_real_fpu_disabled` to remain zero. A nonzero value indicates
   a different ownership/enable fault and must not be hidden by this change.

## Relationship to earlier analysis

`FPU-STATE-CENSUS.md` already classified the inherited byte-zero decision as
060-incompatible. `FPU-TIER1-ENABLE-SPEC.md` already specified byte `+2` for
060 save/restore and a complete 12-byte reset frame. Those conclusions stand.

This audit adds the missing `UFPRWRT` ownership proof, identifies the lone
setter and `/proc` asymmetry, and corrects the new DZ-specific premise. The
implementation should build on the earlier 060 design rather than on the
reverted unconditional-save experiment.
