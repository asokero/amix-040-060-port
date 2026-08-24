# Platform class `LC060-Z3660` — a real 68LC060 on a Z3660, and what it does not model

`docs/ACCEPTANCE.md` §1 names three classes — `EMU`, `HW`, and *"a third platform — e.g. a
Z3660's own 68040 emulation — its own class, neither of the above"* — and then makes one rule
binding on all of them:

> **A new platform must arrive with its own such list.** Only whoever built it knows what it does
> not model, and without that list its results will be read as stronger than they are. Ask for it
> before accepting results from it.

A real 68LC060 executing instructions on a Z3660 is a **fourth** class. This is its list, written
before the first AMIX boot on it, so that the rule applies to us and not only to results we
receive. Nothing here has been accepted from this platform yet, because nothing has been measured
on it yet.

---

## 1. What the class is, precisely

| | |
|---|---|
| CPU | a socketed **68LC060**, **50 MHz**-rated. Both facts are stated by whoever holds the card; neither is corroborated here by a chip-marking capture or by a PCR reading, and the PCR ID is still a **prediction** (§2.10) |
| card | Z3660 in an A4000, firmware in `bootmode CPU` — the real-CPU path, not either emulation mode |
| CPU clock | `cpufreq 50` ⇒ **`PCLK 050.00 MHz`** at **`Clock index 0`** (**measured**, the firmware's own readback) |
| motherboard clocks | **`BCLK`/`CPUCLK`/`CLK90` `025.00 MHz`** — and see §2.4, because that 25.00 is not free |
| FPU | **none**. Regime 3 of the three-regime law: every floating-point instruction traps |
| boot chain | native — bare Kickstart, **no SetPatch and no `68060.library`**. `cputype = 60` is stamped into the image by the build rather than inherited from `AttnFlags`; the banner flips at `src/inituname040.s:32-34` |
| Kickstart under it | **KS 3.x only** — KS 2.04 is **measured** unable to start a 68060 at all |

**It is real silicon, and it is still not `HW`** as this repository uses the word. Every `HW` row
here was taken on a local-bus 68k card — a Mercury or an A3640 — with a working FPU. Three of this
platform's properties do not exist in that column at all (no FPU, an ARM-sourced clock, RAM behind
an FPGA), so folding it into `HW` would let a reader lean on a Mercury row to excuse a result from
here, or the reverse. It gets its own tag: **`LC060-Z3660`**.

Consequence for `STATUS.md`'s platform matrix: its four columns (`EMU`/`HW` × 040/060) have no
cell for this class, and its `68LC060 / EC variants` row currently reads `untested, unknown`
across all four. Entering a result from this platform needs a fifth column, or an explicit
per-row note. That is a decision for whoever maintains the matrix; this document does not make it.

---

## 2. What it does not model

Each entry says what the gap is, what the evidence is, and — the part that matters when someone
reads a green result six months from now — **what a result from this platform may therefore not
claim**.

### 2.1 No hardware FPU. No floating-point evidence of any kind comes from here.

The part has no FPU, so every FP instruction takes vector 11 and, for a user process, ends in
`SIGSYS` — working as designed, not a defect (`src/fpsp060_glue.s`, the regime-3 arm; the
outcome is **measured** on the synthetic-LC bench rig, where `awk 'BEGIN{print 1.5*2.5}'` returns
`Bad System Call - core dumped`, rc 140, and the machine stays up).

**May not claim:** anything in `ACCEPTANCE.md` §6's 68060-only list — `fp060probe`, `ftest060`
`unimp` and `main`, `fpenab060`, `fputest060 fork`, the six enabled IEEE exception classes. Those
cells stay with the Mercury. A test that *passes* here by not executing FP is not evidence that FP
works; it is evidence that the test did not need FP.

**And it has a userland consequence that is not a kernel bug.** Two `ufs` binaries execute FP for
display only — `mkfs_ufs` at its banner (9 instructions) and `fsck_ufs` in its summary, *after*
all repairs and *before* the filesystem is marked clean (4 instructions). Untreated, that makes a
**dirty root unrepairable on this platform**: `fsck` runs all five phases, repairs, dies on the
summary, the boot script reboots, and the next boot finds the same dirty root. The bench cycle is
16 s, byte-identical every time, and the single-variable proof is that the same image with an FPU
present reaches login. Until the integer-math patch to those two binaries is on the image (and on
the miniroot copies), **every session on this platform must end with a clean unmount**, and an
`s5` root is the fallback that has no FP on its path at all.

### 2.2 Real caches — for the first time. Nothing about them is settled here yet.

Neither emulated class models the 68040/68060 copyback data cache: Amiberry does not
(`AGENTS.md`, the standing list, and it is why ISSUE-38 could only be found on silicon), and the
Z3660's own 68040 emulation has no cache model at all. **This is the first class in which the
kernel's copyback data cache and the drivers' cache maintenance actually execute.**

That cuts both ways, and the list must say both:

* it is the only class here that *can* settle a cache- or DMA-coherency question; and
* until the driver A/B protocol has actually run on it, **nothing about that question is settled
  in either direction on this platform** — the maintenance code and the boot-time
  cache-inhibition asserts in both Z3660 drivers have never executed on real 68060 caches.

**May not claim:** that the drivers are coherent here, and equally may not claim that they are
not. A first boot that survives is not a coherency result — a wild write of this class is silent
and is caught by whole-file checksums and canary binaries, not by "it booted".

### 2.3 A real bus — but an FPGA-mediated one, which is a different bus from every `HW` row.

RAM is Zynq DDR presented through an FPGA, not a local 68k bus. Three named consequences:

* **`/SNOOP` does not cover the ARM's direct DMA.** The CPLD asserts `nSNOOP` only for 68k
  local-bus cycles (`z3660.vhd:459`, gated on `DMA_BUSY` / `nBG_ARM`), while the piscsi path has
  the **ARM** write Zynq DDR from its own memory system. That class of traffic is structurally
  invisible to snoop even where snoop is wired — and the firmware books the same class as a known
  gap for its own MPEG and USB paths.
* **`/SNOOP` may not be wired at all.** It is a no-connect on v0.2-series boards (the v0.23
  schematic carries the annotation *"`_SNOOP` not connected on v02 (was TP5 on v02)"*), and it
  separately depends on which CPLD image is programmed. The CPLD image on this card is known (a
  single image, `DMA_WIP` lineage, BETA 20 usercode, byte-identical across every `.jed` copy in
  the tree); **the board revision is still not recorded anywhere** and needs eyes on the PCB.
* **Store ordering through the FPGA is an assumption, specified nowhere.** The ethernet driver's
  acquire order — header before payload before serial — is derived from the firmware's own publish
  order in its transmit/receive code, i.e. from the ARM's store order *as seen through the FPGA*.
  No document specifies that ordering. Tagged `assumed`, and it is the first suspect if frames
  arrive torn or stale.

**May not claim:** that a coherency or ordering result here transfers to a local-bus 060 (a
Mercury), or the reverse. And **no performance number from here is comparable to a Mercury
number** except as an explicitly annotated cross-platform comparison — see §2.4 and §2.9.

### 2.4 The clock is an ARM-sourced table lookup, and one of its entries lives outside every repository.

Not a crystal. `PCLK`/`CLKEN` come from the Zynq PL clock wizard; the configured `cpufreq` is
clamped to `[50, 120]` and then **replaced by a table entry** (`clk = cd[ind].clk`), and in the
*emulated* modes an `emu_div = 2` halves both the PCLK and CLKEN dividers — so an emulated-mode
clock number and a real-CPU clock number are not the same quantity even when the config file says
the same word.

Worse, and this is the entry that will bite someone: at `Clock index 0` the shipped timing table
drove the **A4000 motherboard at half speed** (`BCLK`/`CPUCLK`/`CLK90` at 12.50 MHz), because the
table hardcodes the motherboard clock as `PCLK/4` — correct only at the 100 MHz index. The 060
clocked fine; the bus under it did not. The correction is four numbers at index 0 of
**`1:/timings/default_timings.txt` on the card's SD card** — a file that is **not in any
repository**, and which the firmware's own boot-menu item **`G` ("Apply default timings") silently
reverts**.

Standing hazards that ride this:

* **Never press boot-menu `G`** on this card while this platform is in use.
* Clock-table **indices 105–120 overclock the motherboard**. They are not a "try a bit faster"
  option.
* `cpufreq` **defaults to 50**, which is the index the fix lives in — so a card that has been
  reverted looks configured correctly and runs a broken bus.

**May not claim:** any number against a *configured* clock. The rule is absolute: read the clock
back and print `Clock index N` plus the `PCLK`/`BCLK` lines beside every result row.

### 2.5 It cannot currently be booted unattended.

Every `bootmode CPU` boot raises a **modal requester** for an AutoConfig board that is not a board
at all: an end-of-chain Zorro III probe with no responder, read as a Zorro II-typed 4 MB device
with a floating vendor field. It is deterministic — its preceding bus cycles are — and **it blocks
the boot until it is dismissed**. It is *expected* not to be removable by any configuration switch
the card has; the three-boot ladder that tests exactly that is registered in
`docs/060-F4-M2-PREREG-260824.md` §4.5 and has not run yet.

Remote dismissal is **not proven**: in the first-light captures the requester is still on screen
after a keypress *and* after a mouse click on Continue. The working session procedure is a
calibrated mouse click through the KVM, and it is a workaround, not a fix.

**May not claim:** any result whose method requires unattended boots — long soaks, boot-loop
statistics, power-cut durability with an automatic restart. Those shapes are not available on this
platform today, and saying "we did not run them" is different from "they passed".

### 2.6 The memory contract is undetermined — both shapes are still live.

The Fast-RAM window the emulated line uses is built by the card's *second core*, which does not
run in `bootmode CPU` at all; and the card's `amix_mode` switch forces `cpu_ram NO`. A 128 MB
Zorro III board seen during first light turned out to be the extension ROM's own software-declared
`ConfigDev` with `ERTF_MEMLIST` **clear** — an address range, not usable Fast RAM. So the question
is open, not answered.

The consequence is not cosmetic. **The kernel's load base follows the memory map** — this port
already knows that a Mercury binds at `0x08000000` and an A3640 at `0x07000000`, *"so every
address moves by 16 MiB between them"* (`ACCEPTANCE.md` §2). Every counter address, every battery
driver, every `kpeek` recipe moves with it.

**May not claim:** a counter reading taken at an inherited address. Regenerate from
`tools/status-facts.sh` against the artifact actually booted, at the load base actually observed,
and read the block magic before believing any number in it — which is the standing rule anyway,
and here it has a second, platform-specific way to go wrong.

### 2.7 Thermal policy is in force, and the only plateau that exists is a bare-Kickstart idle plateau.

There is no heatsink or fan in the card's BOM and no thermal limit or throttle anywhere in the
firmware; there is telemetry (an LTC2990) and a heatsink fitted by hand. The standing policy:

> baseline recorded each session; **WARN** at 60 °C or +30 °C over baseline; **ABORT** (halt, park,
> power off) at 70 °C or +35 °C, whichever comes first; real-CPU runs **capped at 15 minutes**
> until a plateau (< 2 °C per 5 min) is characterized, then the caps lift gradually.

It is not theoretical: the abort clause has **fired once**, at 70.19 °C after 383 s, on the
un-heatsinked card at the 2× clock. With the heatsink, at the rated 50 MHz, the part plateaued
**dead flat at 53.52 °C for 45 minutes** (slope 0.00 °C/5 min, 16.48 °C of margin) — **and that was
bare Kickstart sitting at an idle Workbench.** An AMIX install is a heavier load than an idle
Kickstart, and the first long run under it re-characterizes the plateau from scratch under the
15-minute cap.

One honesty note that changes how the numbers should be read: the **absolute** °C rest on the
shipped LTC2990 calibration constants, and the board's THERM resistor has never been measured.
**The relative thresholds (+30 / +35 over the session's own baseline) are the defensible ones.**

**May not claim:** that a run which ended at the cap failed, or that it passed. A truncated run is
truncated. And no durability claim survives a policy abort.

### 2.8 The 060-unimplemented integer instructions: an LC changes nothing — and this platform has still never run them.

An LC060 is a 68060 minus the FPU. The integer instruction set, and therefore the vector-61
unimplemented-integer-instruction path, is the same. The port's vector-61 unit is **hardware-
accepted on a full 060** (`isp61ea` 7/7, `docs/ISP-VECTOR61-LANDED-260806.md`), and there is no
mechanism by which an LC part would differ.

That is an argument from family, not a measurement on this platform. **Until `isp61ea` runs here,
any vector-61 claim about this platform is inherited**, and should be tagged as such.

The practical corollary is already in `ACCEPTANCE.md` §5 and applies unchanged: on this CPU,
`/usr/bin/cc` dies on vector 61 (gcc's own `cpp` and `cc1` contain 64-bit `muls.l`). Build guest
tools with `/usr/ccs/bin/cc`.

### 2.9 Superscalar dispatch is off unless something turns it on — and on this platform nothing does.

`PCR` bit 0 is `ESS`, *enable superscalar dispatch*, and the manual says it must be set for normal
operation (`docs/060-PCR-BIT1-VERDICT-260824.md`). On the Mercury it reads **set** —
`pcr_boot = 0x04300601` — and it is set there **by SetPatch**, i.e. by AmigaOS.

`docs/060-D-CACHE-KNOBS-PLAN.md`'s own knob table records it in one line: `ESS` superscalar
dispatch, PCR bit 0, **"on — measured, not set by us — inherited from SetPatch"**.

This platform boots natively, by design: bare Kickstart, and **neither SetPatch nor
`68060.library`** — which is precisely the pair that sets `ESS` on the Mercury. The port does not
write it either (`src/cputype060.s` only *captures* the word; the `fpuinit` probe clears bit 1 and
nothing else). The expected native-boot state is therefore `ESS = 0`.

**May not claim:** a per-MHz performance comparison against any AmigaOS-hosted 060 number without
reading `PCR` on both sides and saying so. The Mercury's `916.1 dhry/MHz` reference was taken with
`ESS = 1`; comparing a native-boot number to it without that annotation compares two different
machines.

### 2.10 There is no oracle. Zero LC060 results exist anywhere, including the identity reading.

`STATUS.md`'s matrix has four `untested, unknown` cells for `68LC060 / EC variants`, and no LC060
result exists in this project. There is nothing to differential-test against and nothing to
sanity-check a surprise against — which is exactly why every expectation from this platform has to
be registered before the run rather than recognised after it.

That extends to the identity reading itself. The PCR ID high word is expected to be `$0431`, but
that expectation rests on **two implementations agreeing** — an emulator models a no-FPU part as
`0x0431`, and the card's own extension ROM gates its FPU-disable code on `== $430` and branches
away otherwise — and **not on the manual**. A real part reading `$0430` with no FPU is a possible
outcome and would be a finding about everyone's gate, not a failure of the boot.

**The vector-11 probe remains the authoritative negative probe**, exactly as
`docs/contracts/FPU-TIER1-ENABLE-SPEC.md:238-240` pre-refutes the shortcut: *"Do not simply clear
PCR bit 1 and declare success. A 68LC060 or EC variant can lack usable hardware FP, and vector 11
remains the authoritative negative probe."* The PCR readback is a diagnostic. It is not the
decider, on this platform least of all.

### 2.11 A trap may be classified differently here than on the bench — the outcome is invariant, the counter split is not.

On the synthetic-LC bench rig every no-FPU floating-point instruction arrived as **FP-disabled**
and was counted on that arm. Real LC silicon may raise a plain **F-line** instead, landing on the
other arm of the same dispatch (`src/fpsp060_glue.s`, `Lco_fline` versus `Lco_fpu_disabled`). Both
arms `jmp nullvect`; both end in `SIGSYS` for a user process. **The outcome is invariant; only the
split moves.**

**May not claim** — and this is a rule for writing predictions, not for reading them: register the
invariants

```text
f60_entry_n == f60_fpudis_n + f60_fline_n
f60_fpudis_nofpu_n == f60_fpudis_n
```

and the outcome, **never the arm split**. A prediction that pins the split will score a correct
kernel as a miss the first time silicon classifies differently from the emulator.

---

## 3. What it does model, that nothing else here does

A list of blind spots read alone makes a platform look worthless. This one is the most evidential
rig in the project for three classes, and that is why the list above exists at all:

* **a real 68060 data cache in copyback**, executing real maintenance — the class ISSUE-38 lives
  in, and the class neither emulated platform can see;
* **a real bus, with real DMA from a real device**, including a DMA path that no snoop covers —
  the class the 2026-07-13 page-crossing wild write lived in;
* **a genuinely FPU-less part.** Regime 3 is not reachable on any other real machine here, and an
  emulated 060 has a *present* FPU — it can only ever exercise regimes 1 and 2. Every claim this
  port makes about running correctly without an FPU is, in the end, a claim about this platform.

---

## 4. Reading a result from this class

1. **Tag it `LC060-Z3660`.** Not `HW`, not `EMU`. If a row needs a class it does not have, add the
   class rather than borrowing the nearest one.
2. **Carry four readbacks with every row**, or the row is not a result:
   `Clock index N` + the `PCLK`/`BCLK` lines (§2.4); `pcr_boot` (§2.9, §2.10); `CACR`, including
   the store-buffer and branch-cache bits (§2.2); and the **load base** the counters were computed
   against (§2.6).
3. **Read every block magic before every counter in it.** Standing rule, doubly live here because
   the load base is not yet a constant on this platform.
4. **Say which of §2's entries the result is downstream of.** A green run that is downstream of
   §2.1 (no FP executed) or §2.7 (ended at the thermal cap) is a green run with a scope, and the
   scope belongs in the same sentence as the result.
5. **This list is not closed.** `AGENTS.md` says as much of Amiberry's list, and it is truer here,
   where the platform has produced no results at all yet. An entry earned by measurement is worth
   more than every entry above that was earned by reading code — add them.

---

## 5. Files

```text
docs/ACCEPTANCE.md                       §1, the rule this document exists to satisfy
docs/contracts/FPU-TIER1-ENABLE-SPEC.md  :238-240, the pre-refutation §2.10 rests on
docs/060-PCR-BIT1-VERDICT-260824.md      the PCR layout, incl. bit 0 = ESS (§2.9)
docs/060-F1-M2-GATE-CENSUS-260824.md     §4, the arm-classification note behind §2.11
docs/ISP-VECTOR61-LANDED-260806.md       the vector-61 unit §2.8 inherits from
src/fpsp060_glue.s                       the two vector-11 arms and the regime-3 path
src/cputype060.s                         pcr_boot: captured, never written
src/inituname040.s                       :32-34, the banner flip
STATUS.md                                the platform matrix with no column for this class
```
