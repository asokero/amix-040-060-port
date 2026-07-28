# RESUME HERE — ISSUE-22, state at the end of 2026-07-28 (was: the hunt; now: the acceptance)

Read this file and nothing else to continue. Everything below is measured unless it says otherwise,
and the one open question is marked as open.

---

## 1. ISSUE-22 has a named root cause, measured on hardware

**`prototypes/wb040.s` does not restore DFC.** The 68040 write-back replay sets
`DFC = WBxS & 7` to re-issue a pending store with the faulted access's function code, and never puts
the register back. DFC is not saved by the exception mechanism, so the value survives the `rte` into
whatever the CPU was doing — and what it was doing is often a copy:

```text
000005a0 <lcopyout>:                     (stock, disassembled)
     5a2:  movec %d0,%dfc                DFC = 1 (user data), set ONCE
     5c0:  movel %a0@+,%d1               source read from the kernel segmap  (supervisor data)
     5c2:  movesl %d1,%a1@+              destination write to user space     (DFC)
                                         the loop NEVER reloads DFC
```

With DFC left at 5, the next `movesl` looks a **user** address up in the **supervisor** tree, faults
with TM=5, and `k_trap`'s `userspace()` — reading the frame correctly — routes it to the kernel
resolver, whose stock `as_segat(&kas, userVA)` gate cannot succeed. Unresolved, **no `as_fault`
call**, `sf_fault`, EFAULT, `read: Bad address`.

That is exactly the failure captured on `68040-260728-36`:

```text
WARNING: DBG krnxflt FAILEXIT w=2 va=800C96B0 rw=2 depth=1
```

`va` is inside b2verify's own `malloc`'d 4 MiB heap, `rw` is a write, `depth=1`. Full evidence and
the route with byte-exact addresses: `test-tools/issue22-misroute-260728.txt`.

**Codex's prediction (`w=1 depth=5`, the global `Lkx_depth` counter) was refuted by measurement.**
The counter is global and is held across a sleeping `as_fault` — that part of their reading is
correct and remains a latent defect worth fixing on its own terms — but `Lkx_depth` read live was 0
at rest before and after every failure.

## 2. The mechanism is measured, not inferred

`68040-260728-45` counts the mechanism itself instead of waiting for its rare symptom:

| | one boot | +30 s cofault (pure reads) | +12 bursts b2repro |
|---|---:|---:|---:|
| `wb_replay_n` write-back replays | 4747 | +6472 | +74428 |
| `wb_replay_odd` replays setting DFC ≠ user data | 218 | **+0** | +16 |
| `wb_dfc_changed` faults returning with a changed DFC | 218 | +0 | +25 |
| `wb_dfc_lastold` → `wb_dfc_lastnew` | **1 → 5** | — | 1 → 5 |
| `us_odd_user` misroutes | 0 | 0 | **0** |

The two 218s are the same events counted in two places. `1 → 5` is the pair the theory predicted
before the counter existed. The cofault column is the useful negative: a pure read workload produces
thousands of replays and **not one** with a non-user function code, which is why it never reproduces
ISSUE-22 — the hazard needs a pending *supervisor* store at the moment of a copy fault.

## 3. The fix, and what is NOT yet proven about it

`wb040.s` now saves DFC on entry to each fault wrapper and restores it before returning — in the
wrapper, not in `Lwb_do`, because that is nesting-safe and because `Lwb_fail` returns via `rts` on
the trap-time stack. `wb_dfc_on = 0` (one `.data` long, poke it with `kpeek`/`kpoke`) restores the
old behaviour for an A/B inside a single boot.

**OPEN: the fix has not been shown to change the EFAULT rate.** The control run (fix off, 12 bursts)
produced 25 DFC corruptions and zero EFAULTs, and the historical rate is ~1 EFAULT per 15 bursts, so
12 clean bursts is not evidence either way. Do not record the fix as verified on the strength of a
clean run.

## 4. Next step: stop rolling dice — inject the corruption

Add `wb_dfc_force` to `wb040.s`: when nonzero, the wrapper deliberately leaves that value in DFC on
exit for the next N faults — exactly what nature does 243 times per boot. Then the causal chain is
testable in seconds instead of hours:

* `force=5`, `wb_dfc_on=0` → one `read()` into a fresh buffer should EFAULT immediately, with
  `us_odd_user` climbing and `DBG krnxflt FAILEXIT w=2` on serial. That proves the chain end to end.
* `force=5`, `wb_dfc_on=1` → nothing should happen. That proves the fix by the same measure.

Only after that is it worth spending hours on a natural-rate A/B, and then it is confirmation rather
than the primary evidence.

## 5. Artifacts (`nasu:Public/amix/hwtest-260728/`, `SHA256SUMS-issue22.txt`)

```text
unix-040-b2-dbg-260728-45   copyback + DFC fix + mechanism counters   <- current
unix-040-b2-dbg-260728-42   copyback + DFC fix (no mechanism counters)
unix-040-b2-dbg-260728-39   copyback + misroute probe, no DFC fix
unix-040-b2-dbg-260728-36   the kernel that captured the FAILEXIT line
unix_boot040                MANDATORY loader
kpeek.c kpoke.c cofault.c kdepthmax.c   (also in test-tools/)
```

Counter addresses in **-45** (recompute after any relink: `0x08000000 + textsize + .data offset`):

```text
us_calls 080FFD88  us_odd_user 080FFD8C  us_odd_kern 080FFD90  us_reroute_on 080FFD98
wb_dfc_on 080FFEB4  wb_dfc_n 080FFEB8  wb_dfc_changed 080FFEBC
wb_dfc_lastold 080FFEC0  wb_dfc_lastnew 080FFEC4
wb_replay_n 080FFEC8  wb_replay_odd 080FFECC
Lkx_fn 080FFF54  xpage_on 080FFF58 (=1, ANCHOR)  Lkx_depth 080FFF5C
```

Always read a known anchor in the same `kpeek` range. Every reading in this file was taken with
`xpage_on == 1` and the string `segkmem_ptes` bracketing the counters.

## 6. Instrument discipline that earned its keep, and one failure of mine

* Serial was bracketed with a deliberate `kill -9` before AND after every run.
* `Lkx_fn`, the probe's own print counter, read from `/dev/mem`, equalled the number of lines in the
  serial log — so the capture provably lost nothing. Prefer this over trusting the log.
* A stray `cat /dev/ttyUSB0` was holding the port at session start. Two readers split the byte
  stream; kill the old one first.
* **My driver's timeout stopped waiting but did not kill the remote workload**, so every command
  after it queued behind the still-running script and the post-run counters were never read. Fix the
  driver before the next long run.

## 7. Cleanup owed once the fix is accepted

* `userspace040.s` still carries the reroute band-aid (`us_reroute_on`, default 0). Remove it: it
  treats the symptom and cannot succeed when the access itself is aimed at the wrong space.
* The `DBG userspace ODD` `cmn_err` prints live in the BASE link. Keep the counters, drop or gate
  the printing before shipping a quiet kernel.
* Nothing in this work is committed yet.
