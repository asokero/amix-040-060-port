# Reviewing the FPE branch, and what it measured here — 2026-08-28

The collaborating line's soft-FPU lane (`origin/fpe`, 34 commits, 47 files) reviewed and built on
this side, then run on three beds: an emulated 68LC060, an emulated 68060 with an FPU, and the
Mercury 68060. Nothing was merged; the branch was built in an isolated worktree.

Two things below outlived the review. The `mk_fpe_cc.py` blocker turned out to be
[ISSUE-55](../KNOWN-ISSUES.md) — our own compiler, not their script — and the emulated LC060 bed
is now `emu-reset-boot.sh lc060`, which gives this side an FPU-absent machine it never had.

## A1 — building the branch here

Isolated worktree at origin/fpe (24a391a), our config.sh, our pinned tarball.  main untouched.

## What passed unchanged

* `tools/check-env.sh` — "NetBSD syssrc.tgz (sha256 matches)".  His pin accepts our archive.
* Base relink: `TOTAL complaints: 0`, `68040-260828-01`, sha256 `24a29b89…`.
* **`FPE=0` reproduced the base byte for byte** and said so with the sha — the rollback proof
  works as claimed.
* Extraction: 25 files + 4 machine-ABI headers, **byte-identical to the tarball**, "still
  tail-only".
* Model-B sysroot mirror; the geometry probe passes through the mirror and fails against the
  stock sysroot — the 2 KiB-header trap is gated.
* `FPE=1`: 20/20 emulator objects, glue compiles, six overrides weakened with addresses read
  from the base, `ld -r`, all FPE relink assertions, and **"family unchanged by the FPE pass"**.
* Artifact `68040-260828-02`, sha256 `3de029c0…`, 1 902 032 bytes.

## The one blocker, and it is not a defect in his logic

`src/mk_fpe_cc.py` refuses to run here:

    ABORT: the .swbeg anchor is not present exactly once in .../m68k-cbm-sysv4-gcc
           -- the wrapper changed shape and this generator must be re-checked

It fails **closed**, with the right message, which is the correct behaviour.

The cause is that the anchor is one implementation's exact text:

    his:  perl -pi -e 's/^(\s*)\.swbeg\s+&(\d+)[ \t]*$/$1.long $2/'
    ours:         s{^(\s*)\.swbeg\s+&?\d+\s*$}{$1.long 0}gm;

**The two repairs are equivalent.**  Our wrapper's own comment settles it: the four bytes "sit
between an unconditional jmp and the table, so they are never executed", so whether the long
holds the case count or zero cannot matter.  No correctness question in either toolchain —
worth stating explicitly, because our wrapper compiles every kernel this side ships.

Two further facts that shape the fix:

* Our wrapper carries **eight** repairs in one perl block (cmp operand order, fsgl/fs/fd sizes,
  fdmov, fmovm, mov, tdivs, tdivu, swbeg), not the five his header describes.
* It does **not** repair the SGS bit-field operand, so his added line is genuinely needed here.

And the insertion form matters as much as the anchor: his FIX is a standalone `perl -pi -e …
"$1"` invocation.  Dropped after our `.swbeg` line it lands *inside* the existing perl block and
the generated wrapper dies with a shell syntax error at that line.  Adapted to an in-chain
`s/…/…/g;` it works and the build completes.

**Superseded by ISSUE-55 the same day:** the anchor matches the current upstream wrapper
exactly once and ours zero times, so their script was pinned correctly and this side was the
outlier. The original reading, kept because it was wrong in a useful way:

**Suggested resolution, and it is his own:** `mk_fpe_cc.py`'s header already says the repair
"belongs in gcc-cross-amix rather than here".  That is the fix — a ninth repair in the wrapper
upstream, after which `mk_fpe_cc.py` can be deleted rather than made portable.  Our wrapper
already carries eight, so adding one is the established pattern rather than a new mechanism.
Until then the generator needs to know which wrapper shape it is editing, and both the anchor
and the insertion form differ between the two shapes.

## Not reviewed

The 9 464 lines of glue logic, the compat headers, `fpe_glue.c`'s re-entrancy rule.  Those need
running, not reading.  Structure, mechanism, licence and instrument review is in the session
record.

## Merge surface

Merge base `4f15c81cc`; he is missing 24 of our commits (all of 2026-08-27).  Conflicts expected
in `tools/check-env.sh` and `BUILDING.md`, both small, and in both his version supersedes ours:
`tools/netbsd-pin.sh` is one value in one file covering all four extraction sites, where our
inline check covers the env check and none of the four.


## Phase C — the decline arm on 68060 silicon

Kernel `68060-260828-02`, sha256 `3de029c052ed30a636df…` — Jussi's `fpe` branch (24a391a) built
with our toolchain from our pinned NetBSD 10.1 tarball. Amiga 3000, Mercury 68060 **with** FPU.

## The bar, and this time it means something

|  | LC060 emulator | 060+FPU emulator | **68060 silicon** |
|---|---|---|---|
| `fpu_present` / `fpu_emul` / `fpe_armed` | 0 / 1 / 1 | 1 / 0 / 0 | **1 / 0 / 0** |
| `fpe_entry_n` (the bar) | 7862 | 0 | **0** |
| `fpe_v11_n` (denominator) | 7862 | **0** | **12** |
| `fpe_v11_fmt2_n` | 0 | 0 | **12** |
| `fpe_v11_fmt4_n` | 7862 | 0 | 0 |
| `fpe_fmtx_n` | 0 | 0 | **0** |
| `fpe_cputype_amix` | 60 | — | `0xffffffff` sentinel |

On both emulator beds with an FPU the census was **also** zero, so the bar said nothing there —
registered as a failure mode in the prediction before the runs. On silicon it moved, so
`fpe_entry_n = 0` is a **declined** zero and not an unreached one. That is the measurement the
whole instrument exists for, and it did not exist until now.

The census arithmetic matches the workload exactly: **8** from `ftest060 unimp`, **+4** from
`fp060probe`'s four instructions the 68060 does not retire (`fsin`, `fetox`, `flogn`,
`fmovecr`) = **12**.

`fpe_cputype_amix` stays at its `0xffffffff` initialiser — the sentinel meaning "never
sampled", which is consistent with a lane that never armed. It is doing exactly the job the
comment claims: distinguishing not-sampled from sampled-as-zero.

## The oracle passes, so interposing ahead of the FPSP broke nothing

    fp060probe        bad=0 -- 7/7 at 0 ulp, including the four the 060 hardware does not retire
    ftest060 unimp    Unimplemented FP instructions...passed
    ftest060 main     Unimplemented <ea> / data type / non-maskable overflow / underflow, all passed

## The surprise: format 2 on a 68060

All twelve frames are **format 2**. `src/fpe040.s` labels the two shapes:

    cmpiw &0x402c   eight-word, format 4: 68060 FP disabled
    cmpiw &0x202c   six-word,  format 2: 68040 unimplemented FP

The LC060 run agrees with the first label — 7862 events, all format 4, FP disabled. This run
contradicts the second: a 68060 with a working FPU takes the **six-word format-2** frame for
unimplemented FP instructions, twelve times.

So format 2 is the *unimplemented instruction* frame rather than a 68040-specific one, and the
comment's labelling is incomplete. The dispatch is unaffected — both shapes are decoded and
`fpe_fmtx_n` stayed 0 — so this is a documentation defect, not a behavioural one.

It is also the counter Jussi asked for by name: *"fpe_v11_fmt2_n is where an FPU-present 68040
would latch the format-2 frame this tree has only ever cited from documentation."* It latched —
on an FPU-present 68**060**, which is not where either side expected to find it.

## A prediction of mine that failed, and what it corrects

I predicted the census would move on hardware because "hardware has real unimplemented traps".
It did not move on boot or under ordinary work. Both platforms read zero until an unimplemented
instruction was deliberately executed, because **AMIX's libm computes transcendentals in
software** — `sin(1)`, `exp(1)`, `log(10)`, `sqrt(2)` all print correctly with the census at 0.

That also corrects my earlier emulator diagnosis. I attributed the emulator's zero census to
`fpu_no_unimplemented=true` in the stock configs. That setting is real and worth knowing about,
but it was not the whole cause: silicon has no such setting and read zero too. The dominant
cause on both is the workload.

Whether `fpu_no_unimplemented=false` would let the emulator reach vector 11 is still untested —
`ftunimp0`, the probe that issues a raw `fsin`, is GNU-syntax and will not assemble with the
guest's native `cc`, and `test-tools/README.md` documents no build path for it. Cross-building
it is the way, and `fp060probe` turned out to be the same class: it uses `__asm__ volatile` and
must be cross-built, which is not written down anywhere either.
