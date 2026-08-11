# Task — are the five unmeasured IEEE exception classes wired correctly on the 68060?

**For Codex. Static analysis of Motorola's 060SP, NetBSD's adaptation and this port's own glue;
no hardware, no emulator, no kernel changes.** Written 2026-08-11, the day M4 landed.

The deliverable is a verdict per class with its reasoning, not a patch.

## The situation in one paragraph

F3 M4 wired the 68060's IEEE arithmetic vectors into Motorola's FPSP. The vector → entry map is
a permutation and was verified statically nine times out of nine. On hardware exactly **one** of
the six classes has actually been exercised: SNAN. The other five — OPERR, OVFL, UNFL, DZ, INEX —
rest on the static map alone, because Motorola's own suite structurally cannot exercise them on
this OS (see E4). The question is whether static analysis can raise or lower confidence in those
five before someone writes the instrument that measures them.

## What is already established — do not re-derive

**E1. The map, verified from the built object's relocations, 9 of 9.**

```text
entry +0x00 snan  <- vector 54      entry +0x18 unfl  <- vector 51
entry +0x08 operr <- vector 52      entry +0x20 dz    <- vector 50
entry +0x10 ovfl  <- vector 53      entry +0x28 inex  <- vector 49
entry +0x30 fline <- vector 11      +0x38 unsupp <- 55   +0x40 effadd <- 60
```

Corroborated by the call-out table's own order in `prototypes/fpsp060_head.s`
(`bsun, snan, operr, ovfl, unfl, dz, inex`) — the same sequence minus bsun — and by decoding all
nine entry slots from the linked `.text` (each a real `bra.l` to a distinct target, none a stub).

**E2. Vector 48 (BSUN) is deliberately NOT wired on the 68060.** The package exports a call-out
(`_060_real_bsun`, implemented as `Lco_bsun`) but no entry. The 68040 is the mirror image: it
hooks 48 and leaves 49/50 alone, because *its* package exports no dz/inex entry. Same rule,
different vectors.

**E3. SNAN is measured end to end on real silicon.** `ftest060 enabled`, kernel
`68060-260810-03`: `f60_vec54_n` 0 → 1 (the vector reached the package) and `f60_snan_n` 0 → 1
(it left through `_060_real_snan` — the same class), `f60_entry_n`/`real_n`/`arith_n` all 1,
`f60_done_n` 0. Then SIGFPE.

**E4. That SIGFPE is correct, and it is also why the other five cannot be measured this way.**
Motorola's `test.doc`, quoted in `test-tools/ftest060.c` since M2b:

> "the test expects `_real_XXXX()` to do nothing except clear the exception and rte. If a
> system's `_real_XXXX()` handler creates an alternate result, the test will print 'failed' but
> this is acceptable."

AMIX delivers a signal instead of returning, so the group can never pass here. Worse for
measurement: all six sub-tests share one child, so the first SIGFPE kills it and sub-tests 2–6
never execute. `ftest060 enabled` is an excitation source, not a pass/fail instrument.

**E5. The two non-maskable classes ARE measured, and they behave differently.** Across one
`ftest060 main` run on hardware: `f60_vec51_n` +1 and `f60_vec53_n` +1, while `f60_unfl_n` and
`f60_ovfl_n` stayed 0 and `f60_done_n` rose by the full entry count. The package **repaired**
the non-maskable overflow and underflow and returned through `_060_fpsp_done` rather than
signalling. So vectors 51 and 53 are proven to reach the right entry; what is unproven for them
is the *enabled* path, where the package should signal instead.

**E6. Our exit implementation is one shared routine.** `prototypes/fpsp060_glue.s`, `Lco_snan`
… `Lco_inex` each set `f60_last_co`, bump their own counter, and fall into `Lco_fparith`:

```
	addql	#1,f60_real_n
	addql	#1,f60_arith_n
	fsave	%sp@-			| 12-byte 68060 FP state frame
	movew	#0x6000,%sp@(0x2)	| clear the pending exception in its status word
	frestore %sp@+
	jmp	nullvect		| vector 48-54 -> u_trap -> stock SIGFPE
```

The three-instruction prelude is Motorola's `fskeletn.s` and NetBSD's `fnetbsd.S`, identically.
`Lco_bsun` differs deliberately: it clears the FPSR NaN condition and DISCARDS the saved state
rather than restoring it.

## The questions

**Q1. Is one shared exit correct for all six classes?** Motorola's skeleton has six separate
`_060_real_*` stubs. Ours funnels them into one body after a per-class counter. Does any class
require something the shared body does not do — a different frame size, a different status-word
value than `0x6000`, restoring versus discarding the state, or a different stack adjustment?
Name any class where the answer is "no, it needs X", and say what X is.

**Q2. Is `0x6000` right for every class?** It came from `fskeletn.s` as a single pattern. Check
it against the 68060 FP state frame layout and against what NetBSD does per class.

**Q3. INEX is the one that worries us most.** Inexact is normally non-fatal: a program that
enables the inexact trap expects to keep running. Our path signals SIGFPE and, with no handler,
the process dies. Is that what a 68060 Unix should do — and specifically, does the 060SP expect
`_060_real_inex` to be re-enterable or to return? If our behaviour is defensible, say so; the
040 side has made the same choice and is hardware-accepted, which is evidence but not proof.

**Q4. Can any of the five be reached at all on this hardware?** DZ and INEX in particular: does
the 68060 raise them only when enabled in the FPCR, and is there any path in normal userland
that enables them? If a class is structurally unreachable, that is worth knowing before anyone
writes a test for it.

**Q5. What would the per-class instrument have to do?** We will write one in the shape of
`fp060probe` / `ftunimp0` / `isp61ea`: one child per class, each raising exactly one enabled
exception, counters read around each. Say for each of the five what instruction sequence and
FPCR setting raises it deterministically, and what the correct post-state is (FPSR, FPIAR, the
destination register) so the test can compare bit patterns rather than survival. **This is the
most directly useful part of the answer** — it is the difference between a test we can write
today and one we have to discover by experiment.

## What would count as an answer

Per class: reachable / not reachable, exit correct / exit needs X, and the excitation recipe for
Q5. File:line for anything asserted about the package or about NetBSD. Where the sources do not
settle it, name the measurement — this project runs things on real 68060 hardware routinely and
a precise experiment is a good deliverable.

## Sources on disk

```text
kernelsupport/prototypes/fpsp060_glue.s        our call-outs, the six Lco_* exits, the trampolines
kernelsupport/prototypes/fpsp060_head.s        the 128-byte call-out table and its order
kernelsupport/prototypes/fpsp_glue040.s        the 68040 equivalent -- hardware-accepted
kernelsupport/test-tools/f3-m4-verify-260811.txt   what M4 measured, and what it did not
kernelsupport/test-tools/f3-m3-verify-260810.txt   vectors 55 and 60
kernelsupport/REALHW-260807-11-ACCEPTANCE.md   M5; section 4c is the first sighting of this gap
kernelsupport/060-F3-FPSP-PLAN-260807.md       the campaign plan and the entry-point table
amix-kernel-analysis/vm-map/F3-FPSP060-CALLOUT-CONTRACT.md   your own earlier contract answer
Motorola 060SP sources + NetBSD's fnetbsd.S / fskeletn.S     as used by build-fpsp060.sh
```

## Out of scope

Writing the instrument, and any kernel change. The point of this task is to make the instrument
cheap to write correctly and to say, before it is written, which of the five we should expect
to fail.
