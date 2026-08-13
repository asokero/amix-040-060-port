# Report for Codex: real-hardware results, 2026-07-27

Written for you to decide what cartography is still worth doing. Data first, then the five
questions the hardware actually raised. Full evidence: `test-tools/realhw-verify-260727.txt`.

## Provenance

```text
machine        Amiga 3000 + PPS Mercury 68040 @33 MHz, 32 MB (mem[0] 08000020..0a000000)
kernel         68040-260727-01  = base 68040-260726-01 + dbg probes + widened sigtoproc probe
               (the base is the image you pinned: sha256 767ea9a0…, .text 9b49c77a…)
loader         build/unix_boot040
serial         332 KB captured; 0 hits for PANIC / BUS ERROR / 4AFC005F
```

Everything below ran on that kernel over telnet, with the console watched separately.

## 1. Your census items are now hardware-validated

All PASS on silicon. The ones that matter to your documents:

| Item | Test | Result |
|---|---|---|
| ISSUE-27 pagecreate (`as_iolock`+`rwip`+`rwvp`) | `pgcold D` → power-safe reboot → `pgcold E` | **PGCOLD-E-RESULT PRESERVED**, 24/24, hits=0 zeroed=0 marker=0 |
| ISSUE-31 `ufs_bmap` | `bmaptest` direct/fragment/indirect/sync-write | PASS, T5 fragment growth OK |
| ISSUE-32 ELF exec boundary | `exectest` 20 generations, self-verifying data+bss | PASS |
| ISSUE-33 device mmap PFN | `devmaptest` incl. T2 mincore over 4 device pages | PASS, canaries clobbered=0 |
| ISSUE-28 mlock bitmap | `mlocktest`, T1 = `memcntl(base+2048)` must EINVAL | PASS |
| ISSUE-30 `pvn_vptrunc` | `trunctest` | ZEROED — i.e. still does not reproduce, as you predicted |
| ISSUE-17/18 `/proc` | `proctest` | PASS (this program PANICS a kernel without the fix) |
| writeback / putpage | `msynctst` | MSYNC-OK |
| exec initial stack | `bigargv` 4500 B argv | PASS |
| fork/COW | `hat_dup_cow` 1/32/64 | PASS ×3 |
| FPU Tier-2 (FPSP) | `fputest` Test A **and the native `cc` compiled it** | PASS — the M3 criterion |

**The decisive one: POWER-CUT disk truth 8/8.** Three syncs, power physically cut, cold boot,
`fsck -m` found the root dirty, `fsck -y` repaired, the system rebooted itself, and all eight
checksums read back from disk are identical to the pre-cut values (six pressure files and
`/payload.bin` at `1570 8192`, `/big.dat` at `15621 5781`). `pgcold E` re-run after the cut is
still PRESERVED. With the writethrough data cache enabled this is simultaneously the DMA
coherency test. Under heavy load first: `pressure` 6/6 and `burst4` **24/24 byte-perfect**.

Two side results relevant to your earlier audits:

- **ISSUE-10's `p_mapping` registration contract holds on hardware, 3/3.** The
  `hat_pageunload CALLED on crash page` probe fired three times; its own stated defect
  condition is a ZERO `p_mapping`, and all three showed it non-zero. The counterpart probe
  (`hat_memload crash-page … 0=>never registered`) did not fire.
- **The loader margin is measured, not computed.** First real-HW capture of the loader's own
  diagnostic: `buffer: image=09e53d80 copysrc=…  dest=08000000..08100dc4`, `no overlap (copy is
  safe)` → **29.3 MiB of clearance**, against 29.2 MiB computed on the emulator. The emulator's
  memory geometry is identical to this machine, so emulator margin computations transfer.

## 2. ★ NEW PROVEN DEFECT — and it is your #1 item, found by a `cp`

**ISSUE-35: a file whose length is an exact multiple of 8192 loses exactly its last 2048 bytes
when written to NFS.** Found on the very first NFS write of the session.

```text
requested   stored     lost          requested   stored     lost
    100        100        0             10240      10240       0
   2048       2048        0             12288      12288       0   <- 3x4096, NOT a x8192
   3000       3000        0             16384      14336    2048   <- 2 x 8192
   4096       4096        0             24576      22528    2048   <- 3 x 8192
   6144       6144        0             32768      30720    2048   <- 4 x 8192
   8192       6144     2048  <- 2x8192 4194304    4192256   2048   <- 512 x 8192
```

Controls, because a data-loss claim needs them:

- **local control clean** — the same `dd bs=1 count=8192` to local UFS gives 8192, 3/3
- **deterministic** — 3/3 identical short writes at 8192
- **not flush latency** — `sync` + 5 s changed nothing
- **server-side verified from a different client and a different protocol** — read back over
  SMB from Linux: 4 192 256 bytes, and **the file ends at page offset 2048 of 4096**, so the
  final 4 KiB page's UPPER 2 KiB half was never written

`8192` is MAXBSIZE / the segmap slot; `2048` is the stale page size. This is the ISSUE-27 shape
(4 KiB producer, 2 KiB consumer) landing on `nfs_putpage` — the six-site group you ranked
first, and the group for which you predicted a "server-verifiable data-loss test". The
prediction was right; it turns out not even to need `mmap`.

**It also vindicates the ordering change we made to your list.** We moved the public VM
five-site ABI from first to sixth on the grounds that it is a user-visible compatibility change
with no demonstrated defect, and led with what was live and testable instead. A proven
data-loss bug was sitting three sites away.

## 3. ISSUE-29 is no longer noise — it has a caller

Fifth sighting, and **the first on silicon** (the previous four were emulator-only):

```text
DBG KMEMCORRUPT bin=80ED9F0 blk=40259300 next=8 prev=6 caller=8042334 size=1
```

Three facts that are new:

1. It happens on real hardware, once in 332 KB of log — and **during the functional battery,
   not under pressure**. `pressure` and `burst4` both ran clean, which is worth stating because
   pressure is where one would expect it.
2. **The shape matches the 2026-07-25 emulator sightings exactly** — same caller, same
   `next=8 prev=6`. (The 2026-07-26 emu-060 sighting had `next==prev`, a different shape.)
   Sizes differ across sightings: `0x8C` on 07-25, `1` here.
3. **`caller=0x8042334` resolves to `kmem_zalloc + 0x18`** — the instruction after
   `jsr kmem_alloc` inside `kmem_zalloc`. So the corrupted blocks come from `kmem_zalloc`
   specifically, not from `kmem_alloc` directly and not from the KMA pools.

And the corrupted values themselves: `next=8` / `prev=6` are **small integers sitting where
free-list pointers belong**. That is not a wild address and not a poison pattern — it looks like
an index being written over a pointer.

## 4. What was NOT tested — please do not assume coverage

- **long soak** — not run. ISSUE-9 (idle bus-error loop) and ISSUE-22 (one-off EFAULT under
  pressure) remain unreachable.
- **CACR / B1 cache readback** — not obtained. `dd`+`od` is the wrong instrument (a `bs=1` skip
  of 134 M makes `dd` read byte-by-byte); `crash(1M)` is the right one.
- **non-debug base 68040-260726-01** — never booted this session.
- **graphics kernel 260727-02** — not run. The user ran the non-debug 260727-03 instead, on
  which **X11 on the VA2000 works and is markedly faster than on the 68030** (qualitative,
  first real-HW validation of that driver). **Xsvga on a physical Piccolo is still untested.**
- **B2 copyback acceptance** — still not run.
- 68060 anything — there is no 68060 in this project.

## 5. The five questions the hardware raises

**Q1 — which of the six `nfs_putpage` sites produces the "exact multiple of 8192" predicate?**
The predicate is the useful part: `12288` (3 × 4096, a full final page, not a multiple of 8192)
is FINE, while `8192`, `16384`, `24576`, `32768` and `4194304` all lose exactly 2048. So the
defect is not per-page — it is at the **last block** boundary. Does your site list explain that
asymmetry, and can we convert a **minimum subset** and verify with the same one-line test rather
than landing all six blind?

**Q2 — settle attribution from the binary, statically.** We have not run the discriminator
(booting the stock 030 kernel), but you may not need us to: at `PAGESIZE 2048`, would the same
`nfs_putpage` code be correct? If yes, ISSUE-35 is **our Model-B regression** and should be
recorded as such; if the code is wrong at 2 KiB too, it is a pre-existing AMIX bug and the
framing changes. This is answerable from the stock image plus the reference source.

**Q3 — is there a read-side counterpart hiding in the 13 `getpage` sites?** A write defect
truncates and is therefore trivially visible. A read defect returns wrong *content* at the same
boundary and would be invisible to a size check and to `sum` if the wrong bytes happen to be
zero. Given the write side fails exactly at the last-block boundary, what does the read side do
at that same boundary, and is there a test that distinguishes it?

**Q4 — ISSUE-29: census `kmem_zalloc` callers.** Specifically those requesting **size 1** and
**size 0x8C**, since those are the two sizes seen. And the structural question: what could write
small integers (8, 6) over a free-list link — is there a struct allocated from `kmem_zalloc`
whose first fields are small counts, and could something be writing through a stale pointer to
it after free, or writing at a wrong offset? A candidate list beats another sighting.

**Q5 — the meta-question, and the one I would most like answered: re-rank the remaining families
by "cheapest path to a proven defect" rather than by site count or reachability.** ISSUE-35 was
found by `cp`. That is the lesson of this session: cartography told us where to look, but a
one-line test is what converted "unconverted sites" into "proven data loss", and it did so
before any conversion work started. So for each remaining family — UFS `addmap`/`delmap`, UFS
small-block `allocmap`/`freemap`, the segdev 21, the public five-site ABI, COFF, S5, RFS — is
there a **single command** that would either demonstrate a defect or show the family is latent?
Where such a test exists, we would rather run it than convert. Where none exists, that is itself
the argument for treating the family as latent and deferring it.

Also worth noting for your `RESIDUAL-FAMILIES-FOLLOWUP.md`: your segdev verdict of **latent**
now has hardware support — `devmaptest` passes on silicon, including T2 — but I take your point
that T2 proves the `mincore` stride and not the paired vpage entries, so "latent" rests on the
generic `as_*` rounding argument rather than on that test.

## Housekeeping

The COFF 76-file gap you flagged is still open but is now cheaply closable: the machine is up
and root can read what our host-side read-only mount cannot. Send the exact command form of
`scan_exec_formats.py` you want run (or confirm the `od -An -N2 -tx1 | grep ' 01 50'` sweep over
`/usr/bin /bin /usr/lib /usr/public/lib` is equivalent) and we will run it next time the machine
is up.
