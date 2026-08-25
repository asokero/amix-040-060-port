# Why Zorro III gave 7.66 MB/s and not 20 — the brake is in the card, and it is latency

2026-08-19, after the Zorro III acceptance run. The question: Zorro III is generally expected to
reach the high teens or low twenties in MB/s, and we measured 7.66. What is holding it, and is any
of it ours?

**Short answer: none of it is ours.** The card terminates a Zorro III bus cycle in roughly 500 ns
regardless of transfer width. Everything else follows from that, and it is visible in the card's
own Verilog.

## Step 1 — convert the measurements from bandwidth to cycle time

Bandwidth hides the mechanism; cycles per second do not. Each Zorro III transfer is one bus cycle
whatever its width, so dividing throughput by the transfer size gives the cycle rate.

| | MB/s | transfers/s | **ns per bus cycle** |
|---|---|---|---|
| Zorro III write32 | 7.66 | 1.92 M | **522** |
| Zorro III write16 | 4.12 | 2.06 M | **485** |
| Zorro III read32 | 7.05 | 1.76 M | **568** |
| Zorro II write32 | 3.12 | 1.56 M | 641 |
| Zorro II write16 | 2.78 | 1.39 M | 719 |

**The card sustains about 2 million Zorro III cycles per second, and the width of the transfer
barely moves that number.** A 16-bit write costs 485 ns and a 32-bit write 522 ns — 7% more for
twice the data.

That is the whole story in one line: **we are latency-bound per cycle, not bandwidth-bound.** It
is also why Zorro III helped at all — the gain came from carrying 4 bytes per cycle instead of 2,
plus a cycle that is about 25% shorter, which multiplies out to the 2.45× measured.

For scale: a Zorro III non-burst cycle is nominally in the neighbourhood of 150 ns, which is where
the ~26 MB/s figure comes from. *(That figure is general knowledge of the bus specification, not
something read from a document in this repository — treat it as an order-of-magnitude reference,
not a citation.)* At ~520 ns the card is running roughly 3.5× slower per cycle than that.

## Step 2 — four brakes, all in the card, all readable in `va2000.v`

Source: `~/kehitys/amiga2000-gfxcard/va2000-spartan6/va2000.v` and `SDRAM_Controller_v.v`.

**1. The memory path is 16 bits wide, so a 32-bit transfer becomes two transactions.**

```verilog
Z3_WRITE_UPPER:  zorro_ram_write_data <= z3_din_high_s2;   // upper 16
Z3_WRITE_LOWER:  zorro_ram_write_data <= z3_din_low_s2;    // lower 16
Z3_WRITE_FINALIZE: wait for the controller to release
```

`SDRAM_Controller_v.v` confirms it at the interface: `input [15:0] cmd_data_in`,
`output [15:0] data_out`. The bus got wider; the memory behind it did not. Half of what Zorro III
offers is given straight back here.

**2. Every 16-bit transaction is a separate arbiter round-trip. There is no queue and no burst on
the Zorro path.** The FSM raises `zorro_ram_write_request`, waits for the arbiter to notice it in
`RAM_READY`, passes through `RAM_WRITING_ZORRO_PRE`, and only then may the next one start. At
~2 M cycles/s with two transactions per longword, that is ~260 ns per transaction — far longer
than the memory itself needs, so what is being measured is the handshake, not the SDRAM.

**3. The display scanout has absolute priority on that same port.** The arbiter's `RAM_READY`
order is explicit:

```
1. display row fetch   (need_row_fetch … && x_safe_area && cmd_ready)
2. Zorro write
3. Zorro read
4. blitter
```

and `Z3_WRITE_UPPER`'s own comment says `// wait for free memory bus`. Every row the display
fetches is time the Zorro port does not get. This one scales with resolution and depth: a bigger
screen costs CPU write bandwidth.

**4. There is no Zorro III Multiple Transfer Cycle support at all.** Searching the whole design for
MTC handling finds nothing; the only bursts anywhere are on the *SDRAM* side, and they are used by
the display row fetch (`ram_burst_size <= 3'b111`, 8 words) and a 2-word videocap burst. The Zorro
FSM does one address phase and one data phase per transfer, then `Z3_ENDCYCLE`.

This is the one that matters most for the headline figures. The high Zorro III numbers assume MTC:
one address phase followed by several data phases, amortising exactly the per-cycle latency that is
limiting us. Without it, ~520 ns is paid on **every** longword.

The asymmetry is worth naming: the SDRAM controller supports bursts and the *display* uses them.
The Zorro path does not.

## Step 3 — what is demonstrably *not* the brake

**Not the cache class.** The framebuffer is mapped `CM=0x60`, noncacheable and *not* serialised,
verified page by page out of the live page table. Serialisation would force each access to complete
before the next begins; it is switched off.

**Not the CPU.** 7.66 MB/s is 1.92 M longword writes per second on a 66 MHz 68060 — about 34 CPU
clocks per write. The same loop against local RAM in the same session ran at 25.91 MB/s. The
processor is idling against this bus.

**Not the kernel.** Once the mapping exists there is no kernel involvement per access: `busbench`
writes straight through an `mmap`ed aperture. The kernel's contribution is the mapping and its
cache class, and both are measured correct.

**Not Zorro II leftovers.** The width discriminator settles it: on Zorro II `write32/write16` was
1.12× — flat, meaning the same bytes per second whatever the width, a saturated 16-bit bus. On
Zorro III it is 1.86×, so the wider path is genuinely being used.

## Step 4 — what could actually raise it, in order of expected effect

1. **Zorro III burst (MTC) in the card's FSM.** This is where the missing factor of two-to-three
   lives. It is an FPGA change, not a software one.
2. **A wider or queued path to the SDRAM.** Assembling a 32-bit word and issuing one transaction,
   or letting the Zorro side queue writes instead of round-tripping the arbiter per 16 bits.
3. **Lower display bandwidth while measuring** — fewer pixels or fewer bits per pixel leaves more
   of the port to the CPU. Cheap to test and it would *quantify* brake 3 rather than merely assert
   it: run `busbench` at two screen modes and compare.
4. Nothing on our side. There is no kernel change that makes a 500 ns bus cycle shorter.

## What would be worth measuring next, if anyone wants a number rather than an argument

* **`busbench` at two different screen modes.** If throughput rises when the display is smaller,
  brake 3 is quantified. This is one command and no rebuild.
* **The same at 8-bit versus 16-bit depth**, for the same reason.
* **A read/write asymmetry check**: reads measured 568 ns against writes at 522 ns, which is
  consistent with reads needing the data back before `DTACK` while writes can post. Not chased.

## Bottom line

The Zorro III work delivered what it could deliver: the bus is wider, it is demonstrably being
used as such, and the throughput went up 2.45×. The remaining gap to the numbers Zorro III is
associated with is the VA2000's own implementation — a 16-bit memory path, a per-transaction
arbiter handshake, priority given to the display, and no burst support. All four are in the FPGA.
