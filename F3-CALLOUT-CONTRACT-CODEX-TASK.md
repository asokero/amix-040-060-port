# Task — the 68060 FPSP call-out contract: how must an OS re-enter, and exit, the package?

**For Codex. Static analysis of Motorola's 060SP and NetBSD's adaptation; no hardware, no
emulator, no kernel code.** Written 2026-08-07 after M2a was wired, run, and panicked. Every
number below was measured. The question is a contract question, and the sources are on disk.

## The situation in one paragraph

The 68060 has no FP support package in this kernel, so any FP instruction it does not retire in
hardware becomes SIGSYS. F3 is fixing that with Motorola's own M68060 FPSP. The package is built
and correctly wired — vector 11 now reaches it — but the **AMIX side of the call-out table is
wrong**, and the first trapping instruction takes the machine down. The wrong part is small and
specific: what an OS must do in the `_060_real_*` exits, and what state they are reached in.

## What is already established — do not re-derive

**E1. The package builds and its entry table is verified by decode, not by document.**
`build-fpsp060.sh` produces `build/fpsp060_pkg.o` = `[128-byte call-out table][fpsp.S image][AMIX
call-outs]` as one assembly unit (the SysV4 assembler has no `.incbin`, and the table entries are
symbol differences, which are only link-time constants inside one unit). Asserted every build:
`fpsp060_top` at 0, `fpsp060_image` at 0x80, all 32 call-out slots inside the object, and

```text
TOP+128+0x30 -> bra.l image+0x1b8c   _060_fpsp_fline
TOP+128+0x38 -> bra.l image+0x00668  _060_fpsp_unsupp
TOP+128+0x40 -> bra.l image+0x0106e  _060_fpsp_effadd
```

**E2. Vector 11 reaches the package.** `fpsp_vec11` gained a `cputype == 60` branch. Before it
existed, M0's probe measured `kvp_vec[11]` moving **0 → 4** across one `fp060probe` run (four
unimplemented FP instructions: `fsin`, `fetox`, `flogn`, `fmovecr`). After it exists, the machine
panics instead — with the PC inside the package.

**E3. The panic, emulated 68060, kernel `68060-260807-04`:**

```text
PANIC: KERNEL FAULT psw=0x2004, pc=0x80E6C6E, fmt=0x2, vector=0x6 (CHK, CHK2)
proc = 4022EC00 (pid 213, fp060probe)
PC = fpsp060_image + 0x1fb6
```

Disassembling the package at that offset gives **data, not code** — `chkl %fp@+,%d5` then
`.short 0x4b4c`, `.short 0x4f4c`, nonsense addressing modes. So control flow left the rails into a
constant table; the CHK is what executing data happened to hit.

**E4. The 040 path is unaffected.** The emulated 040 boots clean and reaches login on the same
image, so this is confined to the `cputype == 60` branch.

**E5. What M2a's stubs do, i.e. the suspect.** Every call-out is a counted decline:

* the eleven memory accessors return `d1 != 0` (failure), deliberately — a stub returning zeroes
  would let the package emulate an instruction from garbage and answer wrongly in silence;
* the twelve `_060_real_*` exits and the reserved slots end in **`jmp nullvect`**;
* `_060_fpsp_done` is a bare `rte`, copying Motorola's `fskeletn.s`.

**E6. Why `jmp nullvect` is suspected.** `nullvect` is the kernel's shared exception entry, entered
by the *CPU* with a raw exception frame at `(sp)`: it immediately saves 60 bytes and dispatches on
`sp@(60)` (`btst #5,%sp@(60)`, verified by disassembly at 0x11b4). When a call-out runs, the stack
holds whatever the package left, not a fresh exception frame — so `nullvect` would dispatch on
garbage. And because the memory stubs fail closed, the package is driven into `_060_real_access` on
the very first trapping instruction, which makes this reachable immediately.

**E7. The contract we already read out of NetBSD**, since `fpsp.doc` does not document it:

```text
_060_imem_read_long / _060_dmem_read_long
  INPUTS   a0 = user address;  a6@(0x4) bit 5:  1 = supervisor, 0 = user
  OUTPUTS  d0 = data;  d1 = 0 success, non-zero failure
```

## The questions

**Q1 — in what state is each `_060_real_*` reached?** Motorola's `fskeletn.s` shows
`_060_real_ovfl` doing `fsave -(%sp) / mov.w &0x6000,0x2(%sp) / frestore (%sp)+ / rte`, which
implies the **original exception frame is back on the stack and the call-out is expected to `rte`**.
If that holds for all of them, E6 is only half right and the defect is narrower than assumed.
Please state, per call-out, what is on the stack and what the OS is permitted to do: `rte`,
transfer to a signal path, or neither.

**Q2 — `_060_real_access` specifically.** It is the one reached when a memory call-out reports
failure, and it is what M2a hits first. What must it deliver — an access-error exception to the
faulting user process, i.e. a synthesized frame? What does NetBSD's `_060_real_access` in
`netbsd060sp.S` actually do, and what does the package guarantee about the stack at that point?

**Q3 — how should an SVR4-style kernel route these to a signal?** AMIX's path is
`nullvect → utraps/ktraps → u_trap`, and `u_trap` selects the signal from an out-parameter
(`usrxmemflt`'s arg2), which is how F4's siginfo translation works. Is the correct shape
(a) rebuild a raw exception frame and enter `nullvect`, (b) call the trap machinery directly, or
(c) return into the package and let it finish? A recommendation with the reason, please.

**Q4 — does the entry path owe the package any setup we are not doing?** Two candidates, both
untested: the 040 branch of `fpsp_vec11` sets CACR from `sup_cacr` before entering its package and
our 060 branch does not; and the `a6@(0x4)` convention in E7 implies an `a6` frame — is that built
by the package itself, or expected from the caller?

**Q5 — full `fpsp.sa` (53 KiB) or `pfpsp.sa` (27 KiB)?** Their entry tables are byte-identical, so
inspection cannot separate them. Which modules differ, and does `pfpsp` still emulate `fmovecr` and
the transcendentals? We intend to settle this by running `fp060probe` against both, but a reading
of the module lists would tell us what to expect.

## What is NOT being asked

* No kernel code and no `.s` file. The ISP vector-61 unit, ISSUE-41's fix and ISSUE-42's contract
  all came from specs of exactly this shape.
* No hardware. The accepted baseline is `68060-260806-06`; the tree's default build now has
  `FPSP060=0` so nothing knowingly-panicking can reach the machine.
* Do not redesign the packaging. E1 is measured and settled.

## Artifacts

```text
kernelsupport/060-F3-FPSP-PLAN-260807.md     the plan, with M0/M1/M2a results inline
kernelsupport/060-FPU-STATE-260807.md        why F3 exists: the measured SIGSYS mechanism
kernelsupport/build-fpsp060.sh               packaging + the entry-table assertions
kernelsupport/prototypes/fpsp060_head.s      the 128-byte call-out table
kernelsupport/prototypes/fpsp060_glue.s      the AMIX call-outs -- the suspect
kernelsupport/prototypes/fpsp_glue040.s      fpsp_vec11, both CPU branches
kernelsupport/prototypes/kvecprobe040.s      M0: the vector probe that measured vector 11
netbsd/syssrc.tgz  usr/src/sys/arch/m68k/060sp/
    dist/fpsp.doc        entry points, call-out slots; no register contract
    dist/fskeletn.s      Motorola's example call-outs      <- Q1
    fnetbsd.S            NetBSD's FP adaptation            <- Q1, Q3
    netbsd060sp.S        NetBSD's memory + access call-outs <- Q2, and the source of E7
vanilla stand/unix       nullvect 0x11b4, utraps 0x11ea, ureturn 0x11f8, u_trap 0x5a586
```
