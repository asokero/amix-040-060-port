# RESUME HERE — the ISSUE-22 hunt, starting state as of 2026-07-28 (kernel HEAD 46f9dca)

Read this file and nothing else to start the hunt. Everything below is measured, not inferred, and
the two places where that is not true are marked.

---

## 1. Why this is now the top item

**ISSUE-22 is the only thing between this port and a measured +63 % machine.** Copyback's own
acceptance is complete — reboot disk-truth PASS, the July corruption scare explained, Dhrystone
30000/s vs 18292.7 write-through, three boots within 0.7 % — and the single remaining objection to
flipping it is that **copyback multiplies ISSUE-22's frequency**:

| kernel | 3-byte difference | `cp: /payload.bin: read: Bad address` |
|---|---|---|
| copyback `260728-32` | `hat_cm_ram = 0x20` | burst 4, then burst 1 on a clean repeat (2/2 runs) |
| write-through `260728-28` | `hat_cm_ram = 0x00` | clean 16/16, and 3 runs / 288 verifications total |

## 2. The reproducer — this is the part that changed everything

ISSUE-22 was "1 case in 48 parallel copies" and five cold-boot cycles in July failed to reproduce it.
**On copyback it fires within the first four bursts, every time.**

```text
boot  build/unix-040-b2-dbg = 68040-260728-36   (copyback + the exit probe)
mount -F nfs nasu:Public /mnt/nasu
cp /mnt/nasu/amix/hwtest-260728/b2verify.c /mnt/nasu/amix/hwtest-260728/b2repro-copy.sh /tmp/
cd /tmp && cc -o b2verify b2verify.c            # /tmp is cleared by every boot
sh b2repro-copy.sh 16 hunt
```

It stops on the first non-V0 and preserves state. Expect the failure inside four bursts. Do **not**
log in or browse the filesystem while it runs: the first copyback run was invalidated exactly that
way, and the write-through comparisons had no such load.

## 3. What the failure looks like, and what it is NOT

```text
cp: /payload.bin: read: Bad address          <- the EFAULT, from read(2)
B2V ... CLASS=SOURCE_ERROR dst=/cp2.bin stat_errno=2   <- CONSEQUENCE: cp died, so the file is absent
```

* **Not corruption.** In the same burst, `cp1` verified as a complete byte-exact match. What gets
  written lands intact; an operation aborts.
* **Which read the EFAULT hits is chance** — `cp`'s read of the source in one run, the verifier's in
  another. July recorded the same.
* `V1_*` classes are this same transient, with the file intact on reopen. `V3`–`V6` would be
  something else and worse; nothing has ever produced one.

## 4. The measurement that makes the question narrow

**The `as_fault` FAIL logger (cap 64, in the weakened `as_fault` wrapper, logs every nonzero return
from every caller) printed ZERO lines during both copyback hits.**

EFAULT reaches user space through `sf_fault @0x5f2`, which is entered only when the **resolver**
returns nonzero — so something returned "unresolved" to `k_trap` **without any `as_fault` call having
failed**. In our own `krnxmemflt040` exactly three exits return failure and **two never call
`as_fault`**:

```text
line 56   depth/recursion cap exceeded (depth > 4)
line 80   "no kas segment owns this address"
line 139  as_fault failed (F_PROT branch)  <- this one WOULD be logged
```

## 5. The probe is already built and verified silent

`68040-260728-35` (WT) and `-36` (copyback) carry it:

```text
DBG krnxflt FAILEXIT w=<1|2|3> va=<x> rw=<1|2> depth=<n>
     w=1 depth cap    w=2 no kas segment    w=3 as_fault failed
```

Cap 8 prints. **Silent on a healthy 040 boot (verified).** One reproducer run should name the exit.

**Bracket the serial capture** — verify it before AND after the run by firing a deliberate
`kill -9` (which must print `DBG SIG sig=9`) and checking the log grew. Today an identical 0-byte
reading came from a dead capture and was nearly recorded as the strongest possible result. Capture as
`cat /dev/ttyUSB0 | tee -a /tmp/amix-hw-test.log` so it survives a terminal.

## 6. If the probe stays silent, the framing is wrong — go here next

That would mean the resolver never reported failure, and EFAULT came from outside the fault
machinery: `uiomove`/`copyout` bounds checks, `useracc`-style validation, or a filesystem/driver
returning EFAULT directly. `ISSUE22-HUNT-TASK.md` asks Codex exactly that as its question 2, so check
their answer before building a second probe.

## 7. Codex is working on four questions (`ISSUE22-HUNT-TASK.md`)

1. Which paths in stock `usrxmemflt_orig` (0x5aede) and `hardbus` return nonzero without calling
   `as_fault` — byte-exact, so the probe can be extended in one edit.
2. Whether `read(2)` has EFAULT sources outside the fault machinery at all.
3. **★ Why copyback amplifies it** — candidates: `dma_cache040`'s prepare=`cpusha` /
   complete=range-`cinvl` protocol, `cb_release040`'s per-page `cpushl` sweep, `hat040`'s
   `Lhl_dofree` reorder (leaf-clear + `cpusha` + `pflusha` before `page_free`). A named transient
   window would be both the mechanism and the amplification in one answer.
4. Whether depth 4 is legitimately reachable, which decides "raise the cap" versus "stop the
   nesting".

## 8. Two things NOT to redo

* **Do not re-run the write-through comparison** unless a fix lands: 3 runs / 288 verifications
  clean is already recorded.
* **Do not re-run copyback's acceptance items**: reboot disk-truth PASS, `pl[]` no violation on
  either body (Codex predicted that for a tail-fault workload), Dhrystone measured three times.

## 9. Artifacts (`nasu:Public/amix/hwtest-260728/`, names carry the build id)

```text
unix-040-b2-dbg-260728-36    copyback + exit probe   <- the hunt kernel
unix-040-dbg-260728-35       write-through + probe   <- control
unix-040-260728-34           base, no probes
unix_boot040                 MANDATORY loader
b2verify.c b2repro-copy.sh b2reboot-truth.sh COPYBACK-RUNSHEET.txt
```

`uname -m` is the only reliable identifier — the filenames in `build/` never change.

## 10. Marked as inference, not measurement

* That the depth cap or the no-kas-segment exit is the source is a **hypothesis**; the probe exists
  to test it and may refute it.
* That copyback's cache-management hooks create the window is a **candidate list**, not a finding.
* July's "ISSUE-22 is kernel-independent" is a July measurement; today's data shows a strong
  kernel-dependence in *frequency*, which is not the same claim and does not contradict it.
