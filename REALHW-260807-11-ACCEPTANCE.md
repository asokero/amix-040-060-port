# Real-hardware acceptance: `68060-260807-11` — F3 M5, the 68060 FPSP on silicon

**Machine:** Amiga 3000, 68060 @ 66 MHz, AMIX SVR4 2.1c, `solon` / 10.0.10.10
**Date:** 2026-08-09
**Image:** `build/unix-040`, textsize `0xf2508`, booted with `unix_boot040` after SetPatch
**Previous hardware baseline:** `68060-260806-06` (`REALHW-260806-06-ACCEPTANCE.md`)

`260807-11` is the M2b image: `FPSP060` defaults to 1, so `sh relink-040.sh` produces it. It
differs from the emulator-accepted `-09` in exactly two bytes, both build-id digits
(`test-tools/f3-m2b-emu-verify-260808.txt`).

**Headline: the 68060 does floating point on real silicon, and it is bit-exact.** Every value
`fp060probe` returns on hardware is identical to the emulator's, and Motorola's own
unimplemented-instruction suite — which could not be made to pass under Amiberry — passes here.

## 0. Which image, and why we believe it is that image

The package variant could not be taken on faith: the D2 control experiment (M2b §5) built the
*partial* `pfpsp` package into a kernel of the same name. Checked before boot, on the file:

| Check | Value |
|---|---|
| build id | `68040-260807-11` (banner reads `68060-` = the running CPU, not the image) |
| sha256 | `4962361b612a3c8e75bdbcfb7cc38eb9091e16ad5d0d11a8b69d2e45e6ee8ebe` |
| textsize | `0xf2508` = base `0xe4c24` + **55 524** bytes of package |
| variant | **full `fpsp.sa`** — `pfpsp` is 29 108 bytes and cannot account for the delta |
| `build/.emu-image` | records this same sha256 → this file is what the emulator last booted |

Counter addresses were recomputed from `nm` for this image (`0x08000000 + textsize + nm(.data)`)
and independently reproduced `test-tools/f3-m2b-emu-verify-260808.txt`'s table to the byte, so
`batteryrun6.sh`'s anchors apply verbatim.

## 1. Identity

| Item | Value | Expected |
|---|---|---|
| `uname -m` | `Amiga (Unlimited) 68060-260807-11` | ✅ |
| `f60_magic` @`0810B164` | `46503630` ("FP60") | ✅ read before anything else was believed |
| `segvn_prot_magic` @`0810AAE4` | `53564e21` | ✅ as `-06` |
| `cputype` @`0810AB48` | `0000003c` (60) | ✅ |
| `pcr_boot` @`0810AB4C` | `04300601` (ESS=1) | ✅ as `-06` |
| `isp61_magic` @`0810AB50` | `49363121` | ✅ |
| `hat_cm_ram` @`0810A808` | `0x20` (copyback) | ✅ |
| all 15 `f60_*` counters | `0` | ✅ clean baseline |

The machine boots to multiuser with 54 KiB of extra kernel text. That is itself the first
hardware fact of F3.

## 2. `fp060probe` — pre-registered, and it came out exactly

Expectation registered before the run (`NEXT-SESSION-PROMPT-260809.md` item 2): 7/7 `OK`, `0 ulp`,
`bad=0`, counters `entry 4 / mem 4 / done 4`, `real 0`, `access 0`, `memfail 0`, `kvp_vec[11]`
unmoved.

```
fadd       OK  3FF0000000000000  (0 ulp)
fsqrt      OK  3FE6A09E667F3BCD  (0 ulp)
fintrz     OK  0000000000000000  (0 ulp)
fsin       OK  3FDEAEE8744B05F0  (0 ulp)
fetox      OK  3FFA61298E1E069C  (0 ulp)
flogn      OK  BFE62E42FEFA39EF  (0 ulp)
fmovecr    OK  400921FB54442D18  (0 ulp)     <- pi, exact
FP060PROBE bad=0
```

**All seven bit patterns are identical to the emulator's M2b run.** Survival is not correctness,
so the comparison is against the IEEE-754 pattern, through a pipe, with an FP-free parent.

| Counter | before | after | pre-registered |
|---|---|---|---|
| `f60_entry_n` | 0 | **4** | 4 ✅ |
| `f60_mem_n` | 0 | **4** | 4 ✅ |
| `f60_done_n` | 0 | **4** | 4 ✅ |
| `f60_real_n` | 0 | **0** | 0 ✅ |
| `f60_access_n` | 0 | **0** | 0 ✅ |
| `f60_memfail_n` | 0 | **0** | 0 ✅ |
| `f60_last_co` | 0 | **12** = `_060_fpsp_done` | ✅ |
| `kvp_vec[11]` @`0810ABCC` | 0 | **0** | unmoved ✅ |

## 3. `fputest060` — FP context switching under fork

`Test A PASS`; `Test C` (`fputest060 fork`): CHILD `1.5^12*1000 = 129746`, PARENT
`1.25^-12*100000 = 6871`, `RCC=0`. Counters 4 → 6 on entry/mem/done, `real` still 0.

**Instrument note.** Run without the `fork` argument first: Test A passed, `RCC=0`, and **no
counter moved** — Test C had not run at all. The counters caught it, exactly as the `-O`
lesson did in M2b. The binary was disassembled before running and carries `fmovecrx #50,%fp0`
at `+0x57a`, the same shape as the emulator-measured binary.

## 4. Motorola's `ftest060` — the session's decisive new measurement

The emulator could never render a verdict here: its FPU cannot hold `DEF_FPREGS`' extended NaN,
which every sub-test loads before it begins. So `ftunimp0` ran first, as the gate:

```
FTUNIMP0 bad=0 nanbad=0
```

**`nanbad=0` — real silicon holds the value the emulated FPU mangled.** All seven compared
fields correct (fp0 all 96 bits, FPCR, FPSR `08000208`, FPIAR = the `fsin`'s own address, CCR).
`ftest060` therefore measures the FPSP from here on, and only from here on.

### 4a. `unimp` — **passed**

```
Testing 68060 FPSP unimplemented instruction started:
	Unimplemented FP instructions...passed
FTEST060 died=0
```

Counters across it: entry 6 → **15**, mem 6 → **21**, done 6 → **15**, `real 0`, `last_co 12`.
`mem` outrunning `entry` is expected — one entry can fetch several operand words.

Motorola's own suite accepts our FPSP. This is what M2b could not obtain.

### 4b. `main` — vector 60, expected, and now named

```
Testing 68060 FPSP started:
	Unimplemented <ea>...  DIED by signal 9
```

Two independent instruments agree, which is why this is attribution and not inference:

* **Counters did not move at all** — the package was never entered.
* **Console:** `u_trap WARNING: SIGKILL sent to pid 311 (/tmp/ftest060 main ) because of
  vector 0xF0, pc=0x80000CAC`. The kernel prints the vector *offset*: the known vector-61 case
  prints `0xF4` (= 61 × 4), so `0xF0` = 240 = **60 × 4 = vector 60**, unimplemented effective
  address — `_060_fpsp_effadd`, which M3 deliberately does not hook.

The faulting instruction, disassembled from `build/ftest060` at that PC:

```
80000cac:	f23c 4823 c000 0000 8000 0000 0000 0000 	fmulx #-2.0,%fp0
```

An extended-precision **immediate** operand. That is M3's first test case, handed to us for free.

### 4c. `enabled` — the six exits that had never been measured, and what they actually did

```
Testing 68060 FPSP exception enabled started:
	Enabled SNAN...  DIED by signal 8       (SIGFPE)
```

**No `f60_*` counter moved** — `entry` stayed `0x0f`, `arith` stayed `0`. So:

* On hardware the enabled FP exceptions **do** fire. Under Amiberry they never did, which is why
  these exits were unmeasured rather than passing.
* They do **not** reach the 060 package. They go to the IEEE vectors 48–54, which are not routed
  to it on the 060 — **this is exactly M4, and it is now measured rather than assumed.**
* Nothing here implicates M2b's call-outs: `Lco_fparith`'s prelude and the `_060_real_*` exits
  still have not run.

**Open, and not resolved by this session:** whether the correct end state is "SIGFPE delivered to
the process" or "FPSP fixes up and returns" depends on M4's design *and* on whether the
`ftest060` harness installs signal handlers of its own. The measurement above stands regardless;
the interpretation of "should it have died" does not, and is M4's to settle.

## 5. Battery — 11/11 on hardware

Sources compiled in the guest by `/usr/ccs/bin/cc` (`mkall6.sh`): **12/12 built, 0 errors**.
`batteryrun6.sh` verified `segvn_prot_magic` and `f60_magic` before running anything.

**31 PASS, 0 FAIL.** All eleven results, identical to both emulator CPUs:

```
PROCTEST-RESULT PASS          MSYNC-OK path=/msync_test.dat sz=65536
FPUTEST Test A PASS           MINCORE PASS
MLOCKTEST-RESULT PASS         BIGARGV PASS 45 args 4500 bytes
PTRACEPOKE-RESULT PASS        BMAPTEST-RESULT PASS
DEVMAPTEST-RESULT PASS        EXECTEST-RESULT PASS (data+bss verified across every generation)
MUL64-RESULT PASS             PROTFAULT-RESULT PASS  (a and b)
```

f60 across the battery: entry 15 → **17**, mem 21 → **23**, done 15 → **17** (the battery's own
`fputest` Test A), and `real` / `access` / `memfail` / `arith` / `bsun` / `fline` / `trap` /
`trace` / `fpudis` / `superdone` **all still 0**.

Across the entire session `entry` equals `done` at every reading and `last_co` is always 12: every
single entry into the package completed normally through `ureturn`. Not one exception exit of any
class has been taken on this machine.

## 6. Burst — 96/96

`burstloop.sh 4` = 4 rounds × 4 bursts × (6 concurrent 4 MiB copies of `/payload.bin` +
`hat_dup_cow 64`). 384 MiB written under concurrent fork/COW pressure.

```
good sums   96 / 96      every `sum` line is `1570 8192`
sum lines   96           none missing, none short
```

Anomalies re-checked **one pattern per grep**, because `burstloop.sh`'s own anomaly line uses
`\|` alternation and is inert on AMIX (it prints nothing whatever happens — a silent pass):

| pattern | hits |
|---|---|
| `bad address` | 0 |
| `read error` | 0 |
| `bus error` | 0 |
| `cannot` | 0 |

Matches `-06`'s `96/96`. f60 counters **unchanged** across the whole burst (17 / 23 / 17) — the
expected negative control: 384 MiB of I/O touches no floating point, and the package stayed out
of it.

## 7. Power-cut disk truth — 6/6

The stronger variant, repeated from `-06` on this image.

* write phase on `68060-260807-11`: 6 × 4 MiB to `/b2dt`, `sync` / `sleep 2` / `sync`, plus a
  second `sync; sync` and a wait for the disk to go quiet
* **power physically cut** — not `init 6`, not `haltsys`
* fsck ran on the next boot, as it always does after a violent shutdown on this machine; this
  is the established procedure and was the same for `-06`
* rebooted on the **same** kernel (SetPatch, then `unix_boot040`)

```
B2RT wrote-by: uptime=  5:59pm  up 39 mins   kernel=Amiga (Unlimited) 68060-260807-11
B2RT now:      uptime=  6:04pm  up 1 min     kernel=Amiga (Unlimited) 68060-260807-11
B2RT preconditions OK: same kernel, and uptime shows a real reboot

b2rt-f1 .. b2rt-f6   CLASS=V0_COMPLETE_MATCH   size=4194304   crc=50250
B2RT-RESULT PASS (6 files, every byte intact)
```

**6/6 `V0_COMPLETE_MATCH`**, identical to `-06`. Unlike `-06` the harness proved its own
preconditions this time instead of needing them checked by hand (see below).

**fsck rescued nothing.** The newest entry in `/lost+found` is dated May 15; the write was
May 19 17:59. The power cut orphaned no inode, so the six files were on the disk rather than
reconstructed — which is what makes this a statement about the copyback flush chain and not
about fsck.

### Instrument repaired: the uptime guard now works above one hour

`-06` recorded, as defect 1, that `b2reboot-truth.sh`'s reboot guard reads the writer's uptime
with `up \([0-9]*\) min` and therefore goes blind once a machine has been up an hour — `uptime`
switches to `up  1:15` and `WROTE_MIN` comes out empty, so the `-n` test skips the guard. It
**fails open**, the opposite of what its own comment promises.

This run was started at 39 minutes uptime, deliberately inside the window where the original
guard is known-good, rather than editing an instrument in the middle of a measurement. The fix
was made afterwards, between reboots:

* `up_minutes()` now understands `up 39 mins`, `up  1:15` and `up 2 days,  3:45`
* the H:MM pattern is anchored **after `up`**, because the leading clock (`  6:04pm`) is also
  H:MM and matching it would compare wall-clock times and call every run a reboot
* the same anchoring makes it skip the decoy `up` inside `uptime=` on the EXPECT line
* if a format is genuinely unrecognised it now says so out loud instead of skipping in silence

Verified against all six shapes (including the two that broke the original) before landing.

## 8. Attribution: wolf3d and xv

Deferred to the RTG kernel — wolf3d and xv can only be exercised there.

**The RTG image on disk was stale and would have measured the wrong kernel.**
`build/unix-040-rtg` (2026-08-07 00:37) predates the M2b base (12:55 the same day) and carries
**zero** `f60_*` symbols. Running wolf3d under it would have shown the FPSP not helping, and the
conclusion would have been backwards.

Rebuilt from this session's base — `relink-040-rtg.sh` takes the base as input and inherits FPSP
from the base link, so the 060 package comes along automatically:

```
build/unix-040-rtg-f3    build id 68040-260809-01    textsize 0xfb534
reloc validation: TOTAL complaints: 0
19 f60_*/fpsp060 symbols present
parinit @0xfe6c — asserted unmoved despite the 54 KiB package
boot: unix_boot040 unix-040-rtg-f3  +  mknod /dev/svga c 67 0 / /dev/va2000 c 68 0
```

**Its counter addresses differ** — the RTG `.text` is 36 KiB larger, so `-11`'s addresses would
silently read unrelated memory:

| symbol | `unix-040` (`-11`) | `unix-040-rtg-f3` |
|---|---|---|
| `f60_magic` | `0810B164` | `08114190` |
| `f60_entry_n` | `0810B168` | `08114194` |
| `f60_real_n` | `0810B170` | `0811419C` |
| `kvp_vec[11]` | `0810ABCC` | `08113BF8` |
| `cputype` | `0810AB48` | `08113B74` |

`batteryrun6.sh`'s anchors do not apply to it either; the script's `f60_magic` guard catches
that and aborts rather than reporting nonsense.

### Pre-registered, before the run — so the answer cannot be fitted afterwards

This is the question F3 opened at M0 (`amix-060-fpu-no-fpsp`): wolf3d and xv died of SIGSYS on the
060, which was *compatible* with the missing FPSP but never demonstrated. `fp060probe` has since
shown that unimplemented FP instructions were indeed reaching `nullvect`. The remaining step is to
show it was **their** SIGSYS.

Read `f60_magic` @`08114190` = `46503630` first, then, for each program:

| Outcome | Reading |
|---|---|
| runs, and `f60_entry_n` moved | **attribution confirmed** — the SIGSYS was the missing FPSP |
| runs, `f60_entry_n` = 0 | it never needed the package; the old SIGSYS had another cause, still open |
| still SIGSYS, `kvp_vec[11]` moved | an FP instruction reached `nullvect` — a *gap in the package's coverage*, i.e. M3/M4 territory, and the vector number on the console names which |
| still SIGSYS, `kvp_vec[11]` = 0 | not an FP fault at all — the M0 hypothesis was wrong and something else kills them |
| dies by signal 9, console `vector 0xF0` | vector 60 = M3, the same gap `ftest060 main` found |

The third and fourth rows are the ones worth the trip: either would move the cause somewhere this
campaign has not looked, and both are distinguishable in a single run.

## Status after this run

* **`68060-260807-11` is the hardware baseline**, replacing `68060-260806-06`. Everything `-06`
  was accepted on has been re-run and matched: battery 11/11, burst 96/96, power-cut 6/6.
* **F3 M5 is done for the base kernel.** The 68060 executes floating point correctly on real
  silicon and Motorola's own unimplemented-instruction suite passes.
* **`FPSP060=1` is justified as the default by hardware**, not only by the emulator.
* The 040 path is untouched by construction and was proven inert by counter on the emulated 040 in
  M2b; nothing in this session touched it.
* **Open, and now measured rather than assumed:**
  * **M3** — vectors 55 and 60. First test case in hand: `fmul.x #-2.0,%fp0` at `ftest060`'s
    `Unimplemented <ea>`.
  * **M4** — IEEE vectors 48–54. `ftest060 enabled` shows they fire on hardware and bypass the
    package entirely; `f60_arith_n` has still never moved.
  * **Attribution (§8)** — wolf3d and xv, deferred to `unix-040-rtg-f3`.
  * `_060_real_fpu_disabled` remains implemented but unexercised: `f60_fpudis_n` is 0 here too. If
    it ever moves, something is turning the FPU off behind our back and that is to be investigated,
    not tolerated.
* Out of scope and unchanged: **ISSUE-42** and the **68040 session** (`NEXT-040-SESSION-RUNLIST.md`,
  needs the A3640 card swap).

## Working notes earned this session

1. **The SVR4 cross-assembler cannot build `ftunimp0_asm.s`.** `m68k-cbm-sysv4-gcc` rejects
   `moveq #0,%d0`, `movew #0,%ccr`, `subql #1,%d0` with "operands mismatch" — reproduced in a
   three-line isolated file, so it is the assembler and not the source (SVR4 m68k syntax spells
   immediates `&`, not `#`). Assemble that file with `m68k-linux-gnu-gcc -c -x assembler` and
   link the object with `m68k-cbm-sysv4-gcc`; the repo already mixes the two toolchains this way
   in `build-fpsp060.sh`.
2. **`fputest060` needs the `fork` argument** for Test C. Without it Test A passes and `RCC=0`
   while nothing under test runs.
3. **tftp ports 1069 *and* 1070 were both held** by other sessions. Test with `ss -uln`, not
   `pgrep -af tftp_onesock`; this session ran on 1071.
4. **`burstloop.sh`'s anomaly grep is inert on AMIX** — it uses `\|` alternation, which AMIX grep
   does not support. Its `grep -c '1570 8192'` count is fine; the anomaly line is not, and was
   re-checked one pattern at a time.
5. `burstloop.sh` / `burst4.sh` / `hat_dup_cow` are **not in the repo**; they are on the NAS at
   `amix/f2-260806b/`. M2b recorded burst as unrunnable for lack of the script — it was there.

## Rollback

If anything here has to be undone, the previous baseline is `68060-260806-06` — but **its binary
is no longer on the build host**: it was `build/unix-040` and the M2b build overwrote it.
`FPSP060=0 sh relink-040.sh` does *not* reproduce it either, because M2a/M2b also changed the base
(textsize `0xe4bb8` → `0xe4c24`). The only copy is whatever sits on the Amiga's AmigaOS boot
volume. Preserve it by name before staging any new kernel there.
