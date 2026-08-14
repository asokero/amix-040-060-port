# 68040/68060 Tier 1 Hardware-FPU Enablement Specification

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/FPU-TIER1-ENABLE-SPEC.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

## Scope and target

This specification covers hardware-implemented floating-point operations:

- move and conversion operations supported by the CPU;
- add, subtract, multiply, divide, compare, absolute, negate, and square root;
- FP programmer-model preservation across kernel activity.

It deliberately excludes transcendental instruction emulation and unsupported
data-type handling. Those belong to `FPSP-INTEGRATION-PLAN.md`.

Pinned implementation target:

- kernel task commit: `0af9c58`
- `build/unix-040` SHA-256:
  `5bd37386d9c5a0f89be451b187fa5dfe9e4f05bcf2f1c37accdc22177a225b38`
- `build/unix-040-dbg` SHA-256:
  `a35a4b596f3c1387d4b890f2108fb0c3b8470a4da3292f83873a23fee0f6f952`

This is an implementation specification, not a kernel change.

## Required correction to the original plan

Do not add `fpu_save` and `fpu_restore` calls to `resume040`.

The pinned stock `swtch` body still owns eager FP switching:

```text
0x000b9046  save current integer context
0x000b905e  fpu_restore after the selected context resumes
...
0x000b920a  fpu_save while the outgoing fixed u-area is still mapped
0x000b925c  call native resume at 0x000d9c34
```

The fact that `resume040` itself contains no FP call is therefore not a lost
feature. A direct insertion there would either save the wrong fixed-u image or
save/restore twice, depending on placement.

The Tier 1 implementation is instead:

| CPU | Required action |
|---|---|
| 68040 | Validate the existing probe and eager switch before changing code |
| 68060 | Override the four frame-sensitive routines and retain stock `swtch` |

## Design decision: eager, not lazy

Retain eager context switching for the first correct implementation.

The existing kernel already has:

- one saved FP image in every u-area;
- complete save/restore call placement;
- `/proc`, exec, signal, fork, and core-file consumers built around that image;
- no current per-process FPU-owner field;
- no existing FP-disabled ownership trap protocol.

A lazy design would need all of the following new state:

- current hardware FP owner;
- per-process valid/dirty state;
- an intentional FPU-disable mechanism;
- vector-11 ownership dispatch that distinguishes lazy activation from a
  genuinely unimplemented instruction;
- forced save during exit, `/proc`, core, fork, and signal paths;
- CPU-specific 040 versus 060 disable semantics.

That is a different milestone and offers no correctness advantage for initial
enablement. The accepted contract is:

```text
when fpu_present != 0, every swtch saves the outgoing image and restores the
incoming image through the fixed u-area
```

## Phase 0: prove the 68040 baseline

Before applying any FPU code override, run a diagnostic image that records:

1. `fpu_present` after `fpuinit`;
2. whether `chk_fpu`'s temporary vector-11 landing pad ran;
3. the first 12 bytes of `reset_fsave` after the probe;
4. `cputype`;
5. counts of `fpu_save` and `fpu_restore`.

Expected full-68040 result:

```text
cputype       = 40
fpu_present   = 1
probe trap    = 0
FSAVE frame   = valid 040 null/reset frame
save/restore  = paired under process-switch load
```

The static ELF value `fpu_present=0` is not a failure: `.data` must start at
zero before boot probing. Existing boot logs contain no observed
`no fpu detected` message, which is supporting but not sufficient evidence.

### If the 040 probe reports zero

Do not patch `fpu_present` or force it to one. Preserve and print:

- vector 11 before and after temporary replacement;
- probe landing-pad flag;
- fault PC and format/vector word if vector 11 fired;
- all 12 scratch bytes;
- whether `FRESTORE` or `FSAVE` was the faulting operation.

Only then choose between:

- a probe-buffer/initial-frame correction;
- an emulator CPU/FPU configuration correction;
- a real no-FPU/LC040 outcome.

A broad startup poke would hide all three cases and make later context
corruption nondiagnostic.

## 68040 implementation verdict

If Phase 0 and the Tier 1 tests pass, make no 040 state-machine patch.

The existing code has the required properties:

- `fpuinit` is reached through `init_tbl`;
- `chk_fpu` uses a 040-compatible null-frame test;
- `fpu_info.fsave` has 216 bytes, versus a 100-byte maximum 040 busy frame;
- `fpu_save` and `fpu_restore` preserve FP0-FP7 and FPCR/FPSR/FPIAR;
- `setregs` resets FP state on exec;
- `setuctxt` snapshots state before fork/context copy;
- normal FP exceptions already map to `SIGFPE`;
- `swtch` retains eager state transfer.

Tier 2 is still required for `fsin`, `fcos`, `fatan`, `flogn`, `fetox`, and
other instructions not implemented by the 040 hardware.

## 68060 implementation

### Why an override is mandatory

The 060 FSAVE frame is 12 bytes and identifies its state at byte 2. The stock
AMIX routines inspect byte 0 and use an eight-byte reset buffer. Under normal
060 switching, the stock code can therefore classify a live idle frame as
null and omit FP0-FP7 and control-register preservation.

PCR bit 1 also disables the 060 FPU. The current project contains no PCR
enable write.

### Override surface

Add one machine-dependent object, for example `fpu04060.o`, exporting strong:

```text
fpu_save
fpu_restore
fpu_setup
fpuinit
```

Preserve callable aliases for the inherited bodies:

```text
fpu_save_orig    = .text:0x00000132
fpu_restore_orig = .text:0x00000158
fpu_setup_orig   = .text:0x00019b50
fpuinit_orig     = .text:0x00019bac
```

Weaken only those original symbols and let all existing relocations resolve
to the strong dispatch definitions. Do not patch the five save, three
restore, or three setup calls independently.

Dispatch rule:

```text
if cputype != 60:
    tail-call corresponding *_orig routine
else:
    execute 060 body
```

This keeps the byte-proven 040 path unchanged while repairing 060.

### Old-byte assertions

Before relinking, assert the pinned entry bytes:

| Symbol | Address | Required leading bytes |
|---|---:|---|
| `fpu_save` | `0x00000132` | `20 79 00 00 00 00 08 28 00 00 00 03 f3 28 00 70` |
| `fpu_restore` | `0x00000158` | `20 79 00 00 00 00 4a 28 00 70` |
| `fpu_setup` | `0x00019b50` | `4e 56 00 00 48 e7 00 30 48 78 00 08` |
| `fpuinit` | `0x00019bac` | `4e 56 00 00 48 79 00 00 00 00 48 79 00 00 00 00` |

Also assert:

- the symbol value and type before weakening;
- all expected relocation counts still equal 5/3/3;
- `init_tbl` has one relocation to `fpuinit`;
- `fpu_ptr` still relocates to fixed `u + 0x9c`;
- `fpu_present` remains the existing global object.

Abort the relink on any mismatch.

### 060 `fpuinit`

The 060 branch should:

1. set `fpu_present = 0`;
2. install a temporary vector-11 handler while preserving the prior entry;
3. read PCR with `movec`;
4. clear PCR bit 1 and write PCR back;
5. use a dedicated, aligned buffer of at least 12 bytes;
6. execute a reset/probe FRESTORE and FSAVE;
7. restore vector 11 on every success and fault path;
8. set `fpu_present = 1` only if no trap occurred and byte 2 describes a
   valid 060 frame;
9. populate the reset programmer-model image and complete 12-byte reset frame;
10. call the 060 setup body only after success.

The relevant `movec` encodings used by the 060 support reference are:

```text
4e 7a 08 08    movec PCR,d0
4e 7b 08 08    movec d0,PCR
```

The PCR operation must remain inside the `cputype == 60` branch. Executing it
on 040 is not a legal detection method.

Do not simply clear PCR bit 1 and declare success. A 68LC060 or EC variant can
lack usable hardware FP, and vector 11 remains the authoritative negative
probe.

The temporary fault handler must use a separate result flag and must not
enter the normal Unix `SIGSYS` path during boot probing.

### Reset-frame storage

Do not enlarge `fpu_info` or the u-area.

Use:

- existing 216-byte `fpu_info.fsave` for per-process state;
- existing 216-byte signal save area for signal state;
- a new 12-byte-or-larger 060 reset/probe object in the appended object.

The inherited COMMON `reset_fsave` is only eight bytes. Never issue a 060
FSAVE into it and never copy only those eight bytes into a 060 process image.

### 060 `fpu_setup`

The 060 body should:

1. copy the complete 12-byte reset frame to `fpu_ptr + 0x70`;
2. restore/reset the hardware from that complete frame;
3. copy the existing 108-byte reset programmer model to `fpu_ptr + 0x04`;
4. clear `fpu_ptr->ustate`;
5. leave the rest of the 216-byte raw slot deterministic, preferably zero.

This preserves the public AMIX `fpu_info` offsets and all core/proc consumers.

### 060 `fpu_save`

The wrapper has no arguments. It must load the existing `fpu_ptr`, not
`curproc` and not a `proc *`.

Required sequence:

```text
fp = value stored in fpu_ptr
if fp->ustate has UFPRWRT:
    return without overwriting the software-supplied image
FSAVE fp+0x70
if format byte at fp+0x72 is non-null:
    save FP0-FP7 at fp+0x04
    save FPCR at fp+0x64
    save FPSR at fp+0x68
    save FPIAR at fp+0x6c
return
```

Use separate FPCR, FPSR, and FPIAR moves, matching the known 060 context
reference. Preserve the stock routine's ABI-visible integer registers and
condition-code expectations.

Read the 060 format byte only after FSAVE has completed. Never use
`tst.b (frame)` for the 060 branch.

### 060 `fpu_restore`

Mirror the inherited semantics:

```text
fp = fpu_ptr
if frame format at fp+0x72 is non-null:
    restore FPCR
    restore FPSR
    restore FPIAR
    restore FP0-FP7
    FRESTORE fp+0x70
    clear UFPRWRT
else:
    FRESTORE fp+0x70
    if UFPRWRT is set:
        restore FPCR/FPSR/FPIAR and FP0-FP7 from the software image
        clear UFPRWRT
return
```

The exact null plus `UFPRWRT` branch must preserve `/proc` behavior: software
register edits cannot be discarded merely because the raw internal frame is
null.

Use the NetBSD 060 sequence as an instruction-order reference, but retain
AMIX's offsets and `UFPRWRT` policy.

## Exception-vector requirements for Tier 1

No 040 vector retarget is needed for basic hardware instructions:

- implemented operations execute directly;
- divide by zero, underflow, overflow, operand error, signaling NaN, BSUN, and
  inexact exceptions already enter `nullvect` and the Unix signal path;
- vector 11 intentionally remains `SIGSYS` until Tier 2.

For 060 Tier 1:

- leave vector 11 on the Unix path after boot probing;
- do not claim unimplemented-instruction support yet;
- record vector 60 and 61 events as unsupported/unexpected until 060SP;
- use the temporary vector-11 replacement only inside the boot probe.

Tier 1 acceptance must verify an ordinary arithmetic exception is delivered
without corrupting the saved FP image.

## Core, signal, fork, and `/proc` compatibility

The state area ABI remains fixed, but the 060 implementation must validate all
consumers:

| Consumer | Required property |
|---|---|
| `setuctxt` / fork | Live state is saved before the u-area image is copied |
| `setregs` / exec | New image receives reset FP state |
| `sendsig` / signal return | Handler starts clean and interrupted state returns |
| `procxmt` / `/proc` | `UFPRWRT` changes survive the next restore |
| `coffcore` | Live state is snapshotted before writing |
| `elfcore` | FP note availability, size, and payload remain coherent |
| `savecontext` | Legacy 68882 BIU-format test remains harmless for 040/060 |

No consumer needs a new offset. However, passing only the context-switch test
does not close these interfaces.

## Tier 1 acceptance programs

Build the tests with the native AMIX compiler in K&R-compatible mode. Inspect
the final executable before running it:

- permit `fmove`, `fadd`, `fsub`, `fmul`, `fdiv`, `fsqrt`, `fcmp`, and
  conversions;
- reject `fsin`, `fcos`, `ftan`, `fatan`, `fetox`, `flogn`, `frem`, and other
  software-package instructions from the Tier 1 binary;
- reject an accidental dependency on a transcendental `libm` startup path.

### Test A: basic implemented operations

Use volatile double inputs and independently known hexadecimal/result
patterns. Exercise:

```text
add -> subtract -> multiply -> divide -> square root -> compare
```

Run enough iterations to prevent constant folding. Report both numerical
results and a deterministic checksum of their stored 64-bit representations.
An assembly helper may issue `fsqrt.d` explicitly if the C compiler lowers
`sqrt()` through a library routine.

### Test B: FP-register switch canary

An assembly helper should:

1. load unique 96-bit values into FP2-FP7;
2. return to C without using those registers;
3. force many system calls and scheduler switches;
4. read FP2-FP7 back;
5. compare every byte.

Run at least 32 concurrent workers, each with a process-unique canary, for
thousands of yields or blocking pipe operations. FP0/FP1 may be compiler
temporaries; FP2-FP7 make the ownership failure easier to localize.

### Test C: fork and exec

- establish a live FP accumulator before fork;
- have parent and child diverge to different expected values;
- run both under scheduler pressure;
- confirm one process cannot inherit later updates from the other;
- exec a helper and confirm reset state rather than stale parent state.

### Test D: asynchronous signal

Use repeated `SIGALRM` while an FP accumulator and FP2-FP7 canaries are live.
The handler should perform its own basic FP work. Confirm both handler output
and interrupted-state restoration.

### Test E: process inspection and core

When practical:

- read FP state through `/proc`;
- modify an allowed register and confirm `UFPRWRT` applies it;
- generate COFF/ELF core state and inspect the FP payload;
- confirm FPIAR's inherited write restriction is unchanged.

### Negative Tier 2 control

Before FPSP integration, issue one known `fsin` instruction in a separate
test process. Expected 040 result:

```text
process receives the existing SIGSYS result; kernel and other processes stay
healthy
```

This proves Tier 1 has not accidentally hidden vector 11.

## Acceptance matrix

| Environment | Boot probe | Basic ops | Switch canary | Fork/exec | Signals | Negative `fsin` |
|---|---|---|---|---|---|---|
| Amiberry 68040 | Required | Required | Required | Required | Required | Required |
| Amiberry 68060 | Required | Required after 060 override | Required | Required | Required | Required |
| Real 68040 | Required | Required | Required | Required | Required | Required |
| Real 68060 | Separate milestone | Separate milestone | Separate milestone | Separate milestone | Separate milestone | Separate milestone |

Emulator success is useful for logic and context ownership. It does not
replace real-silicon exception-frame validation.

## Relink and rollback checks

The implementation image must report:

- exactly one strong definition for each overridden routine;
- each original alias still callable;
- 5 save, 3 restore, and 3 setup call relocations resolving to the wrapper;
- the `init_tbl` entry resolving to wrapper `fpuinit`;
- no new direct FP calls in `resume040`;
- unchanged `fpu_info` and u-area offsets;
- no 060 FSAVE target smaller than 12 bytes.

Keep a build-time switch that omits `fpu04060.o` and reproduces the pinned
baseline. A test failure should therefore be reducible to:

1. stock image;
2. wrapper linked but 040 delegated;
3. 060 routines enabled;
4. later FPSP vector hooks.

## Implementation order

1. Read and record runtime `fpu_present` on the unchanged 040 and 060 image.
2. Run the basic 040 arithmetic and switch-canary tests unchanged.
3. If 040 passes, preserve the stock 040 path.
4. Add the four CPU-dispatch overrides with old-byte and relocation asserts.
5. Implement and test 060 probe/setup.
6. Implement and test 060 save/restore under process and signal pressure.
7. Close fork, exec, `/proc`, and core consumers.
8. Keep vector 11 as the Tier 2 boundary until the FPSP milestone.
