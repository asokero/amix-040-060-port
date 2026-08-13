# Phase 060-F0 — measurement boot on real 68060 hardware, 2026-08-05

Machine: A3000 + Mercury 68060 @ 66 MHz, `solon` (10.0.10.10).
Kernel: `build/unix-040`, build id **`68040-260802-01`**, textsize `0xe4868` — the fully accepted
ISSUE-40 base, unchanged. No new kernel code was written this session, by design.

Counter addresses were recomputed from `nm` for this image and matched the campaign plan exactly
(`cputype 0x080FCE58`, `fpu_present 0x080E9844`, `i39_magic 0x080FD27C`, `i40_magic 0x080FD2B4`,
`ptd_magic 0x080FD2E8`). All three magic words read back correct on hardware before any number
below was believed.

---

## 0. Boot precondition found the hard way: SetPatch must run first

The first boot of `68040-260802-01` on the 060 **panicked**, and the banner said `68040-260802-01`,
not `68060-`. The user then found the cause: **if AmigaOS has not run `SetPatch` before
`unix_boot` is started, AmigaOS itself does not know a 68060 is installed.** `SysBase->AttnFlags`
has no `AFB_68060` bit, so the loader pokes `cputype = 40` and the kernel runs its 040 paths on an
060. With SetPatch first, the same kernel boots to a login.

The panic is worth keeping, because it is the **first hardware proof that a real 68060 traps
PTEST** — something Amiberry never demonstrated:

```text
PANIC: KERNEL FAULT psw=0x2100, pc=0x80D9946, fmt=0x0, vector=0xB (Line-F Emulator)
  ...
  WARNING: DBG krnxflt FAILEXIT w=2 va=FFFFFFFA rw=1 depth=1
DOUBLE PANIC: KERNEL FAULT psw=0x2418, pc=0x8059640, fmt=0x4, vector=0x2 (Bus Error)
```

`0x080D9946` is `ptest+0x1e` in `src/ptest040.s`:

```text
000d9928 <ptest>:
   d9928:  2039 ...        movel cputype,%d0
   d992e:  0c80 0000 003c  cmpil #60,%d0
   d9934:  6700 003a       beqw  d9970 <Lpt_060>     <- not taken: cputype was 40
   ...
   d9946:  f568            ptestr %a0@                <- vector 11 on the 060
```

So the `cputype`-gated software URP walk (060-B, 2026-07-10) is not theoretical: without it the
kernel dies on the first user fault. Note also the second frame: `fmt=0x4` — the 060 *did* generate
a format-4 access-error frame, and the 040-shaped decode read `va=FFFFFFFA` out of it, exactly as
the format dispatch predicts when `cputype` is wrong.

**Rule for every 060 boot from here on: SetPatch, then `unix_boot`.**

---

## 1–2. Identity and FPU — both clean

| check | result |
|---|---|
| banner / `uname -m` | `UNIX_System_V solon 4.0 2.1c 0800430 Amiga (Unlimited) **68060-260802-01** m68k` |
| `cputype` @ `0x080FCE58` | `0000003c` = **60** |
| `buildid` @ `0x080FCE44` | `" 68060-260802-01"` |
| `fpu_present` @ `0x080E9844` | **1** — a full 68060, **not** an LC060 |
| `i39_magic` / `i40_magic` / `ptd_magic` | `49333921` / `49343021` / `50544421` — all correct |
| `i40_on` / `ptd_on` | 1 / 1 — both ISSUE-40 halves active |
| `hat_cm_ram` | `00000020` |
| `hat_pfnmiss_n` / `hat_badaslot_n` after boot | 10 / 8 |

`fpu_present = 1` settles item F of the campaign plan's open list for free: the FPU is there, so
vector 11 coverage matters in full.

---

## 3. The gate measurement: native `mul64test` — prediction **REFUTED**

The plan pre-registered (§2): *"If the guest's `cc` does not emit the 64-bit form, then the entire
test battery is usable on the 060 today."* Hardware says the opposite, and then says something
better.

### 3a. The guest's `cc` is gcc, and gcc's own binaries are the casualty

```text
$ cc -o mul64test mul64test.c
gcc: Internal compiler error: program cpp got fatal signal 9
```

Deterministic across three runs. `/usr/bin/cc` is a 243-byte `sh` wrapper around **gcc 2.7.2.3**.
The console named the mechanism outright — this is the measurement, not an inference:

```text
u_trap WARNING: SIGKILL sent to pid 263 (/usr/local/lib/gcc-lib/m68k-cbm-sysv4/2.7.2.3/cpp
  -lang-c -undef -D__GNUC__=2 -) because of vector 0xF4, pc=0x80006ED6
```

`0xF4 / 4 = 61` — unimplemented integer instruction. And `0x80006ED6` disassembles to:

```text
80006ed6:  4c3c 1c00 8421   mulsl #-2078209981,%d0,%d1
```

ext word `0x1c00`, **bit 10 = 1 = 64-bit product** — the form the 68060 does not implement. This is
ISSUE-34a, now proven on a **native** binary rather than a cross-compiled repro, with the faulting
PC matching the disassembly to the byte.

### 3b. How wide is the damage? Narrow, and that is the useful part

Encoding-based scan (`scan060.py`, kept in the session scratchpad and on the NAS):

| binary | vector-61 instructions |
|---|---|
| `cpp` (gcc 2.7.2.3) | **2** |
| `cc1` (gcc 2.7.2.3) | **104** |
| `libc.so.1` | **0** |
| `ld.so.1` | **0** |
| `/usr/ccs/bin/as` | **0** |
| `/usr/ccs/bin/ld` | **0** |

Every hit is `mulsl #<constant>,%dX,%dY` — gcc's magic-multiply for division by a constant. There
is **not one 64-bit divide** anywhere. That is a design input for F2: a targeted emulator needs to
cover the `MULU.L/MULS.L` 64-bit-product form only, and `lmul060.s` already has that arithmetic
validated over 202 500 cases.

It also explains the whole observed behaviour: the machine boots, logs in, runs the shell, telnet
and Dhrystone because **libc and the dynamic linker are clean** — only the compiler is dead.

### 3c. Why the earlier scan said "clean" — an instrument bug, not a hardware change

KNOWN-ISSUES §ISSUE-34 records the guest toolchain as scanning *clean*. The binaries have not
changed since 2005. What changed is the instrument: the 2.8.1-era `objdump` in this tree prints the
64-bit form as

```text
mulsl #-2078209981,%d0,%d1        (comma)
```

not in Motorola's `Dh:Dl` notation. **A grep for `:%d` returns nothing on a file full of them.**
`scan060.py` therefore decides from the encoding (opcode `0x4C00`–`0x4C7F`, extension bit 10), never
from the spelling. My own first grep this session made exactly the old mistake and reported clean.

### 3d. There is a second native compiler, and it works

`/usr/ccs/bin/cc` is the **original AT&T SVR4 driver (1991)**, predating gcc's magic-multiply
optimization. It compiles `mul64test.c` natively on the 060 and the binary runs:

```text
MUL64 before
MUL64 after  q=12345 (expect 12345)
MUL64-RESULT PASS
```

Evidence, not exit status — its codegen for `v / 100L`:

```text
8000055c:  4c7c 0800 0000 0064   divsll #100,%d0,%d0
```

ext word `0x0800`, **bit 10 = 0 = 32-bit dividend**, which the 68060 *does* implement. No magic
multiply at all.

**Consequence:** the battery can be built natively on the 060 today with `CC=/usr/ccs/bin/cc`
(`test-tools/mkall060.sh`), and vector 61 becomes a correctness item for the *gcc* chain rather than
a blocker on measurement — which is the plan's intended outcome, reached by a different route than
the one it predicted.

---

## 4. Second finding: the AT&T chain dies on FP code — SIGSYS, and it is not vector 61

13 of 14 battery programs compiled natively. `fputest.c` did not:

```text
==== /usr/ccs/bin/cc fputest ====
Fatal error in /usr/ccs/lib/acomp
Status 0140
```

`0140` octal = 96 = shell status 140 = **128 + 12 = SIGSYS**. Narrowed with three minimal cases:

| case | content | result |
|---|---|---|
| `fpmin1.c` | `double` add + scale, no `volatile` | compiles |
| `fpmin2.c` | same with `volatile double` | compiles |
| `fpmin3.c` | `double`-returning `nsqrt()`: loop, `x / r`, `<= 0.0` | **acomp dies, SIGSYS** |

SIGSYS is what `nullvect` produces, and the campaign plan §6 pre-registered exactly this shape for
ISSUE-34b: vector 11 reaching `nullvect` because `fpsp_vec11` is gated on `cputype == 40`, so on an
060 the FPSP hook is not installed. The 68060 FPU implements a smaller set than the 040's, and
`acomp` does constant folding in floating point.

**Not yet proven:** the vector number for this one — and the console cannot supply it. The kernel
holds exactly one such message,

```text
u_trap WARNING: SIGKILL sent to pid %d (%s) because of vector 0x%x, pc=0x%x
```

(the only match in the whole image), so it announces **SIGKILL kills only**. `acomp`'s death
printed nothing, which is expected and therefore proves nothing either way about its vector. What
it *does* establish, negatively and usefully: **`acomp` is not dying of vector 61**, because every
vector-61 kill on this machine printed a line. That separates 34b from 34a on hardware for the
first time. `/var/adm/messages` does not exist here, so closing the vector needs the `nullvect`
probe KNOWN-ISSUES already specifies — i.e. kernel code, which this session deliberately did not
write.

### And `cc1` itself: measured, and it is 34a, not 34b

The gcc `cc1` can be reached even with `cpp` dead — preprocess with the AT&T `cpp` and feed the
`.i` straight in:

```text
$ /usr/ccs/lib/cpp mul64test.c > /tmp/mul64test.i          rc=0, 162 lines
$ .../2.7.2.3/cc1 /tmp/mul64test.i -o /tmp/mul64test.s
Killed                                                     rc=137 = 128+9 = SIGKILL
```

Console: `SIGKILL sent to pid 2046 (.../cc1 /tmp/mul64test.i -o /tmp/mul6) because of vector 0xF4,
pc=0x80021530` — and `0x80021530` is in the scan list above as
`mulsl #-2115558717,%d1,%d0`. Second byte-exact match this session.

So on this machine `cc1` dies of **vector 61**, not SIGSYS. The original ISSUE-34b observation
(cc1 = SIGSYS 12) does not reproduce here — consistent with it having been made against the
*vanilla* cc1 (666 440 B, genuinely clean) or in the emulator, not against the installed
1 250 916-byte binary.

`test-tools/fputest060.c` is the cross-compiled substitute: identical test, with `i % 20` replaced
by an explicit counter, because gcc compiles that modulo into precisely two 64-bit `mulsl`
instructions (scanned and confirmed, then confirmed clean after the change).

---

---

## 5. The battery on the 68060 — 10/10, and the calibration instrument holds

Built natively with `/usr/ccs/bin/cc` (13 programs) plus the cross-built `fputest`, then
`batteryrun2.sh` unchanged, addresses and all:

```text
proctest      PASS (10 sub-tests, fails=0)     bigargv       PASS 45 args 4500 bytes
fputest       PASS FP arithmetic correct       ptracepoke    PASS pokes=4 fails=0
mlocktest     PASS fails=0 skipped=0           bmaptest      PASS fails=0
msynctst      MSYNC-OK 65536                   devmaptest    PASS fails=0
mincoretst    PASS                             exectest 20   PASS
```

Against the 68040 acceptance run of 2026-08-02 on the **same kernel image**:

| instrument | 68040 (2026-08-02) | 68060 (2026-08-05) |
|---|---|---|
| battery | 10/10 | **10/10** |
| `hat_pfnmiss_n` across the battery | `0x0a → 0x0c` = **+2** | `0x0a → 0x0c` = **+2** |
| `ptd_calls` vs `ptd_retired_n` | equal | equal (`0x1f39 → 0x2056`, both) |
| `ptd_keep0/keepn/meta/badlink` | 0 / 0 / 0 / 0 | **0 / 0 / 0 / 0** |
| `hat_sdtfail_n` | 0 | 0 |

`hat_pfnmiss_n` moving by exactly +2, from `devmaptest` and nothing else, is the calibration that
has now held across four kernels and two CPUs.

`fputest` PASS is its own small result: the 68060 FPU computes add/sub/mul/div and a 40-iteration
Newton sqrt correctly **with no FPSP installed** (`fpsp_vec11` is gated to `cputype == 40`). What is
missing on the 060 is the *unimplemented*-instruction support, not the basic arithmetic.

Caveat, stated because it is real: these binaries were built by a different compiler than the 040
run's (AT&T `cc` vs gcc). The tests exercise the kernel, not the compiler, but the two binary sets
are not byte-identical, so this is a same-test comparison rather than a same-binary one.

---

## 6. CACR on the 060 — read back, decoded, unchanged

There is no way to read the live CACR from userland, and no dbg image was booted, so this is the
**kernel's CACR globals** — the values `p1int..p6int` and `ttrap` reload into CACR on every
interrupt entry/return, i.e. the value the hardware is continuously being given:

```text
cacr      @ 0x080EBB24 = 80008000     (user-mode value, restored by ttrap)
sup_cacr  @ 0x080EBB28 = 80008000     (supervisor value, restored per interrupt)
```

Decoded against NetBSD's definitions, on the 68060:

| bit | mask | meaning on 060 | state |
|---|---|---|---|
| 31 | `0x80000000` | `DC60_EDC` — data cache enable | **on** |
| 15 | `0x00008000` | `IC60_EIC` — instruction cache enable | **on** |
| 23 | `0x00800000` | `IC60_EBC` — branch cache enable | **off** |
| 22 | `0x00400000` | `IC60_CABC` — clear all branch cache | not used |
| 29 | `0x20000000` | `DC60_ESB` — store buffer enable | **off** |

So the plan's §5 reading is confirmed on hardware: `0x80008000` means the same thing on both CPUs,
and the branch cache and store buffer are two unused knobs. Nothing was changed, as instructed.

**There is a third knob the plan does not list, and it is not in CACR: `PCR` bit 0 (ESS,
superscalar dispatch).** The kernel never reads or writes PCR — verified by disassembly — so its
state is inherited from AmigaOS and currently unmeasured. See §9; it has to be read before any
060-D work, because with ESS=0 the 060 is dispatching one instruction per clock and the cache
knobs are the smaller effect.

The honest limit: this is the value the kernel *writes*, verified in memory, not a `movec %cacr,%d0`
readback. A dbg image already prints the real register (`btrace 'D' + CACR` in `pstart040.s`), so
one dbg boot closes that gap when it matters.

---

## 7. Burst — 96/96 ×4, and the ISSUE-40 flatness is CPU-independent

`burstrepeat2.sh 4` unchanged (it refuses to start unless `ptd_magic` reads `50544421`; it did).
Four consecutive 16-burst suites, no reboot, `memwatch` sampling every 2 s throughout.

| suite | 68060 wall clock | good_sums | 68040 (2026-08-02) |
|---|---|---|---|
| 1 | **13m05s** | 96 | 17m21s |
| 2 | **12m33s** | 96 | 16m32s |
| 3 | **12m24s** | 96 | 16m38s |
| 4 | **12m36s** | 96 | 17m02s |

**Flat within 41 seconds, slowest first** — cold caches, not decay, the same shape the 040 run has.
Data integrity **96/96 in every suite, 4/4**. And ~25 % faster wall-clock on this mixed
fork/exec/copy workload.

Counters at each suite boundary:

```text
            pfnmiss  badaslot  sdtfail | ptd_calls  retired  pgfreed  k0 kN meta bl wake
after 1          12       110        0 |    12881    12881      355   0  0    0  0    0
after 2          12       117        0 |    16140    16140      371   0  0    0  0    0
after 3          12       119        0 |    19116    19116      371   0  0    0  0    0
after 4          12       119        0 |    21904    21904      384   0  0    0  0    0
```

`ptd_calls == ptd_retired_n` at every checkpoint, `ptd_keep0/keepn/meta/badlink` all zero across
21 904 retirements, `hat_sdtfail_n` 0, and `hat_pfnmiss_n` **did not move at all** during the burst
run — 12 throughout, exactly as on the 040. The ISSUE-40 teardown path is CPU-independent in
practice, not just in principle.

`ptd_wake_n = 0` again: the `pt_waiting` branch remains unexercised on this CPU too. Same honest
caveat as the 040 acceptance.

### `availrmem` under an hour of load — same regime as the 040

`memwatch` every 2 s, 1492 samples over 49.7 minutes, ten-minute buckets:

```text
bucket        n     min     max     mean        68040 2026-08-02 mean
 0-10 min   300    6908    7071    6941.8            6953
10-20 min   300    6894    6950    6919.2            6950
20-30 min   300    6894    6943    6913.1            6944
30-40 min   300    6901    6943    6911.8            6944
40-50 min   292    6896    6931    6911.4            6945
```

(The 0–10 bucket includes the `t=0` sample taken before the load started, 7071, which is why its
mean sits high.) Measured between the first 60 samples after the 10-minute mark and the last 60:
**13.8 pages over 39.7 minutes = 0.35 pages/min**, against the 040's ~0.2 pages/min and the
pre-fix **~21 pages/min**.

The bucket means also stop falling: −6.1, −1.3, −0.4 pages between successive buckets. That is a
settling curve, not a leak, and the min/max bands overlap completely from bucket 1 onward
(6894–6950). `sdtfail` 0 and `deficit` 0 throughout, with `freemem` touching 0 — the same
"depletion without failure" pattern the 040 run showed.

Honest reading: 0.35 vs 0.2 pages/min is not identical, and the run was 50 minutes rather than 65,
so I would not claim the two are the same number. The claim that holds is the *regime*: ISSUE-40's
fix carries to the 060 unchanged, and nothing on this CPU reintroduces a linear decline.

### One number that does not match, and I cannot explain it yet

Per-suite `ptd_calls` deltas are **~2 800–3 900 on the 060** against **~14 500 on the 040** for what
is the same script driving the same system utilities on the same kernel image:

```text
040 (2026-08-02):  +14463  +14631  +14532
060 (2026-08-05):   +3259   +2976   +2788      (suite 1 delta 3904 over a different starting point)
```

`good_sums` is 96 either way, so the *work* is the same. `ptd_pgfreed`/`ptd_calls` also differs
(≈0.4 % on the 040, ≈1.8 % on the 060). Recorded as an open observation rather than explained: the
honest next step is to count process creations during one suite on each CPU rather than to reason
about why page tables would empty differently.

---

## 9. Dhrystone — exactly double the 040, which is itself a finding

Same binary as every earlier measurement (`/root/amix-bench/dhry`, found on the machine), three
consecutive runs of 1 000 000 iterations (50 000 is now too few to time on this CPU — it prints
"Measured time too small to obtain meaningful results"):

```text
60423.0 /s      16.5 us/run
60544.9 /s      16.5 us/run
60423.0 /s      16.5 us/run        spread 0.2 %
```

| configuration | Dhrystones/s | source |
|---|---|---|
| 68040 @ 33 MHz, caches off (`68040-260719-13`) | 11 538.5 | `/root/amix-bench/bench-results.solon.txt` |
| 68040 @ 33 MHz, write-through DC | 18 292.7 | KNOWN-ISSUES |
| 68040 @ 33 MHz, copyback | 30 000.0 / 30 037.5 / 29 813.7 | KNOWN-ISSUES, three boots |
| **68060 @ 66 MHz, copyback, `68060-260802-01`** | **60 423 / 60 545 / 60 423** | this session |

**+102 % over the 040 — almost exactly the clock ratio (66/33 = 2.0).**

### What was actually enabled during that measurement

| feature | state | evidence |
|---|---|---|
| instruction cache | **on** | `CACR = 0x80008000`, bit 15 |
| data cache | **on** | `CACR` bit 31 |
| data cache mode | **copyback** | `hat_cm_ram = 0x20` = CM=01, read back live at `0x080FCB68` |
| branch cache (`IC60_EBC`) | **off** | not in the CACR word |
| store buffer (`DC60_ESB`) | **off** | not in the CACR word |
| **superscalar dispatch (PCR bit 0, ESS)** | **UNKNOWN** | see below |

**The kernel contains no PCR access at all** — a disassembly search for `movec` to/from control
register `0x808` finds nothing. So PCR holds whatever AmigaOS left in it, and two things point in
opposite directions:

* `68060-prestudy.md` §3.4 states the intent plainly: *"we leave ESS=0 (reset default) during
  bring-up."* With ESS=0 the 060 issues one instruction per clock, and then **doubling the clock is
  the entire expected result** — there is nothing to explain.
* But SetPatch is now known to be mandatory before `unix_boot` (§0), and SetPatch is exactly what
  loads `68060.library`, which normally enables ESS. Since the kernel never touches PCR, that
  setting would survive into AMIX.

Neither is a measurement, so **the honest statement is that it is not known whether this Dhrystone
ran superscalar or scalar**, and no performance conclusion — including any claim about the branch
cache — can be drawn from the 2.0× ratio until PCR is read.

**Cheapest way to close it:** a `cputype == 60`-gated three-instruction unit in the boot path that
does `movec %pcr,%d0` into a new global, readable with `/kpeek` (PCR is 060-only and traps as
illegal on the 040, hence the gate). That is F5's `cpuinfo`/PCR item, and it should now come
*before* any 060-D cache work, because it changes what 060-D is even trying to fix.

---

## 8. What this changes in the campaign

The plan made two named predictions and asked for both to be measured. Both were answered, and
neither the way it expected:

| §  | prediction | outcome |
|---|---|---|
| §2 | the guest's native `cc` is 060-safe, so the battery is usable today | **refuted** for gcc — its `cpp` dies of vector 61 — but the *conclusion* survives via a second, older native compiler |
| §6 | ISSUE-34b is vector 11, and it is `cc1`'s SIGSYS | **half refuted, half sharpened**: on this hardware `cc1` dies of **vector 61 / SIGKILL** (`pc=0x80021530`, console-confirmed), not SIGSYS — so the original 34b observation does not reproduce here. But SIGSYS is real and now has a smaller home: AT&T `acomp` on FP code |

Consequences for the sequence:

* **F2 (vector 61 / ISP) is no longer a blocker on measurement.** `/usr/ccs/bin/cc` builds the
  battery natively. F2 stays necessary — the gcc toolchain, and any gcc-built userland, is dead
  without it — but F1 can run first as the plan intended.
* **F2's scope is now measured, not estimated.** Every vector-61 instruction in the whole scanned
  userland is a 64-bit `MULS.L`/`MULU.L` product. Zero 64-bit divides, no CMP2/CHK2/CAS2. A
  targeted emulator covering one instruction form would revive gcc, and `lmul060.s` already holds
  the validated arithmetic.
* **F3 (vector 11 / 060 FPSP) has a two-second repro** that needs no kernel change to reproduce:
  `/usr/ccs/bin/cc -o fpmin3 fpmin3.c` on the 060. That is a better starting point than `cc1`,
  which cannot even be reached now that `cpp` dies first.
* **F5 (`cpuinfo`) partly answered for free:** `fpu_present = 1`, so this is a full 68060.
* **F5's PCR read is promoted ahead of 060-D.** The kernel has no PCR access, so superscalar
  dispatch (ESS) is inherited from AmigaOS and unmeasured — and until it is read, no performance
  number on this machine can be attributed to anything. Three instructions behind a `cputype == 60`
  gate, plus one `/kpeek`.

## Artifacts

```text
kernel     build/unix-040   68040-260802-01  textsize 0xe4868   (banner 68060-260802-01 on the 060)
new tools  test-tools/scan060.py      encoding-based 060-unimplemented-instruction scanner
           test-tools/mkall060.sh     battery build with CC=/usr/ccs/bin/cc
           test-tools/fputest060.c    fputest without the magic-multiply modulo
           test-tools/fpmin{1,2,3}.c  acomp SIGSYS narrowing (3 = the failing shape)
logs       NAS amix/hwtest-260802b/060-F0-260805/{battery2-060,burstrepeat2-060,memwatch-060,
                                                  scan1,scan2}.txt + this file
machine    /tmp holds the natively built battery; it will be gone after the next boot.
           Sources are on the NAS; /kpeek and /pgc survive in the root.
```

Not done this session, and why:

* **060 fault-path counters** (`x60_fmt4_n` etc.) — that is F1 and it is kernel code; this session
  was explicitly measurement-only. Without them the XPAGE acceptance still cannot be taken: the
  panic in §0 proves format-4 frames *occur*, not that the MA tier is *exercised*.
* **The RTG twin** (`68040-260802-04`) was not booted — one variable at a time, and the base image
  filled the session.
* **`acomp`'s vector number** — needs the `nullvect` probe, i.e. kernel code again.
* Scanning the natively built battery binaries was attempted but the NFS copy of 13 binaries timed
  out; the compiler evidence (`/usr/ccs/bin/cc` emits `divsll`, bit10 = 0) plus 10/10 passes and a
  console with no vector-61 line for any of them covers the same ground.

## Instrument notes

* Detached runs: `(nohup sh /tmp/x.sh > /tmp/x.log 2>&1 &)` created an **empty** log and ran
  nothing on this machine today; `(nohup sh -c "sh /tmp/x.sh > /tmp/x.log 2>&1" &)` works. AMIX's
  `nohup` prints "Sending output to nohup.out" and appears to take the redirection itself.
* `grep -E` does not exist on AMIX (`illegal option -- E`), on top of the known `grep -q` gap.
* The host's Debian cross binutils (`m68k-linux-gnu-*`) are gone after the Trixie upgrade, as
  LOCAL-BUILD-NOTES §1 warned. Use `/home/asokero/opt/amix-cross/bin/m68k-cbm-sysv4-*`.
* The cross sysroot's `usr/lib/libc.so.1` was a dangling symlink into the unmounted vanilla image.
  Replaced this session with a copy taken from the live machine; the original symlink is recorded
  in the scratchpad as `sysroot-libc-symlink.orig` and kept as
  `usr/lib/libc.so.1.vanilla-symlink`.

---

## CORRECTION (2026-08-13): §9's clock figure was wrong, and the conclusion changes

**The Mercury's 68040 runs at 35 MHz, not 33.** Its oscillator is 70 MHz and the 68040 runs at
half clock; the 68060 runs from a 66 MHz oscillator at **full** clock. Established by the person
who fits the oscillators, which outranks every document here that said 33 — including §9's table.

Recomputed:

```
  clock ratio     66/35 = 1.886      (not 2.000)
  measured ratio  60 463.6 / 29 950.4 = 2.019
  surplus         +7.1 % beyond clock scaling
```

§9's headline — *"+102 % over the 040 — almost exactly the clock ratio"* — is therefore **wrong**,
and so is the argument built on it: that with ESS=0 the doubling was fully explained and there was
nothing left to account for. There is a 7.1 % surplus, and the ESS question was settled separately
in the other direction: `REALHW-260806-06-ACCEPTANCE.md` measured `pcr_boot = 0x04300601`, **ESS=1**.

So the corrected statement is the opposite of the original one in an interesting way:

> A **superscalar** 68060 was only **7.1 % faster per clock** than the 68040 on Dhrystone.

That is a *low* number for superscalar dispatch, and this same document already records where the
missing performance most plausibly is — the two knobs it found switched off:

| CACR bit | | state at that measurement |
|---|---|---|
| 23 | `IC60_EBC` branch cache | off |
| 29 | `DC60_ESB` store buffer | off |

The question therefore moves from "why is it exactly the clock ratio" (which it never was) to
"how much of the missing per-clock performance do the branch cache and store buffer account for" —
which is a measurable A/B on two bits, and the campaign's existing F4-060-D item.

Source of the corrected 040 number: `REALHW-A3640-260813-ACCEPTANCE.md` §9, where the same
correction also removed a 6.5 % "memory penalty" for the A3640 that turned out to be the 33 MHz
artifact rather than a measurement.
