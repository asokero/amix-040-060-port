# Follow-up for Codex — the `ptdat` half is the gate, not a residual

*Measured twice: emulator first, then real hardware the same day, with every prediction registered
in the script headers before the machine was switched on. Both agree.*

Your `ISSUE40-LEGACY-SDT-TEARDOWN-CONTRACT.md` was implemented exactly as specified and every static
checklist item holds. The edge fires: across a boot plus a 419-teardown workload it released 629
legacy objects, `i40_bad_n = 0`, `i40_err_n = 0`, and `hat_badaslot_n` moved **+2 with the edge on vs
+631 with it gated off** — the native walk no longer traverses the stale legacy descriptors.

**It returns zero pages.** One-boot A/B, same workload, only `i40_on` flipped:

```text
                       teardowns   availrmem   pages_pp_kernel   hat_badaslot_n
i40_on = 1                419        -208           +208              +2
i40_on = 0                419        -208           +208            +631
```

Instrumented at the call (`availrmem` sampled across `hat_growsdt`):

```text
i40_pgfreed_n = 0        i40_held_n = 434
```

and the residual bitmap of the last page that stayed charged:

```text
n         = 18 units       (freed: bits 0..17)
base      = 0x097B4000     page-aligned -> the object was at index 0
p_sdtbits = 0x7FFC0000     bits 18..30 still set = 13 one-unit allocations
```

`hat_sdtfree` credits `availrmem/availsmem/pages_pp_kernel` at `0xb66e4` only when `p_sdtbits`
reaches zero. Thirteen one-unit crumbs sit immediately above every SDT object, and
`hat_ptalloc`'s `hat_sdtalloc(…, 1, …)` @ `0xb69ae` is the only one-unit customer in this kernel.
So your "secondary `ptdat` metadata leak" is not secondary: it is what pins the page, and
`32 - 18 - 13 = 1` free unit is why the next exec cannot reuse it — **one page per dynamic exec**,
which is the whole of ISSUE-40.

Q5's "observed residual timing can change" understates this. The SDT half alone is exactly zero.

**Confirmed on real hardware the same day** (A3000+Mercury 040, `68040-260801-12`,
`docs/REALHW-ISSUE40-PART1-260801.md`, NAS `amix/hwtest-260801b/`), with every prediction registered
before the machine was switched on:

```text
300 x fork+exec, edge ON    availrmem -315      pages_pp_kernel +315
300 x fork+exec, edge OFF   availrmem -316      pages_pp_kernel +320
300 x fork                  availrmem  -24 / 0
i40_pgfreed_n = 0     i40_held_n = 3440 = i40_sec2_n 2284 + i40_sec3_n 1156   (exactly)
i40_bad_n = 0         i40_err_n = 0        cb_rel_reject = 0
hat_badaslot_n        +2 over 1665 teardowns ON   vs   +975 over 654 teardowns OFF
exectest 20 PASS, hat_dup_cow 1/32/256 PASS, hat_pfnmiss_n exactly +2 per devmaptest
```

Residual `p_sdtbits` sampled at five moments on hardware: `0x000e5fff`, `0x000e017f`,
`0x5fffffff`, `0x000e0017`, `0x000e0bff` — densely shared pages, up to 22 of 32 units occupied,
with the freed object punched out of the middle. `i40_last_n = 1` in every hardware sample (the
last object released was a one-unit allocation), where the emulator saw an 18-unit object at
index 0 with 13 crumbs above it. Same allocator behaviour, busier mix.

## What the implementation needs

We write the `.s`. These are the facts we cannot safely derive from the binary in the time we have,
and each one is a panic-grade guess if we get it wrong.

**P1 — the `ptdat` record array layout in THIS image.** Your `HAT-PTFREE-AUDIT.md` says one 64-byte
unit holds four 16-byte records, the first on `active_pts`, three spares on `free_pts`, and
`pp->p_ptdats` (`pp+32`) points at the array. Give the field offsets within a record as this binary
uses them — link pointers (and whether the lists are singly or doubly linked; `hat040.s`'s stock
teardown comment mentions `node->prev@(12)`), `pt_addr`, `pt_as`, `pt_secseg` — and the head/tail
convention of `active_pts` and `free_pts`.

**P2 — the unlink sequence, and whether a retained helper already does it.** Is there a retained
local that removes a record from its list (the mirror of whatever `hat_ptalloc_orig` uses to insert),
callable the way `hat_growsdt` turned out to be? Calling a retained body beat reimplementing one last
time; we would rather do that again than open-code four list removals in assembler. If there is none,
name the exact order: remove the `active_pts` node, remove the three `free_pts` nodes, then
`hat_sdtfree(pp->p_ptdats, 1)`, then clear `pp+32`.

**P3 — where the edge belongs in `hat_ptfree`.** Our override currently does
`clrl %a0@(32)` **before** the keepcnt test, i.e. it destroys the only pointer to the records before
it knows whether it owns the page (you flagged this). The release presumably has to happen after the
`keepcnt 1 -> 0` proof and before `page_free`. Confirm, and say what must happen on the two
exceptional paths (`keepcnt == 0`, `keepcnt > 1`) — leak-and-log as today, or something else.

**P4 — `pt_waiting` / `free_pts` sleepers.** You noted `hat_ptalloc_orig` can still sleep on
`free_pts` with `HAT_CANWAIT` while our `hat_ptfree` neither returns storage there nor wakes anyone.
Does the new edge have to wake `pt_waiting`, or is that path unreachable in the current port (as
`hat_swapout` is)? We would rather not add a `wakeprocs` to a per-teardown path without a reason.

**P5 — is the one-unit allocation avoidable instead of releasable?** `hat_ptalloc` is already patched
to skip `free_pts` reuse (`0xb68a2`), so three of the four records are inert the moment they are
created. If the metadata array serves nothing live in the 040 port, not allocating it at all is a
smaller change than a correct four-node unlink. What would break — the legacy steal path, `hat_swapout`,
`prfastmap`, anything that walks `active_pts`? Say which of those are reachable in this kernel.

## Not needed

A new census. The mechanism is measured end to end: the debit site, the pinning owner, the exact
bitmap, and the credit condition at `0xb66e4`. We need the record layout and the safe order, nothing
larger.

## Pinned artifacts

```text
kernel        build/unix-040        68040-260801-12  textsize 0xe46ec
              sha256 d1acde8d3442c348924bf9ab9ffb8639a53394d18f54305a13380fc94822f24b
measured on   build/unix-040-quiet  68040-260801-11  textsize 0xe472c
source        amix-040-060-port         src/legacysdt040.s + hat040.s @ Lhf_nodbg
                                    commits fbb93aa, 2b35a65, d9d3b15
records       amix-040-060-port/ISSUE40-LEGACY-SDT-LANDED-260801.md   (emulator, re-scoping)
              amix-040-060-port/REALHW-ISSUE40-PART1-260801.md        (hardware, all predictions)
logs          NAS amix/hwtest-260801b/i40regr.log, i40d.log
```

The counters named above are permanent parts of the kernel (`src/legacysdt040.s`), not a
one-off probe.

> **⚠ CORRECTED BY CODEX, and the correction is right.** An earlier version of this paragraph said
> part 2's acceptance would be `i40_pgfreed_n` rising with `i40_sec3_n` while `i40_held_n` stops.
> It cannot be. `hat_legacy_sdt_free` runs at `hat_free::Lhf_nodbg`, **before** the A/B/C walk that
> calls `hat_ptfree`, and `i40_pgfreed_n`/`i40_held_n` sample `availrmem` only around the
> `hat_growsdt` call inside it. The `ptdat` credit happens later, outside that window. Requiring
> those counters to move would be requiring the wrong instrument to move — and worse, it would
> invite reordering the teardown to make them move, which the contract explicitly forbids.
>
> Part 2 therefore carries its own site counter, `ptd_pgfreed_n`
> (`src/ptdatfree040.s`), sampled across the new `hat_sdtfree(ptd, 1)` call. The mandatory
> end-to-end criterion is unchanged and instrument-independent: the one-page-per-dynamic-exec slope
> disappears, fork stays flat, `availrmem + pages_pp_kernel` stays conserved. `i40_pgfreed_n`
> staying at zero after part 2 is expected, not a failure.
