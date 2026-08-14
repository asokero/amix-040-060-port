# NFS read-side ISSUE-36 site analysis

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/NFS-READSIDE-ISSUE36-SITE.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** The minimum four-site unit derived here
> is implemented by `src/patch_nfs_getpage.py`. ISSUE-36 is closed by a
> real-hardware A/B: the 2048-byte final-page remainder fails on the control,
> the 2049-byte remainder passes, and the repaired image also preserves the
> full past-EOF zeroing and page-list contract. See
> `docs/REALHW-ISSUE36-260728.md`.

## Verdict

The hard SIGBUS has one direct producer:

```text
nfs_getpage+0xe6, 0x0008b6ba
    rp->r_size + 0x7ff
```

The stale `PAGEOFFSET` makes `nfs_getpage` return `EFAULT` before
`nfs_getapage` runs. `segvn_fault` converts that errno to
`FC_MAKE_ERR(EFAULT)`, which is `0x0e05`; the user fault path reports SIGBUS.

One instruction is therefore enough to stop the reported `+123` SIGBUS.
It is not a safe standalone repair. The minimum safe demand-page repair is
four instructions:

```text
0x8b6ba  EOF PAGEOFFSET
0x8b26c  returned-page countdown
0x8b282  primary io_len round-up add
0x8b288  primary io_len alignment mask
```

This four-site unit permits the final 4 KiB page, returns no more pages than
the caller capacity describes, and submits enough I/O to initialize every
byte of every allocated 4 KiB page. The other nine sites are genuine
Model-B residuals, but none produces this hard failure.

## Pin

```text
kernel repository HEAD at task issue     288c011
task's kernel build commit               582ef71
build/unix-040                           68040-260727-07
ELF SHA-256                              5df4158bc548803515334f02ab2607e21f8c0e27d3b48b4fa236117e4e68eaba
.text SHA-256                            f6faa8178d9ba02a6a15c47da1eb52cfebcf6c7ca7ecc47e41e75781ddd14c63
.text file offset                        0x34
.text size                               0x0e4010
```

The task commit adds documentation only. Relative to the previously pinned
image, the three stated immediate-byte changes are present and no function
address moved.

Relevant current symbols:

| Function | Address | Size |
|---|---:|---:|
| `execmap` | `0x00057a4c` | `0x288` |
| `nfs_getapage` | `0x0008b14c` | `0x488` |
| `nfs_getpage` | `0x0008b5d4` | `0x214` |
| `nfs_map` | `0x0008baf6` | `0xd4` |
| `segvn_fault` | `0x000ac434` | `0x40e` |
| `pvn_kluster` | `0x000b17f0` | `0x1de` |
| `pvn_getpages` | `0x000b25da` | `0x10c` |
| `mapelfexec` | `0x000b85f0` | `0x168` |

The behavioral source anchors are:

```text
svr4-src-3b2/usr/src/uts/3b2/fs/nfs/nfs_vnops.c
svr4-src-3b2/usr/src/uts/3b2/vm/vm_pvn.c
svr4-src-3b2/usr/src/uts/3b2/vm/seg_vn.c
svr4-src-3b2/usr/src/uts/3b2/os/exec.c
svr4-src-3b2/usr/src/uts/3b2/exec/elf/elf.c
```

Addresses and bytes below come from the pinned linked ELF, not from source
layout inference.

## Fault-code confirmation

The installed AMIX `vm/faultcode.h:26..27` assigns object errors the low-byte
class value `5` and constructs an object fault by shifting the errno left by
eight bits before combining it with that class.

Therefore:

```text
FC_MAKE_ERR(EFAULT)
= (14 << 8) | 5
= 0x0e05
```

The runtime `ret=E05` reading is correct. The same installed headers define
`F_INVAL == 0` and `S_READ == 1`, so the probe's `type=0 rw=1` is an invalid
translation caused by a read access, not a write.

## Direct failure

The current `nfs_getpage` body implements:

```text
0x8b6b2  d0 = off
0x8b6b4  d0 += len
0x8b6b6  d1 = rp->r_size
0x8b6ba  d1 += 2047
0x8b6c2  compare d1 with d0
0x8b6c4  branch to provider if d1 >= d0
0x8b6c8  also allow segkmap
...
0x8b726  return EFAULT
```

For an ordinary one-page `segvn` fault:

```text
off = floor(fault_file_offset / 4096) * 4096
len = 4096
```

Let `r = file_size mod 4096`, with `1 <= r <= 4095`. The old gate accepts
the last page only when:

```text
off + 4096 <= file_size + 2047
4096 <= r + 2047
r >= 2049
```

The exact static predicate is therefore:

```text
r == 0           full final page: accepted
r in 1..2048     partial final page: rejected with EFAULT
r in 2049..4095  partial final page: accepted
```

The two observed `+123` cases are in the rejected range. The current evidence
does not establish that every non-page-multiple size fails; the binary proves
that upper-half remainders are already accepted. A boundary test should add
remainders `1`, `2048`, `2049`, and `4095`.

No `nfs_getapage` instruction executes on the rejected path. Thus
`0x8b6ba`, not the dispatch comparison or `io_len` arithmetic, directly
produces the logged EFAULT and SIGBUS.

## Why the one-site fix is unsafe

### Incomplete page initialization

For a file ending 123 bytes into a fresh NFS block, converted
`pvn_kluster` does this correctly:

```text
raw io_len                 123
allocated page bytes       roundup(123, 4096) = 4096
```

The provider then applies its old primary round-up:

```text
(123 + 2047) & -2048 = 2048
```

That 2048 becomes `bp->b_bcount`. `do_bio` reads 123 bytes and zeros only
the `2048 - 123` residual bytes. Current `pvn_done` advances its completion
walk by 4096, so it marks the whole 4 KiB page complete although bytes
`2048..4095` were never initialized by this I/O.

This violates the source's explicit requirement that EOF page-in initialize
the entire page to zero. The primary `io_len` add and mask must therefore
land with the EOF allowance:

```text
(123 + 4095) & -4096 = 4096
```

The same mismatch appears when a partial 8 KiB NFS block contains two 4 KiB
pages: an old 6144-byte request can complete an 8192-byte page list.

### Page-list return contract

The earlier shorthand "`pvn_getpages` passes `plsz=4096`" is true for a
non-final iteration, but it is not universally true in this linked body.
Current `pvn_getpages` does:

```text
0xb25f8  default provider plsz = 4096
0xb260c  test whether this is the last requested page
0xb261a  on the last page, use caller_plsz - bytes_already_returned
```

Consequently a normal single-page `segvn_fault` supplies its remaining local
capacity, 16384 bytes, to `nfs_getapage`. Other live callers can supply 8192
or 4096.

With an 8 KiB cluster, the current `0x8b26c` subtraction interprets each
returned 4 KiB `page_t` as only 2048 bytes:

```text
raw cluster pages          A, B
sz = 8192
old returned pointers      A, B, A, B, NULL
correct returned pointers  A, B, NULL
```

For `plsz=4096`, the old code can return two pointers plus NULL where one
pointer plus NULL is allowed. For a larger physical array this may not smash
the stack immediately, but duplicate pointers, duplicate holds, overwritten
list entries on a following iteration, and unbalanced release ownership
remain possible.

This matters to the EOF repair. For a cold tail-first fault in a file whose
last 8 KiB block contains `4096+123` bytes, `pvn_kluster` may scan backward
and return both physical pages. The old EOF gate currently masks part of
that input range. Relaxing the gate without correcting `0x8b26c` can expose
the malformed return list on a newly admitted fault.

Changing the countdown to 4096 makes both cases correct:

```text
plsz < io_len   return exactly plsz / 4096 requested pages
plsz >= io_len  return exactly ceil(io_len / 4096) cluster pages
```

## Minimum safe atomic unit

All four old forms should be verified before any replacement is written.

| Address | Assert old bytes | Replacement bytes | Contract |
|---:|---|---|---|
| `0x8b6ba` | `06 81 00 00 07 ff` | `06 81 00 00 0f ff` | `rp->r_size + PAGEOFFSET` |
| `0x8b26c` | `06 ae ff ff f8 00 ff ec` | `06 ae ff ff f0 00 ff ec` | `sz -= PAGESIZE` |
| `0x8b282` | `06 80 00 00 07 ff` | `06 80 00 00 0f ff` | primary `btopr(io_len)` add |
| `0x8b288` | `02 40 f8 00` | `02 40 f0 00` | primary `ptob()` mask |

Half states are invalid:

- EOF only admits a page whose upper half can remain uninitialized.
- EOF plus I/O rounding can admit a two-page cluster whose return list is
  still malformed.
- Countdown or I/O rounding without EOF does not repair the reported hard
  failure.

The four sites are the minimum safe repair for demand faults at the final
file page. They are not a claim that the remaining provider residuals are
correct.

## Classification of all 13 sites

The instruction-start corrections `0x8b406` and `0x8b46c` are used below.
Earlier notes sometimes named the preceding moves at `0x8b402` and
`0x8b468`.

| Site | Current bytes or immediate | Role | ISSUE-36 minimum |
|---:|---|---|---|
| `0x8b1c0` | `06 80 ff ff f8 00` | synthesize one page beyond EOF for `segkmap`; not an in-file user fault | no |
| `0x8b26c` | `06 ae ff ff f8 00 ff ec` | returned-page countdown | **yes** |
| `0x8b282` | `06 80 00 00 07 ff` | primary I/O round add | **yes** |
| `0x8b288` | `02 40 f8 00` | primary I/O mask | **yes** |
| `0x8b360` | `06 80 00 00 07 ff` | primary statistics round add | no, accounting only |
| `0x8b366` | `7a 0b` | primary statistics shift | no, accounting only |
| `0x8b406` | `06 80 00 00 07 ff` | asynchronous read-ahead I/O round add | no, separate correctness site |
| `0x8b40c` | `02 40 f8 00` | asynchronous read-ahead I/O mask | no, separate correctness site |
| `0x8b46c` | `06 80 00 00 07 ff` | read-ahead statistics add | no, accounting only |
| `0x8b472` | `7a 0b` | read-ahead statistics shift | no, accounting only |
| `0x8b50c` | `06 85 00 00 08 00` | resident-hit `r_nextr` page advance | no, read-ahead policy |
| `0x8b6ba` | `06 81 00 00 07 ff` | EOF allowance | **yes, direct failure** |
| `0x8b72c` | `0c 84 00 00 08 00` | direct-provider versus `pvn_getpages` dispatch | no |

`0x8b72c` should eventually compare with 4096 to restore the source's
one-page dispatch. It is safe to leave at 2048 in the minimum repair because
both branches reach `nfs_getapage` and current `pvn_getpages` iterates in
4 KiB units. If it is converted now, it must not be converted without
`0x8b26c`: direct dispatch exposes the caller's larger page-list capacity to
the stale countdown.

The read-ahead I/O pair remains a real data-initialization residual, but the
last partial NFS block cannot satisfy the read-ahead loop condition
`blkoff + bsize < r_size`. It does not produce ISSUE-36.

## Relationship to the `pl[]` defect

ISSUE-36 and the return-list defect are independent consequences of the same
stale page geometry:

- `0x8b6ba` rejects the request before page allocation.
- `0x8b26c` misdescribes pages after `pvn_kluster` succeeds.

The reported `+123` fault itself does not exercise the return-list defect:
raw `io_len=123`, so even the old countdown emits one pointer. The defect is
already reachable on full 8 KiB clusters and can also be newly exposed by
the EOF repair on the second page of a partial NFS block.

The four-site minimum closes that newly exposed path. It does not close
read-ahead geometry, statistics, the resident `r_nextr` update, or the
one-page dispatch policy.

A deterministic user-space data mismatch is not guaranteed for the old
return list. The RPC may fill every physical page correctly, and the reviewed
`segvn` and `segmap` local arrays have enough physical slots to hide a small
over-return. Multi-iteration callers can nevertheless overwrite an
extra-held pointer and leak its hold. The provider probe remains the reliable
detector:

```text
log io_len, plsz, count, every pointer and p_offset
require count <= ceil(plsz / 4096)
require every returned pointer to be distinct
require every PAGE_HOLD to have one release
```

Run the probe once on the old body to prove the violation and again after the
four-site unit to prove the demand-path closure. A black-box checksum alone
cannot replace it.

## NFS exec reachability

Normal ELF execution can reach this exact provider:

```text
elfexec
  -> mapelfexec @0xb85f0
  -> execmap @0x57a4c
  -> vnode VOP_MAP
  -> nfs_map @0x8baf6
  -> as_map(segvn_create)
  -> segvn_fault @0xac434
  -> VOP_GETPAGE
  -> nfs_getpage @0x8b5d4
```

`execmap` takes the mapped path when file offset and virtual address have
matching page offsets and the vnode is mappable. That is the normal ELF
`PT_LOAD` layout. Its fallback is a zfod mapping plus `vn_rdwr`; that fallback
does not use `nfs_getpage`.

The severity needs one correction: an ELF segment's partial last page is not
by itself enough. `nfs_getpage` compares against the whole vnode size, not
`p_filesz`. A segment is exposed when its last mapped file page begins within
2048 bytes of the executable vnode's EOF. Trailing ELF data can therefore
mask the defect.

A bounded scan of readable executable m68k ELF paths under the mounted
vanilla `bin`, `sbin`, `etc`, `usr/bin`, `usr/sbin`, and `usr/lib` trees used
this predicate for every nonempty `PT_LOAD`:

```text
last_page = floor((p_offset + p_filesz - 1) / 4096) * 4096
1 <= st_size - last_page <= 2048
```

Result:

```text
readable executable ELF paths scanned     524
paths with at least one exposed PT_LOAD    85
```

Examples include `/sbin/su`, `/sbin/uname`, `/usr/bin/ls`,
`/usr/bin/mkdir`, `/usr/bin/ps`, and `/usr/sbin/crash`. This is a static
potential-fault census, not proof that every listed last page is touched in
one run. It does prove that NFS execution is not merely hypothetical.

If `PREREAD` runs, `execmap` ignores its `as_fault` return; otherwise the
fault occurs on demand. In either case a later instruction or data access can
receive the same object EFAULT and SIGBUS. The acceptance suite should
therefore copy at least one exposed installed binary to NFS under a unique
name, execute it cold, and exercise its data path.

## Acceptance

Use the four-site unit as one fail-closed patch and require:

1. Old image: cold mmap tail faults fail for page remainders `1` and `2048`,
   while `2049` and `4095` establish the predicted old-boundary controls.
2. New image: remainders `1`, `2048`, `2049`, and `4095` all return correct
   server-derived bytes without SIGBUS.
3. First-touch the tail before earlier pages in a cold file of size
   `8192*N + 4096 + 123`; run the page-list probe to exercise backward
   clustering.
4. Require full-page zero initialization after EOF, not only successful
   access to `sz-1`.
5. Run one exposed ELF directly from NFS and one non-exposed ELF as control.
6. Retain the existing 3 MB NFS-to-local checksum and ISSUE-35 server-truth
   writeback test as regressions.

The final 13-site provider conversion should still receive its own
read-ahead and accounting review. It is not required as the atomic repair for
ISSUE-36.
