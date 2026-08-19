# Mixing NC and NCS on one board: the ordering contract, and why no barrier is needed

2026-08-19. Written before change D, because change D is what creates the question.

## Why the question exists at all

Today every CPU access to an RTG board takes **one** cache class, so ordering between classes
cannot arise. Change D splits them:

| | today | after change D |
|---|---|---|
| framebuffer, user `mmap` | `0x40` NCS (every `pp == NULL` leaf) | **`0x60` NC** |
| register page | `0x40` NCS | `0x40` NCS |

That creates a producer/consumer pair straddling two classes: write pixels **NC** (buffered,
unserialised — which is the performance the Zorro III work exists for), then write a command
register **NCS**. If the command could reach the board before the pixels, the blitter would read
stale framebuffer content. That does not crash anything; it puts intermittent garbage on screen,
which is the hardest failure class here to attribute, and it would look like a Zorro III timing
problem while being a CPU write-buffer problem.

Choosing NCS for the framebuffer too is not an acceptable answer: it gives back the gain.

## The answer, per CPU

**68040 — safe.** *M68040 User's Manual*, §7.7 *Bus Synchronization* (pp. 7-43…7-44) states that a
given sequence of read accesses or write accesses completes in order, and that reordering occurs
only between writes and reads. Write-to-write order is therefore architectural: the command store
cannot complete ahead of the framebuffer stores. §4.3.2 (pp. 4-7…4-8) establishes that both NC and
NCS bypass the cache and perform an external transfer, so neither allocates a line.

Two details worth keeping:

* The serialised/nonserialised distinction is about **reads**. An NCS *read* waits for all pending
  writes before its external read begins; an NCS *write* is not documented as a special drain. So
  the pair is safe because of general write ordering, not because NCS is a fence.
* That makes `va2_blit_wait()` — which *reads* `VA2_BLIT_ENABLE` — an implicit drain of pending
  writes, for free, wherever it already runs.

`nop` is documented in the same section as the operation that halts execution until all pending
bus cycles complete. It is the correct explicit barrier **if one is ever wanted**, placed after the
last framebuffer store and before the first command store. It is optional here. `trap` and `movec`
are *not* substitutes: §10.5's timing notes (pp. 10-11…10-12) classify them as synchronising only
parts of the processor.

**68060 — safe, and it stays safe.** *M68060 User's Manual* §§5.9–5.10 and §7.10: all reads and
writes are in strict program order. With the store buffer disabled (the state this port ships),
cache-inhibited writes generate bus cycles directly and the instruction waits for termination.
With the store buffer **enabled** — which `docs/060-D-CACHE-KNOBS-PLAN.md` intends — NC/imprecise
stores may enter the FIFO, but the NCS/precise command store bypasses it and the processor drains
its write buffers first. **Enabling ESB later does not change this contract**, which is the part
worth writing down: the fix chosen today does not silently expire when 060-D lands.

`cpusha dc` / `cpushl` are not part of this contract. Both mappings bypass the cache, so a cache
push would be a broad and expensive substitute for a bus-ordering operation. A *cacheable* alias
to the same physical pages would be a different defect needing its own contract.

Source: static audit against the two manuals, `vm-map/Z3-NC-NCS-ORDERING-AUDIT.md` in the
kernel-analysis repository. No hardware or emulator run; this is an architecture result.

## A source correction that closes a design option

The brief that asked this question cited the VA2000 driver's blitter register sequence as a
kernel-side command path. That was misattributed, and checking it against the driver settles
something:

* those lines are `SVGAIOCClearBoardMem`, **not** `SVGAIOCStartBlit`;
* `SVGAIOCStartBlit` and `SVGAIOCEndBlit` are both `break;` — no-ops.

So the kernel does drive the blitter, but only to clear board memory. A general blit is driven from
userspace through the mapped register page. Consequently the contingency floated earlier — *keep
the register page out of userspace and route every register access through `ioctl`* — is **closed**:
it would break the X server, which needs that mapping. It stays a valid design for a future ioctl
implementation, not a fallback available now.

## What is still owed to hardware

The CPU side is settled. The **bus** side is not: whether the Zorro III bridge posts writes, and
what it guarantees about a posted write ahead of a following one, is not a CPU property and cannot
be read out of these manuals. It is a hardware test, and it belongs with the firmware move — the
first run in Zorro III mode should include a deterministic blitter/display visibility check, not
only a throughput number.

## Bearing on change D

Proceed as designed: framebuffer NC, registers NCS, no barrier instruction, no `cputype` gate for
ordering. If a barrier is ever wanted for belt-and-braces, `nop` is the documented one and its
placement is stated above.
