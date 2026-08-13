# F4 — `faultcode_t` → `k_siginfo_t` on the user fault path

**2026-08-06, kernel `68040/68060-260806-06`.** Implements the second half Codex specified in
`amix-kernel-analysis/vm-map/XPAGE-FPROT-CONTRACT.md` Q2. Companion to the generic VM fix in
`SEGVN-PAGEPROT-PANIC-260806.md`; together they close the protected-far-page case on the 060.

## The contract, read from the binary

Vanilla `usrxmemflt`, `0x5b120..0x5b12e`:

```text
5b120:  moveal %fp@(12),%a0 / movel %d0,%a0@     infop->si_signo = <signal>
5b12a:  moveal %fp@(12),%a0 / movel %a0@,%d0     return infop->si_signo
```

`u_trap@0x5a5a2` then picks its `/proc` fault class by comparing `infop->si_signo` against
SIGSEGV 11 / SIGBUS 10 / SIGFPE 8, and `trapsig` queues nothing while `si_signo == 0`. Our
wrapper had been returning nonzero while leaving `infop` exactly as the *successful* near-page
call left it — zero. Hence 32 340 propagated failures and no signal.

The observable form of that, on the 060 console, was one line per retry:

```text
NOTICE: User BUS ERROR at C1033FFE, PC:8000088E FAULT:1 PID:190 CMD:/tmp/protfault
```

`FAULT:1` is `u_trap`'s default class — direct confirmation that the signal number never arrived.

## What was added

`Lu_siginfo` in `src/wb040.s`, called only when `wb060_xpage` reports a permanent far-page
failure on the **user** path:

| faultcode_t | si_signo | si_code |
|---|---|---|
| `FC_PROT` 4 | SIGSEGV 11 | `SEGV_ACCERR` 2 |
| `FC_NOMAP` 3 | SIGSEGV 11 | `SEGV_MAPERR` 1 |
| anything else | SIGBUS 10 | `BUS_ADRERR` 2 |

`si_addr` = `x60_far_addr`, the **denied far page** — not the frame's FA. On a crossing access the
CPU reports where the transfer *started*, which is the page that was fine; reporting that to the
process would be actively misleading.

`Lwx_protfail` now returns `FC_PROT` rather than a synthetic 1, so a real faultcode reaches the
translator. `krnxmemflt` is deliberately untouched: it has no siginfo argument and keeps the plain
zero/nonzero convention, so the shared helper never hands it a signal number.

## Measured

**Emulated 68060 — `protfault` 3/3 PASS**, including case C, which has live-locked or panicked
every kernel until now:

```text
case a PASS: child terminated by SIGSEGV
case b PASS: child terminated by SIGSEGV
case c PASS: child terminated by SIGSEGV

x60_siginfo_n     1     the translation ran exactly once
x60_far_addr      0xC1034000    si_addr names the protected page
x60_far_fail_n    1     one propagated failure
x60_last_afret    4     <- as_fault returned FC_PROT ITSELF
x60_fprot_fail_n  0     <- the verify-then-fail fallback was never needed
```

The last two lines are the interesting part. Yesterday's post-check existed because `as_fault`
claimed success on a page it had not changed; with `segvn_faultpage` fixed it now returns
`FC_PROT` on its own, and the fallback sits unexercised. That is the signature of having fixed a
root cause rather than papering over it — the workaround became dead weight.

**Emulated 68040 — A and B PASS, and `x60_far_addr`/`x60_siginfo_n` both stayed 0**, i.e. the 040
executed none of this. `proctest` and `exectest 20` both PASS, so the change did not disturb the
user fault path it lives in.

## Still open: case C on the 68040

C remains a **protection bypass** on the 040: the store into the protected page succeeds. That is
a different mechanism — the 040 has already performed the access internally and `wb040_replay`
re-issues the pending write-backs, which no protection check in this chain covers. It is not
reached on the 060 (no write-backs) and is untouched by this unit.

The open question is a contract one, not a coding one: *should the replay consult protection, or
should the pending write-backs be discarded once the fault is known to be fatal?* That belongs in
the same kind of analysis that produced this fix.

## Not yet done

* Full battery and burst on `260806-06` (they were run on `-05`, which differs only in this
  translation and the `FC_PROT` return).
* Everything on hardware. The Amiga stays on `68060-260806-02`.
