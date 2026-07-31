# RESUME HERE — 2026-07-31: copyback landed, the base is silent, and the port needs a direction

Read this file and nothing else to start. `RESUME-HERE-ISSUE38.md` and `RESUME-HERE-ISSUE22.md` are
**closed records** — do not resume from them. Everything below is measured unless it says otherwise.

## 0. Where the port stands

The 68040 port boots, runs userland, and is now **copyback by default** with the full acceptance
taken on the image that actually ships:

```text
ISSUE-38          closed on hardware.  main+0x1e8's copyout(icode) left proc 1's bootstrap text in
                  dirty copyback lines that the 040 ifetch does not snoop; fix = gated cpusha bc in
                  prototypes/cb_icode040.s.  Records: ISSUE38-ICODE-CACHE-FINDING-260730.md
copyback default  hat_cm_ram ships 0x20 (prototypes/hat040.s); the WT control is the derived image
                  (patch_b2_flip.py --wt).  REALHW-COPYBACK-ACCEPTANCE-260730.md
acceptance        burst suite 96/96 V0, power-cut disk truth 6/6, Dhrystone 30037/s = +64 % over
                  write-through, exectest 20 PASS -- all probe-less
base is silent    kdbg_on (prototypes/kdbg040.s) gates 15 diagnostic cmn_err sites; 11 real warnings
                  stay ungated.  dbg build flips the flag; /dev/kmem can too
```

Current artifacts, NAS `nasu:Public/amix/hwtest-260731/` (`SHA256SUMS-quiet.txt`):

```text
unix-040-quiet-base-260731-02   base: copyback, silent, no probes      <- the shipping content
unix-040-quiet-260731-03        + serial mirror
unix-040-dbg-260731-04          probe overlay (btrace_on + kdbg_on = 1)
unix-040-rtg-260731-05          + BOTH RTG drivers (Xsvga cdevsw[67], VA2000 cdevsw[68])
unix-040-xsvga-only-260731-06   bisect ladder (see §2)
unix-040-va2000-only-260731-07  bisect ladder
unix-040-pad-260731-09          bisect ladder: dead space, byte-identical geometry to -06
unix_boot040                    MANDATORY loader
```

## 1. Open issues, honestly graded

**Blocking nothing, but real:**

* **ISSUE-10 / amixadm — intermittent (2026-07-31).** Crashed at startup on the RTG kernel, then
  booted clean on the *same image*. So it is probabilistic per boot and **single-boot bisects are
  invalid**; everything gathered on 07-31 is samples, not verdicts. The ladder above is the right
  ladder but needs a *rate per image*, measured in the emulator
  (`test-tools/emu-amixadm-test.sh`, ~4 min/cycle unattended), not one hardware boot per sample.
* **ISSUE-11** — `wb040.s` WB1 replay data alignment: latent real-HW landmine, emulator never fires it.
* **ISSUE-16** — RFS client cache 2 KiB geometry: 72 sites, not 5. Unconverted on purpose.
* **ISSUE-20** — stock `hat_swapout` is a mine if process swap-out is ever re-enabled.
* **ISSUE-34b** — `cc1` SIGSYS on the 68060 is *not* the vector-61 division defect (34a is proven).
* **ISSUE-3 / 19 / 29 / 30** — bounded skips and unproven-reachability items, all recorded.

**Known residuals of today's work:**

* `ptrace` POKETEXT writes user text through `copyout` and is deliberately outside the ISSUE-38
  gate. A general fix needs a VA→phys ranged push; Codex has been asked for the census.
* `hat_badaslot_n` reads ~500/boot on hardware where the old print cap only ever showed 8. Not a
  leak (the skipped descriptors point outside managed RAM), but *every* address-space root carries
  two of them — nobody has yet asked who writes root[4] and root[6].

## 2. Three candidate directions

**A. 68060.** 060-B is complete (dual-CPU binary, emulated-060 login) and 060-C is effectively done.
What remains before an 060 is usable: **060-D** caches (now much cheaper — the 040 copyback
campaign did the hard thinking), **060-E** the FPU/060SP work, which ISSUE-34a makes non-optional
(the 68060 traps *any* constant division into vector 61, so both halves of 060SP are needed, not
just the FP half), and **060-F** real hardware when a board exists. Codex's queued 060 XPAGE unit
(`vm-map/XPAGE-COVERAGE-AUDIT.md`, a61d2ac, six items, not to be split) belongs here.

**B. A3640 (an 040 card with no RAM of its own).** Everything the port assumes about the memory map
comes from the Mercury: kernel at `0x08000000` in the card's own fast RAM. On an A3640 all RAM is
motherboard fast RAM and the kernel lands elsewhere, which touches `pstart040`'s DTT/TT setup, the
`vtop040` DTT0 identity assumption for DMA, and every "phys < 0x08000000" reasoning in the tree. The
2026-07-09 analysis found the A3640 map emulator-identical, so most of this is testable locally
*before* the card is in the machine — that is the cheap half and it is worth doing first.

**C. A driver kernel for the Z3660 (a friend's drivers).** See §3 — it has a prerequisite that
decides everything else.

## 3. Z3660 driver kernel — feasibility

`~/kehitys/amix-z3660scsi` (PISCSI mailbox SCSI) and `~/kehitys/amix-z3660net` (STREAMS/DLPI
ethernet, `zen0`) are both native AMIX drivers, C, proven on a real A4000 + Z3660 — **against a
68030 kernel** (`SVR4/68030`, the Z3660's EMU core). Four findings, in the order that matters:

1. **What CPU does the friend's Z3660 present to AMIX?** If it is the emulated 68030, our kernel
   cannot run there at all and the question is moot. If it can present a 68040/68060, everything
   below applies. *Nothing else should be built before this is answered.*
2. **The board lives in Zorro III space (`0x40000000`)**, and this port cannot reach Z3 device
   apertures today: DTT0 covers 0–1 GB and `0x40000000` is a fill-on-fault kvseg
   (`amix-zorro3-aperture-limitation`, a one-variable A/B already done on hardware; the fix is
   scoped at two changes). **That is a hard prerequisite for the SCSI driver**, and it is work we
   already know how to do.
3. **Cache mode.** Their own scoping document already names 030-side coherency of the shared window
   as the top residual risk, and notes the window is mapped *cacheable*, not CI. On our kernel that
   risk is strictly worse: copyback, no bus snooping, and our DMA coherency hooks cover only the
   A3000 SDMAC. A Z3660 driver needs either a CI mapping or explicit ranged `cpushl`/`cinvl` — and
   `CPUSHL` takes a **physical** address on the 040 (the lesson from `cb_release040.s`).
4. **Page geometry.** Our kernel is Model-B 4 KiB; their sources compile against vanilla headers
   where `NBPP` is 2048 (`amix-crosscompile-headers-2kib-trap`). Any `btoc`/`ctob`/`sptalloc` page
   arithmetic in the drivers is silently wrong on our kernel. This is the most likely
   "compiles, links, boots, then corrupts" failure and it needs a source audit, not a build.

Integration itself is the *easy* part and needs no new mechanism: their build hub
(`amix-kerntools`, not present locally) rebuilds a source kernel and edits generated tables, which
we cannot use — but we already do the equivalent by relink. Ethernet wants a `streamtab` pointer in
`cdevsw[48].d_str`, which is exactly `patch_va2000_cdevsw.py`; SCSI wants a `scsicard[]` row plus a
`probe=` hook in `sd.c`'s init, which is the class of `patch_a3091_dma.py`'s reloc retarget. Both
drivers already tolerate an absent board (`autocon()` misses → the queue is never called), so a
kernel carrying them is safe to boot on our A3000 for a regression check, which is the only thing
we can verify locally: compiles, links, boots, registers, no regression. The datapath is
verifiable only on the friend's machine.

## 4. Instrument discipline — unchanged, and it keeps paying

* A **base image emits nothing on serial by design**; a silent log is an instrument failure, not a
  clean run. Take verdicts from telnet, and now also from counters via `kpeek`.
* **A boot is not proof that a fix fired.** ISSUE-38's acceptance rests on `cb_icode_push` = 1 with
  `hat_cm_ram` = `0x20` as the anchor, not on the machine reaching a login prompt.
* **Recompute counter addresses after every relink**: `0x08000000 + textsize + .data offset`.
* `real.py` takes `AMIX_CMD_TIMEOUT` (default 120 s) and sends `^C` on timeout — the native `cc`
  needs 900 for anything real.
* An intermittent needs a **rate**, not a verdict. That is the emulator's job.
