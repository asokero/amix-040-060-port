# RESUME HERE — AMIX 68040 REAL-HARDWARE line (next: retest with ISSUE-8 fixed)

> ## ▶ NEXT VISIT (2026-07-09) — ISSUE-8 is FIXED on the emulator; RETEST on real silicon
> **The real-HW p0init bus error was ISSUE-8's halved leaf-table address** — now root-caused and
> fixed (commit `998737f`, 2026-07-09). `kvm_init`'s leaf-table `ctob`/`btoc` were left at 2 KB in
> the Model-B conversion, so `word2` = the leaf phys was HALVED: `d5=0x714E` → `0x038A7000`, which
> is real RAM on the emulator's low memory but an **unmapped hole on the real A3000** (chip ends
> 0x200000, RAM at 0x07/0x08000000). p0init's STORE B wrote it and `segu_get` (0xaa6f8) read it
> back — both hit the hole on real silicon → the bus error. The 2026-07-08 Amiberry.log compare
> nailed it (`Gary timeout 038a78XX R PC=070aa6f8` = segu_get reading the halved address). Fix =
> convert all 6 `ctob`/`btoc` sites to 4 KB. The earlier "click<<11 DISPROVEN" verdict was wrong
> (fs-uae masked the halved read, and only 2 of 6 sites had been patched — see KNOWN-ISSUES.md
> ISSUE-8).
>
> **So on the next real-HW visit: boot `unix-040-dbg` (current master) and capture serial. EXPECT
> it to get PAST the p0init panic (pc≈0x7049130).** If it does, the next real-HW frontier is
> whatever comes after (early fork / SCSI-a3091 DMA / interrupts). If it STILL faults in p0init,
> the live candidate is **hypothesis #1 below (STORE A / stale page-table cache lines)** — a real-
> silicon cache-coherency effect the emulator doesn't model; try the `cpusha`-after-segkmem-PTE-
> writes fix. The emulator line has since reached full login + `ls -alR` + reboot cycles (ISSUE-7
> also fixed, commit `51cdbc7`), so the emulator is a solid regression baseline before each HW try.
> **Current source of truth: `KNOWN-ISSUES.md` ISSUE-8 + the MILESTONE banner atop `RESUME-HERE.md`.**
> The STORE A/B markers + `cpusha` test at the bottom of THIS file remain the right HW-debug moves
> if p0init still faults.

Status: **paused** while the dev continues the EMULATOR + SCSI/root-mount line on a
laptop (real A3000 not available for a couple of days).  The 040 VM port works on
emulators (boots to root-fs mount); on REAL silicon it gets further-verified but hits a
single, well-localized real-040 blocker described here.

## The machine (real A3000 + PPS Mercury 68040)
- CPU: 68040 (ShowConfig: "CPU 68040/FPU restricted/MMU 68040"). AttnFlags 0x804f.
- RAM: **Mercury 32MB at 0x08000000-0x09FFFFFF**, motherboard **16MB at 0x07000000-
  0x07FFFFFF**, chip 2MB. (bootinfo mem[0]=08000020..0a000000, mem[1]=07000020..08000000.)
- **The kernel loads at 0x08000000** (Mercury RAM, region 0): unix_boot prints
  `kernel: entry=08000000 tvaddr=08000000 tsize=000d7898 dvaddr=080d7898 dsize=00017f31`.
  So all kernel addresses are 0x08xxxxxx (region 0, covered by ITT0/DTT0 identity).
  NOTE: panic prints drop the leading zero, so "pc=80490D6" = 0x080490D6 = p0init+0x10A.
- 030 AMIX boots fine on this exact config.
- Emulators (WinUAE/fs-uae) load the kernel at 0x07000000 (16MB, no Mercury) and reach
  root mount.  So real-HW vs emulator differ only by (a) RAM at 0x08 vs 0x07 (both region
  0) and (b) **real 040 silicon vs emulator's lenient CPU/cache/MMU model**.

## What WORKS on real silicon (verified by debug markers)
pstart040 (MMU enable -- fs-uae log: "68040 MMU: enabled=1") -> mlsetup -> kvm_init ->
p0init's **first** svirtophys(u=0x40000000) -> **vatosde/vatopte (the 040 page-table
walk) RAN** (a one-shot `cmn_err` "DBG vatosde va=40000000" PRINTED on real HW).  So the
whole 040 VM bring-up + the 040 software table walk work on real silicon too.

## THE BLOCKER: p0init u-area-PTE loop, a DEFERRED bus error
`p0init` (0x48fcc) builds the u-area page-table entries in a 4-iteration loop
(0x490c8-0x49130; va = 0x40000000, 0x40000800, 0x40001000, 0x40001800):
```
490c8 LOOP: d0 = d2<<11 + u ; jsr svirtophys      ; d0 = phys of u-area click d2
490dc  d0 = (d0+2047)&~2048 | 1                    ; -> a PTE value
490f6  STORE A: *(fp@-4) = PTE                      ; fp@-4 = (proc[0]+95)&~15  (REGION 1, kvseg)
4910e..49120  STORE B: *(st_top1[seg].leaf[leaf]) = PTE   ; the 030-tree leaf (inert on 040)
4912a  d2++ ; if d2<=3 loop
```
On real HW: only the FIRST svirtophys printed (va=40000000), then BUS ERROR
(fmt=0x7 vector=0x2) reported at **pc=0x490D6 (no marker) or 0x490C8 (with marker)** --
both are `jsr`/`movel %d2,%d0`, instructions that CANNOT data-fault.  An impossible pc +
the pc MOVING when a debug marker changed timing = a **DEFERRED WRITE fault**: the 040
posts a write, continues, and the write faults a few instructions later (imprecise pc).
proc=0x4007EC00 (proc[0], kvseg).  kstack ~0x080D96xx (the pstack, kernel .data, region 0).

So: one of the loop's STORES (most likely **STORE A**, writing proc[0]+0x50 in the
kvseg/region-1 window) writes to a target the 040 ends up rejecting -- a real-silicon
MMU/cache effect the emulator doesn't model.

## What was TRIED and did NOT work
- **Serialize DTT0/DTT1 (CM 0x60 -> 0x40)** to stop write buffering -> NO change (still
  faults at 0x490D6).  Reason it can't help: STORE A targets region 1 (0x4007EC50), which
  is **page-table-mapped (kptr040)**, so its cache mode comes from the **leaf PTE**, not
  DTT0.  Reverted to 0x60 (no-op on emulators).

## OPEN HYPOTHESES for next time (in priority order)
1. **STORE A's region-1 translation reads stale page tables.** proc[0]'s kvseg pages were
   mapped by `segkmem_mapin` (leaf PTEs written into kptbl, region-0 kernel RAM) AFTER
   pstart040's cpusha.  On real 040 those PTE writes may sit in the cache/write buffer
   when the MMU hardware table-walk reads them -> stale descriptor -> garbage phys ->
   deferred bus error on STORE A.  FIX candidates: (a) a `cpusha`/`cpushl` after
   segkmem_mapin writes PTEs (flush page-table lines before the MMU can walk them);
   (b) make the page-table backing memory (kptbl / kptr040 / leaf tables) cache-inhibited
   *serialized* via its PTE CM, not via DTT0; (c) check the kvseg leaf PTE CM bits our
   Model-B byte patches produce (the {0:21}->{0:20} edits keep the low byte = status; verify
   the CM/cache bits are sane for real 040 -- 0xE1 = nocache for the u-area, but the
   GENERAL kvseg pages may be cacheable copyback, which needs coherency).
2. **The 030-tree STORE B** writes `*(st_top1[seg].leaf[leaf])`.  If st_top1[seg] is unset
   (0) for the computed seg, leaf addr = 0+leaf*4 ~= low memory -> a write near the vector
   table.  Less likely to bus-error (chip RAM is writable) but worth ruling out.  d3 =
   *p0seguser drives the seg index; confirm st_top1[seg] is the u-area entry pstart040 set.
3. **Broader cache coherency:** pstart040 does ONE cpusha before MMU-enable; but page
   tables keep being written during boot (sysseginit/segkmem/p0init) and are never flushed
   again.  Real 040 needs the tables coherent at every walk.  Consider cache-inhibiting
   the entire page-table region, or flushing after each batch of PTE writes.

## How to RESUME the HW line
- The debug technique that worked: a **range-limited / one-shot `cmn_err`** marker in our
  own code (kvm040.s vatosde / pstart040), fired only AFTER curproc is set (p0init).
  **LESSON: never cmn_err before mlsetup/curproc** -- it adds a garbage curproc to the
  sleep queue and corrupts the kernel (wakeprocs walks a garbage pointer; fs-uae log:
  "Gary timeout 2c00485e PC=07048912" in wakeprocs+0x30).
- Next markers to add: distinguish STORE A vs STORE B (put a marker between them, or
  print fp@-4 and the st_top1 leaf addr), and confirm whether a `cpusha` after segkmem
  PTE writes makes the fault go away.
- fs-uae logs the 040 MMU + bus errors automatically (~/Asiakirjat/FS-UAE/Cache/Logs/
  fs-uae.log.txt) -- but the emulators DON'T reproduce this fault (they pass p0init), so
  HW-only debug markers + photos of the real screen are the channel.

## Build
`sh relink-040.sh` -> build/unix-040.  Current tree = clean (serialization reverted, no
debug markers).  Emulators reach root-fs mount; real HW hits the p0init deferred-write
blocker above.
