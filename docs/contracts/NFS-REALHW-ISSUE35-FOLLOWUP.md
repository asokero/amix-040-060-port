# NFS Real-Hardware ISSUE-35 Follow-up

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/NFS-REALHW-ISSUE35-FOLLOWUP.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** The two-instruction atomic unit identified
> here is implemented by `src/patch_nfs_putpage.py`. ISSUE-35 is fixed and was
> verified byte-for-byte from the NFS server side on 68040 hardware; the
> remaining four provider sites stay asserted as deliberate canaries for the
> measured 8 KiB mount contract.

## Scope and pin

This note answers Q1-Q3 from `REALHW-REPORT-FOR-CODEX-260727.md`. It
identifies the smallest `nfs_putpage` unit that explains the real-hardware
short file, settles stock attribution, and states the corresponding read-side
proof obligation. It does not modify the kernel.

For the proven 8 KiB-mount failure, this supersedes the earlier statement
that all six `nfs_putpage` sites must be the first atomic patch. It does not
remove any site from the complete final provider conversion.

The hardware report ran:

- base build `68040-260726-01`;
- base `build/unix-040` SHA-256
  `767ea9a0b904752701f3d49d8df9bba55fe46bbadbc70da95c8001b0e22540fb`;
- base `.text` SHA-256
  `9b49c77a59d3b77effab6c1847a0f6633200f7ce0f0600d3f696e6ce41ac4111`;
- debug build `68040-260727-01`, consisting of that base plus diagnostics.

The source tree advanced after the report. At tree HEAD
`47ee1af4f76052009cc1853e95f67f763c9c75db`, the rebuilt image SHA-256 is
`89d1312bf7d1bc69d1e4d1d8fa095d09ad92062c1e75b1e685b4341637db0f06`.
That change patches only `sysconfig`; the NFS function and addresses below
are unchanged.

## Hardware observation

For foreground copies to an 8 KiB-block NFS mount:

```text
requested  stored   visible loss
8192       6144     2048
16384      14336    2048
24576      22528    2048
32768      30720    2048
4194304    4192256  2048
```

Lengths whose final foreground chunk is not a full 8192 bytes reported their
nominal size, including 12288. That result does not prove their interior
content correct.

## Q1: producer and minimum patch

### Complete six-site group

`nfs_putpage` is at `0x8b7e8`:

| Site | Current instruction | Source meaning |
|---|---|---|
| `0x8b84e` | compare `vfs_bsize` with `0x7ff` | `MAX(vfs_bsize, PAGESIZE)` gate |
| `0x8b85a` | local minimum `0x800` | fallback `PAGESIZE` |
| `0x8b916` | add `0x7ff` | round file size |
| `0x8b91c` | mask `0xf800` | rounded file boundary |
| `0x8b9de` | `io_len = 0x800` | first dirty page length |
| `0x8ba2c` | `io_len += 0x800` | add one contiguous dirty page |

All six are genuine page-geometry sites. They remain the complete eventual
conversion unit, but only the final pair produces ISSUE-35 on the reported
8 KiB mount.

### Why the first four do not produce this observation

The mount has `vfs_bsize = 0x2000`, so both old and new forms of the first
pair select 8192.

At an exact 4 KiB or 8 KiB file boundary, the old and new file-size rounding
pair produce the same byte boundary. The `len == 0` whole-vnode branch does
not use that pair at all. These four sites are therefore not needed to change
the observed result.

### The exact failing loop

Common `pvn_range_dirty` now returns pages at 4 KiB offsets. The stock loop
still starts with:

```text
io_off = first_page->p_offset
io_len = 2048

while next_page->p_offset == io_off + io_len:
        add next page
        io_len += 2048
```

For pages at offsets 0 and 4096, the first comparison asks whether the next
offset is 2048. It therefore submits each 4 KiB page as only a 2 KiB write.
For a page at offset 4096, the RPC reaches only offset 6144, which exactly
explains the 8192 -> 6144 result.

`rwvp` processes foreground writes in 8192-byte `MAXBSIZE` slots. A full slot
is released through asynchronous putpage. A partial final slot takes a
different foreground/release schedule and can extend the reported server EOF
to the nominal length. That explains the exact-multiple predicate without
making the defect block-sized internally.

In particular, `12288` reporting the right size does not clear its first
8192 bytes. The first full slot can still have unwritten upper halves. The
next acceptance run must compare bytes, not only `st_size` or a same-client
read.

### Minimal atomic unit

The smallest safe patch is exactly two instructions:

| Site | Assert old bytes | New bytes | Change |
|---|---|---|---|
| `0x8b9de` | `26 3c 00 00 08 00` | `26 3c 00 00 10 00` | initialize `io_len` to 4096 |
| `0x8ba2c` | `06 83 00 00 08 00` | `06 83 00 00 10 00` | grow `io_len` by 4096 |

The sites must land together:

- changing only `0x8ba2c` has no effect because the 2048-byte initial
  comparison never admits the second page;
- changing only `0x8b9de` admits the second page but then describes two 4 KiB
  pages as 6144 bytes.

After both changes, two pages in one NFS block produce `io_len = 8192`, and
the existing block-boundary clipping remains correct.

### Acceptance

The existing one-line size sweep is a valid negative control, but the
acceptance test must add server-side byte truth:

1. generate an absolute-offset-derived nonzero pattern across every 512-byte
   region;
2. copy lengths 8192, 12288, 16384, and `16384+123`;
3. sync and verify from the server or an independent client;
4. compare every byte, especially each page's
   `+0x7ff/+0x800/+0xfff` boundary;
5. require exact size and exact content.

The old image must fail at least 8192 and the patched image must pass all
lengths.

## Q2: stock attribution

The complete `nfs_putpage` body, `0x8b7e8..0x8baf5` inclusive, is byte
identical between:

- mounted stock `/vanilla/stand/unix`; and
- the current linked 040 image after the unrelated `sysconfig` patch.

The 782-byte function slice has SHA-256:

```text
18c4003317ca8df3907087f4781759b857cf6cbb723f1581b5bb2cdfe15a94ce
```

The 3B2 source expresses the same loop with `PAGESIZE` and page offsets. In
the stock 030 kernel, `page_t` offsets advance by 2048 and `io_len` advances
by 2048. Four pages can therefore be coalesced into one 8192-byte NFS block.
The body is correct in its original 2 KiB environment.

ISSUE-35 is therefore a Model-B mixed-geometry regression: the common dirty
page producer was converted to 4 KiB, while the byte-identical NFS consumer
retained 2 KiB.

## Q3: read-side counterpart

### Static verdict

The 13-site `nfs_getapage`/`nfs_getpage` group remains genuine. The lower
`nfs_strategy -> do_bio -> nfsread -> XDR` path is byte-count based and adds
no hidden page constant.

The strongest live defect is not necessarily wrong RPC data. It is the page
return-list capacity calculation:

```text
pvn_getpages provider plsz = 4096
nfs_getapage @0x8b26c: sz -= 2048 for each returned page_t *
```

An 8 KiB cluster can contain two 4 KiB pages. The provider can therefore
write two page pointers plus the terminator into capacity intended for one
page. This violates the provider contract and can overrun a small caller
array even when the RPC filled both pages with correct bytes.

Other old sites affect EOF allowance, direct-versus-multipage dispatch,
read-ahead position, and statistics. Since they share the provider geometry,
`nfs_getapage` plus `nfs_getpage` remains one 13-site implementation unit.

### Discriminating test

Use both data truth and an invariant probe:

1. create unique cold server files with absolute-offset-derived patterns and
   lengths 8192, `8192+123`, 12288, and `16384+123`;
2. copy and mmap-read them from AMIX, first-touching pages in nonsequential
   order;
3. compare every byte at 2 KiB, 4 KiB, 8 KiB, and EOF boundaries;
4. temporarily log `io_len`, `plsz`, returned pointer count, each pointer,
   and each `p_offset` where `nfs_getapage` constructs `pl[]`;
5. require distinct pointers,
   `count <= ceil(plsz / 4096)`, and balanced holds/releases.

Unique file names or a remount are needed to avoid a warm client page cache.
`mincore`, `st_size`, and a same-client checksum alone do not test this
contract.

## Final verdict

1. ISSUE-35 is produced by `0x8b9de` and `0x8ba2c`.
2. Those two instructions are the minimum atomic repair for the proven 8 KiB
   NFS workload.
3. The full six sites remain the correct final `nfs_putpage` conversion.
4. The stock body is correct with 2 KiB pages; the failure is a Model-B
   regression.
5. The read side has a concrete page-list-capacity violation and should be
   tested next with provider instrumentation plus a cold patterned read.
