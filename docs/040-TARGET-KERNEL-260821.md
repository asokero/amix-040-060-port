# The 68040 TARGET kernel — the one an installed AMIX disk boots (2026-08-21)

Until now every 68040 kernel this project shipped was a **miniroot** kernel: it is booted off
the install medium, roots on that medium's own slice, and its job ends when the install ends.
The kernel the *installed disk* then boots is a different artifact with a different root stamp,
and this is the record of the first one minted from the cure line.

Everything below is host-side measurement. **No 68040 silicon ran either image**, and neither
image can be bench-booted (see §7).

## 1. What the installed disk was carrying, and why it had to be replaced

The staged target kernel was the link produced from `a0ff2c2a`, build id `68040-260818-02`,
framed to `sum -r` **52867**. Two facts about it, both measured rather than assumed:

* it is **the same link** as that lineage's miniroot kernel (framed `sum -r` 06634). The two
  framed images differ in exactly **two bytes** — the `rootdev` minor and one digit of the
  `/dev/dsk/c?d0s2` swap-path string. Everything else, including the build id, is identical.
  So "the target kernel" was never a separate build; it was the miniroot build re-stamped;
* it therefore predates the whole 2026-08-20/21 fix run. `tools/status-facts.sh` reads **four
  failing override bindings** in it, and each one names a fix it does not have:

  | binding in 52867 | verdict | the fix it is missing |
  |---|---|---|
  | `usrxmemflt` strong, `usrxmemflt_stock` **missing** | CHECK | the ISSUE-10 cure (`hgfault040.o`) |
  | `sync` still stock at `0x5d21a` | CHECK | ISSUE-100, the `sync()` guard on the panic path |
  | `page_init` still stock at `0xaf42a` | CHECK | ISSUE-102, the page-frame database zero fix |
  | `setregs` still stock at `0x58b62` | CHECK | the ISSUE-104/51/52 setregs work |

The first row is the one that showed. On its first boot the installed system reached
`/sbin/sh /var/adm/firstboot/firstboot.sh` and then repeated `User BUS ERROR at 4AFC0003,
PC:800023FC` — the ISSUE-10 signature, a shell faulting while growing its arena and refaulting
without progress, which is exactly the wall the medium's own kernel had already been cured of.
An installed system is a *larger* target for it than an installer is: the install medium runs
one script, the installed system runs `firstboot.sh` and then everything else forever.

## 2. Build line

Built on the **minimal-delta line** (`issue46-minimal-260821-cure`), not on `main`, for the
reason that line exists at all: `main` also carries the ISSUE-10 audit instruments, whose hooks
sit on the resolved fault tails and run during boot, so a kernel built from `main` executes tens
of kilobytes of code the metal-proven lineage never had. That was the right trade while the
instruments were answering a question. It is the wrong trade for the kernel a user's disk boots.

The line gains exactly one thing here — the `relink-040-z3660.sh` flow, brought across
unmodified as three commits so the two branches' copies of that flow stay byte-identical:

* `z3660 relink: accept the drivers' NBPP-derived page counts` — both driver projects now state
  their window geometry in bytes and derive the page count from `NBPP`, so the literal this
  script used to rewrite is gone and the old check aborted the whole relink;
* `z3660 relink: resolve the alien SCSI headers instead of assuming AMIX_ROOT` — `rico.h`/`sd.h`
  are looked up rather than assumed under a staging `AMIX_ROOT` that holds only `stand/unix`;
* `z3660 relink: the ethernet char major is 51, not 48` — `cdevsw[51].d_str`, i.e. byte offset
  `51*52 + 44 = 2696 = 0xa88`.

Nothing else about the base link changed, and that is measurable: the base kernel built here is
**byte-identical to the metal-proven cure kernel** (build id `68040-260821-34`) except for one
byte inside the 16-character build-id field.

## 3. Two images, because the drivers are a new variable

`relink-040.sh` produces the base; `relink-040-z3660.sh` takes that base and adds the drivers.
The intermediate is a legitimate artifact in its own right, so both are kept:

| | plain | + Z3660 drivers |
|---|---|---|
| build id | `68040-260821-37` | `68040-260821-38` |
| ET_REL image | 1 805 453 B, `sum -r` **55772** | 1 818 794 B, `sum -r` **22565** |
| sha256 (ET_REL) | `e8601c1079a0d73c6302421d6582f37f0c6d65faef3a26bf1e8d2e4db077c897` | `e2ed8cec9fe1af636464b94f9fbe6d037aa6989bd3136c3443d15b40e5e7ac66` |
| framed image | 1 336 916 B, `sum -r` **60367** | 1 345 748 B, `sum -r` **51443** |
| sha256 (framed) | `6ef444644e217e60825bd36664865c37320b72d48634e7da67033125a5417333` | `6161875cddeaf754b59af7da2d7ced277d82bb353c9f30a69606b2b40dff32b8` |
| `.text` | 996 380 (`0xf341c`) | 1 003 232 (`0xf4ee0`) |
| `.data` / `.bss` | 102 552 / 67 600 | 102 860 / 71 096 |
| `hg` block @ base `0x08000000` | `0810C3EC` | `0810DEB0` |
| `wbf` block @ base `0x08000000` | `0810BA4C` | `0810D510` |

Framing is `elf2brel.py` from the `amix-kerntools` build hub, which statically applies the 330
intra-`.text` PC-relative relocations and re-frames the image as `e_type = 0xff00`; the ET_REL
input reads `e_type = 0x0001` and the framed output `0xff00`, checked on all four files.
The release string is untouched (`2.1c 0800430`); the build id rides in `utsname.machine`.

**The counter addresses are not the miniroot's.** `hg_magic` sits at `0810C3EC` in the plain
image and `0810DEB0` in the driver image — `0x1AC4` apart, which is precisely the `.text` the
two drivers and the glue add. Reading the driver image's counters at the plain image's address
returns a plausible number from whatever now lives there. Re-derive per image, always, with
`sh tools/status-facts.sh <image> <load base>`; the load base is the loader's own `tvaddr`.

## 4. The root stamp is inherited, not applied

The installed root is `/dev/dsk/c6d0s1` and its swap is `/dev/dsk/c6d0s2`. In the kernel that is

```
rootdev  @ .data+0xfe20 = 0x00480016      major 18, minor 0x16 = slice 1, target 6
swapdev  @ .data+0xfe24 = 0x00480026      major 18, minor 0x26 = slice 2, target 6
                                          "/dev/dsk/c6d0s2" as a plain string a little further on
```

The staged AMIX 2.1c `stand/unix` this project relinks **already carries those exact values** —
it was produced by an on-box relink on a machine whose root was SCSI target 6 — so every image
built here is target-stamped for `c6d0` with **zero edits**, and the 52867 kernel's stamp was
inherited the same way. Both images were verified by symbol, not by assumption, and match 52867
byte for byte in all three places. `cputype` reads `0x28` = 40 in both, as it does in 52867
(the loader pokes 60 over it on 68060 silicon). `hg_on` defaults to 1 and `hg_magic` reads
`48474621` = `HGF!`.

The cleanest statement of what the plain image *is*: framed, it differs from the metal-proven
cure **miniroot** image in exactly **three bytes** — the `rootdev` minor `0x16`↔`0x10`, the
swap-path digit `6`↔`0`, and one build-id character. It is the kernel that has already booted
this hardware, pointed at the installed disk instead of the medium.

## 5. Reproducibility

Two full passes of each script, back to back:

```
base   pass A (37) vs pass B (39)   1 byte  @0x10bbab   inside the build-id field at 0x10bb9c
Z3660  pass A (38) vs pass B (40)   2 bytes @0x10d66e-f inside the build-id field at 0x10d660
base   pass A (37) vs the metal-proven cure build (34)   1 byte @0x10bbab, same field
```

Every differing byte is inside the 16-character build-id string and nowhere else.

## 6. Boot-slice geometry

The target boot slice is 2 MiB (`BOOTSIZE=2`), and the chain ahead of the kernel occupies
`0x2800` = 10 240 bytes:

| image | `0x2800` + framed bytes | of 2 097 152 | spare |
|---|---:|---:|---:|
| 52867 (what is on the disk now) | 1 342 680 | 64.0 % | 754 472 B (736.8 KiB) |
| plain | 1 347 156 | 64.2 % | 749 996 B (732.4 KiB) |
| + Z3660 drivers | 1 355 988 | 64.7 % | 741 164 B (723.8 KiB) |

The whole fix run plus the cure costs 4 476 bytes over 52867, and the drivers 8 832 more.
Neither moves a slice boundary, and the slice still has room for roughly half a kernel again.

## 7. Gates — and what a gate here can and cannot say

A kernel carrying the Z3660 SCSI driver **is not bench-booted here, deliberately**. The bench
presents a Z3660 of its own making, so the board the driver finds there is not the board it will
find on the card; a green bench boot would be a statement about the emulator and a red one would
be unattributable. Either way it is not evidence about this image, so there is no boot smoke
test in this record and the checks are all link-time and image-time:

* **base link** — every hard check in `relink-040.sh` passes, including the cure's own: the
  object is present, the alias renamed, the tail target bound, and `as_map` / `segvn_create` /
  `zfod_argsp` / `as_segat` all resolved. `check_relink_relocs.py`: 0 complaints, both images;
* **override bindings** — `tools/status-facts.sh` reads **0 failing** on both images, against
  **4 failing** on 52867 (§1). Both directions are checked: the strong symbol has moved off the
  stock address *and* the retained `*_orig` / `*_stock` alias still points at it;
* **page geometry** — both driver objects shift by 12 (4 KiB PFN) at every page-math site and by
  11 at none, asserted in the compiled bytes;
* **link hygiene** — no unresolved symbols; `.text`/`.data` contiguous; `.data` size `0x191cc`
  is 4-aligned, so `.bss` lands aligned at runtime;
* **registration, read back out of the linked image** — the glue's `parinit` is
  `movel #z3660ethinfo, cdevsw+0xa88` followed by `jmp parinit_orig` (`0xfe6c`, the retained
  stock body). `0xa88` = 2696 = slot 51's `d_str`, so the ethernet driver registers where a
  `mknod /dev/zen0 c 51 0` node reaches it;
* **the SCSI table** — four rows where stock has three, rows 0–2 still relocating to
  `a3091queue` / `a2090queue` / `a2091queue` with their original name strings, row 3 =
  product `0x144B0001` → `z3660queue`; loop bound `moveq #2` → `moveq #3`;
* **`dd.c` completion ordering** stays OFF (it panics before the banner; `Z3660_DD_ORDER=1`
  when there is a board to validate it against).

## 8. What is not established

**Which image the installed disk should get.** The plain image is a one-variable change from a
kernel that has demonstrably booted this disk. The driver image is not: no 68040 kernel that has
run on this hardware has ever carried these two drivers, and the SCSI half registers a *second*
card into a namespace where the working disk already answers at target 6. What happens when two
cards enumerate the same backing store is not something this project can measure without the
board. The ethernet half is the reason to want the image at all, and it is the half that carries
no such risk.

**Silicon.** Every measurement behind the cure is emulator work, and the 68040 write-back replay
has panicked real silicon before when the target was not already resident. `hg_unres_n` and the
`wbf` block are what to read on the first hardware boot, at the addresses in §3 **for the image
actually booted**.
