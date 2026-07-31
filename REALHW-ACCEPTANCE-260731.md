# Re-acceptance of the shipping kernel — 2026-07-31

Why this run existed: nearly every claim in the docs was measured on a kernel that no longer exists.
The last full battery was 2026-07-27 on a **write-through** kernel. Since then the cache mode became
copyback by default, `copyout` gained a `cpusha bc` (the ISSUE-38 fix), fifteen diagnostic sites were
gated behind `kdbg_on`, and one machine-specific print gate was closed. Each of those changes timing
and cache footprint — which is precisely what ISSUE-38 taught us not to assume away.

## Kernel under test

```text
unix-040-260731-10      copyback, silent, no probes -- the shipping content
uname -m: Amiga (Unlimited) 68040-260731-10
loader: unix_boot040
```

The acceptance set is on the NAS as `amix/acceptance-260731/` with `SHA256SUMS.txt`, including the
write-through control (`unix-040-wt-control-260731-29`, built from this same base) for one-boot A/B
if anything fails, and the dbg image for diagnosis only — never as the subject of a verdict.

## Result: 9/9

| test | result |
|---|---|
| `exectest 20` | **PASS** — data+bss verified across every generation |
| `proctest` | **PASS** — fails=0 (this program panics a kernel without the ISSUE-17/18 fix) |
| `fputest` | **PASS** — 040 hardware FP arithmetic correct, and the native `cc` compiled it (the M3 criterion) |
| `bmaptest /pgc` | **PASS** — fails=0, direct/indirect/unaligned/SYNC/fragment growth |
| `devmaptest` | **PASS** — `/dev/mem` PFN correctness, mincore over 4 device pages, canaries clobbered = 0 |
| `mlocktest` | **PASS** — fails=0, skipped=0 |
| `msynctst` | **PASS** — `MSYNC-OK sz=65536` |
| `bigargv` | **PASS** — 45 args, 4500 bytes |
| `mincoretst` | **PASS** — vector correct, 2 KiB-offset call correctly EINVAL |

No panics, no traps, no console noise. Whole battery ≈ 90 seconds including the on-machine compiles.

## Counters (recomputed for this build, anchor first)

```text
hat_cm_ram      080FC6CC = 0x00000020    ANCHOR: copyback live
cb_icode_calls  080FCA6C = 1             the ISSUE-38 gate matched main's icode copyout
cb_icode_push   080FCA70 = 1             the cpusha bc actually executed
kdbg_on         080FCA74 = 0             base silent by flag, not by luck
hat_pfnmiss_n   080FCA78 = 12            boot-time constant (10-12 across machines and builds)
hat_badaslot_n  080FCA7C = 1713          the per-teardown skip; not a leak, see KNOWN-ISSUES
cb_rel_count    080FCA5C = 38291         copyback release barrier running
cb_rel_reject   080FCA60 = 0             every released page inside [pages, epages)
wb_dfc_changed  080FC948 = 262           the ISSUE-22 DFC fix fired 262 times during the battery
us_odd_user     080FC820 = 0             no odd user-space faults
```

## Two harness lessons, both mine

* **`bmaptest` defaults to `/pgc`**, the two-phase test directory, which did not exist on this
  machine — every subtest reported `errno=2` and the test said FAIL. That is an empty test
  environment, not a kernel defect; with `mkdir /pgc` it passes 11/11. A test that fails for lack of
  a directory must never be reported as a kernel result.
* **Counter addresses were stale.** The first read used addresses computed for build `-02`, and this
  is `-10` — relinked since, so every `.data` address moved. The reads looked plausible except the
  anchor: `hat_cm_ram` returned `0x64290000` instead of `0x20`. That is exactly what the anchor rule
  exists for, and it caught the error on the first line. Recomputed (`0x08000000 + textsize + .data
  offset`), everything reads correctly.

## Burst suite on this exact image — CLEAN

```text
sh b2repro-copy.sh 16 accept10
B2REPRO-COPY CLEAN (0 non-V0 in 16 bursts)
96 x CLASS=V0_COMPLETE_MATCH size=4194304 crc=50250      (0 non-V0)
```

16 bursts x 6 concurrent 4 MiB copies with a `hat_dup_cow 64` fork/COW churn each, ~60 min. So the
copyback acceptance now stands on the image the quieting unit and the `vtop` gate are actually in,
not only on yesterday's `-260730-03` content.

Counters across the burst run:

| counter | before | after | delta |
|---|---|---|---|
| `cb_rel_count` | 41 299 | 603 437 | +562 138 |
| `cb_rel_reject` | 0 | **0** | 0 |
| `wb_dfc_changed` | 264 | 309 | **+45** (the ISSUE-22 DFC fix firing under load) |
| `hat_badaslot_n` | 1 849 | 4 043 | +2 194 |
| `hat_pfnmiss_n` | 12 | **12** | 0 — still a boot-time constant, even under this load |
| `us_odd_user` | 0 | **0** | 0 |
| `cb_icode_calls` / `cb_icode_push` | 1 / 1 | 1 / 1 | one-shot, as designed |
| `hat_cm_ram` (ANCHOR) | 0x20 | 0x20 | copyback live throughout |

`hat_pfnmiss_n` not moving at all across half a million page releases is worth noting: whatever
produces those 12 events happens during boot and never again, which rules the COW-replacement path
out as a runtime source of stale-PTE events.

**One warning appeared on the console during this run** and is recorded as ISSUE-39: `hat_sdtalloc`
could not get a page of contiguous memory for segment tables, called from `hat_ptalloc+0x126`. It
did not damage anything — 96/96 verified byte-exact — but it is the first measured evidence of the
memory regime the open intermittents live in, and it was only seen because a human was watching the
screen. A base image has no serial hook, so console warnings leave no trace; that is a gap worth
closing with a counter.

## Not covered by this run

* **Graphics/RTG** (`unix-040-rtg-260731-13`): X11, wolf3d, `/dev/svga`, `/dev/va2000`. Needs its own
  boot.
* **The copyback pressure suite and power-cut disk truth** were run on 2026-07-30 against
  `-260730-03` content, which differs from this image by the quieting unit and the `vtop` gate.
  Neither touches the I/O path, but "does not touch" is an argument, not a measurement — a repeat
  burst run on this image is the honest completion of the set.
* `hat_dup_cow` (fork/COW pressure) — binary lives in the analysis repo's `runtime-tests/`.

## The three 07-31 units, hardware-verified on `68040-260731-33`

One boot, three units, and the counters match the tests' semantics rather than merely being nonzero:

| test | result |
|---|---|
| `exectest 20` | **PASS** — no regression from any of the three units |
| `proctest` | **PASS** — incl. CHILD-PRIV-WRITE and CHILD-COW-WRITE |
| `ptracepoke` (new) | **PASS** — 4 POKETEXTs at `0x80000650`, word `0x4e560000`, 0 fails |

```text
                       before   after
dbg_publish_on              1       1     publication enabled
dbg_ptrace_calls            0       4     <- exactly the 4 POKETEXTs ptracepoke does
dbg_ptrace_publish          0       4     every one of them published
dbg_procfs_calls            0       2     <- proctest's two child writes
dbg_procfs_publish          0       2     both published
hat_sdtfail_n               0       0     no memory pressure in a light run (expected)
Lkx_badslot/noproc/underflow 0/0/0  0/0/0 no fail-soft path taken
Lkx_maxdepth                1       1     deepest single-process recursion
Lkx_maxactive               2       2     most resolvers active at once
hat_cm_ram (ANCHOR)      0x20    0x20
cb_icode_push               1       1
```

Two readings are worth more than a PASS:

* **`dbg_procfs_calls` = 2, not more.** `proctest` also *reads* process memory through the same
  `prusrio`/`uiomove` body, and those reads did not increment anything — so the UIO_WRITE direction
  gate does exactly what the spec required, and publication is not being spent on reads.
* **`Lkx_maxactive` = 2 while `Lkx_maxdepth` = 1.** Two kernel fault resolvers were active at the
  same instant during an ordinary boot, in different processes. The retired global gate counted
  precisely that as "depth 2". It is far from the cap of 4, so it was never fatal here — but it is a
  direct measurement of the aggregation the old design could not distinguish, on an idle machine.
  Under burst load the same number is the one to watch.

`ptracepoke.c` (new, in the acceptance set) forks so the child's text VA matches the parent's,
TRACEMEs and stops, then the parent PEEKs a text word, POKEs the same value back four times and
reads it back. Harmless by construction, and it drives both `procxmt` store paths — the
already-writable one and the `as_setprot` temporarily-writable one — through `suword`.

## Burst suite on `68040-260731-33` (the three units under load) — CLEAN

```text
B2REPRO-COPY CLEAN (0 non-V0 in 16 bursts)
96 x V0_COMPLETE_MATCH      (0 non-V0)
```

Second full 96/96 of the day, now on the image carrying DBG-TEXT-PUBLISH, the per-process
fault-depth gate and the ISSUE-39 counter. Counters across the run (fresh boot to end):

| counter | before | after | reading |
|---|---|---|---|
| `hat_cm_ram` (ANCHOR) | 0x20 | 0x20 | copyback live throughout |
| `cb_icode_push` | 1 | 1 | one-shot per boot |
| `hat_pfnmiss_n` | 10 | **10** | unchanged again — boot-only, third independent confirmation |
| `hat_badaslot_n` | 545 | 3 126 | +2 581, scales with process teardowns as expected |
| **`hat_sdtfail_n`** | 0 | **1** | see below |
| `dbg_ptrace_calls/publish` | 0/0 | **0/0** | the burst path never touches ptrace |
| `dbg_procfs_calls/publish` | 0/0 | **0/0** | nor procfs writes |
| `Lkx_badslot/noproc/underflow` | 0/0/0 | **0/0/0** | no fail-soft path taken |
| `Lkx_maxdepth` / `Lkx_maxactive` | 1 / 2 | **1 / 2** | unchanged under full load |
| `cb_rel_count` / `cb_rel_reject` | — | 570 283 / **0** | |
| `us_odd_user` | 0 | **0** | |

**ISSUE-39 now has a number, and it matches the eye.** `hat_sdtfail_n` = 1 for exactly the one
console warning the user photographed during this run (`pid 1313`, again from `hat_ptalloc+0x126`,
again inside an 8 KiB `read`, again with first argument `0x40001A70` — the same value as the
2026-07-30 occurrence). So the event is genuinely rare, roughly once per burst suite, and nothing
was being hidden by print caps or console scroll. That is the difference between a warning someone
happened to see and a measured rate.

**`Lkx_maxactive` did not move under load.** Six concurrent 4 MiB copies plus a fork/COW churn per
burst still produced at most two kernel fault resolvers active at once — the same as an idle boot.
So the retired global gate had a wide margin in this workload (the cap was 4) and would not have
produced a false EFAULT here. The gate is still wrong in principle, and X11 with clients is a
different concurrency profile worth measuring, but the honest statement is that this workload never
approached the old limit.

**The publish wrappers cost nothing here.** Both `dbg_*` pairs stayed 0 across 570 283 page
releases, i.e. the retargeting adds no work to any path the burst suite touches.

## Graphics phase on `unix-040-rtg-260731-34`

RTG kernel rebuilt from the `-33` base so it carries the same three units as everything else.

| test | result |
|---|---|
| `hat_cm_ram` anchor | **0x20** |
| `exectest 20` | **PASS** |
| `fputest` | **PASS** — 040 hardware FP correct |
| `devmaptest` | **PASS** — device-mmap PFN, canaries 0. This is what all RTG rests on |
| `svgaprobe` | **PASS** — `CardID=3 (Piccolo)`, 2 MiB framebuffer, blitter, panning |
| `wolf3d` | **PASS** (user-run from the console) — the hardest fault-path exercise we have |
| VA2000 X server (`Xrtg`) | **PASS** (user-run) — desktop up, several clients opened |
| Xsvga X server | **not run** — this disk image does not carry it; it needs the other image |

Device nodes: `svgaprobe` opens `/dev/svga0`, with the digit — `/dev/svga` alone is not enough.

**A correction I have to make.** I read `va2000probe`'s "firmware version = -2147408624" as evidence
that no VA2000 board was present. That was wrong: the board is in the machine, and its X server
brought up a desktop with clients. The probe's version read is what is broken, not the hardware.
The lesson is the one this project keeps relearning — an odd-looking number from an unverified
instrument is a statement about the instrument until something independent agrees with it.

### Counters, boot to end of the graphics session

| counter | at boot | after | reading |
|---|---|---|---|
| `hat_pfnmiss_n` | 10 | **12** | **+2 — the first runtime movement ever recorded** |
| `hat_badaslot_n` | 512 | 1 289 | +777, scales with teardowns |
| `hat_sdtfail_n` | 0 | **0** | X did *not* reach the memory-pressure edge; the burst suite does |
| `Lkx_maxdepth` / `Lkx_maxactive` | 1 / 2 | **1 / 2** | still two, even with an X server and clients |
| `dbg_ptrace_*` / `dbg_procfs_*` | 0 | **0** | graphics touches neither path |
| `cb_rel_reject` / `us_odd_user` | 0 / 0 | **0 / 0** | |

**`hat_pfnmiss_n` moved.** Until now it had been a boot-time constant of 10-12 that did not budge
across `exectest`, an `amixadm` session, a compile load, or two full 16-burst suites — 570 000+ page
releases without a single event. In this session it went 10 → 12. The session contained several
native compiles, the test battery, wolf3d and an X server with clients; compiles alone did not move
it on the previous boot, so the graphics/game workload is the likely source, but **this measurement
cannot separate wolf3d from X** and should not be reported as if it could.

That matters because the counter names exactly the ISSUE-10 chain: `hat_pteload` found a live leaf
PTE naming a different pfn and overwrote it. The revmap fix at that site is what stops it being
fatal, and nothing failed here. But "boot-only" is now falsified, and the next question is which of
the two workloads produces it — a question one more boot answers cheaply, by running them one at a
time with a counter read between.

**`Lkx_maxactive` has never exceeded 2** in any workload measured today: idle boot, 16-burst suite
with six concurrent copies and fork churn, wolf3d, and an X session with several clients. The
retired global gate's cap was 4, so it had margin everywhere we have looked. It was still the wrong
design, and the per-process gate costs nothing — but the honest summary is that no measured workload
came near the old limit.

## `hat_pfnmiss_n` attributed — one variable at a time

The previous section reported that the counter moved 10 → 12 during a session containing compiles,
the battery, wolf3d and X, and said explicitly that the measurement could not separate them. It was
worth one more boot to find out, and the answer is not what I guessed.

Fresh boot of the same kernel, nothing else run, counter read between each step:

| step | `hat_pfnmiss_n` | delta |
|---|---|---|
| boot | 10 | — |
| **wolf3d** (user-run, full session) | 10 | **0** |
| **X server + several clients** (user-run) | 10 | **0** |
| one native `cc` compile | 10 | **0** |
| **`devmaptest`** | **12** | **+2** |
| `devmaptest` again | 14 | +2 |
| `devmaptest` a third time | 16 | +2 |

Deterministic: exactly two events per `devmaptest` run, and nothing else in any workload measured
today produces a single one — including two 16-burst suites totalling over 570 000 page releases.

**So the counter is not watching an anomaly in normal operation.** `devmaptest` maps `/dev/mem`, and
installing a *device* PFN over a leaf PTE that currently names a managed page is precisely the
"existing PFN differs from the new one" case. The revmap fix at that site unlinks the old page's
reverse mapping and registers nothing for the device page, which is why the test passes with its
canaries clean. Two mappings in the test, two events.

That retires the open question this counter was added for. It also sharpens what a *future* nonzero
delta means: with device mapping accounted for, any movement of `hat_pfnmiss_n` in a workload that
does not mmap a device is worth investigating, and now there is a clean baseline to say so against.

My earlier guess — that graphics work produced it — was wrong, and the guess before that ("boot-only,
never at runtime") was also wrong. Both were stated as hypotheses and both cost one boot each to
refute, which is the cheapest either could have been.

## Xsvga on X11R5 (the other disk image) — and what it sharpens

The Xsvga server was not on the acceptance disk; the user booted the same kernel
(`68040-260731-34`) against the X11R5 root and ran it there. **It worked flawlessly** — so both RTG
drivers are now hardware-verified with a real X server on this kernel: VA2000 through `Xrtg`, and
Piccolo through Xsvga.

Counters after that session (this root has no `/kpeek`, so it was compiled there first — a compile
is known to produce zero events):

```text
hat_cm_ram      0x20     ANCHOR          cb_icode_push   1
hat_pfnmiss_n   10       = boot baseline, so Xsvga produced ZERO
hat_badaslot_n  747                      hat_sdtfail_n   0
Lkx_maxdepth/maxactive  1 / 2            Lkx_badslot/noproc/underflow  0/0/0
cb_rel_count    21 602                   cb_rel_reject   0        us_odd_user  0
```

**This sharpens the `hat_pfnmiss_n` mechanism.** Both X servers map device memory — the Piccolo's
framebuffer through `svgammap`, the VA2000's through `va2000mmap` — and both produce zero events,
while `devmaptest` produces exactly two per run. So the producer is not "a device mapping". It is
**installing a mapping over a leaf PTE that already names a different, managed page**, which
`devmaptest` deliberately constructs (it maps `/dev/mem` over addresses it has already touched, and
checks the `base+2048` alias) and which an X server never does: it maps the framebuffer into fresh
address space.

That is a more useful statement than the one in the previous section, and it came free — from a run
done for a different reason.

**`Lkx_maxactive` = 2 for the fourth time.** Idle boot, 16-burst suite, wolf3d, `Xrtg` with clients,
and now X11R5 with clients: no workload measured on this hardware has ever had more than two kernel
fault resolvers active at once, against the retired global gate's cap of 4.
