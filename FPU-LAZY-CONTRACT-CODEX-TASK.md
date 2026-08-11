# Task — what is AMIX's lazy-FP contract, and who owns bit 0 of the u-area FP flags?

**For Codex. Static analysis of the SVR4 3b2 sources, the AMIX tree and the pinned kernel
binary; no hardware, no emulator, no kernel changes.** Written 2026-08-11, immediately after a
change to this path was tried on hardware and made things worse.

The deliverable is the contract, with file:line, and a recommendation. Not a patch.

## Why this is being asked, in one paragraph

F3 M4 wired the 68060's IEEE exception vectors into Motorola's FPSP. Five of the six classes
are now bit-exact on real silicon. The sixth, divide-by-zero, comes back from a returning SIGFPE
handler with the FPU **reset** — and the cause is known exactly: stock `fpu_save` treats a null
`fsave` frame as "this process has no live FP state", which is true on an 030 or an 040 and
false on a 68060 whose FPSP consumed the internal state before calling the OS. One attempt to
fix it was made, measured, and reverted the same hour; it failed because the flag it used was
read backwards. Hence this task: establish the contract before anyone writes assembly again.

## What is already established — do not re-derive

**E1. The two routines, disassembled from the pinned kernel.**

```
fpu_save    0x132:  moveal  fpu_ptr,%a0
            0x138:  btst    &0,%a0@(3)          <- THE FLAG
            0x13e:  bne     no_fpu1             <- set: skip saving ENTIRELY
            0x140:  fsave   %a0@(112)
            0x144:  tstb    %a0@(112)
            0x148:  beq     no_fpu1             <- null frame: do NOT save fp0-7 / ctrl regs
            0x14a:  fmovem.x %fp0-%fp7,%a0@(4)
            0x150:  fmovem.l %fpiar/%fpsr/%fpcr,%a0@(100)
no_fpu1     0x156:  rts

fpu_restore 0x158:  moveal  fpu_ptr,%a0
            0x15e:  tstb    %a0@(112)
            0x162:  beq     null_state
            0x164:  fmovem.x %a0@(4),%fp0-%fp7
            0x16a:  fmovem.l %a0@(100),%fpiar/%fpsr/%fpcr
            0x170:  frestore %a0@(112)
            0x174:  andi.l  #-2,%a0@            <- CLEARS the flag
            0x17a:  bra     no_fpu2
null_state  0x17c:  frestore %a0@(112)          <- null frame: RESETS the FPU
            0x180:  btst    &0,%a0@(3)          <- THE FLAG again
            0x186:  beq     no_fpu2             <- clear: restore nothing
            0x188:  fmovem.x %a0@(4),%fp0-%fp7
            0x18e:  fmovem.l %a0@(100),%fpiar/%fpsr/%fpcr
            0x194:  andi.l  #-2,%a0@            <- CLEARS the flag
no_fpu2     0x19a:  rts
```

**E2. `fpu_ptr` is static and points into the u-area.** It is a `.data` long at `.data+0x4fe0`
with a single relocation: **`u + 0x9c`**. It is *read* by `fpu_save` and `fpu_restore` and
written by nothing in the kernel — those two are its only references anywhere in the image.

So the FP context block is a structure at `u+0x9c` with, by offset:

```
    +0    a long whose BIT 0 is the flag in question
    +4    fp0-fp7          (8 x 12 = 96 bytes)
    +100  fpcr, fpsr, fpiar
    +112  the fsave frame  (12 bytes -- measured, see E5)
```

**E3. Neither routine ever SETS bit 0.** Both only clear it (`andi.l #-2`). Its owner is
somewhere else and writes it by name through the u-area, not through `fpu_ptr` — which is why a
relocation search for `fpu_ptr` does not find it. **Finding that owner is the core of this
task.**

**E4. Callers.** `fpu_save` and `fpu_restore` are called from `setuctxt` (0x4192e),
`restorecontext` (0x58ea4), `savecontext` (0x58f8a) and `coffcore` (0xb7ffa, 0xb920a).
`sendsig` sits at 0x59022, immediately after savecontext/restorecontext, and the signal path
goes through them.

**E5. Measured facts from hardware, kernel 68060-260810-03 and -04.**

* The 68060 `fsave` frame is **12 bytes**, null or not — sp recorded either side of the
  instruction, both cases. `Lco_bsun`'s own `addl #0xc,%sp` agrees independently.
* The frame's first word, per exception class, at the FPSP call-out:
  **OPERR 0x7fff, INEX 0x4000, DZ 0x0000.** DZ's is null because `_fpsp_dz` does
  `frestore FP_SRC(%a6)` before branching to the call-out (`fpsp.s:3810`).
* **The null-frame case is the COMMON case: 7100 occurrences during one boot**, counted in
  `fpu_save`. Most processes have no live FP state, so any "always save" answer is a permanent
  per-context-switch cost, not a rare one.

**E6. The attempt that failed, so nobody repeats it.** `fpu_save` was overridden so that on
`cputype == 60` a null frame still saved fp0-7 and the control registers and then **set** bit 0,
intending to make `null_state` restore them. It built clean, all five callers resolved to the
override, the encodings matched stock. On hardware it turned "5 of 6 bit-exact, DZ wrong" into
**all six wrong**. Reverted the same hour.

The reason it failed is the reason for this task: in `fpu_save` the flag being set means *skip
saving*, so it cannot mean "a restore is pending" — it must mean something closer to **"the
registers are not live; the pcb copy is authoritative"**. Setting it while the registers WERE
live asserted the opposite of the truth, 7100 times a boot.

## The questions

**Q1. Name the field.** What is the structure at `u+0x9c` in the SVR4 / 3b2 sources, and what
is the documented meaning of bit 0 of its first long? A name and a header line beat any amount
of inference from the disassembly.

**Q2. Who sets it?** The owner writes it somewhere this project has not found. Identify every
site that sets it and under what circumstances — process creation, `exec`, first FP use, an
FPU-disabled trap, context switch, signal delivery.

**Q3. State the lazy-FP contract.** Across `fpu_save`, `fpu_restore`, `savecontext`,
`restorecontext`, `setuctxt` and `coffcore`: what is the invariant at each entry and exit, and
what is the intended lifecycle of the FP state between them? Include what a *null* fsave frame
is intended to mean, and whether the design assumes the FPU is ever disabled — this port has
`_060_real_fpu_disabled` wired and `f60_fpudis_n` has never left 0, which suggests it is not.

**Q4. Given the 68060 FPSP breaks "null frame implies no live registers", what is the minimal
correct change?** Evaluate at least:

  a. save unconditionally on `cputype == 60` (costs 108 bytes of register traffic on every
     context switch — see E5's 7100/boot);
  b. have the FPSP glue leave a NON-null frame before jumping to `nullvect`, so the stock
     logic's premise becomes true again;
  c. change only the signal path rather than the context-switch path;
  d. something that follows from the real contract and is not on this list.

For whichever you recommend, say what invariant it preserves and what it costs.

**Q5. Is DZ actually the only affected case?** Five classes work because their frames are
non-null. Is there any other path — `fmovecr`, an unimplemented instruction completed by the
package, a `_060_fpsp_done` exit — that also leaves a null frame while fp0-7 are live? If so,
the same defect is reachable without an enabled exception at all, and that would raise the
priority considerably.

## Constraints any answer must respect

* **The 68040 path must stay byte-identical.** This is on the path every context switch and
  every signal takes, on both CPUs; the 040 is hardware-accepted and must not move.
* Changes are `cputype`-gated and counted, so the frequency is visible rather than argued.
* This port's rule: a fix is not accepted until a counter shows the new path ran.

## Sources on disk

```text
kernelsupport/build/unix-040                    the pinned kernel (fpu_save 0x132, fpu_restore 0x158)
kernelsupport/test-tools/f3-m4-enabled-hw-260811.txt   all three measurement rounds, incl. the failure
kernelsupport/prototypes/fpsp060_glue.s         our call-outs and the null-frame guard
amix-src/sys/                                   the AMIX machine-dependent tree
the SVR4 3b2 sources                            where the u-area fields still have names
build/fpsp060-work/.../dist/fpsp.s              _fpsp_dz at 3749-3813
```

## Out of scope

Writing the fix. The previous attempt is exactly what happens when this path is changed before
the contract is known, and it cost a hardware boot to find out.
