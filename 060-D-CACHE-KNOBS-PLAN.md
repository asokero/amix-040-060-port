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
