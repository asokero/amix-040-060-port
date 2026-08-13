# Acceptance run — ISSUE-22's natural-rate confirmation AND copyback's pressure suite, in one go

One run answers both questions, because they are the same run: copyback's pressure suite is exactly
the workload whose historical ISSUE-22 rate (~1 EFAULT per 15 bursts) is the number the fix has to
beat. Codex's acceptance list for the DFC fix ends with the same item ("run the normal copyback
pressure suite after injection proves causality", `vm-map/ISSUE22-DFC-ARCH-STATE-AUDIT.md`).

## Boot

```text
unix-040-b2-dbg-260729-06    copyback + DFC/SFC contract + counters + injection (inert)
sha256 fc42939b63b0afcbcb51b9949cc3f75947bcce0646f7dd139f24fa8f4021c375
unix_boot040                 MANDATORY loader
```

**On a FRESH boot.** Yesterday's control run was slowed by memory pressure left behind by earlier
cofault runs: the baseline burst cost was identical (~120 s) but stalls of 300–900 s appeared five
times in eleven bursts. That is a property of the machine's state, not of the kernel, and it makes
timings incomparable.

Also on the NAS, for the record and for a WT control if one is ever needed:
`unix-040-260729-04` (base, silent) and `unix-040-b2-260729-07` (copyback, no probes).

## What changed since the last acceptance

1. **DFC is preserved across a fault** — the ISSUE-22 root cause, proven by injection on
   `260729-03`: with the fix off an injected `DFC=5` aborted a 1 MiB read at zero bytes with
   errno 14 and printed the exact ISSUE-22 signature; with it on, forty injections were absorbed
   inside one read that completed byte-complete.
2. **SFC is preserved the same way** — Codex found `ptest040.s:52` leaking it with no victim path
   today. The write is deliberately kept (it is hardware insurance against DFC/SFC ambiguity on
   real silicon); the wrapper now makes the leak harmless. `wb_sfc_changed` measures whether it
   ever actually differs.
3. **The reroute band-aid is gone** and the `DBG userspace ODD` lines are gated on `btrace_on`, so
   the base and quiet kernels are silent. The counters stay as regression detectors.

## The run

```text
mount -F nfs nasu:Public /mnt/nasu
cp /mnt/nasu/amix/hwtest-260728/{b2verify.c,b2repro-copy.sh,kpeek.c,kpoke.c} /tmp/
cd /tmp && cc -o b2verify b2verify.c && cc -o kpeek kpeek.c && cc -o kpoke kpoke.c

serial bracket:  sleep 120 & p=$!; sleep 2; kill -9 $p     -> must print DBG SIG sig=9
baseline:        /tmp/kpeek 080FFDE0 3 ; /tmp/kpeek 080FFF04 11 ; /tmp/kpeek 080FFFB4 4
the run:         sh b2repro-copy.sh 16 accept
counters again:  same three kpeek lines
```

Counter addresses in **260729-06** (`0x08000000 + textsize + .data offset`):

```text
us_calls 080FFDE0  us_odd_user 080FFDE4  us_odd_kern 080FFDE8
wb_dfc_on 080FFF04  wb_dfc_n 080FFF08  wb_dfc_changed 080FFF0C
wb_dfc_lastold 080FFF10  wb_dfc_lastnew 080FFF14
wb_replay_n 080FFF18  wb_replay_odd 080FFF1C
wb_dfc_force 080FFF20  wb_dfc_force_n 080FFF24  wb_dfc_forced 080FFF28
wb_sfc_changed 080FFF2C
Lkx_fn 080FFFB4  xpage_on 080FFFB8 (=1, ANCHOR)  Lkx_depth 080FFFBC
```

## Pass criteria, and what each one is worth

| observation | meaning if it holds | meaning if it fails |
|---|---|---|
| `B2REPRO-COPY CLEAN (0 non-V0 in 16 bursts)` | 96 verifications, no EFAULT — copyback's pressure suite passes and ISSUE-22 did not fire | a `V1_*` class is an ISSUE-22 EFAULT: the fix is incomplete, capture and stop |
| `us_odd_user = 0` | no misroute occurred at all — stronger than "no failure", since this counts the event and not its symptom | any nonzero value means a misroute happened; read the serial `ODD`/`FAILEXIT` lines |
| `wb_dfc_changed` > 0 | the fix did real work: that many corruptions were caught and repaired during the run | **zero means the run proves nothing** — no corruption occurred, so nothing was tested |
| `Lkx_fn = 0` | no resolver failure exit was taken | nonzero with a silent serial log = the capture died, not a clean run |
| `wb_dfc_forced = 0` | injection stayed inert, as it must in an acceptance run | nonzero = something poked it; the run is void |
| `wb_sfc_changed` | just a measurement of Codex's latent SFC finding — any value is informative | — |

**The third row is the one that makes this run meaningful.** A clean 16-burst run on its own is weak
evidence, because yesterday's control run was clean too with the bug active. `wb_dfc_changed > 0`
plus `us_odd_user = 0` is the pair that says the hazard occurred and was neutralised.

## Not re-run, deliberately

* **Reboot disk-truth** — PASSED at 46f9dca on the same copyback configuration; the DFC/SFC contract
  touches no disk path.
* **Dhrystone** — copyback measured three times (30000.0 / 30037.5 / 29813.7 /s vs the write-through
  baseline 18292.7). A few instructions per page fault cannot move a CPU benchmark, and there is no
  dhrystone binary on the machine.
* **The write-through comparison** — 3 runs / 288 verifications clean is already recorded.
