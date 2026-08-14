# AMIX Boot Path Map — from AmigaOS to MMU-enabled kernel

Purpose: a precise, instruction-level map of how control reaches the AMIX kernel and
how the kernel turns on the MMU, so the 68040/060 bring-up has an exact starting
point. Every address/opcode below is real output from
`m68k-linux-gnu-objdump -m m68k:68030 stand/unix` (kernel side) and the
`unix_boot/src` sources (AmigaOS side).

The 68030-specific steps that **must change for 68040/060** are marked **⚠️ 030**.

---

## Stage 0 — AmigaOS side (`unix_boot`, or the equivalent `sys/amiga/boot/boot2.c`)

`unix_boot` (Markus Wild, 1991) is an AmigaDOS program that boots an ELF kernel
*without rebooting*. It is the DOS-based twin of `boot2.c` and is the recommended
development bootstrap (see “Why unix_boot matters” below).

### 0a. `unix_boot.c : main()`
1. Parse args: `unix_boot [kernel_file [bind_address]]`. Default kernel `unix`,
   default bind address `0xFFFFFFFF` (= auto).
2. `stat`/`open`/`read` the ELF kernel into a `MEMF_FAST` buffer.
3. Build `struct bootinfo` in **chip** RAM (`MEMF_CHIP|MEMF_CLEAR`):
   * `bi->autocon[]` ← walk `ExpansionBase->BoardList` (every `ConfigDev`, incl.
     Zorro III) — this is what fills `bootinfo.autocon[16]`.
   * `bi->memory[]` ← walk `SysBase->MemList` (every `MemHeader`).
4. `bindaddr = bind()` if auto — pick the largest non-chip RAM region
   (`unix_boot/src/bind.c`). **Refuses to bind into chip RAM.**
5. `rel()` relocates the ELF kernel to `bindaddr`, filling `bi->bootdata`
   (`bd_entry`, `bd_tvaddr`, `bd_tsize`, …). Requires text+data contiguous, text first.
6. Fill `struct copyinfo` in chip RAM: `ci_d0 = EXEC1 (3)`, `ci_d1 = bi`,
   `ci_entry = bd_entry`, copy `copyit` code into chip RAM, then
   `supervisor(copyit, copyinfo)`.

### 0b. `Supervisor.s : _supervisor()`
Enters supervisor mode via `exec/Supervisor`, with the copy routine pointer in `a5`
and `copyinfo` in `a2`. The user routine must end in `RTE`.

### 0c. `copyit.s : _copyit()` — runs in chip RAM, supervisor mode
```asm
    movew  #0x2700,sr            | ints off, supervisor
    lea    pc@(zero-.+2),a0
 ⚠️030 pmove  a0@,tc             | turn MMU OFF      (68030 PMOVE)
    lea    pc@(nullrp-.+2),a0
 ⚠️030 pmove  a0@,crp            | turn MMU OFF      (68030 PMOVE)
 ⚠️030 pmove  a0@,srp            | turn MMU OFF      (68030 PMOVE)
    btst   #2,(4)@(0x129)        | AFB_68030 in SysBase->AttnFlags
    beq    nott                  | skip TT regs if NOT 68030
 ⚠️030 .word 0xf010,0x0800       | pmove a0@,tt0     (68030 only — already guarded)
 ⚠️030 .word 0xf010,0x0c00       | pmove a0@,tt1     (68030 only — already guarded)
nott:
    <copy text+data from load buffer to ci_vaddr, byte-wise, up or down>
    movel  a2@(ci_entry),a0
    movel  a2@(ci_d0),d0         | d0 = 3 (EXEC1)
    movel  a2@(ci_d1),d1         | d1 = bootinfo *
    jmp    a0@                   | --> kernel _start, MMU OFF
```
**⚠️ First 040/060 crash point.** The three *unguarded* `pmove tc/crp/srp` execute on
any CPU. On a 68040/060 `PMOVE` is illegal → the machine traps **before the kernel
runs**. The TT-register block is already guarded by `AFB_68030`, but the MMU-disable
above is not. For 040/060 this must become a `movec`-based MMU disable
(`movec #0,TC`; clear `URP/SRP`; `movec #0,ITT0/ITT1/DTT0/DTT1`), selected by AttnFlags
(AFB_68040 = bit 3, AFB_68060 = bit 7).
**→ FIXED in our `unix_boot/src/copyit.s` (AttnFlags-guarded 040/060 `movec` path).**

**⚠️ Second stock defect — the copy itself (FIXED 2026-07-09, commit `196ed09`).** The
stock copy loop had its direction choice INVERTED for overlapping ranges (dest<src copied
descending, dest>=src ascending — each clobbers unread source bytes) and copied size+1
bytes (one stray byte below the destination). With `AllocMem(MEMF_FAST)` placing the ELF
buffer ~0.94 MB above the fast-RAM base, the ~0.96 MB image overlapped it by ~25 KB and
the copy corrupted the first 25 KB of the copied kernel including `_start` → wild
execution at handoff. This was the cold-boot flakiness / `ed`-warm-up mystery, and very
likely the real-A3000 first-boot guru. Our copyit.s now: overlap-safe directions, exact
size, and a **checksum verify** (loader pre-sums the image into `ci_cksum`; copyit
re-sums the copied destination and flashes color0 white/red forever on mismatch instead
of jumping into a corrupt kernel). The buffer is also allocated `MEMF_REVERSE` (top of
RAM) so overlap cannot arise in the first place.

**Handoff state to the kernel:** supervisor mode, interrupts masked (`sr=0x2700`),
MMU **off**, `d0 = 3 (EXEC1)`, `d1 = bootinfo *`.

---

## Stage 1 — Kernel side

### 1a. `_start` (vaddr `0x00000000`, in `ml/syms.s`/`vec.s` region)
```asm
   0: movew #0x2700,sr           | ints off
   4: movec %vbr,%d2
   8: movel %d2, bugvbr          | save AmigaOS VBR
   e: movel #M68Kvec,%d2
  14: movec %d2,%vbr             | install kernel vector table (vec.s)
  18: lea   pstack,%sp           | kernel boot stack
  20: movel %d1,%sp@-            | push bootinfo *
  22: movel %d0,%sp@-            | push boot method (3)
  24: jsr   config               | --> 1b  config(method, bootinfo)
  2a: jsr   pstart               | --> 1c  pstart()  [enables MMU]
  30: movel %d0, ublksde         | store u-block sd entry
⚠️030 38: pflusha                | flush ATC (68030 PFLUSHA encoding f000 2400)
  3c: moveal #0x1fc0,%sp         | reset stack
  44: jsr   main                 | --> SVR4 main(); never returns
```

### 1b. `config` (vaddr `0x18f5c`, source = `sys/amiga/kernel/support.c`)
Confirmed by the `*(uchar*)0xde0002 |= 0x80` store at `0x18f76` (“A3000
Bletcherosity”). Does, in C:
* `boot_arg0 = method; boot_arg1 = bootinfo`;
* `case EXEC1:` `bcopy(bootinfo, &bootinfo_global, …)`;
* size chip RAM, build `MAINSTORE`/`VSIZOFMEM` from `bootinfo.memory[]`
  (the 32 MB the turbo card reports lands here — see boot screenshot:
  `Total Unix memory = 33554384`);
* `figuredisplaytype()`.
**CPU-agnostic C** — no 030 changes needed here, but this is where a CPU/AttnFlags
probe would be added for milestone task 1.

### 1c. `pstart` (vaddr `0x0d44`, 724 bytes, source = `pstart.c`) — **MMU ENABLE**
Builds the MMU root-pointer descriptors and turns the MMU on:
```asm
  ...  (crash-sync / crash-dump bookkeeping)
  d86: build cpuroot[0]   movew #0x7fff,cpuroot ; bfclr/bfins ...   | root descriptor
  da8: clrl  cpuroot+4
  dae: movel cpuroot, userroot ; movel cpuroot+4, userroot+4        | user = cpu root
  dc2: movel #end,%d0
⚠️030 dc8: addil #2047,%d0 ; lsrl #11   | round end up to 2 KB page  (PAGE SIZE = 2 KB)
  ...  (allocate u-area / kuptr / ublksde, build segment descriptors via bfins)
  fcc: lea   cpuroot,%a0
⚠️030 fd6: pmove %a0@,%srp             | load supervisor root pointer (68030 PMOVE)
⚠️030 fda: pflusha                     | flush ATC                    (68030 PFLUSHA)
⚠️030 fde: pmove tc_on,%tc             | TC = 0x82B02D60 -> MMU ON, 2 KB pages, TI 2/13/6/11
  fe6: jsr   vstart                    | VM start
  fee: jsr   mlsetup                   | --> 1d  machine-level setup (CACR)
 1002: jsr   svirtophys                | virtual->physical helper
 1016: rts                             | back to _start (MMU now on)
```
`tc_on = 0x82B02D60` (from `ttrap.s`): `E=1, PageSize=2 KB, TI = 2/13/6/11`.
**⚠️ The whole block is the core 040/060 rewrite:** new root-pointer + page-table
descriptor format, `pmove %srp`→`movec URP/SRP`, `pmove %tc`→`movec TC` with the
040/060 TC layout and a **4 KB or 8 KB** page size (2 KB is impossible on 040/060),
`pflusha` re-encoded. The `addil #2047 / lsrl #11` page rounding (here and at ~176
other sites) changes with the page size.

### 1d. `mlsetup` (vaddr `0x48ac8`, 218 bytes) — machine-level setup
Page-rounds the u-area and kernel limits with the same `addil #2047 / lsrl #11`
(2 KB) idiom, sets up `proc[0]`, and is near where `cacr`/`sup_cacr` (the per-vector
cache-mode values used by `ttrap.s`) are established. **⚠️ CACR format is 030-specific.**

---

## The complete chain, one line

```
unix_boot.c main → supervisor() → copyit.s [⚠️MMU off via 030 pmove] → jmp
  → _start [VBR, stack] → config() [bootinfo, sizes 32 MB] → pstart() [⚠️MMU ON,
    2 KB pages, 030 pmove/pflusha] → vstart/mlsetup [⚠️CACR] → main() → multiuser
```

## Minimal 040/060 boot bring-up checklist (in execution order)

1. **`copyit.s` MMU-disable** → `movec`-based, AttnFlags-guarded. *First thing that
   crashes; fix first.* (Source available in `unix_boot/src` — easy to build/test.)
2. **`_start` `pflusha`** → 040/060 encoding.
3. **`pstart` MMU-enable** → 040/060 root pointer + page-table format, `movec TC/SRP`,
   **4 KB/8 KB page size**, re-encoded `pflusha`. *Hardest single step.*
4. **`mlsetup` / `ttrap.s` CACR** → 040/060 cache enable (`CINV`/`CPUSH` model).
5. Only then does `main()` run; first goal is reaching the idle loop, FPU disabled.

---

## Why `unix_boot` matters for this project

* **Fast iteration.** It boots a modified `unix` kernel straight from AmigaDOS — no
  reboot, no boot menu, no partition selection. For 040/060 bring-up (many
  boot-crash-fix cycles) this turns a multi-minute reboot loop into seconds. Copy a
  freshly linked `unix` to an AmigaDOS volume and run `unix_boot unix`.
* **Its `copyit.s` is the very first code to fix, and it is *source*.** The kernel’s
  own `boot2.c`/`servant.s` MMU-disable is harder to iterate on; `unix_boot/src` is
  self-contained, MIT-syntax, GCC-buildable, and editable today. The 040/060
  MMU-disable can be prototyped here in isolation.
* **It builds with modern tooling.** MIT-syntax `.s` + GCC C → buildable with
  `m68k-linux-gnu-gcc`/`as` (adjust for AmigaOS libs / vbcc as needed). It only needs
  the AT&T `sys/elf.h`, `sys/elf_68K.h`, `sys/elftypes.h` copied in from the AMIX
  partition (per `src/README.BEFORE.BUILD!`).
* **It already shows the AttnFlags pattern** (`btst #2, AttnFlags` = AFB_68030) we’ll
  reuse to branch MMU code per CPU class.
* **Caveat:** it binds the kernel into fast RAM and refuses chip RAM; with the turbo
  card’s 32 MB this is fine. It assumes text+data contiguous (true for the shipped
  `unix`).

### AttnFlags CPU bits (exec/execbase.h), for the per-CPU guards
```
AFB_68010=0  AFB_68020=1  AFB_68030=2  AFB_68040=3
AFB_68881=4  AFB_68882=5  AFB_FPU40=6  AFB_68060=7
```
