# ISSUE-40 `ptdat` teardown contract

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/ISSUE40-PTDAT-TEARDOWN-CONTRACT.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

## Scope

This note answers the five implementation questions in
`amix-040-060-port/ISSUE40-PTDAT-CODEX-QUESTIONS.md`. It is deliberately narrower
than a new HAT census: the debit, pinning bitmap, and missing credit are already
measured. The remaining task is to retire one allocator unit without corrupting
the retained `active_pts` / `free_pts` lists or freeing a table page whose
ownership is not proven.

This is static analysis and an implementation contract. It does not patch the
kernel.

## Pinned artifacts

| Artifact | Identity |
|---|---|
| Kernel source tree | `amix-040-060-port` commit `2b35a653dce1a03b526903d08b0e214371640530` |
| Kernel | `build/unix-040`, build `68040-260801-12` |
| Kernel SHA-256 | `d1acde8d3442c348924bf9ab9ffb8639a53394d18f54305a13380fc94822f24b` |
| Kernel `.text` size | `0x000e46ec` |
| Retained allocator | `hat_ptalloc 0x000b688e` |
| Retained metadata free | local `hat_sdtfree 0x000b65ca` |
| Retained stock table free | body at `0x000b6cf4` |
| Active table free | native `hat_ptfree 0x000d85ce` |
| Follow-up brief | `amix-040-060-port` commit `cef651f`, `ISSUE40-PTDAT-CODEX-QUESTIONS.md` |
| Hardware evidence | `amix-040-060-port` commit `d9d3b15`, `REALHW-ISSUE40-PART1-260801.md` |
| AMIX layout header | `vanilla/usr/include/vm/vm_hat.h:74..96` |
| Reference implementation | `svr4-src-3b2/usr/src/uts/3b2/vm/vm_hat.c:2437..2719` |

Addresses are linked `.text` offsets. Relocations, rather than the zero-filled
immediate operands printed from this relocatable ELF, establish references to
data and functions.

## Evidence update: emulator and real hardware

The `cef651f` brief does not change P1 through P5 or the pinned kernel image. It
adds independent hardware confirmation that the `ptdat` allocation is the gate
for the whole measured page leak, rather than a lower-rate residual:

```text
A3000 + Mercury 68040, build 68040-260801-12
300 x fork+exec, legacy edge ON:   availrmem -315, pages_pp_kernel +315
300 x fork+exec, legacy edge OFF:  availrmem -316, pages_pp_kernel +320
300 x fork:                        availrmem -24, then 0
i40_pgfreed_n = 0
i40_held_n = 3440 = i40_sec2_n 2284 + i40_sec3_n 1156
i40_bad_n = 0, i40_err_n = 0, cb_rel_reject = 0
```

The safety subset also passed `exectest 20`, `hat_dup_cow 1/32/256`, and
`devmaptest`. This strengthens the attribution and the need for the second
ownership edge. It does not change the record layout, unlink sequence, or
exception policy below.

### Counter-boundary correction

The follow-up brief proposes that, after the `ptdat` fix, `i40_pgfreed_n` must
rise with `i40_sec3_n` and `i40_held_n` must stop. Those two conditions are not
valid mandatory acceptance predicates for the implementation as currently
ordered:

1. `hat_legacy_sdt_free` runs at `hat_free::Lhf_nodbg` before the native A/B/C
   walk and its calls to `hat_ptfree`.
2. `i40_pgfreed_n` and `i40_held_n` sample `availrmem` only around the retained
   `hat_growsdt` call inside `hat_legacy_sdt_free`.
3. The new `hat_sdtfree(ptd,1)` executes later inside `hat_ptfree`, outside that
   measurement interval.

Consequently the existing counters may still report a held legacy release,
followed later by the `ptdat` release that clears the final bitmap bit and
returns the backing page. Allocator packing can make an earlier legacy release
occasionally become the final owner, but that is not guaranteed by the lifetime
contract. Do not reorder teardown merely to make these counters move.

The mandatory end-to-end acceptance remains the disappearance of the exact
one-page-per-dynamic-exec slope while fork stays flat, with
`availrmem + pages_pp_kernel` conserved. If site attribution is required, add a
counter or before/after sample around the new direct `hat_sdtfree(ptd,1)` call;
the existing legacy-SDT counters cannot observe that call.

## Short verdict

| Question | Verdict |
|---|---|
| P1: layout | Four 16-byte records. The use union is at `+0..+7`, `pt_prev` is `+8`, and `pt_next` is `+12`. Both lists are circular doubly linked sentinel lists: `sentinel+12` is first/head and `sentinel+8` is last/tail. |
| P2: helper | No callable narrow unlink helper exists. `REMOVE_PT` is a C macro open-coded at every site. The retained stock `hat_ptfree` contains the desired four removals but is not safe to call as a helper. |
| P3: placement | Prove `page_t.p_keepcnt == 1` and all metadata invariants before mutation. Unlink and free metadata while the table page is still held, then clear `p_ptbits/p_ptdats`, perform `1 -> 0`, restore table-page accounting, and call `page_free`. On `0`, `>1`, or bad metadata, mutate nothing and log/leak. |
| P4: waiters | Reachable under memory pressure: native `hat_pteload` and root `hat_dup` pass `HAT_CANWAIT|HAT_NOSTEAL`. Wake `&free_pts` only after a successful table-page release, then clear `pt_waiting`. |
| P5: omit allocation | Not safe. Record zero is live metadata for `hat_pteload`, `hat_pt2ptdat`, `hat_unlock`, `hat_unload`, and `hat_dup`. Only records 1..3 are inert. Replacing the array with embedded native metadata is a separate allocator redesign, not the smaller ISSUE-40 change. |

## P1: exact `ptdat_t` layout

The installed AMIX header and the current binary agree exactly:

```text
offset  size  active interpretation                         free interpretation
------  ----  --------------------------------------------  ---------------------
+0      4     struct as *pt_as                              pte_t *pt_addr
+4      4     ushort pt_secseg; uchar pt_inuse, pt_keepcnt  page_t *pt_pp
+8      4     struct ptdat *pt_prev                          pt_prev
+12     4     struct ptdat *pt_next                          pt_next
total   16
```

The `+0..+7` fields are one union. `pt_as` and `pt_addr` do not coexist, and
`pt_secseg` at `+4`, `pt_inuse` at `+6`, and `pt_keepcnt` at `+7` overlap the
four-byte `pt_pp` field.

This resolves the comment ambiguity mentioned in the task. `pt_prev` is at
`+8`, not `+12`. A disassembly sequence that appears to write
"`node->prev@(12)`" means:

```text
prev = node->pt_prev       // load node+8
prev->pt_next = node->pt_next  // store at prev+12
```

It does not place `pt_prev` at record offset 12.

### List sentinel convention

`active_pts` and `free_pts` are full 16-byte dummy `ptdat_t` records:

| Symbol | Current address | Visibility |
|---|---:|---|
| `active_pts` | `0x00010290` | local `b` |
| `free_pts` | `0x000102a0` | globalized `B` |
| `pt_waiting` | `0x000102b0` | globalized `B` |

`hat_init 0x000b4148` initializes both lists as:

```text
list.pt_prev = &list       // list+8: tail
list.pt_next = &list       // list+12: head
```

Therefore:

```text
empty:  list.next == &list && list.prev == &list
first:  list.next
last:   list.prev
walk:   for (node = list.next; node != &list; node = node.next)
```

The stock macros, byte-identical in intent to the AMIX body, are:

```text
APPEND(node, list):
    list.prev->next = node
    node->prev = list.prev
    node->next = &list
    list.prev = node

PREPEND(node, list):
    list.next->prev = node
    node->next = list.next
    node->prev = &list
    list.next = node

REMOVE(node):
    node->prev->next = node->next
    node->next->prev = node->prev
```

Fresh allocation at `0x000b6a86..0x000b6ae4` appends record zero to
`active_pts`, then appends records one through three to `free_pts` while
advancing the old table-fragment address by `0x200` each time.

## P2: exact unlink and retained-code verdict

### No narrow helper

There is no retained function corresponding to `REMOVE_PT`. The 3B2 source
defines it as a macro at `vm_hat.c:2451..2454`, and the AMIX binary open-codes
the same two pointer stores.

The best byte witness is the four-record loop in the retained stock
`hat_ptfree` at `0x000b6e18..0x000b6e52`:

```text
base = pp->p_ptdats
for i = 0..3:
    node = base + i * 16
    node->prev->next = node->next
    node->next->prev = node->prev
hat_sdtfree(base, 1)
pp->p_ptdats = NULL
```

The generic removal body is at `0x000b6e26..0x000b6e38`. It does not need to
know which sentinel owns a node. With the current fresh-only allocator, the
ascending order has the desired meaning:

1. remove `base + 0x00` from `active_pts`;
2. remove `base + 0x10` from `free_pts`;
3. remove `base + 0x20` from `free_pts`;
4. remove `base + 0x30` from `free_pts`;
5. call `hat_sdtfree(base, 1)`;
6. clear `pp->p_ptdats`.

This matches the stock loop exactly and is safer than writing separate active
and free list operations.

### Why not call retained `hat_ptfree`

The whole retained body at `0x000b6cf4` is not a usable helper:

- it repeats physical-page lookup, fragment-index, bitmap, hold, and accounting
  decisions that the native wrapper must guard;
- it retains old fragment arithmetic around those decisions;
- when `pt_waiting != 0`, `0x000b6dea..0x000b6e0c` wakes the sleepers and then
  deliberately skips the four-node unlink, `hat_sdtfree`, page release, and
  accounting credit;
- its full-release block is reached only when no waiter exists;
- entering the block at `0x000b6e18` directly would depend on private register
  and stack state, so it has no callable ABI.

Use the retained body as the byte-level template, not as a callee.

The one retained callee that should be reused is `hat_sdtfree`. It is still a
local `t` symbol at `0x000b65ca`, so an external assembler implementation must
globalize it without weakening it, just as the landed legacy-SDT edge does for
`hat_growsdt`. Add a link-time assertion that the call resolves to a global
defined symbol, not an unresolved address zero.

## P3: safe insertion and exception policy

### Do not confuse the two keep counts

Two independent fields are involved:

| Object | Offset | Width | Meaning |
|---|---:|---:|---|
| table page `page_t.p_keepcnt` | `pp+2` | word | physical page holds; fresh `page_get` leaves the HAT table hold at one |
| record `ptdat.pt_keepcnt` | `ptd+7` | byte | count of soft-locked translations in that table |

Both must satisfy their own release condition:

```text
page_t.p_keepcnt == 1      // native wrapper has exclusive final HAT page hold
ptdat[0].pt_keepcnt == 0   // no translation remains soft-locked
```

Do not require `ptdat[0].pt_inuse == 0`. Whole-address-space `hat_free` follows
the stock optimization that unlinks every mapped page but does not maintain
per-table `pt_inuse` on the way to whole-table destruction. A nonzero stale
`pt_inuse` at this boundary is therefore legal. Likewise, do not require
`pt_as != NULL`: lazily allocated 040 pointer-table pages receive the allocator
record but do not initialize it as a leaf owner.

### Required pre-mutation proof

After the existing alignment and managed-PFN checks derive `pp`, require:

```text
pp->p_keepcnt == 1
pp->p_ptbits  == 1
pp->p_ptdats  != NULL
(pp->p_ptdats & 0x3f) == 0
ptd[0].pt_keepcnt == 0
all four nodes have valid reciprocal prev/next links
```

`p_ptbits == 1` is a useful ownership discriminator in this exact image:
fresh `hat_ptalloc` writes one at `0x000b6a4c..0x000b6a52`, and the patched
allocator never reuses another fragment from the page. It is stronger than
the current "aligned managed page" test, which can accept an unrelated held
RAM page.

If reciprocal-link diagnostics are implemented, validate all four records in
a first pass and mutate in a second pass. Do not discover a bad fourth record
after the first three have already been unlinked.

### Release order

The task's proposed placement is correct with one refinement: prove the page
hold is exactly one first, but keep the hold at one while retiring metadata.
The stock order is the safer ownership order:

```text
derive pp and ptd
prove all invariants, including pp->p_keepcnt == 1

for ptd[0..3]:
    REMOVE_PT(ptd[i])

pp->p_ptbits = 0
hat_sdtfree(ptd, 1)
pp->p_ptdats = NULL

--pp->p_keepcnt             // proven 1 -> 0
++availrmem
++availsmem
--pages_pp_kernel
page_free(pp, 0)

if pt_waiting != 0:
    wakeprocs(&free_pts, 1)
    pt_waiting = 0
```

The metadata is removed while the table page is still held. `hat_sdtfree` may
free the separate allocator backing page when this bit was its final owner, so
no `ptd` field may be read after that call. Clearing `pp->p_ptdats` afterward
matches the stock body and is safe because `pp` is a different page.

The active wrapper currently performs:

```text
0x000d860e  42 a8 00 20       clrl pp@(32)
0x000d8612  4a 68 00 02       tstw pp@(2)
0x000d861a  53 68 00 02       subqw #1,pp@(2)
0x000d861e  66 00 00 24       bne Lpf_held
```

The first store must move behind the metadata retirement, and the decrement
must become an exact-one gate followed by the normal `1 -> 0` transition.

### Exceptional paths

For this current port, both physical-page exceptions should fail closed:

| Condition | Required action | Reason |
|---|---|---|
| `p_keepcnt == 0` | no list write, no metadata free, no field clear, no accounting, no wake; log and return | double release or wrong page |
| `p_keepcnt > 1` | do not decrement; no other mutation; log and return | the remaining holder has no proven contract to retire `ptdat` or restore HAT accounting later |
| missing/bad `p_ptdats`, `p_ptbits != 1`, locked `ptdat`, or bad links | no mutation; log and return | ownership is not established |

The current `>1` behavior, decrement-and-return, is not a safe compromise. It
separates the table page from the HAT's accounting without retiring metadata,
and a later generic holder release cannot know which HAT credits and list
nodes remain. A bounded fail-closed leak preserves one diagnosable owner
instead of creating an orphan.

If hardware ever records a legitimate `p_keepcnt > 1` teardown, capture the
holder provenance and design that transition separately. It must not be
silently generalized from the normal exclusive path.

## P4: `pt_waiting` is reachable and must be woken

The sleep body remains at `hat_ptalloc+0x43e`:

```text
0x000b6ccc  ++pt_waiting
0x000b6cd2  sleep(&free_pts, 2)
0x000b6ce4  retry from hat_ptalloc entry
```

`HAT_NOSTEAL` does not bypass this path. It only skips the old active-table
steal. Current native callers are:

| Caller | Flags | Failure behavior |
|---|---:|---|
| `hat_pteload`, lazy pointer table | `3 = HAT_CANWAIT | HAT_NOSTEAL` | can sleep |
| `hat_pteload`, leaf table | `3` | can sleep |
| `hat_dup`, pointer table | `3` | can sleep |
| `hat_dup`, leaf table | `2 = HAT_NOSTEAL` | returns failure; does not sleep |

Thus the wait path is statically reachable under real memory pressure even
though normal tests may never have exhausted fresh pages.

The current `hat_unlock` wake at `0x000d7d58..0x000d7d72` is not a substitute.
It wakes when a `ptdat.pt_keepcnt` becomes zero but publishes no physical page,
and `free_pts` reuse is disabled. It is at best a spurious retry for the
fresh-page allocator.

A successful exact-one `hat_ptfree` does publish a real page through
`page_free`, so it is a valid progress event for the fresh-page retry. Wake
after metadata retirement, accounting, and `page_free`, not before. On any
fail-closed path, do not wake because no new resource became available.

The channel name is historical: the allocator still sleeps on `&free_pts`,
but after waking it skips that list and retries `page_get`.

## P5: the allocation cannot simply be removed

### Live record-zero consumers

Record zero is not compatibility debris. For a managed 040 leaf,
`hat_pt2ptdat 0x000b5e0a` does:

```text
pp = pages[(pte_address >> 12) - pages_base]
index = (pte_address >> 9) & 3
return pp->p_ptdats + index * 16
```

Live leaf PTEs occupy only table offsets `0x000..0x0ff`, so the index is zero.
The following native paths use that exact persistent record:

| Path | Live use |
|---|---|
| `hat_pteload` | initializes `pt_as`, `pt_secseg`, `pt_inuse`, and `pt_keepcnt`; increments in-use and lock counts on later loads |
| `hat_unlock` | resolves record zero and decrements `pt_keepcnt` |
| `hat_unload` | resolves record zero and decrements `pt_inuse` and, for unlock unloads, `pt_keepcnt` |
| `hat_dup` | initializes child leaf metadata, resolves existing child metadata, and increments `pt_inuse` for copied mappings |
| `hat_ptfree` | needs the base to remove list records and return the one-unit allocation |

If the `hat_sdtalloc(...,1)` call were simply omitted, `pp->p_ptdats` would be
null or stale. The managed branch of `hat_pt2ptdat` would then return an
invalid pointer, and byte updates at `+6/+7` would corrupt low or unrelated
memory.

Records one through three are inert in the current configuration because
`0x000b68a2` unconditionally skips the `free_pts` consumer. That does not make
the 64-byte allocator unit avoidable: `hat_sdtalloc`'s unit is 64 bytes, and
the one live record shares that unit with the three spare records.

### Requested reachability decisions

| Mechanism | Current verdict |
|---|---|
| old `free_pts` fragment reuse | linked but bypassed unconditionally at `0x000b68a2` |
| legacy `active_pts` steal | linked inside `hat_ptalloc`; no known live native caller permits it because all native calls pass `HAT_NOSTEAL`; keep it unreachable |
| stock `hat_exec` zero-flag allocation | public `hat_exec 0x000d8894` is a no-op, so this former steal entry is gone |
| stock `hat_swapout` | linked at `0x000b4360` and uses `ptdat`, but unreachable under the current replacement scheduler; it remains unsafe if re-enabled |
| `prfastmapin` / `prfastmapout` | active, but they walk native PTEs and hold/release `page_t.p_keepcnt`; they do not use `ptdat` or either list |
| native `hat_pageunload` | active reverse-map walker; does not use `ptdat` |
| native `hat_pagesync` | active reverse-map walker; does not use `ptdat` |

The three spare list records are therefore an avoidable design relic, but
record zero is required independently of the legacy steal/swapout paths.

### Possible later redesign

A native allocator could place one 16-byte record in unused space of every
whole 4 KiB table page and point `pp->p_ptdats` there, or allocate it from a
new one-record pool. That would eliminate the one-unit `hat_sdtalloc` debit and
the three free-list nodes.

It is not smaller than this teardown fix. It changes allocation, out-parameter
semantics, record initialization, `hat_pt2ptdat` provenance, list policy, and
freeing at once. The current measured issue needs only the already-proven
inverse of the retained allocation.

## Static implementation checklist

1. Pin or rederive the image before using the addresses above.
2. Globalize retained `hat_sdtfree`; do not weaken or replace it.
3. Preserve the current 4 KiB alignment and managed-PFN guards.
4. Replace the early `clrl pp@(32)` with an exact pre-mutation ownership gate.
5. Require `page_t.p_keepcnt == 1`, `p_ptbits == 1`, nonnull aligned
   `p_ptdats`, and `ptdat[0].pt_keepcnt == 0`.
6. Do not reject a stale nonzero `ptdat[0].pt_inuse` or null `pt_as`.
7. Validate all four links before modifying any if structural diagnostics are
   included.
8. Remove records `0..3` with the generic two-store `REMOVE_PT` sequence.
9. Clear `p_ptbits`, call `hat_sdtfree(base,1)`, then clear `p_ptdats`.
10. Perform the proven page hold `1 -> 0`, the existing three accounting
    updates, and `page_free(pp,0)` exactly once.
11. After successful publication, wake `&free_pts` if `pt_waiting != 0` and
    clear the counter.
12. On every exceptional path, leave holds, fields, lists, and accounting
    untouched and record the reason.
13. Keep old free-list reuse, old steal, public no-op `hat_exec`, and old
    `hat_swapout` reachability policy unchanged.

## Runtime acceptance

The implementation should satisfy both the measured ISSUE-40 discriminator
and the broader HAT regressions:

```text
300 x fork + exit
300 x fork + exec + exit
the existing 419-teardown ISSUE-40 workload
hat_dup_cow 1 / 32 / 256
copyback burst and power-cut disk-truth suites
```

Require:

- no one-page-per-dynamic-exec `availrmem` loss;
- no matching permanent `pages_pp_kernel` rise;
- every successful fresh table allocation eventually retires exactly one
  metadata unit and one table-page hold;
- no record from a freed array remains reachable from `active_pts` or
  `free_pts`;
- no double-unlink, bad-link, zero-hold, held-page, or locked-ptdat diagnostic;
- `pt_waiting` is zero after any exercised memory-pressure run;
- `hat_badaslot_n`, copyback release rejects, COW results, and disk truth stay
  clean.

The permanent `i40_*` counters continue to validate the earlier legacy-SDT
edge. They are useful corroboration, but `i40_pgfreed_n > 0` and a stopped
`i40_held_n` are not required for the later `ptdat` edge because of the call
ordering documented above.

The strongest allocator-family invariant after the already landed legacy-SDT
edge is:

```text
legacy SDT bits freed at AS teardown
+ all ptdat n=1 bits freed as table pages die
=> p_sdtbits reaches zero
=> hat_sdtfree executes the backing-page credit
```

## Closure

The measured ISSUE-40 page remains pinned because the native table-page free
discarded `pp->p_ptdats` without retiring its four list nodes or its one-unit
allocation. The minimum safe repair is the exact retained metadata inverse,
inserted behind a stronger native ownership gate:

```text
prove page hold 1 and unlocked metadata
REMOVE_PT four records
hat_sdtfree(base, 1)
clear table metadata fields
drop/finalize the table page
wake fresh-page waiters
```

Do not call the whole stock `hat_ptfree`, do not merely credit counters, and do
not remove the allocation while its first record remains a live native HAT
contract.
