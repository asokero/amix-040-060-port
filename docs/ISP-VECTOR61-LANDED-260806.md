# F2 landed — vector 61 immediate-multiply unit, emulator-accepted on both CPUs

**2026-08-06.** Implements `amix-kernel-analysis/vm-map/ISP-VECTOR61-UNIT-SPEC.md` (Codex).
Image `68040-260806-02`, textsize `0xe4a64`, `check_relink_relocs.py` clean.
Hardware run still pending.

## What it does

`src/isp61_060.s` emulates exactly one instruction form on the 68060:

```text
MULU.L #imm32,Dh:Dl        opword 0x4c3c, extension bit10 = 1
MULS.L #imm32,Dh:Dl
```

That is not a guess about what is needed — it is the measured scope. F0's encoding-based scan
of the installed guest binaries found 103 vector-61 instructions, **all of them this form**
(68 unsigned, 35 signed), with `libc.so.1`, `ld.so.1`, `as` and `ld` completely clean. So one
addressing mode revives the whole installed compiler. Everything else — register and memory
sources, 64-bit divide, CMP2/CHK2/CAS2, supervisor origin, trace mode, a failed instruction
fetch — takes a **counted, state-preserving** fallback to the existing `nullvect` SIGKILL path.
Nothing is partly decoded and nothing is silently approximated.

Wiring: `patch_isp_vec61.py` retargets the `M68Kvec[61]` relocation from `nullvect` to
`isp61_vec`, deriving the field from the `M68Kvec` symbol. It runs **after** the optional FPSP
block, so an FPSP `ld -r` cannot supersede it and `FPSP=0`/`FPSP=1` images behave identically.
No FPSP script reads slot 61 (they own 11, and 48/51–55). The script also asserts vector **60**
is still `nullvect` before touching 61 — a cheap independent check that we are looking at the
vector table and not merely at the right offset.

## Acceptance, both emulator CPU configurations

`test-tools/isp61test.c` + `isp61test_asm.s`: five raw-encoded multiplies, each preceded by
`CCR = 0x10` (X set) and followed immediately by a canary increment.

| case | ext | operation | Dh:Dl | CCR |
|---|---:|---|---|---:|
| U1 | `0x1400` | `MULU`, `0xffffffff * 2` | `00000001:fffffffe` | `0x10` |
| U2 | `0x0401` | `MULU`, `0xffffffff * 0xffffffff` | `fffffffe:00000001` | `0x18` |
| UZ | `0x2400` | `MULU`, `0x12345678 * 0` | `00000000:00000000` | `0x14` |
| S1 | `0x2c01` | `MULS`, `-3 * 7` | `ffffffff:ffffffeb` | `0x18` |
| S2 | `0x1c02` | `MULS`, `0x80000000 * -1` | `00000000:80000000` | `0x10` |

**68040 (emulated): 5/5 PASS by hardware execution, every `isp61_*` counter ZERO.** That is the
strongest available check that the `cputype` gate holds — the vector is installed, and ordinary
040 execution never enters it. It also makes the 040 run the *reference*: those CCR values come
from real 68040 multiply hardware, and the 060 handler has to reproduce them bit for bit.

**68060 (emulated): 5/5 PASS, and the counters are exactly the pre-registered numbers:**

```text
isp61_entry_n  5      isp61_unsupported_n   0      isp61_last_pc   0x800004DC  (= S2's site)
isp61_ok_n     5      isp61_ifetch_fail_n   0      isp61_last_insn 0x4C3C1C02  (= S2's opword:ext)
isp61_mulu_n   3      isp61_nonuser_n       0
isp61_muls_n   2      isp61_badframe_n      0
                      isp61_trace_decline_n 0
```

Every canary read exactly 1, which is what rules out both a retry loop (canary > 1) and a
wrong PC advance (a `+4` would have executed the immediate as opcodes).

## The bug the test caught, and why it matters

The first 060 run reported **five clean successes in the counters while two of five results
were wrong** (U2 and S2). That is precisely the failure mode counters cannot see, and it was
mine, not the emulator's:

```
	movew	%a5@(2),%d1		| extension word
	...
	andiw	&7,%d2			| Dl
	lsll	&2,%d2
	lea	%a6@(0,%d2:l),%a4	| &saved Dl  <-- LONG index
```

`movew` writes only the low half of `d1`, so its **upper half was whatever `copyin` left
there**. `andiw` masks only the low word, but `lsll` and the `%d2:l` index use all 32 bits — so
the saved-register slot address depended on stale bits. Three cases happened to land correctly
and two did not, which is exactly the shape of a latent register-hygiene bug. Fixed by
zero-extending the extension word (`moveq &0,%d1` before `movew`) and using long masks.

Two lessons worth keeping:

* **`isp61_ok_n` means "the handler believed it succeeded", not "the answer was right."** Only
  the pre-registered product and CCR table separates those. Codex's insistence on exact values
  rather than "the counters moved" is what caught this.
* **S2 is the load-bearing case.** `0x80000000 * -1 = 0x00000000:0x80000000` must leave N
  CLEAR, because N comes from bit 63, not bit 31. A handler taking N from the low longword
  passes the other four.

## Implementation notes worth remembering

* **Shift immediates on the 68k are 1..8**, so a 12-bit right shift is not encodable — the Dl
  field is extracted with `rolw &4` plus a mask.
* **gcc 2.7.2.3's inline assembler mangles mnemonics** (`movel` → `movl`, `moveq` → `mov`) as
  soon as the asm block has operands, and then fails to assemble. The test's raw encodings
  therefore live in a standalone `.s` file, which is assembled verbatim.
* The success path returns through `ureturn` in the `fpsp_done` shape (push USP, set
  `u.u_ar0`, reload USP, jump), never a bare `rte` — otherwise STREAMS qrun, `cl_trapret`,
  signal delivery and the user CACR reload would all be skipped.

## Not yet established

* **Hardware.** Amiberry may execute what real silicon traps, so its 060 is a regression gate
  only (campaign rule 4). What the emulator *did* show is that the handler is entered, decodes,
  computes and resumes correctly — the architectural question of whether a real 68060 delivers
  this frame the same way is the hardware run's job.
* **The negative test** from the spec (a valid register-source 64-bit multiply, which must
  increment `isp61_unsupported_n` and die on the old path) is not written yet. It is real-060
  only: the 040 implements that instruction.
* **The page-crossing fetch case** (opword at `page+0xffc` so the immediate lands in the next
  page) is likewise unwritten. It is what justifies the single 8-byte `copyin`.
* **End-to-end gcc** — rerunning the `cpp` and `cc1` invocations that faulted at `0x80006ED6`
  and `0x80021530`. That is the payoff, but it cannot replace the checks above.

## Artifacts

```text
src/isp61_060.s          the handler
src/patch_isp_vec61.py   M68Kvec[61] -> isp61_vec, after the FPSP block
relink-040.sh                   assembles, links and patches
test-tools/isp61test.c          the five-case acceptance test
test-tools/isp61test_asm.s      its raw encodings
kernel  build/unix-040  68040-260806-02  textsize 0xe4a64
```
