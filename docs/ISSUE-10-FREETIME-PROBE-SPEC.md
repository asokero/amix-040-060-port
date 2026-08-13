# ISSUE-10 free-time reverse-map invariant probe — implementation spec

> **STATUS 2026-07-16 (SUPERSEDED as the primary lead):** the chain-II question was answered
> instead by a *victim-context* probe (`DBG SEGVCHAIN` in `src/sigkill_dbg.s`, commit
> `744cd65`), which is cheaper (fires only on the crash, in the victim's context) than this
> free-time all-AS/kernel-tree scan. It measured **`in=1`** — the victim's live PTE IS in the
> freed page's `p_mapping` chain — so **chain-II "missing-live-entry" is REFUTED and the
> reverse map is intact.** The real root is a **DOUBLE-REGISTERED frame** (a file vnode-cache
> page that is also a live user-anon page); see `ISSUE-10-CHAIN-II-030-MAP.md` and
> `KNOWN-ISSUES.md`. A free-time probe like this one could still be useful later to catch the
> double-registration at `page_get`/`page_free` (check the returned page has no `p_vnode` AND
> no live user PTE), but the `p_mapping==0` gate below is the WRONG gate — the chain is
> non-empty in the real bug. Kept for reference / possible repurposing.



**Purpose:** catch the ISSUE-10 stale-PTE page-reuse bug *opportunistically at free
time*, without needing the userspace crash to manifest. Directly verifies the invariant
`page_abort`/`page_free` rely on: **when `p_mapping == 0`, no live PTE may still map this
page.** A hit is the smoking gun and names the offending pfn + the table that still maps it.

This is diagnostic instrumentation (a dbg-overlay wrapper), NOT a fix. Runs on the
emulator, where the bug still fires under sustained pressure.

## Hooks (from relink-040-dbg.sh, build 260715-16)
- `page_abort_orig = .text:0xaf8d6`   (already wrapped in `hatalloc_dbg.s`)
- `page_free_orig  = .text:0xaf9ea`
- `hat_memload_orig = .text:0xb4cb0`
- globals (COMMON, resolve at link): `pages`, `pages_base`, `pages_end`, `epages`,
  `kptr040` (D @ 0xfed4), `curproc`

## struct page (vm/page.h, EMPIRICAL offsets — stock sizeof, binary is patched not recompiled)
- `p_mapping` at **offset 32** (validated: hatalloc_dbg.s uses `%a2@(32)`).
- pfn: `page_pptonum(pp) = (pp - pages)/sizeof(page) + pages_base`; ratio
  `PAGESIZE/MMU_PAGESIZE == 1` (both scale together Model-B), so this holds unchanged.
- **`sizeof(page)` = the STOCK struct size** (kernel is byte-patched, not recompiled with
  PAGESIZE=4096) → `p_dblist[PAGESIZE/NBPSCTR]` uses stock 2048/512 = **4** daddr_t = 16 B.
  CONFIRM stride at build: `page[1]-page[0]` from the live `pages` array via IPC READ_MEM,
  or `nm`+struct math. Do NOT assume — a wrong stride poisons every pfn computed.
- target phys = `pfn << 12` (Model-B PNUMSHFT effectively 12 in the running kernel).

## Algorithm (bounded — kernel tree only, the high-value scan)
At `page_free`/`page_abort` entry, for pp with `p_mapping == 0`:
1. compute `targ = ((pp - pages)/stride + pages_base) << 12`  (physical page base).
2. **Bounded reverse-scan of the KERNEL page tables only** (`kptr040` root → leaf tables):
   - kernel VA space is finite → bounded iteration (unlike a full all-AS scan).
   - targets the leading hypothesis directly: the 4AFC crash content is **kvsegu-range**
     (kernel u-area alias), so a surviving stale PTE most plausibly lives in the kernel
     tree / a leaked legacy SDT table, not a random user AS.
   - walk: for each present root entry → leaf table base (`&~0xFF`); for each of the 64
     leaf PTEs, `(pte & 0xFFFFF000) == targ` ?  → HIT.
3. On HIT: `cmn_err` log `pfn=`, `pp=`, the root index + leaf index (→ the mapping VA),
   and `caller=` (frame walk, as the existing wrapper does). Cap ~8 to avoid flooding.
   No behaviour change — tail-call the _orig.
4. `p_mapping != 0` → normal, skip the scan (fast path; scan cost only on the suspect case).

## Wiring
- extend `src/hatalloc_dbg.s` (already has the page_abort wrapper + msg pool +
  frame-walk helper), OR a new `src/freeprobe_dbg.s` in the dbg overlay only.
- dbg-overlay ONLY (never base) — it's instrumentation. `relink-040-dbg.sh` link list.
- 040 privileged/scan ops via `.word` where the native cc lacks mnemonics; end every
  section `.balign 4` (bss-misalign → SDMAC DMA → root-mount ENXIO, cd5b15a).

## Validation
Boot `unix-040-dbg` with the probe, run the fast 6×4 MiB pressure repro (tftp a 4 MiB
file, `cp` it 6× to `/`, sums). Read serial: a `FREETIME-HIT pfn=... root=... leaf=...`
line is the smoking gun → identifies the code path that loaded the unregistered PTE
(candidates (a) coherency/ordering, (b) old-SDT teardown leak, (c) hat_pageunload bypass).
Zero hits across sustained pressure = the kernel-tree scan cleared; widen to current-AS
user tree next.

## Risk / ownership
Load-bearing kernel `.s`: a wrong struct stride, pages anchor, or leaf-walk bound silently
breaks the boot. Per `[[feedback-delegate-coding-to-fable]]` this class is Fable's to
execute (Sonnet/Opus = this spec + review). Staged here ready for Fable, or for a careful
self-implementation if Fable stays unavailable. ISSUE-10 is paused/opportunistic
(`[[feedback-pause-elusive-bug-hunting]]`) — this probe is a background catcher, not a hunt.
