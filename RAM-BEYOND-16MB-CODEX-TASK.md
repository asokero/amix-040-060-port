# Task — how much RAM can this AMIX actually use, and what stops it using the rest?

**For Codex. Static analysis of the AMIX sources on disk plus the measurements below; no
hardware, no emulator, no kernel changes.** Written 2026-08-11.

The deliverable is a written answer with its reasoning, not a patch.

## Why this is being asked now

The working assumption in this project has been vague: "more than 16 MB probably works, we run
32 MB". That is not good enough to plan on, and a measurement taken while writing this task
suggests the truth is more interesting than either "it works" or "it is capped".

## What is already established — do not re-derive

**E1. The machine reports 32 MB and uses 32 MB.** Boot banner, real hardware, kernel
`68060-260810-03`:

```text
Graphics (chip) memory = 2097152
Total    Unix  memory = 33550336        = 32 MiB - 4096
Available Unix memory = 30920704
```

**E2. But `bootinfo` describes THREE regions, totalling 48 MB of fast RAM plus chip.**
`bootinfo` is a kernel global (`struct bootinfo`, `amix-src/sys/amiga/boot/bootinfo.h:43`):

```c
struct bootinfo {
    struct ConfigDev autocon[NAUTO];    /* NAUTO = 16 */
    struct MemHeader memory[NAUTO];     /* <- this array */
    unsigned char keystates[16];
    struct BootData bootdata;
    unsigned char reserved[256];
};
```

On this image `bootinfo` is at `0x080F6F3C`. Taking `sizeof(struct ConfigDev) == 68` (recorded
empirically in `~/kehitys/CLAUDE.md` for the lszorro work), `memory[]` begins at `0x080F737C`.
Read from real hardware with `/kpeek 080F737C 24`, and interpreted as 32-byte `MemHeader`s with
`mh_Lower` at +20, `mh_Upper` at +24, `mh_Free` at +28:

| region | lower | upper | size | free |
|---|---|---|---|---|
| A | `0x08000020` | `0x0A000000` | **32 MiB** | `0x01C25AC8` ≈ 29.5 MiB |
| B | `0x07000020` | `0x08000000` | **16 MiB** | `0x00FFFFE0` ≈ 16 MiB |
| C | `0x00004020` | `0x00200000` | 2 MiB (chip) | `0x001E7048` |

Raw dump, so you can re-read the fields yourself if the offsets below are wrong:

```text
080f737c 07000000 080009c6 0a2800f8 471c0505 0800a628 08000020 0a000000 01c25ac8
080f739c 00004000 08000000 0a1e00f8 471c0505 07000020 07000020 08000000 00ffffe0
080f73bc 080009ca 07000000 0af600f8 041c0703 00004608 00004020 00200000 001e7048
```

**E3. So 16 MiB at `0x07000000` is described to the kernel and appears not to be counted.**
32 MiB (region A) minus one page is exactly what the banner reports. Region A is where the
kernel itself is loaded — the build-id formula this project uses is
`0x08000000 + textsize + nm(.data)`, and every counter address in every acceptance document is
of that form.

**E4. The 68040/68060 MMU setup.** `DTT0 = 0x003fc060` transparently maps `0x00000000` –
`0x3FFFFFFF` with cache mode `0x60` (noncacheable, not serialised). Both fast regions and chip
RAM are inside that window; Zorro III at `0x40000000` is not (see
`Z3-BUSBENCH-Z2-MEASUREMENT-260810.md` and the `amix-zorro3-aperture-limitation` note).

**E5. Zorro II address space overlaps neither region.** Z2 memory space is
`0x00200000`–`0x009FFFFF` and Z2 I/O is `0x00E80000`–`0x00EFFFFF`; the boards on this machine
sit at `0x00200000`, `0x00600000`, `0x00E90000`, `0x00EA0000` (`~/kehitys/CLAUDE.md`). Region C
stops at `0x00200000`, i.e. exactly where Z2 memory space begins.

**E6. The struct layouts for `ConfigDev` and `MemHeader` are NOT in the tree.** They come from
AmigaOS includes. The 68-byte `ConfigDev` in E2 is an empirical figure, and the `MemHeader`
field offsets used above are an inference from the AmigaOS layout
(`Node` 14 + `Attributes` 2 + `First` 4 + `Lower` 4 + `Upper` 4 + `Free` 4 = 32). **Both could
be wrong, and if they are, E2's table is wrong with them.** Confirming or correcting that is
part of this task, not an assumption it may rest on.

## The questions, in priority order

**Q1. Is E2's reading of `memory[]` correct?** Establish `sizeof(struct ConfigDev)` and the
`MemHeader` layout as AMIX actually uses them — from `amix-src` where possible, from the
kernel's own use of the fields where not. If the offsets are different, redo the table. Say
which fields you trust and why.

**Q2. Why is region B not in `Total Unix memory`?** Find the code that walks
`bootinfo.memory[]` and decides what becomes managed RAM — `kernel/support.c` is named in this
project's notes as where `bootinfo` is consumed. Candidate explanations to confirm or kill:

* only the region containing the kernel is taken;
* regions are taken until some count/limit is hit;
* a region is rejected by an attribute test (`mh_Attributes`, FAST vs CHIP vs "public");
* the loader (`unix_boot040`) passes on only part of what AmigaOS knows;
* it *is* taken, and the banner simply reports one region.

The last one is testable from the sources and would change the whole answer, so kill it first.

**Q3. Is there a hard ceiling anywhere, and where is it?** Specifically: page-frame array
sizing, `physmem`/`maxmem` types and any 16-bit or 24-bit truncation, `btoc`/`ctob` overflow,
the page-table geometry this port already had to fix for 4 KiB pages, and anything sized from a
constant rather than from the memory list. This project has already been bitten by 2 KiB vs
4 KiB assumptions in exactly that kind of arithmetic (`amix-crosscompile-headers-2kib-trap`).

**Q4. Does anything overlap?** Region A ends at `0x0A000000`; the DTT0 window ends at
`0x40000000`; Zorro III boards autoconfigure at `0x40000000` upward. Is there a physical
address range where a large RAM expansion and a Zorro III aperture could collide, and does
anything in the kernel assume RAM stops below some boundary?

**Q5. If region B were taken, what else would have to be true?** Contiguity assumptions are the
usual trap: does the VM layer assume one contiguous physical span, and would a 16 MiB hole
between `0x08000000` (region A base) and `0x07000000` (region B base, *below* it) break
anything? Note the regions are not adjacent in the obvious order — B sits *below* A.

## What would count as an answer

A document with, for each question, the answer and the file:line that supports it. Where the
source does not settle it, say so and name the measurement that would — this project can run
things on real hardware, and a precise experiment is a perfectly good deliverable.

Explicitly worth saying out loud if true: **"nothing prevents it, the kernel just takes one
region"** would be a fine answer and would make this a small change rather than a campaign.
The opposite — a structural ceiling — is equally fine to hear. What is not useful is a maybe.

## Sources on disk

```text
amix-src/sys/amiga/boot/bootinfo.h        struct bootinfo, NAUTO
amix-src/sys/amiga/inc/                   amigarom.h, memory.h and friends
amix-src/sys/amiga/                       the rest of the machine-dependent tree
kernelsupport/prototypes/                  every override this port has made, incl. the VM ones
kernelsupport/KNOWN-ISSUES.md              ISSUE-39/40 touch memory accounting
kernelsupport/Z3-BUSBENCH-Z2-MEASUREMENT-260810.md   DTT0 and the Z3 aperture
~/kehitys/CLAUDE.md                        board addresses on this machine, ConfigDev = 68 bytes
```

## Out of scope

The Zorro III driver work, and any implementation. This task is: what is true, and what would
have to change. Deciding whether to do it comes after.
