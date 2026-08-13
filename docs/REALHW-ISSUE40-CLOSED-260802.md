# ISSUE-40 is closed on real hardware — the per-exec page leak is gone, and the machine takes back what the control phase leaked

**2026-08-02, A3000 + Mercury 68040 @ 10.0.10.10, kernel `68040-260802-01`** (sha256 `3727e5b4…`,
textsize `0xe4868`, both halves present). Logs on the NAS: `amix/hwtest-260802/i40regr2.log`,
`i40e-hw.log`. Anchors verified first: `ptd_magic = 50544421`, `i40_magic = 49343021`,
`i39_magic = 49333921`, `hat_cm_ram = 0x20`.

## The measurement

Same boot, same 300-iteration workload per phase, one variable (`ptd_on`, poked live):

```text
phase                        availrmem     Δ     ppk     Δ   ptd_pgfreed   Δ
baseline                          7113          616            151
300 x fork                        7113    +0    616   +0      151        +0
300 x fork+exec   ptd_on=1        7113    +0    616   +0      154        +3
300 x fork+exec   ptd_on=1        7113    +0    616   +0      154        +0
300 x fork+exec   ptd_on=0        6796  -317    935  +319     154        +0
300 x fork+exec   ptd_on=1        6783   -13    946   +11     478      +324
300 x fork                        6783    +0    946   +0      502       +24
```

**Zero.** Not "within noise" — `availrmem` did not move by a single page across 600 dynamic execs
with the fix on, where the same workload cost `-315` yesterday. Gating part 2 off reproduces the old
kernel exactly (`-317`), and turning it back on stops the loss again.

The last two rows are the part nobody pre-registered: with the fix back on, `ptd_pgfreed_n` jumped
**+324** while `availrmem` fell only 13. The machine was *recovering the pages the control phase had
just leaked* — those SDT backing pages became free as their last `ptdat` crumb was retired by later
teardowns. The leak is not merely stopped; the backlog drains.

`availrmem + pages_pp_kernel` conserved throughout (7729 / 7731 / 7729).

## The ownership gate never fired once

Across **30716 calls and 26934 retirements** on hardware:

```text
ptd_keep0_n = 0     ptd_keepn_n = 0     ptd_meta_n = 0     ptd_badlink_n = 0
```

`ptd_badlink_n = 0` is the one that matters most: it says the `ptdat_t` layout in Codex's contract
(`pt_prev` at +8, `pt_next` at +12, circular sentinel lists) is correct for this image, verified by
reciprocal-link checks on all four records of every single retirement. Had it been wrong, the
two-pass design would have caught it before mutating anything — that is why the validation pass
exists, and it cost nothing to have it.

`ptd_calls` (30716) exceeds `ptd_retired_n` (26934) by 3782, which is exactly the gated-off phase's
calls. The A/B control really is "the previous kernel", not a third behaviour.

## Safety — clean

```text
exectest 20                     PASS
hat_dup_cow 1 / 32 / 256        PASS isolation / fork+exec / stress, all three
devmaptest                      PASS, fails=0
hat_pfnmiss_n                   0x0a -> 0x0c = EXACTLY +2 across devmaptest
cb_rel_reject                   0
hat_badaslot_n                  69 -> 99 over the whole session (part 1 holding)
```

`hat_ptfree` now runs an ownership gate and four list removals on every table-page free — the
hottest new code path in this port — and 26934 retirements later nothing has complained.

## Pre-registered criteria, scored

The criteria were written on 2026-08-01, before either half existed.

| # | criterion | status |
|---|---|---|
| 1 | `leaktest 300 1` leaves all three counters flat | **MET** — exactly 0, twice |
| 2 | `availrmem + pages_pp_kernel` still conserved | **MET** — 7729 throughout |
| 3 | `leaktest 300 0` (fork) behaves as before | **MET** — 0, twice |
| 4 | battery 9/9 + burst 96/96, `hat_pfnmiss_n` +2 per devmaptest | **partly** — the safety subset passed incl. the +2; the full battery is a separate session |
| 5 | no ~21 pages/min drift under load | **not yet run** — needs the long burst session |

So ISSUE-40's *mechanism* is closed and hardware-proven. Criteria 4 and 5 are the remaining
confirmation, and they are one session: the full battery plus a long burst run with `memwatch`, which
is also the run that produced the original 100-minute decline.

## Method note: the guest-side run script failed, the measurement did not

`issue40e.sh` died on the machine with `/tmp/issue40e.sh: no space` immediately after its anchor
block, reproducibly, under `sh -x` too — the trace stops right where the shell finishes parsing the
first function definition. It is **not** resource exhaustion: at that moment `freemem` was 5342
pages, `availrmem` 7117, swap 97 % free, 27 processes, and `/tmp/leaktest 20 1` ran with zero fork
failures immediately afterwards.

Bisecting it cost real time and did not converge:

* a minimal script with a function (`t1.sh`) runs fine;
* `r1.sh`, containing the **byte-identical** `rd()` from the failing script plus its helpers, runs
  fine and prints correct values;
* `head -72` of the script is fine, `head -76` reproduces — but both truncate inside a function
  body, so that bisect is confounded by the truncation itself;
* isolating `ptd()` alone (`r4.sh`) hung the telnet command instead of erroring.

**Unresolved, and logged rather than chased further.** The same script *shape* ran fine yesterday on
`68040-260801-12`, which makes a one-variable A/B (same script, both kernels) the cheap next probe if
it ever matters. It is a plausible `sh`-internal allocation failure, i.e. a brk/`grow` path question,
and this port has form there — but "plausible" is not evidence and nothing here measured it.

The acceptance itself was then driven **from the host**: one `real.py` call per phase, counters read
with `/kpeek` between them, no guest shell functions in the loop at all. That is strictly better
instrumentation anyway — the measuring apparatus no longer shares a process with the thing being
measured — and it is how the emulator side had already been done.

## Artifacts

```text
kernel     build/unix-040   68040-260802-01   textsize 0xe4868
           sha256 3727e5b4b162a8a73a9d04475882213e52411012c02db5c1742af19676cbdd25
source     src/ptdatfree040.s + hat040.s hat_ptfree V3 + src/legacysdt040.s
contract   analyysirepo vm-map/ISSUE40-PTDAT-TEARDOWN-CONTRACT.md (ac954b3)
records    ISSUE40-LEGACY-SDT-LANDED-260801.md, REALHW-ISSUE40-PART1-260801.md, this file
logs       NAS amix/hwtest-260802/{i40regr2.log,i40e-hw.log}
```

Runtime counter addresses for **this image only** (`0x08000000 + 0xe4868 + nm(.data)`):

| symbol | address | | symbol | address |
|---|---|---|---|---|
| `ptd_magic` | `0x080FD2E8` | | `i40_magic` | `0x080FD2B4` |
| `ptd_on` | `0x080FD2EC` | | `i39_availrmem_p` | `0x080FD284` |
| `ptd_calls` | `0x080FD2F0` | | `i39_availsmem_p` | `0x080FD288` |
| `ptd_retired_n` | `0x080FD2F4` | | `pages_pp_kernel` | `0x080EFD90` |
| `ptd_pgfreed_n` | `0x080FD2F8` | | `hat_pfnmiss_n` | `0x080FD24C` |
| `ptd_keep0_n` | `0x080FD2FC` | | `hat_badaslot_n` | `0x080FD250` |
| `ptd_keepn_n` | `0x080FD300` | | `cb_rel_reject` | `0x080FD234` |
| `ptd_meta_n` | `0x080FD304` | | `hat_cm_ram` | `0x080FCB68` |
| `ptd_badlink_n` | `0x080FD308` | | | |

`ptd_magic .. ptd_tblfreed_n` are 11 contiguous longs: `kpeek 080FD2E8 11` reads the lot.

## What did not need doing

No compensating write to `availrmem`, `availsmem` or `pages_pp_kernel` exists anywhere in either
half — the 2026-08-01 instruction not to "fix" this with a naked credit was followed, and the reason
it was right is visible in the numbers above: the pages are genuinely coming back, so the counters
now describe memory that actually exists.
