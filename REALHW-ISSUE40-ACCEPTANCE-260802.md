# ISSUE-40 acceptance complete — all five criteria met on hardware

**2026-08-02, A3000 + Mercury 68040, clean boot of `68040-260802-01`** (sha256 `3727e5b4…`,
textsize `0xe4868`). Criteria 1–3 were met earlier the same day
(`REALHW-ISSUE40-CLOSED-260802.md`); this run closes 4 and 5. Logs on the NAS in
`amix/hwtest-260802b/`: `battery2.log`, `burstrepeat2.log`, `memwatch-repeat2.log`, `mkall.log`.

The clean boot was the point: counters start at zero and `availrmem` at its boot high-water mark, so
the bucket series compares directly with the 2026-08-01 run that started all of this.

## Criterion 4 — battery 10/10

```text
proctest      PASS (10 sub-tests, fails=0)     bigargv       PASS 45 args 4500 bytes
fputest       PASS 040 hardware FP correct     ptracepoke    PASS pokes=4 fails=0
mlocktest     PASS fails=0 skipped=0           bmaptest      PASS fails=0
msynctst      MSYNC-OK 65536                   devmaptest    PASS fails=0
mincoretst    PASS                             exectest 20   PASS
```

Instruments either side: `hat_pfnmiss_n` `0x0a → 0x0c` = **exactly +2**, from `devmaptest` and
nothing else; `cb_rel_reject` 0; `hat_sdtfail_n` 0; and after 4555 `ptdat` retirements
`ptd_keep0_n = ptd_keepn_n = ptd_meta_n = ptd_badlink_n = 0`.

## Criterion 5 — the decline is gone

Four consecutive 16-burst suites, no reboot, `memwatch` every 2 s, 1955 samples over 65 minutes.
`availrmem` in ten-minute buckets:

```text
bucket      n    min    max   mean      2026-08-01 mean (68040-260801-04)
 0-10 min  300  6903   7066   6953           3981
10-20 min  300  6907   6981   6950           3698
20-30 min  300  6907   6969   6944           3405
30-40 min  300  6918   6972   6944           3128
40-50 min  300  6898   6969   6945           2891
50-60 min  300  6897   6966   6942           2690
60-70 min  155  6897   6970   6939           2450 … down to 1847 at 100 min
```

**Total drift: 14 pages of mean across 65 minutes**, i.e. ~0.2 pages/min against the original
**~21 pages/min**. The min/max bands overlap completely across every bucket (6897–7066 throughout),
and the 40–50 min mean is *higher* than 30–40: this is noise, not a trend. The old series had every
bucket lower than the last, with both min and max falling.

And the independent signal — suite wall-clocks, which depend on none of our counters:

```text
             2026-08-02          2026-08-01
suite 1      17m21s              24m37s
suite 2      16m32s              27m03s
suite 3      16m38s              34m56s
suite 4      17m02s              45m56s   (+87 % across the run)
```

**Flat within 50 seconds**, and the slowest is suite 1 — cold caches, not decay. That settles the
open question of whether the +87 % inflation was a separate problem: it was a consequence of the
leak. (The absolute level is also better than the old first suite, but those runs started from
different `availrmem` levels on different kernels, so the honest claim is the *shape*, not the ratio.)

Data integrity: `good_sums = 96` in every suite, 4/4.

## The new teardown path under an hour of load

```text
                pfnmiss  badaslot  sdtfail | ptd_calls  retired  pgfreed  k0 kN meta bl wake
after suite 1        12        49        0 |    19363    19363      137   0  0    0  0    0
after suite 2        12        61        0 |    33826    33826      185   0  0    0  0    0
after suite 3        12        73        0 |    48457    48457      207   0  0    0  0    0
after suite 4        12        86        0 |    62989    62989      236   0  0    0  0    0
```

**62 989 `ptdat` retirements, every one clean.** `ptd_calls == ptd_retired_n` at every checkpoint —
the ownership gate never once failed closed under sustained fork/exec/copy pressure, and
`ptd_badlink_n = 0` means every one of those retirements verified reciprocal links on all four
records before touching either list. Boot-time evidence was already good; this is the same result at
63k events.

`hat_pfnmiss_n` did not move at all during the burst run (12 throughout) — the calibration holds on a
third kernel. `hat_sdtfail_n` stayed 0 even though `freemem` touched 0 in six of the seven buckets,
which is consistent with ISSUE-39 being a race that needs a call to land in that window, not plain
depletion.

**`ptd_wake_n = 0`.** The `pt_waiting` path still has never fired, in any run. `hat_ptalloc` can
sleep on `free_pts` under `HAT_CANWAIT` and our release wakes it, but nothing has yet driven the
machine into that state — so that branch remains correct-by-construction and unexercised. Worth
saying plainly rather than counting it as tested.

## All five criteria, pre-registered 2026-08-01

| # | criterion | status |
|---|---|---|
| 1 | `leaktest 300 1` leaves all three counters flat | **MET** — exactly 0, twice |
| 2 | `availrmem + pages_pp_kernel` conserved | **MET** — 7729 throughout, every run |
| 3 | `leaktest 300 0` (fork) behaves as before | **MET** — 0, twice |
| 4 | battery 9/9 + burst 96/96, `hat_pfnmiss_n` +2 | **MET** — 10/10, 96/96 ×4, +2 exactly |
| 5 | no ~21 pages/min drift under load | **MET** — ~0.2 pages/min, suite times flat |

**ISSUE-40 is closed.** The fix is two units: `prototypes/legacysdt040.s` (the legacy-SDT lifetime
edge, which alone returned zero pages) and `prototypes/ptdatfree040.s` + `hat_ptfree` V3 (the
one-unit `ptdat` metadata lifetime, which is what actually frees the backing page). Neither contains
a compensating write to `availrmem`, `availsmem` or `pages_pp_kernel`.

## Two things left open, deliberately

* **`sh: no space`** — `issue40e.sh` died reproducibly on the machine right after its anchor block
  while `freemem` was 5342 pages and `leaktest` ran with zero fork failures. Not root-caused, logged
  in `REALHW-ISSUE40-CLOSED-260802.md`. The same script shape ran fine the day before on
  `68040-260801-12`, so a same-script two-kernel A/B is the cheap probe if it ever matters. Nothing
  in this acceptance depended on it: every run here was either host-driven or used the plain-loop
  scripts, which work.
* **`ptd_wake_n` unexercised**, as above.

## Artifacts

```text
kernel    build/unix-040   68040-260802-01   textsize 0xe4868
          sha256 3727e5b4b162a8a73a9d04475882213e52411012c02db5c1742af19676cbdd25
units     prototypes/legacysdt040.s, prototypes/ptdatfree040.s, hat040.s (hat_free + hat_ptfree V3)
contracts vm-map/ISSUE40-LEGACY-SDT-TEARDOWN-CONTRACT.md, vm-map/ISSUE40-PTDAT-TEARDOWN-CONTRACT.md
records   ISSUE40-LEGACY-SDT-LANDED-260801.md, REALHW-ISSUE40-PART1-260801.md,
          REALHW-ISSUE40-CLOSED-260802.md, this file
scripts   test-tools/{mkall.sh,batteryrun2.sh,burstrepeat2.sh}, README-I40-LONGRUN.md
logs      NAS amix/hwtest-260802b/{battery2.log,burstrepeat2.log,memwatch-repeat2.log,mkall.log}
```
