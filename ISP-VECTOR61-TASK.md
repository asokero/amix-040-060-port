# Task — vector 61 (unimplemented integer) support for the 68060

**For Codex. Static analysis and a unit spec; no hardware needed.**
Written 2026-08-05, after F0 measured the problem's actual size on real 68060 hardware.

## Why this is now worth specifying

ISSUE-34a is no longer a cross-compiled repro. On the real machine the guest's own gcc dies, and
the console names the mechanism:

```text
u_trap WARNING: SIGKILL sent to pid 263 (.../2.7.2.3/cpp -lang-c -undef -D__GNUC__=2 -)
  because of vector 0xF4, pc=0x80006ED6
u_trap WARNING: SIGKILL sent to pid 2046 (.../2.7.2.3/cc1 /tmp/mul64test.i -o /tmp/mul6)
  because of vector 0xF4, pc=0x80021530
```

`0xF4 / 4 = 61`. Both PCs disassemble, byte-exact, to a 64-bit `MULS.L`/`MULU.L`. Details and the
scanner in `060-F0-MEASUREMENT-260805.md` and `test-tools/scan060.py`.

## The measured scope — this is the part that makes the unit small

Encoding-based scan (opcode `0x4C00`–`0x4C7F`, extension word bit 10 = 1) of the installed guest
binaries:

| binary | vector-61 instructions |
|---|---|
| `cpp` (gcc 2.7.2.3) | 2 |
| `cc1` (gcc 2.7.2.3) | 101 |
| `libc.so.1`, `ld.so.1`, `/usr/ccs/bin/as`, `/usr/ccs/bin/ld` | **0** |

And of all 103:

* **Every single one is the immediate form**: `mulsl #<imm32>,%dX,%dY`. There is **not one**
  memory or data-register source operand. All of them are gcc's magic-multiply for division by a
  constant.
* 68 are `MULU.L`, 35 are `MULS.L`.
* Only five distinct register pairs occur, all within d0–d2: `%d1,%d0` (36), `%d2,%d1` (31),
  `%d0,%d1` (24), `%d1,%d2` (11), `%d2,%d0` (1).
* **Zero 64-bit divides. Zero CMP2/CHK2/CAS2.**

So a targeted emulator can be correct for the entire installed compiler while decoding exactly one
addressing mode. Motorola's full 060SP integer package remains the general answer; the question
this task must settle is whether the targeted route is sound and what it must cover.

## What already exists

* `prototypes/lmul060.s` — a portable 32×32→64 multiply, **already validated** against a `muls.l`
  model over 202 500 cases, currently used for the kernel's own `lmul`. The arithmetic is done;
  the missing work is trap-frame handling, decode and write-back.
* `prototypes/cputype060.s` — `cputype` (40/60, loader-poked) and `pcr_boot`.
* FPSP shims already occupy vectors 11, 48 and 51–55; 49, 50, 60 and **61** are still `nullvect`.
  `patch_fpsp_vec*.py` assert their target is `nullvect`, so anything landing on 61 must not
  disturb those assertions.
* `prototypes/wb040.s` now carries `x60_*` counters in the `wb_dfc_*` shape — the same idiom is
  available for an ISP hit counter.

## Questions to answer, in order

1. **The frame.** What exception frame does the 68060 push for vector 61, and where in it are the
   faulting PC and the instruction? Confirm from the 68060 UM, and state whether the handler must
   read the opword from user space (and therefore honour SFC/DFC and the possibility of a page
   fault on that read) or whether the frame carries it.
2. **Restart vs resume.** Does the 060 expect the handler to emulate and then continue *after* the
   instruction (adjusting the stacked PC), or to restart it? State exactly which field is written
   and with what value, including the immediate's length (opword + extension word + 4-byte
   immediate = 8 bytes for the measured form).
3. **Decode.** Given the measured scope, specify the minimum decode: opcode mask, extension-word
   fields (Dh in bits 2–0, Dl in bits 15–12, signed in bit 11, size in bit 10), and what the
   handler must do when it meets a form outside that scope — the answer must be *fail loudly*
   (counter + the existing SIGKILL path), never silently wrong arithmetic.
4. **Write-back and flags.** Which registers are written (Dh:Dl), and what does the 060 architecture
   require of CCR after MULU.L/MULS.L 64-bit? Confirm whether the stacked SR must be updated and,
   if so, which bits — a wrong Z or N here is a silent miscompare in user code, the worst failure
   mode available.
5. **Placement.** Where does the handler attach (`M68Kvec[61]`), how is it kept `cputype`-gated so
   the 040 path is untouched, and does it collide with `patch_fpsp_vec*.py`'s `nullvect`
   assertions? Propose the concrete relink wiring.
6. **Verification without gcc.** The obvious test is "gcc works again", but that is a big
   end-to-end claim. Specify a small one first: a cross-compiled binary containing exactly the
   measured form, with known operands and expected products, run on both CPUs — and say what
   counters must move.

## Constraints

* `cputype`-gated: the 040 instruction stream must be unchanged. Both emulator CPU configs boot
  before any hardware boot.
* Amiberry is not evidence for unimplemented-instruction trap behaviour (campaign rule 4). Its 060
  may execute what real silicon traps, so the emulator is a regression gate only.
* Do not propose changes to `hat_*`, the fault resolvers, or anything on the memory path. This unit
  touches one vector.
* Deliverable: a spec of the same shape as `060-COUNTERS-UNIT-SPEC-260805.md` — decisions,
  constraints, pre-registered readings — not code.

## Sources

* `060-F0-MEASUREMENT-260805.md` (hardware measurement, scanner methodology, the objdump
  comma-vs-colon trap that made an earlier scan report "clean")
* `KNOWN-ISSUES.md` §ISSUE-34 (corrected 2026-08-05)
* `prototypes/lmul060.s`, `prototypes/cputype060.s`, `prototypes/wb040.s`
* `68060-prestudy.md` §3.4, `amix-kernel-analysis/vm-map/M68060-SUPPORT-LANDSCAPE.md`
* `test-tools/scan060.py`, `test-tools/mul64test.c`
