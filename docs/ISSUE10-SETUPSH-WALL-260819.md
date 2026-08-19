# ISSUE-10 has a reliable trigger again — and the page under it is not what we thought

**2026-08-19 · EMU (Amiberry, 68040+MMU, 16 MB, load base `0x07000000`)**

Raw readings: [`test-tools/issue10-revmap-counters-260819.txt`](../test-tools/issue10-revmap-counters-260819.txt)
(counters) and [`test-tools/issue10-page-identity-260819.txt`](../test-tools/issue10-page-identity-260819.txt)
(the page-identity capture).
Write-watch capture (§10): [`test-tools/issue10-writewatch-260819.txt`](../test-tools/issue10-writewatch-260819.txt).
Instrument: [`src/i10rev040.s`](../src/i10rev040.s) — the counters, `i10p_probe`, and `i10w_hook`.
Guest drivers: [`test-tools/i10bench.sh`](../test-tools/i10bench.sh),
[`test-tools/i10probe.sh`](../test-tools/i10probe.sh),
[`test-tools/i10w.sh`](../test-tools/i10w.sh). Probe:
[`test-tools/shmband.c`](../test-tools/shmband.c).
**Sections 14 and 15 are the current state of this document**; sections 2, 6, 11 and 12 record
readings that §14 has since overturned, and are kept because each of them is how the next one was
reached. Resolution audit: [`test-tools/i10r.sh`](../test-tools/i10r.sh).

## Summary

Running a 68040 install miniroot, `/bin/sh` dies while reading a ~77 KB shell script with a flood
of

```
NOTICE: User BUS ERROR at 4AFC0003, PC:800023FC FAULT:6 PID:20 CMD:sh -n /cdrom/install/bin/setup.sh
```

and then `no space`. That is byte-for-byte the signature `KNOWN-ISSUES.md` records for ISSUE-10's
**`amixadm` trigger, which was retired on 2026-07-15 as no longer firing** — same fault address,
same PC, same fault class. It fires again here, and it is **deterministic**: one command, no
memory pressure, no fork storm.

Three mechanisms were on the table; the counters settled two of them and re-aimed the third. A
second instrument found the page (candidate D); a third — a frame census (§9) — then refuted the
stale-fill reading of it (candidate E) and left a mis-addressed write standing; a fourth — a
write-watch (§10) — then caught that store and **refuted the mis-addressing** too: it is `/bin/sh`'s
own correctly-addressed allocator carrying a corrupt free-list **link**. A fifth — a value-triggered
genesis watch (**§11**) — then found what put `0x4AFC0000` there: a **USER store** in `sh` whose landed
value has **no source** (its operands all point at valid `sh` tokens; the value is in no register and is
not an immediate). That closes "kernel or user" — it is a user store, not a kernel one — and promotes
**candidate C**, the **68040 write-back-fidelity** family, from "untested" to measured: the value is
fabricated by the 040 store/write-back mechanism, `0x4AFC` is the `ILLEGAL` opcode, and the 68060 (whose
write-back path differs) does not reproduce it. Two limits are stated in §11: the capture routes through
`wb040_replay`, and none of this has run on real 040 silicon — so the wall may be a 68040 **emulation**
defect that does not occur on hardware.

**That verdict is overturned, the same day, by §14.** An emulator-side watch — which perturbs the
guest not at all — traced the chain end to end. `0x4AFC0000` is **not fabricated by anything**: it is
the kernel's own `ILLEGAL`-at-null sentinel, read *legally* through user VA 0 after `sh`'s free-list
walk followed a **NULL** link. The NULL is there because the arena's end-of-arena marker store
**vanished** — a user write-class first-touch fault on a freshly `brk`'d anon page for which the
68040 pushed a **valid pending write-back** and the kernel returned **as-if-resolved**: nothing
mapped, nothing zero-filled, no store replayed, no signal posted. The genesis is therefore
**kernel-side, on the 040 lane**, the emulator is exonerated by both its source and a NetBSD
cross-check, and the confound §12 and §13 spent two instruments on dissolves — there was no
fabrication for the write-protect to be an artifact of. §15 is the instrument built to name the
branch inside `usrxmemflt` that swallows the fault.

| | Candidate | Verdict |
|---|---|---|
| **A** | One of the bounded-256 reverse-map unlink paths gives up on exhaustion, leaving a stale `p_mapping` after the PTE is removed | **REFUTED** — all three give-up counters are 0 across every reproduction, and no search ever walked half its budget |
| **B** | The eight-site SysV shm 2 KiB anon-map mismatch | **CONFIRMED as a live defect, but a different bug** — it panics, deterministically, in its predicted band; `sh` never calls `shmget` |
| **C** | Amiberry 68040 format-$7 write-back infidelity | **OVERTURNED — §14.** The value has a source and it is the kernel's own `ILLEGAL`-at-null sentinel, read through user VA 0; nothing fabricates it. The emulator arms the write-back correctly (its own source, plus NetBSD/amiga 9.2 running byte-perfectly on the same rig). §11's "no source" was an instrument artifact: `i10g`'s pointer chase never chased VA 0 through the user map. What is 040-specific is the **kernel's** handling of the fault, not the CPU's arming of it |
| **F** | The 040 lane's user fault path returns **as-if-resolved** for a first-touch WRITE on a freshly `brk`'d anon page — mapping nothing, signalling nothing, and never replaying the valid pending write-back the CPU handed it | **CONFIRMED (measured) — §14.** Three arena grows, three format-7 write faults, every one with `wb3v=1 wb3s=81 wb3d=800114b5`; for the fatal one the physical frame backing the address shows no mapping, no zero-fill, no replayed store on any chain, no nested fault and no signal, and `sh` runs on. The page is mapped and zero-filled five ticks later by the *read* fault that follows — so the marker is overwritten by zeros that arrive after it |
| **D** | The page holding the corrupt word is a frame that is, or recently was, a kernel u-area page — the phys double-use / page-lifetime family | **REFUTED** — §4. The page is an ordinary, correctly-mapped, singly-mapped anon heap page of `sh`'s own arena with an intact reverse map, holding **one** wrong longword |
| **E** | The frame was handed to the anon page with its upper 2 KiB uncleaned — a fill that stopped at `0x800`, so `0x4AFC0000` is a prior owner's content (the Model-B tail-zero family) | **REFUTED** — §9. A frame census shows the upper half is 80% zero with a 343-long contiguous zero run, and the bad word sits in valid `sh` arena among ASCII tokens; the frame was zero-filled correctly. The named 2 KiB tail-zero sites are all already `0x1000` in this kernel. What remains is **H2**: a mis-addressed single-longword write |

## 1. Candidate A — refuted, with the reading that makes zero mean something

`src/i10rev040.s` adds uncapped counters, in the shape of `kdbg040.s`'s `hat_pfnmiss_n`, at the
three places that walk a page's `p_mapping` chain with a 256-node bound and then carry on when the
bound runs out: `hat_pteload`'s replacement path (which was **completely silent**), `hat_unload`
and `hat_free` (which print through a cap of 4 and then go dark for the rest of the uptime).

The fourth site on the list, `hat_dup040`, turned out to have no bounded unlink loop to
instrument: it never *searches* a chain, it only pushes onto one. It is therefore not a consumer
that can give up — it is the **producer** that makes chains long enough for the other three bounds
to matter, so what it contributes is that rate.

```
sample                 rpfail  hlfail  hffail   dupreg   deep
baseline                    0       0       0      478      0
after-mount                 0       0       0      663      0
after sh -n setup.sh        0       0       0      944      0   <- wall fired
after sh -n install.sh      0       0       0     1129      0   <- wall fired
after sh setup.sh #1        0       0       0     1364      0   <- wall fired
after sh setup.sh #2        0       0       0     1599      0   <- wall fired
after sh setup.sh #3        0       0       0     1834      0   <- wall fired
```

Three things make this a result rather than an absence:

* **The counters are demonstrably live.** `i10_dupreg_n` moves by **exactly +235** across each of
  the three identical full runs. A dead link or an unlinked island reads zero too; this one does
  not. Four further independent boots on 08-19 reproduced the same shape (`dupreg` 0x21d, 0x33a,
  0x5e7, 0x653; the three fail counters 0 and `deep` 0 in every one).
* **`i10_deep_n` is 0.** No successful reverse-map search anywhere walked even 128 of its 256-node
  budget. So the give-up counters are not zero because the workload got lucky — the bounds were
  never within reach of being exhausted. "Did not happen" and "could not have happened" are
  different claims, and this is the second one.
* **The address was verified before the numbers were believed.** `i10_magic` reads `I10!`, and the
  same offset at the other candidate load base reads zeros throughout — which is also how the load
  base was established, this rig having no accelerator RAM.

## 2. What the wall is at the instruction level — and the one claim in it that was wrong

`PC:800023FC` sits in `/bin/sh`'s own allocator. Disassembling the miniroot's `sh` at that address
gives the free-block coalescing loop:

```
800023f8:  movel  %a1@,%a0@       p->word = q->word     (write)
800023fa:  moveal %a0@,%a1        q = p->word           (read back)
800023fc:  btst   #0,%a1@(3)      busy(q)?              <-- faults
80002402:  beqw   0x800023f8
```

So the fault address `4AFC0003` is `q + 3`, and the free-list link `q` read out of `sh`'s arena is
**`0x4AFC0000`**. `FAULT:6` is FLTBOUNDS: the kernel is correctly refusing a user access to an
address that is not in the process's address space. The repeats and the closing `no space` are
Bourne `sh`'s own catch-and-retry-after-`sbrk` behaviour giving up, not a kernel fault loop.

**What was wrong.** The 08-19 morning reading of this document said `0x4AFC0000` is
`kvsegu + 0x2B80000` and therefore "a pointer into the kernel's u-area virtual segment". The
arithmetic is right and the conclusion does not follow: `kvsegu` is `[0x48440000, 0x48480000)`,
256 KiB, so `0x4AFC0000` lies about 45 MB **past its end**. It was a distance from the nearest
named symbol below it, not a containment.

The live kernel now says so directly. `i10p_probe` resolves the value through the kernel's own
region-1 tree, exactly as `vatosde`/`vatopte` would:

```
i10p_kdesca  07105cfc     &kptr040[((0x4AFC0000>>18) - 4096) * 4]
i10p_kdesc   00000000     UDT 0 -- there is no pointer table for that VA at all
```

reproduced in every capture run. **`0x4AFC0000` is not a kernel address of any kind** — not
`kvsegu`, not `kvsegmap`, not `kvseg`, not mapped anywhere in region 1. It is a value with no
kernel meaning, and the whole "u-area alias" line of reasoning built on it goes with it.

What it *is*, as a bit pattern, is the 68k `ILLEGAL` opcode word `0x4AFC` followed by zeros. That
is a coincidence worth naming rather than a lead: the exact byte string `4A FC 00 00` occurs
**zero** times in the 60 KB of `/bin/sh`, so the value was not copied out of the program's own
text (see §4, where the loose version of that mask did find sh's text and was thrown away).

## 3. The trigger

Worth writing down carefully, because ISSUE-10 has been without a reliable one since 2026-07-15.

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
* **The flood is thousands of faults deep, not the "11–20" recorded this morning.** That figure
  was the number of `NOTICE` lines a console page holds. `i10p_n` counts them: **8048** in the
  capture run, and 16096 in another. Every one is at the same address — `i10p_fa` and
  `i10p_lastfa` both read `4afc0003`.

## 4. What the page actually is

This is the probe the morning's document asked for, and the answer is not the one it predicted.

`i10p_probe` hooks `usrxmemflt`'s unresolved-fault tail — the moment the resolver has given up, the
process is about to be told, and the word it tripped over is still sitting in its own memory in its
own context. It then walks the victim's page tree and looks for the value the fault died on. That
hook was chosen over the mapping side (`hat_pteload`) deliberately: a mapping-time scan can only
see corruption that was already in the frame when the frame was mapped, which is one hypothesis out
of several, and an instrument must not be built so that it can only confirm one of them.

The capture, with the mask set to the free-list **link** the allocator loaded (`0x4AFC0000`, i.e.
the fault address with the `q+3` busy-bit displacement taken back off):

```
i10p_have   1          a page was found, on the FIRST walk (i10p_tries 1)
i10p_pgs    51         resident user pages scanned
i10p_hits   1          exactly ONE of them holds the value
i10p_uva    80014000   its user VA -- sh's heap, past the end of its file image
i10p_hoff   00000aa0   -> the corrupt word is at user address 0x80014AA0
i10p_hitv   4afc0000
i10p_pfn    00007623   i10p_pte 07623039   i10p_ptea 0764c050
i10p_pp     40051058   i10p_pflags 06000000
i10p_vnode  40078704   i10p_off 00036000   i10p_hash 00000000
i10p_map    0764c050   i10p_map0 07623039  i10p_mapn 1   i10p_min 1
w0..w7      6e745f6d 62000000 8001401d 80013ff8 02000000 80011414 00000000 80014031
```

Reading it:

* **It is `sh`'s own arena, and the content says so.** `w0`/`w1` are ASCII (`"nt_m"`, `"b\0\0\0"`);
  `w2`, `w3`, `w5` and `w7` are `0x8001xxxx` pointers back into the same heap, several with bit 0
  set. That is Bourne `sh`'s allocator exactly: block headers holding `next|busy`, interleaved with
  string data. The neighbouring links are intact.
* **The page is anon, not a file page.** `p_vnode` is non-zero, but so is the *stack* page's in a
  second capture — same vnode `0x40078704`, different `p_offset` — which is what one anon/swap
  vnode covering a process's anon pages looks like. There is no file identity here.
* **The reverse map is perfectly intact.** `p_mapping` equals `i10p_ptea`, the address of this
  page's own live leaf PTE; the chain is **one** node long and `i10p_min = 1` says that node is
  this mapping. Nothing stale, nothing missing, nothing doubled. This is the 2026-07-16 `SEGVCHAIN`
  `in=1` result again — now measured on the page that actually holds the corruption rather than on
  a page adjacent to the crash.
* **One word, not a region.** One page out of 51, one longword out of 1024 in it.

So the page is **not** a frame that is or was a u-area, **not** a double-registered file page,
**not** a stale or replaced mapping. It is a healthy, correctly-mapped, singly-mapped anon heap
page with one wrong longword in the middle of it.

That re-aims ISSUE-10 for this trigger. A whole page handed out twice, or a mapping pointing at
the wrong frame, would show as a page whose *identity* is wrong; this shows as a page whose
identity is right and whose *content* has one bad word. The next thing to chase is therefore a
**write that landed at the wrong address**, or a store that was lost and left the slot holding
something else — not a page-lifetime bug. The `p_mapping`/page-reuse family is measured innocent
here, twice, by two different instruments.

**Two masks were tried and thrown away before this one, and both are kept in the record** because
each refutes a reading of the third:

* A 64 KiB **band** mask (`0xFFFF0000`) found 8 pages, and latched `sh`'s own **text** at
  `0x80006000` — whose word at frame offset `0x92C` is `0x4AFC0055`. Verified host-side: the
  frame's first eight longs are that file at offset `0x6000` byte for byte, and `0x4AFC0055` is
  that file at offset `0x692C`. `0x4AFC` is the `ILLEGAL` opcode and occurs at four places in that
  binary. The page was not corrupt; the instrument was. (It also proves the probe reads the right
  frame and reports it accurately, which is why that run is evidence and not just a mistake.)
* An **exact fault-address** mask (`0xFFFFFFFF`) found exactly one word — `0x4AFC0003`, on the
  user **stack**, in a page whose first eight longs are all zero. That is the kernel's own residue
  from an earlier fault in a flood thousands deep, not the corruption.

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
fail". Sizes 1, 2047 and 8193 were not attached; each panic costs a boot.

`IPC_STAT` reports the original byte count for every size including the fatal ones, and every
successful attach is 4 KiB-aligned, so the API-visible contract is intact right up to the point
where the segment is created.

This is a **real defect, reachable by any unprivileged process**, and X11's MIT-SHM is a named
caller. It is **not** the setup.sh wall: it panics rather than faulting, and `sh` never calls
`shmget`. The two share a family — a 2 KiB constant surviving the 4 KiB conversion — but not a
site.

## 6. Candidate C — retracted as a measurement

This morning's document said the `wbf_*` write-back counters read all-zero "while the fault was
firing", and concluded the 68040 write-back replay path is not producing the corrupt link.

**The counters were read, but not across a wall.** In that run the payload slice failed to mount
(`No space left on device`, the read-write mount problem of §7), `setup.sh` could not be opened
(`cannot open`, `rc=1`), and the console for that boot carries **no `User BUS ERROR` line at all**.
An all-zero counter block from a boot in which the trigger never fired says nothing about the
trigger. The summary row that read `(second boot, block F) … <- wall fired` was wrong.

Candidate C is therefore **untested**, not refuted. What remains true, and is from the existing
record rather than from that run, is: `wb040.s:613` states from reading the emulator's source that
it never sets WB1S valid, so those paths have never executed there; the ISSUE-10 progress log
reached the same conclusion on 2026-07-10; the same fault reproduces on **two different emulators**
at the same address; and the **68060 does not reproduce it on the same emulator**. Re-reading the
`wbf_*` block across a wall that actually fires is cheap now and should be done before anyone
quotes this section.

## 7. Reproducing the rig — two staging facts that are not in the kernel or the script

Both cost a run to relearn, and neither is visible in any artifact this repository tracks.

**The kernel needs a two-byte swap-device edit before it will boot this medium.** Built straight
from the tree, it names `/dev/dsk/c6d0s2` as its swap device; on a rig whose install *source* is
the id-0 disk that is the wrong controller, and the boot dies with
`PANIC: swapconf lookupname /dev/dsk/c6d0s2 failed - error 2`. The two fields sit at fixed offsets
from the anchor string `/dev/dsk/c`, which occurs exactly once in the image:
`anchor-0x24` is the `dev_t` (`0x00480016` → `0x00480010`, i.e. `makedevice(18, 22→16)`) and
`anchor+0x0a` is the id digit in the name. The generic host-side rootdev patcher refuses this image
— its contract wants an sd-major root and this miniroot kernel has `rootdev` major 0 — so the edit
is made by anchor and verified by re-reading both fields.

**This presents as a size effect, convincingly.** Adding four bytes of `.data` to the tree
"reproduced" the panic; so did 944 bytes of `.text` and 200 of `.data` of pure padding with no code
change anywhere. Every one of those variants was rebuilt from source and therefore carried the
unpatched `c6d0s2`, while the only kernel that booted was a previously staged one that already had
the edit. Six boots went into that before the two kernels were diffed against each other, which
would have shown it in one step. **The control that was missing was booting one's own rebuild of
HEAD**, and it is the cheapest control there is.

**The payload slice must be mounted read-only.** On any image whose slice 4 was previously mounted
read-write and never unmounted — which is every image a crashed or killed bench run leaves behind
— a read-write mount returns `No space left on device` while the root filesystem is very nearly
empty (154 blocks used). The same slice mounts read-only on the same image immediately, and the
probe only ever reads. A run that cannot mount its source disk still produces a full log of zeroes,
which is indistinguishable from a measurement that found nothing.

## 8. What was not established

* Everything above is **EMU**. The wall has never been run on 68040 silicon.
* Candidate C is untested, not refuted (§6).
* `i10p_comm0..3` (the `u+0x1C0` u_comm read) came back zero in every capture even though
  `i10p_curproc` and `u.u_procp` agree, so the u-area window is the victim's. The offset is
  unconfirmed for this kernel; it is not load-bearing for anything above.
* **Why the word is `0x4AFC0000` specifically is still unexplained.** It is not a kernel address
  (§2), not a copy of `sh`'s own text (§4), and it is the same constant in every fault, every
  process, both of today's boots and the 2026-07-10 `amixadm` captures. A constant that survives a
  reboot and a different program is the sharpest remaining thread.
* The obvious next probe follows from §4 rather than from §2: the page is healthy and one word in
  it is not, so watch the **word**, not the page — trap the write. `sh`'s arena address is known
  (`0x80014AA0` in this run), the trigger is one command, and a write-watch on that longword would
  name the store that puts `0x4AFC0000` there.

## 9. The frame census — the stale-fill hypothesis refuted, the store confirmed

§4 left one reading of the healthy page still open, and it is the one the Model-B work makes most
tempting: the offending word is at frame offset `0xAA0`, in the **upper half** of the 4 KiB page,
and this port's history is full of 2 KiB-era fills that clean only `0x000..0x7FF` of a 4 KiB frame
and leave `0x800..0xFFF` holding a prior owner's content. If that were happening here, `0x4AFC0000`
would not be a *write* at all — it would be **stale frame content** the anon page was handed with
its tail uncleaned, and the fix would be a one-constant change at a named fill site.

`i10p_probe` now censuses the latched frame (`src/i10rev040.s`, the loop in `Lip_hit`): non-zero
longs in each half, the longest run of consecutive zero longs, and the 64-byte block that contains
the hit. Raw readings: [`test-tools/issue10-census-260819.txt`](../test-tools/issue10-census-260819.txt).

```
i10p_nzlo   411      non-zero longs in the LOWER half (512)
i10p_nzhi   102      non-zero longs in the UPPER half (512) -- 410 are ZERO
i10p_zrun   343      longest run of consecutive zero longs = 1372 bytes
i10p_h0..15          the 64-byte block at 0xA80 (the hit is at 0xAA0):
    0xA80  22000000   .  0xA88  69660000 "if"  .  0xA90  5b000000 "["
    0xA98  2d730000 "-s"  .  0xAA0  4afc0000  <-- the hit  .  0xAA4..0xABC all zero
```

Two facts, and they point the same way:

* **The frame was zero-filled correctly — the fill did not stop at `0x800`.** The longest run of
  consecutive zero longs is **343** (1372 bytes). The lower half holds only 101 zeros, so that run
  lies in the **upper half** — the very region the stale-fill hypothesis says should be dense prior
  content. A page whose tail was left uncleaned cannot contain a 343-long zero run; 80% of the upper
  half is zero. The demand-zero path produced a clean frame.
* **The bad word is an isolated anomaly in valid arena.** Its 64-byte block is `sh`'s own parse
  memory for `setup.sh` — the tokens `if`, `[`, `-s` (an `if [ -s … ]` under construction) with
  zero padding between them — and the seven longs immediately after the hit are all zero.
  `0x4AFC0000` is **one** wrong longword surrounded by `sh`'s own content and clean zero-fill, not
  one word of a page full of somebody else's content.

So **candidate E is refuted and H2 is confirmed**: the frame was correctly zero-filled and a
mis-addressed write (or a single-longword store of a wrong value) put `0x4AFC0000` at `0x80014AA0`.
This is not a fill-tail bug and there is no fill constant to change for it. The named 2 KiB tail-zero
sites the hypothesis rests on — `anon_zero`'s `pea 0x800` (`patch_modelb.py`), the block-swap-in
`klustsize` `.data` initializer and `anon_getpage` length (`patch_swapin.py`), the s5/ufs/spec
file-getapage tails, and `segmap_pagecreate`'s five callers (`patch_pagecreate.py`) — are all
already converted to a full `0x1000` clear in this kernel, and this census shows the anon
demand-zero fill they govern holds at run time. The historical `0x4AFC005F`/`0x4AFC0055` avalanche
that the swap-in `klustsize` half-fill produced (stale `sh` **text**) is a different, already-fixed
mechanism; this trigger's `0x4AFC0000` occurs nowhere in `sh` and comes from a store.

The instrument was byte-audited: the census is entirely inside `i10rev040.o` (`.data` +76 bytes =
19 new longs, `.text` +240 bytes for the loop and window copy), every pre-existing `i10p_*` symbol
keeps its offset, and the full kernel links with `TOTAL complaints: 0`. The census kernel reproduces
the wall byte-for-byte (`4AFC0003`, `PC:800023FC`, `FAULT:6`, `i10p_n` = 8048), so the added code
does not perturb the trigger.

**Next.** The write-watch of §8 is now the single remaining thread and it is sharper for this result:
the store is one longword into an otherwise clean, valid page, so it need not pass through `copyout`
and cannot be found by scanning frames — it has to be caught at the moment it lands. Checkpoint
`0x80014AA0` across kernel entry/exit and name the PC of the good→bad transition. `0x4AFC0000` is a
constant across processes, both of today's boots, and the July `amixadm` captures, so the writer is
deterministic and a bracketed checkpoint will find it.

## 10. The write-watch — the store named, and the hypothesis overturned

The store was caught as it landed. `i10w_hook` (`src/i10rev040.s`) write-protects the target page's
leaf PTE (bit 2, the write-protect bit `hat_chgprot040` flips) so every store into it faults; the
stock resolver upgrades the page and `wb040_replay` lands the store; the hook then reads the 68040
format-7 access-error frame and, when the watched longword transitions to `0x4AFC0000`, latches the
whole frame — PC, SR, effective address, the write-back's own address and data, and the 16 saved
registers of the faulting instruction. It hooks the resolved tail of **both** `usrxmemflt` and
`krnxmemflt`, so a kernel store into the user page is named with its exact PC just as a user store
is. It ships dormant (`i10w_on = 0`, one `tstl` per fault) and is armed with a `kpoke` immediately
before the wall. Guest driver: [`test-tools/i10w.sh`](../test-tools/i10w.sh); raw capture:
[`test-tools/issue10-writewatch-260819.txt`](../test-tools/issue10-writewatch-260819.txt).

The wall reproduces byte-for-byte under the watch (`4AFC0003`, `PC:800023FC`, `FAULT:6`, `PID:23`),
so the instrument does not mask the trigger. `i10w_latch_n` is **1** — one unambiguous transition —
after `i10w_fault_n` = **1869** write faults on the page. And the capture is of the wall's own `sh`:
`i10w_armproc` = `0x4013BE00` equals `i10p_curproc` = `0x4013BE00` in the same run.

```
i10w_pc    800023fa     the frame PC (one past the store; the 040 defers the write-back)
i10w_sr    00000000     S bit CLEAR -> a USER store
i10w_w3a   80014aa0     the store's effective address
i10w_w3d   4afc0000     the value the store wrote
i10w_hitval 4afc0000    the target longword after the store landed
regs: a0 80013d2c  a1 80014aa0  a3/a4 80013d14  a5 80013d28   (all sh arena; 0x4AFC0000 in NONE)
```

Verified against `/bin/sh` in the source image at file offset `0x23F8` (VA base `0x80000000`), byte
for byte, this is `sh`'s own free-block coalescing loop:

```
800023f8:  2091            move.l  (a1),(a0)     the STORE: (a0) := *(a1)
800023fa:  2250            movea.l (a0),a1
800023fc:  0829 0000 0003  btst    #0,3(a1)      the flood read -> 4AFC0003
80002402:  6700 fff4       beq.w   0x800023f8
```

**The verdict, and it overturns candidate H2 for this site.**

* The write into `0x80014AA0` is a **USER store** — `SR` S-bit clear, `PC` in `/bin/sh`'s own text —
  not a kernel `copyout`/`bcopy`/`pagezero` and not a mis-addressed store. The `PC` is `0x800023FA`,
  one instruction past the store, because the 68040 defers the store's write-back (`WB3`), which is
  the whole reason `wb040.s` exists; `WB3A`/`WB3D` carry the store's true target and data.
* The store is **correctly addressed**: `(a0)` = `0x80014AA0` is exactly where the coalescing loop
  means to write the link. There is no off-by-N and no wrong base — *intended equals actual* for the
  address. What is wrong is the **value**, not the address, so the "mis-addressed single store" shape
  the morning's H2 assumed does not hold here.
* The instruction is `move.l (a1),(a0)`, a **memory-to-memory copy**, so `WB3D` = `*(a1)`. The poison
  is not an immediate (the byte string `4AFC0000` occurs zero times in `/bin/sh`, §2) and it is in no
  register (see the capture), so it was **copied from another slot of `sh`'s own arena that already
  held it**. This store **propagates** a corrupt free-list link; it does not originate it.

So the corrupting write at `0x80014AA0` is `sh` faithfully carrying a bad free-list link forward until
it dereferences it (`btst #0,3(a1)` with `a1` = `0x4AFC0000`) and walls. The kernel-mis-addressed-store
reading of H2 is **refuted for this site**, and the question moves one hop upstream — but it is now a
*different* question (a corrupt free-list **link**, on a *different* page) than the one §4–§9 framed.

| | Candidate | Verdict |
|---|---|---|
| **H2** | A mis-addressed single-longword store (off-by-N / wrong-base), possibly kernel, poisons `0x80014AA0` | **REFUTED for this site** — §10. The store there is `sh`'s own correctly-addressed coalescing `move.l (a1),(a0)`; the anomaly is the copied *value*, a pre-existing corrupt free-list link |

**Next — the genesis.** The remaining thread is what first wrote `0x4AFC0000` into a free-list link.
That is a *different* address — the copy's source `*(a1)`, which the `a0`/`a3`/`a4`/`a5` = `0x80013xxx`
free-list cursors in the capture place on page `0x80013000`, one this watch (pinned to `0x80014000`)
did not cover. The follow-up is a **value-triggered** watch: protect the arena and latch the first
store whose `WB3` data is `0x4AFC0000`, wherever it lands, and read its PC and SR. Only that capture
closes "kernel or user" for the **genesis** — this one closed it for the propagation. If the genesis
store is itself another `move.l (a1),(a0)`, the chain is walked one hop at a time back to the store
that computes or is handed `0x4AFC0000` from outside the arena; if it is a supervisor store, the
kernel corner of ISSUE-10 is back on the table, now with an exact PC to name.

## 11. The genesis — the value has no source

The write-watch of §10 was built (`i10g_hook`, `src/i10rev040.s`). Raw capture:
[`test-tools/issue10-genesis-260819.txt`](../test-tools/issue10-genesis-260819.txt). It rides the
same resolved-fault tail, write-protects a heap band so the stores into it fault, and for the first
resolved fault whose landed value is the poison records the storing PC and privilege (**PART W**), the
frame it appears in with its fill census (**PART I**), and — the deciding field — the value each of the
store's **address registers points at**. The kernel is byte-audited: a control rebuild of `HEAD` is
identical to the shipped kernel except the 16-byte build-id, and only `i10rev040.o` (the instrument)
and `wb040.o` (its two `jsr` sites) differ from the control; the wall reproduces byte-for-byte under it
(`4AFC0003`, `PC:800023FC`, `FAULT:6`, `PID:23`) and `i10g_armproc` = the wall's own `sh`.

**The §10 guess about the source page was wrong, and measuring it was how.** A first run watched page
`0x80013000` — the page the §10 cursors pointed at — write-protected it, and scanned it after **all
3320** of its forced store faults: `0x4AFC0000` appeared there **zero** times (`i10g_scan_hits = 0`).
The poison does not transit page `0x80013`. Re-aimed at page `0x80014` — the page the wall reads the
bad link from — the watch caught it at once.

```
i10g_wctx  1        usrxmemflt: a USER-fault wrapper
i10g_wsr   00000000 SR S-bit CLEAR -> a USER store, not a kernel copyout
i10g_wpc   800023fa the storing instruction (one past it; the 040 defers the WB)
i10g_wb3a  80014aa0 the store target      i10g_wb3d 4afc0000  the value landed
i10g_iself 3        this store's own WB wrote that offset -> the poison's FIRST
                    appearance in the arena, not a value the frame arrived carrying
i10g_inzlo 411  i10g_inzhi 102  i10g_izrun 343   the page is cleanly zero-filled
a0 80013d2c *(a0) 5b000000 "["     a3/a4 80013d14 *()=24656c65 "$ele"
a1 80014aa0 *(a1) 4afc0000 <- but a1 == WB3A == the DEST this store just wrote
a5 80013d28 *(a5) 5b000000 "["     i10g_wsrcr -1: no NON-DEST register holds it
```

Reading it:

* **WRITTEN, not inherited — settled three ways.** The frame is cleanly zero-filled (census identical
  to §9's), PART I catches the poison's *first* appearance as a store (`iself = 3`), and the companion
  page-`0x80013` run scanned that page 3320 times and never saw the value. The demand-zero fill is not
  the culprit and the value is not prior-owner content — it is stored.
* **A USER store, not a kernel one.** `SR` S-bit clear, `PC` in `/bin/sh`'s own text, caught through the
  user wrapper; the kernel-store wrapper (`krnxmemflt`, ctx 2) never latched. No `copyout`/`bcopy`/
  mis-addressed supervisor write put it there. The kernel corner of ISSUE-10 that §10 left open is
  **closed** for this genesis: it is not a kernel store.
* **The value has no source.** For a `move` that lands `0x4AFC0000`, the write-back data must equal the
  source it copied; but every one of the store's address registers points at a **valid `sh` parse token**
  (`"["`, `"$ele"`), the value is in **no data register**, and it is **not an immediate** (`4A FC 00 00`
  occurs zero times in `/bin/sh`). The only place `0x4AFC0000` exists is in the write-back landing at the
  destination. It was **not copied from anywhere** — it was produced by the 68040 store / deferred
  write-back mechanism itself.

**Verdict — candidate C, promoted from "untested" to measured.** The genesis is the **68040
write-back-fidelity family** (§6's candidate C): a store whose intended source value is a valid link
lands `0x4AFC0000` instead, `0x4AFC` being exactly the m68k `ILLEGAL` opcode, and the fault not
reproducing on the 68060 whose write-back path differs. It is **one 040-specific mechanism and one
constant**, not a per-site fill or VM defect, and it is the same signature the historical `amixadm`
avalanche carried — so it explains that avalanche rather than being trigger-specific.

**Two limits, stated rather than hidden.**

* **The capture routes through `wb040_replay`.** Write-protecting the page forces the store's completion
  through the 68040 write-back replay in `src/wb040.s`, so this run cannot by itself separate "the
  emulator's 040 core fabricates the value on the ordinary store" from "the fault-driven replay
  fabricates it." Both are the same 040-write-back surface. The poison is *independently* real —
  `i10cen.sh` read `0x4AFC0000` at `0x80014AA0` with no write-protection at all (§9) — so it is not an
  artifact of the watch; what the watch adds is that the landed value has no data source.
* **Never run on 68040 silicon.** All of this is emulated, on two emulators, and the 68060 does not
  reproduce it. A store-mechanism defect that is 040-specific and emulator-reproduced may be a **68040
  emulation defect** rather than a port defect — in which case the `setup.sh` wall would not occur on
  real 040 hardware. The follow-up that separates the emulator core from `wb040_replay`, and both from
  silicon, is a **non-write-protect single-step** capture of the ordinary store, plus a real-hardware
  run of the same `sh -n setup.sh`.

## 12. Confound #1 — the ordinary-store trace-watch (`i10t`)

§11's first limit is that **every** i10g capture forced the store to fault (write-protect), routing
its completion through the 68040 deferred-write-back replay in `src/wb040.s`. So the record could not
separate two worlds:

* **world A** — the ordinary, non-faulting store on the emulated 040 already fabricates `0x4AFC0000`
  → the 040 write-back core (the emulator's, possibly silicon's);
* **world B** — the value appears **only** because the write-protect forced the deferred/replay path
  → an artifact of the method, not of the store the wall actually runs.

**Two things narrow this before any new run.**

* **(a) `wb040_replay` is a faithful courier — world B *as a defect in this port's replay code* is
  refuted by inspection.** `wb040_replay` → `Lwb_do` → `Lwb_loop` (`src/wb040.s`) reads the write-back
  **data** from the CPU-pushed access-error frame (`WB3D` at frame `+92`) into `d2`, derives `d1` from
  `d2` alone for the store size, and writes `d1` to the frame's `WB3A` (`+88`) byte-wise. It never
  recomputes the value and never re-reads the store's source operand. So whatever `0x4AFC0000` is, it
  is what the **68040 core pushed** into `WB3D` when the write-protected store faulted — the replay
  only lands it. The genesis is therefore not an arithmetic bug in this port's replay; that reading of
  world B is dead.
* **(b) The live question is ordinary-vs-deferred, and only the ordinary path settles it.** Even with a
  faithful courier, the core could mis-push `WB3D` *only* in the deferred-write-back regime that the
  write-protect forces, and write the correct value on an ordinary immediate store. That is a runtime
  property of the emulated 040 in two regimes; static reading cannot decide it. §9 established that the
  poison *reaches* `0x80014AA0` on a run with no write-protect (`i10cen`, post-mortem) — but not
  *which* store put it there, nor whether that store's source held a valid link.

**The instrument.** `i10t` (`src/i10rev040.s`, PART FIVE; driver `test-tools/i10t.sh`) observes the
store on the path the uninstrumented wall takes. The write into `0x80014AA0` is a **user** store
(§10/§11: `SR` S-bit clear, `PC` in `/bin/sh`'s own text), so the 68040 trace bit is live for it — the
reason the write-watch header (§10) rejected a trace watch, that a kernel store runs with `T` clear,
does not apply here. On the resolved tail of the **ordinary** demand-zero that first brings in the
poison page, `i10t_maybe_arm` sets `T1` in the returning user frame, installs its own vector-9 handler
(saving the stock one to chain and to restore), and records the process. `/bin/sh` then single-steps
with **no page protected**; the handler re-reads `0x80014AA0` each step through the same
resident-or-abandon walk i10g uses, and latches the first transition into the poison, recording:

* `i10t_wbdelta` — `wb_replay_n` across that one step. **Zero proves the store neither faulted nor
  entered `wb040_replay`** — the ordinary path, the replay off it.
* `i10t_srcr` — the address register (a0–a6) that held the poison as a **non-destination** source, or
  `-1` if none did.
* `i10t_before`/`i10t_after`, `i10t_culpc`, and the register file `i10t_r0..r14` with `i10t_pv0..6`
  (what each address register points at) — the raw evidence, instruction-agnostic so the verdict does
  not turn on decoding source-vs-dest from the frame.

**The decision rule** (with `i10t_wbdelta = 0` proving the ordinary path):

* `i10t_after = 0x4AFC0000` and `i10t_srcr = -1` → the ordinary store **fabricated** the value while
  its source held a valid link → **world A**: candidate C stands as an *emulator-measured* effect.
  Silicon — `sh -n setup.sh` on a real 68040 — is then the only remaining decider; nothing on the
  emulator proves a real-hardware bug.
* `i10t_srcr ≥ 0` (a non-destination register already held the poison) → the ordinary store **copied**
  it → **world B**: the genesis is one hop upstream, i10g's write-protected attribution to the store at
  `0x800023F8` was the method artifact, and §11's "explains the `amixadm` avalanche" claim must be
  re-examined, since it rested on that attribution.

**Status — the instrument is built, byte-audited and has now been run; the A/B is a null result (§13).**
The trace-watch kernel is `68040-260819-38`: it links with `TOTAL complaints: 0`, a control rebuild is
byte-identical to it except the single build-id sequence byte, and the only source change from the
genesis kernel is `src/i10rev040.s` (PART FIVE) — every other object is unchanged. That control
rebuild, `68040-260819-39`, is the kernel the run booted. **§13 records it: the arm and the stepping
both worked, the latch never fired, and neither branch of the decision rule above was reached — so
world A vs world B is still not measured.** What is settled without it remains (a): this port's
`wb040_replay` is not the fabricator, so the remaining question is purely whether the emulated 040
store core mis-produces the write-back value on the ordinary path or only under the forced deferred
path.

## 13. The run — a null result, and the instrument's gap

**2026-08-19 · EMU (Amiberry, 68040+MMU, 16 MB, load base `0x07000000`) · kernel `68040-260819-39`**,
the byte-audited control rebuild of `-38` (identical except the build-id byte). Raw capture:
[`test-tools/issue10-i10t-260819.txt`](../test-tools/issue10-i10t-260819.txt) — the decode plus the
guest's own log, byte for byte as `test-tools/i10t.sh` published it into slice-5 block 25696.

**The staging was clean, which is what makes the null worth writing down.** `i10t_magic` read
`49315421` at `0x0710CD7C` and `00000000` at the `0x08` twin, so the live base is the A3000
motherboard one and the block addresses are the right ones. All three base-`0x07` pokes reported `OK`
— `i10g_plo` `0x80014000 → 0` (so PART P write-protects nothing), `i10g_on` `0 → 1` (so `i10g_hook`
runs and reaches `i10t_maybe_arm`), `i10t_want` `0 → 1` — while their `0x08` twins declined (`REFUSED`
for `plo`, `READBACK-MISMATCH` for the other two), which is the base pick confirming itself; the
`rc=5`/`rc=8` in the log are those dead-base pokes, not the live ones. The BEFORE dump is pristine:
`want`/`on`/`armed_t`/`latched` all `0`, `srcr` at its `-1` preset, `stepmax` `0x007A1200`. The
read-only `s5` mount returned `rc=0`.

**The arm worked.** Every field the arm path writes is set:

```
i10t_on        00000001  the watch went live: vector-9 handler installed, T1 set
i10t_armed_t   00000001  the one-shot fired on the first fault into page 0x80014
i10t_proc      4013be00  the traced process -- the same value the genesis run recorded
                         as i10g_armproc, and the process that then died: T1 was set
                         on it alone, and it is the wall's own sh that took SIGTRAP
i10t_oldvec    070da704  the stock vector-9 handler, saved to chain and to restore
i10t_seeded    00000001  i10t_prev holds a real read of 0x80014AA0
```

**The stepping worked too — and saw nothing.**

```
i10t_step_n     0000009f  159 traced instructions for that process
i10t_res_n      0000009f  159 -- every step's read of the target resolved through the
                          resident-or-abandon walk; not one step was abandoned
i10t_prev       00000000  the target's value at the last of those 159 reads
i10t_wbrep_arm  000000e4  228 wb040 replays at the arm
i10t_wbrep_prev 000000e4
i10t_wbrep_now  000000e4  FLAT: wb_replay_n is monotonic and ends where it armed, so it
                          never advanced across the traced window -- no store in those
                          159 instructions faulted, none entered wb040_replay
i10t_latched    00000000  the transition into the poison was NEVER observed
```

Everything downstream of the latch — `before`, `after`, `culpc`, `nextpc`, `lsr`, `wbdelta`,
`wbrep_latch`, `srcv`, `usp`, `r0..r14`, `pv0..pv6` — is still zero. **`i10t_srcr` reads `FFFFFFFF`,
and that is the ship-time preset, not a measurement**: with `i10t_latched = 0` it says nothing about
sources, and reading it as "no non-destination register held the poison" would be reading the
instrument's own default back as evidence.

**Then `sh` died.** The armed `sh -n /cdrom/install/bin/setup.sh` ended with `Trace/Breakpoint Trap -
core dumped` and `WALL rc=133` (128 + `SIGTRAP`), and printed **no `User BUS ERROR` line at all** — the
parse died far short of §3's 34 KiB/38 KiB threshold. 159 instructions is a handful of a parse that
needs millions of them.

**The reading — analysis, not measurement.** 159 steps past the arm the process reached a syscall
boundary. On m68k a `TRAP` executed with `T1` set processes the trap exception and *then* a trace
exception; that trace arrives from the syscall boundary and is handled on the stock path (kernel
syscall handling, stock vector-9 semantics), which posts `SIGTRAP` to the process — `sh` has no
handler, so it cores. The counters are consistent with that route and with no other: `i10t_step_n`
stopped at 159 while `i10t_on` was still `1` and `i10t_proc` unchanged, so the final trace never
reached `i10t_trace` at all — had it done so for this process it would have incremented the counter.
`i10t`'s handler covers **straight-line user stepping** only. Stepping *across* syscalls needs
kernel-side work PART FIVE does not have: clear `T` in the trap-entry frame, and re-arm it at syscall
exit for the armed process alone. That is the instrument's gap.

**The control, same boot.** Immediately afterwards, with the instruments disarmed by `kpoke`
(`i10t_want` `1 → 0` at `0x0710CD80`, `i10g_on` `1 → 0` at `0x0710CB70`; the write-protect band was
already `0` for this run), the same command was run again on the same booted kernel:

```
NOTICE: User BUS ERROR at 4AFC0003, PC:800023FC FAULT:6 PID:43 CMD:sh -n /cdrom/install/bin/setup.sh
... (the full flood) ...
/cdrom/install/bin/setup.sh: no space
```

So under this exact kernel, on this exact boot, the corruption fires on the **fully ordinary path** —
no write-protect, no trace bit, no instrument armed. The null result is the instrument's gap; the bug
did not go anywhere, and the kernel that carries `i10t` is not one that masks it.

**Verdict — null on world A vs world B.** Neither branch of §12's decision rule was reached, because
the latch that both branches read never fired. §11's genesis verdict stands exactly as it stood and
confound #1 stays open: it is still unmeasured whether the emulated 040 store core fabricates
`0x4AFC0000` on the ordinary store or only under the write-protect-forced deferred path.

**Where confound #1 goes next.** The guest-side portable instrument is **parked** — closing its gap
means kernel syscall-path surgery, a large and intrusive change to make for one measurement. The next
probe moves **emulator-side**: an env-gated value watch in the bench Amiberry's 68040 MMU data path
that logs every data read returning `0x4AFC0000` and every data write landing it, with `PC`, `SR` and
the register file, and perturbs the guest not at all — no trace bit, no protected page, no kernel
change, so the guest runs exactly the code the uninstrumented wall runs. It also has a shot at the
bench half of **confound #2**: `0x4AFC` is the UAE core's own `ILLEGAL` marker constant, and both
emulators that reproduce this wall are UAE-derived, so a common-mode emulator defect is a live
hypothesis such a watch can name rather than merely suspect. For the port-level claim — does the wall
happen on a real 68040 — **silicon remains the sole decider**.

## 14. The emulator-side watch — the poison has a source, and the bug is a store that vanishes

**2026-08-19 evening · EMU (Amiberry, 68040+MMU, 16 MB, load base `0x07000000`) · deterministic,
every reading below reproduced on demand.** The probe §13 asked for was built: an env-gated watch in
the bench emulator's own 68040 MMU data path (a five-commit `i10-watch` branch of the Amiberry build
this project benches on), with four capture modes — VALUE (every data access carrying `0x4AFC0000`),
PCWIN (a PC window), ADDR (a virtual address), PADDR (a *physical* frame) — plus decoding of every
68040 format-7 frame the core pushes. It changes no guest byte: no trace bit, no protected page, no
kernel change, so the guest runs exactly the code the uninstrumented wall runs.

The log it produces is the emulator's own output and is not tracked in this repository; the lines
quoted below are from that run. **Measurement and reading are kept apart throughout: what the watch
observed at run time is marked as measured; what was established by reading an image, a symbol table
or source is marked as read.**

### 14.1 `0x4AFC0000` is the kernel's own sentinel, read through a NULL pointer

The one thing §2 through §13 could never explain — *why this constant* — has a plain answer.

* **READ (static, four images).** The byte string `33 fc 4a fc` — `MOVE.W #$4AFC,(0).L`, i.e. *store
  the `ILLEGAL` opcode word at absolute address 0* — sits at file offset `0x73CC` of stock AMIX 2.1,
  of our 2.1c, and of both `unix-040` and `unix-060`. It is stock kernel code, present on every CPU
  lane, and it is why a longword read at address 0 returns `0x4AFC0000`: the sentinel word followed
  by the zeros after it.
* **MEASURED.** The watch caught the read itself. `/bin/sh`'s `alloc()` free-block **coalescing walk**
  (`blok.c`; the loop at user VA `0x800023C8..0x8000245C`, rover `blokp` at `0x80010F08`) followed a
  link that was **NULL** and read the longword at user VA 0 — legally, no fault — getting
  `0x4AFC0000`. That value is then carried forward as a free-list link exactly as §10 measured, and
  dereferenced at `q+3` = `0x4AFC0003`, which is the wall.

**So §11's central claim — "the value has no source" — was an instrument artifact, and naming the
artifact matters more than retracting the claim.** `i10g` scanned the store's address registers and
what each pointed at, and concluded that nothing the store could have copied held the poison. It was
right about the registers and wrong about the conclusion, because the source it never considered was
**user VA 0**: its pointer chase resolved candidates through the process's own page map and a NULL
pointer is not a candidate any such chase produces. An instrument that cannot see the one source that
matters reports "no source" with perfect internal consistency.

### 14.2 The NULL comes from a store that never happened

`sh`'s `addblok` grows the arena and then writes the **end-of-arena marker** — the value `_end+1` —
to the new `bloktop`, which is what terminates the coalescing walk.

* **READ.** From the miniroot `sh`'s own symbol table: `_end` = `0x8000F6F8 + 0x1DBC` = `0x800114B4`,
  so the marker value is `0x800114B5`.
* **MEASURED.** For the fatal grow the marker's destination is user VA `0x800152A0`. **That store
  vanishes.** The longword at `0x800152A0` never becomes `0x800114B5`; it becomes zero, and a walk
  that reads zero where its terminator should be follows a NULL link into §14.1.

### 14.3 The CPU handed the kernel a valid write-back, three times

Every format-7 frame the core pushed was decoded. The marker store faults on **each** arena grow —
first touch of a fresh page — and the three of them are identical in everything that matters:

```
grow 1  fa=80012688   grow 2  fa=80014530   grow 3  fa=800152a0   <- the fatal one
all three:  ssw=0401   fc=1 (user data)  rw=W  sz=L  atc=1
            wb3v=1  wb3s=81  wb3d=800114b5
            stacked pc = ipc = 8000250e        (deferred write-back: PC is past the store)
```

This is the architectural contract working exactly as `wb040.s` was written for: the 68040 does not
re-run a faulted write on `rte`, it hands the operating system the pending store in WB3 and expects
it back. `wb3s=81` is *valid, size long, TM 1*; `wb3d=800114b5` is the marker; `wb3a` is the
destination. Nothing here is ambiguous or empty.

### 14.4 The emulator is exonerated — twice, and by two different kinds of evidence

* **READ (emulator source).** The path that produces these frames is a table-walk fault →
  `mmu_bus_error(write=true, val)` → `wb3_status = 0x80 | ssw`. The write-back is armed with the
  store's own data, on the same code path for every write fault; there is no branch on which it is
  armed empty.
* **MEASURED (cross-check).** NetBSD/amiga 9.2 boots and runs on **the same emulated 040+MMU rig**
  and completes a 200 000-entry `awk` heap-hash **byte-perfectly**. NetBSD does its own format-7
  write-back replay, from the same frames, and its heap survives a workload far heavier than `sh -n`.
  An emulator that dropped write-backs could not produce that result.

So the write-back arrives, correctly armed, and something on the AMIX side does not land it. The
"world A vs world B" question §12 built an instrument for, and §13 failed to answer, **dissolves**:
both worlds presupposed a fabricated value, and there is none.

### 14.5 What the kernel did with the fatal fault: nothing, in five distinct ways

The physical frame backing `0x800152A0` for the fatal grow is `07E8E2A0` (deterministic across runs).
Watching that **frame** rather than the VA removes every question about which mapping is being
observed. In order, all measured:

1. **tick ~153** — the write fault is pushed (the frame of §14.3).
2. Then, for that fault: **no mapping** is established, **no zero-fill** runs, **no replayed store**
   lands — user or supervisor, on any chain, including `MOVES` under any DFC — **no nested replay
   fault** is taken, and **no signal** is delivered: `sh` simply continues.
3. **five ticks later** the *walk's own read* — `btst #0,3(a1)` — faults on the same page: format 7,
   `rw=R`, `sz=B`, `fa=800152a3`, `ssw=0521`, `wb3v=0`.
4. **That** fault maps the page and zero-fills it (the kernel fill loop at `pc=0700032c`, opcode
   `20c9`; an earlier, unrelated fill of the same recycled frame ran at `pc=070002e8`).
5. The walk then reads the zeros that arrived *after* its marker should have been written, copies the
   NULL, dereferences it, reads `0x4AFC0000` from VA 0, and walls on `btst` at `0x4AFC0003`.

Point 2 is the defect and point 4 is why it is invisible from inside the guest: the page *does* get
mapped and zero-filled, just by the wrong fault, five ticks too late and with the marker's slot
zeroed rather than written. Every post-mortem probe in §4 through §11 was looking at a page that had
been correctly zero-filled — because it had been, by the read fault.

### 14.6 Cross-CPU, same disk, same script

| lane | result |
|---|---|
| **68040** (`unix-040`) | the wall, onset **< 35 s** — the fatal grow happens early in the parse |
| **68060** (`unix-060`, the same sentinel bytes in its image) | **no wall**, and no completion in ≥ 5.5 min |
| **68030** (stock golden) | **no wall**, and no completion in ≥ 50 min |

Two things follow, and they are different claims. First, the whole-file `sh -n` parse is
**quadratically pathological on every CPU** — neither the 030 nor the 060 finished it — so "the 030
handles this script fine" was never true and is not the contrast that matters. Second, **only the 040
lane corrupts**: the other two are slow, not wrong. The wall is not about parsing cost; it is about
what the 040 fault path does with a first-touch write.

### 14.7 The conclusion, and how far it reaches

**The genesis is kernel-side, on the 040 lane.** A **user write-class first-touch fault on a freshly
`brk`'d anon page** returns as-if-resolved while mapping nothing, signalling nothing, and never
replaying the valid pending write-back the CPU handed over. That is one mechanism, and it is not
specific to `sh`, to `setup.sh`, or to the arena:

* **Every first-touch WRITE to a fresh anon page on the 040 line can silently vanish.** The setup.sh
  wall is a *tripwire*, not the bug — it is merely the shortest path from a lost store to a visible
  death, because the lost store happens to be a data structure's terminator.
* It **plausibly explains the historical `amixadm` avalanche** (`KNOWN-ISSUES.md`, ISSUE-10's original
  trigger): the same fault address and the same constant, produced by the same lost-store mechanism
  in a different program. That is a reading, not a measurement — the avalanche has not been re-run
  under this watch.
* It is **silicon-relevant**. Nothing emulator-specific remains anywhere in the chain: the CPU
  behaviour (deferred write-back on a write fault) is the architecture, the emulator arms it
  correctly, and the part that fails is our own kernel's fault path. §11's "this may be an emulation
  defect that does not occur on hardware" no longer applies — if anything the risk is the reverse,
  since real silicon fills the write-back slots more aggressively than the emulator does — the
  ISSUE-11 note in `src/wb040.s` records that WinUAE and Amiberry never set WB1S valid at all, and
  the first real-hardware `Lwb_fail` landing came from a WB aimed at a page `as_fault` never touched.

**What is still not established.** *Which* branch of `usrxmemflt` returns the as-if-resolved verdict,
and therefore what the fix is. The watch can see that the kernel did nothing; it cannot see where
inside the kernel the doing-nothing happens, because it observes memory and frames, not control flow.
That is exactly one instrument's worth of work, and §15 is that instrument.

## 15. PART SIX — `i10r`, the resolution audit

**Purpose.** Latch **one** watched fault from inside the fault path and record what each stage of it
decided, so the swallowing branch is *named* rather than inferred. Instrument:
[`src/i10rev040.s`](../src/i10rev040.s) PART SIX; guest driver:
[`test-tools/i10r.sh`](../test-tools/i10r.sh). It ships **dormant** (`i10r_watchva = 0`) and is armed
with a single `kpoke` of the address to audit — `0x800152A0` for the fault of §14.3.

**Where it hooks, and why both ends.** `usrxmemflt` only, at two sites in `src/wb040.s`: `i10r_pre`
just before the wrapper calls `usrxmemflt_orig`, and `i10r_post` at the wrapper's single exit join.
Two ends are necessary because the question is *what the wrapper did*. The resolved tail where
`i10w_hook` and `i10g_hook` ride is reached only by faults that resolved, so a fault returning
nonzero would leave the whole block at its ship-time zeros — and §13 is this document's own record of
how easily a ship-time default gets read back as a measurement. The exit join is downstream of every
path the wrapper has. `krnxmemflt` is deliberately not hooked: the measured frame carries `fc=1`, a
user-data access.

**What it records** (79 longs, magic `I1R!`, `kpeek <i10r_magic> 79`):

| field | what it answers |
|---|---|
| `i10r_frame` | the frame **pointer value** `%fp@(8)` the wrapper received |
| `i10r_pre_w1s/w2s/w3s`, `…_w?a`, `…_w?d` | the write-back status **words** at `+78/+80/+82` and the address/data longs at `+88/+92/+96/+100/+104/+108` — read from that pointer at exactly the offsets and widths `wb040_replay` uses. These are the fields the emulator's WB7 line prints, so *kernel reads ≠ CPU pushed* is directly visible |
| `i10r_post_*` | the same fields at the wrapper's exit — any difference is a rewrite between the two |
| `i10r_ret` | the verdict `usrxmemflt` returns (the wrapper's `d4`) |
| `i10r_sisig/sicode/siaddr` | the `k_siginfo_t` it returns it in — `si_signo` is the field `u_trap` selects its fault class from and `trapsig` queues nothing while it is 0, so "no signal was delivered" becomes a reading of the field that actually decides it |
| `i10r_pt_pre` / `i10r_pt_post` | `ptest` — *the same routine the stock classifier branches on* — for the fault address before and after the resolver. `0x400` both times means the resolution mapped nothing |
| `i10r_mmusr_pre/post` | the raw 68040 MMUSR for the same VA (R, W, M, B), which the 030-form result throws away |
| `i10r_pte_pre/post`, `i10r_tv_pre/post` | the leaf PTE and the longword at the address, before and after: *did anything get mapped* and *did the store land*, as two numbers each |
| `i10r_wb_d` | `wb_replay_n` across the fault = write-back slots actually re-issued. **0 while `i10r_dec3 = 1` is the finding in two numbers** |
| `i10r_wbfail_d`, `i10r_wbsig_d`, `i10r_x60sig_d`, `i10r_wbf_addr/wbs` | whether a write-back was permanently **denied** rather than never attempted, and whether the wrapper replaced `d4` with a signal number (both zero ⇒ `i10r_ret` *is* `usrxmemflt_orig`'s own return) |
| `i10r_r0..r15` | the 16 saved registers of the faulting instruction |
| `i10r_seen_n / match_n / nest_n / alien_n / post_n / pend / latched` | the arming and nesting accounting; **read `i10r_latched` first** — with it 0 every field above is ship-time state |

**Derived is kept separate from measured.** Exactly four fields are computed rather than observed:
`i10r_dec1..3` decode each write-back slot the way `wb040_replay`'s own gating would (bit 7 valid;
a WB2 with `SIZE = LINE` skipped by name), and `i10r_branch` decodes the stock classifier's branch
from `i10r_pt_pre` and the SSW exactly as [`src/usrxmemflt040-design.md`](../src/usrxmemflt040-design.md)
maps them for this kernel:

```
1 = 030 B  (0x8000)          -> 5af6e, SIGSEGV err 9
2 = 030 S  (0x2000)          -> 5af8c, err 11
3 = 030 L|I (0x4400)         -> 5afb2 SET -> the F_INVAL demand path at 5aff6
4 = 030 W  (0x0800) + WRITE  -> 5b040/5b050 -> as_fault(F_PROT)
5 = 030 W  (0x0800) + READ   -> 5b0f2 hardbus
6 = no fault bits at all     -> 5b0f2 hardbus, with nothing to resolve
```

The decode has to be separate from `i10r_wb_d` precisely so the two can **disagree**: "the frame said
there was a store to land" and "a store was landed" are different claims, and a unit that merged them
could not report the defect §14 measured.

**What it does not do, stated rather than hidden.** `as_fault`'s own `(addr, type, rw)` triple is
**not** captured. The call site is inside the stock resolver's body, so reaching it means either a
byte patch of stock code or wrapping `as_fault` for every caller in the kernel, and neither is
proportionate to one measurement. What is captured is the branch that *chooses* those arguments —
`ptest`'s result and the SSW jointly determine it — so if the audit lands on branch 3 (the `F_INVAL`
demand path) then `as_fault`'s arguments become worth the intrusion, and not before. Two smaller
limits: the audit calls `ptest` twice, and a 68040 `PTEST` loads the ATC entry it walks — the stock
classifier's own `ptest` does the same microseconds later, and `i10r_ptest_on = 0` turns both calls
off in one `.data` long if that is ever suspected of perturbing what it measures; and the audit is
one-shot per boot by construction.

**How to run it.** `i10r.sh` stages `kpeek`/`kpoke` out of the raw slice, verifies the load base by
reading `i10r_magic` at both candidates, dumps the block before and after, arms `i10r_watchva` (the
only poke it makes — `i10g_on` and `i10w_on` stay 0, so **nothing is write-protected** and the audited
fault is the ordinary one), mounts the payload slice read-only, runs `sh -n /cdrom/install/bin/setup.sh`,
and publishes its log at slice-5 block 25728. If the exact address never presents — a run whose arena
grows differently would not produce it — a second pass in the same boot widens `i10r_famask` to
`0xFFFFF000` and re-aims at the whole page, which is the same event with a coarser aim.

**Expected reading, if §14 is right.** `i10r_pre_w3s = 0081`, `i10r_pre_w3a = 800152a0`,
`i10r_pre_w3d = 800114b5`, `i10r_dec3 = 1` — and `i10r_wb_d = 0`, `i10r_ret = 0`, `i10r_sisig = 0`,
`i10r_pte_post = 0`. `i10r_branch` then names the branch that produced that verdict, and the fix
follows from which one it is. Any other shape is more interesting still: `i10r_pre_w3s = 0` with the
emulator's WB7 line showing `wb3v=1` would mean the kernel's *read* of the frame is the defect, which
is a different bug in a different file.

**Build state.** The audit kernel is `68040-260819-41`: it links with `TOTAL complaints: 0` and
`bindings failing: 0`, only `i10rev040.o` (the instrument) and `wb040.o` (its two `jsr` sites) differ
from a build of the same tree without it, all 404 pre-existing symbols in `i10rev040.o` keep their
offsets, and a control rebuild (`-42`) is byte-identical to it except the single build-id sequence
byte. `relink-040.sh` refuses a build whose user-fault path would call an unbound `i10r_pre` or
`i10r_post`, in the shape the `i10w_hook`/`i10g_hook` guards already use. **It has not been run on the
bench yet** — the block ships all-zero and dormant, and no reading in §15 is a measurement.
