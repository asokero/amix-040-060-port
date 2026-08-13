# Copyback power-cut disk truth — the last thing I would want before flipping the default

## Why this one and not another burst run

A clean reboot lets the kernel tidy up after itself: the shutdown `sync` gets a chance to push
anything still sitting in a dirty D-cache line. A power cut does not. With copyback that is exactly
the question worth asking — after `sync` returns, is the data on the platter, or only in a cache
line that a well-behaved shutdown would have rescued?

Write-through has passed this twice (B1 7/7, and 8/8 in the 2026-07-27 acceptance). **Copyback has
never been power-cut tested.** It is not on the recorded acceptance list; this is my recommendation,
not a documented requirement.

## Kernel: the one that would actually ship

```text
unix-040-b2-260729-07     copyback, NO probes   <- boot this
sha256 c63b89a198965597782f919b6c85aaf65b9ec5c08ce4f5df365e34e28c8dac02
unix_boot040              MANDATORY loader
```

This kills a second bird: today's acceptance ran on the **dbg** kernel `-06`, so the image intended
for actual use has never been booted anywhere — not even in the emulator, where the smoke test
loaded `-05`. If `-07` boots, runs the test and passes, the shipping artifact is covered too.

**The same kernel must be running for both phases.** The verify phase fails closed on a kernel
mismatch, because otherwise it would measure one kernel's writes through another kernel's reads. So
either set `-07` as the startup-sequence default, or boot it by hand both times. `/b2dt` survives,
so a wrong boot costs only a reboot, never the write phase.

## The run

```sh
# --- phase 1, on -07 ---------------------------------------------------------
uname -m                                  # must print 68040-260729-07
mount -F nfs nasu:Public /mnt/nasu
cp /mnt/nasu/amix/hwtest-260728/b2verify.c /mnt/nasu/amix/hwtest-260728/b2reboot-truth.sh /tmp/
cd /tmp && cc -o b2verify b2verify.c
sh b2reboot-truth.sh write                # writes 6 x 4 MiB to /b2dt, syncs twice

# --- the boundary ------------------------------------------------------------
# wait for the disk to go quiet (a few seconds after B2RT WRITE-DONE), then
# CUT THE POWER.  No shutdown, no reboot, no sync -- that is the whole point.

# --- phase 2, after booting -07 again ----------------------------------------
# let fsck run; a power cut leaves the filesystem dirty and that is expected.
uname -m                                  # must print 68040-260729-07 again
mount -F nfs nasu:Public /mnt/nasu
cp /mnt/nasu/amix/hwtest-260728/b2verify.c /mnt/nasu/amix/hwtest-260728/b2reboot-truth.sh /tmp/
cd /tmp && cc -o b2verify b2verify.c      # /tmp is cleared by every boot
sh b2reboot-truth.sh verify
```

## Reading the result

| output | meaning |
|---|---|
| `B2RT-RESULT PASS (6 files, every byte intact)` | copyback's write path survives an unclean stop |
| `V4_INODE_SHORT` / `V5_DATA_MISMATCH` / `V6` | **a real copyback disk-truth defect** — capture everything and stop; do not flip the default |
| `V1_EFAULT_TRANSIENT` | a transient read fault, file intact on reopen. That is ISSUE-22's old signature; with the DFC fix in this kernel it should not appear, and if it does I want to see it |
| `B2RT ABORT: kernel MISMATCH` | the machine came back on the default kernel. Boot `-07` and re-run verify; `/b2dt` is intact |
| files missing entirely | fsck moved them to `lost+found`, which is itself the finding |

Expect fsck to report and repair something after the power cut — an unclean UFS always does. What
matters is what the six files look like afterwards, not whether fsck had work to do.

## What this does not test

The buffer cache's own unwritten data. Anything written but never `sync`ed is legitimately allowed
to be lost, on any OS and any cache mode. That is why the write phase syncs twice and then waits:
the test is about data the system has already promised to have written.
