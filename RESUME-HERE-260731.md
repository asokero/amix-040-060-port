# RESUME HERE — end of 2026-07-31: the port is accepted, and four instruments are calibrated

Read this file and nothing else to start. `RESUME-HERE-ISSUE38.md` and `RESUME-HERE-ISSUE22.md` are
closed records. Everything below is measured unless it says otherwise.

## 0. Where the port stands

The 68040 port is **copyback by default, silent, and accepted on hardware** — the whole battery
re-run on the image that actually ships, because every earlier claim had been measured on a kernel
that no longer existed.

```text
unix-040-260731-10   copyback, silent, no probes    battery 9/9 + burst 96/96
unix-040-260731-33   + three new units              units verified + burst 96/96
unix-040-rtg-260731-34  + both RTG drivers          exec/fpu/devmap PASS, wolf3d PASS,
                                                    VA2000 Xrtg PASS, Piccolo Xsvga PASS
```

Acceptance set with roles and `SHA256SUMS.txt`: NAS `amix/acceptance-260731/`, including the
write-through control built from the same base for a one-boot A/B, and the dbg image for diagnosis
only — never the subject of a verdict. Full record: `REALHW-ACCEPTANCE-260731.md`.

Performance, for the record: Dhrystone **30037/s** vs write-through 18292.7/s (+64 %), ~2.6× over
the no-data-cache baseline of 11538.

## 1. What landed today

| unit | what it fixes | verified by |
|---|---|---|
| `cb_icode040` (ISSUE-38) | the boot icode was invisible to the 040 ifetch under copyback | probe-less copyback boots; `cb_icode_push` = 1 |
| copyback default | `hat_cm_ram` ships `0x20` | flipped base is one build-id byte from the accepted image |
| `kdbg040` | base kernel is silent; 15 trace sites gated, 11 real warnings left alone | quiet boot = 1 354 bytes, dbg = 111 754 |
| `dbgpublish040` (DBG-TEXT-PUBLISH) | ptrace POKETEXT and `/proc` writes published from cache | `dbg_ptrace_*` 4/4, `dbg_procfs_*` 2/2, reads counted 0 |
| per-proc fault depth | global `Lkx_depth` was a false-EFAULT generator by design | `Lkx_badslot/noproc/underflow` all 0 across every workload |
| ISSUE-39 counter | `hat_sdtalloc` OOM warning was only ever visible on a console | counter 1 = the one warning photographed |
| `padtest040`, `z3660*`, A3640 config | tooling and driver work (see §4) | |

## 2. The four calibrated instruments

This is the part worth carrying forward: each counter now has a *known* meaning, measured one
variable at a time, so a future reading means something.

| counter | calibration |
|---|---|
| `hat_pfnmiss_n` | ~10 at boot, then **exactly +2 per `devmaptest` run** and zero from everything else — wolf3d, *both* X servers, compiles, two 16-burst suites (570 000+ page releases). The producer is installing a mapping over a leaf PTE that already names a different managed page, which only `devmaptest` deliberately constructs |
| `hat_sdtfail_n` | ~1 per 16-burst suite; 0 under X, wolf3d, or light load. Console and counter agreed exactly |
| `Lkx_maxactive` | **2** in every workload measured — idle, burst suite, wolf3d, Xrtg + clients, X11R5 + clients — against the retired gate's cap of 4 |
| `dbg_ptrace_*` / `dbg_procfs_*` | 0 everywhere except the tests that exercise those paths |

**Recompute counter addresses after every relink** (`kernel_base + textsize + .data offset`), and read
the `hat_cm_ram` anchor first: today it caught a stale-address read on the first line.

## 3. Open issues

* **ISSUE-39** (new): `hat_sdtalloc` runs out of contiguous memory during the burst suite, ~1 per
  run, harmless so far. Now counted. Cheap follow-up: sample `freemem`/`availrmem` across a run to
  characterise the regime the two intermittents live in.
* **ISSUE-10 / amixadm**: intermittent — the same image crashed once and booted clean next time, so
  single-boot bisects are invalid. Needs a *rate* per image, measured in the emulator
  (`emu-amixadm-test.sh`, ~4 min/cycle, `AMIX_EMU_CPU=040|a3640`). The ladder is built and on the NAS.
* **ISSUE-11** (wb040 WB1 alignment, latent), **ISSUE-16** (RFS 2 KiB, 72 sites), **ISSUE-20**
  (`hat_swapout` mine), **ISSUE-34b** (`cc1` SIGSYS on 060), **ISSUE-3/19/29/30**.
* **Residual from ISSUE-38**: `mprotect(..., PROT_EXEC)` as the general user-code publication
  boundary is specified by Codex (`USER-CODE-CACHE-ABI-SPEC.md`) and **not implemented**. Today's
  kernel publishes W→X only incidentally, and a same-protection RWX call cannot publish at all.
* **`dd.c` completion ordering**: their Z3660 patch (startio before iodone) is off by default because
  it panics here; whether the stock A3091 path has the same latent race is unanswered.

## 4. Side work, done and parked

* **A3640** (040 card with no RAM of its own): emulator half done. The port has **no hardcoded load
  address** — checked, then confirmed by booting at `0x07000000`. One real finding: a diagnostic
  gated on a *physical address range* is machine-specific by construction, and one such gate fired
  200× on that machine. Config `a3000ux-a3640.uae`, `emu-reset-boot.sh a3640`.
* **Z3660 driver kernel** for a friend's 040-emulation bench: `unix-040-z3660-260731-26` boots with
  both drivers linked and registered. Their sources' `phystopfn` is 2 KiB and would map the wrong
  physical page here; `z3660_modelb.py` converts a copy, and the build asserts the shift in the
  compiled object. Record: `Z3660-KERNEL-FEASIBILITY-260731.md`.
* **Tooling**: `emu-reset-boot.sh` now takes the kernel image as an argument (it destroyed a real dbg
  build twice when it was by filename); `real.py` takes `AMIX_CMD_TIMEOUT` and sends `^C` on timeout.

## 5. Proposed next session

**First, and small: the `mprotect` publication ABI.** It is the last piece of the story ISSUE-38
opened, Codex has specified it, it is one wrapper plus a flag, and — unlike anything 060 — **its
acceptance can be taken on this hardware**: write code into a page, `mprotect(..., PROT_EXEC)`,
execute it, in a loop, with the counter proving the push ran.

**Second: Model-B headers.** A private `immu.h` with `NBPP 4096` / `PNUMSHFT 12` for everything
compiled into this kernel. Today's Z3660 work showed the trap in the wild: their driver compiled
against the vanilla headers would map `2*pa`. This makes correct-by-default what is currently
correct-by-patcher, and it is a precondition for compiling any reconstructed kernel source later.

**Third, riding along: ISSUE-39 characterisation.** Sample `freemem`/`availrmem` across a burst run.
No extra hardware session — it is one small object plus the existing suite.

**Not yet: the 060.** See §6.

## 6. Is it 060 time?

> **CORRECTED 2026-08-01, and the correction changes the answer.** This section was first written on
> the assumption that no 68060 hardware was available. That assumption was wrong and had been
> wrong in the docs for a long time: the user has a **66 MHz 68060 on a Mercury adapter**
> (overdrive-style CPU swap), long in use. Real-silicon 060 acceptance is therefore a *scheduling*
> question. What survives from the analysis below: 060SP's integer half is still what gates 060
> userland, and emulator cache results are still not evidence. What does **not** survive: the
> recommendation to defer 060-D and the crossing-page runtime acceptance "until a board exists".
> The revised plan is in §7.

### The original reasoning (kept, because most of it still holds)

Partly — but not the part that looks most attractive.

**What is done:** 060-B (dual-CPU binary boots on an emulated 060) and 060-C are complete, and Codex
has now given the crossing-page unit a **static acceptance PASS** on all eight audit obligations
(`M68060-XPAGE-ACCEPTANCE.md`). Its own verdict on the remaining item is the important sentence:
runtime acceptance needs a **real 68060**, and *Amiberry must not be treated as proof* that a
hardware format-4 frame delivers FSLW.MA as expected.

**Why a cache campaign is the wrong thing to start.** 060-D would transfer today's copyback thinking
to the 060 — but its acceptance would be emulator-only, and this project has just spent a week
learning what that is worth: ISSUE-38 was **invisible in Amiberry**, because Amiberry does not model
the copyback data cache at all. Building a body of "verified in the emulator" cache claims for the
060 would manufacture exactly the kind of evidence we have learned to distrust.

**The one 060 unit that is worth doing blind** is the *integer* half of Motorola's 060SP. ISSUE-34a
is proven: the 68060 traps **any** constant division (`muls.l` → vector 61), so without it no
ordinary C program runs on an 060 at all — the FPU half is not the blocker, the integer half is. It
is the same shape as the FPSP integration that already succeeded, and its acceptance is *functional*
("does the trapped division produce the right answer"), which an emulator can legitimately settle —
unlike cache or timing behaviour.

**So:** if the goal is "an 060 that boots and runs programs", do 060SP-integer next and leave 060-D
until there is silicon. If the goal is "an 060 that is trustworthy", the honest answer is that it
needs a board, and the cheapest path to one may be the friend's Z3660 work — though he is
implementing an **040** core, so that door is not open yet either.

My recommendation: **§5 first** (all three are hardware-acceptable today), and start 060SP-integer
after that, explicitly labelled as emulator-functional acceptance.

## 7. Revised plan (2026-08-01)

**040 tails first, because the CPU swap is one-way per session.** After the swap the machine is an
060 machine and any 040 regression needs a swap back, so finish what only the 040 can answer:

1. `mprotect(..., PROT_EXEC)` publication ABI — the last piece of the ISSUE-38 story.
2. Model-B headers — makes correct-by-default what is currently correct-by-patcher.
3. ISSUE-39 characterisation (`freemem`/`availrmem` sampling across a burst run), riding along.

**Then swap to the 060 and run it as its own campaign**, in this order:

1. **A first hardware boot of the existing dual-CPU kernel, as a measurement, not as a milestone.**
   The kernel avoids the vector-61 trap through `lmul060`, so it may well reach userland before
   060SP exists; wherever it stops is the most valuable single datapoint the 060 side can produce
   right now. Bring the counters: the anchor, `cb_icode_push`, `Lkx_*`, `hat_sdtfail_n`.
2. **Codex's crossing-page runtime acceptance** — does a hardware format-4 frame set and deliver
   FSLW.MA as the unit assumes? This is the one item its static PASS explicitly leaves open, and it
   is exactly the class of question an emulator cannot settle.
3. **060SP integer half** (ISSUE-34a), which gates every ordinary C program on the 060 — now with
   real acceptance available rather than emulator-functional only.
4. **060-D caches**, with the copyback campaign's machinery and, this time, silicon to accept on.

Expect the 060 to find things the 040 could not: different store-buffer and branch-cache rules, a
different fault frame, and the same class of "the emulator was lenient" surprises that ISSUE-38 was.
