# AMIX 68040/68060 DMA Initiator Census

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/DMA-INITIATOR-CENSUS.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** The current A3000 configuration uses the
> A3091/SDMAC row as its sole host-RAM DMA owner. Its B2 prepare/complete hooks
> are implemented and hardware-accepted. The A2090, A2091, and native `hd`
> rows remain complete patch anchors for configurations that enable those
> controllers, but they are not covered by the current acceptance claim.

## Scope and target

This is the static DMA-coherency gate for the writethrough data-cache pilot
(`B1`) and the later copyback stage (`B2`). It answers four separate questions
for every machine-side transfer engine:

1. Does the engine access host RAM, chip RAM, or memory local to an expansion
   board?
2. Which CPU-visible alias supplies or consumes that storage?
3. Where does software transfer ownership to the engine and take it back?
4. Which cache operation is required in B1 and B2?

No kernel source or binary is changed by this audit. Zorro III devices and the
B2 low-physical-alias implementation policy are outside this census.

Target:

- kernel commit:
  `8c0772a7ee8497e1dd63966262a4419a776e58cc`
- `build/unix-040` SHA-256:
  `ef63f751c5059245d4ffd0696bde338cbab08d5b7d98c54f1b3e1a19d53edc03`
- ELF `.text` address/file-offset relation:
  `file_offset = text_address + 0x34`

The mounted files under `vanilla/usr/sys/amiga` and the corresponding files
under `kernelsupport/amix-src/sys/amiga` compare byte-for-byte for every source
file cited here. Current linked symbols, relocations, register stores, and
callback order were checked independently in `build/unix-040`.

Both target CPUs use 16-byte data-cache lines. All endpoint and line-sharing
decisions below use that size.

Evidence grades used below:

- **linked**: instruction and relocation checked in the target binary;
- **AMIX source**: mounted AMIX source agrees with the linked control flow and
  register use;
- **exact exp**: the complete linked function body is also byte-provenanced
  through the named mounted `exp` object.

## Direction terminology

The old drivers use disk-oriented names. This note uses unambiguous device
directions:

| Term | Old `buf`/SCSI term | Meaning |
|---|---|---|
| `FROM_DEVICE` | `B_READ`, `sdcom.reading == TRUE` | device writes memory |
| `TO_DEVICE` | `B_WRITE`, `sdcom.reading == FALSE` | device reads memory |

In B1, ordinary cacheable RAM is writethrough. `TO_DEVICE` therefore sees
current RAM without a push. `FROM_DEVICE` can leave stale but valid CPU cache
lines and requires completion-side invalidation before any callback exposes
the bytes.

In B2, `TO_DEVICE` additionally needs a pre-DMA push. `FROM_DEVICE` needs
prepare and complete operations, including explicit partial-cache-line
handling.

## Verdict

The configured kernel has four host-RAM DMA implementations:

1. A2090 SCSI DMA, shared by generic SCSI disk, tape, and SCSI control traffic;
2. A2091 SCSI DMA, including its chip-RAM bounce path;
3. A3000 internal A3091/SDMAC SCSI DMA;
4. the native A2090 ST-506 `hd` path.

These were the only B1 cache-hook owners in the pinned pre-hook image. All
four then armed and completed DMA without a data-cache operation; the current
A3091 status is recorded above.

This also corrects one shorthand in the task description. The mounted
`driver/hd.c` is the native A2090 ST-506 path. WD33C93 SCSI requests originate
in `alien/dd.c`/`ct.c` and reach either the A2091 DMA front-end or the A3000
A3091/SDMAC front-end.

Paula floppy, audio, bitplane, copper, and the one kernel blitter operation use
low chip RAM. With DTT0 unchanged, that CPU alias is cache inhibited. The
screen mmap path is an unmanaged `hat_devload` mapping and B1 classifies it
NCS. These engines therefore require no B1 or B2 cache operation while that
noncacheable-only invariant remains true.

The A2065 result is more precise than the earlier phrase "PIO only":

```text
the LANCE performs DMA, but only within the A2065's on-board RAM;
the host CPU copies between STREAMS memory and the board aperture.
```

No host physical address, PFN, `vtop` result, or KMA buffer is published to the
LANCE. A2065 therefore needs a noncacheable board aperture, not a host-RAM DMA
prepare/complete hook.

## Initiator matrix

`arm/complete` addresses are linked text addresses in the target image.
`CPU alias` records the alias actually used by software, including an
additional cacheable alias that can remain live over the same physical page.

| Initiator / clients | Direction and buffer source | CPU alias | Arm / complete anchors | Current cache ops | B1 requirement | B2 requirement | Line-boundary hazard | Recommended patch site |
|---|---|---|---|---|---|---|---|---|
| A2090 SCSI; `dd`, `ct`, generic SCSI commands | both; buffer cache, B_PAGEIO, raw/tape, and static control buffers in host RAM | `sdcom.addr` is a physical/direct low alias from `vtop`; the original kernel or user VA may remain WT | `startdma 0xc580`, arm `0xc5de`; `stopdma 0xc5f0`; completion cases call stop at `0xc418` and `0xc4c0`, callbacks at `0xc428` and `0xc514` | none | `FROM_DEVICE`: invalidate all DC after every stop and before callback; `TO_DEVICE`: none | prepare before `startdma`; complete after each stop; retain a range snapshot | yes: raw/tape and short control buffers need not cover whole lines | B1 complete in both `a2090intr 0xc37e` stop gaps; B2 prepare in `start 0xc25e` before `startdma`; override recommended |
| A2091 SCSI direct path | both; same SCSI client classes, direct host RAM below its DMA limit | physical/direct low alias plus possible WT/CB kernel or user alias | `startdma 0xcc18`, arm `0xcd2a`; `stopdma 0xcd3c`, hardware stopped by `0xcd68` | none | `FROM_DEVICE`: invalidate all DC before `stopdma` returns to `service`; `TO_DEVICE`: none | prepare before arm, complete after stop; one pair per disconnect/reconnect segment | yes, especially raw/tape/control traffic | prepare after `rp` and `tc` are known, before the direct/bounce split at `0xccb0`; complete at the `stopdma` tail before `0xcdbc`; override recommended |
| A2091 SCSI bounce path | both; original host RAM plus temporary `MEMF_CHIP` DMA buffer | bounce alias is low chip/NCS; original copy uses the physical low alias while a high cacheable alias may remain | write-side copy `0xccec..0xcd08`; arm `0xcd2a`; read-side copy `0xcd86..0xcda6`; free ends `0xcdb8` | none | `FROM_DEVICE`: invalidate all DC **after** bounce-to-original copy and before callback; `TO_DEVICE`: none under WT | prepare original range **before** original-to-bounce copy; complete original range after bounce-to-original copy | yes: `AllocMem` base is 32-byte aligned, but tape/control lengths and endpoints can be partial | prepare before `0xccec`; complete at `0xcdbc`; same A2091 override |
| A3000 internal A3091/SDMAC SCSI | both; buffer cache, B_PAGEIO, raw/tape, and control buffers in direct 32-bit host RAM | physical/direct low alias plus possible cacheable original alias | `startdma 0xd40a`, address `0xd4ae`, arm `0xd4b2`; `stopdma 0xd4cc`, quiesced by `0xd50a` | none | `FROM_DEVICE`: invalidate all DC after each stop and before callback/requeue-visible consumption | prepare before `0xd4b2`; complete after stop; snapshot each reconnect segment's start/count | yes: generic SCSI clients include short and unaligned ranges | prepare in `startdma`; complete at `stopdma` tail before `0xd510`; override recommended |
| native A2090 ST-506 `hd` | both; block buffer, B_PAGEIO, or raw user host RAM | `vtop(paddr(bp), bp->b_proc)+off`; original `buf`/user VA may be cacheable | `hdstart 0xf3a6`, arm `0xf484`; `hdintr 0xf4f6`, controller acknowledged/stopped at `0xf50a..0xf50e`; `hddone 0xf614` | none | `FROM_DEVICE`: invalidate all DC each programmed segment before reading/exposing it or starting the next segment | prepare after range calculation and before `r_star`; complete conservatively over the programmed segment on success or error | yes for raw user endpoints; programmed disk count itself is in 512-byte units | prepare before `0xf484`; complete after `0xf50e` and before dispatch at `0xf542`; override recommended |
| Paula floppy read | `FROM_DEVICE`; dedicated 32 KiB `MEMF_CHIP` track buffer | direct low chip alias; ordinary track cache is filled later by CPU decode/copy | `flread 0x1874e`, pointer `0x187b8`, double arm `0x187d0/0x187d6`; polled complete/stop `0x187e2..0x187f8` | none; alias is NC | none while chip buffer has only NC/NCS aliases | none under the same invariant; otherwise invalidate after `0x187f8` before decode | possible trailing partial line: transfer length is only guaranteed even | NC/NCS policy assertion; conditional hook after `0x187f8` |
| Paula floppy write | `TO_DEVICE`; same chip track buffer | direct low chip alias after CPU MFM encoding | `flwrite 0x1880c`, pointer `0x188ca`, double arm `0x188e2/0x188e8`; polled complete/stop `0x188f6..0x18916` | none; alias is NC | none | none while NC; otherwise push before `0x188e2` | possible trailing partial line | NC/NCS policy assertion; conditional hook before `0x188e2` |
| Paula streaming audio, channels 0-3 | `TO_DEVICE`; three 8192-byte `MEMF_CHIP` buffers per active channel | CPU fills direct low chip alias with `bcopy` | first handoff: `handfeed 0x14796`, DMA enable `0x14810`; every buffer publication: `loadup_dma 0x1487c`, stores `0x148c4/0x148d8`; complete ISR `audiointr 0x14214`, release `0x14948` | none; alias is NC | none | none while all audio buffers are NC; otherwise push before every `loadup_dma` publication | allocation and capacity are line aligned; final valid byte count may be partial | allocator policy assertion; conditional prepare before `0x148c4` |
| console bell, audio channel 3 | `TO_DEVICE`; 20-byte `MEMF_CHIP` waveform object | direct low chip alias after one `bcopy` | `bell 0x5d86`, pointer `0x5e06`, arm `0x5e2e`, timeout stop `0x5e7e` | none; alias is NC | none | none while NC; otherwise push waveform before pointer/arm | yes, deliberately smaller than two cache lines | policy assertion; conditional prepare before `0x5e06` |
| bitplane display DMA | `TO_DEVICE`; page-aligned `MEMF_CHIP|MEMF_PAGEB` planes | kernel direct low chip alias; `scrmmap 0x82f8` creates an unmanaged NCS user alias | pointers are embedded in copper lists; enable in `screeninit 0x899e`; ownership is continuous, synchronized at `screen_vbint 0x855a` | none; aliases are NC/NCS | none while every alias is NC/NCS | no hook if invariant retained; otherwise explicit drawing/display handoff | planes are page aligned, but drawing ranges are arbitrary | enforce NCS in `scrmmap`/`hat_devload`; no BIO hook |
| Copper list DMA | `TO_DEVICE`; `MEMF_CHIP` lists containing register and bitplane-pointer writes | direct low chip alias | `cop1lc`: `0x8434`, `0x852e`, `0x86e8`, `0x875e`, initial `0x895c`; completion/handoff is vblank | none; alias is NC | none | none while NC; otherwise push completed list before publishing `cop1lc` | allocation is 32-byte aligned; list length may be partial | policy assertion; conditional prepare before each `cop1lc` store |
| Blitter, kernel bootstrap | both in principle; this transfer uses zero pointers and one word | no meaningful RAM range: all A/B/C/D pointers are zero | setup `0x89cc..0x8a14`; arm `bltsize` at `0x8a1a`; no wait | none | none for this operation | none for this operation | not applicable | none |
| Blitter through `/dev/amiga` | both; userspace chooses chip source/destination | unmanaged custom-register/chip mappings must be NCS | no kernel arm/complete boundary; userspace writes mapped custom registers | none in kernel | correctness rests on NC/NCS-only chip memory | same; kernel cannot hook arbitrary userspace programs | arbitrary | reject cacheable chip aliases; mapping-policy gate |
| Sprite DMA | `TO_DEVICE` in hardware, but kernel sprite DMA is disabled | no active kernel sprite buffer | `screeninit` clears `DMASPR`; no active pointer writer found | none | none | none until a client is added | not applicable | retain negative result |
| A2065 LANCE | both, but only between LANCE and **board-local RAM** | CPU copies between board aperture and STREAMS/KMA buffers | TX copy `aenxmit 0x14c3c`, OWN about `0x14d48`; IRQ `0x15702`; RX CPU copy `0x1597c`, OWN return `0x1599c`; setup `0x15fcc` | none; aperture must be NCS | no host-RAM hook | same | board-local, not a host-cache line issue while NCS | mapping policy only |
| QL serial card / on-board 6502 | board-local producer/consumer, not host-RAM DMA | CPU accesses `device_t::tbuf/rbuf` in board aperture | CPU buffer accesses in `ql.c`; polled `qlintr 0x11b56` | none; aperture must be NCS | no host-RAM hook | same | not a host-cache line issue | mapping policy only |

## The four crossed searches

### 1. Configured strategy functions

The mounted driver-source search finds these strategy implementations:

```text
alien/ct.c            static strategy
alien/dd.c            ddstrategy
driver/dummy.c        dumstrategy
driver/hd.c           hdstrategy
driver/ram.c          ramstrategy
floppy/flop.c         fdstrategy
```

The configured block switch in `amix-src/sys/master.d/kernel.c` contains:

| Major | Driver | Public strategy | Hardware DMA |
|---:|---|---|---|
| 16 | floppy | `fdstrategy` | Paula, through private chip track buffer |
| 17 | native disk | `hdstrategy` | A2090 ST-506 host DMA |
| 18 | generic SCSI disk | `ddstrategy` | selected A2090/A2091/A3091 controller |
| 19 | dummy | `dumstrategy` | none |
| 20 | RAM disk | `ramstrategy` | none; CPU `bcopy` |

All five entries have `nullflag` and are wrapped by `gen_strategy 0x3d988`.
That proves coverage of public block submissions; it does **not** make
`gen_strategy` the DMA owner. Character tape and generic SCSI commands bypass
that block-strategy perimeter, and controller reconnects happen below it.

The character switch independently exposes `/dev/amiga` (major 6), QL (13),
SCSI control (11), `ct` (16), A2065 `aen` (18), TIGA (22), and audio (46).
In particular, `ctread`/`ctwrite` and SCSI control traffic prove that a census
limited to `bdevsw`, `strategy`, or `gen_strategy` would miss real controller
DMA clients.

### 2. Interrupt and polling entry points

The level-2 table is:

```text
aciaaintr
jbintr       -> a2090intr for native and alien A2090 clients
a2091intr
a3091intr
aenintr
```

Additional completion domains are:

- level 3 -> vblank server table -> `screen_vbint`;
- level 4 -> `audiointr`;
- `qlintr` through `io_poll`;
- floppy completion by polling `AIEDBLK` inside `flread`/`flwrite`;
- no linked blitter completion ISR.

This search catches both interrupt-driven DMA and the floppy path that would be
missed by an ISR-only census.

### 3. Custom-chip pointer and arm registers

The complete mounted-source search for `dskpt/dsklen`, audio pointer/length and
`DMACON`, `cop1lc`, bitplane pointer construction, and blitter pointers/size
found only the Paula rows in the matrix.

The important negative results are:

- no normal runtime kernel blitter client beyond the one-word initialization;
- no active kernel sprite-DMA client;
- bitplane pointers are written into chip-resident copper lists rather than
  directly armed from a block strategy;
- `/dev/amiga` is a capability boundary that can expose custom registers to
  userspace, so cache safety there must be guaranteed by mapping class.

The linked-binary absolute-address scan independently found the same
`0xdff000` register families: bell/audio pointer and length stores, five
`cop1lc` publications, screen blitter initialization, and floppy
`dskpt`/`dsklen`. No additional custom-chip DMA arm survived source-level
conditional compilation.

### 4. Controller and SDMAC register programming

The linked and source searches identify:

```text
dd/ct/scsi client
  -> sdqueue
  -> controller startdma
  -> controller interrupt/service
  -> stopdma
  -> sdcom.intr callback
```

`sdcom` retains `reading`, `addr`, `nbyte`, and the callback. A2091 and A3091
can stop and restart one command on disconnect/reconnect. A cache hook at final
`iodone` therefore neither describes all hardware segments nor precedes every
consumer callback.

No `cinva` or `cpush` instruction occurs in linked text
`0x0000b000..0x00019000`, which covers these controller, display, audio,
network, and floppy bodies. Existing cache operations are confined to the
appended 040 VM/MMU layer and debug probes.

## SCSI client coverage

The controller hooks cover more than filesystem disk buffers:

| Client | Buffer form | Why a controller hook is required |
|---|---|---|
| `dd` disk | `buf`, page I/O, buffer cache, or raw user I/O | original cacheable alias can survive the direct physical handoff |
| `ct` tape | raw/kernel buffers and controller commands | character path is not fully represented by `gen_strategy`; lengths may be partial-line |
| request sense | small static driver buffer | callback parses it before final `iodone` |
| generic SCSI ioctl | caller-supplied data and command callback | may not use a block `buf` completion at all |
| disconnect/reconnect segment | subrange of one `sdcom` | one logical request may have several hardware ownership intervals |

This is the decisive reason not to put the primary B1 invalidate in
`biodone`.

## A2091 bounce ordering

The bounce path has two CPU copies around the hardware transfer:

```text
TO_DEVICE:
  original host RAM -> CPU bcopy -> low chip buffer -> DMA -> device

FROM_DEVICE:
  device -> DMA -> low chip buffer -> CPU bcopy -> original host RAM
```

Consequences:

- B1 `TO_DEVICE`: WT makes original RAM current before the CPU reads its low
  physical alias.
- B1 `FROM_DEVICE`: completion invalidation belongs **after** the CPU has
  copied the bounce data into original RAM.
- B2 `TO_DEVICE`: prepare belongs **before** the source-to-bounce `bcopy`, or
  that copy can read stale RAM through DTT0.
- B2 `FROM_DEVICE`: prepare original RAM before DMA ownership and invalidate
  again after the bounce-to-original copy.

Calling only around `dp->st_dma` is therefore too late on the write-side
bounce path.

## A2065 no-host-DMA proof

The A2065 source and `amiga/driver/aen/exp` establish all of the following:

1. `setup_lance` places the initialization block at
   `board_base + 0x8000`.
2. CSR1 receives the low board-local initialization-block address and CSR2 is
   explicitly written as zero.
3. RX/TX ring addresses are offsets from `board_base`.
4. Every ring descriptor's `loaddr` names storage inside that same board
   aperture; `hiaddr` is zero.
5. TX copies STREAMS data into `board_base + tx.loaddr` before setting OWN.
6. RX copies from `board_base + rx.loaddr` into a host static buffer before
   returning OWN.
7. The complete A2065 source contains no `vtop`, PFN conversion, or publication
   of a host pointer to the LANCE.

Thus A2065 network traffic reaches host memory through CPU `bcopy`, not bus
mastering. The LANCE/board aperture still must remain NCS. This same conclusion
applies to the debugger's A2065 helper, which uses the established board-local
rings.

## Other mounted drivers

Every C file under `vanilla/usr/sys/amiga/driver` was classified:

| Driver/group | Transfer mechanism | Census result |
|---|---|---|
| `acia`, `par`, `sl` | byte/word registers and interrupts | PIO, no DMA |
| `bb`, `ben`, `cl`, `slip` | STREAMS/software glue | no hardware initiator |
| `ram` | CPU `bcopy`, despite being a block strategy | no DMA |
| `dummy` | error/diagnostic strategy | no transfer |
| `amiga` | direct custom/chip read/write and mmap capability | no initiator; mapping policy matters |
| `tiga` | board MMIO/read/write/mmap | no host pointer published |
| `ql` | CPU accesses board-local serial buffers | no host DMA |
| `jb` | A2090 bus arbitration and interrupt dispatch | initiators are the SCSI and `hd` clients already listed |
| `machid` | identification/control | no DMA |
| `kdb` | debug/control; A2065 helper uses board-local rings | no additional host DMA |
| `as65`, `ql65` | build-time tools | not kernel drivers |
| A2088/Janus | no driver source, configured switch entry, or linked symbol in this target | absent, not an unclassified initiator |

No unclassified strategy, custom-chip arm, SDMAC arm, or interrupt completion
remains in the mounted AMIX driver tree.

## Patch anchors and old-byte assertions

The controller edits should be source/object overrides, not blind insertion
into the stock text. The functions have no guaranteed instruction slack, and
B2 needs saved per-segment state rather than a one-instruction cache patch.

The following windows are stable pre-edit assertions for the target image.
Text file offsets are `address + 0x34`. Zero longwords in `jsr` and absolute
operands are ELF relocation fields: acceptance must verify both the bytes and
the relocation's target symbol.

| Owner / purpose | Text address | File offset | Current bytes | Required semantic position |
|---|---:|---:|---|---|
| A2090 prepare-to-arm call sequence | `0xc2a8` | `0xc2dc` | `2f2b0014102b000449c02f002f034eb900000000` | B2 prepare must precede the relocated `startdma` call |
| A2090 completion case 1 | `0xc418` | `0xc44c` | `2f024eb90000000026922f0a206a00244e90` | B1/B2 complete after relocated `stopdma`, before indirect callback |
| A2090 completion case 2 | `0xc4c0` | `0xc4f4` | `2f024eb900000000584f4a0066000012` | complete after relocated `stopdma`; retain all false/error branches |
| A2090 hardware arm | `0xc5de` | `0xc612` | `177c00f70064` | prepare must already be complete before DMA-control store |
| A2091 direct/bounce branch | `0xccb0` | `0xcce4` | `202a00140c8000ffffff6300005a` | common prepare must precede direct/bounce split |
| A2091 bounce source copy | `0xccec` | `0xcd20` | `2f2d00942f2d009c202a0014222a0018d081222d009490812f004eb900000000` | B2 `TO_DEVICE` prepare precedes this relocated `bcopy` |
| A2091 hardware arm | `0xcd2a` | `0xcd5e` | `377c000100e0` | prepare must already be complete |
| A2091 bounce/free and epilogue | `0xcda0` | `0xcdd4` | `4eb900000000defc000c2f2a00942f2a009c4eb90000000042aa009c246efffc` | complete after read-side `bcopy` and `FreeMem`, before epilogue |
| A3091/SDMAC hardware arm | `0xd4b2` | `0xd4e6` | `317c00010012` | prepare must already be complete |
| A3091/SDMAC stop tail | `0xd4f8` | `0xd52c` | `207900000000317c0001001a317c0001003e42390000000020404e5e` | complete after SDMAC quiesce and `dma_on=0`, before return |
| native `hd` hardware arm | `0xf484` | `0xf4b8` | `337c00010052` | prepare must already be complete |
| native `hd` stop and dispatch prefix | `0xf50a` | `0xf53e` | `426d0050426d005270644c0208002640d7fc000000004a2b0016` | complete after the two stop stores, before result dispatch |

Expected relocations inside those windows are:

```text
0xc2b8 startdma
0xc41c stopdma
0xc4c4 stopdma
0xcd08 bcopy
0xcda2 bcopy
0xcdb4 FreeMem
0xd4fa device
0xd50c dma_on
0xf51c hdctab
```

For B1, an override may use a direction-aware shared helper whose
`TO_DEVICE` branch is a no-op and whose `FROM_DEVICE` branch executes
`cinva dc`. B2 must additionally preserve the exact physical start, programmed
length, direction, and pairing state for every arm, disconnect, retry, and
completion.

## Static closure

The requested static census is complete if the target hashes above are used.
Its implementation consequences are:

1. Add B1 `FROM_DEVICE` completion invalidation to A2090 SCSI, A2091,
   A3091, and native `hd`.
2. Place every invalidate after hardware quiescence and after any
   bounce-to-original copy, but before `sdcom.intr`, `hddone`, `iodone`, or
   other CPU consumption.
3. Preserve chip RAM and board apertures as NC/NCS; do not add redundant cache
   hooks to floppy, audio, display, A2065, or QL while this invariant holds.
4. Treat a future cacheable chip/board alias or a new Zorro DMA driver as a new
   initiator requiring its own census row.
5. Keep B2 disabled until per-segment ranges, aliases, and partial-line
   ownership are implemented as specified in
   `DMA-PREPARE-COMPLETE-CONTRACT.md`.

The closure inventory contains 16 positive/policy rows in the initiator matrix
and 12 grouped negative driver results. Every hit from the four independent
searches is assigned to one of those rows.

This closes the **analysis** part of CM-B1 matrix item 8. It does not close the
kernel implementation or real-hardware acceptance gate.
