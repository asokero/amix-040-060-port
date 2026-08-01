# Real hardware, ISSUE-40 part 1 — every pre-registered prediction confirmed, including the negative one

**2026-08-01, A3000 + Mercury 68040 @ 10.0.10.10, kernel `68040-260801-12`** (sha256
`d1acde8d…`, textsize `0xe46ec`). Logs on the NAS: `amix/hwtest-260801b/i40regr.log`,
`i40d.log`. Scripts `test-tools/i40regr.sh`, `test-tools/issue40d.sh`; predictions were written
into their headers **before** the machine was switched on.

Anchors first, because nothing below means anything otherwise: `i40_magic = 49343021`,
`i39_magic = 49333921`, `hat_cm_ram = 0x20` (copyback). Both scripts abort without them.

## 1. Safety — clean

```text
exectest 20                     PASS (data+bss verified across every generation)
hat_dup_cow 1 / 32 / 256        PASS isolation / PASS fork+exec / PASS stress   (all three)
devmaptest                      PASS, fails=0
hat_pfnmiss_n                   0x0a -> 0x0c  = EXACTLY +2 across devmaptest, and
                                0x0c for the whole run afterwards -- nothing else moves it
i40_bad_n                       0
i40_err_n                       0
cb_rel_reject                   0
hat_sdtfail_n                   0   (ISSUE-39 never fired)
```

The new edge runs on every process exit and calls a retained stock body this port had never
invoked. It survived ~3900 teardowns plus the COW stress suite without a single anomaly.

**`i40_bad_n = 0` is the one that mattered most.** The shape guard never had to reject a
descriptor on the real memory map, where `pages_base`/`pages_end` sit elsewhere and the machine
used to walk ~499 stale legacy descriptors per boot. Codex's "A4..A7 are never native" argument
holds here too — and it is now a measurement rather than an argument.

## 2. The edge fires — sharper on hardware than in the emulator

`hat_badaslot_n`, the count of legacy false descriptors the native walk trips over:

```text
edge ON    +2    over 1665 teardowns   (0x27 -> 0x29)
edge OFF   +975  over  654 teardowns   (0x32 -> 0x401)
```

Same boot, same workload, one variable (`kpoke i40_on`). The legacy descriptors are being
cleared before the walk, exactly as designed.

## 3. And it returns zero pages — confirmed on hardware

```text
phase                          availrmem   delta   pages_pp_kernel   delta
baseline                          6845               884
300 x fork                        6821     -24      912             +28
300 x fork+exec                   6512    -309     1217            +305
300 x fork+exec                   6197    -315     1532            +315
300 x fork                        6197       0     1532               0
300 x fork+exec   (edge OFF)      5881    -316     1852            +320
```

`availrmem + pages_pp_kernel` conserved at 7729 throughout (±4 background).

**−315 with the fix, −316 without it.** One page per dynamic exec, unchanged, and fork stays
flat. The half-fix fixes nothing observable, on hardware as in the emulator.

The instrument says why, without ambiguity:

```text
i40_pgfreed_n = 0        3440 releases, ZERO pages returned
i40_held_n    = 3440  =  i40_sec2_n (2284) + i40_sec3_n (1156)   exactly
```

Every single release left `p_sdtbits` non-zero, so `hat_sdtfree` never reached its credit at
`0xb66e4`. Residual bitmaps sampled at four different moments:

```text
0x000e5fff   0x000e017f   0x5fffffff   0x000e0017   0x000e0bff
```

These are **densely shared** pages — up to 22 of the 32 units occupied, with the freed object's
bits punched out of the middle. `i40_last_n = 1` in every sample, i.e. the last object released
was a one-unit allocation. The emulator saw an 18-unit object at index 0 with 13 crumbs above it;
the real machine shows the same allocator behaviour at a busier mix.

## 4. What this settles

| pre-registered prediction | outcome |
|---|---|
| `availrmem ≈ -300`, **unchanged** by the fix | confirmed: −315 on, −316 off |
| fork behaves as before | confirmed: −24 and 0 |
| `i40_bad_n = 0` | confirmed |
| `i40_err_n = 0` | confirmed |
| `i40_pgfreed_n = 0` | confirmed |
| `i40_held_n = sec2 + sec3` | confirmed exactly (3440) |
| `i40_last_bits` nonzero above the object | confirmed, five samples |
| edge OFF: same slope, `hat_badaslot_n` jumps | confirmed: −316, +975 |

So the re-scoping in `ISSUE40-LEGACY-SDT-LANDED-260801.md` holds on the real machine:

> The legacy-SDT edge cannot return a single page while the `ptdat` records leak. The two are
> independent to *write* and strictly serial to *observe*.

ISSUE-40 stays **open**. Part 1 is landed, hardware-safe, and is the prerequisite for part 2
being observable at all. Part 2 is `hat_ptfree`'s one-unit `ptdat` lifetime —
`ISSUE40-PTDAT-CODEX-QUESTIONS.md`, P1..P5.

## 5. What was NOT run, and why

The full acceptance battery (9/9 + burst 96/96 + power-cut disk truth) was deliberately not run.
Its pre-registered ISSUE-40 criterion cannot pass with half the fix present, and part 2 touches
the same teardown path — so the battery is run once, after both halves, instead of twice. What
*was* run is the subset that could actually fail because of this change: the exec path, fork/COW,
the device-mapping PFN calibration, and the three counters that would expose a bad free.

## 6. Method notes worth keeping

* `real.py` is recreated per session in the scratchpad from `test-tools/emu.py` plus the
  credentials — it is deliberately not in the repo.
* A trailing `&` breaks the driver's sentinel: `cmd &` becomes `cmd &; echo TAG`, a Bourne syntax
  error, and the command silently never runs while the driver times out. Wrap it:
  `(nohup sh /tmp/x.sh > /tmp/x.log 2>&1 &)`. Cost one confusing timeout before it was spotted —
  and note the failure mode is a *silent no-op*, not an error message.
* Each `cc` its own command with `AMIX_CMD_TIMEOUT=900`; four compiles, four calls.
* `kpeek` prints hex. The decimal in the log comes from `dc`, which exists on this machine.
