# 68040 FPSP and 68060SP Integration Plan

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/FPSP-INTEGRATION-PLAN.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

## Scope and pinned target

This plan covers Tier 2 floating-point support:

- 68040 instructions not implemented in hardware, including transcendental
  operations;
- 68040 unsupported-data-type and package-assisted exception handling;
- the corresponding, but separate, Motorola 68060 software package;
- the kernel vector, exit, memory-access, and signal ABI needed by both.

It does not implement the packages and does not modify the kernel.

Pinned kernel target:

- kernel task commit: `51f3d71`
- `build/unix-040` SHA-256:
  `5bd37386d9c5a0f89be451b187fa5dfe9e4f05bcf2f1c37accdc22177a225b38`
- `build/unix-040-dbg` SHA-256:
  `a35a4b596f3c1387d4b890f2108fb0c3b8470a4da3292f83873a23fee0f6f952`

Tier 1 detection and context preservation must pass first. See
`FPU-TIER1-ENABLE-SPEC.md`.

## Recommendation

**Use Motorola's 68040 FPSP for full-FPU 68040 systems. Use Motorola's 060SP
as a separate CPU branch. Do not make NetBSD's generic C FPE the primary
040 path.**

The reasons are concrete:

- the 040 FPSP is designed for the exact hardware exception frames produced
  by a full 68040;
- it emulates only what hardware omitted and leaves normal arithmetic fast;
- it contains Motorola's exception and silicon-workaround logic;
- its body has already been converted and built into an m68k relocatable
  object accepted by the project's SysV4 linker;
- its external OS ABI is a small, enumerable glue surface;
- NetBSD FPE is a larger machine-ABI port despite being written in C;
- 060 uses different frames and exception semantics and must use 060SP, not
  the 040 package.

NetBSD FPE remains valuable as a later fallback for an LC040/no-FPU target or
as a mathematical cross-check. It is not the shortest path to Xsvga on the
current full-FPU 040 target.

## Package comparison

| Property | Motorola 040 FPSP | NetBSD m68k FPE |
|---|---|---|
| Intended CPU | Full 68040 FPU | Software emulation independent of full hardware |
| Work handled | Missing instructions, unsupported types, package exceptions | Complete instruction decode and arithmetic |
| Execution model | Assembly entered from raw 040 exception frame | C called with NetBSD machine trap/register structures |
| Hardware use | Uses the 040 FPU for implemented primitives | Software arithmetic |
| Expected speed | Best available for full 040 | Substantially slower |
| Port surface | Vector wrappers plus 12 observed OS callbacks | Trap frame, FP frame, signals, user fetch/store, headers, and kernel APIs |
| Current build result | Package body builds and links as m68k ELF | Individual C translation still needs a compatibility layer |
| 060 suitability | None | Possible in principle, but not the supplied 060 contract |
| Recommended role | Primary Tier 2 for 040 | Later fallback or reference |

### Correction to the task inventory

The local FPE directory contains 20 `.c` files, not 23:

```text
20 C files                    6,833 lines
3 private headers              548 lines
total                         7,381 lines
```

The distinction matters because the complexity is in its dependencies, not
the raw file count.

## 040 FPSP build proof

The package body under the extracted NetBSD source was converted with its
provided `asm2gas` path and assembled with an m68k GNU toolchain. A relocatable
link produced:

```text
ELF 32-bit MSB relocatable, Motorola m68k
.text size = 39,250 bytes (0x9952)
```

The resulting object was also accepted as input by:

```text
m68k-cbm-sysv4-ld -r
```

This proves object-format and relink compatibility. It does not yet prove the
AMIX exception ABI.

The package body has exactly these unresolved OS glue symbols:

```text
fpsp_done
fpsp_fmt_error
mem_read
mem_write
real_bsun
real_fline
real_inex
real_operr
real_ovfl
real_snan
real_trace
real_unfl
```

The major exported entry points include:

```text
fpsp_bsun
fpsp_fline
fpsp_operr
fpsp_ovfl
fpsp_snan
fpsp_unfl
fpsp_unimp
fpsp_unsupp
```

The existing CBM assembler does not directly accept the generated GNU/MIT
syntax. That is not a blocker: assemble the package body with
`m68k-linux-gnu-gcc -m68040`, then use the existing CBM SysV4 linker for the
kernel relink. Keep the generated package object as a reproducible build
artifact, not as hand-edited source.

Preserve the Motorola copyright and modification notice required by the
package source when carrying its code into a build.

## Why NetBSD FPE is not drop-in

The C source depends on NetBSD-specific definitions and behavior including:

- `struct frame` and `struct fpframe`;
- machine register numbering and saved-register offsets;
- `ksiginfo_t` and NetBSD signal-code construction;
- NetBSD IEEE representation headers;
- `ufetch_*` helpers and user-memory semantics;
- `copyin`, `copyout`, and panic interfaces;
- trap PC adjustment and effective-address conventions.

`fpu_emulate.c` also holds emulator state in its own C model, and
`fpu_calcea.c` assumes NetBSD's user access environment. A successful
cross-compile of arithmetic files would not prove correct trap-frame or
signal integration.

Selecting FPE first would therefore trade a small assembly glue port for a
large kernel ABI shim and a slower runtime. It should be revisited only for:

- 68LC040 or another genuinely absent-FPU target;
- a future all-software diagnostic mode;
- differential tests against Motorola FPSP results.

## Vector ownership and patch mechanism

The kernel installs `M68Kvec` at VBR during startup. In the pinned image all
FP-related `R_68K_32` fields still target `nullvect`. Use relocation
retargeting, not runtime writes to the vector table.

Required assertions per vector patch:

1. the field address matches the pinned table;
2. relocation type is `R_68K_32`;
3. the current relocation target is `nullvect`;
4. the replacement is a strong CPU-dispatch wrapper;
5. all unrelated vector fields remain byte- and relocation-identical.

Pinned fields:

| Vector | Field | Current target |
|---:|---:|---|
| 11 | `0x000013a4` | `nullvect` |
| 48 | `0x00001438` | `nullvect` |
| 49 | `0x0000143c` | `nullvect` |
| 50 | `0x00001440` | `nullvect` |
| 51 | `0x00001444` | `nullvect` |
| 52 | `0x00001448` | `nullvect` |
| 53 | `0x0000144c` | `nullvect` |
| 54 | `0x00001450` | `nullvect` |
| 55 | `0x00001454` | `nullvect` |
| 60 | `0x00001468` | `nullvect` |
| 61 | `0x0000146c` | `nullvect` |

One wrapper name per semantic vector keeps the linker map auditable, for
example:

```text
fpu_vec11_dispatch
fpu_vec48_dispatch
...
fpu_vec61_dispatch
```

Each wrapper branches on `cputype`, restores any scratch integer register and
the original stack pointer, and then enters the CPU package with the raw
hardware exception frame.

The entry must also establish the kernel cache mode before executing package
code. A safe outline is:

```text
push d0 temporarily
load sup_cacr into d0
movec d0,CACR
inspect cputype and select an entry
restore d0 and SP exactly
branch, rather than call, to the selected package entry
```

The temporary push must be gone before the branch so every package stack
offset still refers to the original CPU frame. Normal AMIX return processing
restores the user `cacr`.

Do not call a package entry with a normal C ABI or after `nullvect` has pushed
its 60-byte register block. Motorola FPSP expects the CPU frame at the
package-defined stack offsets.

## 040 vector policy

### Recommended first complete mapping

| Vector | 040 entry policy |
|---:|---|
| 11 | Validate the 040 format/vector; enter `fpsp_unimp` for format-2 unimplemented FP, otherwise use `fpsp_fline` classification |
| 48 BSUN | Package-aware BSUN wrapper to `fpsp_bsun` |
| 49 INEX | Adapt Motorola skeleton's inexact/errata glue, then existing Unix result when real |
| 50 divide by zero | Keep on `nullvect`; all divide-by-zero exceptions are real |
| 51 underflow | `fpsp_unfl` |
| 52 operand error | `fpsp_operr` |
| 53 overflow | `fpsp_ovfl` |
| 54 signaling NaN | `fpsp_snan` |
| 55 unsupported data type | `fpsp_unsupp` |
| 60/61 | Not 040 vectors; keep defensive unexpected handling |

NetBSD's 040 entry validates format/vector `0x202c` before entering
`fpsp_unimp`. Motorola's `fpsp_fline` can also distinguish a true
unimplemented FP instruction, `fmovecr` corner cases, and a real line-F
instruction. Preserve that distinction so a non-FP coprocessor opcode still
becomes the existing `SIGSYS` result.

Vector 49 is not represented by a standalone exported `fpsp_inex` in the
built body. Its wrapper must adapt the package skeleton's E1/E3 and known
erratum handling rather than inventing a missing entry symbol.

### Real-exception callbacks

The `real_*` exits mean that FPSP declined to consume the exception and has
restored the machine state expected by the operating system. They must reach
the existing AMIX trap/signal policy.

Do not reduce every callback to a blind alias to `nullvect`. The Motorola
skeleton performs exception-specific pending-bit cleanup before returning
some real exceptions to the OS. Adapt those short sequences and then enter
the AMIX trap path with the original raw exception frame.

Required outcomes:

| Callback | AMIX outcome |
|---|---|
| `real_fline` | Existing vector-11 `SIGSYS` path |
| `real_bsun` | Existing BSUN `SIGFPE` class after required FPSR cleanup |
| `real_inex` | Existing inexact `SIGFPE` class after E1/E3 handling |
| `real_operr` | Existing invalid-operation `SIGFPE` class |
| `real_ovfl` | Existing overflow `SIGFPE` class |
| `real_snan` | Existing invalid-operation `SIGFPE` class |
| `real_unfl` | Existing underflow `SIGFPE` class |
| `real_trace` | Existing trace semantics, not an unconditional user return if tracing is pending |

Test enabled and masked exception modes separately. A callback that returns
with an uncleared pending exception can retrap indefinitely.

## `fpsp_done` and AMIX return ABI

`fpsp_done` is reached after the package fully emulated the instruction and
reconstructed a returnable raw exception frame. A bare `rte` is insufficient
for a user exception because it bypasses:

- STREAMS queue run processing;
- scheduler-class `cl_trapret`;
- `s_trap` signal and reschedule work;
- AMIX user CACR restoration.

The adapter should use this split:

### Supervisor-origin exception

Kernel FP use is not an intended AMIX workload. If FPSP nevertheless handles
a supervisor-origin frame, restore the wrapper's scratch state and `rte`.
Count the event and make it diagnostic in debug builds.

### User-origin exception

Starting with the package-restored raw frame:

1. push D0-D7/A0-A6 exactly as `nullvect` does, producing the 60-byte AMIX
   saved-register block;
2. load `sup_cacr`;
3. read USP and push it as the pseudo-register immediately before that block;
4. set `u.u_ar0` at `u + 0x864` to that pseudo-register address;
5. pop/reload USP, leaving SP at the register block;
6. branch to `ureturn` at `0x000011f8`.

This reproduces the state normally established by:

```text
nullvect -> utraps -> u_trap -> ureturn
```

without reporting a second trap for an instruction FPSP already completed.
`ureturn` later pushes USP again before `s_trap`, so the saved `u_ar0` address
continues to name the expected pseudo-register slot.

Acceptance must inspect SP, `u_ar0`, saved PC, saved SR, and format/vector
before the final RTE. A one-longword error here would corrupt signal delivery
or return to the wrong instruction.

## Memory operand adapters

Motorola FPSP calls:

```text
mem_read:
    a0 = source effective address
    a1 = supervisor-stack destination
    d0 = byte count, at most 12

mem_write:
    a0 = supervisor-stack source
    a1 = destination effective address
    d0 = byte count, at most 12
```

For supervisor-origin frames, use a bounded byte copy after validating that
the path is intended. For user-origin frames, adapt to AMIX:

```text
copyin(user_source, kernel_destination, count)
copyout(kernel_source, user_destination, count)
```

### Mandatory error rule

The sample NetBSD glue ignores the integer return from `copyin`/`copyout`.
That is not acceptable as an AMIX production contract.

An invalid or newly faulting user operand must not let FPSP continue with
uninitialized stack bytes, and it must not panic the kernel. The glue needs a
defined abort path that:

1. detects nonzero `copyin`/`copyout`;
2. unwinds the FPSP local frame using its documented `a6`/raw-frame layout;
3. requests the appropriate user memory-fault signal;
4. enters AMIX `ureturn` with a coherent register frame;
5. does not advance the emulated PC as if the instruction succeeded.

The exact unwind should be implemented from the Motorola skeleton offsets,
not inferred from one entry point. Until this path is implemented and tested,
the package is an experimental Xsvga enabler, not a general user ABI.

The legal-fault case also tests a second ownership boundary. `copyin` or
`copyout` may sleep, and stock `swtch` can then eagerly save the FPSP's
temporary hardware state into the process u-area. On resume it must restore
that temporary state, let FPSP finish, and eventually leave the user's final
programmer model coherent. Instrument at least one sleeping cross-page
operand and verify:

- save/restore counts remain paired;
- package local state resumes correctly;
- `/proc` and signal delivery do not expose or commit a half-finished package
  image;
- the next ordinary context switch saves the completed user state.

Required tests:

- source operand entirely resident;
- destination operand entirely resident;
- operand crossing a valid page boundary;
- second page absent but legally faultable;
- invalid source address;
- read-only destination;
- signal arriving while a faulting operand is resolved.

## Format-error policy

`fpsp_fmt_error` means the package encountered an unknown or internally
inconsistent 040 frame. It is a kernel invariant failure, not a user
arithmetic exception.

Implement:

```text
panic("bad 68040 FPSP frame")
```

The debug build should first record:

- CPU type;
- vector;
- SR and PC;
- frame format/version/size bytes;
- package entry;
- current process.

Do not execute the sample embedded F-line instruction as an error handler.

## 060SP integration

The 060 package is a separate binary and ABI. It must never receive a 040
FSAVE frame or enter through a 040 FPSP symbol.

### Required 060 entries

The supplied glue exposes package branches for:

```text
_060_fpsp_snan
_060_fpsp_operr
_060_fpsp_ovfl
_060_fpsp_unfl
_060_fpsp_dz
_060_fpsp_inex
_060_fpsp_fline
_060_fpsp_unsupp
_060_fpsp_effadd
```

The package's callout area is exactly 128 bytes and uses fixed relative
entries for real exceptions, completion, instruction/data memory access, and
typed reads/writes. Preserve that layout exactly; do not reorder it to match
the 040 callback list.

### 060 vector policy

| Vector | 060 policy |
|---:|---|
| 11 | `_060_fpsp_fline`; it distinguishes unimplemented FP, disabled FPU, and real line-F |
| 48 BSUN | 060 real/package BSUN policy |
| 49-54 | Corresponding 060SP entries, with divide-by-zero included |
| 55 | `_060_fpsp_unsupp` |
| 60 | `_060_fpsp_effadd` |
| 61 | 060 integer software package if included; otherwise explicit unsupported path |

On 060, an implemented instruction attempted while PCR disables the FPU also
arrives through vector 11. The Tier 1 probe should already clear PCR bit 1,
but `_060_real_fpu_disabled` still needs a deliberate policy rather than
being mistaken for a 040 unimplemented operation.

### Shared wrappers, separate package bodies

The vector-table relocation can point to a shared dispatch wrapper:

```text
if cputype == 40:
    enter 040 FPSP/glue
if cputype == 60:
    enter 060SP/glue
else:
    enter nullvect
```

Restore all scratch state before the final branch. Keep independent symbols,
build objects, counters, and rollback switches for `fpsp040` and `fpsp060`.

Real-060 hardware acceptance remains a separate milestone even if Amiberry
passes.

## Instrumentation

Add low-overhead per-CPU-path counters:

```text
040 vector 11 / 48..55 entries
040 fpsp_done
040 real_* exits by class
040 mem_read / mem_write / copy fault
040 format error
060 vector 11 / 48..55 / 60 / 61 entries
060 package done and real exits
supervisor-origin package entries
maximum observed package stack use
```

For the first diagnostic build, retain a small ring with:

```text
sequence, cputype, vector, SR, PC, frame format bytes, process, exit class
```

Do not print from every FP trap; Xsvga and mathematical workloads can generate
many package entries.

## Tier 2 acceptance

### Arithmetic correctness

Use instruction-specific assembly helpers so the test cannot silently call a
different `libm` implementation. Cover at least:

- `fsin(0)`, `fsin(pi/6)`, and a large argument;
- `fcos(0)` and `fcos(pi)`;
- `fatan(1)`;
- `fetox(0)` and `fetox(1)`;
- `flogn(1)` and `flogn(e)`;
- `ftan`, `fsinh`, `fcosh`, and `ftanh`;
- `frem`/`fmod`;
- denormal source and result cases;
- all four rounding modes and supported precision modes.

Compare stored bit patterns or bounded ULP error against precomputed trusted
vectors. Do not use the same kernel FPSP to generate the expected values.

### Exception behavior

Test masked and enabled:

- divide by zero;
- overflow;
- underflow;
- inexact;
- signaling NaN;
- operand error;
- BSUN.

Verify one signal per event, correct signal class, resumability where defined,
and no immediate retrap loop.

### Context and asynchronous behavior

Repeat the Tier 1 FP2-FP7 canary, fork, exec, and `SIGALRM` tests while workers
execute transcendental operations. This detects package exits that bypass
normal `ureturn` housekeeping or damage the per-process frame.

### Xsvga acceptance

The practical 040 acceptance target is:

1. Xsvga server passes the former F-line site;
2. Piccolo mode initialization completes;
3. the graphical display is visible and captured;
4. repeated server start/exit cycles do not leak or retain FP state;
5. a concurrent FP canary process remains correct.

Xsvga success alone is not enough; it may not exercise user-memory faults,
signals, enabled arithmetic exceptions, or every package exit.

## Implementation sequence

1. Complete and accept Tier 1 on 040.
2. Reproduce the package-body build with a checked-in build recipe and hashes.
3. Implement AMIX 040 vector dispatch and the `real_*`/done/format glue.
4. Implement fault-aware `mem_read`/`mem_write`.
5. Run focused instruction, memory-boundary, exception, and context tests.
6. Run Xsvga and graphical acceptance on emulated 040.
7. Validate on real 040 hardware.
8. Integrate the separate 060SP callout table and vector branch.
9. Repeat the full suite on emulated 060.
10. Treat real 060 as a distinct hardware milestone.

## Rollback and closure criteria

Keep independent link switches for:

```text
Tier 1 CPU-specific state routines
040 FPSP body and vector hooks
060SP body and vector hooks
diagnostic ring
```

The Tier 2 milestone is closed only when:

- all patched vector relocations pass old-target assertions;
- package objects build reproducibly;
- no package OS symbol remains unresolved;
- handled user traps return through coherent AMIX `ureturn` state;
- real exceptions retain normal Unix signal behavior;
- `copyin`/`copyout` failures are controlled;
- context, fork, exec, signal, and core paths still pass;
- Xsvga reaches the graphical display;
- 040 and 060 package bodies never receive each other's frame format.
