# F1-M2 — the LC gate is `prhasfp`, and the relocation census walked past it

Written 2026-08-24, after the F2-M0 trap census raised anomaly A1. It corrects a claim this
repository made about its own kernel; the wrong claim is not deleted anywhere, it is left where
it was written with a pointer to this file beside it.

## 1. The anomaly

The F2-M0 census (`CENSUS.txt` §ANOMALIES A1) reported that on the LC060 bench rig **every**
`fpc_*` counter reads exactly 0 — including the three F1-M2 refusal counters
`fpc_save_nofpu_n` / `fpc_rest_nofpu_n` / `fpc_setup_nofpu_n`, which exist precisely to catch
"a caller reached the body with no FPU". The same ladder on the FPU rig logs `fpc_save_n`
54253, `fpc_rest_n` 51371, `fpc_setup_n` 2449. Zero refusals therefore does not mean
*refused*; it means the bodies in `src/fpu060.s` **are never entered at all** on an LC part.

That is the opposite of what the F1-M2 comment blocks in `src/fpu060.s:71-80` and
`src/fpuinit060.s:169-193` assert — that five of the eleven pinned call sites reach those
bodies with nothing in front of them. Something upstream declines first. This file names it.

## 2. The reconciliation, first: `fpi_ss_skip_n` climbs while `fpc_setup_nofpu_n` stays 0

There is no contradiction, and the two counters are not measuring the same event. They are in
**series**, and the first one short-circuits.

`fpu_setup_gated` (`src/fpuinit060.s:195-205`) is a wrapper, not a pre-check that falls through:

```text
fpu_setup_gated:
        cmpil   &60,cputype
        bnew    Lsg_go                  | 040: tail jump, no counter
        tstl    fpu_present
        bnes    Lsg_have
        addql   &1,fpi_ss_skip_n        | LC: count ...
        rts                             | ... and RETURN.  fpu_setup is never reached.
Lsg_have:
        addql   &1,fpi_ss_pass_n
Lsg_go:
        jmp     fpu_setup
```

The refusal arm ends in `rts`. Only the pass arm falls into `jmp fpu_setup`. So on an LC part
`fpi_ss_skip_n` counts entries into the **wrapper** and `fpc_setup_nofpu_n` counts entries into
the **body**, and by construction the sendsig path can never produce the second. A climbing
`fpi_ss_skip_n` beside a zero `fpc_setup_nofpu_n` is the wrapper working exactly as written.

The numbers close, on both arms of the same ladder
(`Amix/tmp/2026-08-24-blizzard-f2m0/lc/counters-final.txt` and `fpu/counters-after-ladder.txt`):

```text
LC rig    fpi_ss_skip_n  898     fpi_ss_pass_n    0     fpc_setup_n     0
FPU rig   fpi_ss_skip_n    0     fpi_ss_pass_n  879     fpc_setup_n  2449
```

`2449 − 879 − 1 = 1569` — the sendsig share, the boot probe's single call, and the rest from
`setregs`/exec. The census's own phrase "898 signal deliveries" **is** `fpi_ss_skip_n`, so A1's
two numbers were the wrapper counter and the body counter of one path, read as though they
described two.

**That disposes of `fpu_setup` entirely.** Its other two call sites are gated too — `fpuinit`
reaches `jsr fpu_setup` only on its success tail (`src/fpuinit060.s:142`, after `Lfi_yes`; the
`Lfi_none` arm returns first, and `fpi_nofpu_n = 1` on the LC rig says that is the arm taken),
and `setregs` tests `fpu_present` directly. A1 therefore narrows to `fpu_save` and
`fpu_restore` — five sites, not eleven.

## 3. The gate at every one of the eleven sites

Disassembled out of the image that was actually booted
(`Amix/tmp/2026-08-24-blizzard-f1m3/kernels/unix-060`, sha256
`82470ea2943ff420e5315d4aed46b270830cb07eb2f7f1c099fe43c4807c7ef7`) and cross-checked against
`build/REF-unix-040-f1-baseline`, which carries the same stock bodies at the same addresses.
Both are relocatable images, so each gate is named by its relocation rather than inferred.

| call site | reloc | reaches | the gate in front of it | evidence |
|---|---|---|---|---|
| `fpuinit+0x22` (stock; `fpuinit_orig` once ours is linked) | `0x19bd0` | `fpu_setup` | direct `tstl fpu_present`; our override gates the same call on its `Lfi_yes` tail | `0x19bc6` → `fpu_present`, in both images |
| `setregs_orig+0xd0` | `0x58c34` | `fpu_setup` | direct `tstl fpu_present` / `beqw` | `0x58c2a` → `fpu_present` |
| `sendsig+0x1f8` | `0x5921c` | `fpu_setup` | **none in stock** — now `fpu_setup_gated` | reloc reads `fpu_setup_gated` |
| `setuctxt+0x16` | `0x41930` | `fpu_save` | direct `tstl fpu_present` / `beqw` | `0x41926` → `fpu_present` |
| `coffcore+0x8a` | `0xb7ffc` | `fpu_save` | direct `tstl fpu_present` / `beqw` | `0xb7ff2` → `fpu_present` |
| `swtch+0x1de` | `0xb920c` | `fpu_save` | direct `tstl fpu_present` / `beqw` | `0xb9202` → `fpu_present` |
| `swtch+0x32` | `0xb9060` | `fpu_restore` | direct `tstl fpu_present` / `beqw` | `0xb9056` → `fpu_present` |
| `savecontext+0x7a` | `0x58f8c` | `fpu_save` | **`jsr prhasfp`** / `tstl %d0` / `beqw` | `0x58f7a` → `prhasfp` |
| `savecontext+0xbe` | `0x58fd0` | `fpu_restore` | same block, same gate | — |
| `restorecontext+0x12e` | `0x58ea6` | `fpu_save` | `uc_flags & UC_FPU`, then **`jsr prhasfp`** | `0x58e98` → `prhasfp` |
| `restorecontext+0x154` | `0x58ecc` | `fpu_restore` | same block, same gate | — |

**Eleven sites, ten gated in stock, one ungated — and the one is `sendsig`.** That is exactly
the site `M68060-SUPPORT-LANDSCAPE.md:183` marks **None** and whose fix is its recommendation
#1. F1-M2 fixed the right thing; it just described the surrounding landscape wrongly.

### `prhasfp` — one instruction, one level of indirection

```text
00063308 <prhasfp>:
   63308:  linkw %fp,#0
   6330c:  movel fpu_present,%d0        <- reloc 0x6330e -> fpu_present
   63312:  moveal %d0,%a0
   63314:  unlk %fp
   63316:  rts
```

`prhasfp()` **is** `return fpu_present;`. The /proc accessor and the FP-context gate are the
same read.

`restorecontext` puts a second, independent gate ahead of it — `uc_flags & UC_FPU` (`010`,
`sys/ucontext.h:45`) at `0x58e8c`, `moveq #8 / andl (%a2) / beqw`. `savecontext` runs
`prhasfp` first and then, on the no-FPU arm at `0x58fdc`, **clears `UC_FPU` out of the caller's
`uc_flags`** (`moveq #-9,%d1 / andl %d1,(%a0)`), so the ucontext it hands back tells userland
there is no FP component. The stock code is not merely safe here; it is deliberate.

### Why our census missed it

`src/fpuinit060.s:185-187` says, correctly and misleadingly: *"savecontext and restorecontext
contain no reference to `fpu_present` at all — there is no relocation to it anywhere in either
body."* True. The census predicate was "does this function body carry a relocation to
`fpu_present`", and a **call to a one-instruction accessor that loads it** does not. The method
could only ever have found direct references, so it found four false positives and reported
them as ungated.

The answer was already written down. `M68060-SUPPORT-LANDSCAPE.md:174-186` (analysis lane) is a
caller-and-consumer census with a "Presence gate" column that says `prhasfp, which returns
fpu_present` on both rows, and `**None**` on exactly one. Our census re-derived a *different*
answer with a narrower method and did not reconcile the two. The process defect is not the
grep; it is landing a disagreement with an existing document without noticing there was one.

## 4. What is genuinely ungated, and the silicon risk

**On an `060` boot: nothing.** The static census of coprocessor-1 instructions in the booted
`unix-060` `.text` finds 2945 of them in exactly three populations:

* `0xda`–`0x18e` — the stock `chk_fpu` / `fpu_setup_orig` / `fpu_save_orig` / `fpu_restore_orig`
  bodies. Reachable only through the `Lxx_stock` tail jumps, which sit behind `cputype == 60`
  and are therefore **not taken on an 060 at all**.
* `0xda682`–`0xda8a2` — our own `src/fpu060.s` and `src/fpuinit060.s` bodies, all behind
  `fpu_present` except the boot probe itself, which is unguarded on purpose and runs under a
  temporary vector-11 handler.
* `0xde2c8` onward, ~2900 instructions — the FPSP packages, entered only from an FP exception
  vector.

Corroborated dynamically, and this is the stronger half: across the whole LC ladder
`kvp_super_n = 0` over `kvp_n = 703492`. The scope of that number is exactly *"every exception
that reached `nullvect`"* (`src/kvecprobe040.s:1-19`), which is not literally every trap in the
machine — but it **is** the path an FP trap takes, from either arm: the package's call-outs both
`jmp nullvect` (`src/fpsp060_glue.s:360`, `:424`), and the wrapper records the saved SR's S bit
there. So a supervisor-mode FP trap on this rig would have been counted, and none was. All 20
vector-11 events were user-mode, and all 20 took the regime-3 arm
(`f60_entry_n = f60_fpudis_n = f60_fpudis_nofpu_n = 20`).

The one silicon-shaped uncertainty left is not a missing gate, it is a **classification**
question: on the bench every no-FPU FP instruction arrived as FP-disabled and was counted by
`f60_fpudis_n`. Real LC silicon may raise a plain F-line instead, which would land on
`Lco_fline` rather than `Lco_fpu_disabled` (`src/fpsp060_glue.s:357` vs `:408`). Both arms
`jmp nullvect` and both end in SIGSYS for a user process, so the **outcome** is invariant; only
the counter split moves. F4 should predict the sum and the outcome, not the arm.

## 5. Consequence: the F1-M2 body gates are correct, load-bearing on paper, and unexercised

`fpc_save_nofpu_n` / `fpc_rest_nofpu_n` / `fpc_setup_nofpu_n` all read 0 on the LC rig at
multiuser, after ladder 1, after ladder 2, and on the two F1-M3 repeats (`rigA3`, `rigA4`).
They are **defense in depth behind stock's own `fpu_present` gates, not the first line**, and
in normal operation on an LC part nothing reaches them.

That does not make them wrong or removable. It makes their status honest:

* they are the correct place for the gate — a body gate cannot be bypassed by a caller, and
  `sendsig` proved stock has at least one caller that forgets;
* they are **untested by every run to date**, because no path has ever reached them. A gate
  that has never fired is a gate whose *code* is unproven, however sound its argument;
* a non-zero reading on any of the three is therefore a **finding**, not reassurance: it means
  a caller exists that the eleven-site census does not know about, or that `fpu_present` became
  1 on a part that has no FPU.

The `Expected: 0` line for these three counters should be read that way from here on.

## 6. F1-M2b — pre-registered, not built

The recon found **no real missing gate**, so there is nothing to implement this round. What is
registered instead, so that a later reader can see it was decided rather than forgotten:

1. **Do not remove the body gates** on the grounds that they never fire. The `sendsig` case is
   the standing proof that a stock caller can arrive ungated, and the cost is one `tstl`.
2. **Do not add gates at `savecontext`/`restorecontext`.** They are already gated twice, and a
   third test would be the third place to keep in step.
3. **If any `fpc_*_nofpu_n` is ever non-zero**, the response is a caller census against the
   pinned eleven, not a patch at the body. Name the new caller first.
4. **The census method is the thing to fix**: a gate census that only follows direct
   relocations to the flag misses accessor functions. Follow calls one level, or start from the
   existing document and disagree with it explicitly.

## 7. What F4's silicon pre-registration should carry differently

`BLIZZARD.md` F4-M2 owes "expected `fpu_present` value (0 on an LC), expected `f60_*` counter
values". Three deltas from this work, all of which change what a first-boot reader should
expect to see:

* **Register the `fpc_*_nofpu_n` counters as `= 0`, and say why.** The naive registration is
  "> 0, because the LC has no FPU and the gates will refuse". That is wrong, and it would score
  a HIT on the port as a MISS. The right prediction is 0, with the mechanism named: stock's own
  `fpu_present` / `prhasfp` gates decline before the bodies are reached.
* **Register `fpi_ss_skip_n > 0` as the load-bearing signal-delivery counter**, and register
  `fpc_setup_nofpu_n = 0` beside it as its *expected* companion, so the pair is not read as a
  contradiction on silicon the way it was on the bench. Ratio to check: `fpi_ss_skip_n` should
  track signal deliveries, `fpi_ss_pass_n` should be 0.
* **Register `f60_entry_n == f60_fpudis_n + f60_fline_n` and
  `f60_fpudis_nofpu_n == f60_fpudis_n`, rather than pinning the split.** The bench put all of
  it on the FP-disabled arm; silicon may put some or all on the F-line arm. The invariant that
  matters is that every no-FPU FP event is accounted for and ends in SIGSYS with the machine
  alive — not which of two equivalent arms counted it.

Nothing here changes the F4 gates themselves, the expected `fpu_present = 0`, or the
regime-3 boot claim. It changes three predicted numbers and the reason attached to them.

## 8. Files

```text
src/fpu060.s              the three body gates + the fpc_*_nofpu_n counters (§5 correction note)
src/fpuinit060.s          fpu_setup_gated + fpi_ss_skip_n/fpi_ss_pass_n (§3 correction note)
src/fpsp060_glue.s:395    Lco_fpu_disabled, the regime-3 arm and its no-FPU branch
docs/060-F1-FPUINIT-PREREG-260824.md   §7 carries the dated correction
build/REF-unix-040-f1-baseline         the pre-F1 image the stock gates were read out of
```

Bench evidence, outside the repository:

```text
Amix/tmp/2026-08-24-blizzard-f2m0/CENSUS.txt              anomaly A1 as raised
Amix/tmp/2026-08-24-blizzard-f2m0/lc/counters-final.txt   the LC zeros + fpi_ss_skip_n 898
Amix/tmp/2026-08-24-blizzard-f2m0/fpu/counters-after-ladder.txt   the FPU-rig mirror
Amix/tmp/2026-08-24-blizzard-f1m3/kernels/unix-060        the image disassembled here
Amix/tmp/2026-08-24-blizzard-f1m3/SCORESHEET.txt          rigA3/rigA4, the same zeros
```
