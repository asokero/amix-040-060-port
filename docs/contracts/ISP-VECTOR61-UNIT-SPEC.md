# 68060 Vector 61 Immediate-Multiply Unit Specification

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/ISP-VECTOR61-UNIT-SPEC.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

## Status and scope

This document answers the six questions in `ISP-VECTOR61-TASK.md`. It is a
static implementation specification, not kernel code.

Pinned input:

- kernel task commit: `a3b9bb67a92d05c2ea23f072a01f9d825e3e5038`;
- `build/unix-040` SHA-256:
  `66a98ca37be2525298691ea545fc05db8500844e0e5633444f9a11b9793a206d`;
- linked `.text` size: `0x000e48b8`;
- current image type: ELF32 big-endian m68k `ET_REL`;
- measured userland scope: 103 instructions, all immediate-source 64-bit
  `MULS.L` or `MULU.L`, with 68 unsigned and 35 signed instances.

The unit deliberately supports only this measured form:

```text
MULU.L #imm32,Dh:Dl
MULS.L #imm32,Dh:Dl
```

All other vector-61 instructions remain work for Motorola's complete 68060
ISP. An instruction outside the accepted form must take a counted,
state-preserving fallback to the current `nullvect` path. It must never be
partly decoded or silently approximated.

## Executive decisions

| Question | Decision |
|---|---|
| Q1: exception frame | Vector 61 creates an eight-byte format-0 frame: SR at `SP+0`, faulting PC at `SP+2`, format/vector at `SP+6`. The frame contains no instruction word. Fetch all eight instruction bytes through `copyin`. |
| Q2: restart or resume | The stacked PC initially points at the unimplemented instruction. After successful emulation, replace it with `old_pc + 8`. Leave it unchanged on every declined or failed path. |
| Q3: minimum decode | Accept opword `0x4c3c`, a valid 64-bit multiply extension, immediate source, and distinct `Dh`/`Dl`. Reject every other form through a counter plus `nullvect`. |
| Q4: result and CCR | Write low 32 bits to `Dl`, high 32 bits to `Dh`; preserve X, set N from product bit 63, set Z from the full 64-bit result, and clear V and C. Update the stacked SR, not the handler's live CCR. |
| Q5: placement | Add a `cputype == 60` wrapper at `M68Kvec[61]`. Link its object in the base image and retarget the vector relocation after the optional FPSP relink. No FPSP vector script owns slot 61. |
| Q6: unit test | Use five raw eight-byte multiply encodings with known products and CCR results, plus a real-060-only unsupported-form child. The 040 must execute the positive cases natively with zero handler counters. |

## Provenance and current-image anchors

### Architecture sources

The authoritative architecture contract comes from:

- Motorola/NXP `M68060 User's Manual`, sections 8.2.4 and 8.4.1, plus
  Appendix C.2.2;
- Motorola/NXP `M68000 Family Programmer's Reference Manual`, the long-form
  `MULS` and `MULU` descriptions;
- Motorola 68060SP `dist/isp.doc`, `dist/isp.s`, and the NetBSD integration
  glue under `sys/arch/m68k/060sp`.

The manuals establish that vector 61 uses a type-0 frame whose PC points to
the unimplemented integer instruction. Motorola's ISP independently fetches
the opword and extension through its instruction-memory callout, advances an
instruction pointer as operands are fetched, writes that pointer back as the
new PC only on success, and synthesizes a trace exception when tracing is
active.

The local NetBSD glue routes `_060_imem_read` through `copyin` for user
origins. This is the correct integration precedent for AMIX: do not directly
dereference a user PC while in supervisor mode.

### Current AMIX image

| Item | Pinned value / evidence |
|---|---|
| `M68Kvec` | `.text:0x00001378` |
| `M68Kvec[61]` relocation field | `.text:0x0000146c` (`0x1378 + 61 * 4`) |
| Current slot-61 relocation | `R_68K_32 -> nullvect` |
| `nullvect` | `.text:0x000011b4` |
| `ureturn` | `.text:0x000011f8` |
| `copyin` | `.text:0x000004fa` |
| `u_trap` | `.text:0x0005a47e` |
| `cputype` | `.data:0x00018610` |
| `sup_cacr` | `.data:0x000072c0` |

The four current relocation fields at `0x1460`, `0x1464`, `0x1468`, and
`0x146c` all target `nullvect`; the last two are vectors 60 and 61. The
existing `patch_fpsp_vec11.py` changes only vector 11.
`patch_fpsp_vectors.py` changes 48 and 51-55 and asserts 49 and 50. Neither
script reads or asserts slot 61, so a dedicated relocation retarget does not
collide with them.

The AMIX `nullvect` path first saves D0-D7/A0-A6, changes to `sup_cacr`, and
routes user-origin frames through `u_trap`. The current `u_trap` table stops
at vector 55, so vector 61 reaches the existing warning and SIGKILL behavior.
That is the required fail-loud fallback for this bounded unit.

## Q1: frame and fault-safe instruction fetch

### Raw CPU frame

On entry through `M68Kvec[61]`, the supervisor stack is:

| Offset | Size | Value |
|---:|---:|---|
| `+0` | 2 | original SR |
| `+2` | 4 | PC of the unimplemented instruction |
| `+6` | 2 | format 0 plus vector offset `0x0f4` |

Total size is eight bytes. An `RTE` from this frame restores SR and PC and
adds eight to SSP. The frame carries no opcode, extension word, effective
address, or immediate.

If the handler clones the stock `nullvect` register save, its 60-byte
D0-D7/A0-A6 block moves those raw fields to:

| Offset from saved-register base | Value |
|---:|---|
| `+60` | original SR |
| `+62` | faulting PC |
| `+66` | format/vector word; must equal `0x00f4` |

The implementation must define these as named constants and assert the final
object's save/restore layout in disassembly. Do not scatter numeric offsets
through the handler.

### Fetch contract

For a user-origin format-0 vector-61 frame:

1. Read `old_pc` from the raw frame.
2. Allocate an aligned eight-byte supervisor scratch area.
3. Call `copyin(old_pc, scratch, 8)` once.
4. Decode only from the completed scratch copy.

One eight-byte `copyin` is intentional. It gives the existing AMIX user-copy
path ownership of function-code selection, nofault handling, page resolution,
and a possible page crossing between the extension and immediate. Separate
raw word/long reads could leave a partially fetched instruction and would
recreate the architectural-state leak class already seen around DFC.

Do not use a supervisor load from `(old_pc)`, do not use an identity alias,
and do not assume the eight bytes share a page.

The full Motorola ISP converts an instruction-fetch failure into an access
error frame. That machinery is outside this targeted unit. If `copyin`
returns failure here, increment `isp61_ifetch_fail_n`, restore the original
registers and untouched raw frame, and jump to `nullvect`. This is a known
fail-loud limitation, not full ISP compatibility.

### Origin and frame validation

Emulation is allowed only when all are true:

- `cputype == 60`;
- original SR has S clear (user origin);
- format/vector word equals exactly `0x00f4`;
- neither trace mode bit is active for this first unit.

A supervisor-origin hit is a kernel invariant failure: count it and route it
to `nullvect`, which reaches the existing kernel-trap behavior. The kernel's
known 64-bit multiply sites have already been replaced by `lmul060.s`; this
unit must not hide a new supervisor use.

Motorola's complete ISP constructs a format-2 trace frame after an emulated
instruction. A plain return would lose that trace event. The minimum unit
therefore rejects any `SR & 0xc000` frame through `isp61_trace_decline_n` and
the unchanged fallback. Compiler execution does not use trace mode. Proper
trace synthesis can be added as a separate, reviewable extension.

## Q2: transactional resume rule

The stacked PC is the instruction start, not the following instruction. The
accepted immediate form is exactly eight bytes:

| Component | Bytes |
|---|---:|
| opword | 2 |
| multiply extension word | 2 |
| immediate source | 4 |
| total | 8 |

The handler must use a transactional sequence:

1. Validate frame and origin.
2. Fetch all eight bytes.
3. Validate the complete encoding.
4. Read the original `Dl` value and compute the entire 64-bit product in
   temporaries.
5. Compute the replacement CCR from the original stacked SR and product.
6. Commit `Dl`, `Dh`, and stacked SR.
7. Write `old_pc + 8` to the stacked PC last.
8. Increment success counters and enter the normal AMIX user-return path.

No branch that can fail may remain after step 6. Every earlier failure leaves
PC, SR, and the saved user registers byte-identical to entry.

Restarting at `old_pc` after emulation would trap forever. Advancing by four
would execute the immediate as opcodes. Advancing by any decoded effective
address length is unnecessary and dangerous because the accepted opword has
one fixed eight-byte length.

## Q3: exact decoder and arithmetic boundary

### Opword

The general long-multiply group is identified by:

```text
(opword & 0xffc0) == 0x4c00
```

The only accepted effective-address field is immediate mode `111100`, so the
unit can and should require the exact opword:

```text
opword == 0x4c3c
```

This excludes 64-bit divide (`0x4c40` group), data-register and memory source
forms, and unrelated vector-61 instructions before any state is changed.

### Extension word

The task wording says `Dl` is in bits 15-12. The architectural diagram is
more precise: bit 15 is fixed zero and `Dl` occupies bits 14-12.

```text
15       14..12   11       10      9..3       2..0
+--------+--------+--------+-------+----------+--------+
| zero   | Dl     | S      | SIZE  | zero     | Dh     |
+--------+--------+--------+-------+----------+--------+
```

Decode and validation:

```text
reserved_ok = (ext & 0x83f8) == 0
size_64     = (ext & 0x0400) != 0
is_signed   = (ext & 0x0800) != 0
Dl          = (ext >> 12) & 7
Dh          = ext & 7
```

Accept only when `reserved_ok`, `size_64`, and `Dh != Dl` are all true.
The programmer's reference manual defines a 64-bit result with `Dh == Dl` as
undefined. Motorola's full ISP chooses a 040-compatible high-word result by
write ordering, but none of the 103 measured compiler sites uses that form.
The bounded unit rejects it rather than inventing an undocumented silent
result.

The immediate is the big-endian longword at `scratch+4`. The multiplicand is
the original saved value of `Dl`; do not read a `Dl` slot after either result
word has been committed.

### Arithmetic

Do not call the public `lmul` entry as though it were a 32-by-32 helper. Its
ABI implements the stock kernel's low-64-bit 64-by-64 operation and includes
additional cross terms. Instead, reuse or factor only the already validated
32-by-32 core in `prototypes/lmul060.s`:

- four `mulu.w` partial products;
- carry propagation into the high longword;
- for signed multiply, the standard correction
  `hi -= (a < 0 ? b : 0)` and `hi -= (b < 0 ? a : 0)` or Motorola ISP's
  equivalent magnitude/two's-complement sequence.

The handler itself must contain no unimplemented 64-bit `MULx.L`, `DIVx.L`,
FP instruction, or dependency on FPSP. All live working registers may be
used because the complete user register set is already saved.

### Unsupported contract

Any of the following increments `isp61_unsupported_n` and takes the
state-preserving `nullvect` fallback:

- opword other than `0x4c3c`;
- 32-bit result (`SIZE == 0`);
- a reserved extension bit set;
- `Dh == Dl`;
- any other vector-61 instruction family.

The last PC and fetched opword/extension should be retained in diagnostics.
The immediate need not be retained. Failure must preserve user registers, raw
SR, and raw PC exactly.

## Q4: register write-back and CCR

Let the complete product be `hi:lo`.

- write `lo` to saved register `Dl`;
- write `hi` to saved register `Dh`;
- X is unchanged;
- N is `hi` bit 31, including for unsigned multiply;
- Z is set exactly when `(hi | lo) == 0`;
- V is zero for the 64-bit form;
- C is zero.

N is not the sign bit of `lo`. In particular, signed
`0x80000000 * -1 = 0x00000000:0x80000000` has N clear because bit 63 is
clear. Conversely, unsigned
`0xffffffff * 0xffffffff = 0xfffffffe:0x00000001` has N set.

The new raw stacked SR is:

```text
new_sr = (old_sr & 0xfff0)
       | ((hi & 0x80000000) ? 0x0008 : 0)
       | ((hi | lo) == 0    ? 0x0004 : 0)
```

Mask `0xfff0` preserves X at bit 4 and every non-CCR SR bit while clearing
N/Z/V/C before the new N/Z values are inserted. The handler's live supervisor
CCR is irrelevant and must not be copied into the frame.

Motorola's ISP source independently follows this contract: it stores low then
high, derives N from the high result even for unsigned multiplication,
derives Z from a zero 64-bit product, preserves old X, and leaves V/C clear.

## Q5: wrapper, completion, and relink wiring

### Entry and CPU gate

Recommended symbols and file:

```text
prototypes/isp61_060.s
isp61_vec
```

`isp61_vec` begins with a memory compare that does not clobber a user register:

```text
if (cputype != 60)
        jump nullvect
```

On 060 it clones the stock `nullvect` save of D0-D7/A0-A6 and then loads
`sup_cacr`. On a normal 040 the supported multiply executes in hardware, so
the vector wrapper is not entered and no 040 instruction stream changes. A
synthetic or unexpected 040 vector-61 hit immediately falls back to stock.

Use one live address register as a stable saved-register base and an aligned
eight-byte scratch below it. The raw frame offsets then remain named relative
to the saved base even while `copyin` arguments are pushed.

### Successful AMIX return

Do not finish with a bare `RTE`. The current `fpsp_done` glue documents why:
AMIX must still run queue processing, `cl_trapret`, `s_trap`, pending-signal
work, scheduling checks, register restoration, and the user CACR reload.

With the modified D-register save block still on the stack, use the same
completion shape as `fpsp_done`:

1. push the current USP as the pseudo-register;
2. set `u.u_ar0` to that pseudo-register entry;
3. pop/reload USP so SP again points at the saved D0 block;
4. jump to `ureturn`.

This completion belongs in the base ISP object so `FPSP=0` builds retain
vector-61 support. It may share a future generic user-emulation completion
helper with FPSP, but factoring that helper is not part of this unit.

### Failure return

Every decline path:

1. removes local scratch and argument storage;
2. restores D0-D7/A0-A6 exactly;
3. leaves the raw eight-byte frame unchanged;
4. jumps to `nullvect`.

`nullvect` then re-saves the registers and preserves today's user SIGKILL or
kernel-trap behavior. Do not call `u_trap` directly and do not manufacture a
vector number in C.

### Counters

Use the existing `wb_dfc_*` / `x60_*` data-symbol convention. Recommended
symbols:

| Symbol | Increment / value |
|---|---|
| `isp61_magic = 0x49363121` | ASCII `I61!`, checked before counters |
| `isp61_entry_n` | every `cputype == 60` slot-61 entry |
| `isp61_ok_n` | fully committed emulation |
| `isp61_mulu_n` | successful unsigned emulation |
| `isp61_muls_n` | successful signed emulation |
| `isp61_unsupported_n` | fetched but out-of-scope encoding |
| `isp61_ifetch_fail_n` | eight-byte `copyin` failed |
| `isp61_nonuser_n` | supervisor-origin entry |
| `isp61_badframe_n` | slot entry without exact `0x00f4` frame word |
| `isp61_trace_decline_n` | trace mode deliberately declined |
| `isp61_last_pc` | last validated frame's instruction PC |
| `isp61_last_insn` | last successfully fetched opword/ext as one longword |

`entry_n` is incremented before frame classification. `last_pc` is written
only after the exact frame check. `last_insn` is written only after a
successful `copyin`. Success counters move only after D-register, SR, and PC
commit.

### Concrete relink sequence

1. Assemble `prototypes/isp61_060.s` with the existing m68k toolchain. Its
   code uses no 060-only opcode, so the current `-m68040` assembly mode is
   sufficient.
2. Add `build/isp61_060.o` to the base `m68k-cbm-sysv4-ld -r` object list near
   `cputype060.o` and `lmul060.o`. Do not weaken `nullvect` and do not override
   an existing function symbol.
3. Add `prototypes/patch_isp_vec61.py`. Derive the field from the `M68Kvec`
   symbol, find its unique `.rela.text` record, require relocation type
   `R_68K_32`, and assert the old target is exactly `nullvect`. Be idempotent
   when the target is already `isp61_vec`.
4. Run that patch after the existing optional FPSP `if ... fi` block, before
   relocation validation and build-id stamping. This makes both `FPSP=1` and
   `FPSP=0` images use the same ISP unit, and ensures an FPSP `ld -r` cannot
   supersede the retarget.
5. Assert after patching:
   - vector 11 and 48/51-55 have their expected FPSP targets when FPSP is on;
   - vectors 49, 50, and 60 remain `nullvect`;
   - vector 61 targets `isp61_vec`;
   - all ISP symbols are defined and no `isp61_*` symbol remains undefined.

For the pinned image the old relocation field is `.text:0x146c`, but the
script must not hard-code that number. `M68Kvec` and `.rela.text` are the
stable provenance.

## Q6: pre-registered verification

### Positive microtest

Build the test with the cross toolchain and encode each instruction as raw
words so assembler spelling cannot change the requested form:

```asm
        .word   0x4c3c, EXTENSION
        .long   IMMEDIATE
```

Before each instruction, load the multiplicand into `Dl` and set the low CCR
to exactly `0x10` (X set, N/Z/V/C clear). Immediately after it, copy CCR to a
spare register before any compare or address arithmetic. Store `Dh`, `Dl`, and
CCR to a result table and verify them only after all samples have run.

The five samples cover every measured `(Dl,Dh)` pair and both operations:

| Case | Ext | Operation / inputs | Expected `Dh:Dl` | Expected low CCR with X preset |
|---|---:|---|---|---:|
| U1 | `0x1400` | `MULU`, `Dl=d1`, `Dh=d0`, `0xffffffff * 2` | `00000001:fffffffe` | `0x10` |
| U2 | `0x0401` | `MULU`, `Dl=d0`, `Dh=d1`, `0xffffffff * 0xffffffff` | `fffffffe:00000001` | `0x18` |
| UZ | `0x2400` | `MULU`, `Dl=d2`, `Dh=d0`, `0x12345678 * 0` | `00000000:00000000` | `0x14` |
| S1 | `0x2c01` | `MULS`, `Dl=d2`, `Dh=d1`, `-3 * 7` | `ffffffff:ffffffeb` | `0x18` |
| S2 | `0x1c02` | `MULS`, `Dl=d1`, `Dh=d2`, `0x80000000 * -1` | `00000000:80000000` | `0x10` |

Each extension satisfies:

```text
ext = (Dl << 12) | (signed ? 0x0800 : 0) | 0x0400 | Dh
```

Place a canary update immediately after every eight-byte instruction. It must
execute exactly once. A handler that restarts loops; a handler that advances
by four enters the immediate; only `old_pc + 8` reaches the canary correctly.

The test reports products, complete low CCR, canaries, and counter deltas. It
must not rely only on process exit status.

### CPU-specific readings

#### 68040

- all five product and CCR rows pass using hardware multiplication;
- all five canaries are one;
- every `isp61_*_n` delta is zero.

This is the strongest 040 gate: the vector is installed, but ordinary 040
execution never enters it.

#### Amiberry 68060

- both CPU configurations boot before hardware use;
- the arithmetic test must pass;
- handler counters may be zero if Amiberry executes the instruction rather
  than modeling the real 060 trap, or may match hardware if it traps.

Do not use Amiberry counter behavior as architectural acceptance evidence.

#### Real 68060

For one clean five-sample run, counter deltas must be:

```text
isp61_entry_n        +5
isp61_ok_n           +5
isp61_mulu_n         +3
isp61_muls_n         +2
all failure counters +0
```

Products, CCR values, and canaries must all match the table. Read the magic
word before interpreting addresses, and derive data addresses from the final
image's `.text` size plus symbol offsets.

### Required negative test on real 060

Run an isolated child containing a valid 64-bit register-source multiply,
for example opword `0x4c03` with a valid 64-bit extension. This is a genuine
vector-61 instruction but outside the immediate-only unit.

Expected result:

- child follows the existing vector-61 SIGKILL path;
- `isp61_entry_n` increases by one;
- `isp61_unsupported_n` increases by one;
- `isp61_ok_n` does not move;
- `isp61_last_pc` names the negative-test site;
- the raw frame was not advanced or altered before fallback.

Do not expect this child to die on 040; the 040 implements that instruction.

### Additional boundary test

For fetch-path closure, place one accepted instruction with its opword at
`page+0xffc`, so opword/extension are in one page and the immediate is in the
next. Assert the runtime address before using the result. This test validates
the eight-byte `copyin` decision and catches any later replacement with raw
word loads. It is a boundary extension to the five-case unit, not a reason to
expand the supported instruction set.

### End-to-end follow-up

Only after the microtest passes on real 060:

1. rerun the installed gcc `cpp` invocation that faulted at `0x80006ed6`;
2. rerun `cc1` on the saved preprocessed input that faulted at `0x80021530`;
3. scan the final kernel and ISP object to confirm the handler introduced no
   unimplemented 64-bit multiply/divide instruction itself;
4. run the normal dual-CPU regression battery.

"gcc works" is useful integration evidence, but it cannot replace the CCR,
PC, unsupported-form, and 040-zero-counter checks above.

## Acceptance and non-goals

This unit is accepted only when:

- current-image relocation and frame assertions hold;
- both emulator CPU configurations boot;
- positive tests pass on 040 and real 060;
- the real-060 counter deltas match exactly;
- the unsupported real-060 child fails loudly through the old path;
- no fetch, frame, supervisor, trace, or unsupported counter moves during the
  positive run;
- gcc advances past both previously measured vector-61 PCs.

Explicit non-goals:

- memory and data-register source modes;
- 64-bit divide, MOVEP, CMP2, CHK2, CAS, or CAS2;
- trace-frame synthesis;
- access-error-frame synthesis after instruction-fetch failure;
- supervisor-mode emulation;
- replacement of Motorola's full ISP for general 68060 compatibility.

These exclusions are safe because they fail through a counted unchanged
fallback. They must be revisited if a new installed binary or runtime capture
shows a vector-61 form outside the measured 103-site set.

## Sources

- NXP/Motorola, `M68060 User's Manual`, sections 8.2.4, 8.4.1, and C.2.2:
  <https://www.nxp.com/docs/en/data-sheet/MC68060UM.pdf>
- NXP/Motorola, `M68000 Family Programmer's Reference Manual`, `MULS` and
  `MULU` long forms:
  <https://www.nxp.com/docs/en/reference-manual/M68000PRM.pdf>
- local Motorola 68060SP source archive:
  `netbsd/syssrc.tgz`, members `usr/src/sys/arch/m68k/060sp/dist/isp.doc`,
  `dist/isp.s`, `netbsd060sp.S`, and `inetbsd.S`;
- current AMIX source provenance: `amix-040-060-port/amix-src/sys/amiga/ml/ttrap.s`
  and `vec.s`;
- current relink provenance: `amix-040-060-port/relink-040.sh`,
  `prototypes/fpsp_glue040.s`, `patch_fpsp_vec11.py`, and
  `patch_fpsp_vectors.py`;
- runtime/measured scope: `amix-040-060-port/060-F0-MEASUREMENT-260805.md`,
  `ISP-VECTOR61-TASK.md`, and `test-tools/scan060.py`.
