# Adding 68040 / 68060 Support to Amiga Unix (AMIX SVR4)

**A feasibility and reverse-engineering analysis**

Target system: Commodore Amiga UNIX System V Release 4.0 (Amiga, Limited) Version 2.1,
as shipped on the Amiga 3000 (68030 @ 0x0800089c fast RAM).
Source basis: `amix-sources.tar` from the mounted vanilla disk image, plus the
installed kernel `stand/unix`. All disassembly in this report was produced with
`m68k-linux-gnu-objdump -m m68k:68030` against the un-stripped `stand/unix`, and the
addresses/opcodes shown are real output (see §4).

---

## 1. Executive summary

Adding 68040/68060 support to AMIX is the **hardest** of the four known limitations
(synchronous SCSI, Zorro II memory limits, Zorro III, CPU support). It is, however,
**not categorically impossible**. The decisive factors are:

1. **The whole kernel is built for the 68020/68030 only.** Every machine-dependent
   path — MMU setup, cache control, exception frames, FPU save/restore — uses
   instructions and register formats that the 68040 and 68060 either redefine or
   removed entirely.

   **The single biggest obstacle, found by disassembly (§4.3), is the page size.**
   AMIX runs the MMU with a **2 KB hardware page** (TC register `0x82B02D60`,
   PS field = 2 KB). The 68040 and 68060 MMUs support **only 4 KB or 8 KB pages** —
   2 KB is not selectable in hardware. The 2 KB assumption is baked into the VM at
   hundreds of sites (176 `addil #2047` page round-ups, ~450 `>>11` PFN shifts), so
   a CPU port is not merely instruction translation: it forces a **global page-size
   change** that ripples through the entire (binary-only) VM subsystem.

2. **The machine-dependent C core is not available as source.** Only the Amiga *glue*
   layer (`sys/amiga/`) ships as real C/assembly. The SVR4 machine-dependent files
   that matter most (`machdep.c`, `vm_machdep.c`, `vm_hat.c`, `trap.c`, `fpu.c`,
   `fpu.s`) exist **only as precompiled relocatable objects** (`sys/os/exp`,
   `sys/vm/exp`, `sys/ml/exp`) and inside the final `unix` binary.

3. **Reverse engineering is unusually tractable here.** The kernel and every `.exp`
   object are **non-stripped, relocatable ELF with full symbol tables and full
   relocation records**. This is the best possible starting point short of having
   source: functions have names, source files are identifiable, and relocations are
   resolvable. (Details in §4.)

**Verdict:** A 68040 port is a realistic multi-month reverse-engineering and kernel-
hacking project for a small team, with NetBSD/amiga and Linux/m68k as proven
reference implementations of the exact same CPU transitions. A 68060 port is
strictly harder still (more software emulation required). Neither is a weekend patch.

---

## 2. Why the current kernel is 68020/030-only

The CPU dependency is not isolated in one file — it is woven through every privileged
path. The following is grounded in the actual AMIX source and binary.

### 2.1 MMU programming — `PMOVE` vs `MOVEC`

The 68030 has an on-chip MMU programmed with the `PMOVE` instruction and the
`TC` / `TT0` / `TT1` / `CRP` / `SRP` register set. The 68040/060 **removed `PMOVE`
entirely** and replaced the MMU with a `MOVEC`-accessed register set
(`TC`, `ITT0/1`, `DTT0/1`, `URP`, `SRP`) using **completely different bit layouts**
and a different page-table descriptor format.

In AMIX this appears directly in source we *do* have:

`sys/amiga/kernel/servant.s` (reboot / MMU teardown):
```asm
    pmove   (%a0),%tc        # 68030 only — does not exist on 040/060
    pmove   (%a0),%crp
    pmove   (%a0),%srp
```

`sys/amiga/ml/ttrap.s` (MMU enable values, 68030 register formats):
```asm
tc_on:  long 0x82B02D60   # 68030 TC format (E,Psize,TI fields)
tt0_on: long 0x003F0143   # 68030 TT0 format
tt1_on: long 0x807F0143   # 68030 TT1 format
```

On a 68040/060 every one of these constants and instructions must be replaced.
The TC/TT formats differ; the 040/060 transparent-translation registers are
`ITTx`/`DTTx` (split I/D) rather than a single `TTx`.

### 2.2 Cache control — `CACR` writes vs `CINV`/`CPUSH`

The 68030 has a simple 32-bit `CACR` (instruction + data cache enable/freeze/clear
bits). The trap handler switches cache mode on every kernel entry:

`sys/amiga/ml/ttrap.s` does this at every interrupt vector: it loads the kernel's cached
supervisor CACR value from a global and writes it to `%cacr`, i.e. cache mode is re-selected on
every kernel entry rather than left alone.

`stand/unix` confirms the cached values are kernel globals:
```
5059: 000072bc  4  OBJECT GLOBAL  cacr        # user-mode CACR value
6800: 000072c0  4  OBJECT GLOBAL  sup_cacr    # supervisor-mode CACR value
```

On the 68040/060 the `CACR` bit layout is different (the 040 CACR only has
`DE`/`IE` enable bits; copyback vs write-through is per-page in the PTE), and
**coherency is no longer maintained by toggling CACR**. Correct operation requires
explicit `CINV` (invalidate) and `CPUSH` (push/flush) instructions at the right
points — DMA buffers, page-table edits, context switches, self-modifying boot code.
None of that machinery exists in the current kernel. This is one of the most
error-prone parts of any 040/060 port (silent cache-coherency corruption).

### 2.3 Exception stack frames

The trap return path rebuilds 68020/030 exception frames by frame format code: it takes the
format nibble out of the saved frame, uses it as the index into a `framesz` table, and reads the
frame's byte length from there (`sys/amiga/ml/ttrap.s:237`). Two routines in the same file carry
the frame conversion: one collapses the exception frame to the four-word form, the other rebuilds
a 68020 frame from the copy saved in the u-block.

The 68040 and 68060 generate **different frame formats and sizes** (notably the
format `$7` access-error frame on the 040, and the 060's frames), and the 060 in
particular needs software assistance for some of them. The `framesz` table and the
`stkclear`/`stkrestore` logic must be extended for the new formats. The good news:
**this code is in source we have** (`ttrap.s`).

### 2.4 FPU save/restore and the FPSP

The 68030 uses an *external* 68881/68882 coprocessor. The 68040 and 68060 have an
*internal* FPU, but with two complications:

* `FSAVE`/`FRESTORE` produce **different internal state-frame formats and sizes**
  (NULL / IDLE / UNIMP / BUSY frames differ per CPU).
* The 68040 omits several transcendental instructions (e.g. `FSIN`, `FCOS`,
  `FETOX`, `FMOVECR` constants…) and the 68060 omits even more. These require the
  Motorola **FPSP** (Floating-Point Software Package) — an F-line/unimplemented-
  instruction trap handler that emulates the missing operations.

The current AMIX FPU code is tiny and 68881/882-shaped. From `stand/unix`:
```
fsave        @ 0x00000122      # FSAVE wrapper
frestore     @ 0x0000012a      # FRESTORE wrapper
fpu_save     @ 0x00000132
fpu_restore  @ 0x00000158
fpu_present  @ 0x00004fdc      # detection flag
fpu_ptr      @ 0x00004fe0
fpuinit / fpu_setup / fpu_wrt_ok / chk_fpu   (fpu.s + fpu.c)
```
Raw disassembly of the `fpu.s` region (file offset `0x34 + 0xc0`) shows standard
`fmovem`/`fsave`/`frestore` coprocessor opcodes (`f210 f0ff` = `fmovem fp0-fp7`,
`f228 bc00 0060` = `fsave`), with **no F-line unimplemented-instruction handler** —
i.e. no FPSP hook. A 68040 port must add FPU detection for the internal unit, the
new frame sizes, and at minimum the 040 FPSP; a 68060 port must add the 060SP
(integer + FPU emulation, including the unimplemented integer `divs.l`/`muls.l`
long forms on early 060 mask sets).

### 2.5 The vector table and boot CPU assumptions

`sys/amiga/ml/vec.s` is explicitly titled *“Motorola M68020 vector table”* and
`ttrap.s` *“Motorola M68020 interrupt/trap handler.”* The boot path
(`sys/amiga/boot/boot2.c`) does no CPU capability detection at all — it relies on
AmigaOS having configured the machine. `boot_arg0` only distinguishes boot *method*
(A2620 ROM / EXEC0 / EXEC1), not CPU type. There is no `AttnFlags`/CPU-class probe
anywhere in the kernel boot.

---

## 3. What source we have vs. what is binary-only

This split determines the entire engineering strategy.

### 3.1 Available as real source (`sys/amiga/` in the tar)

| File | Role | CPU-specific content |
|------|------|----------------------|
| `ml/ttrap.s` | interrupt/trap handler, MMU enable, frame fixup | **High** — CACR, TC/TT, framesz |
| `ml/vec.s` | 68020 vector table | Low (just vectors) |
| `ml/syms.s` | kernel virtual-address layout symbols | Low |
| `kernel/servant.s` | halt/reboot, MMU teardown (`pmove`) | **High** |
| `kernel/support.c` | bootinfo parsing, memory sizing | Low (C, portable) |
| `boot/*.c` | two-stage bootloader | Low |
| `driver/*.c`, `alien/*.c` | device drivers | None (CPU-agnostic) |

Crucially, **a large fraction of the CPU-specific *assembly* (`ttrap.s`,
`servant.s`) is in source.** That covers MMU enable values, the per-vector CACR
switch, and the exception-frame fixup — three of the six problem areas in §2.

### 3.2 Binary-only (precompiled `.exp` objects + `unix`)

The machine-dependent **C** core is *not* in the tar as source. It is present only
as relocatable objects that the final link pulls in:

```
sys/ml/exp   19,300 bytes   ELF MSB relocatable, m68k 68020, not stripped
sys/os/exp  233,640 bytes   ELF MSB relocatable, m68k 68020, not stripped
sys/vm/exp  103,960 bytes   ELF MSB relocatable, m68k 68020, not stripped
```

By the `FILE` symbols in `unix`, these objects contain (among others):
`machdep.c`, `prmachdep.c`, `vm_machdep.c`, `vm_hat.c`, `trap.c`, `fpu.c`, `fpu.s`,
`seg_map.c`, `vm_page.c`, `vm_pageout.c`, `bitmap.c`. The MMU abstraction (the SVR4
“HAT” layer) lives here:
```
hat_pteload   @ 0x000b4d64
hat_getkpfnum @ 0x000b5f2e
vatopte       @ 0x000b7540
swtch         @ 0x000b902c
resume        @ 0x0000009c     # context-switch MMU/register reload
ptest / ptest0                 # 68030 PTEST wrappers (MMU probe)
```
`resume`, `ptest`, the page-table descriptor format inside `hat_pteload`, and the
cache flushing inside the context switch are all **68030-shaped and binary-only**.
These are the parts that will require reverse engineering rather than recompilation.

---

## 4. Reverse-engineering feasibility

This is the pleasant surprise of the analysis. The AMIX kernel is about as
RE-friendly as a closed binary can be.

### 4.1 The binary is relocatable, symbol-rich, and un-stripped

`readelf -h stand/unix`:
```
Type:    REL (relocatable)        <-- not a final a.out; relocations preserved
Machine: MC68000
Data:    2's complement, big-endian
```
`readelf -S stand/unix` shows the sections that make RE tractable:
```
.text      0x0d71a8 (~860 KB)
.data      0x00fed4
.bss       0x010810
.symtab    4370 symbols           <-- function & object names preserved
.strtab
.rela.text 0x04737c  (relocs for text)   <-- every cross-reference resolvable
.rela.data 0x00b124  (relocs for data)
.comment   "as: (CDS) 5.0 1/2/90" (toolchain fingerprint)
```

Concretely this means:

* **Every function has a name.** 4370 symbols including `swtch`, `resume`,
  `hat_pteload`, `trap`, `fpu_save`, `mlsetup`, etc. You are not staring at
  `sub_b4d64` — you are looking at `hat_pteload`.
* **Source files are identifiable.** `FILE` symbols (`machdep.c`, `vm_hat.c`,
  `fpu.s`, …) partition the text so you know which routine came from which original
  `.c`/`.s`.
* **Relocations are intact.** `.rela.text`/`.rela.data` let a disassembler resolve
  every `jsr`/`lea`/data reference to a named target, instead of guessing absolute
  addresses. This is the single biggest accelerator for RE.
* **The `.exp` objects are individually analyzable** (each is the same un-stripped
  relocatable ELF), so you can study `sys/vm/exp` and `sys/os/exp` in isolation.

### 4.2 Tooling note — confirmed working

The stock Debian `objdump` is **not** built with m68k support
(`objdump -m m68k:68030` → “cannot set architecture”). Installing the cross-binutils
fixes this and is what produced every disassembly in this report:

```sh
sudo apt-get install binutils-m68k-linux-gnu      # objdump/readelf/nm/ld for m68k
sudo apt-get install gcc-m68k-linux-gnu           # to compile replacement .o files
# Optional but recommended primary RE tool: Ghidra (bundled m68k module) + default-jdk

# One-shot full disassembly with symbols + resolved relocations:
m68k-linux-gnu-objdump -d -m m68k:68030 stand/unix > amix_unix.dis
```

Because relocations and symbols survive, **Ghidra** will import the ELF with named
functions and cross-references directly — turning the task from “reconstruct
everything” into “read and re-target the handful of CPU-specific routines below.”

### 4.3 What you would actually reverse-engineer — *now mapped precisely*

The 68030 hardware-MMU surface is **not** scattered through 860 KB. Disassembly shows
it is confined to ~10 named functions and exactly **21 privileged-instruction sites**
(`pmove`×11, `pflusha`×8, `ptestr`×2) — every one of which is illegal on the
68040/060 and must be rewritten:

| Function | Addr | 68030 instr (illegal on 040/060) | Role |
|----------|------|----------------------------------|------|
| `pstart` | `0x00d44` | `pmove %srp` / `pflusha` / `pmove %tc` | **first MMU enable** |
| `nomsg` (reboot, = `servant.s`) | `0x18ece` | `pmove %tc/%crp/%srp` | MMU teardown |
| `resume` | `0x0009c` | `pflusha` | context switch |
| `swtch` | `0xb902c` | `pmove %crp` / `pflusha` | scheduler ctx switch |
| `hat_map` | `0xb57e0` | `pmove %crp` / `pflusha` | load address space |
| `hat_exec` | `0xb6f20` | `pmove %crp` / `pflusha` | exec() address space |
| `hat_asload` | `0xb7444` | `pmove %crp` / `pflusha` | address-space load |
| `flushmmu` | `0xb78c4` | `pflusha` | TLB flush |
| `ptest` / `ptest0` | `0x003a8`/`0x3c0` | `ptestr` + `pmove %psr` | MMU probe (fault handling) |
| `_start` | `0x00038` | `pflusha` | boot |

On the 040/060 these become `MOVEC`-accessed `URP/SRP/TC` loads plus the new
`PFLUSHA`/`PTESTR/PTESTW` encodings (and on the **060** `PTEST` is gone entirely → a
software table walk is required in the fault path).

**The page-table *format* (separate from the instructions) is the deeper problem.**
The translation routines are tiny and fully readable, but their geometry is 68030 +
2 KB pages:

```
vatopte (0xb7540):     bfextu %fp@(-7),7,6,%d0   ; extract 6-bit table index from VA
                       asll  #2,%d0              ; *4  (PTE = 4 bytes)
                       addl  %a0@(4),%d1         ; + table base
hat_getkpfnum(0xb5f2e):lsrl  #11,%d0             ; PFN = VA >> 11  => 2 KB page
mlsetup (0x48ac8):     addil #2047,%d0 / lsrl #11; round up & divide by 2 KB
```

The `>>11` and `+2047` idioms (2 KB page) recur **451** and **176** times
respectively across the kernel. The 040/060 three-level fixed table format with
4 KB/8 KB pages is a different shape, so `vatopte`, `hat_pteload`, and the PFN math
must be reworked — and because the page size changes, so does every consumer of it.

**FPU (`fpu.s`, fully disassembled).** The save/restore use a 68881/882-style frame
held at offset `0x70` of the FPU save area:

```
chk_fpu (0xc0):     frestore <0>; fsave ...      ; presence/type probe via frame byte
fpu_save (0x132):   fsave %a0@(112); tstb %a0@(112)  ; skip if null frame
                    fmovemx %fp0-%fp7,%a0@(4)
                    fmoveml %fpiar/%fpsr/%fpcr,%a0@(100)
fpu_restore(0x158): fmovemx/fmoveml back; frestore %a0@(112); andil #-2,%a0@
```
`fmovemx`/`fmoveml` are fine on 040/060, but the **FSAVE/FRESTORE frame sizes differ
per CPU** and there is **no F-line/unimplemented-instruction handler** — so the 040
FPSP (and 060SP) must be added and the save-area sized for the new frames.

**Cache.** Note `_start`/`resume` rely on `pflusha` for the ATC, and the per-vector
`mov.l sup_cacr,%cacr` (in `ttrap.s` source) for the caches. On 040/060 ATC flushing
and data-cache push/invalidate are separate (`CINV`/`CPUSH`) and must be inserted at
DMA and PTE-edit points.

Everything else (scheduler logic, VFS, STREAMS, TCP/IP, drivers) is CPU-agnostic and
relinks unchanged.

---

## 5. Engineering approaches, ranked

### Approach A — Hybrid: patch the source we have, RE-and-relink the rest *(recommended)*

The AMIX build links `sys/amiga/*` source objects together with the `sys/*/exp`
precompiled objects to produce `unix`. That same mechanism is the leverage point.

1. **Rewrite the source-available assembly** (`ttrap.s`, `servant.s`) for 040/060:
   `PMOVE`→`MOVEC`, new TC/TT/RP constants, new `framesz` entries, CACR→CINV/CPUSH.
   This is normal kernel hacking — no RE needed.
2. **Reverse-engineer only the binary-only CPU routines** (§4.3) from the `.exp`
   objects, and provide **replacement object files** that the linker uses instead of
   (or in addition to) the originals. Because the objects are relocatable ELF with
   symbols, a hand-written replacement `.o` exporting the same symbols
   (`resume`, `hat_pteload`, `fpu_save`, …) can be substituted at link time.
3. **Add an FPSP**: port Motorola’s 040 FPSP (or Linux/m68k’s `fpsp040`) as a new
   object, hook it on the F-line/unimplemented vector in `vec.s`.
4. **Relink** `unix` with the patched glue + replacement objects + the untouched
   CPU-agnostic `.exp` mass.

This is the highest-probability path because it minimizes RE to the ~6 routine
classes that genuinely differ, and reuses the entire portable kernel as-is.

### Approach B — Full binary patching of `unix`

Patch the linked `unix` in place (replace `pmove`/`cacr` sequences, redirect FPU
traps). Tempting for small fixes but a poor fit here: the 040 frame-size and
cache-coherency changes are not size-neutral, and inserting an FPSP needs new code
space. Use binary patching only for tiny, size-preserving tweaks during bring-up
(e.g. forcing a code path), not as the delivery mechanism.

### Approach C — Emulator-first bring-up *(do this regardless of A or B)*

Develop against an emulated 68040 (e.g. WinUAE / a 68040-capable UAE, or MAME’s
68040 core) before touching real hardware. Rationale:

* The current kernel **crashes if you simply enable a feature it isn’t ready for**
  (already observed with synchronous SCSI). A wrong MMU/CACR value on a 040 will
  hang or silently corrupt; an emulator gives you single-step, register dumps, and
  reproducibility that the real A3000 cannot.
* You can bisect each subsystem (MMU enable → first context switch → first user
  process → FPU) with deterministic state.
* Only after the kernel boots multiuser under emulation do you move to a real
  68040 accelerator (e.g. an A3640/retargeted card or a Zorro 040/060 board).

### Approach D — Don’t port; recompile *(why it isn’t available)*

The clean solution would be to recompile `machdep.c`/`vm_machdep.c`/`fpu.s` with
040/060 codegen. **Not possible: those sources are absent from the image** (§3.2).
If the original AT&T/Commodore SVR4 machine-dependent sources ever surface, this
becomes the right path and the RE work in §4 is obviated. Worth a parallel effort to
locate them (Commodore source escrow, the AMIX developer community, archived SVR4/m68k
ports). Note that the *generic* SVR4/m68k machine-dependent code shares lineage with
other SVR4 68k ports, so even partial source from a sibling port is valuable reference.

---

## 6. Reference implementations to mine

The 68030→68040→68060 transition is extremely well-trodden. None of this has to be
invented:

* **NetBSD/amiga** (`sys/arch/m68k/m68k/` + `sys/arch/amiga/`): clean, readable,
  BSD-licensed support for 68030, 68040 **and** 68060 on the exact same Amiga
  hardware family. The canonical reference for MMU register setup, cache routines
  (`DCFP`/`ICPA` style), frame handling, and FPU/FPSP integration.
* **Linux/m68k** (`arch/m68k/`): `fpsp040/` (the 040 FPSP) and `ifpsp060/` (the 060
  Software Package wrapper) are directly portable as the FPU/integer emulation layer.
* **Motorola originals**: the **M68040 FPSP** and **MC68060 Software Package (060SP)**
  reference releases — the assembly these other OSes wrap.
* **AmigaOS `68040.library` / `68060.library`**: prove the cache and FPSP behavior on
  identical boards; useful for sanity-checking timing and cache modes.

The AMIX-specific work is therefore *adaptation* (matching SVR4’s HAT/PTE format and
trap conventions), not greenfield 040/060 enablement.

---

## 7. Difficulty-ordered task breakdown

From least to most painful, with the source/RE split made explicit:

| # | Task | Source available? | Risk |
|---|------|-------------------|------|
| 1 | CPU/FPU detection at boot (add an AttnFlags-style probe) | Partly (`support.c`) | Low |
| 2 | New MMU enable constants (TC/ITT/DTT), `PMOVE`→`MOVEC` at the 21 mapped sites | **Yes** for `ttrap.s`/`servant.s`; **RE** for `pstart`/`resume`/`swtch`/`hat_*`/`flushmmu`/`ptest` | Med |
| 3 | Exception-frame format/size table (`framesz`, `stkclear/stkrestore`) | **Yes** (asm) | Med |
| 4 | Cache coherency: replace CACR toggling with `CINV`/`CPUSH` at DMA / PTE / ctx-switch sites | Mixed (some asm, some binary) | **High** |
| 5 | RE + replace `resume`/`swtch` MMU/cache reload | **No** (RE) | **High** |
| 6 | FPU: new FSAVE/FRESTORE frame sizes + internal-FPU detection (`fpu.s`/`fpu.c`) | **No** (RE) | High |
| 7 | Integrate 040 FPSP (port from Linux/Motorola) | New code | High |
| 8 | **Global page-size change 2 KB → 4 KB/8 KB** (HAT PTE format `hat_pteload`/`vatopte`, all `>>11`/`+2047` PFN math, segment/swap granularity) | **No** (RE, pervasive) | **Showstopper** |
| 9 | 68060 only: 060SP integer emulation, software PTEST table walk, extra unimplemented-FPU coverage | New code | **Highest** |

Task **8 dominates the risk** and is sequenced last among the “must-haves” because it
touches the most code and is binary-only. Realistically it should be **prototyped
first on paper** (decide 4 KB vs 8 KB, map every `>>11` site) even though it lands
late, because it constrains every other VM decision.

A pragmatic milestone ladder: **(a)** boot to the MMU-enabled idle loop on an emulated
040 with the new page size (tasks 1–5, 8), **(b)** reach single-user with no FPU
(FP disabled), **(c)** add FPSP and FP user programs (6–7), **(d)** real hardware,
**(e)** 68060 (9).

---

## 8. Bottom line

* **Is it possible?** Yes for 68040, but with one genuinely hard sub-project — the
  forced **2 KB → 4 KB/8 KB page-size change** (§4.3, task 8) — on top of bounded,
  well-mapped MMU/FPU reverse engineering. 68060 is possible but adds a second large
  software-emulation layer (060SP) and a software MMU table walk (no `PTEST`).
* **Is the existing kernel code helpful?** Substantially. The most error-prone
  *assembly* (MMU enable, per-vector cache switch, exception-frame fixup, MMU
  teardown) is **in source** (`ttrap.s`, `servant.s`, `vec.s`). That removes a big
  chunk of the RE burden. The remaining hardware-MMU instruction sites are now
  **mapped exactly** — 21 sites in ~10 named functions (§4.3).
* **Is RE realistic for the binary-only parts?** Yes — and this is the strong point.
  The kernel and all `.exp` objects are **non-stripped, relocatable, fully symboled
  ELF with intact relocation tables**, so a Ghidra/m68k import yields named functions
  and resolved cross-references. The RE surface is small and well-identified
  (`resume`, `swtch`, `hat_pteload`, `vatopte`, `fpu.*`, `ptest`).
* **What would make it easy?** Locating the original SVR4/m68k machine-dependent
  sources (`machdep.c`, `vm_machdep.c`, `fpu.s`) so the binary-only routines can be
  recompiled instead of reversed.
* **Recommended path:** Approach A (hybrid source-patch + targeted RE + relink),
  developed Approach C (emulator-first), using NetBSD/amiga and Linux/m68k as
  reference, delivered in the milestone ladder of §7.

---

### Appendix — key evidence locations

```
sys/amiga/ml/ttrap.s        CACR switch, tc_on/tt0_on/tt1_on, framesz, stkclear/stkrestore
sys/amiga/ml/vec.s          "M68020 vector table"
sys/amiga/kernel/servant.s  pmove %tc/%crp/%srp on reboot
sys/amiga/kernel/support.c  config(): bootinfo + memory sizing (boot_arg0 = boot method)
stand/unix                  REL ELF, MC68000, 4370 symbols, .rela.text/.rela.data present
  symbols: resume@0x9c, swtch@0xb902c, hat_pteload@0xb4d64, vatopte@0xb7540,
           fpu_save@0x132, fpu_restore@0x158, fpu_present@0x4fdc,
           cacr@0x72bc, sup_cacr@0x72c0, mlsetup@0x48ac8
sys/os/exp  (233 KB)        machdep.c, trap.c, vm_*, vm_machdep.c, vm_hat.c  (binary only)
sys/vm/exp  (104 KB)        VM core (binary only)
sys/ml/exp  (19 KB)         low-level ml (binary only)
.comment                    "as: (CDS) 5.0 1/2/90"  (SVR4 CDS toolchain; 344 gcc-compiled units)
```

Disassembly facts (via `m68k-linux-gnu-objdump -m m68k:68030 stand/unix`):
```
Page size = 2 KB           TC = 0x82B02D60 (PS field); hat_getkpfnum: lsrl #11
                           pervasive: addil #2047 x176, '>>11'/moveq #11 x451
Illegal-on-040/060 PMMU instructions = 21 sites:
  pmove   x11   pstart@0xfde(%tc), nomsg/reboot@0x18ee2(%tc/%crp/%srp),
                swtch@0xb923c(%crp), hat_map@0xb58c6, hat_exec@0xb70ea,
                hat_asload@0xb7472, ptest@0x3b0/ptest0@0x3c8 (%psr)
  pflusha x8    _start@0x38, resume@0xb2, pstart@0xfda, hat_map@0xb58ca,
                hat_exec@0xb70ee, hat_asload@0xb7476, flushmmu@0xb78d0, swtch@0xb9240
  ptestr  x2    ptest@0x3ac, ptest0@0x3c4
FPU frame (68881/882-style) at save-area offset 0x70; no F-line/FPSP handler:
  chk_fpu@0xc0, fpu_save@0x132, fpu_restore@0x158
```
