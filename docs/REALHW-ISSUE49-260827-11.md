# Hardware acceptance: `68060-260827-11` — 2026-08-27

The ISSUE-49 `/dev/screen` unit — bitplanes 4 KiB aligned and rounded to whole pages — on top
of `-06`, which is where ISSUE-53's A3091 wrapper and the ISSUE-49 fault-path bridge were
accepted the same day.

**Artifact** `build/unix-040`, sha256
`52ec2b02abae0003f68739d5d8e287131e8e18b857c31fc4dc672b3f3069bf61`
**Banner / `uname -m`** `Amiga (Unlimited) 68060-260827-11`
**Machine** Amiga 3000, 68060, booted by the operator.
**Archive** NAS `amix/issue49-260827/` — `unix-040-260827-11`, its `SHA256`, and the battery
driver.
**Emulator pre-flight** `test-tools/issue49-scrdev-emu-verify-260827.txt`, same image.

## The result, in one line

**The same object moved.** The console's own 640x512x1 bitmap sat at physical `0x00013800`
under `-06` — 2048 mod 4096, so `phystopfn` handed back a frame starting 2048 bytes before it
and every byte seen through that mapping was 2048 bytes early. Under `-11` the same bitmap
allocates at `0x00014000`. Both numbers were read out of `scrdev[0].bitmap[0]` on this
machine, one kernel apart.

## Results

| step | result |
|---|---|
| 1 host gates, second build, byte diff | ✅ `TOTAL complaints: 0`, `bindings failing: 0`, **one differing byte** |
| 2 identity + magics | ✅ **35/35** — one more block than `-06`, because the unit brought `scrfix` |
| 3 battery | ✅ **12/12**, `BATTERY-RESULT PASS` |
| 4 `scrprobe pokeall` | ✅ 9/9 YES, unchanged from `-06` |
| 5 plane alignment and accounting | ✅ `scrfix_misalign_n = 0`; the byte accounting closes exactly |
| 6 A3091 classifier still clean | ✅ every must-stay-zero counter 0, `a3d_n = 0` |
| 7 burst | ✅ **96/96**, all ten anomaly patterns zero, wrong-sums check silent |

### 5 — the measurement this unit exists for

`scrfix`, 15 longs at `0810E850`, after `pokeall` allocated and freed nine screens:

```
  scrfix_magic       53434621  "SCF!"
  scrfix_ran         53434652  "SCFR"
  scrfix_alloc_n           10     1 console + 9 probe screens
  scrfix_free_n             9     the console's is never freed
  scrfix_planes_alloc      45
  scrfix_planes_free       44
  scrfix_bytes_alloc   884736
  scrfix_bytes_free    843776
  scrfix_misalign_n         0     MUST STAY 0
  scrfix_allocfail_n        0     MUST STAY 0
  scrfix_badtype_n          0
  scrfix_last_ptr    0014a000     4 KiB aligned
```

Summing the nine modes from the probe's own matrix, **with** the rounding applied, gives
44 planes and **843 776** bytes — exactly `scrfix_bytes_free`. Without the rounding it would be
788 480. So the total can only be produced by the rounding actually running *and* by
`allocbmap` and `freebmap` rounding to the same value; `bytes_alloc - bytes_free` is exactly
40 960, the one console plane that is never freed.

These figures are **identical to the emulator's**, which is worth stating because so little
else in this project is: the unit touches no cache, no DMA and no FP, so for once the emulator
was a fair test and said the same thing silicon did.

### 7 — burst, 96/96

`burstloop11.sh 4` on this kernel: four rounds, 96 good sums, every anomaly pattern zero, no
wedge. Counters read afterwards:

```
  a3w_calls        568955      a3w_notours  410152      a3w_own      158813
  a3w_ints_only    158813  (= own exactly)
  a3w_eint_only 0 | a3w_other 0 | a3w_nodev 0 | a3w_dead_n 0 | a3d_n 0
  a3w_or_istr      fed3        E_INT still never set at any entry
  scrfix           unchanged by the burst; accounting still exact
```

`a3w_calls` against `notours + own` differs by 10, the usual read skew from `kpeek`'s
one-longword-per-read. **`Lkx_fn` was still 1 afterwards** — the `krnxflt FAILEXIT` line did
not recur under the heaviest disk load this project runs, so whatever produced it belongs to
the battery and not to disk pressure. That is a small narrowing, not an attribution.

### What this still does not decide

Whether Deluxe Paint draws where it means to. This shows the plane is aligned, page-rounded,
zeroed and accounted; it does not show a correct picture. That needs the application driven
against a display.

## Two things that looked like failures and were not

**The battery reported `BATTERY-RESULT FAIL (12 missing)` on the first run.** Every one of the
twelve tests had in fact passed — the log held 17 `RESULT PASS` lines and no `RESULT FAIL`. The
driver's verdict greps a **hardcoded** `/tmp/battery.log` while that run had been redirected to
`/tmp/battery11.log`, and the reboot had wiped `/tmp`, so every `grep` read a file that did not
exist and reported `MISSING`. It looked exactly like a total regression on a new kernel.

The driver now takes the log path as `$1` and **aborts if that file does not exist**. A check
that read nothing must not be able to print a verdict — the same rule that produced the
`sdc_setprot_bad` and `burstloop11.sh` lessons, arriving from a third direction.

**One `krnxflt FAILEXIT` line on the console**, photographed during the run:

    WARNING: DBG krnxflt FAILEXIT w=2 va=434D4642 rw=1 depth=1

`cofault.c` documents this exact message shape as an expected observation — it is the kernel
fault resolver declining a kernel-mode access to a bad user address, which is what it is for.
Its own counters were read afterwards: `Lkx_fn = 1` (one print all boot, matching the single
line), and `Lkx_fallback_depth`, `Lkx_badslot`, `Lkx_noproc` and `Lkx_underflow` **all zero**,
with `Lkx_maxdepth = 1` and `Lkx_maxactive = 2`.

`va=434D4642` is ASCII `CMFB`, which is the `cmf` block's magic word — so something used a
magic value as an address. **Which test, and whether this also happened on `-06`, is not
known:** the `Lkx_*` counters are file-local, have no magic word, and therefore appear in no
battery dump, so there is no baseline to compare against. Recorded as a thing to watch, not
claimed as new and not claimed as benign. It is the second counter block found this day to be
invisible for want of a magic word, after `dma_*`.

The two `User BUS ERROR ... CMD:./protfault` notices in the same photograph are `protfault`
doing its job: it provokes denied writes on purpose, and it passed.
