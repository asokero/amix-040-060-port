# ISSUE-40 criteria 4 and 5 — long-run sheet (2026-08-02)

Kernel `unix-040-260802-01` (both halves), **clean boot**. NAS: `amix/hwtest-260802b/`.
Criteria 1–3 are already met on hardware (`REALHW-ISSUE40-CLOSED-260802.md`); this session closes
the two that need wall clock.

A clean boot matters here: the counters start at zero, `availrmem` starts at its boot high-water
mark, and the bucket series is then directly comparable with the 2026-08-01 run that started all
of this.

## What is being compared

On `68040-260801-04`, four consecutive 16-burst suites with no reboot gave `availrmem` in
ten-minute buckets:

```text
3981 → 3698 → 3405 → 3128 → 2891 → 2690 → 2450 → 2235 → 2035 → 1847
```

~21 pages/min, no recovery in 100 minutes, while the identical suites inflated
**24m37s → 27m03s → 34m56s → 45m56s** (+87 %). Data integrity was 96/96 throughout — the failure
was pure resource decay.

**Pre-registered prediction:** with both halves the bucket series stays flat, the four suite
wall-clocks stay within a few minutes of one another, and `good_sums` is 96 every suite. The suite
*times* are the strongest signal in the whole session, because they depend on none of our counters.

## Steps

```sh
# 0. clean boot of unix-040-260802-01 (NAS amix/hwtest-260802b/, sha in SHA256SUMS-260802b.txt)

# 1. NAS + copies (does not survive a boot)
mount -F nfs nasu:Public /mnt/nasu
cp /mnt/nasu/amix/hwtest-260802b/*.c  /tmp/
cp /mnt/nasu/amix/hwtest-260802b/*.sh /tmp/
cp /mnt/nasu/amix/hwtest-260802b/hat_dup_cow /tmp/ && chmod +x /tmp/hat_dup_cow
cp /mnt/nasu/amix/hwtest-260802b/payload.bin /            # burst4.sh reads /payload.bin

# 2. compile everything ONCE, detached (13 binaries; one cc per driver call is
#    13 chances to time out mid-compile)
nohup sh /tmp/mkall.sh > /tmp/mkall.log 2>&1 &
#    ... wait for MKALL-DONE in /tmp/mkall.log

# 3. criterion 4 — the battery, detached (~10 min)
nohup sh /tmp/batteryrun2.sh > /dev/null 2>&1 &
#    ... read /tmp/battery2.log, wait for BATTERYRUN2-DONE

# 4. criterion 5 — four suites, ~100 min, detached
nohup sh /tmp/burstrepeat2.sh 4 > /dev/null 2>&1 &
#    ... read /tmp/burstrepeat2.log and /tmp/memwatch-repeat2.log
```

Both scripts read their own counters and write their own logs, so a driver timeout can never leave
the post-run state unread. `burstrepeat2.sh` refuses to start unless `ptd_magic` reads `50544421`.

## Address table — `unix-040-260802-01` ONLY (textsize `0xe4868`)

| block | address | contents |
|---|---|---|
| `ANCH` | `0x080FCB68` | `hat_cm_ram`, must read `0x20` |
| `CB` | `0x080FD230` | `cb_rel_count`, `cb_rel_reject`, +2 |
| `KD` | `0x080FD24C` | `hat_pfnmiss_n`, `hat_badaslot_n`, `hat_sdtfail_n` |
| `I39` | `0x080FD27C` | `i39_magic` + pointer table (also `memwatch`'s argument) |
| `PTD` | `0x080FD2E8` | `ptd_magic` … `ptd_tblfreed_n`, 11 longs |

## What each result means

* **`availrmem` bucket series flat** → criterion 5 met, and the original observation is explained
  end to end.
* **suite times flat** → the +87 % inflation was a consequence of the leak, not something separate.
* **`good_sums` 96 per suite** → no data-integrity regression from the new teardown path.
* **`ptd_keep0_n`, `ptd_keepn_n`, `ptd_meta_n`, `ptd_badlink_n` all still 0** after ~100 minutes of
  heavy fork/exec/copy load → the ownership gate holds under pressure, not just at boot.
* **`ptd_wake_n` > 0** would be the first time the `pt_waiting` path has ever been exercised: it
  means `hat_ptalloc` actually slept on `free_pts` and our release woke it. Worth noting either way;
  zero is expected and fine.
* **`hat_sdtfail_n` (ISSUE-39)** — a nonzero here is the known race, not a new fault.

## If the bucket series still declines

Then something else leaks too, and the next question is *what shape*: read `ptd_pgfreed_n` per
suite. If it keeps rising while `availrmem` falls, pages are being returned and something else is
taking them — a different owner, not this one. That distinction is why the per-suite `ptd` block is
in the log.
