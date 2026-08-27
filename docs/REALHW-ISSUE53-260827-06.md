# Hardware acceptance: `68060-260827-06` — 2026-08-27

The ISSUE-53 A3091 interrupt-source demultiplex wrapper, on top of the merged tree and the
ISSUE-49 paired-vpage bridge. **The battery reaches 12/12 for the first time**, and a full
four-round burst runs 96/96 with no wedge. What the run does *not* establish is stated as
plainly as what it does: see "What this does not decide" below, which was written before the
counters were read.

**Artifact** `build/unix-040`, sha256
`c2fb10fcf7fc64a4dfdc8d2ab7203d5049592dd7af2a50857c47fa8085fae582`
**Banner / `uname -m`** `Amiga (Unlimited) 68060-260827-06`
**Machine** Amiga 3000, 68060, booted by the operator.
**Archive** NAS `amix/issue53-260827/` — the accepted binary as `unix-040-260827-06`, its
`SHA256`, the three run logs (`battery.log`, `burstloop11.log`, `mkbattery.log`), every test
source and the battery driver. Archived because a later relink in the same session had already
overwritten `build/unix-040` twice: the accepted image survived only as a scratch copy, which is
the near-miss `STATUS.md` §1 warns about after losing `68060-260806-06`.

**Identity, and its one gap.** The loader's `image checksum` line was not captured for this
boot — the machine was booted from the console rather than through the usual capture. The
identity evidence that *is* available is stronger than the banner alone: this image is the
first to carry the `a3w` counter block at all, and `a3w_magic` read `41335721` at
`0810E658`, which is the address computed from *this* build's symbol table. No earlier
kernel has that block, and a wrong image would have failed the magic check rather than
returning a plausible number. Capture the loader line on the next boot anyway.

## Results

| step | result |
|---|---|
| 1 host gates, second build, byte diff | ✅ `TOTAL complaints: 0`, `bindings failing: 0`, **one differing byte** (build-id stamp) |
| 2 identity + magics | ✅ **34/34** — one more block than `-08`, because the wrapper brought `a3w` |
| 3 battery | ✅ **12/12 — first time in this project** |
| 4 burst | ✅ **96/96**, all ten anomaly patterns zero, wrong-sums check clean |
| 5 A3091 classifier | ✅ wired, correct, silent — and **`a3w_eint_only = 0`**, see below |
| 6 DMA prepare/complete | ✅ 162 485 transactions, paired by direction, every must-stay-zero counter zero |
| 7 CPU-specific, graphics, power cut | not run in this session |

### 3 — battery, 12/12

`test-tools/batteryrun-260827-06.sh`:

    all 34 magics OK
    BATTERY-RESULT PASS
      ok proctest  fputest  mlocktest  msynctst  mincoretst  bigargv
      ok ptracepoke  bmaptest  devmaptest  exectest  mul64test  protfault

**`devmaptest` has been the only miss in every battery run since it was written.** The
ISSUE-49 paired-vpage bridge makes its T1 case pass, and this is that bridge's hardware
acceptance as much as it is the wrapper's.

### 4 — burst, 96/96

`burstloop11.sh 4`: four rounds × four bursts × six concurrent 4 MiB copies, with
`hat_dup_cow 64` running against them.

    rounds=4
    good_sums (expect 24 per round): 96
    bad address 0 | Bad address 0 | read error 0 | cannot open 0 | can.t open 0
    No space 0 | BUS ERROR 0 | PANIC 0 | Segmentation 0 | Killed 0
    ---- wrong sums ----          (none)

**This is the workload after which two of the four wedges happened, and it did not wedge.**
It is also the first burst to run 96/96: `68060-260826-04` ran 95/96, the miss being ISSUE-51's
one silently wrong read. One clean run is a rate datum of one and does not close ISSUE-51.

### 5 — the A3091 source classifier

`a3w`, 21 longs at `0810E658`, read after the burst:

```
  a3w_magic          41335721  "A3W!"
  a3w_ran            41335752  "A3WR"      the wrapper body executed
  a3w_consume               1              shipped configuration
  a3w_calls            598868              every level-2 interrupt on the machine
  a3w_nodev                 0              MUST STAY 0
  a3w_notours          436659              INT_P clear at entry
  a3w_own              162217              INT_P set at entry
  a3w_ints_only        162217              the WD asked, and only the WD
  a3w_ints_eint             0
  a3w_eint_only             0              <- the reading this unit exists for
  a3w_other                 0              MUST STAY 0
  a3w_eint_acked            0              no CINT strobe was ever needed
  a3w_eint_deleg            0
  a3w_resid_eint            0
  a3w_eint_then_ints        0
  a3w_last_istr          00d0
  a3w_or_istr            fed3              every bit ever seen at any entry
  a3w_other_istr            0
  a3w_other_pr              0              no console line was spent
  a3w_dead_n                0              MUST STAY 0
  a3w_dead_istr             0
  a3d_ran                   0              the stock DEAD path was never reached
  a3d_n                     0
```

Invariants: `own` = `ints_only` **exactly**; `eint_acked` = 0 = `(0 − 0) + 0` **exactly**;
`calls` 598 868 against `nodev + notours + own` 598 876, a gap of **8**, which is read skew —
`kpeek` does one `lseek`+`read` per longword and `a3w_calls` is read first, so it is the
stalest. Earlier reads in this session gave gaps of 0, 2, 8, 18 and 34. **The gap varies,
which is what distinguishes skew from an off-by-N defect, and no read ever produced a
negative gap.**

### The undefined `ISTR` bits float on silicon, and are constant in the emulator

`a3w_or_istr` is `0xfed3` here and `0x00d1` in Amiberry. Successive `a3w_last_istr` readings on
this machine were `0x00d0`, `0xfed2`, `0xfed0`, `0x00d0` — so **bits 15–9, which neither NetBSD's
`ahscreg.h` nor Linux's `a3000.h` defines, read back sometimes zero and sometimes one.** Bit 8
(`INTX`) is always zero, so it is a real implemented bit, and bits 15–9 are not.

The wrapper is unaffected because its error test masks exactly the three named sources
(`0x010c`) instead of whitelisting the documented bits; `a3w_other = 0` across 162 217 A3091
interrupts proves it. **Anyone "tightening" that mask into a whitelist would classify a varying
subset of every interrupt on silicon as unclassified, and would see none of it in the emulator.**

### 6 — DMA prepare/complete, and why it was nearly misread

`dma_*`, 13 longs at `0810E4E0`:

```
  dma_seg_seq      162485      dma_prep_whole   162485      dma_cmpl_count   162485
  dma_prep_to      118638      dma_cmpl_to      118638
  dma_prep_from     43847      dma_cmpl_from     43847
  dma_zero_arm  dma_reconn_arm  dma_prep_owned  dma_cmpl_noprep  dma_range_ovf   all 0
```

`prep_to + prep_from` = 162 485 = `seg_seq` = `prep_whole` = `cmpl_count`, and each direction's
complete equals its prepare. The prepare path increments these on one straight line with no
branch between them (`src/dma_cache040.s`, `Lst_stateok` onward), so any inequality would be a
defect; there is none.

**Two process notes, because both nearly produced a false finding.**

The first read of this block used a runtime address computed as `nm value + 0x08000000`. That is
the `.text` base; `.data` lives at `0x08000000 + tsize` = `0x080F5778`, so the read landed inside
`.text` and returned `207c00bf`, `4e5e4e75` and other perfectly plausible-looking longwords. This
block is the one counter block in the kernel with **no magic word** — already recorded as a gap
in ISSUE-51's follow-up list — and this is exactly the failure the magic words exist to prevent.
It was caught only because the values disassemble as instructions. Giving `dma_*` a magic word is
now a concrete item, not a tidy-up.

The second was arithmetic: `0x27ab5` was read as 162 997 rather than 162 485, which made the
direction counters look 512 short and briefly looked like a real imbalance. Recorded because a
"suspiciously round discrepancy" is exactly the shape that gets written up before it is checked.

## What this does not decide

**`a3w_eint_only = 0`.** Over 598 868 level-2 interrupts, of which 162 217 were the A3091's,
including a full four-round burst, `a3w_or_istr` is `0xfed3` — **bit 5, `E_INT`, was never set at
the entry of any of them.** The event the wrapper exists to intercept did not occur.

The consequence has to be stated bluntly, because the temptation runs the other way:

> **The machine surviving the burst is not evidence that the fix works.** The wrapper only
> changes behaviour for an event it counts. A zero count means it changed nothing at all, so it
> cannot be the reason nothing went wrong. Any future claim that ISSUE-53 is closed must be
> backed by `a3w_eint_only > 0`.

What the run *does* establish is that the wrapper is wired, classifies real traffic correctly and
mutually exclusively, costs nothing observable, never takes its loud path, and does not break the
disk under the heaviest workload this project runs. That is the whole of it, and it is what makes
the next wedge worth having: `a3w_dead_istr` will hold the **entry** `ISTR` of the interrupt that
kills the driver, which is the one datum the four August captures could not produce.

It also puts a bound on the mechanism: whatever raises `INT_P` without `INTS`, it does not happen
once in 162 217 A3091 interrupts. That is consistent with the wedge's observed rate — a few times
a day, not a few times a minute — and with the audit's candidate, a FLUSH completion whose
`E_INT` escapes `stopdma`'s own `CINT`.

## Incidental

`uptime` after 33 minutes including the burst: `load average: 0.00, 0.00, 0.00`. The same kernel
in Amiberry showed garbage load figures two minutes after boot with no graphics and no FP-heavy
process (`test-tools/issue53-emu-verify-260827.txt`). ISSUE-52 was recorded on hardware as frozen
garbage *after* FP-heavy graphics; this run's clean hardware reading is consistent with that and
says nothing new about it, but the emulator's behaviour gives ISSUE-52's "date the defect" step a
version that costs no hardware time.
