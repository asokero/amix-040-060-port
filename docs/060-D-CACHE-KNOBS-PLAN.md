# 060-D — the two CACR knobs that are still off

**Written 2026-08-13, not started. Needs the 68060 in the machine (the A3640 is in it now), so
this is a batched session of its own.**

## Why this exists

The 68060's Dhrystone was recorded as "+102 % over the 040 — almost exactly the clock ratio", and
that reading closed the question. It was wrong, because the Mercury's 68040 runs at **35 MHz** (a
70 MHz oscillator at half clock), not 33. Corrected:

```
  clock ratio     66/35 = 1.886
  measured ratio  60 463.6 / 29 950.4 = 2.019
  surplus         +7.1 % per clock
```

And `pcr_boot` was measured as `0x04300601` — **ESS = 1**, so that 060 was running **superscalar**.

> A superscalar 68060 that is only **7.1 % faster per clock** than a 68040 is a low figure.

That is the whole motivation. The performance question is no longer "why is it exactly the clock
ratio" — it never was — but "where is the rest of it", and this document names the two candidates
that the same F0 measurement already found switched off.

## What is on, and what is left

| knob | where | state | note |
|---|---|---|---|
| `DC60_EDC` data cache | CACR bit 31 | **on** | copyback since 2026-07-30 |
| `IC60_EIC` instruction cache | CACR bit 15 | **on** | |
| `ESS` superscalar dispatch | PCR bit 0 | **on** | measured, not set by us — inherited from SetPatch |
| **`DC60_ESB` store buffer** | CACR bit 29 | **off** | candidate 1 |
| **`IC60_EBC` branch cache** | CACR bit 23 | **off** | candidate 2 |
| `IC60_CABC` clear all branch cache | CACR bit 22 | unused | *precondition for candidate 2 — see below* |

The live values are `cacr` and `sup_cacr`, kernel `.data` longs currently holding `0x80008000`.
`pstart040.s` installs them and **every exception handler reloads `sup_cacr`**
(`movel sup_cacr,%d0 ; movec %d0,%cacr`). So changing the enable is a one-word change — and is
even A/B-able inside a single boot, because the next interrupt reloads the word.

## The part that is not free: the branch cache has an invalidation obligation

The 68060's branch cache holds branch-target information. When instruction memory changes — a page
freed and reused for different code, `exec` replacing an address space, COW on a text page,
self-modifying code — a stale entry can send execution to the wrong address. `CINVA IC` is not
specified to clear it; Motorola provides CACR bit 22 (`CABC`) for that, and the practice is to
clear the branch cache wherever the instruction cache is invalidated.

**This port has never had to do that**, because the branch cache has never been on. The
instruction-cache invalidation sites found so far:

* `config040.s` — `cinva ic` (0xf498) at config entry;
* the resume path — `cinva ic` on context resume (CACHES STEP A);
* `codepub040.s` — code publication, `cpusha` based;
* the exec path (ISSUE-38's `copyout` + `cpusha bc`).

None of them touches the branch cache. **Enabling `EBC` without auditing these first would produce
a rare, timing-dependent jump to a stale branch target** — an ISSUE-10-shaped defect, in a project
that already has two unattributed intermittents open. It would not show up in a benchmark; it would
show up as an unexplained crash weeks later.

## Order of work

1. **Store buffer first.** Lower risk: its correctness question is write-visibility ordering for
   device registers, and the DMA cache unit already reasons about CACR (`dma_cache040.s` notes the
   `CACR.DPI` interaction). One boot, three Dhrystone runs, then the battery.
2. **Audit the instruction-cache invalidation sites** and add `CABC` to each. Bounded list, above.
3. **Then the branch cache**, and after it the **whole correctness suite** — battery, burst,
   protfault — not just Dhrystone. Performance work is where correctness regressions hide, and this
   knob's failure mode is a wrong jump.

## Acceptance shape

Per knob, one boot:

```
  identity      uname -m, and every magic read before any counter is believed
  cacr/sup_cacr read back live -- the value the kernel WRITES is not proof it took
  Dhrystone     echo 1000000 | /root/amix-bench/dhry, three runs, spread reported
                (the run count is on STDIN; `dhry 1000000` silently ignores its argument)
  correctness   battery; and for EBC also burst + protfault
```

Baseline to beat, same machine, same binary, copyback, ESS=1:

```
  60 423.0 / 60 544.9 / 60 423.0  /s      spread 0.2 %      916.1 per MHz
```

The 68040 reference for per-clock comparison is **855.7 /MHz** (29 950.4 at 35 MHz).

## The store buffer needs an instrument Dhrystone does not provide (added 2026-09-04)

The acceptance shape above would have measured `ESB` with Dhrystone and could well have recorded
"no effect". **Dhrystone never writes to noncacheable space at all**, and noncacheable writes are
the only thing the store buffer can help: writes to cache-inhibited *serialised* pages bypass it by
design, and cached writes do not depend on it in the same way. So the knob's own use case is
outside the measurement.

This came from the Xrtg line, which is bound by exactly those writes and offered a probe
(`tools/copyfloor.c` in `xrtg-amix`, native `cc`, no X server, framebuffer only, never a register).
Their reasoning about *which pages* is correct and is checkable here rather than taken on trust:

* framebuffer pages are classified `0x60` — CM = 11, **noncacheable, not serialised**, the class
  the store buffer serves. `hat040.s:690`, `Lcm_fb`, whose own comment says so.
* the VA2000's control registers are mapped `VA2000_CM_NCS` = `0x40` — CM = 10, noncacheable
  **serialised**, which bypasses the store buffer structurally. `va2000_040.c:173`.

So for this driver the usual `ESB` worry — a register write that has not landed before a dependent
read — is closed by the mapping rather than by argument. **Other drivers need the same check**, and
it is mechanical: does the driver map its registers with a serialised class.

### But the premise that the CPU is mysteriously slow does not survive our own baseline

Their probe reports 12 600 KB/s filling local RAM and reads that as ~16 cycles per longword,
"where four to eight would be expected". `busbench` measured the same operation on the same machine
class at **25 910 KB/s** (2026-08-19, Mercury 68060 @ 66 MHz, same CACR `0x80008000`), which is
~10 cycles per longword — inside the band they expected. The difference is the loop, not the core:
`busbench`'s `write32` is **unrolled ×4** with the comment "loop overhead off the measurement",
theirs is `while (n--) *d++ = v;`. With the branch cache *also* off, that overhead is unusually
expensive here.

The ratio that carries the hypothesis is unaffected and the two agree: board write is **0.30** of
local by our measurement (7.66 / 25.91) and **0.365** by theirs (4.60 / 12.60).

### What this changes about the run

* Add a noncacheable-store measurement to candidate 1's acceptance. `busbench` is the better
  primary instrument because it already has a same-machine baseline to compare against
  (`REALHW-Z3-VA2000-ACCEPTANCE-260819.md`: local 25.91 / VA2000 Z3 7.66 MB/s, write32);
  `copyfloor` is the useful second opinion because it is shaped like the server's real inner loop.
* **Change `ESB` alone.** A non-unrolled probe partly measures loop overhead, so enabling `EBC` in
  the same boot would move the board number for a reason that has nothing to do with the store
  buffer. The order of work above already separates them, for the independent reason that `EBC`
  carries an unmet invalidation obligation.

## What is deliberately not claimed

No number is predicted for either knob. Motorola describes branch folding as significant and
Dhrystone is branch-heavy, so it is a reasonable place to look — but a predicted percentage here
would repeat the mistake this document exists because of. One boot measures it.

## Related

* `060-F0-MEASUREMENT-260805.md` — the CACR decode, the PCR discussion, and the correction appended
  2026-08-13.
* `REALHW-A3640-260813-ACCEPTANCE.md` §9 — the corrected clock table.
* `STATUS.md` §7 — the three refuted conclusions this correction produced.
* `060-CAMPAIGN-PLAN-260805.md` — F4-060-D, of which this is the concrete form.
