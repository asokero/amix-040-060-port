# RESUME HERE — AMIX 68040 REAL-HARDWARE line

> ## ✅ 2026-07-12 — ISSUE-13 FIXED + VERIFIED ON REAL HW; COW ACCEPTANCE PASSES ON REAL HW
> **Build 260712-03 (unix-040 + unix-040-dbg) is the current real-HW line.** Two real-HW
> validations landed this session (full detail: RESUME-HERE.md top banner + KNOWN-ISSUES
> ISSUE-13):
> 1. **ISSUE-13 capture 1 (NFS→local copy panic) fixed by `prototypes/bp_map040.s`**
>    (commit `4099f4e`): stock 030 `bp_map`/`bp_mapout` walked the retired `st_top1` tree
>    on the NFS/RFS page-I/O path → low-memory writes + a temp mapping the MMU never saw.
>    Verified on the real A3000+040: the previously-panicking NFS→local copy now completes;
>    **5 consecutive 3 MB copies, every one byte-perfect** (`sum` 11920 6060 identical
>    NFS↔local), machine stable throughout.
> 2. **hat_dup_cow acceptance test FULL MATRIX PASS on real HW** — 1/32/256 forks (also
>    passes emu-040 + emu-060). Closes the long-open "fork/COW never runtime-validated on
>    real silicon".
> Real-HW session practicals: `telnet 10.0.10.10` works but the Linux telnet client is
> flaky mid-negotiation — the scratchpad raw-socket runner (`real.py`) is the reliable
> driver. `nohup` does NOT survive session exit on the real machine. File transfer:
> slirp-safe TFTP recipe in RESUME-HERE.md. Still NO serial cable on the real machine.
>
> ## ★★★ 2026-07-11 — MILESTONE: AMIX BOOTS TO LOGIN ON REAL HARDWARE ★★★
> **Amiga 3000 + Mercury 68040 @33 MHz, 32 MB — builds 260711-01/-02/-03, user logged in.**
> The 2026-07-10 night session found and fixed TWO real-silicon-only bugs from screen
> photos + one emulator log, then the next boot (after fsck from the crashed attempts)
> reached login:
> 1. **hat_free A-slot guard** (hat040.s V3): init's exec teardown walked relic 030-written
>    root descriptors; a garbage pointer-table base (0x3F0000 = Zorro space) bus-erred on
>    real HW where the emulator reads it leniently. Same-night emulator log had the
>    identical BAD-slot/LEAK lines — only the read's outcome differs on silicon.
> 2. **wb040_replay u_nofault guard** (wb040.s): the replay's `moves` to user space ran
>    unarmed; stock k_trap only resolves supervisor faults on user VAs when u+0x374 is
>    armed (copyin/copyout convention), else krnxmemflt→as_segat(&kas)=NULL→PANIC. Real
>    040 fills WB2/WB3 with the previous insn's pending store → unmapped targets happen.
>    Now armed around the loop with a log+skip landing pad (Lwb_fail).
> Verified working on HW: boot, fsck, login, remote telnet over A2065, and amixadm
> (floods the known ISSUE-10 signature IDENTICALLY to the emulators — see
> KNOWN-ISSUES.md ISSUE-10 2026-07-11 datapoint).
> **ISSUE-12 was a false alarm:** A2065 networking works on real-HW 040 AMIX
> (build 260711-02). `ifconfig -a` is just an unsupported/silent AMIX option;
> the correct query is `ifconfig aen0`. Remote interactive sessions over the
> wire work, so the "network access to the real machine" goal is achieved.
> ISSUE-11 (WB1 lane realign) rode along on these boots with no visible anomalies.
>
> ## (previous banner) 2026-07-10 — THE HW SESSION IS STARTING (Mercury 040 @33 MHz, 32 MB; FIRST BOOT DONE)
> User has the card installed and a first boot attempted; **no serial cable yet — analysis is
> screenshot-based for now** (the console wraps ~40 lines; prioritize the LAST screen + any
> guru/panic text + the boot banner). What to bring/use:
> - **Kernels: builds 260710-24 (unix-040) / -25 (dbg) / -26 (quiet)** — dual-CPU (68040+68060),
>   all Model-B patches, s5/spec pager fixes, AND the **ISSUE-11 WB1 lane-realignment fix**
>   (emulator-inert; the FIRST REAL-040 BOOT IS ITS ACTUAL TEST — WB1 writebacks only exist on
>   real silicon). Verify which build is running from the banner / `uname -m` tag.
>   NOTE: -24/-25/-26 not yet emulator-boot-verified (built at session end) — do one quick
>   Amiberry regression boot before the HW visit if convenient.
> - **Loader: `build/unix_boot040` (2026-07-10)** — overlap-safe copyit + MEMF_REVERSE buffer +
>   checksum transit guard (**white/red color0 flash = corrupt copy, don't debug past it**) +
>   cputype poke (prints `kernel cputype set to 40`).
> - **Known non-bugs on HW:** `amixadm` (or other sh scripts) flooding `User BUS ERROR at
>   xxx PC:800023xx CMD:...` = **ISSUE-10, known+paused, not a HW regression** (sh self-recovers
>   with "no space"). dbg probes (SEGVCTX/DMP/PP etc.) print WARNING lines — normal.
> - Serial cable is the single highest-value hardware purchase for this line (conputc mirror
>   already in dbg/quiet; SERIAL-DEBUG.md has the recipe).
>
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
>
> **★ 2026-07-09 PM — TAKE THE NEW LOADER TO THE HW VISIT (cold-boot flakiness fixed).** The
> Amiberry cold-boot flakiness was root-caused the same day: `AllocMem(MEMF_FAST)` put the
> loader's ELF buffer ~0.94 MB above the fast-RAM base, the ~0.96 MB image OVERLAPPED it by
> ~25 KB, and copyit's INVERTED copy-direction choice corrupted the first 25 KB of the copied
> kernel (including `_start`) → wild execution at handoff. **The real-A3000 "1st boot → AmigaOS
> guru, 2nd boot → kernel runs" pattern is very likely THIS SAME BUG** (same loader, same AmigaOS
> allocation geometry; the 2nd boot's residue shifts the buffer past the overlap — exactly the
> emulator's `ed`-warm-up effect). Fixed in `unix_boot/src` (overlap-safe copy directions +
> `MEMF_REVERSE` top-of-RAM buffer + a permanent copyit checksum verify); deployed as
> `build/unix_boot040`. **On real HW: use the new loader; if the screen ever flashes white/red
> at handoff, the copied image failed its checksum (transit corruption — report it, don't
> guess).** Verified on Amiberry: multiple cold boots through AMIX reboot cycles, zero warm-up.

Current status (2026-07-12): the real-HW p0init blocker below is historical. The
ISSUE-8, loader-overlap, hat_free, and wb040_replay fixes moved the Mercury-040
machine through fsck/login and onto the network, and the bp_map040 fix (ISSUE-13)
made NFS page-I/O reliable on it. Keep the lower p0init material as the original
failure analysis and regression context, not as the live blocker.

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
