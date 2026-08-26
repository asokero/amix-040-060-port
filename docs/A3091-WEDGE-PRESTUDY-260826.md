# `a3091: 0x16 0 0x8112B84` — what the message means, and what would settle its cause

Preliminary study, 2026-08-26, from the driver's **source**. No hardware was available; nothing
here needed any.

## First: `a3091.c` is not binary-only

`sys/amiga/alien/a3091.c` — 8574 bytes, dated 22 November 1991 — is inside
`amix-playground/vanilla/amix-sources.tar`, along with `scsi.c`. This project has treated the
A3091 driver as binary-only and reverse-engineered around it (`docs/contracts/`
`A3091-B2-PREPARE-PATCH-SPEC.md` was written against a disassembly).

Everything below is read from that source rather than inferred from the image, which is the
order this project asks for and which I got wrong the first time here too: I had already started
disassembling before checking whether a source existed.

## The message decodes exactly

    printf( "a3091: 0x%x %d 0x%x\n", ss, istate, curunitp);      /* a3091.c:414 */

in `badhardware()`, which does nothing else and `return (DEAD)`.

| field | value | meaning |
|---|---|---|
| `ss` | `0x16` | 3393A status. `itab[0x16]` = **8** = *"Request has completed."* |
| `istate` | `0` | **IDLE** — *"3393A is ready to start new request"* |
| `curunitp` | `0x8112B84` | `&units[6]` — see below |

`atab[IDLE][8]` = **1** = *"Report that driver has shut down."*

**So: a request-completed interrupt arrived while the driver believed nothing was outstanding.**

### `curunitp` is a valid pointer, and it points at the root disk

`units` is at `.bss + 0x3ce8`; the loader reports the image ending at `0x0810ee3c`, so
`units = 0x08112B24`. `sizeof(struct unit)` is 16 (three pointers plus three `uchar`s, padded).

    0x08112B84 - 0x08112B24 = 0x60 = 96 = 6 x 16     ->  &units[6]

**SCSI ID 6 is this machine's root disk.** The driver died with the root disk as its current
unit, which is why everything that needed the disk stopped and nothing else did.

## Why the machine wedged instead of reporting an error

`atab` row 3 — the `DEAD` row — is `1,1,1,1,1,1,1,1,1`. **Every input from every source maps back
to "report that driver has shut down."** And `startany()` opens with

    unless ((istate == IDLE) and (up = starthead))
            return;

so once `istate` is `DEAD`, no request is ever started again. Nothing re-arms, so no further
interrupt arrives, so `badhardware()` is never reached a second time.

That predicts exactly what the console showed: **one line, then permanent silence**, with every
disk-backed operation queued forever and the network — interrupt-driven, in memory, no disk —
entirely unaffected. `telnetd` accepts the connection and forks a login shell that must read from
disk, which is why the port answers and the prompt never comes.

That is the wedge, confirmed at source level.

## The tolerance here is zero, and that is the driver's own property

One unexpected completion interrupt kills this driver permanently. There is no retry, no bus
reset, no recovery path, and no way back to `IDLE`. That is true of the 1991 driver as shipped
and has nothing to do with anything this port added: **whatever produces a single stray
completion, the outcome is always this.**

Which means the interesting question is not "what broke the driver" — the driver breaks on
contact — but "what delivered an unexpected completion".

## How the driver comes to be IDLE with a completion still possible

Two paths, both stock:

* **`case 0`** — a request completes normally, the callback runs, `istate = IDLE`, `startany()`
  finds an empty queue and returns. Any *second* completion interrupt now lands on IDLE.
* **`case 7`** — the target reports a temporary disconnect (`0x85`), `stopdma()`, `istate = IDLE`,
  empty queue. A target that disconnected mid-transaction is expected to **reselect** (`0x81`,
  input 4, `atab[IDLE][4] = 3`, handled). If a **completion** arrives instead of a reselection,
  it is `atab[IDLE][8]` and the driver dies.

## Where this port's code could plausibly contribute — hypothesis, not finding

`src/dma_cache040.s` wraps both `startdma` and `stopdma`. Three properties matter:

1. **The prepare hook executes `cpusha dc` — a whole-data-cache push — inside `startdma`**, before
   tail-calling the stock arm (`.word 0xf478`, `Lst_push`). On a 68060 that is not a few cycles.
2. **The wrapper raises no interrupt level.** There is no `movew …,%sr` and no `spl` call anywhere
   in the file.
3. In `startany()` the stock order is `startdma(up); setreg(CON,…); istate = STARTING;
   setreg(COM, startcom);` — **`istate` is set after `startdma` returns.** So the whole-cache push
   happens while the DFA still reads `IDLE`. The same hook also runs inside the interrupt handler
   on the reconnection path (`case 3`), lengthening interrupt service time.

And one more, from this port's own comment in that file:

> *68060 note: CPUSH invalidation depends on CACR.DPI; current CACR 0x80008000 has DPI clear.
> **Real-060 B2 acceptance is a separate milestone.***

**B2 has never been accepted on a real 68060**, and that is what is running.

None of this is evidence that the hook caused anything. It is a list of ways a pre-existing race
could have been made more likely, written down so it can be tested rather than argued about.

## What would settle it, cheapest first

1. **Did any of the three earlier sightings predate 2026-07-20?** B1 landed that day, B2 on
   2026-07-23. A sighting before then rules this port's DMA hooks out completely and makes
   everything above moot. **Only the user has this, and it costs nothing to answer.**

2. **The counters, which have never been read after a wedge.** `dma_cache040.s` carries
   `dma_prep_owned` and `dma_cmpl_noprep` — both "this must stay 0" diagnostics — plus
   `dma_zero_arm`, `dma_reconn_arm`, `dma_range_ovf`, and `dma_prep_whole` for the rate. All read
   **zero** in the pre-burst dormancy check on 2026-08-25 and were never read again. Reading them
   on a wedged machine, before rebooting it, is the single most informative measurement available
   and it has never been taken.

3. **Does the burst provoke it?** The burst is the heaviest sustained DMA this project has. It ran
   72/72 clean, and the wedge appeared afterwards — which is suggestive of load but proves
   nothing about order, because nothing timestamped the `a3091:` line.

4. **An A/B is currently impossible at runtime**, and that is worth fixing before the next
   attempt: the DMA hooks have **no gate**. Every other instrument in this port has one
   (`hg_on`, `i10*_on`, `wbf_prop_on`, `xpage_on`, …). A single gating longword on the prepare
   path would turn "is it the cache push?" into a one-boot question instead of a two-build one.

## What this does not claim

That the wedge is reproducible. Three sightings across an unknown span is not a rate, and the one
observed here followed a battery, a burst and several hours of use. Establishing whether it
reproduces is the point of the next session, and the counters above are what will make the answer
mean something either way.

---

## The instrument, built 2026-08-26

`src/a3091dbg040.s` + `src/patch_a3091_badhardware.py`, in the base link. It interposes on the
a3091 `badhardware()` call, prints three bounded lines and latches the surrounding state, then
tail-jumps to the stock body — so the stock line still appears and `DEAD` is still returned.
**Nothing about the driver's behaviour changes.**

It is reached by retargeting **one relocation** (`0xd3a6`, inside `a3091intr`) rather than by
weakening a symbol, because `badhardware` is a file-LOCAL static and the image holds two: the
other belongs to `service`, whose call site at `0xcba6` the patcher reports leaving alone. The
three source-level calls (cases 1, 3 and 8) share one compiled tail, which is why one
relocation covers all of them.

What it captures at the moment of death:

    a3091dbg ss=%x istate=%d unit=%x head=%x dmaon=%d
    a3091dbg segstate=%d segseq=%d segpa=%x seglen=%x segdir=%d
    a3091dbg zarm=%d rarm=%d owned=%d noprep=%d ovf=%d whole=%d

`head` is the decisive one for the open question: `starthead == 0` proves the start queue was
empty, which is what separates "IDLE with nothing to do" from "IDLE with work waiting".

**It prints as well as latches, and that is the point.** When the dying unit is the root disk the
machine wedges, and a latched block is then unreachable — telnet never gets past `accept()`, and
even a console login needs `/bin/login` off that same disk. The print reaches the screen in that
instant, which is proven, since the stock line did; and the serial cable is now attached.

**It does not touch the device.** `reg()` would give phase and status, and reading them is
deliberately omitted: this runs at the moment of a hardware anomaly, in an interrupt handler, and
reading `SS` is what acknowledges the interrupt. Adding register reads is a later decision to be
made with evidence.

### Verified, both directions

    [left] @0x0cba6 -> badhardware@0xcf46 (service; not ours)
    [ok]   @0x0d3a6  badhardware@0xd666 -> a3091_badhardware_dbg

and on a booted 68060 emulator, `68060-260826-03`:

    a3d_magic = 41334421   "A3D!"   the block is where it is said to be
    a3d_ran   = 00000000            the body has never run

The first draft had a single magic written only when the body ran — so an all-zero block could
not distinguish *never fired* from *wrong address*, which for an instrument expected to read zero
for its whole life is the one distinction that matters. `a3d_magic` is now static and `a3d_ran`
carries the fired flag, following `usptrap.s`'s pattern.

