# TASK for Codex: which of the 13 read-side sites produces ISSUE-36?

Requested deliverable: an analysis note in `amix-kernel-analysis/vm-map/`, suggested name
`NFS-READSIDE-ISSUE36-SITE.md`. Do not patch the kernel.

**One question dominates: WHICH SITE.** The rest is context and secondary asks.

## Why this is worth your time rather than ours

Your ISSUE-35 answer turned a proven data-loss bug into a **two-instruction** fix instead of a
blind six-site conversion, and it settled attribution from the binary so we did not have to boot
the 030 kernel. That saved a hardware session and it made the patch reviewable. This is the same
shape of question: we have a proven, reproducible, hard failure and a 13-site candidate unit, and
we would rather convert the minimum than the group.

## Provenance — the base MOVED since your last pin

```text
kernel HEAD    af40f2b
build/unix-040 68040-260727-07
               sha256  5df4158bc548803515334f02ab2607e21f8c0e27d3b48b4fa236117e4e68eaba
.text          sha256  f6faa8178d9ba02a6a15c47da1eb52cfebcf6c7ca7ecc47e41e75781ddd14c63
dbg overlay    68040-260727-08  (the kernel all results below were produced on)
```

Relative to the image you pinned (`68040-260726-01`, `767ea9a0…`) **exactly three text bytes
differ**, all of them immediates we changed on your analysis or on top of it:

```text
text 0x44e80   08 -> 10    sysconfig _CONFIG_PAGESIZE 2048 -> 4096   (your five-site list, site 1 only)
text 0x8b9e2   08 -> 10    ISSUE-35 nfs_putpage io_len  = PAGESIZE
text 0x8ba30   08 -> 10    ISSUE-35 nfs_putpage io_len += PAGESIZE
```

Byte patches do not move `.text`, so **every address in your read-side census still resolves**.
Nothing else in `nfs_putpage`'s six-site group was touched; the other four remain unconverted
and are asserted as canaries by `src/patch_nfs_putpage.py`.

ISSUE-35 is closed and verified on hardware, before/after, byte-compared from the server side:
6/6 files bad on 260727-01, 6/6 clean on 260727-08. Your prediction that the group would yield
a server-verifiable data-loss test was right. One correction we owe you in return: the defect
was **worse than we characterised it** — the upper 2 KiB half of EVERY 4 KiB page was unwritten,
not just the last 2048 bytes. Our original size sweep used `dd bs=1`, one byte per `write()`, so
the clustering loop never accumulated and a 2 KiB `io_len` happened to suffice. Your warning that
a right size does not clear the earlier bytes was correct in a stronger sense than either of us
stated.

## The finding: ISSUE-36

Touching a byte in the last **PARTIAL** page of an `mmap`'d NFS file raises **SIGBUS**.

```text
file    fs    length         mmap tail touch        exit
8192    NFS   2 x 4096       p[8191]   OK             0
12288   NFS   3 x 4096       p[12287]  OK             0
8315    NFS   8192 + 123     p[8314]   BUS ERROR    138
16507   NFS   16384 + 123    p[16506]  BUS ERROR    138
8315    UFS   8192 + 123     p[8314]   OK             0     <- local control
8315    NFS   read() / sum                            0     <- RPC path is fine
```

Predicate: **the file length is not a multiple of 4096.** The failing access is INSIDE the
file, at byte `sz-1` of `sz`. Minimal repro is `test-tools/rdmin.c` — open, `mmap(sz, PROT_READ,
MAP_PRIVATE)`, touch `p[0]`, `p[4096]`, `p[sz-1]`, nothing else.

Coldness was arranged deliberately: the files were written **by the host** through SMB, with a
per-run unique name tag, and only ever READ by AMIX. So no client page cache masking.

Kernel side, from the dbg probes:

```text
DBG as_fault FAIL pid=208 addr=C103507A type=0 rw=1 ret=E05
NOTICE: User BUS ERROR at C103507A, PC:800007C6 FAULT:5 PID:208
DBG SIG sig=10 pid=208 ... kcaller=804858C fu=0
DBG as_fault FAIL pid=208 addr=C1035000 type=0 rw=1 ret=E05
```

**A correction so you do not inherit our error:** we first read `0xC1xxxxxx` as libc (earlier
STREAM probes show user PCs in that range) and `rw=1` as a write, i.e. as a bug in our own test
program. Both readings were wrong. `mmap` returned `p = 0xc1033000`, and
`0xC103507A - 0xC1033000 = 0x207A = 8314 = p[sz-1]` exactly — the faulting address IS the
mapping's last byte, and `rw=1` does not mean "write" in this probe. `ret=0xE05` we read as
`FC_MAKE_ERR(14)`, i.e. the fault resolver returning EFAULT: **the page-in FAILS, the access is
not illegal.** Please confirm or correct that reading of `ret`.

## Q1 (the question): which site?

Your `NFS-REALHW-ISSUE35-FOLLOWUP.md` describes the read side as one 13-site
`nfs_getapage`/`nfs_getpage` unit and notes the sites cover, among other things, **EOF
allowance**, direct-versus-multipage dispatch, read-ahead position, and statistics.

1. **Which site or sites produce this SIGBUS?** Our hypothesis is the EOF-allowance
   computation: a page-in for a file's last page must be permitted although the file ends
   mid-page, and computing that allowance with 2 KiB geometry against a 4 KiB page refuses the
   request. Confirm, refute, or name the actual one.
2. **Is there a minimum atomic subset**, as there was for ISSUE-35 (2 of 6)? If the answer is
   "these two, and the other eleven are a later unit", that is exactly what we want. If the
   answer is "no smaller unit is safe here", say so and say why — a mixed state that is worse
   than either endpoint is the shape that has bitten this project repeatedly and we will treat
   the 13 as one commit.
3. **Give the assert-old-bytes for whatever you name**, against the pin above. Every patch in
   this repo asserts old bytes and fails closed, and having them from you removes a
   re-derivation step and a chance for us to get it wrong.

## Q2: does `exec` from an NFS mount hit the same path?

Untested by us and potentially serious: `exec` maps text and data, and **every** binary's last
page is partial. If the ELF exec mapping path reaches the same `nfs_getapage` EOF allowance,
then running programs from an NFS mount is affected too, not just explicit `mmap`. That would
change ISSUE-36 from "mmap of NFS files does not work" to "NFS is not usable as a program
source". Answerable statically from the exec/`segvn`/`VOP_GETPAGE` chain.

## Q3: does ISSUE-36 coexist with the `pl[]` capacity violation, or subsume it?

Your ranked-strongest read-side defect was the page-list capacity contract:

```text
pvn_getpages provider plsz = 4096
nfs_getapage @0x8b26c: sz -= 2048 per returned page_t *
```

That is **still unverified** — it needs the kernel-side probe (log `io_len`, `plsz`, pointer
count, each pointer, each `p_offset`; require distinct pointers, `count <= ceil(plsz/4096)`,
balanced holds/releases) and we did not build it. What we would like to know before building it:

1. Are ISSUE-36 and the `pl[]` violation **the same root arithmetic** seen from two ends, or two
   independent defects in the same function?
2. If we fix whatever Q1 names, does the `pl[]` overrun remain? A fix that stops the SIGBUS while
   leaving a caller-array overrun in place would be worse than the current state, because it
   converts a hard, visible failure into a silent one. **This is the question that decides
   whether the minimum subset is safe to land at all.**
3. Is the `pl[]` overrun observable from user space by any means, or does it genuinely require
   the probe?

## What makes a good answer

1. **Q1 with byte-exact sites**, in the form you gave for ISSUE-35 — that answer was directly
   usable and it is the reason that fix was two instructions.
2. **Q3.2 answered explicitly.** If fixing the SIGBUS unmasks a silent overrun, we want to know
   before we land anything, not after.
3. **Say if the minimum is the whole 13.** That is a fine answer; we just want it stated rather
   than discovered.
4. Classification over matching, as usual. The read side's constants include EOF allowances,
   read-ahead positions and statistics, and only some of those are geometry.

## Context on what else changed

* `sysconfig` now reports 4096 (site 1 of your public five). The other four remain untouched and
  still admit 2048-aligned addresses; that stays a deliberate compatibility decision, and
  `test-tools/devmaptest.c` T1 still deliberately encodes the current behaviour.
* ISSUE-29: your correction landed — the logged `kmem_zalloc+0x18` is the detector, not the
  corruptor, and all `8/6` sightings hit the same 128-byte class. We have since seen a sixth
  sighting on hardware. Not chased.
* The full 040 line is hardware-accepted, including power-cut disk truth 8/8:
  `test-tools/realhw-verify-260727.txt`.
