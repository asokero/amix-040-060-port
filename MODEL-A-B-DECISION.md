# Where "Model B" comes from — the 2026-06-18 fork in the road

This records a decision the whole port has been living inside ever since, because the name turns up
in a dozen filenames (`patch_modelb.py`, `include-modelb/`, `mk_modelb_sysroot.sh`,
`z3660_modelb.py`, `patch_modelb_pager.py`) and nothing said in one place what it means.

**"Model A" and "Model B" are this project's own labels**, invented at one fork in the road on
2026-06-18. They are not standard terminology and you will not find them in any 68k or SVR4
literature. Primary source: `prototypes/hat-040-port-worklist.md`, lines ~296–460.

## The problem that created the fork

AMIX is built on **2 KiB pages**. The kernel's unit of memory is a *click* = 2048 bytes, and the
whole bookkeeping is built on it: `mlsetup` computes `maxclick = memsize >> 11`, `pages[]` is sized
in clicks, `btoc`/`ctob` convert in clicks, and page-table fields carry click numbers.

The 68030 MMU could be configured for 2 KiB pages. **The 68040 cannot** — its page size is fixed at
4 KiB (or 8 KiB), with no 2 KiB option. That single hardware fact is the root of the entire port,
and it forced a choice:

| | what it does | cost |
|---|---|---|
| **Model A** | keep the kernel's 2 KiB clicks; map two clicks into every 4 KiB MMU page | few edits, and **each function testable on its own** |
| **Model B** | move the page frame itself to 4 KiB: `NBPC`, `maxclick`, `pages[]`, `page_get`, PTE PFN shifts | estimated ~186 sites / 45 functions boot-critical, ~892 sites / 279 functions total |
| **Model C** (hybrid) | 4 KiB-granular allocator, but keep 2 KiB accounting | fewer sites than B, but **mixes two page sizes on purpose** |

The worklist's own note on B is worth quoting, because it was written before any of the work:
"the *correct* model real 040 ports use".

## Model A was built, and then disproved

This is the part worth remembering: **A was not argued down, it was measured down.**

Model A was implemented far enough to work end to end through `page_init` — the kvseg map,
`sysseginit` and `segkmem_mapin` all ported and running, visual console restored. The worklist calls
it "Huge", and it validated the `pstart040` scaffold and the whole override/relink machinery that the
port still uses today.

Then it hit a wall that no amount of care could move:

```text
kmem_allocspool -> sptalloc(..., phys=0, ...) -> segkmem_alloc -> page_get
```

`page_get` returns a **linked list of physically scattered 2 KiB clicks** and `segkmem_alloc` maps
them onto **2 KiB-packed consecutive virtual addresses**. On a 68040 that is impossible for two
independent reasons at once:

* a 4 KiB MMU page needs 4 KiB of *contiguous* physical memory — two scattered 2 KiB clicks cannot
  be made into one;
* the 040 forces 4 KiB granularity on the virtual side too — a 2 KiB-packed VA stream cannot be
  mapped at all.

So the kernel's page **allocator** being 2 KiB-granular is irreconcilable with 4 KiB MMU pages.
Model A works for pre-mapped and contiguous regions and fails structurally on the allocator path.
It was never a complete option; it only looked like one until the allocator was reached.

## Model C was considered and rejected in one word

The hybrid — 4 KiB-granular allocator, 2 KiB accounting kept — is recorded as "fewer sites but mixes
two page sizes, **fragile**". It was rejected on 2026-06-18 on that judgement alone, before any
evidence existed either way.

## The cost was recorded honestly at the time

The same note that chose B wrote down what B would cost:

> Model B is LESS incrementally testable than Model A: the page frame size is a global invariant
> (`maxclick` computed once in `mlsetup`, `pages[]` sized once); ported (4KB) and un-ported (2KB)
> functions on the same path disagree, so the core page-frame set must flip together-ish, then test.
> Model A allowed per-function test cadence; Model B is more big-batch.

That prediction was accurate, and the project paid it in full.

## What it actually cost, measured

Today's `relink-040.sh` applies **571 byte-patch sites** to build one kernel. The Model-B conversion
proper is the bulk of it:

```text
Model B Tier-0 (page frame + VM/mem core)          246 sites
Model B Tier-2 (pager / dir-read chain)            123 sites
Model B writeback / putpage group                   23 sites
per-issue geometry groups (kmapools 26, pagecreate 28, execboundary 21,
  memcntl 17, procio 15, ufsbmap 11, devmmap 7+, nfs 6, pvntrunc 2,
  sysconfig 1, …)                                  ~180 sites
```

Against the 2026-06-18 estimate of "~186 boot-critical / ~892 total": the total was in the right
order, but **the boot-critical half was underestimated by more than a factor of two** — Tier-0 alone
is 246. The remainder of the 892 is deliberately not converted (S5, RFS, parts of segdev, COFF core)
and is asserted as canaries so a stray conversion fails the build.

## The long tail, which is the real story

Nearly every defect this port has hunted since is a **Model-B residual**: one site that still thinks
a page is 2 KiB while its neighbour knows it is 4 KiB.

```text
ISSUE-13  bp_map/bp_mapout        ISSUE-31  ufs_bmap geometry
ISSUE-15  KMA pool page counts    ISSUE-32  ELF exec mapping boundary
ISSUE-17  procfs prfastmap        ISSUE-33  /dev/mem mmap PFN + segdev_incore
ISSUE-27  pagecreate tail-zero    ISSUE-35  nfs_putpage — silent NFS data loss
ISSUE-28  memcntl mlock bitmap    ISSUE-36  nfs_getpage — mmap SIGBUS on the last page
```

plus `sysconfig(_CONFIG_PAGESIZE)` reporting 2048 to user space, the VA2000 driver's `phystopfn`,
the Z3660 drivers' page counts, and the cross-compile header trap where every C file compiled into
the kernel silently got 2 KiB geometry because the toolchain's `-I` never took effect
(`MODELB-HEADERS-260801.md`).

Two of those — ISSUE-35 and ISSUE-36 — were **silent data corruption on the NFS path**. That is the
sharpest illustration of what a mixed page-size kernel costs: it compiles, links, boots, and loses
half of every page you write.

## Why the name is everywhere

It became a tag. Anything named `modelb` is about the 2 KiB → 4 KiB page-frame conversion:

```text
prototypes/patch_modelb.py          Tier-0 core conversion
prototypes/patch_modelb_pager.py    Tier-2 pager / dir-read chain
include-modelb/ + mk_modelb_sysroot.sh   4 KiB headers for anything compiled INTO the kernel
prototypes/check_page_geometry.sh   object-level assertion: no shift-by-11 survives
prototypes/va2000_modelb.py         same fix for the VA2000 driver source
prototypes/z3660_modelb.py          same fix for the two Z3660 driver sources
```

The last three exist because the invariant has to be enforced on *every* piece of code that enters
the kernel, including third-party drivers — and because a wrong page shift is invisible in
behaviour until it corrupts something, the checks are made on compiled bytes, never on source.

## Where to read more

* `prototypes/hat-040-port-worklist.md` — the original A-vs-B analysis, the wall, and the scope count
* `MODELB-HEADERS-260801.md` — the header half of the same invariant
* `KNOWN-ISSUES.md` — the residuals listed above, each with its own evidence
