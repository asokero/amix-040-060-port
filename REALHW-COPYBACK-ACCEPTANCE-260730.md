# Copyback acceptance on the SHIPPING kernel — 2026-07-30/31

The first copyback acceptance ever run on a probe-less image. Every earlier copyback result was
taken on a dbg overlay — which, as ISSUE-38 showed, carried an unconditional `cpusha bc` in its
`copyout` wrapper and therefore was not the kernel anyone would ship.

## Kernel

```text
unix-040-b2-fix38-260730-03    copyback, NO probes, ISSUE-38 fix (cb_icode040)
uname -m: Amiga (Unlimited) 68040-260730-03
```

Byte-identical to `unix-040-cb-default-260730-06` (the copyback-by-default base link) except for one
build-id character, so this run covers the shipping artifact.

## Result

```text
sh b2repro-copy.sh 16 accept
B2REPRO-COPY CLEAN (0 non-V0 in 16 bursts)
96 x CLASS=V0_COMPLETE_MATCH size=4194304 crc=50250
```

96/96 verifications complete and byte-exact: 16 bursts × 6 concurrent 4 MiB copies, with a
`hat_dup_cow 64` fork/COW churn in every burst. No `V1_EFAULT_TRANSIENT` (ISSUE-22's old signature),
no `V3`–`V6` (a real copyback disk-truth defect). Wall clock ≈ 65 min, ~2.5 min/burst, consistent
with the known b2repro stall behaviour rather than the 120 s ideal.

**Confounder, recorded rather than hidden:** the user ran `/root/amix-bench/dhry` on the machine
during the run (result 30037/s, below). That is concurrent CPU load, not the concurrent *disk*
search that made the 2026-07-28 run uninterpretable — and a clean result under extra load is still
clean. Only the timings are not comparable to an idle-machine run.

## Counters, before and after (kpeek, image `-03`)

| counter | address | before | after | delta |
|---|---|---|---|---|
| `us_calls` | 080FC764 | 3 514 | 185 364 | +181 850 |
| `us_odd_user` | 080FC768 | 0 | **0** | 0 |
| `us_odd_kern` | 080FC76C | 890 | 80 529 | +79 639 |
| `wb_dfc_n` | 080FC88C | 22 260 | 240 748 | +218 488 |
| `wb_dfc_changed` | 080FC890 | 230 | 273 | **+43** |
| `wb_replay_n` | 080FC89C | 7 470 | 120 114 | +112 644 |
| `wb_replay_odd` | 080FC8A0 | 230 | 273 | +43 |
| `wb_sfc_changed` | 080FC8B0 | 1 | 1 | 0 |
| `cb_rel_count` | 080FC9A4 | 28 715 | 584 282 | +555 567 |
| `cb_rel_reject` | 080FC9A8 | 0 | **0** | 0 |
| `dma_cmpl_noprep` | 080FC994 | 0 | **0** | 0 |
| `cb_icode_calls` / `cb_icode_push` | 080FC9B4/B8 | 1 / 1 | 1 / 1 | 0 |
| `hat_cm_ram` (ANCHOR) | 080FC614 | 0x20 | 0x20 | copyback live throughout |

Three of these are results, not bookkeeping:

* **`wb_dfc_changed` +43.** The ISSUE-22 DFC-preservation fix fired 43 times under this load: the
  fault wrapper found DFC different on the way out and restored it. The fix is not dormant, it is
  load-bearing — and the run that exercised it produced zero EFAULTs.
* **`dma_cmpl_noprep` 0 across +555 567 page releases.** Every DMA completion still had a PREPARED
  record; the B1 coherency hook never failed open under real copyback pressure.
* **`cb_rel_reject` 0.** Every page handed to the copyback release barrier was inside `[pages,
  epages)`; no page was silently skipped.

`wb_sfc_changed` reads 1 rather than the 0 recorded on 2026-07-29 — the deliberate `ptest040.s:52`
SFC leak did diverge once on this boot, before the burst run, and did not recur during it. The
wrapper contract makes it harmless; it is worth a line in the log, not an investigation.

## Dhrystone on the shipping kernel

`/root/amix-bench/dhry` on `-03`: **30037/s**, against the write-through hardware baseline
`18292.7/s` — **+64 %**. This matches the 2026-07-28 copyback measurements (30000.0 / 30037.5 /
29813.7) to within noise, so the number survives the removal of the dbg overlay: the speed was never
an artifact of instrumentation. `dhry` reads its run count from **stdin**, not argv.

## What is still open

The power-cut disk-truth run (`REALHW-COPYBACK-POWERCUT-260730.md`) — the one thing copyback has
never been asked. A clean reboot lets shutdown's `sync` rescue dirty D-cache lines; a power cut does
not.
