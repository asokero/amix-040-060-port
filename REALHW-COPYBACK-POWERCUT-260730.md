# Copyback power-cut disk truth — ✅ PASSED 2026-07-31, on the shipping kernel

> **RESULT: `B2RT-RESULT PASS (6 files, every byte intact)`.** Six 4 MiB files written and synced on
> `68040-260730-03`, then the power was cut with no shutdown and no further sync. The machine came
> back on the same kernel, fsck ran and repaired the expected unclean-UFS damage, and every one of
> the six files verified `V0_COMPLETE_MATCH size=4194304 crc=50250` — the same CRC the write phase
> recorded, read back byte for byte. Nothing landed in `lost+found`, no file was short.
>
> The reboot boundary is evidenced, not assumed: the write phase ran at uptime ≈ 1 h 23 min, the
> verify phase at uptime 1 min, and the verify script's own kernel-identity check (which fails
> closed) passed. `hat_cm_ram` read `0x20` on both sides, so it was copyback that wrote and copyback
> that read. After the cold boot `cb_icode_calls` / `cb_icode_push` read 1 / 1 again — the ISSUE-38
> fix fires once per boot as designed — and `cb_rel_reject` / `dma_cmpl_noprep` were both 0.
>
> **This was copyback's last unanswered question.** Write-through had passed it twice (B1 7/7, and
> 8/8 on 2026-07-27); copyback had never been asked. It has now been asked and answered on the image
> that ships.

## Original run sheet (2026-07-30)

Supersedes the kernel identity in `REALHW-COPYBACK-POWERCUT-260729.md`; the *reasoning* in that
file still stands and is not repeated here. Short version: a clean reboot lets shutdown's `sync`
rescue anything still sitting in a dirty D-cache line, and a power cut does not — so this is the one
question copyback has never been asked. Write-through has passed it twice (B1 7/7, and 8/8 on
2026-07-27).

## Kernel — the same image in BOTH phases

```text
unix-040-b2-fix38-260730-03      copyback, no probes, ISSUE-38 fix   <- the machine is on this now
```

Its content is byte-identical to `unix-040-cb-default-260730-06` (the copyback-by-default base)
except for one build-id character, so testing `-03` covers the shipping artifact.

**Boot the same file both times.** `b2reboot-truth.sh verify` fails closed on a kernel mismatch —
`uname -m` must read ` 68040-260730-03` in both phases — because otherwise it would measure one
kernel's writes through another kernel's reads. `/b2dt` survives, so a wrong boot costs a reboot,
never the write phase.

## The run

```sh
# --- phase 1, on -03 ---------------------------------------------------------
uname -m                                  # must print 68040-260730-03
mount -F nfs nasu:Public /mnt/nasu
cp /mnt/nasu/amix/hwtest-260728/b2reboot-truth.sh /tmp/
cd /tmp && sh b2reboot-truth.sh write     # 6 x 4 MiB into /b2dt, syncs twice
                                          # (b2verify is already built in /tmp)

# --- the boundary ------------------------------------------------------------
# wait for the disk to go quiet a few seconds after B2RT WRITE-DONE, then
# CUT THE POWER.  No shutdown, no reboot, no sync -- that is the whole point.

# --- phase 2, after booting the SAME kernel again ----------------------------
# let fsck run; a power cut leaves UFS dirty and that is expected, not a finding.
uname -m                                  # must print 68040-260730-03 again
mount -F nfs nasu:Public /mnt/nasu
cp /mnt/nasu/amix/hwtest-260728/{b2verify.c,b2reboot-truth.sh} /tmp/
cd /tmp && cc -o b2verify b2verify.c      # /tmp is wiped by every boot; ~2-3 min
sh b2reboot-truth.sh verify
```

## Reading the result

| output | meaning |
|---|---|
| `B2RT-RESULT PASS (6 files, every byte intact)` | copyback's write path survives an unclean stop |
| `V4_INODE_SHORT` / `V5_DATA_MISMATCH` / `V6` | a real copyback disk-truth defect — capture everything and stop |
| `V1_EFAULT_TRANSIENT` | transient read fault, file intact on reopen: ISSUE-22's old signature, which the DFC fix in this kernel should have removed. If it appears, it is worth seeing |
| `B2RT ABORT: kernel MISMATCH` | the machine came back on another kernel. Boot `-03` and re-run verify; `/b2dt` is intact |
| files gone | fsck moved them to `lost+found`, which is itself the finding |

What this does not test: data written but never `sync`ed, which any OS may lose. The write phase
syncs twice and waits, so the subject is data the system has already promised to have written.

## Timeouts, as a courtesy to the next session

The native `cc` needs more than 120 s for `b2verify.c`. `real.py`'s per-command sentinel timeout now
comes from `AMIX_CMD_TIMEOUT` (default 120) and it sends `^C` to the remote shell when it fires, so
run the compile as `AMIX_CMD_TIMEOUT=900 python3 real.py '...'` rather than letting the driver
interrupt a compiler halfway.
