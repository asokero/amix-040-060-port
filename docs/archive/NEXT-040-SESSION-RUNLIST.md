# Run list for the next **68040** hardware session (A3640 swap)

**Written 2026-08-07, before the swap, deliberately.** The machine currently has the 68060 and
`68060-260806-06` is the accepted baseline. Putting the A3640 back costs a card swap and jumpers,
so this session is batched: **do not swap for any one of these items alone.**

Ordering rule from the campaign: the swap is one-way per session. While the 040 is in, there is no
060 regression, so nothing 060-specific gets touched during it.

## Preconditions

* A3640 (68040) installed, jumpers set.
* **SetPatch is an 060 precondition, not an 040 one.** On a real 040 the loader writing
  `cputype = 40` is correct. Verify at boot rather than assume: `cputype` must read `0x28` (40),
  not `0x3c`. If it reads 0x3c, something is wrong with the swap, not with the kernel.
* Boot with `unix_boot040` (mandatory: FPSP carries ~330 PC-relative relocs).
* **Recompute every counter address for the image you actually boot** — `0x08000000 + textsize +
  nm(.data)` — and read each magic word before trusting the block. Addresses are not carried over
  from any earlier document.

Magics to check first: `segvn_prot_magic` = `53564e21`, `isp61_magic` = `49363121`,
`kvp_magic` = `4b565021`, `i40_magic` = `49343021`, `ptd_magic` = `50544421`.

## 1. ISSUE-42 — the one thing that genuinely requires a 68040

Everything else here is regression confirmation. This is the open question.

`wb040.s`'s own verified comment says the emulators never set **WB1S valid**, so the emulated 040
exercises only WB2/WB3. Real silicon fills WB1 — and the ISSUE-11 note records that WB1D is
**bus-lane aligned** on real hardware while WB2D/WB3D are right-justified. So the real 040 can
behave differently from every measurement taken so far.

Run `protfault a`, `b`, `c`, each supervised, and read:

```text
Lwbf_n          replays that failed permanently and were swallowed
wb_replay_n     total replays
wb_replay_odd   replays whose DFC was not 1 (user data)
```

Measured on the **emulated** 040, kernel `260806-06`, one `protfault c`:

```text
Lwbf_n          0 -> 1      exactly one denied replay, swallowed
wb_replay_odd  82 -> 82     unchanged, so the failing replay used FC = 1
protected bytes 01->01 00->00    page 2 untouched -- no protection bypass
unprotected     00->5a 00->5a    page 1 took the store  => a silently TORN store
```

**Questions only real silicon can answer:**

1. Does case c still tear the store, or does WB1 change the outcome?
2. Which WB slot carries the crossing store on real hardware?
3. Is `Lwbf_n` still exactly 1 per case, or do the live WB1 replays add more?

If the ISSUE-42 fix has landed by then (Codex's contract: validate WB1/WB2/WB3 independently, first
permanently denied user write-back stops the replay and becomes a protection fault for *that*
address), then case c must instead **PASS by SIGSEGV with the protected bytes intact**, and
`protfault` now measures both halves of that claim rather than inferring one from the other.

## 2. 040 hardware baseline — nothing has been re-established since the CPU swap

Everything below landed while the 060 was in the machine and has only ever been emu-validated on
the 040 path: ISSUE-41 (`segvn_prot040.s`, deliberately **not** cputype-gated), F4's siginfo
translation, and the M0 vector probe.

Pre-registered, same criteria as the 060 acceptance:

* battery **11/11**, 0 FAIL / 0 error / 0 panic
* `segvn_prot_pp_n` well over a thousand, `segvn_prot_n` moving **only** for deliberate denials
* `hat_pfnmiss_n` **+2 exactly**
* burst **96/96 per suite** (`/payload.bin` sums `1570 8192` on hardware)
* `i40_bad_n` = `i40_err_n` = 0; `ptd_keep0/keepn/meta/badlink` = 0
* power-cut disk truth **6/6** — and note the harness defect found on 2026-08-07: the uptime guard
  in `b2reboot-truth.sh` **fails open** once the writer has been up over an hour, because it parses
  `up N min` and gets `up 1:15`. Either fix it first or record both uptimes by hand.

## 3. The M0 vector probe — the 040 is its control

`kvecprobe040.s` wraps `nullvect`, which M0 established is not the "unhandled vector" path but the
**shared exception entry**: every syscall and every page fault passes through it. It is the most
load-bearing hook in the tree and has **no hardware validation on either CPU**.

Measured on the emulated 040 at idle:

```text
vector 2   12 346   access fault
vector 32  26 552   TRAP #0 = system call
all others      0
```

On the real 040 expect the same *shape*. Two specific readings:

* **`kvp_vec[11]` must stay 0 on the 040**, because the FPSP handles vector 11 there. That is the
  control for the 060 measurement where it moved 0 → 4 across `fp060probe`.
* `kvp_super_n` vs `kvp_user_n`: the emulator showed user-origin dominating. Worth one look.

## 4. Cost of the probe, and the byte-identity claim

* **Dhrystone A/B across `kvp_on`** (1 → 0 → 1 within one boot). The probe adds work to every
  syscall; its cost has never been quantified, and it should not ship on hardware unmeasured. If
  it is material, the default flips to 0 and it becomes an opt-in instrument.
* Assert the 040 path is behaviourally unchanged by all the 060 work: every `x60_*` counter and
  `isp61_*` counter must still read **0** after the full battery on the 040.

## 5. If time remains

* `exectest 20`, `hat_dup_cow 1/32/256` — the old 040 standbys.
* Re-run `fp060probe` on the 040 as a control: `fsin/fetox/flogn/fmovecr` should **survive** there,
  because the 040 FPSP emulates them. That is the cleanest possible demonstration that F3 is
  restoring on the 060 what the 040 already has.

## Explicitly not in this session

* Any 060 work: F3, the 060 FPSP, `fp060probe` as anything but a control.
* Re-opening ISSUE-40 or the 040 VM port; both closed.
