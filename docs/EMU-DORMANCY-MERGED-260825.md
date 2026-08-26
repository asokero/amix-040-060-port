# Dormancy of the merged tree, measured on both emulated CPUs — 2026-08-25

Image: `build/unix-040` from `main` at the z3660 merge, one binary booted on both configs
(`68040-260825-02` and `68060-260825-02` — the banner reports the CPU, not the image).

**sha256 `35203427648337dd55f756d6039c7a209887355e7e58982efbde449f1edc7e3c`** — added 2026-08-26, and the reason is
a live collision rather than a precaution. `68040-260825-02` **also** names a different kernel in
this same tree: `docs/060-F4-M2-PANIC-260825.md` uses it for `unix-060-f1-z3660-CARD1-ced0s1`,
sha256 `f53bc0eb…`. Two kernels, one string, both load-bearing, both merged. That document
carried its sha and this one did not, so this was the ambiguous half. Found by the other line,
not by us.

This is the cheap step between merging and hardware, and its purpose is attribution. A green
battery would only say *nothing visibly broke*; this says **which of the 16 118 new lines
actually executed**, which is what narrows the suspect list if hardware does go red.

## Method

`tools/status-facts.sh` resolves 30 counter blocks and 824 named fields for this image.
`kpeek` reads each block in one call on the guest, zeros suppressed — so a dormant hook
leaves nothing but its magic, and **what survives the filter is the report**.

## 1. All 30 magic words correct, on both CPUs

Every block is where `status-facts.sh` says it is, so every other reading here is
trustworthy. This is also a merge check in its own right: two lines' counter blocks now live
in one image, and none of them moved onto another.

## 2. Every ISSUE-10 investigation hook is dormant

`i10a_watchva`, `i10b_on`, `i10c_on`, `i10d_on`, `i10g_on`, `i10r_watchva`, `i10s_watchva`,
`i10t_on`, `i10w_on` — all zero, on both CPUs, and every counter in their blocks is zero too.

What *is* non-zero in those blocks is compiled-in configuration, not evidence of execution:
masks (`i10p_gmask`, `i10s_watchmask`), watch targets (`i10w_target`, `i10g_lova/hiva`), and
the poison value `4afc0000` the hooks are looking for. Reading those as activity would be the
same error as reading a counter without its magic.

## 3. Three behaviour changes are live by default — not two

An earlier reading of the diff said two. There is a third, and it is the most consequential:

| | gate | what it did |
|---|---|---|
| `hgfault040.s` | `hg_on = 1` | an ISSUE-10 **cure**, not an instrument |
| `pageinitzero.s` | — | `pgz_calls = 1`, **7712 pages** zeroed at boot |
| `syncguard.s` | — | `syncg_calls = 2` |

`hgfault040.s`'s own header calls it "the cure is live"; it completes a user first-touch write
one page past the break, which a 68040 otherwise discards. That is a semantic change to fault
handling in the base link, carried by every image on both CPUs.

## 4. The cure is live but measurably inert — and that is the stronger statement

On the 68040 it inspected **1674** user-mode write faults and acted on **none**:

    hg_seen_n    = 0x68a (1674)     its own documented denominator
    hg_cand_n    = 0                hg_grow_n    = 0        hg_landed_n  = 0
    hg_win_n     = 0                hg_cover_n   = 0        hg_unres_n   = 0
    hg_mapfail_n = 0                hg_far_n     = 0        hg_lim_n     = 0

A zero action counter *beside a non-zero denominator* says the code ran 1674 times and
declined correctly every time. A zero counter alone cannot distinguish that from a path that
was never reached — which is the difference between a tested branch and an untested one, and
the reason the denominator is worth as much as the counters.

On the 68060 even the denominator is zero: the hook hangs off the 68040 access-error frame, so
it is absent from that path entirely rather than merely quiet.

## 5. The CPU split is coherent

The only activity present on the 060 and absent on the 040 is the `fpc_*` block — the 060 lazy
FPU context path (`fpc_save_n` 7294, `fpc_null_n` 6378, `fpc_rest_n` 6870). Nothing else
diverges, which is what a single binary correctly branching on `cputype` should look like.

## What this does not cover

Hardware, and any workload that would actually **trigger** the cure — Bourne sh's `addblok`
raising its arena top across the break is the case `hgfault040.s` was written for, and this
boot did not reach it. So the cure's decline path is exercised 1674 times and its **act** path
not at all. That gap belongs in the hardware run, and it is the one place where a green
battery would still leave something unmeasured.
