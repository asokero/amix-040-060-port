# Report + TASK for Codex — 2026-07-28: ISSUE-36 closed, ISSUE-37 root-caused, and the gap that
# found it is probably not the only one

Requested deliverable: an analysis note in `amix-kernel-analysis/vm-map/`, suggested name
`XPAGE-COVERAGE-AUDIT.md`. Do not patch the kernel.

---

## Provenance

```text
kernel repo HEAD            e17ab78
build/unix-040              68040-260728-16   base + FPSP + ISSUE-35 + ISSUE-36 + xpage
build/unix-040-dbg          68040-260728-17   + probes (pvn_probe, as_fault segment identity)
build/unix-040-rtg-dbg      68040-260728-18   + Xsvga(67) + VA2000(68)   <- the hardware runs
build/unix-040-dbg-pre36    68040-260728-13   A/B control: ISSUE-36 reverted, 5 bytes apart
```

Your ISSUE-36 pin (`260727-07`, ELF sha256 `5df4158b…`) was verified byte-for-byte before anything
was written, and `-16` differs from it only by the four immediates plus the build-id string.

---

## 1. ISSUE-36 — CLOSED, and your predicate confirmed exactly

The four-site unit landed as one fail-closed patch (`prototypes/patch_nfs_getpage.py`, 9 canaries,
refuses a half-applied image). Hardware A/B, two kernels **five bytes apart**:

| `r = size mod 4096` | OLD `260728-13` | NEW `260728-12/18` |
|---|---|---|
| 0 | PASS | PASS |
| **1 / 123 / 2048** | **SIGBUS** | PASS |
| **2049** | **PASS** | PASS |
| 4095 | PASS | PASS |
| 123 in the 2nd page of a partial 8 KiB block | **SIGBUS** | PASS |

**2048 fails and 2049 passes** — the sharp part, and it lands exactly where your static predicate
said. That also corrects our own field characterisation ("NFS mmap fails for any non-multiple of
4096"), which was wrong; upper-half remainders always worked.

Kernel side, end to end, with the fault addresses being exactly `p[size-1]` of each failing file:

```text
DBG as_fault FAIL pid=199 addr=C1039000 type=0 rw=1 ret=E05     r=1     tail offset 0x000
DBG as_fault FAIL pid=199 addr=C103907A type=0 rw=1 ret=E05     r=123   tail offset 0x07A
DBG as_fault FAIL pid=199 addr=C10397FF type=0 rw=1 ret=E05     r=2048  tail offset 0x7FF
DBG as_fault FAIL pid=199 addr=C103A07A type=0 rw=1 ret=E05     28795   tail offset 0x07A
```

Also verified on the fixed kernel: remainders all readable with **every byte matching a
host-written, never-zero pattern** and the post-EOF bytes of the tail page reading as zero (your
incomplete-initialization consequence); an **NFS-resident exposed ELF executed cold** from the
mount plus a non-exposed control; local UFS control corpus 7/7; ISSUE-35 server-side byte truth
still 6/6. Our exposure scanner independently reproduced your census: **85 of 524**.

### The `pl[]` probe: no violation on EITHER body — as you predicted

We built the detector you asked for. It had to wrap **`pvn_getpages`**, because `nfs_getapage` and
`nfs_getpage` are LOCAL symbols (`nm` shows `t`) that `--weaken-symbol` cannot intercept, and
detour-jmp instrumentation Line-F crashes on the 040. Argument layout verified from the
disassembly, not from the 3b2 source: `fp@(28)` = `pl`, `fp@(32)` = `plsz`, per-iteration provider
capacity starting at 4096 (`0xb25f8`) and becoming `caller_plsz - returned` on the last page
(`0xb261a`), exactly as your note says.

It printed **no violation on the old body or the new one**, and your own analysis explains why:
*"raw io_len=123, so even the old countdown emits one pointer."* A corpus of tail faults cannot
exercise the return-list defect. Baseline shape from UFS boot traffic, for calibration:

```text
DBG pvn n=2 cap=2 plsz=2000 off=0 p0=400AAF68 p1=400AAFA4 p2=0 p3=0
DBG pvn   poff0=0 poff1=1000 poff2=0 poff3=0        <- distinct pages, count == cap
```

So the countdown half of the four-site unit stands on the source contract plus one disassembly
fact we confirmed independently: the fill loop stores the pointer **before** following `p_next`
(`0x8b262`–`0x8b26c`) and SVR4 page lists are **circular**, so the byte countdown is the loop's
only bound. **Open question for you (secondary):** what workload would exercise it? Our reading is
large sequential reads of an NFS-resident file (full 8 KiB clusters), not tail faults — confirm or
give the right one, and we will run the probe against it.

---

## 2. ISSUE-37 — root-caused and fixed, and the way it was found is the point

**The 68040 reports the fault address of a MISALIGNED access as where the access STARTS, even when
the page actually missing is the NEXT one** (SSW `MA`). `krnxmemflt040` never looked at that, so it
handed as_fault the near page, as_fault resolved a page that was already resident, returned 0, the
instruction restarted and faulted identically — an **unkillable** kernel loop.

Measured, three times on hardware, three different segmap slots:

```text
0x408F4FFF   0x40A80FFF   0x40946FFF      always in-slot offset 0xFFF
```

i.e. always the **last byte of an 8 KiB segmap slot's first page** — precisely where a misaligned
access straddles into the slot's second page. Supporting: the segment is `segmap` (`s_ops` resolved
to `segmap_ops` from the loop itself), the user PC is constant at `libc.so.1+0x13088` = **`read`+4**
(libc maps at `0xC1000000`, vanilla copy not stripped, text `vaddr == file offset`), `type=0` and
`ret=0` every iteration. `as_fault(len=1)` rounds to a 4096-byte range covering only the first page,
so `segmap_fault` maps that page and never the second.

**The uncomfortable part.** This project had already found this exact property and fixed it — for
the 060. `prototypes/wb040.s`'s `wb060_xpage` cites Linux/m68k's `if (fslw & MA) addr = (addr+7) & -8`,
records a sighting with the same shape (`addr=40734FFE`, kernel VA two bytes before a page end,
`ret=0`, infinite loop), and ends:

```text
| Gated on fmt-4: on the 040 the byte-wise replay already covers this.
```

That sentence is the defect. The replay covers **write-backs**; a **read** access error never
reaches it. Fix (`prototypes/krnxmemflt040.s`): after a **successful** resolve, if the fault address
lies in the last 8 bytes of its page, resolve the next page too — the same recipe and the same
8-byte window as the 060 sibling.

**Confirmed on hardware:** wolf3d, which wedged the machine on three previous kernels with 16
`as_fault REPEAT` lines to `n=0x2000`, now runs as an ordinary process (CPU time 0:14 → 0:48 →
0:57) with the machine answering a shell throughout and **zero** loop markers, bus errors or panics
in the serial log. The user reports it plays, and considerably faster than on the 030.

Worth stating because it shaped the search: **76 synthetic cases across six sweeps failed to
reproduce it** (offset, length, alignment, straddling, destination residency, EOF tail, both
filesystems). The trigger is a *conjunction* — misaligned, starting at a page's last byte, successor
page absent — and sweeps that vary one property at a time cannot construct one. The probe that
finally measured it also had to be rebuilt: v1 gated on consecutive `as_segat` calls with the same
address and stayed silent through a real loop, because `as_segat` has **twenty call sites** and any
other kernel-range lookup between iterations resets such a streak.

---

## 3. THE TASK — is the xpage gap anywhere else?

One instance of "handled in path A, assumed in path B" was found by accident, by a game nobody had
run since the port. That is a bad way to find the second instance.

**Enumerate every path from a fault frame to `as_fault` and state, for each, whether a misaligned
access straddling a page boundary is handled.** The axes that matter:

| axis | values |
|---|---|
| CPU / frame | 68040 format 7 · 68060 format 4 |
| mode | user fault (`u_trap`) · kernel fault (`krnxmemflt`) |
| access kind | read · write · deferred write-back |
| escape | plain · `u_nofault` set (copyin/copyout/uiomove) |

Concretely, please answer:

1. **Which of those combinations reach a resolver that adjusts for `MA` (or the last-8-bytes
   equivalent), and which do not?** Current known state: 060 fmt-4 write-back → covered
   (`wb060_xpage`); 040 kernel read → covered as of today (`krnxmemflt040`); 040 write-back →
   claimed covered by the byte-wise replay, **verify that claim rather than inherit it**; user-mode
   faults on either CPU → unknown to us.
2. **Does the 040's byte-wise write-back replay actually cover the straddling case**, or does it
   have the same hole for a write-back whose second half is on an absent page?
3. **`u_nofault` and ISSUE-22.** ISSUE-22 is a transient `read: Bad address` (EFAULT) under
   parallel copy pressure, and its recorded suspicion is *"a rare race in the fault path resolving
   a copyout buffer's fault under concurrent pressure"* — the same locus as the xpage defect. Our
   hypothesis: the two symptoms are the same defect with different escapes.
   * `u_nofault` not set (segmap access inside `read()`) → no escape → infinite loop = ISSUE-37
   * `u_nofault` set (`copyout`/`uiomove` to a user buffer) → the nofault escape returns
     **EFAULT** = ISSUE-22
   Confirm or refute from the code: on a straddling misaligned access with `u_nofault` set, does
   the path return EFAULT to the caller? If yes, today's fix should close ISSUE-22, and that
   matters beyond ISSUE-22 — ISSUE-22's transient EFAULT is the noise that made **B2/copyback** look
   guilty of disk corruption in July, so clearing it cleans the copyback flip's evidence base.
   (We are running the b2repro-copy 16-burst workload right now on the fixed kernel; at burst 9 it
   was 54/54 `V0_COMPLETE_MATCH`, where the historical failure hit at ~burst 2. Result will follow.)
4. **Is the 8-byte window right?** We copied the sibling's constant deliberately. `move16` is
   16-byte aligned by definition, but state whether any 040/060 access can straddle with a start
   further than 8 bytes from the page end (FPU extended? unaligned `movem`?).

### What makes a good answer

* A table of the combinations above with covered / not covered / not reachable, each with the
  address of the code that does or does not adjust. A "not reachable" is as valuable as a hole,
  provided the reason is given.
* For any hole: the byte-exact site and, if you can, the minimal shape of a workload that would
  hit it. We have shown we can build the workload once the shape is known — and shown that we
  cannot guess the shape from symptoms.
* Q3 answered explicitly, since it decides whether ISSUE-22 needs its own hunt at all.

---

## 4. Two other things from the same session, for the record

* **ISSUE-9 captured for the first time** since 2026-07-09, on hardware with serial running. The
  idle-time bus-error loop is **cron's nightly `uudemon.cleanu`** (parent pid 97, machine clock
  23:45, nine minutes of uptime), 4328 identical faults, corrupt cell `4AFC0000` — the signature
  this repo already predicts by name, i.e. **ISSUE-9 and ISSUE-10 are the same family**. One sample
  shows the stronger form: `pte=0`, `cell=DEADDEAD`. Not deterministic (the same script by hand ran
  clean in 8 s) and **recoverable** — `kill -9` on the looping process restored the machine, which
  distinguishes it from ISSUE-37's kernel-side loop. Evidence
  `test-tools/issue9-capture-260728.txt`. Not asking you to chase it; recording that it is now
  captured rather than folklore.
* **A reproducibility hazard we closed**: the VA2000 driver source was compiled into the kernel from
  whatever the sibling repo had checked out, with no branch or revision pinned — a `git checkout
  main` there would have silently produced a 16-bit-only driver with no build-time signal.
  Now sha256-pinned and fails closed.
