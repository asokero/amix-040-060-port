# ISSUE-22 is CLOSED (2026-07-29): root cause fixed, proven by injection, accepted on hardware

> ⚠ **This is a closed record, not the entry point.** To resume work, read
> **`docs/archive/RESUME-HERE-ISSUE38.md`** — copyback's remaining blocker. This file is kept for the ISSUE-22
> evidence chain and for the counter addresses in §5, which are still current.

Everything below is measured unless it says otherwise.

---

## 1. ISSUE-22 has a named root cause, measured on hardware

**`src/wb040.s` does not restore DFC.** The 68040 write-back replay sets
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

## 3. The fix, and what injection proved about it

`wb040.s` saves DFC on entry to each fault wrapper and restores it before returning — in the wrapper,
not in `Lwb_do`, because that is nesting-safe and because `Lwb_fail` returns via `rts` on the
trap-time stack. Codex confirmed both byte-exactly (`vm-map/ISSUE22-DFC-ARCH-STATE-AUDIT.md`,
7c314b2). `wb_dfc_on = 0` is a one-`.data`-long A/B inside a single boot.

## 4. ✅ DONE — the injection A/B (2026-07-29, `68040-260729-03`, two seconds)

The natural event is far too rare to A/B (12-burst control: 25 corruptions, zero EFAULTs), so the
corruption was injected at exactly the point a leaking replay leaves it, **before** the restore —
which makes one test an A/B of the fix and not only of the mechanism:

```text
A  wb_dfc_on = 0   read_total=0        errno=14  injections=3    VERDICT EFAULT
B  wb_dfc_on = 1   read_total=1048576  errno=0   injections=40   VERDICT CLEAN

serial during A:
WARNING: DBG userspace ODD fmt=7 fc=5 fa=80003228 ssw=85
WARNING: DBG krnxflt FAILEXIT w=2 va=80003228 rw=2 depth=1     <- the ISSUE-22 signature, exactly
```

| | baseline | after A | after B |
|---|---:|---:|---:|
| `us_odd_user` | 0 | **1** | 1 |
| `Lkx_fn` | 0 | **1** | 1 |
| `wb_dfc_forced` | 0 | 3 | 43 |
| `wb_dfc_changed` | 213 | 214 | **254** |
| `wb_replay_odd` (natural) | 213 | 213 | 213 |

40 corruptions repaired inside one 1 MiB read with no user-visible damage; 3 were enough to abort
the read at zero bytes without the fix.

## 4b. ✅ ACCEPTED — the natural-rate confirmation (2026-07-29, `68040-260729-06`, fresh boot)

`b2repro-copy.sh 16`, 72.6 min, serial bracketed at both ends:
**`B2REPRO-COPY CLEAN (0 non-V0 in 16 bursts)`**, 96/96 verifications byte-exact.

| counter | before | after |
|---|---:|---:|
| `wb_dfc_changed` (corruptions repaired) | 220 | **233 (+13)** |
| `us_odd_user` (misroutes) | 0 | **0** |
| `Lkx_fn` (resolver failure exits) | 0 | **0** |
| `wb_replay_n` | 7686 | 112558 |
| `wb_sfc_changed` | 0 | **0** |
| `wb_dfc_force*` (injection) | 0 | 0 — stayed inert |

The +13 is what makes the clean run mean anything: the hazard occurred thirteen times and was
repaired every time. Against a historical ~1 EFAULT per 15 bursts this is about one expected event
avoided, so it is confirmation on top of the injection A/B, not evidence on its own.

**Why it matters beyond ISSUE-22:** this was the last objection to flipping copyback, whose own
acceptance is complete and which measures +63 % (Dhrystone 30000/s vs 18292.7).

## 5. Artifacts (`nasu:Public/amix/hwtest-260728/`, `SHA256SUMS-issue22.txt`)

```text
unix-040-b2-dbg-260729-06   copyback + DFC/SFC contract + counters   <- the ACCEPTED image
unix-040-b2-260729-07       same, copyback, no probes
unix-040-260729-04          base (write-through, silent)
unix-040-b2-dbg-260729-03   the injection kernel (wb_dfc_force)
unix-040-b2-dbg-260728-36   the kernel that captured the original FAILEXIT line
unix_boot040                MANDATORY loader
kpeek.c kpoke.c dfcinject.c cofault.c kdepthmax.c   (also in test-tools/)
```

Counter addresses in **260729-06** (recompute after any relink: `0x08000000 + textsize + .data
offset`; read a known anchor in the same `kpeek` range — every reading in this file was taken with
`xpage_on == 1` and the string `segkmem_ptes` bracketing the counters):

```text
us_calls 080FFDE0  us_odd_user 080FFDE4  us_odd_kern 080FFDE8
wb_dfc_on 080FFF04  wb_dfc_n 080FFF08  wb_dfc_changed 080FFF0C
wb_dfc_lastold 080FFF10  wb_dfc_lastnew 080FFF14
wb_replay_n 080FFF18  wb_replay_odd 080FFF1C
wb_dfc_force 080FFF20  wb_dfc_force_n 080FFF24  wb_dfc_forced 080FFF28
wb_sfc_changed 080FFF2C
Lkx_fn 080FFFB4  xpage_on 080FFFB8 (=1, ANCHOR)  Lkx_depth 080FFFBC
```

## 6. Instrument discipline that earned its keep, and one failure of mine

* Serial was bracketed with a deliberate `kill -9` before AND after every run.
* `Lkx_fn`, the probe's own print counter, read from `/dev/mem`, equalled the number of lines in the
  serial log — so the capture provably lost nothing. Prefer this over trusting the log.
* A stray `cat /dev/ttyUSB0` was holding the port at session start. Two readers split the byte
  stream; kill the old one first.
* **My driver's timeout stopped waiting but did not kill the remote workload**, so every command
  after it queued behind the still-running script and the post-run counters were never read. Fix the
  driver before the next long run.

## 7. What is done, and what is left

**Done** (commits fd97f04, b240aa3, 8631bf9, 80487ad, eabd43f):

* DFC preserved across a fault; proven by injection and accepted under the copyback pressure suite.
* SFC preserved by the same contract. Codex offered removing `ptest040.s:52`'s SFC write instead;
  that write is insurance against DFC/SFC ambiguity on real silicon and the case for removing it
  rests on an emulator source reading, so the leak was made harmless rather than the insurance
  removed. `wb_sfc_changed` stayed 0 across a boot and 105k replays, which is the measured version
  of Codex's "no victim path".
* The reroute band-aid is gone; the `DBG userspace ODD` prints are gated on `btrace_on` so base and
  quiet are silent; the stale header paragraph that defended the removed code is rewritten.

**Left:**

* **Copyback's default — BLOCKED by ISSUE-38, discovered hours after this was written.** ISSUE-22
  was the last objection *known at the time*; booting the probe-less copyback image then showed it
  does not boot at all. Flipping `hat_cm_ram` to `0x20` in the base link is no longer a policy
  decision. See `docs/archive/RESUME-HERE-ISSUE38.md`.
* **`Lkx_depth`** — still a machine-wide counter compared against a per-context limit. Refuted as
  ISSUE-22, real as a latent defect. Codex's design: a private 200-entry `proc *`-keyed table, not
  an unproved u-area field (`vm-map/ISSUE22-DFC-ARCH-STATE-AUDIT.md`, 7c314b2).
* **The b2repro stalls** — 120–125 s baseline bursts interrupted by stalls of 200–900 s, present
  since before any DFC work and on fresh boots. Cheap first checks: root-fs free space and
  fragmentation after ~1 GB of burst writes, and paging pressure from 6 × 4 MiB copies plus a 4 MiB
  verify buffer on a 32 MB machine.
