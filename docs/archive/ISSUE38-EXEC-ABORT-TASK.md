# TASK for Codex — ISSUE-38: why does exec abort under copyback when the probes are absent?

Requested deliverable: an analysis note in `amix-kernel-analysis/vm-map/`, suggested name
`ISSUE38-EXEC-HEADER-ABORT.md`. Do not patch the kernel.

Your DFC audit (`ISSUE22-DFC-ARCH-STATE-AUDIT.md`, 7c314b2) was directly usable: the wrapper scope
and the `Lwb_fail` contract were confirmed byte-exactly, the SFC sibling you found is now covered by
the same contract, and ISSUE-22 is closed — root cause fixed, proven by injection, and accepted
under the copyback pressure suite (16 bursts clean with 13 corruptions repaired under way).

This is the bug that appeared the moment we booted the image that would actually ship.

---

## Provenance

```text
kernel repo HEAD                       48ab481 + the commit that adds this file
unix-040-260729-04    base, write-through, no probes   c5d7f1808a1b5751...   BOOTS
unix-040-b2-260729-07 base, COPYBACK,      no probes   c63b89a198965597...   HANGS
unix-040-b2-dbg-260729-06  copyback + full probe overlay                     BOOTS
```

`-04` and `-07` differ in **exactly two bytes**: `hat_cm_ram` `0x00 → 0x20` at file offset 1033728,
and one build-id character. So the hang is attributable to copyback and to nothing else.

---

## 1. The symptom, and where it stops

Init never starts. The machine is not dead: with `mainmarks` linked it spins in the scheduler
printing its proc-table dump forever, so this is "no runnable process", not a lockup.

The console's last kernel line before the spin, on every hanging image:

```text
WARNING: DBG hat_unload va=48442000 size=2000 flags=A
```

`0x48442000 size=0x2000` is the **8 KiB exec-header segmap slot**. In a booting kernel that slot is
mapped and exec proceeds — the next lines are `DBG execmap vaddr=80000034 filesz=66D4 off=34 prot=D`
and then init's text faulting in at `ufault VA=800096C8`. In a hanging kernel the slot is
**released** instead and nothing follows.

**So exec aborts; it does not stall.** That is the single most useful fact we have.

Immediately around the release, two lines appear (see the provenance caveat in §4 before relying on
their ordering):

```text
DBG page_abort crash pp=400AD254 p_mapping=0 caller=80AD7DA (0=>SKIPs hat_pageunload, PTE stays)
DBG page_abort crash pp=400AD290 p_mapping=0 caller=80AD7DA
```

(In another hanging image the same shape appears with `caller=80B1EFE`.)

## 2. The bisect: `assegat_dbg` masks it, and that is informative

Five hardware boots, deterministic verdict each time, and every verdict taken from **telnet/login**
rather than from the serial line:

```text
full dbg overlay (14 probe objects)                                boots
A  = serdbg + ddopen,blkatoff,mainmarks,assegat,execmark,
              hatalloc,sigkill                                     boots  (uname 260729-12)
B2 = serdbg + mainmarks,ddopen,blkatoff,execmark                   HANGS
D  = serdbg + mainmarks,hatalloc                                   HANGS
E  = D + assegat_dbg                                               boots  (uname 260729-22)
quiet = serdbg only                                                hangs
```

**E − D is exactly `assegat_dbg`.** And note what does NOT mask it: `hatalloc_dbg`, which prints
heavily and wraps `page_get` / `page_free` / `hat_ptalloc`. So the masking is neither chatter nor
page-allocation instrumentation — it is specifically the wrapping of **`as_fault`, `as_segat` and
`execmap`** (`assegat_dbg.s`; its `as_fault` wrapper is an ordinary link / save d2-d3,a2-a3 / forward
five args / call `as_fault_orig`).

## 3. Ruled out BY MEASUREMENT, so you need not re-derive these

* **The DMA prepare/complete fail-open did not fire.** `dma_cmpl_noprep` read live from `/dev/mem` on
  a running machine: **0**, with `dma_cmpl_to` 2402 + `dma_cmpl_from` 3153 = `dma_cmpl_count` 5555
  exactly. Every completion had a PREPARED record, so the range `cinvl` ran every time. (This does
  not clear the *range* being wrong — only that the path executed.)
* **The copyback page-release hooks are wired identically** in base, quiet and dbg:
  `patch_cb_release.py` reports `page_free @0xafb08 -> cb_pgfree_enter` already present in all three.
* **`.data` size is 4-aligned** in every image (the base link's own guard passes), so this is not the
  2026-07-09 `.bss`-misalignment/SDMAC class.
* **It boots in Amiberry**, which does not model the 040 copyback data cache — consistent with a
  cache-coherency or timing mechanism and the reason it could only be found on silicon.

## 4. Instrument provenance, stated because it limits one claim

From 20:59 onward three processes were reading `/dev/ttyUSB0` simultaneously, and serial readers
split the byte stream between them. Captures for `-20` and `-22` are therefore **incomplete**: the
lines quoted are real, but their ordering and completeness are not established. The `-07`, `-09` and
`-16` captures and the `-07` console photograph were taken with a single reader and are sound, as
are all bisect verdicts (telnet). The tell for a split stream is garbling, not absence.

---

## What we need from you

**1. ★ Which paths in the exec header sequence RELEASE the 8 KiB header slot and abort?** Byte-exact,
in the form your ISSUE-36 answer used. The relevant bodies as we know them:

```text
exece 0x56444   gexec 0x576c0   elfexec 0xb80f2
exhd_getmap 0x5704e   execmap 0x57a4c   page_abort 0xaf8d6
```

We want the enumeration of "header read → validation → give up" edges, and specifically which of
them ends in unmapping the header slot **without** reaching `execmap` of the program's segments.
That set, intersected with what can go wrong under copyback, is the answer.

**2. How is the exec header actually read, and where is its cache maintenance?** Through `bread` and
the buffer cache, or through segmap + `VOP_GETPAGE`? If the bytes arrive by DMA and are then read by
the CPU through a mapping that may hold stale lines, name the window. Note our measurement above:
the invalidation *ran*, so if this is the mechanism it is a range or ordering defect, not an absent
call.

**3. Why would wrapping `as_fault` / `as_segat` / `execmap` mask it?** This is the question we cannot
answer from our side and the one most likely to name the mechanism. A plain wrapper adds a call
frame, a few stores to `.data` counters, and occasional `cmn_err`. If that is enough to change the
outcome, what is the window? (And why does `hatalloc_dbg`'s much heavier instrumentation of the page
allocator NOT change it?)

**4. The `page_abort` lines: is that legitimate here?** A page freed with `p_mapping = 0`, skipping
`hat_pageunload`, leaving the PTE in place. Callers `0x80AD7DA` and `0x80B1EFE`. Is leaving the PTE
correct on that path, and can the page be recycled while a stale translation still points at it?
That is the ISSUE-10 family, and if the two are one defect we would rather learn it now.

## What makes a good answer

* Byte-exact sites for (1) — that form is why the ISSUE-36 fix was four instructions.
* An explicit "no" where the answer is no; (2) may simply be the buffer cache with correct
  maintenance, and knowing that is worth as much as a finding.
* If you think the copyback attribution is wrong despite the two-byte A/B, say so early. The A/B is
  strong but the mechanism is entirely unproven, and we would rather discard the frame than defend
  it — that is how the ISSUE-22 depth hypothesis got resolved.
