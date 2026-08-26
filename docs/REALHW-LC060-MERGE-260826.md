# Hardware acceptance: the LC060 merge on `68060-260826-06` — 2026-08-26

**Artifact** `build/unix-040`, sha256
`20eb470b5350721bf22e554955ecac283ce61cdaf2a4bbe89303eca5d003c493`
**Loader identity** `image checksum = 0d8a0168 (277686 longs)` — and this one is worth noting:
the emulator printed the same value for the same file. The loader's checksum is a **file**
identity, not a machine-specific number, and it reaches the serial log even from a kernel that is
otherwise silent there.

## Results

| step | result |
|---|---|
| 1 host gates, second build, byte diff | ✅ `TOTAL complaints: 0`, `bindings failing: 0`, one differing byte |
| 2 identity + magics | ✅ **32/32** |
| 3 battery | **11/12** — the miss is ISSUE-49, unchanged from every previous image |
| **the merge's own criterion** | ✅ `fpc_save_nofpu_n` = `fpc_rest_nofpu_n` = `fpc_setup_nofpu_n` = **0** |
| 4 CPU-specific | ✅ `fp060probe bad=0`, `isp61ea bad=0`, `fputest060 fork` exact, Motorola `unimp` and `main` 4/4 |
| 5 device/graphics | n/a — base kernel, no VA2000 driver |
| 6 burst | ✅ **96/96**, zero anomalies, **no wrong sums** |
| 7 power cut | not run on this image |

### The FPU gates are inert here, measured rather than assumed

The merge added `tstl fpu_present` to each 060 arm of `fpu060.s` because a 68LC060 has no FPU and
every body there issues FSAVE or FRESTORE. On this machine `fpu_present` reads `00000001`
(measured before merging), so the gates fall through — and all three `*_nofpu_n` counters read
zero after a full battery and burst. A non-zero reading would have meant a gate firing on a part
that has an FPU, which the authors name as a finding rather than a curiosity.

The counters were appended to the **end** of the `fpc` block on purpose, so every address already
published for it kept its offset. That is why this tree's earlier battery drivers stayed valid.

### The burst, with the DMA counters on both sides

    before:  prep_from   5 164   prep_to  13 289   cmpl_count  18 453
    after:   prep_from  41 710   prep_to 123 997   cmpl_count 165 703

~147 000 DMA transactions across the run. `cmpl_from == prep_from` and `cmpl_to == prep_to`
exactly, and `dma_prep_owned`, `dma_cmpl_noprep`, `dma_range_ovf`, `dma_zero_arm` and
`dma_reconn_arm` all stayed zero.

Small skews between `cmpl_count`, `prep_whole` and `seg_seq` (165 703 / 165 708 / 165 715) are the
snapshot not being atomic — it is 39 separate `kpeek` invocations on a working machine — and not
an anomaly. Said here because a reader comparing three numbers that should match deserves to know
which differences are measurement and which are findings.

**And the wrong-sums section is empty.** The previous burst produced one real wrong sum
(ISSUE-51); this one produced none. Both readings are only legible because that check stopped
matching its own header earlier the same day.

## What this does and does not settle about the wedge

`a3d_ran` stayed `0` for the whole run: the machine was up 55 minutes, built 13 programs, ran a
battery, five CPU tests and a four-round burst, with the interposer armed.

**The first run of this same kernel died two minutes after boot.** So:

| | 1st run `-06` | 2nd run `-06` | `-04` |
|---|---|---|---|
| NFS mount + 13 copies | **wedged** | ok | ok |
| build, battery, CPU tests | — | ok | ok |
| burst | — | **96/96** | 95/96 + wedge |

Three wedges now, **two different kernels**, all three on `units[6]` with the same
`head=0 dmaon=0 segstate=0`.

The honest statement is narrow: **swapping the kernel is not the variable that explains the
wedges.** Not "the merge is clean" — three samples cannot carry that — but the merge is defended
twice over: no mechanism was found by looking, and the failure does not reproduce as a function
of which kernel runs.

It also removes the burst correlation entirely. Wedge 3 came under light load and this burst,
heavier than the one that preceded wedge 2, produced nothing.
