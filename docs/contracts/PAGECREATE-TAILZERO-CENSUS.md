# `segmap_pagecreate` Tail-Zero Census

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/PAGECREATE-TAILZERO-CENSUS.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** This is the byte-provenance companion to
> `PAGECREATE-TAILZERO-SPEC.md`. Its reachable groups are now implemented by
> `src/patch_pagecreate.py` and ISSUE-27 is hardware-accepted; the addresses,
> object matches, exclusions, and S5 deferral below remain the patch census.

Status of this record: static analysis only. The later implementation status
is recorded above.

## Scope and provenance

The requested release image was pinned by the task brief as:

```text
build/unix-040
SHA-256 5bd37386d9c5a0f89be451b187fa5dfe9e4f05bcf2f1c37accdc22177a225b38
```

The ELF `.text` file-offset convention used by this repository is `+0x34`.
The stock bodies were also checked against the mounted AMIX `exp` objects:

| Function | AMIX object | Object SHA-256 | Result |
|---|---|---|---|
| `segmap_pagecreate`, `as_iolock` | `usr/sys/vm/exp` | `fdf33bc8e3dabcb16b0c1db22cb24954b3076dee83856e117a24206cfdb7cdf1` | exact stock body; pagecreate has four later 4 KiB edits |
| `fbzero` | `usr/sys/os/exp` | `79ebb30ce2e5ee689a8efc13a631978153ed5d8e4542d39ada0be6f637e0a1b8` | byte-identical |
| `spec_write` | `usr/sys/fs/specfs/exp` | `cb6373cc97d7cc6c8655787cc20c1020e180b878c8eb8a650e94789a2e7b366d` | byte-identical |
| `writei` | `usr/sys/fs/s5/exp` | `1c9cb6342da321047b6861170543382eaa75457573858fe641586ff6fddaf33e` | byte-identical |
| `rwip` | `usr/sys/fs/ufs/exp` | `a439e68f880d01450f156a0fd5886610c828d2a7cbdfdf3e8a28d93dd656273c` | byte-identical |
| `rwvp` | `usr/sys/fs/nfs/exp` | `bd5c7dcc9eaef7ec47bf49549c76098dc9081d77e8a53ce9b21725c87ecfa25d` | byte-identical |

The comparison is against the m68k ELF `.text` bytes, using the symbol start
and size from each object. This is stronger than a source resemblance claim.
The C references below explain the contracts; the `exp` object is the AMIX
byte provenance.

## Producer state

`segmap_pagecreate` is at `0x000a9722`, size `0x18e`.
It is already a 4 KiB producer:

| Address | Old stock bytes | Current bytes | Meaning |
|---:|---|---|---|
| `0xa9742` | `02 42 f8 00` | `02 42 f0 00` | align start with `& -4096` |
| `0xa97a0` | `48 78 08 00` | `48 78 10 00` | `page_get(4096, ...)` |
| `0xa9892` | `06 82 00 00 08 00` | `06 82 00 00 10 00` | next VA by 4096 |
| `0xa9898` | `06 84 00 00 08 00` | `06 84 00 00 10 00` | next vnode offset by 4096 |

The remaining body is stock AMIX `vm/exp`. It allocates or finds one page,
enters it, loads the HAT mapping, and uses `softlock` only for the HAT/page
hold contract. There is no page-list returned by this function.

## All five callers

| Caller and site | Object provenance | `softlock` | Tail-zero sites | Verdict |
|---|---|---:|---|---|
| `fbzero`, `0x3fa8a` | `os/exp`, `svr4-v4 os/fbio.c` | 1 | `0x3fa90`, `0x3fa96` | live UFS helper; independent fix |
| `spec_write`, `0x665f2` | `specfs/exp`, closest source `svr4-3b2 specvnops.c` | 0 | `0x6666c`, `0x66672`, `0x66688`, `0x6668e` | independent block-device fix |
| `writei`, `0x70cfa` | `s5/exp`; no available C source is exact | 0 | geometry sites below plus `0x70df4`, `0x70dfa`, `0x70e10`, `0x70e16` | dormant S5 hybrid; defer as a unit |
| `rwip`, `0x7f8ac` | `ufs/exp`, structurally `svr4-v4 ufs_vnops.c` | 0 | `0x7f9b6`, `0x7f9bc`, `0x7f9d6`, `0x7f9e0`, `0x7f9e6` | live root-UFS fix; coupled to `as_iolock` |
| `rwvp`, `0x88f28` | `nfs/exp`, structurally `svr4-v4 nfs_vnops.c` | 0 | `0x88fba`, `0x88fc0`, `0x88fd4`, `0x88fde`, `0x88fe4` | NFS fix; coupled to `as_iolock` |

`fbzero` is the only caller with `softlock=1`. Its `fbrelse` at
`0x3fab6` calls `as_fault(..., F_SOFTUNLOCK, ...)`; the existing
`segmap_unlock` path is already 4 KiB-stepped. The four other callers use
`softlock=0`, so their pagecreate calls do not create a softlock imbalance.

## Exact conversion sites

The following table gives the old instruction bytes and the intended same-size
replacement. The replacements change only VM-page geometry; no filesystem
block, sector, or segmap-slot constants belong in this set.

### `as_iolock`: 12 sites

`as_iolock` is `0x000aee34`, size `0x294`. Every entry below is currently 2 KiB.

| Address | Old bytes | New bytes | Role |
|---:|---|---|---|
| `0xaee6a` | `02 80 00 00 07 ff` | `02 80 00 00 0f ff` | input offset page-alignment test |
| `0xaeeba` | `02 46 f8 00` | `02 46 f0 00` | below-EOF trim |
| `0xaeece` | `02 42 f8 00` | `02 42 f0 00` | source VA page base |
| `0xaeed6` | `02 80 00 00 07 ff` | `02 80 00 00 0f ff` | source-page offset |
| `0xaeedc` | `26 3c 00 00 08 00` | `26 3c 00 00 10 00` | first-page copy length |
| `0xaef02` | `06 80 00 00 08 00` | `06 80 00 00 10 00` | page-end test |
| `0xaef10` | `06 80 ff ff f8 00` | `06 80 ff ff f0 00` | last-page length correction |
| `0xaefdc` | `48 78 08 00` | `48 78 10 00` | `VOP_GETPAGE` `plsz` |
| `0xaefe4` | `48 78 08 00` | `48 78 10 00` | `VOP_GETPAGE` `len` |
| `0xaf000` | `26 3c 00 00 08 00` | `26 3c 00 00 10 00` | loop copy length |
| `0xaf006` | `06 82 00 00 08 00` | `06 82 00 00 10 00` | loop source VA |
| `0xaf01c` | `02 80 00 00 07 ff` | `02 80 00 00 0f ff` | final `pagecreate` decision |

The source reference is `svr4-v4/usr/src/uts/i386/vm/vm_as.c:1060`.
AMIX's body is the `vm/exp` body, with the expected ABI/optimization details
(`segvn_ops` comparison and a NULL credential). The USL source is semantically
the same but passes `sys_cred`; it is not the best byte provenance.

### Tail-zero sites

For each `add #2047` / `and #-2048` pair, change the mask/rounding to
`+4095` / `&-4096`:

| Function | Address | Old bytes | New bytes |
|---|---:|---|---|
| `fbzero` | `0x3fa90` | `06 83 00 00 07 ff` | `06 83 00 00 0f ff` |
|  | `0x3fa96` | `02 43 f8 00` | `02 43 f0 00` |
| `spec_write` | `0x6666c` | `06 80 00 00 07 ff` | `06 80 00 00 0f ff` |
|  | `0x66672` | `02 40 f8 00` | `02 40 f0 00` |
|  | `0x66688` | `06 80 00 00 07 ff` | `06 80 00 00 0f ff` |
|  | `0x6668e` | `02 40 f8 00` | `02 40 f0 00` |
| `rwip` | `0x7f9b6` | `06 80 00 00 07 ff` | `06 80 00 00 0f ff` |
|  | `0x7f9bc` | `02 40 f8 00` | `02 40 f0 00` |
|  | `0x7f9d6` | `06 80 00 00 07 ff` | `06 80 00 00 0f ff` |
|  | `0x7f9e0` | `06 80 00 00 07 ff` | `06 80 00 00 0f ff` |
|  | `0x7f9e6` | `02 40 f8 00` | `02 40 f0 00` |
| `rwvp` | `0x88fba` | `06 80 00 00 07 ff` | `06 80 00 00 0f ff` |
|  | `0x88fc0` | `02 40 f8 00` | `02 40 f0 00` |
|  | `0x88fd4` | `06 80 00 00 07 ff` | `06 80 00 00 0f ff` |
|  | `0x88fde` | `06 80 00 00 07 ff` | `06 80 00 00 0f ff` |
|  | `0x88fe4` | `02 40 f8 00` | `02 40 f0 00` |

`writei` has a larger, separate geometry group:

| Addresses | Old form | New form | Role |
|---|---|---|---|
| `0x70bd6`, `0x70bee`, `0x70bfa`, `0x70c24`, `0x70c84`, `0x70c90` | `and #2047` | `and #4095` | S5 pagecreate tests |
| `0x70c5c`, `0x70cc8` | `moveq #11` | `moveq #12` | user-page probe stride |
| `0x70c70`, `0x70cdc` | `add #2048` | `add #4096` | user-page probe stride |
| `0x70df4`, `0x70e10` | `add #2047` | `add #4095` | tail rounding |
| `0x70dfa`, `0x70e16` | `and #-2048` | `and #-4096` | tail rounding |

## False friends and deliberate exclusions

These constants are not VM-page constants in this family:

| Pattern | Meaning | Action |
|---|---|---|
| `MAXBSIZE` `0x2000`, `0x1fff`, `&-0x2000` | 8 KiB segmap/UFS block window | keep |
| `0x2000` and `0x1fff` in block-size comparisons | UFS block geometry | keep |
| `vfs_bshift`, `>>9`, `0x200`, `NBPSCTR` | S5 sectors/fragments | keep |
| `segmap` slot mask/stride `0x2000` | 8 KiB kernel mapping slot | keep |
| `ufs_bmap` `PAGESIZE` uses | separate UFS allocation/provider census | do not fold into this patch blindly |

The live root filesystem has `fs_bsize=8192`, `fs_fsize=1024`, `fs_frag=8`.
Therefore the S5 `bsize < PAGESIZE` hole-marking branch from later SVR4
source is not a live UFS branch. It must not be inferred from a matching
constant.

## Provenance conclusions

- `as_iolock`, `rwip`, and `rwvp` are the later SVR4 family represented by
  `svr4-v4`; the mounted AMIX `exp` objects prove the actual AMIX bytes.
- `fbzero` is the common `fbio.c` helper; both `svr4-3b2` and `svr4-v4`
  contain the same contract, with v4's four-argument ABI closer to AMIX.
- `spec_write` is closer to the old 3B2 implementation: current AMIX has no
  `as_iolock` call and uses the 4-argument pagecreate ABI. The v4 source,
  which adds `as_iolock`, is the wrong patch template.
- `writei` is a real AMIX hybrid. It is byte-identical to `s5/exp`, but none
  of the available C sources is an exact semantic match: current AMIX probes
  source pages with `fubyte`, calls `segmap_pagecreate` before `bmapalloc`,
  and has a later partial-write path.
