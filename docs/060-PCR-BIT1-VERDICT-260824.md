# PCR bit 1 is DFP, not EDEBUG — settled before any PCR code was written

The tree contradicted itself about the meaning of one bit in a register the kernel is about to
start writing, and the disagreement was load-bearing: one reading makes `bclr #1` the way to
turn the FPU on, the other makes it a debug knob that says nothing about floating point at all.

* `src/cputype060.s:26-30` documented **bit 1 = EDEBUG**, bit 0 = ESS.
* `docs/contracts/FPU-TIER1-ENABLE-SPEC.md:153` says *"PCR bit 1 also disables the 060 FPU"*,
  and `src/fpsp060_glue.s:389-391` already **clears bit 1 and calls it "the FPU-disable bit"**.

Nothing shipped depended on the answer yet — `cputype060.s` only *captures* the word into
`pcr_boot` — which is exactly why it had to be settled before something did.

## The verdict

**PCR bit 1 is `DFP`, Disable Floating-Point unit.** The MC68060 PCR is:

| field | meaning |
|---|---|
| bits 31-16 | processor ID — `0x0430` on the full 68060 |
| bits 15-8 | mask revision number |
| bit 6 | `EDEBUG` — internal debug state on the bus pins while the bus is idle |
| bits 7, 5-2 | reserved |
| bit 1 | **`DFP`** — set ⇒ the on-chip FPU is disabled and every floating-point instruction takes a line-F exception (vector 11) |
| bit 0 | `ESS` — enable superscalar dispatch |

`EDEBUG` is real; it is bit 6, not bit 1. The comment in `cputype060.s` had the right name
against the wrong bit, and has been corrected in place with the original text preserved.

## The evidence chain

Ordered by weight, and the first item alone is decisive.

1. **Motorola's own sample operating-system code, from the same 060SP release this port already
   links.** `fskeletn.s`, function `_060_real_fpu_disabled` (NetBSD 9.4
   `usr/src/sys/arch/m68k/060sp/dist/fskeletn.s:226-247`, read 2026-08-24). Its header says the
   sample *"enables the FPU"*, and the code it describes reads PCR, clears bit 1, and writes PCR
   back before setting the current PC and returning. Motorola's words and Motorola's bit, in one
   place. This is the same package `build-fpsp060.sh` builds as `fpsp060_pkg.o`, so the port has
   been consuming this file's contract all along.
2. **The MC68060 User's Manual**, PCR description: bit 1 `DFP` — when set, the on-chip FPU is
   disabled and any attempt to execute a floating-point instruction generates a line-F emulator
   exception; bit 0 `ESS` — must be set for normal operation, cleared only to help emulation or
   hardware debug; `EDEBUG` — cleared at reset, makes internal state visible on the bus pins.
   Consulted online (the manual is not on this machine), which is why Motorola's shipped source
   is quoted first: it is the copy we hold.
3. **NetBSD**, `usr/src/sys/arch/amiga/amiga/locore.s:901-909`: on the 68060 path it reads PCR,
   tests the high half against `0x430`, and on a match clears bit 1 with the comment *"and switch
   it on"* before writing PCR back. An independent OS, the same bit, the same meaning.
4. **UAE / Amiberry**, three sites, read 2026-08-24: `src/newcpu.cpp:3609-3617` sets
   `regs.pcr |= 2` to disable the FPU at reset and again whenever `fpu_model` is 0;
   `src/fpp.cpp:1072,1098` treats `regs.pcr & 2` as "no FPU" for every FP instruction; and
   `src/newcpu_common.cpp:172-178` masks a `movec` to PCR down to **`0x40 | 2 | 1`** and logs
   `68060 FPU state: disabled/enabled` when bit 1 changes. That writable mask is the manual's
   three writable bits — EDEBUG, DFP, ESS — and it is an independent corroboration of the whole
   layout, not just of bit 1.
5. **Our own Mercury measurement decodes cleanly, and only under this reading.**
   `pcr_boot = 0x04300601` (`docs/REALHW-F2-ACCEPTANCE-260806.md` §8, both boots):

   ```text
   0x0430  bits 31-16   processor ID -- the full 68060
   0x06    bits 15-8    mask revision 6
   0       bit 6        EDEBUG off
   0       bit 1        DFP clear  -> the FPU is enabled, which that machine proves by passing
                                     six IEEE exception classes bit-exact
   1       bit 0        ESS set    -> superscalar on, left there by SetPatch
   ```

   Every one of the 32 bits is accounted for. Under `bit 1 = EDEBUG` the word would say nothing
   about the FPU, and bits 9 and 10 would be two undocumented set bits rather than half of a
   revision number.

## Scoring the prediction

`docs/BLIZZARD.md` §4/§13-D6 predicted, before the evidence was gathered, that *"the SPEC and the
glue are right"* and that `cputype060.s`'s comment is wrong. **The prediction was right.**

Two honest corrections to how it was argued, because a prediction that lands for a shaky reason
is still a shaky reason:

* It offered two supports and tagged both `derived`. Only one of them decides. The Mercury word
  is **corroboration**: bit 1 clear is *consistent with* DFP=0 and is not *inconsistent with* an
  EDEBUG reading, so on its own it could not have settled anything.
* The decisive evidence — Motorola's own sample handler, sitting in the tarball this repository
  already builds from — was not among the supports offered. The cheapest experiment was cheaper
  than the plan thought, and it was already on this disk.

## What this does not establish

* That a 68LC060 reports its missing FPU in the ID field. Two implementations behave as if it
  does — NetBSD refuses the FPU path unless the high half is `0x430`, and UAE models an EC part
  as `0x0431` — but that is two implementations agreeing, not the manual, and it is **not** a
  substitute for the vector-11 probe. `FPU-TIER1-ENABLE-SPEC.md:238-240` pre-refutes exactly that
  shortcut, and this document does not reopen it.
* Anything about what a real 68LC060 does when PCR bit 1 is written. On the bench,
  Amiberry re-sets it; on silicon it is expected to read back set for a different reason. The
  probe decides, and the readback is only a diagnostic.
