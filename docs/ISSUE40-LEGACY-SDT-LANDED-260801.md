# ISSUE-40, part 1: the legacy-SDT teardown edge is restored — and it returns ZERO pages

**2026-08-01.** Codex's contract (`vm-map/ISSUE40-LEGACY-SDT-TEARDOWN-CONTRACT.md`, 8234a0e) was
implemented exactly as written and it works exactly as written. The **predicted consequence** —
that the machine gets its page back — is **refuted by measurement**. This file is that measurement
and what it re-scopes.

## What landed

| unit | file | mechanism |
|---|---|---|
| `hat_legacy_sdt_free` | `src/legacysdt040.s` | `hat_growsdt(as+0x14, 2, 0)` then `(…, 3, 0)` |
| call site | `src/hat040.s` @ `Lhf_nodbg` | after the null-root guard, **before** the A/B/C walk |
| linkage | `relink-040.sh` | `--globalize-symbol hat_growsdt` (retained body is *called*, never weakened) + a hard check that refuses an image where the call is unbound |

Contract checklist, all ten items: image pinned by SHA, retained helper globalized not weakened,
null-root guard preserved, `as+0x14` (not `*(as+0x14)`) as argument 1, sections 2 then 3 with
`nentries=0`, both calls before `Lf_A`, `0xb65e4`/`0xb6610` still `72 0c`, the disabled-preload /
no-op-`hat_exec` / native-`hat_dup` / unreachable-`hat_swapout` assumptions unchanged, the central
`cb_page_release` hooks and the final `cpusha bc; pflusha` untouched, and **no compensating write to
`availrmem`, `availsmem` or `pages_pp_kernel` anywhere in the patch**.

One thing is ours and not the contract's: a **shape guard**. Before calling we re-derive what
`hat_sdtfree` will compute (`n = (be16(rdesc)+1+7)>>3`, `base = be32(rdesc+4)`) and refuse anything
that is not a plausible allocator object — `base>>12` inside `[pages_base, pages_end)`, and either
`((base & 0x7ff)>>6) + n <= 32` or, for `n >= 32`, `(base & 0xfff) == 0`. The contract argues
sections 2/3 are safe because user VAs live at `0xC0000000+`, so native root entries A4..A7 are never
real. That argument is correct and it is *an argument*; a native descriptor at A4 carries UDT = 3 too,
and its neighbour word handed to `hat_sdtfree` as a base would free a **live pointer table**. The
guard costs ~15 instructions on a teardown path and makes `i40_bad_n` a number. It has read **0** in
every run so far — the contract's argument is now also a measurement.

## Evidence that the edge fires

Emulated A3000/040, `unix-040-quiet` build `68040-260801-11`, counters read straight out of guest RAM
over the Amiberry IPC (`READ_MEM`), so no guest tooling is in the loop.

```text
boot to login:  calls=296  s2=289  s3=145  empty=158  bad=0  err=0
                289 + 145 + 158 = 592 = 296 x 2      every section visit accounted for
```

The decisive one-boot A/B (same boot, same 100-iteration shell exec loop, `i40_on` flipped live with
`WRITE_MEM`, so the ONLY variable is the edge):

```text
                              teardowns   availrmem   pages_pp_kernel   hat_badaslot_n
i40_on = 1  (edge runs)          419        -208           +208              +2
i40_on = 0  (edge gated off)     419        -208           +208            +631
```

`hat_badaslot_n` is the mechanism showing itself: with the edge on, the native walk stops tripping
over legacy false descriptors, because they have been cleared. **+631 vs +2** across 629 released
objects — the two numbers match, so the edge unambiguously does what it says.

## The refutation

And the leak is **completely unchanged**. `-208` either way, `availrmem + pages_pp_kernel` conserved
at 7729 in every sample.

`hat_sdtfree` only credits `availrmem++ / availsmem++ / pages_pp_kernel--` (`0xb66e4`) when clearing
our bits leaves `p_sdtbits` **zero**. So "we released the object" and "the machine got a page back"
are different events. Sampling `availrmem` across the call turns that from an argument into a number:

```text
pgfreed = 0        held = 434        (434 releases, ZERO pages returned)
```

And the residual bitmap says who is holding them:

```text
last release that returned nothing:
    n         = 18 units            (the object we freed: bits 0..17)
    base      = 0x097B4000          page-aligned -> the object sat at index 0
    p_sdtbits = 0x7FFC0000          bits 18..30 STILL SET
```

**Thirteen one-unit allocations packed immediately above the SDT object keep its 4 KiB backing page
charged.** One unit is 64 bytes, and the only one-unit allocator customer in this kernel is
`hat_ptalloc`'s `ptdat` metadata record (`hat_sdtalloc(…, 1, …)` @ `0xb69ae`) — which our custom
`hat_ptfree` clears the pointer to (`pp+32`) and never releases. That is Codex's own "secondary
`ptdat` metadata leak" (`AVAILRMEM-ACCOUNTING-AUDIT.md` §"Secondary ptdat metadata leak").

## What this re-scopes

Codex's Q5 said the legacy SDT and `ptdat` fixes are *ownership*-independent and could land
separately, with the caveat that "observed residual timing can change". The measurement sharpens
that caveat into a dependency:

> The legacy-SDT edge cannot return a single page while the `ptdat` records leak, because every
> exec's SDT backing page is pinned by that exec's own `ptdat` crumbs. The two are independent to
> *write* and strictly serial to *observe*. ISSUE-40's acceptance criterion cannot be met by either
> half alone.

It also explains the shape of the leak better than "the SDT page is retained" did. The object is
18 units at index 0 of a fresh page; 13 crumbs land above it; 32 - 18 - 13 = 1 unit free. The next
exec's ~18-unit object cannot fit, so it takes a new page — **one page per dynamic exec**, exactly
the measured slope, and it is the *crumbs* that make the page unreusable, not the SDT object.

## Pre-registered acceptance: status

Restating the five criteria from `archive/NEXT-SESSION-ISSUE40-PROMPT.md` honestly.

| # | criterion | status |
|---|---|---|
| 1 | `leaktest 300 1` leaves all three counters flat | **NOT MET** — unchanged by this half |
| 2 | `availrmem + pages_pp_kernel` still conserved | met (7729 in every sample) |
| 3 | `leaktest 300 0` (fork) behaves as before | not yet measured on hardware |
| 4 | battery 9/9 + burst 96/96, `hat_pfnmiss_n` +2 per devmaptest | not yet measured on hardware |
| 5 | no ~21 pages/min drift under load | **NOT MET** — unchanged by this half |

So this half is landed but ISSUE-40 stays **open**. It is landed anyway, on its own merits: it is the
missing lifetime edge from the stock contract, it is a prerequisite for the other half being
observable, and it removes 631 traversals-per-419-teardowns of stale legacy descriptors by the native
walk — a use-after-free-adjacent hazard the `Lf_badA` bounds check was only *containing*.

## Hardware exposure: deliberately not spent yet

No hardware run. The pre-registered criterion cannot pass with half the fix in, and the `ptdat` unit
will touch the same teardown path, so one hardware session after **both** halves costs one session
instead of two. The image is built, checked and ready if a safety-only regression run is wanted first.

## Artifacts

```text
build/unix-040        68040-260801-12  textsize 0xe46ec
                      sha256 d1acde8d3442c348924bf9ab9ffb8639a53394d18f54305a13380fc94822f24b
build/unix-040-quiet  68040-260801-11  textsize 0xe472c   (the image these numbers came from)
```

Runtime counter addresses — **recomputed per image**, `0x08000000 + textsize + nm(.data)`; the
quiet overlay's are NOT the base's:

| symbol | base `unix-040` | quiet `unix-040-quiet` |
|---|---|---|
| `i40_magic` (must read `0x49343021`) | `0x080FD138` | `0x080FD178` |
| `i40_on` | `0x080FD13C` | `0x080FD17C` |
| `i40_calls` | `0x080FD140` | `0x080FD180` |
| `i40_sec2_n` | `0x080FD144` | `0x080FD184` |
| `i40_sec3_n` | `0x080FD148` | `0x080FD188` |
| `i40_empty_n` | `0x080FD14C` | `0x080FD18C` |
| `i40_bad_n` | `0x080FD150` | `0x080FD190` |
| `i40_err_n` | `0x080FD154` | `0x080FD194` |
| `i40_pgfreed_n` | `0x080FD158` | `0x080FD198` |
| `i40_held_n` | `0x080FD15C` | `0x080FD19C` |
| `i40_last_n` | `0x080FD160` | `0x080FD1A0` |
| `i40_last_base` | `0x080FD164` | `0x080FD1A4` |
| `i40_last_bits` | `0x080FD168` | `0x080FD1A8` |
| `i39_availrmem_p` (follow the pointer) | `0x080FD108` | `0x080FD148` |
| `i39_availsmem_p` (follow the pointer) | `0x080FD10C` | `0x080FD14C` |
| `pages_pp_kernel` (plain `.data`) | `0x080EFC14` | `0x080EFC54` |
| `hat_badaslot_n` | `0x080FD0D4` | `0x080FD114` |
| `hat_cm_ram` (anchor, must read `0x20`) | `0x080FC9EC` | `0x080FCA04` |

## Refuted predictions, logged

1. **Mine, going in:** "restoring the `hat_growsdt(…,0)` edge returns the page." It returns nothing.
   The debit is where the audit said; the *release condition* is not what either of us checked.
2. **Codex's Q5 framing:** the two leaks are "not measurement-independent … observed residual timing
   can change." Too weak. The SDT half is not merely differently-timed without the `ptdat` half — it
   is exactly zero.
3. **The audit's 17-unit libc object:** measured `n = 18` on this image's last release. Same order,
   not the same number; nothing downstream depends on it, but the model was checked rather than
   assumed.

Next: `archive/ISSUE40-PTDAT-CODEX-QUESTIONS.md`.
