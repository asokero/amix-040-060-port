# ISSUE-10 has a reliable trigger again — and it is not the bounded reverse-map unlinks

**2026-08-19 · EMU (Amiberry, 68040+MMU, 16 MB, load base `0x07000000`) · kernel `68040-260819-05`**

Raw readings: [`test-tools/issue10-revmap-counters-260819.txt`](../test-tools/issue10-revmap-counters-260819.txt).
Instrument: [`src/i10rev040.s`](../src/i10rev040.s). Guest driver:
[`test-tools/i10bench.sh`](../test-tools/i10bench.sh). Probe: [`test-tools/shmband.c`](../test-tools/shmband.c).

## Summary

Running a 68040 install miniroot, `/bin/sh` dies while reading a ~77 KB shell script with a flood
of

```
NOTICE: User BUS ERROR at 4AFC0003, PC:800023FC FAULT:6 PID:35 CMD:sh /cdrom/install/bin/setup.sh
```

and then `no space`. That is byte-for-byte the signature `KNOWN-ISSUES.md` records for ISSUE-10's
**`amixadm` trigger, which was retired on 2026-07-15 as no longer firing** — same fault address,
same PC, same fault class. It fires again here, and this time it is **deterministic**: eight
consecutive reproductions, no memory pressure, no fork storm, one command.

Three mechanisms were on the table. The measurements settle two of them and re-aim the third.

| | Candidate | Verdict |
|---|---|---|
| **A** | One of the bounded-256 reverse-map unlink paths gives up on exhaustion, leaving a stale `p_mapping` after the PTE is removed | **REFUTED** — all three give-up counters are 0 across every reproduction, and no search ever walked half its budget |
| **B** | The eight-site SysV shm 2 KiB anon-map mismatch | **CONFIRMED as a live defect, but it is a different bug** — it panics, deterministically, in its predicted band; `sh` never calls `shmget` |
| **C** | Amiberry 68040 format-$7 write-back infidelity | **Not supported as stated** — the write-back replay path recorded no event at all while the fault fired |

What the evidence points at instead is named in §4, and it is the same conclusion the 2026-07-16
`SEGVCHAIN` probe reached from the other side: a **user heap page that holds kernel u-area
content**.

## 1. Candidate A — refuted, with the reading that makes zero mean something

`src/i10rev040.s` adds uncapped counters, in the shape of `kdbg040.s`'s `hat_pfnmiss_n`, at the
three places that walk a page's `p_mapping` chain with a 256-node bound and then carry on when the
bound runs out: `hat_pteload`'s replacement path (which was **completely silent**), `hat_unload`
and `hat_free` (which print through a cap of 4 and then go dark for the rest of the uptime).

The fourth site on the list, `hat_dup040`, turned out to have no bounded unlink loop to
instrument: it never *searches* a chain, it only pushes onto one, on both its private-copy and its
share path. It is therefore not a consumer that can give up — it is the **producer** that makes
chains long enough for the other three bounds to matter, so what it contributes is that rate.

```
sample                 rpfail  hlfail  hffail   dupreg   deep
baseline                    0       0       0      478      0
after-mount                 0       0       0      663      0
after sh -n setup.sh        0       0       0      944      0   <- wall fired
after sh -n install.sh      0       0       0     1129      0   <- wall fired
after sh setup.sh #1        0       0       0     1364      0   <- wall fired
after sh setup.sh #2        0       0       0     1599      0   <- wall fired
after sh setup.sh #3        0       0       0     1834      0   <- wall fired
second boot, independent    0       0       0      466      0   <- wall fired
```

Three things make this a result rather than an absence:

* **The counters are demonstrably live.** `i10_dupreg_n` moves by **exactly +235** across each of
  the three identical full runs. A dead link or an unlinked island reads zero too; this one does
  not.
* **`i10_deep_n` is 0.** No successful reverse-map search anywhere in the run walked even 128 of
  its 256-node budget. So the give-up counters are not zero because the workload got lucky — the
  bounds were never within reach of being exhausted. "Did not happen" and "could not have
  happened" are different claims, and this is the second one.
* **The address was verified before the numbers were believed.** `i10_magic` reads `49313021`
  (`I10!`) at `0x0710B8F8` and the same offset at the `0x08000000` base reads zeros throughout —
  which is also how the load base was established, this rig having no accelerator RAM.

## 2. What the wall actually is

`PC:800023FC` sits in `/bin/sh`'s own allocator. Disassembling the miniroot's `sh` at that address
gives the free-block coalescing loop:

```
800023f8:  movel  %a1@,%a0@       p->word = q->word     (write)
800023fa:  moveal %a0@,%a1        q = p->word           (read back)
800023fc:  btst   #0,%a1@(3)      busy(q)?              <-- faults
80002402:  beqw   0x800023f8
```

So the fault address `4AFC0003` is `q + 3`, and the free-list link `q` read out of `sh`'s arena is
**`0x4AFC0000`**. On this image `kvsegu` is the absolute symbol `0x48440000`, so that value is
`kvsegu + 0x2B80000` — **a pointer into the kernel's u-area virtual segment**. `FAULT:6` is
FLTBOUNDS: the kernel is correctly refusing a user access to a kernel VA. The 11–20 repeats and
the closing `no space` are Bourne `sh`'s own catch-and-retry-after-`sbrk` behaviour giving up, not
a kernel fault loop. Every part of that matches the decode `KNOWN-ISSUES.md` already carries for
the amixadm trigger, independently re-derived here.

The value is not random dirt. It is the **same constant, `0x4AFC0000`, in every fault, in every
process, in both boots, and in the 2026-07-10 amixadm captures**. A race would not produce a
constant.

## 3. Characterising the new trigger

The trigger is worth writing down carefully, because ISSUE-10 has been without a reliable one
since 2026-07-15.

* **It is parse-time.** `sh -n`, which parses the whole file and executes none of it, reproduces
  the fault identically. Nothing in the script runs.
* **It is not this script.** A different, larger installer script (118500 bytes) fails the same
  way under `sh -n`.
* **It is not raw file size.** A synthetic 64 KiB script made by concatenating the same
  syntactically-complete 4 KiB chunk sixteen times parses **clean** at every step from 8 to 64 KiB
  — each repeat redefines rather than grows the parse tree. What matters is how far `sh`'s arena
  has to grow, not how many bytes went past the lexer.
* **The threshold is sharp.** Truncated to 34 KiB the script parses clean; at 38 KiB and beyond it
  walls, every time. (36 KiB lands on a truncation syntax error and aborts the parse early, so it
  says nothing.)

That combination — deterministic, arena-growth-driven, a constant stale u-area pointer — is a
far better instrument than a fork storm, and it costs one command.

## 4. Where this points

`sh`'s heap contains a kernel u-area *virtual address* where a free-list link belongs. Not
zeros, not file data — a value of the kind the kernel writes into a u-area page. The reverse map
is intact (measured above, and the 2026-07-16 `SEGVCHAIN` probe measured `in=1` on all eight
hits), so this is the **phys double-use / page-lifetime family (ISSUE-5/6)**, and specifically the
`segu`/`kvsegu` corner of it: a frame that is, or recently was, a u-area page and is now backing
user anon memory.

The obvious ZFOD half-zero explanation is already excluded: the `pagezero(pp, 0, 0x800)` family was
converted in `bc68e1b` and `src/patch_modelb.py` covers `anon_zero`, `s5getapage`, `ufs_getapage`
and `spec_getapage`. So the residual is elsewhere, and the constant offset `kvsegu + 0x2B80000` is
the thread to pull: the same u-area slot is reachable every time.

**Recommended next probe**, in the spirit of the free-time invariant spec: at the point `sh`'s
`brk` growth hands back the page that later reads `0x4AFC0000`, dump `{pfn, p_vnode, p_mapping,
the frame's first words}` and compare the pfn against the live `segu`/`kvsegu` mappings. The
trigger is now cheap enough to make that a single run rather than a grind.

## 5. Candidate B — the SysV shm band, measured

Separately queued, and settled while the rig was up. `test-tools/shmband.c` walks `shmget` →
`IPC_STAT` → `shmat` → first/last byte → detach across the sizes the audit predicts.

| size | `mod 4096` | in `[1,2048]`? | measured |
|---:|---:|:---:|---|
| 2047 | 2047 | no | SURVIVE (get + `IPC_STAT` only) |
| **2048** | 2048 | **yes** | **PANIC: `segvn_create anon_map size`** |
| 2049 | 2049 | no | SURVIVE, attached at `c1001000` |
| 4095 | 4095 | no | SURVIVE |
| 4096 | 0 | no | SURVIVE |
| **4097** | 1 | **yes** | **PANIC: `segvn_create anon_map size`** |
| **6144** | 2048 | **yes** | **PANIC: `segvn_create anon_map size`** |
| 6145 | 2049 | no | SURVIVE |
| 8191 | 4095 | no | SURVIVE |
| 8192 | 0 | no | SURVIVE |

Six survivors, three panics, no exception. Both edges of two consecutive bands are pinned —
4096 survives and 4097 panics; 6144 panics and 6145 survives — so the failing set is a **band**,
not a threshold, which is the specific claim that distinguishes this mechanism from "large sizes
fail". Sizes 1, 2047 and 8193 were not attached; 1 and 8193 sit in bands whose behaviour is
already measured, and each panic costs a boot.

`IPC_STAT` reports the original byte count for every size including the fatal ones, and every
successful attach is 4 KiB-aligned, so the API-visible contract is intact right up to the point
where the segment is created.

This is a **real defect, reachable by any unprivileged process**, and X11's MIT-SHM is a named
caller. It is **not** the setup.sh wall: it panics rather than faulting, and `sh` never calls
`shmget`. The two share a family — a 2 KiB constant surviving the 4 KiB conversion — but not a
site.

## 6. Candidate C — not supported as stated

The `wbf_*` counters were read across the wall on a second boot:

```
wbf_magic 57424621 ("WBF!")   wbf_prop_on 1   wbf_sup_fatal 1   wbf_slot 3
wbf_fail_n  wbf_user_n  wbf_sup_n  wbf_signal_n  wbf_nosig_n  wbf_krn_n
wbf_swallow_n  wbf_afb_n  wbf_alien_n  ...  ALL ZERO, before and after
```

The 68040 write-back replay path recorded **no event of any kind** while the fault was firing, so
a mis-replayed or dropped write-back is not producing the corrupt link. That agrees with what
`wb040.s:613` already states from reading the emulator's source — the emulator never sets WB1S
valid, so those paths have never executed there — and with the ISSUE-10 progress log's own
conclusion on 2026-07-10 that the write-back replay is "not the corruptor".

Two further points argue against an emulator-only artefact, and both are from the existing record
rather than from this run: the same fault reproduces on **two different emulators** (fs-uae and
Amiberry) at the same address, and the **68060 does not reproduce it on the same emulator**. A
divergence that is CPU-model-specific within one emulator is more easily explained by the 040 code
path than by the emulator's memory model.

This does not clear the emulator. `AGENTS.md` is right that Amiberry is not evidence for
cache/DMA-coherency behaviour, and the wall has never been tried on 68040 silicon. But (C) as
stated — the format-$7 write-back frame — is measured inert here, and it should not be the next
thing tested.

## 7. What was not established

* The wall has **not** been run on hardware. Everything above is EMU.
* Sizes 1, 2047 and 8193 were predicted, not attached (§5).
* The three reproductions asked for were taken **within one boot**, plus one independent
  reproduction on a second boot. Cumulative counter deltas across a single boot are the stronger
  reading for this question, but they are not five independent boots.
* Nothing here explains *why* `0x4AFC0000` is always the same value. That is the next probe.
