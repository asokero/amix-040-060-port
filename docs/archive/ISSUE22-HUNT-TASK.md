# TASK for Codex — ISSUE-22: which path returns EFAULT to `read(2)` without a failed page-in?

Requested deliverable: an analysis note in `amix-kernel-analysis/vm-map/`, suggested name
`ISSUE22-EFAULT-SOURCE.md`. Do not patch the kernel.

This is a narrow question with strong runtime evidence behind it, not a general "find ISSUE-22".

---

## Provenance

```text
kernel repo HEAD                 206f32f (this brief adds documentation only)
build/unix-040                   68040-260728-34
build/unix-040-dbg               68040-260728-35   + the new exit probe
build/unix-040-b2-dbg            68040-260728-36   same, hat_cm_ram = 0x20 (copyback)
```

`-35` and `-36` differ in the `hat_cm_ram` flip plus the build-id characters. `-34/-35` add only the
ISSUE-22 exit probe over `cc9049d`, which your XPAGE audit was pinned against.

---

## 1. What changed since your audit: ISSUE-22 now has a reproducer

Your audit said ISSUE-22 "still needs its own latch if it reappears". It has reappeared, on demand:

| kernel | difference | `cp: /payload.bin: read: Bad address` |
|---|---|---|
| **copyback `260728-32`** | — | burst **4**, then burst **1** on a clean repeat (2 of 2 runs) |
| **write-through `260728-28`** | **3 bytes** | **clean 16/16, 96 verifications** |

Counting two earlier write-through runs, that side stands at **3 runs / 288 verifications with zero
hits**, while copyback failed in **both** of its runs inside the first four bursts. Workload:
`test-tools/b2repro-copy.sh 16` — six concurrent 4 MiB copies of `/payload.bin` per burst, then
`b2verify` on each. Same cold boot, same harness, same day, same machine.

Copyback is confirmed **in effect** by measurement, not inference: Dhrystone `30000.0`, `30037.5`,
`29813.7` /s across three boots versus the write-through baseline `18292.7`.

Two things follow. Copyback does not appear to *create* the defect — July established ISSUE-22 as
kernel-independent, and its write-through baseline hit it too — but it **amplifies it enormously**.
And that makes copyback the trigger ISSUE-22 never had (it was "1 case in 48 parallel copies", and
five cold-boot cycles in July could not reproduce it at all).

---

## 2. The observation that makes this a narrow question

**The `as_fault` FAIL logger printed ZERO lines during both copyback hits.** Its cap is 64 and it was
unused, so the absence is meaningful rather than exhausted: it logs *every* nonzero `as_fault`
return, from every caller, because it lives in the weakened `as_fault` wrapper.

By your own route analysis, EFAULT reaches user space through `sf_fault @0x5f2`, which is entered
only when the **resolver returns nonzero** (`k_trap` replaces the saved PC with the landing pad).
So:

> **something returned "unresolved" to `k_trap` without any `as_fault` call having failed.**

In our own `krnxmemflt040` there are exactly three failure exits, and **two never call `as_fault`**:

```text
line 56   depth/recursion cap exceeded (depth > 4)        -> no as_fault call
line 80   "no kas segment owns this address"              -> no as_fault call
line 139  as_fault itself failed (F_PROT branch)          -> WOULD be logged
```

`-35`/`-36` now carry a probe that names which one fires:

```text
DBG krnxflt FAILEXIT w=<1|2|3> va=<x> rw=<1|2> depth=<n>
    w=1 depth cap   w=2 no kas segment   w=3 as_fault failed (cross-check: must also appear in FAIL)
```

Verified silent on a healthy boot, capped at 8 prints.

---

## 3. What we need from you

Our side of the resolver is enumerable by reading our own source, and it is done above. **Your side
is the stock binary and the paths we cannot read as easily.**

1. **In stock `usrxmemflt_orig` (0x5aede) and the `hardbus` wrapper: which paths return nonzero
   WITHOUT calling `as_fault`?** A read(2) copies segmap → user, so both resolvers are in play: the
   segmap source is a supervisor-TM fault (→ `krnxmemflt`) and the user destination is user-TM
   (→ `usrxmemflt`). We have named our own exits; please name theirs, byte-exact, so the probe can
   be extended to them in one edit rather than by trial.
2. **Are there EFAULT sources on the `read(2)` path OUTSIDE the fault machinery entirely?**
   `uiomove`/`copyout` bounds checks, `useracc`-style validation, a filesystem or driver returning
   EFAULT directly. If one of those can produce `read: Bad address` under pressure, the whole
   fault-path framing above is the wrong tree and we would rather learn that from you than after
   another five hardware runs.
3. **★ The question we consider most valuable: WHY does copyback amplify it?** What in the B2
   configuration increases either the fault rate or the chance of hitting one of those gates?
   Candidates we can see but cannot weigh: `dma_cache040`'s ownership protocol (prepare = `cpusha`,
   complete = range `cinvl`) leaving wider windows where a PTE or ATC entry is transiently absent;
   `cb_release040`'s per-page `cpushl` sweep on page free; `hat040`'s `Lhl_dofree` reordering
   (leaf-clear + `cpusha` + `pflusha` **before** `page_free`). If one of these creates a window in
   which a resolver gate legitimately says "unresolved", that is both the ISSUE-22 mechanism and the
   copyback amplification in one answer.
4. **Is the depth cap of 4 legitimately reachable** in the resolver chain under this workload
   (nested faults inside a fault, e.g. resolver → page allocation → another fault), or would
   reaching it always indicate a prior defect? This decides whether the fix is "raise/remove the
   cap" or "stop the nesting".

## What makes a good answer

* Byte-exact sites for (1), in the form your ISSUE-36 note used — that answer was directly usable
  and it is why that fix was four instructions.
* (3) answered as a mechanism, even if the confidence is medium: a named window is testable, and we
  have a workload that fires in the first burst.
* An explicit statement if the fault-path framing is wrong. Two of today's five instrument failures
  were caused by trusting a frame that could not detect its own precondition, and we would rather
  discard this one early than defend it.

---

## 4. Context you may want, briefly

* **ISSUE-37 is closed**: the 68040 reports a misaligned access's START address while the missing
  page is the next one. Your audit's six-item unit is landed (`cc9049d`), MA-based with the proven
  address window kept as a second tier, and wolf3d — which wedged the machine on three kernels —
  now runs. The 040 regression was re-verified on hardware with the serial instrument **bracketed**
  before and after, after an identical 0-byte reading earlier that day turned out to be a dead
  capture.
* **ISSUE-36 is closed**: your predicate confirmed exactly, including 2048 failing and 2049 passing.
* **Copyback's own acceptance is complete**: reboot disk-truth PASS (6 × 4 MiB, byte-exact, same
  kernel, reboot proven by uptime), and the `pl[]` probe found no violation on either body — which
  your note predicted for a tail-fault workload. **ISSUE-22 is the only thing between us and a
  measured +63 % machine.**
