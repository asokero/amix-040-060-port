# RESUME HERE — end of 2026-08-01: the 040 side is closed; next is the ISSUE-40 fix, then the 060

Read this and `RESUME-HERE-260731.md` (the standing record of where the port stands). Everything
below is measured on hardware unless it says otherwise. Where a claim made earlier in the day was
later refuted by measurement, this file states the **final** version — the corrections themselves
are in the per-topic records.

```text
build/unix-040               68040-260801-04   base        textsize 0xe4588
build/unix-040-rtg-260801    68040-260801-05   + both RTG drivers   textsize 0xed5b4
```

Both on the NAS in `amix/hwtest-260801/` with `unix_boot040` and `SHA256SUMS-260801.txt`.

## 0. Where things stand

**Everything on the 040 list is done and accepted on hardware.** Battery 9/9 + `ptracepoke`,
burst 96/96, the `mprotect(PROT_EXEC)` publication ABI, and the Model-B header set — the last via
`unix-040-rtg-260801-05`, which boots, drives the physical Piccolo (`CardID=3`) and the VA2000,
and runs X11R5 with `twm` and `xterm` on screen. Full record: `REALHW-ACCEPTANCE-260801.md`.

**Two things are open.** The ISSUE-40 fix (§3), which is the main open piece of engineering, and
the 060 campaign (§5). Neither is an acceptance gap.

## 1. What landed today

| unit | what it does | record |
|---|---|---|
| `codepub040` | `mprotect(..., PROT_EXEC)` is the user-code cache-publication barrier | `USER-CODE-PUBLISH-260801.md` |
| `include-modelb/` + mirror sysroot | 4 KiB page geometry for everything compiled into this kernel | `MODELB-HEADERS-260801.md` |
| `issue39_040` + `memwatch.c` + `leaktest.c` | the kernel's COMMON memory globals are readable at last | `ISSUE39-MEMORY-REGIME-260801.md` |

The publication ABI's acceptance is a one-byte A/B decisive in both directions: with the barrier
on `codepub` passes and reports the unpublished read as **STALE**; with it off the same binary
dies of an instruction fetch off the end of its code page —
`NOTICE: User BUS ERROR at C1034000, PC:C1034000 FAULT:6 PID:293 CMD:./codepub` — which is
ISSUE-38's death reproduced on demand in userland. Photo on the NAS.

## 2. Findings worth carrying forward

* **The publication ABI is on a live path and costs nothing.** ~102 `PROT_EXEC` `mprotect` calls
  by the time a boot reaches a shell, `calls == exec` exactly — that is the runtime linker.
  Starting X adds ~80 more. But 100 execs plus a full `cc` compile move all three counters by
  **zero**: the barrier never runs during ordinary work.

* **The `-I` in `AMIX_KERNEL_CFLAGS` has never worked.** The toolchain's gcc wrapper prepends
  `-I$sysroot/usr/include` before every user `-I`, so the vanilla headers named in the CFLAGS have
  never supplied `<sys/immu.h>` or `<sys/param.h>`. The override goes through `AMIX_SYSROOT` and a
  mirror sysroot. `<sys/param.h>` is the bigger half of that trap (`ptob`/`btop`/`btopr`).

* **A shift check that only matched `lsrl` was blind to signed `>> 11`**, which compiles to
  `asrl` — exactly what `va2000.c` emits. `prototypes/check_page_geometry.sh` matches both.

* **`hat_pfnmiss_n` is a trustworthy instrument.** 10 at boot, exactly +2 per `devmaptest`, and
  zero from everything else — now confirmed across a 96-burst suite, a full battery, and X, on
  **two different kernels**.

* **ISSUE-39 is plain free-list exhaustion, not fragmentation.** The console line settled it:
  `hat_sdtalloc(...) - not enough contiguous memory ...; 1 pages` — a **one-page** request, from
  `hat_ptalloc`'s hardcoded `pea 1` on the exec path. It needs `freemem = 0` *and* a call landing
  in that window: a race. The stock message's word "contiguous" is a red herring. Two earlier
  readings of mine (both involving fragmentation) were wrong; the record documents them.

## 3. ISSUE-40 — CLOSED AND FULLY ACCEPTED on hardware 2026-08-02

> **★ All five pre-registered criteria met: `REALHW-ISSUE40-ACCEPTANCE-260802.md`.** Clean boot of
> `68040-260802-01`. Battery **10/10**, burst **96/96 x 4**, `hat_pfnmiss_n` exactly +2 and unmoved
> by anything else. `availrmem` in ten-minute buckets over 65 minutes of load:
> 6953 / 6950 / 6944 / 6944 / 6945 / 6942 / 6939 — **14 pages of drift**, i.e. ~0.2 pages/min where
> it used to lose ~21. Suite wall-clocks **17m21s / 16m32s / 16m38s / 17m02s** where they used to
> inflate 24m37s → 45m56s (+87 %), which settles that the slowdown was a consequence of the leak.
> 62 989 `ptdat` retirements with `ptd_calls == ptd_retired_n` at every checkpoint and
> `keep0 = keepN = meta = badlink = wake = 0`. Two units: `prototypes/legacysdt040.s` +
> `prototypes/ptdatfree040.s` with `hat_ptfree` V3. Open and logged, not chased: the `sh: no space`
> harness failure, and `ptd_wake_n` still unexercised (the `pt_waiting` path has never fired).

> **★ Both halves landed and hardware-proven: `REALHW-ISSUE40-CLOSED-260802.md`.** Kernel
> `68040-260802-01`. 300 x fork+exec moves `availrmem` by **exactly 0** with the fix on and by
> **-317** with part 2 gated off, in the same boot; fork flat; `availrmem + pages_pp_kernel`
> conserved. Turning it back on returned **324 pages** the control phase had leaked, so the backlog
> drains too. 30716 calls / 26934 retirements with
> `ptd_keep0_n = ptd_keepn_n = ptd_meta_n = ptd_badlink_n = 0`. Safety: `exectest 20`,
> `hat_dup_cow` 1/32/256, `devmaptest` all PASS, `hat_pfnmiss_n` exactly +2, `cb_rel_reject` 0.
> **Remaining: criteria 4 and 5 only** — the full battery 9/9 + burst 96/96, and a long burst run
> with `memwatch` to confirm the ~21 pages/min decline is gone. One session.
> Open, logged, not chased: `issue40e.sh` died on the machine with `sh: no space` while the machine
> was demonstrably healthy; the acceptance was driven from the host instead. See the method note.

## 3b. ISSUE-40 — how it looked while open

> **UPDATE, later on 2026-08-01 — half of it landed and the other half turned out to be the gate.**
> Codex's legacy-SDT teardown edge is implemented (`prototypes/legacysdt040.s`, called from
> `hat040.s` at `Lhf_nodbg`) and provably fires — `hat_badaslot_n` moves **+2** with it on vs **+631**
> with it gated off, over the same 419 teardowns. It returns **zero pages**: `i40_pgfreed_n = 0`,
> `i40_held_n = 434`, and the residual bitmap of a page that stayed charged is `0x7FFC0000` — thirteen
> one-unit `ptdat` crumbs sitting immediately above an 18-unit SDT object at index 0 of its page.
> `hat_sdtfree` only credits when `p_sdtbits` reaches zero, so the "secondary" `ptdat` leak is what
> pins every exec's page. **ISSUE-40 stays open and needs both halves.** Record:
> `ISSUE40-LEGACY-SDT-LANDED-260801.md`; contract request: `ISSUE40-PTDAT-CODEX-QUESTIONS.md`.
> **RAUTAVAHVISTUS samana iltana** (`REALHW-ISSUE40-PART1-260801.md`, NAS `amix/hwtest-260801b/`):
> jokainen ennalta kirjattu ennuste toteutui, myös negatiivinen. `availrmem` **−315 korjaus päällä,
> −316 pois** (300 × fork+exec), fork tasainen; `i40_pgfreed_n = 0`, `i40_held_n = 3440 = sec2+sec3`
> tarkalleen; `i40_bad_n = 0` (muotovartija ei joutunut hylkäämään mitään oikealla muistikartalla);
> `hat_badaslot_n` **+2 / 1665 teardownia päällä vs +975 / 654 pois**. Turvallisuus puhdas:
> `exectest 20` PASS, `hat_dup_cow` 1/32/256 PASS, `hat_pfnmiss_n` tarkalleen +2 per devmaptest,
> `cb_rel_reject` 0. Patteristoa 9/9 EI ajettu: se ajetaan kerran, molempien puolikkaiden jälkeen.
> Base on `68040-260801-12` (textsize `0xe46ec`); kaikki laskuriosoitteet siirtyivät, laske per image.



**`availrmem` loses exactly one page per `exec`, zero per `fork`, and it never comes back.**
Measured with an exact denominator (`test-tools/leaktest.c`); root-caused by Codex
(`amix-kernel-analysis/vm-map/AVAILRMEM-ACCOUNTING-AUDIT.md`, d27a303); confirmed on hardware by
a pre-registered counter signature:

```text
300 x fork        availrmem   +8    availsmem  +123   pages_pp_kernel   -8    sum 0
300 x fork+exec   availrmem -319    availsmem  -319   pages_pp_kernel +319    sum 0
300 x fork+exec   availrmem -308    availsmem  -308   pages_pp_kernel +308    sum 0
300 x fork        availrmem   -8    availsmem    -8   pages_pp_kernel   +8    sum 0
```

`availrmem + pages_pp_kernel` is conserved in every phase, so **a real 4 KiB page is retained per
exec** — it is not lost accounting, and **a naked `availrmem++` would be actively dangerous**
because the counters would then offer a page that is not there.

Mechanism: a dynamic `exec` makes a **17-unit** legacy SDT allocation for libc via
`segvn_create → hat_map → hat_growsdt → hat_sdtalloc`. Two 17-unit allocations cannot share a
32-unit SDT page, so every exec address space gets its own 4 KiB backing page — and the port's own
`hat_free040` (`0x000d82bc`) tears down only the live 040 A/B/C tree, never calling
`hat_growsdt(..., 0)` / `hat_sdtfree`. Debit in retained stock code, missing lifetime edge in our
override.

Scale: ~6900 pages at boot, one per exec; a burst suite eats 5000 in 100 minutes and identical
suites slowed 24m37s → 45m56s over that span. A machine running compiles and X degrades within
hours and needs a reboot. It is the most user-visible defect currently known.

**Acceptance criterion, pre-registered:** `pages_pp_kernel` must stop rising per exec, with
`availrmem + pages_pp_kernel` still conserved; `300 × leaktest 1` must leave all three counters
flat within background noise, and the burst battery + 9/9 must still pass.

Secondary, documented separately by the audit and explicitly **not** part of the same unit: a
`ptdat` metadata leak in `hat_ptfree` (one 64-byte allocator unit per newly allocated table page,
reachable from fork too — the plausible source of the ±8..16 background drift).

Start here: `NEXT-SESSION-ISSUE40-PROMPT.md`. Open questions for Codex, if wanted before
implementation: `ISSUE40-CODEX-FOLLOWUP-QUESTIONS.md`.

## 4. Coverage gaps, stated plainly

* **`Xrtg` is not on this root disk or the NAS**, so X on the VA2000 was not exercised *this
  session*. ⚠ An earlier version of this line said it "was never tested" — that was wrong and the
  user corrected it: **`Xrtg` on the VA2000 is hardware-proven** (2026-07-27, user-run, desktop up
  with several clients — `REALHW-ACCEPTANCE-260731.md`). The only open part is re-verification on
  the newest kernel build, and no unit since has touched that path.
* `/dev/va2000` did not exist on the X11R5 disk and was created on 2026-08-01
  (`mknod /dev/va2000 c 68 0`). `/dev/svga0` has been there since 1992.
* Dhrystone is not on this root disk, so the +64 % copyback figure was not re-measured. The
  publication barrier's cost was settled by counting instead.
* ISSUE-40 has not been dated: the same experiment on `unix-040-260731-33` (on the NAS) would say
  whether it predates today's units. Nothing in them allocates memory, so it almost certainly does.

## 5. Then the 060

Unchanged from `RESUME-HERE-260731.md` §7: measurement boot on the existing dual-CPU kernel →
Codex's crossing-page runtime acceptance (FSLW.MA on a real format-4 frame) → 060SP integer half
→ 060-D caches. The CPU swap is one-way per session. ISSUE-40 is a port bug rather than a
CPU-specific one, so it does not gate the swap — but it is far easier to attribute on the 040.
