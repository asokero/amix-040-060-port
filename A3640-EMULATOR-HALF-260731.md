# A3640 (an 040 card with no RAM of its own) — the emulator half, 2026-07-31

Everything the port knows about memory came from one machine: an A3000 + PPS Mercury, whose card
carries its own 32 MB at `0x08000000`. An A3640 has **no RAM of its own**, so the kernel has to live
in A3000 motherboard fast RAM at `0x07000000`. The 2026-07-09 analysis found the A3640 memory map
emulator-identical, so this half is testable before the card is ever in the machine — and it was
worth doing first, because it found something.

## Setup

`Configurations/a3000ux-a3640.uae` = the 040 config with `mbresmem_size=32 → 0`. Nothing else
changed: same CPU, same disk, same DH2: mapping to `build/`. `emu-reset-boot.sh` gained an `a3640`
mode alongside `040`/`060`.

```text
040 config     mem[0] 08000020..0a000000 (32 MB card)   mem[1] 07000020..08000000 (16 MB mobo)   mem[2] chip
a3640 config   mem[0] 07000020..08000000 (16 MB mobo)   mem[1] chip
```

## Result 1 — the port is load-address agnostic, and that was checked before it was claimed

Grepped every base object for a hardcoded `0x08000000`: the only hits are comments, a debug-only
RAM scan in `assegat_dbg.s`, `wb040.s`'s FSLW **MA bit mask** (`0x08000000` is bit 27, not an
address), and one diagnostic print gate. No functional dependency.

The boot confirms it. `unix_boot040` relocated the ET_REL kernel into the only bank there is:

```text
kernel: entry=07000000 tvaddr=07000000 tsize=000e4438 dvaddr=070e4438
UNIX(R) System V Release 4.0 ... 68040-260731-11
Total Unix memory = 16773120      (16 MB instead of 48)
```

and the run is functionally identical to the Mercury config, measured rather than eyeballed — the
counters read the *same values* on both machines:

```text
cb_icode_push    1     the ISSUE-38 fix fires once per boot, as designed
hat_pfnmiss_n   10     identical to the Mercury config
hat_badaslot_n 439     identical to the Mercury config
```

**Note the tooling consequence:** every counter address moves. The rule is unchanged but the base
is not — it is `kernel_base + textsize + .data offset`, and `kernel_base` is `0x07000000` here, not
`0x08000000`. Read the anchor first on an unfamiliar machine.

## Result 2 — a diagnostic that was "silent on a healthy boot" fired 200 times

The first A3640 boot produced 200 × `DBG vtop pool` — the whole cap — on an otherwise clean boot.
That message was one of the eleven left **ungated** in the 2026-07-31 quieting unit, on the evidence
that it never fires on a healthy boot. That evidence came from a Mercury-config log, and the
message's gate is a **physical address range** (`[0x07C00000, 0x07E00000)`). On the A3640 the kernel
and all its allocations live at `0x07xxxxxx`, so that window is ordinary memory and the probe fires
on normal traffic.

The classification was machine-specific, not health-specific. `vtop pool` is now behind `kdbg_on`
with the other traces, and the A3640 boot is silent again (1 304 bytes of serial log, zero DBG
lines, `cb_icode_push` = 1).

**The general rule this earns:** a diagnostic gated on a physical address range is machine-specific
by construction. The other two `vtop040` warnings were re-checked and are fine — `VTOPALIAS` gates
on `p_mapping` being live and `KERNVA-WITH-PROC` on a violation condition, both properties of state
rather than of the memory map.

## What this half does NOT test, and what the card will

* **Bus timing and DMA against motherboard RAM only.** The A3091/SDMAC path now has every buffer in
  the same bank as the kernel; the emulator does not model the timing, and the B1 coherency hooks
  have only ever been exercised with the Mercury layout.
* **The 040 in an A3640 is a real 68040 on a different bus** — cache behaviour under copyback is
  precisely what the emulator cannot model (ISSUE-38 was invisible there).
* **16 MB instead of 48.** Memory pressure is a different regime: `b2repro`'s stalls and the
  `amixadm` intermittent both live in that regime, and this configuration is a cheap way to reach it
  deliberately.

## Artifacts

```text
Configurations/a3000ux-a3640.uae    the config
emu-reset-boot.sh a3640             the boot mode
NAS amix/hwtest-260731/
  unix-040-quiet-base-260731-10     base with the vtop gate (the shipping content)
  unix-040-quiet-260731-11          + serial mirror  (the image booted in this test)
  unix-040-dbg-260731-12            probe overlay
  unix-040-rtg-260731-13            + both RTG drivers
```
