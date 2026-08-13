# REPORT + TASK for Codex — ISSUE-22 is a leaked DFC, and the question is what else leaks

This supersedes the four questions in `docs/archive/ISSUE22-HUNT-TASK.md`. Your answer there
(`amix-kernel-analysis/vm-map/ISSUE22-EFAULT-SOURCE.md`, f757544) was directly useful and its
routing analysis was right; its headline prediction was wrong, and the way it was wrong is worth one
paragraph because it will save you effort on the questions below.

---

## Provenance

```text
kernel repo HEAD                 b8adfc7 + the commit that adds this file
build/unix-040-b2-dbg            68040-260728-45   copyback + the DFC fix + mechanism counters
                                 sha256 fb79d8c699262c20e1dc808a9ff8000c4e2a92dbc516e9d490b7033373d725de
earlier images in the chain      -36 (captured the failure), -39 (misroute probe), -42 (fix, no counters)
evidence                         test-tools/issue22-misroute-260728.txt + the logs beside it
```

---

## 1. What the probe measured, and what it refuted

Your prediction was `DBG krnxflt FAILEXIT w=1 ... depth=5` from the global `Lkx_depth`. The hardware
printed:

```text
WARNING: DBG krnxflt FAILEXIT w=2 va=800C96B0 rw=2 depth=1
```

* `w=2` = no `kas` segment owns the address — the exit that never calls `as_fault`, which is why the
  FAIL logger was silent through every hit. That part of your route analysis was exactly right.
* `depth=1`. And `Lkx_depth`, read live through `/dev/mem` with known anchors on both sides, was 0 at
  rest before the run and 0 after the failure, on two different boots.

Your static reading of the counter is nevertheless correct — it is global, it is held across a
sleeping `as_fault`, and it compares a machine-wide count against a per-context limit. It is a latent
defect. It is not ISSUE-22. **Question 4 asks what you now think it is worth.**

`va=0x800C96B0` is inside b2verify's own freshly `malloc`'d 4 MiB heap and `rw=2` is a write: this is
`copyout` filling a user buffer during `read(2)`, misrouted to the kernel resolver.

## 2. The root cause: `wb040.s` does not restore DFC

Found by reading, then measured. The stock copy loop, disassembled:

```text
000005a0 <lcopyout>:
     5a0:  moveq #1,%d0
     5a2:  movec %d0,%dfc          DFC = user data, set ONCE
     5c0:  movel  %a0@+,%d1        source read from the kernel segmap (plain move, supervisor data)
     5c2:  movesl %d1,%a1@+        destination write to user space (uses DFC)
     5c6:  subql #4,%d0 ; bgel 5c0     -- the loop NEVER reloads DFC
```

`src/wb040.s`'s `Lwb_do` sets `DFC = WBxS & 7` to re-issue a pending write-back with the
faulted access's function code, and never restores it. DFC is not saved by the exception mechanism,
so it survives the `rte` back into the interrupted copy. From there:

```text
next movesl runs with DFC = 5
  -> a USER address is looked up in the SUPERVISOR tree
  -> access error, SSW TM = 5
  -> k_trap 0x5a1ca jsr userspace  (its ONLY call site, reached only with u+0x374 armed)
     reads the frame CORRECTLY and says "kernel"
  -> krnxmemflt -> as_segat(&kas, userVA) = NULL -> unresolved, no as_fault
  -> sf_fault 0x5f2 -> copyout -1 -> uiomove 0x43b54 -> EFAULT
```

## 3. The mechanism, counted rather than argued

`-45` counts the mechanism instead of waiting for its symptom. All figures from `/dev/mem`, each read
anchored between `xpage_on == 1` and the string `segkmem_ptes`:

| | one boot | +30 s of pure-read load | +12 bursts of b2repro |
|---|---:|---:|---:|
| `wb_replay_n` write-back replays | 4747 | +6472 | +74428 |
| `wb_replay_odd` replays setting DFC ≠ user data | 218 | **+0** | +16 |
| `wb_dfc_changed` faults returning with a changed DFC | 218 | +0 | +25 |
| `wb_dfc_lastold` → `wb_dfc_lastnew` | **1 → 5** | — | 1 → 5 |
| `us_odd_user` misroutes | 0 | 0 | 0 |

The two 218s are the same events counted at two places. `1 → 5` — the interrupted code held user
data, the replay left supervisor data — is the pair the theory predicted before the counter existed.

The middle column is the useful negative: a pure-read workload produces thousands of replays and not
one with a non-user function code, because the only pending stores are the copy's own. The hazard
needs a pending **supervisor** store at the moment of a copy fault. That, plus the fact that the next
`lcopyin`/`lcopyout` call sets DFC again, is why ISSUE-22 was a once-per-40-minutes event.

## 4. The fix as it stands

DFC is saved on entry to each fault wrapper (`usrxmemflt`, `krnxmemflt` in `wb040.s`) and restored
before returning; `wb_dfc_on = 0` is a one-`.data`-long A/B. In the wrapper rather than in `Lwb_do`
because (a) each invocation has its own frame, so a nested fault inside a replay restores the *outer*
replay's DFC, which that loop still needs, and (b) `Lwb_do` cannot touch the stack at all —
`k_trap` lands an unresolvable nested fault on `Lwb_fail` with the trap-time SP and its `rts`
expects the stack exactly as `bsr` left it.

**Not yet proven:** that the fix changes the EFAULT rate. The control run (fix off, 12 bursts) gave
25 DFC corruptions and zero EFAULTs, and the historical rate is ~1 per 15 bursts, so it proves
nothing either way. The next step here is fault injection (`wb_dfc_force`) rather than more dice.

---

## What we need from you

**1. ★ The census we would not think to run: what ELSE does our fault path leave changed that
belongs to the interrupted code?** DFC was invisible for a month because it is not a register anyone
lists when they think about clobbering. Same class, same blast radius: SFC (set by `lcopyin` — does
anything on our side write it?), CACR, VBR, the FPU state (`fsave`/`frestore` around FPSP entry),
`urp`/`srp`, the ATC state after our `pflusha` in `Lwb_do`, and anything else our appended 040/060
code touches while borrowing the interrupted context. Byte-exact sites, in the form your ISSUE-36
answer used. **A leak here does not show up as a crash; it shows up as a once-an-hour EFAULT, which
is how this one hid.**

**2. Is the wrapper the right scope for the DFC restore, and does `Lwb_fail` still hold?** We changed
both wrappers from `linkw %fp,&0` to `linkw %fp,&-4` and the epilogue `moveml` from `%fp@(-24)` to
`%fp@(-28)`. Please check that against the `Lwb_fail` landing-pad contract and the nested-fault case,
and say if a stock caller anywhere relies on a fault CHANGING its DFC (we assume none does — we
restore what the interrupted code had, which is the conservative choice, but we would rather be told).

**3. Does the stock kernel have paths that read DFC/SFC without setting it first?** We found six
`movec ...,%dfc` sites in stock text (0x486, 0x4d2, 0x5a2, 0x660, 0x6f4, 0x728) and they all look
like per-call setup in the copy family. If any routine instead *inherits* the value, the same leak
has a second victim class we have not looked for.

**4. `Lkx_depth`: worth fixing, and with what?** It is now demonstrably not ISSUE-22. Your
per-process contract still looks right, but the u-area offsets we would need are not something we
can prove today (our own probes use `u+0x374`, `u+0x730`, `u+0x864`, `u+0x1C0`, and the vanilla
`user.h` does not match that layout). If you think the counter should be fixed, name a storage
location we can prove — a genuinely unused u-area longword with the evidence, or a keyed table —
and say what the symptom of leaving it alone would actually be under a realistic process count.

## What makes a good answer

* For (1), a census with addresses, in your ISSUE-36 style. That answer was directly usable and it is
  why that fix was four instructions.
* An explicit "no" where the answer is no. Question 3 may well be empty, and knowing that is worth as
  much as a finding.
* If you think the DFC mechanism is wrong or incomplete, say so early. It is supported by 218
  measured corruptions with the predicted `1 → 5` signature, but the causal link to the EFAULT is
  still one measured instance plus a mechanism — the injection test is not run yet.
