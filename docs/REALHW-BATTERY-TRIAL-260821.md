# First run of the documented acceptance procedure — what it found, including in itself

**Machine:** Amiga 3000, Mercury 68060 @ 66 MHz, VA2000 with Zorro III firmware at `0x42000000`,
Piccolo in Zorro III at `0x40000000`
**Image:** `68060-260819-13` (`unix-040-va2000-dbg`)
**sha256:** `8131fc300e6a452d3388b0a5c88fd1e2d9c8cdf8d0aa78969a964b6091739009`
**Built from:** `wip/zorro3`; load base `0x08000000`
**Date:** 2026-08-21
**Why:** `docs/ACCEPTANCE.md` was written two days earlier from twelve past records. This is the
first time anyone followed it. The point was to test the document as much as the kernel.

## Identity, before anything was believed

```
uname -m                Amiga (Unlimited) 68060-260819-13
cmf_magic  0810F2BC     434d4642  "CMFB"
wbf_magic  0810F610     57424621  "WBF!"
… all ten blocks        all 10 magics OK
```

The driver used is `test-tools/batteryrun-260819-13.sh`, written for this image and load base and
checking **ten magic words against ten blocks read**. Its predecessor checked eight against nine.

## Battery: 11 of 12

```
BATTERY-RESULT FAIL (1 missing)
  ok proctest  fputest  mlocktest  msynctst  mincoretst  bigargv
     ptracepoke  bmaptest  exectest  mul64test  protfault
  MISSING devmaptest   (expected: DEVMAPTEST-RESULT PASS)
```

`devmaptest` T1 failed and it is **ISSUE-49**: a 2048-aligned device mmap offset yields the next
page, and it had been masked because the round-up removed in ISSUE-46 was making both mappings
wrong in the same direction. Two defects were cancelling into a green test.

## Counter census

Diffed across the battery. What moved and what did not, both read deliberately:

| block | delta | reading |
|---|---|---|
| `cmf_ncs_n` | **+6** | three device page mappings × 2 events — `devmaptest` mapping `/dev/mem` |
| `cmf_fb_n` | **0** | nothing mapped the VA2000 framebuffer. Correct |
| `segvn_prot_n` | 0 → **1** | `protfault` reached its path; `segvn_prot_pp_n` +692 |
| `fpc_*` | save +1071, null +1070, rest +1015 | lazy FP: almost every save is a null frame |
| `kvp_n` / `kvp_user_n` | **+4201 each, equal** | every trap user-origin — the invariant holds |
| `ptd_calls` / `retired_n` / `tblfreed_n` | **+428 each, equal** | every call retired and freed its table |
| `i40_*` | calls +76, held +122 | page-table reclaim during `exectest 20` |
| `wbf_fail_n` | **0** | no write-back denial in ordinary work |
| `i39_*`, `f60_*` | **0** | no allocation-contiguity failure; the 68060 FP package took no exception exit |
| **`isp61_*`** | **0** | ← see below |

## The measurement that justifies §9

`isp61_*` stayed at zero through the whole battery — **including `mul64test`, whose entire purpose
is the 68060 unimplemented-integer path.**

The test's own header explains why: "Division by a constant makes **gcc** emit `muls.l Dh:Dl`".
But the battery is built with `/usr/ccs/bin/cc`, the 1991 AT&T driver, precisely because gcc cannot
run on this CPU — and that compiler predates the magic-multiply optimisation and emits the 32-bit
form the 68060 implements in hardware.

So **`MUL64-RESULT PASS` on a 68060 is not evidence about vector 61.** The test computes the right
answer without ever reaching the path it is named for.

Then `isp61ea`, the dedicated test, was run on the same boot:

```
isp61_entry_n   0 → 8
isp61_ok_n      0 → 7
isp61_mulu_n    0 → 2
```

Eight entries, seven handled, and the eighth is the post-increment case that **correctly declined**
(`status 0x9`, expected on a 68060). Self-consistent, and the exact contrast that turns "mul64test
probably does not reach the path" from an inference into a measurement.

This is `ACCEPTANCE.md` §9 working: a counter at zero after a run that should have exercised it
means the path was not reached.

## CPU-specific tests

| test | result |
|---|---|
| `fp060probe` | `bad=0`, 7/7 bit-exact, `fmovecr` 0 ulp |
| `isp61ea` | `bad=0`, 7/7 addressing modes, counters above |
| `fputest060 fork` | child `1.5^12*1000 = 129746`, parent `1.25^-12*100000 = 6871` — both expected |

**Skipped, and why**: `fpenab060` — `fpenab060_asm.s` does not assemble with the GNU assembler
available here (line 36) and no working recipe is recorded; its six enabled-exception classes were
accepted on `68060-260812-06`. `ftest060` — needs the host-side build of Motorola's suite
(`build-ftest060.sh`) and was not rebuilt for this image.

## Three defects the procedure found in itself

This is what the trial was for.

1. **The pass oracle would have reported a broken battery as green.** `ACCEPTANCE.md` said to grep
   for `-RESULT` and require no `FAIL`. `fputest` prints no `-RESULT` token at all, so its failure
   is invisible to that grep; `mul64test` says `WRONG` rather than `FAIL`; three tests carry no
   `RESULT` token. All exit(0) regardless. Fixed: one expected line per test, a missing line is a
   `FAIL`, and a single `BATTERY-RESULT`.
2. **`cc` is the wrong compiler.** `/usr/bin/cc` is a gcc wrapper whose own `cpp`/`cc1` contain
   64-bit `muls.l` and die on vector 61 on this CPU. It must be `/usr/ccs/bin/cc`. Fixed.
3. **"Build them on the guest" is false for the 68060 FP and ISP tests.** `fp060probe` uses
   `__asm__ volatile`, which the 1991 compiler rejects; `isp61ea_asm.s` and `fpenab060_asm.s` are
   GNU assembler syntax, which `/usr/ccs/bin/as` rejects. They are cross-built on the host and
   transferred as binaries. The working recipes are now in `test-tools/mk060.sh`.

## What this does not establish

* **No burst suite and no power cut.** Steps 6 and 7 of the documented order were not run, so
  nothing here speaks to sustained transfer integrity or to on-disk durability after power loss.
* **This is a graphics variant**, not the base kernel. It is base + VA2000 driver + `dev_kvmap` +
  the census block, so the battery covers the base within it rather than the base alone.
* **`fpenab060` and `ftest060` were not run**, so the enabled FP exception classes and Motorola's
  suite are unverified *on this image*; both were accepted on earlier ones.
* The `devmaptest` failure is ISSUE-49 and is **not** a regression introduced by this image's
  changes — it is a pre-existing defect that ISSUE-46's fix stopped masking.
