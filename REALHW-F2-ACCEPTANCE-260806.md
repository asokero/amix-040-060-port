# Real-hardware acceptance — F2, the 68060 vector-61 immediate-multiply unit

**2026-08-06, Amiga 3000 + Mercury 68060 @ 66 MHz, kernel `68060-260806-02`
(`68040-260806-02`, textsize `0xe4a64`), copyback (`hat_cm_ram = 0x20`).**
Unit and emulator acceptance: `ISP-VECTOR61-LANDED-260806.md`. Spec:
`amix-kernel-analysis/vm-map/ISP-VECTOR61-UNIT-SPEC.md` (Codex, 69d8f56).

Two hardware sessions the same day. The morning session ran the positive test, the PCR
read and the XPAGE crossing counters; the evening session ran the two tests the landing
note listed as *not yet established*, plus the full battery and a burst regression.

Every address below was recomputed for this image (`0x08000000 + 0xe4a64 + nm(.data)`)
and every run reads `isp61_magic = 0x49363121` before trusting a number.

## 1. The handler does what it claims — `isp61test`, real 68060

**5/5 PASS**, products and CCR bit-identical to the 68040 hardware reference:

```text
isp61_entry_n  5      isp61_unsupported_n   0      isp61_last_pc   0x800004DC
isp61_ok_n     5      isp61_ifetch_fail_n   0      isp61_last_insn 0x4C3C1C02
isp61_mulu_n   3      isp61_nonuser_n       0
isp61_muls_n   2      isp61_badframe_n      0 / trace_decline_n 0
```

Case S2 (`0x80000000 * -1`) is the load-bearing one: N must come from bit 63, and it does.
Every canary read exactly 1 — no retry loop, no wrong PC advance.

## 2. The handler declines everything else — `isp61neg`, real 68060 (NEW)

A **register-source** 64-bit `MULU.L` (`.word 0x4c01,0x0402`): legal on the 020/040,
unimplemented on the 060, and not the form the handler decodes.

```text
isp61_entry_n       +1     the handler was entered
isp61_unsupported_n +1     and declined BY ENCODING
isp61_ok_n          +0     nothing was emulated
isp61_ifetch_fail_n +0     nonuser +0   badframe +0   trace_decline +0
isp61_last_insn      0x4C010402      exactly the encoding the test emitted
isp61_last_pc        0x8000040E
process exit         rc = 137 = 128 + SIGKILL
```

The failure counters matter as much as `unsupported_n`: they show the decline happened for
the *right* reason. A handler that bailed out on a bad frame or a non-user origin would
also have produced a dead process and a plausible-looking `entry_n`.

## 3. A single 8-byte `copyin` may span a page — `isp61xf`, real 68060 (NEW)

The multiply is placed at page offset `0xffc`, so opword+extension end one page and the
32-bit immediate begins the next. Placement is verified at run time, not assumed:

```text
isp61xf: multiply at 0x80002ffc (page offset 0xffc)
Dh:Dl = 00000001:fffffffe  ccr = 10  canary = 1   OK
ISP61XF-RESULT PASS

isp61_entry_n +1   isp61_ok_n +1   isp61_mulu_n +1   isp61_ifetch_fail_n +0
isp61_last_pc  0x80002FFC          isp61_last_insn 0x4C3C1400
```

### The first version of this test was wrong, and the counter is what said so

Run 1 printed `FAIL product`, `Dh = 0000003e` — **with `isp61_entry_n` still 0.** The
instruction had never trapped at all, so the fault could not be in the handler.

Cause: execution fell *through* the alignment padding. Zero fill decodes as `ori.b #0,%d0`
(4 bytes each), the pad length happened to be 2 mod 4, and the stream desynchronised so the
multiply's own opword was consumed as an immediate operand: `ori.b #0x3c,%d0` →
`move.b %d0,%d2` → `ori.b #2,%d0` → `%d0 = 0x3e`. Exactly the observed value.

Fixed by branching over the padding and filling it with `0xfcfc` (Line-F) so any future
desynchronisation dies loudly instead of quietly computing something plausible. This is the
same lesson as the extension-word bug the emulator run caught: **a test that produces a
number is not the same as a test that exercised the path.**

## 4. End-to-end: GCC works again, and the battery is built by it

The morning session established that `cc -o mul64gcc mul64test.c` now returns 0 on the 060
and the resulting binary computes correctly. The evening session went further: **the entire
acceptance battery was compiled with gcc on the 68060** (`mkall.sh`, 13 binaries, log clean —
no errors, no SIGKILLs), which is the broadest end-to-end exercise available, because
gcc's own `cpp`/`cc1` are built out of the very instruction the handler emulates.

Battery run, counters before → after:

```text
isp61_entry_n   28209 -> 71712   (+43 503)
isp61_ok_n      28208 -> 71711   (+43 503)   every emulation succeeded
isp61_muls_n    28207 -> 71710   (+43 503)   gcc's magic-multiply is signed
isp61_mulu_n        1 ->     1   (+0)
isp61_unsupported_n 1 ->     1   (+0)        nothing real hit the decline path
ifetch_fail / nonuser / badframe / trace_decline   all 0 -> 0
```

43 503 emulated 64-bit multiplies during the battery alone, on top of ~28 200 during the
compiles — and every test still validated its own results. A single wrong product would
have shown up as a miscompiled binary or a failed check, not as a counter.

## 5. Battery — 11/11 PASS

```text
proctest      PASS (T1-T7 + CHILD-PRIV-WRITE + CHILD-COW-WRITE)
fputest       PASS (Test A, hardware FP)
mlocktest     PASS (T1-T5)
msynctst      MSYNC-OK  sz=65536
mincoretst    PASS
bigargv       PASS  45 args 4500 bytes
ptracepoke    PASS
bmaptest      PASS
devmaptest    PASS (T1, T2)
exectest 20   PASS (data+bss verified across every generation)
mul64test     PASS (gcc-built -- the F2 payload)
```

Supporting counters over the battery:

```text
hat_pfnmiss_n   10 -> 12    +2 EXACTLY   the devmaptest calibration, again
hat_badaslot_n  43 -> 44    +1           known, addresses outside the RAM ranges
hat_sdtfail_n    0 ->  0
cb_icode_push    1 ->  1                 copyback icode push, once at boot
i40_bad_n / i40_err_n            0       ISSUE-40 fail-closed never taken
ptd_keep0/keepn/meta/badlink_n   0       ptdat lifecycle clean over 390 frees
ptd_calls / retired_n / tblfreed_n  +390 each
i39_fail_n                       0
x60_ma_n +1, x60_rw_read_n +1, x60_compat_n +3, x60_far_fail_n +0
```

`hat_pfnmiss_n` moving **exactly +2** on a third distinct kernel is now a well-established
calibration rather than a coincidence.

`ptd_wake_n` remains 0: the `pt_waiting` branch is still unexercised on either CPU. Noted,
not claimed as covered.

## 6. XPAGE crossing counters on real silicon (morning session)

`xpagetest` T1+T2 (T3 deliberately skipped — see §7):

```text
x60_rw_write_n  0 -> 1     +1 EXACTLY, the pre-registered number (T1)
x60_compat_n    6 -> 6     +0          real 060 set MA; the window tier never fired
x60_ma_n       24 -> 27    +3          global counter, background crossings included
x60_rw_read_n  24 -> 26    +2          likewise
x60_far_fail_n  0 -> 0     +0
x60_last_fa     0x80000FFE -> 0xC1036FFE   (T2's address)
```

`M68060-XPAGE-ACCEPTANCE.md` remaining test 2 (read vs write classification) is satisfied on
hardware. Remaining test 1 is satisfied only **partially**: the document asks for an operand
starting *before* `page+0xff8`, and this test starts at `page_end-2`, inside the window. What
it does establish is that real silicon sets MA and the MA tier is chosen; the wider-operand
case (a 96-bit operand from `0xff4`) is still untested.

## 7. What was NOT run, and why

* **`xpagetest` T3** (write into an mprotect'ed far page) — a known live-lock in this image:
  `Lwx_call` hardcodes `F_INVAL`, so a resident-but-protected far page resolves "successfully"
  forever (397 213 times in the emulator, `x60_far_fail_n` = 0). `XPAGE-FPROT-FINDING-260806.md`.
  Running it on hardware would burn a CPU and require a power cycle. The fix is written
  (`Lwx_callp`, image `68040-260806-03`) but is **not yet emulator-verified**, so it has not
  been near the hardware.
* **The four-suite ISSUE-40 burst criterion** — two suites were run here as a regression, not
  as a re-acceptance; F2 touches only the vector-61 trap path, and the four-suite criterion
  already passed on the 060 in F0 (`68060-260802-01`, 96/96 ×4).

## 8. PCR: superscalar dispatch is ON

`pcr_boot = 0x04300601` on both boots today → revision 0x0430, **ESS = 1**.
This refutes `68060-prestudy.md` §3.4's "we leave ESS = 0 during bring-up": SetPatch sets it
and the kernel never touches PCR. So F0's Dhrystone ratio of exactly 2.0× the 040 is *not*
explained by scalar dispatch — branch cache (still off, CACR `0x80008000`) and the 33 MHz bus
remain the candidates, and 060-D has real headroom.

## 9. Verdict

The vector-61 unit is **accepted on real 68060 hardware**: it emulates the one form it claims
(§1, §3), declines everything else with a counted reason and no state damage (§2), survives a
page-crossing fetch (§3), and has now executed ~71 700 times under real workloads without a
single failure counter moving (§4). The kernel it lives in passes the battery 11/11 with the
`hat_pfnmiss_n` calibration intact (§5).

**The practical consequence: the machine has a working C compiler again.** GCC has been dead
on this CPU since the swap; it now builds the entire test suite.

## Artifacts

```text
test-tools/isp61neg.c + isp61neg_asm.s      the negative test (new)
test-tools/isp61xf.c  + isp61xf_asm.s       the page-crossing test (new)
test-tools/batteryrun3.sh                   battery, re-addressed for this image
test-tools/burstrepeat3.sh                  burst regression, 2 suites
NAS amix/f2-260806b/                        binaries, sources and logs
```
