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

| | Candidate | Verdict |
|---|---|---|
| **A** | One of the bounded-256 reverse-map unlink paths gives up on exhaustion, leaving a stale `p_mapping` after the PTE is removed | **REFUTED** — all three give-up counters are 0 across every reproduction, and no search ever walked half its budget |
| **B** | The eight-site SysV shm 2 KiB anon-map mismatch | **CONFIRMED as a live defect, but a different bug** — it panics, deterministically, in its predicted band; `sh` never calls `shmget` |
| **C** | Amiberry 68040 format-$7 write-back infidelity | **MEASURED — §11.** The genesis store lands `0x4AFC0000` while every operand it could have copied from holds a valid `sh` token, the value is in no register and is no immediate: the write-back value has no source, so it is fabricated by the 040 store/write-back mechanism. 040-specific (the 68060 does not reproduce), constant (`0x4AFC` = `ILLEGAL`). Confounds stated in §11: the WP capture routes through `wb040_replay`, and it has never run on 040 silicon — it may be an emulation defect |
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
