# The root hint: the `RTH1` record the boot loader leaves for the kernel

**Status:** specification, record version 1. Driver line, 2026-10-05. Proposed
to the upstream line; until it is accepted, this is the driver line's own interface and is
not listed in `CONTRACTS.md`. The loader half is built by the kerntools line (identities `good_rth` for
the 68030 loader and `good_040_rth` for the 68040/68060 one). The kernel half is `src/rth1.c`, and the
installer writes the root record.

**Why it exists.** The Amix boot loader passes the kernel two registers, `d0 = 3` and
`d1 = struct bootinfo *` (`amiga/boot/boot2.c`, the `ci_d0`/`ci_d1` setup), and nothing about the disk it
came from. The kernel therefore roots on whatever device is compiled into `rootdev`. That is why every
kernel family existed as one file per target unit and controller, files that differ in two bytes:
the low byte of `rootdev` and the controller digit in `swapfile.bo_name`. This record lets one kernel per
family root on the disk it was booted from, or on the disk an installer named.

## Where the record lives

In `struct bootinfo.reserved`, starting at its first byte. That is offset **0x678** from the start of
the structure, on both sides:

- The loader's `struct bootinfo` (`amiga/boot/bootinfo.h`) is 0x778 bytes: `autocon` 0x440, `memory`
  0x200, `keystates` 0x10, `bootdata` 0x28 (ten longs), `reserved` 0x100.
- The kernel's (`amiga/kernel/support.c`) is **0x76c** bytes. Its `struct BootData` has seven longs, not
  ten; the rodata fields are missing.
- `config()` copies `sizeof bootinfo` = 0x76c bytes from the loader's structure. The kernel's
  `bootinfo+0x66c..0x677` therefore holds the loader's last three `BootData` longs (`bd_dvaddr`,
  `bd_doffset`, `bd_dsize`), and the loader's `reserved[0..243]` lands at kernel `bootinfo+0x678..0x76b`.
  The loader's last 12 bytes never arrive.
- Measured on the emulator, 2026-10-05: the driver line's boot2 record (outside this tree),
  with a 68030 kernel at 0x040effbd and a 68060 kernel at 0x07107ca8.

**Mixed old and new boot as before:**
- Every stock loader allocates the structure `MEMF_CLEAR` (`boot2.c`; `unix_boot` too), so an old loader
  leaves zeros here.
- No stock kernel reads `reserved`. There is no reference in `amix-src`, and in the 68040 base the only
  references to `bootinfo` are `+0`, `+0x440` and `+0x654`, all in `config`.
- So an old loader with a new kernel gives "no record", and the kernel roots as compiled. A new loader with
  an old kernel leaves bytes nobody reads. Both were run on the emulator (`UNKNOWN-boot2.md` §8).

## `struct rth1` — 0x38 bytes, every field a longword, big-endian

| off | field | meaning |
|---|---|---|
| 0x00 | `magic` | `0x52544831`, `"RTH1"` |
| 0x04 | `verlen` | `version << 16 \| length`: version **1**, length **0x38** |
| 0x08 | `flags` | see below |
| 0x0c | `boot_unit` | the booted BootNode's `fssm_Unit`, as AmigaOS has it. For SCSI-style devices this is target + 10·LUN |
| 0x10 | `boot_base` | `cd_BoardAddr` of the booted BootNode's ConfigDev; 0 without `RTH_BCDEV` |
| 0x14 | `boot_id` | `er_Manufacturer << 16 \| er_Product << 8` of that ConfigDev; 0 without `RTH_BCDEV` |
| 0x18 | `check` | `-(sum of the longs at 0x00..0x14)`, so the seven longs `0x00..0x18` sum to 0 |
| 0x1c | `root[7]` | the root record (below), copied **verbatim** from the kernel's info block; all zero when there is none |

| `flags` bit | name | set by the loader when |
|---|---|---|
| 0x01 | `RTH_BOOT` | exactly one BootNode is the one that was booted (rule below). `boot_unit` is then valid |
| 0x02 | `RTH_BCDEV` | that BootNode's `ln_Name` is one of the ConfigDevs `FindConfigDev()` returns. `boot_base` and `boot_id` are then valid |
| 0x04 | `RTH_BMOBO` | `RTH_BOOT`, but the BootNode names no ConfigDev: the boot device is a motherboard controller (A3000 SCSI, Gayle IDE) |
| 0x08 | `RTH_ROOT` | a root record was found in the kernel's info block and copied to `root[]` |
| 0x10 | `RTH_AMBIG` | more than one BootNode matched and they could not be told apart. Informational: `RTH_BOOT` is then clear |

All other bits are 0. A version-1 reader ignores bits it does not know only after rejecting a record whose
version is not 1.

**`length` bounds every read.** A kernel reads the root record at 0x1c, or anything else past the fixed
header, only after it has checked `length` (the low half of `verlen`) and found it ≥ 0x38: a version-1
kernel rejects a shorter record before touching 0x1c, and reads nothing beyond 0x38. A later version can
therefore grow the record by raising `length` without an old kernel reading past what a loader wrote
(agreed with upstream, 2026-10-06).

### The rule for "the BootNode that was booted" (loader)

The strap hands boot1 an open `struct IOStdReq` on the partition, and boot1 passes it to boot2. boot2 walks
`ExpansionBase->MountList` and keeps a BootNode only if all three hold:

- its `FileSysStartupMsg`'s `fssm_Device` (a BSTR) equals `iob->io_Device`'s name;
- its `DosEnvec` start, `de_LowCyl × de_Surfaces × de_BlocksPerTrack × de_SizeBlock × 4`, equals the
  partition start, which is the kernel info block's offset − 0x2600;
- `OpenDevice(fssm_Device, fssm_Unit)` on it yields `iob->io_Unit`. The loader closes the device again.

The `OpenDevice` test is applied to every candidate, not only when two survive. It costs fewer bytes than a
second pass. Exactly one node kept means `RTH_BOOT` and `boot_unit`; more than one means `RTH_AMBIG`.

**Matching on the name or the DosType alone is not enough.**
- On the Z3660 the firmware's mounter also lists `UNIX_Root` and `UNIX_Swap` (priority −128, despite their
  NOMOUNT flags). Measured on the A4000D, 2026-10-05.
- Two disks laid out identically on one controller (an install source and its target) give two nodes with
  the same name and start; only the unit test separates them.

## The root record — `struct rto1`, 0x1c bytes, written by the installer

It names the root disk explicitly. It is needed when the root is not on the disk that was booted.
- The case that requires it in version 1: a root behind the A4092. That card's ROM (42.39) offers no Amix
  partition to Kickstart (measured on the A4000D, 2026-10-05), so such a system boots from a boot-only
  disk on the Z3660 and roots on the A4092.
- An installer writes it only when boot and root disks differ. A same-disk install carries none.

| off | field | meaning |
|---|---|---|
| 0x00 | `magic` | `0x52544F31`, `"RTO1"` |
| 0x04 | `verlen` | version **1** `<< 16 \|` length **0x1c** |
| 0x08 | `unit` | the Amix unit (SCSI target) of the root disk, 0-7 |
| 0x0c | `base` | `cd_BoardAddr` of the root disk's controller, or 0 to match by `id` alone |
| 0x10 | `id` | `er_Manufacturer << 16 \| er_Product << 8` of that controller; 0 with `RTO_MOBO` |
| 0x14 | `flags` | 0x01 `RTO_MOBO`: the root controller is the motherboard controller. Other bits 0 |
| 0x18 | `check` | `-(sum of the longs at 0x00..0x14)` |

**Where it lives:**
- In the kernel's info block (the `IBLK` at boot-slice offset 0x2600), at **offset 0x100 inside that
  block**, in `ib_pad`. That is at boot-slice offset **0x2700**.
- Both loaders already read the whole 512-byte block.
- The block's checksum covers the kernel file, not the block, so writing the record changes no checksum the
  loader tests.
- The loader copies the 0x1c bytes into `rth1.root[]` when the first long is `"RTO1"` and sets `RTH_ROOT`.
  It does not interpret them; the kernel checks them.

## What the kernel does with it (`src/rth1.c`)

**Hook.** `rth1_mountroot()` runs at the one call to `vfs_mountroot` in `main`. It calls `rth1_apply()`
and then `vfs_mountroot()`.
- sd registers its controllers lazily: its static `init()` runs from `sdopen()`, on the first open of
  any disk, which would otherwise be the root's own open inside `vfs_mountroot`. So `rth1_apply()` calls
  `sdopen(0)` first. The init is guarded, so the root's open later finds it done.
- On the 68040/68060 line this is a retarget of that call's relocation (`.text 0x5983c` in the merged
  driver-line base), asserted against its current target.
- On the 68030 line it is the same retarget in the kit's `main` object.
- Nothing has read `rootdev` or `swapfile` before this point. Their only readers are `s5mountroot`,
  `ufs_mountroot` and `swapconf`.

**The built-in root** is what the kernel was linked with: `rootdev` and `swapfile.bo_name` as stamped. For
the one-kernel families that is `c6d0s1` / `c6d0s2` (unit 6, first controller).

**The record is used only when every one of these holds; otherwise the built-in root is used:**
1. `magic` is `"RTH1"`, the version is 1, the length ≥ 0x38, and longs 0x00..0x18 sum to 0. All four are
   checked before `root[]` (0x1c) is read.
2. Choose the reference:
   - if `root[0]` is `"RTO1"`, its version is 1 and its seven longs sum to 0, use the root record:
     `unit`, `base`, `id`, `RTO_MOBO`;
   - a present but damaged root record means the built-in root, not a fallback to the boot fields;
   - otherwise, if `RTH_BOOT` is set and `boot_unit` ≤ 7, use the boot fields: `boot_unit`, plus
     `boot_base`/`boot_id` under `RTH_BCDEV`, or the motherboard rule under `RTH_BMOBO`.
3. The named controller is present: exactly one of sd's registered controllers (`sdcardbase(c)` nonzero,
   c = 0, 1) matches.
   - **By base** if `base` ≠ 0: `sdcardbase(c) == base`.
   - **Else by id:** the `bootinfo.autocon[]` entry whose `cd_BoardAddr == sdcardbase(c)` has
     manufacturer/product equal to `id`.
   - **Motherboard:** the controller whose `sdcardbase(c)` is the base of **no** `bootinfo.autocon[]`
     entry. The A3000 SCSI registers at 0xdd0000; the Gayle IDE glue registers a sort key (0xfffffff0, or
     its task-file base under `IDE_ORDER=address`). Neither is an AutoConfig board address.
   - The matching controller's index c is the Amix card.
4. The kernel is disk-rooted: the major of `rootdev` is 18 (sd), and `bo_name` reads `/dev/dsk/c?d0s2`
   ending in NUL. A floppy-rooted family (`FD0P`, `/dev/fakeswap`) is never moved.

**Then, together or not at all:**
- with v = card << 3 | unit:
  - `rootdev = makedevice(18, 1 << 4 | v)` (slice 1);
  - `bo_name[10] = "0123456789abcdef"[v]` (slice 2 unchanged);
- `bo_size` and `dumpdev` stay as linked.
- Both are written in one place, before anything reads either. A root that moves without its swap name
  panics in `swapconf`: it looks the name up after the root is mounted and calls `cmn_err` at level 3 when
  that fails (`.text 0xb405c` in the merged base).

**One console line, always,** printed before `vfs_mountroot`. It says which root is used and why. Examples:

```
RTH1: root c9d0s1 from the root record (board 48000000 id c0de01 unit 1 = card 1)
RTH1: root c3d0s1 from the boot disk (board 40000000 id 144b01 unit 3 = card 0)
RTH1: root c6d0s1 built in (no record)
RTH1: root c6d0s1 built in (bad record)
RTH1: root c6d0s1 built in (controller not present)
```

**A valid record naming a unit with no disk fails the mount. The kernel never falls back.** `vfs_mountroot`
fails and panics as it does today with a wrong compiled root, and the line above says what was chosen.
Falling back would boot a system on a disk the installer did not mean.

**For the rig and for metal checks** the kernel keeps what it did in two longwords:
- `rth1_used`: 0 built in, 1 boot disk, 2 root record;
- `rth1_why`: 0 used; 1 no record; 2 bad record; 3 bad root record; 4 no boot node; 5 unit out of range;
  6 controller not present; 7 not disk-rooted.

## Conventions this record relies on, and does not encode

- **Root is slice 1, swap is slice 2** of the named disk: the stock installer's convention and every disk
  laid out here. A later version may carry slices.
- **Only units 0-7 with LUN 0.** An AmigaOS unit ≥ 8 (LUN ≥ 1) is out of range, so the built-in root is
  used.
- **Two controllers.** sd keeps two (`SDCARDS`), sorted by board address. A third is dropped before this
  code runs.

## What this record does not do

- **Userland:** Amix's `bcheckrc` takes the root from `/etc/devnm /` (installng, 2026-10-05), not from
  `vfstab`, so a disk booted from another unit comes up multiuser.
  - The device nodes `/dev/dsk/c<v>d0s0..s5` must exist for the unit the root lands on, or `swapconf`
    panics.
  - Creating them is the installer's job.
- **Does not choose the boot disk.** Kickstart does, by boot priority.
