# FPE round 7 — the metal NO-GO, root-caused; and the base the artifact must be built over

Round 6 armed the soft-FPU lane on real silicon for the first time: on the socketed MC68LC060
at cpufreq 80 the kernel printed `no fpu detected` → `fpu emulation enabled`, latched
`fpe_cputype_amix = 60` / `fpe_cputype = 3` / `fpe_cputype_bad_n = 0`, and installed
`fpe_vec11` on vector 11. It then panicked, 2 of 2, byte-identically, **before multiuser and
before a single floating-point instruction was emulated** (`fpe_entry_n = 0`):

```
PANIC: KERNEL FAULT psw=0x2204, pc=0x800D578, fmt=0x4, vector=0x2 (Bus Error)
```

`0x0800D578` is `initialize+0x5c` in the a3091 (A3000/A2091 SCSI) driver, instruction
`movew #3,%a0@(2)` — a word write to `0x00DD0002`, reached from the root-device probe
`ini_main → vfs_mountroot → s5mountroot → sdopen → getrdb → read → ddstrategy → startio →
initialize`. The metal record is `Amix/tmp/2026-08-27-fpe-metal/RESULTS.md`.

This document is committed **before** the round-7 artifact is built. It answers what the
NO-GO was, refutes the two mechanisms that were leading candidates going in, names the one
defect in `relink-040-fpe.sh` that is genuinely the script's own, and registers what the metal
retry should expect.

> **PROVENANCE.** §3–§5 disassemble stock AMIX kernel code (`a3091`'s `initialize`, `sd`'s
> `init`/`insert`) and decode stock `.data` objects, all measured from the image this port
> patches and cited by address. No vendor source text is reproduced. Same class as
> `FPE-INTEGRATION-CONTRACT.md`, `FPE-GLUE-DESIGN.md` and the ATT7/ATT8 results.

**Scope discipline, unchanged from rounds 1–6.** No file under `build/fpe-src/` is touched.

---

## ANSWER FIRST

**The FPE kernel was built over the wrong kernel family, and the family it was built over has
no driver for the metal rig's root device at all.**

`build/unix-040` — the round-1-pinned FPE base,
`b1351544c151dc0d33715fe0bb42c86f119dc60e48b0c0d4d2be108826fc9fe4` — is the base *before*
`relink-040-z3660.sh` runs. It carries **zero** Z3660 symbols, the stock 3-row `scsicard[]`
table, and a `rootdev` of `0x00480016` = card 0 / target 6 / slice 1 = `/dev/dsk/c6d0s1`.
On the A4000 + Z3660 rig, card 0 is the phantom A3000 controller at `0xDD0000` — an address
nothing on that machine answers. The kernel did exactly what it was stamped to do: it mounted
root through card 0, `sd` called a3091's `initialize()`, and the first register write bus-errored.

The known-good metal kernel `build/unix-060-f8a1-CARD1-ced0s1`
(`efd743c9d48667287995e17c7bf32cfe7734d1267778c54f141b8e4351e50441`) descends from the **same**
`build/unix-040`, and its `.text` is byte-identical to it for all 1,004,392 bytes of that
prefix **except one byte** — `0xd79f`, the `scsicard[]` loop bound. That one byte, plus the
8,652 bytes of Z3660 driver appended after it, plus a two-byte `rootdev`/`bo_name` restamp, is
the entire difference between a kernel that reaches multiuser in 46 s and a kernel that
bus-errors in the root probe.

**The 128 MiB / load-base-`0x08000000` hypothesis is refuted** (§6): the faulting address is a
fixed hardware address, the pointer that produced it is written at run time by `autocon()`, and
the object holding it sits at the *same* `.bss` offset in both kernels.

**The genuine defect in `relink-040-fpe.sh`** (§7) is that it asserts fifteen things about the
FPE glue and **nothing about the base it inherited** — so the one fact a deploy decision needs,
which controller this kernel will try to mount root through, is the one fact its build log
omits. That is fixed here.

---

## 1. (a) Which build lineage the metal known-good actually is

`build/unix-060-f8a1-CARD1-ced0s1`, 1,889,316 B, build id `68060-260825-70`, read back off the
card and hashed at `Amix/tmp/2026-08-26-blizzard-f4m2-att9-hwswap/kernels/readback-f8a1.bin`.

Its chain, each link proved below by `.text`-prefix identity rather than by build record:

```
build/unix-040                       b1351544…   THE SHARED ANCESTOR (round-7 040 base)
  │                                              0 z3660 syms · scsicard bound 2 · rootdev card 0
  ├─ relink-040-fpe.sh              →  unix-040-fpe / unix-060-fpe   <-- THE FPE LANE STOPPED HERE
  │                                              0 z3660 syms · bound 2 · rootdev card 0
  └─ relink-040-z3660.sh            →  unix-040-f7base   +8,652 B .text, 109 z3660 syms,
        │                                                 bound 2→3, scsicard[] → z3660_scsicard
        ├─ relink-040-f4arms.sh --ufault --cache 60  →  unix-040-f7uft   (z3660_cache C→D)
        ├─ relink-040-f6.sh --swa                    →  unix-040-f7swa
        ├─ relink-040-f6.sh --kvd                    →  unix-040-f7vs
        └─ relink-040-f8.sh --ucp2                   →  unix-040-f8a1
              └─ tools/stamp-card1.py                →  unix-040-f8a1-CARD1-ced0s1
                    └─ tools/stamp-cputype.py --set 60 →  unix-060-f8a1-CARD1-ced0s1   efd743c9…
```

Prefix-identity measurements (`.text` of the parent compared byte-for-byte against the same
range of the child):

| parent | child | parent `.text` | child `.text` | differing bytes in the prefix |
|---|---|---|---|---|
| `unix-040` | `unix-040-f7base` | 1,004,392 | 1,013,044 | **1** — at `0xd79f` |
| `unix-040` | `unix-040-f7vs` | 1,004,392 | 1,014,192 | **1** — at `0xd79f` |
| `unix-040` | `unix-060-f8a1-CARD1-ced0s1` | 1,004,392 | 1,015,132 | **1** — at `0xd79f` |
| `unix-040-f7vs` | `unix-040-f8a1` | 1,014,192 | 1,015,132 | **0** |
| `unix-040-f7vs` | `unix-040-f7vsu` | 1,014,192 | 1,014,828 | **0** |

The last two rows are the load-bearing ones for §8: `unix-040-f8a1` **is** `unix-040-f7vs` with
the attempt-8 ARM I (`src/ucp2_dbg.s`) appended and nothing else changed.

The two stamps are two and one bytes respectively, and both are pure `.data`:

```
unix-040-f8a1  ->  unix-040-f8a1-CARD1-ced0s1        2 bytes
    @0x107bb3   rootdev+3   0x16 -> 0x1e     minor (slice 1<<4)|(card 0<<3)|unit 6  ->  card 1
    @0x107bde   bo_name+10  '6'  -> 'e'      /dev/dsk/c6d0s2  ->  /dev/dsk/ced0s2
unix-040-f8a1-CARD1-ced0s1  ->  unix-060-f8a1-CARD1-ced0s1     1 byte
    @0x110547   cputype+3   0x28 -> 0x3c     40 -> 60
```

`rootdev` is `.data+0x00fe20` in both; `cputype` is `.data+0x0187b4` in both.
`tools/stamp-card1.py:3` states the card-1 identity in its own words: "card 1 (the Z3660 piscsi
controller)", and its `node(6,1,1) == "/dev/dsk/ced0s1"` self-check is annotated "measured,
reads the root disk".

**The FPE artifact, on the same axes.** `Amix/tmp/2026-08-27-fpe-r5/kernels/unix-060-fpe`
(`8f7c8d62…`, the exact bytes read back off the card at
`Amix/tmp/2026-08-27-fpe-metal/verify/rb-kernel.bin`):

| | FPE metal artifact | metal known-good |
|---|---|---|
| z3660 symbols (`nm`) | **0** | 62 exported / 109 total |
| `z3660_scsicard` | absent | `.data+0x019ec8`, 4 rows |
| `scsicard[]` loop bound `@.text+0xd79f` | `0x02` (3 rows) | `0x03` (4 rows) |
| `rootdev` `@.data+0xfe20` | `0x00480016` → **card 0** `c6d0s1` | `0x0048001e` → **card 1** `ced0s1` |
| `cputype` `@.data+0x187b4` | 60 | 60 |
| `.text` / `.data` / `.bss` | 1,033,728 / 108,932 / 68,020 | 1,015,132 / 120,520 / 71,096 |

The FPE artifact is therefore *card-0 rooted with no Z3660 driver present*. Both halves matter:
even a card-1 restamp would not have saved it, because there is no Z3660 row to register
(§4).

## 2. (b) Has `b1351544` ever run on metal at 128 MiB?

**No, and it could not have.** Round 3 (`Amix/tmp/2026-08-26-fpe-r3/`) and round 5
(`Amix/tmp/2026-08-27-fpe-r5/`) are both Amiberry beds; round 5's own artifact record is
"status-facts for the R5 artifact at load base `0x07000000`", against the metal session's
`facts/status-facts-unix-060-fpe-0x08000000.md`. Round 6 was the first time any kernel from
this base met the A4000 + Z3660, and it panicked in the root probe on both scored boots.

The stronger statement does not need the run history: a kernel with no `z3660queue` in its
symbol table cannot mount `ced0s1` on any rig, at any RAM size, at any load base. The
capability is absent from the image.

This exact failure has a prior. `docs/060-F4-M2-PREREG-260824.md:42` registered it as gate 10
on 2026-08-24, after it happened once already:

> "the F1 kernel's only SCSI driver was `a3091`, an A3000 motherboard controller that does not
> exist in an A4000, while this rig roots on `ced0s1` (card 1, the Z3660 piscsi controller).
> The kernel reached its root mount and wrote through a synthesized controller address that
> nothing answers — a named, instruction-level panic, and an entirely avoidable one"

Gate 10's acceptance was "the driver's symbols are present in the built image
(`z3660queue`/`z3660_scsicard` for piscsi), **and** the stamped `rootdev` decodes to a node that
driver serves. Both checked on the artifact, not argued from the build recipe." The gate was
registered, was correct, and was never mechanized. §7 mechanizes it.

## 3. (c) What the same compare sees in the known-good, and why it survives

### 3.1 The faulting routine, decoded

`initialize` sits at `.text+0xd51c` in **both** kernels and is byte-identical in both
(`objdump -dr`, relocations included). With the relocations resolved:

```
    d522:  tstb   once_%0                 ; static "already done" flag
    d528:  bne    d5e8                    ; -> return
    d52c:  moveb  #1,once_%0
    d534:  pea    %fp@(-4)                ; &size
    d538:  pea    device                  ; &device       (.bss+0x3d68, 8 bytes, LOCAL)
    d53e:  clrl   %sp@-                   ; instance 0
    d540:  movel  #0x0202f003,%sp@-       ; the A3091 autoconfig id
    d546:  jsr    autocon
    d550:  tstl   %d0
    d552:  beq    d564                    ; not found      -> panic
    d556:  cmpil  #0x00DD0000,device
    d560:  beq    d572                    ; found AND at 0xDD0000 -> proceed
    d564:  pea    LC%0
    d56a:  jsr    panic                   ; <-- NOT a mapping call
    d572:  moveal device,%a0
    d578:  movew  #3,%a0@(2)              ; <-- BUS ERROR on metal
```

**One correction to the metal write-up.** `RESULTS.md` reads `d564` as "the mapping call",
skipped on equality by a "built-in-controller fast path". It is not a mapping call: the
relocation at `d56c` names `panic`. The routine's shape is "**panic unless the board was found
and its base is exactly `0x00DD0000`**" — a hard-wired assertion that this driver instance is
the A3000 motherboard controller. Nothing in `initialize` establishes any mapping, so there is
no mapping that "is not in force"; the address is simply written, and on an A4000 nothing
drives DSACK for it.

That correction does not change the verdict, and it sharpens it: on this rig `initialize()` is
fatal **whenever it is called**. The only defence is never to call it, which is what card
selection decides.

### 3.2 Why the known-good never calls it

`sd`'s `init()` at `.text+0xd736` walks the controller registry:

```
    d748:  subal  %a2,%a2                 ; row = 0
    d74a:  lea    z3660_scsicard,%a3      ; (stock: lea scsicard,%a3 — the reloc patch_z3660.py retargets)
    d78c:  jsr    autocon                 ; autocon(row.id, instance, &addr, &size)
    d798:  bne    d762                    ; found -> insert(row.queue, instance, addr, row.name)
    d79c:  addqw  #1,%a2
    d79e:  moveq  #3,%d1                  ; <-- THE ONE DIFFERING BYTE (FPE image holds #2)
    d7a0:  cmpl   %a2,%d1
    d7a2:  bcc    d750                    ; loop while bound >= row
```

`insert` at `.text+0xd7cc` writes into `queue`, `.bss+0x3d70`, **32 bytes = two 16-byte slots**
— `SDCARDS = 2`, the same constant `tools/stamp-card1.py:69` cites from `amiga/alien/sd.h`.
Insertion is sorted ascending by controller address (`d7f4: cmpl %a2@(-8),%d0`), and when both
slots are full it prints `"sd: too many controllers\n"` (`LC%3` at `.text+0xd7b2`) and drops the
board. `rootdev`'s card bit indexes that two-slot array.

The registry itself:

| | stock `scsicard` | `z3660_scsicard` (`src/z3660_glue040.s:87`) |
|---|---|---|
| where | `.data+0x00395c`, **36 B = 3 rows** | `.data+0x019ec8`, **48 B = 4 rows** |
| loop bound `@0xd79f` | `2` → rows 0..2 | `3` → rows 0..3 |
| row 0 | `0x0202f003` → `a3091queue` "A3091 SCSI" | same |
| row 1 | `0x02020001` → `a2090queue` "A2090 SCSI" | same |
| row 2 | `0x02020003` → `a2091queue` "A2091 SCSI" | same |
| row 3 | — | `0x144b0001` → `z3660queue` "Z3660 SCSI" |

So on the A4000 + Z3660, with the four-row table:

* row 0 answers (the phantom a3091 at `0xDD0000`) → `queue[0]`, **card 0**
* rows 1, 2 do not answer
* row 3 answers (the Z3660, a Zorro III address, sorts above `0xDD0000`) → `queue[1]`, **card 1**

`ced0s1` = minor `0x1e` = card 1 = `queue[1]` = `z3660queue`. The known-good's root I/O is
dispatched to the Z3660's own `queue` entry point; a3091's `initialize()` is on the *other*
card's path and is never entered, because nothing ever issues I/O to card 0.

**Answering the question as posed:** in the known-good image the `initialize+0x3a` compare is
not evaluated differently — it is **not reached at all**. The probe never arrives at a3091.
The write does not "not fault"; it does not happen.

### 3.3 And why the FPE image could not have been saved by a restamp

With the stock three-row table, `queue[0] = a3091` and `queue[1]` is empty. A card-1 `rootdev`
would have indexed an all-zero slot. The Z3660 driver is not merely unselected in the FPE
image — it is not linked. The card stamp and the driver set are one decision, not two.

## 4. (d) Does the one differing byte matter?

It is the entire difference, and the metal write-up's "the a3091 driver code is not the
difference" is right for the wrong reason. `0xd79f` is not in a3091 at all — it is the immediate
of `moveq #N,%d1` inside `sd`'s `init()`, and it is edit 2 of three in
`src/patch_z3660.py:24-27,120-127`:

```
BOUND_OFF = 0x0000D79E      # `moveq #2,%d1`
BOUND_OLD = b"\x72\x02"
BOUND_NEW = b"\x72\x03"
```

`0x02` scans three rows — exactly the stock table's 36 bytes. `0x03` scans four — exactly
`z3660_scsicard`'s 48. The byte and the table size are locked together, which is what makes the
coherence assertion in §7 exact rather than a heuristic.

The metal session compared `0xd000..0xe000` and found one byte, then concluded the driver was
identical and the environment was the variable. Both halves are true; the missing step is that
the one byte is the *registry bound*, and the 8,652 bytes of Z3660 driver it exists to reach sit
outside the window that was compared.

## 5. (e) Where the `0x00DD0000` in the COMMON came from

Not from a data initializer, not from loader placement, and not from `.bss` moving under the
extra text.

`device` is a **file-local 8-byte object in `.bss` at offset `0x3d68`** — the identical offset
in the FPE image, in the metal known-good, and in `unix-040-f7vs`. Its absolute address differs
only because `.text`+`.data` ahead of it differ:

```
FPE image        0x08000000 + 0x0fc600 + 0x01a984 + 0x3d68  =  0x0811ACEC
```

which is precisely the address the metal session read the value out of. It is zero at load.
`autocon()` writes it at `d546` as an out-parameter — the base address of the board it found —
and the `cmpil` two instructions later is the driver checking that what it found is the A3000
built-in. The pointer was correct because `autocon()` did its job; the fault is that on this
rig `0xDD0000` is a phantom answer to the probe rather than a controller.

The +18,596 B of `.text` are causally irrelevant to the panic. They move `device`'s absolute
address and nothing else about it.

*(Left open, and not needed for the fix: why `autocon(0x0202f003, …)` answers at all on an
A4000. Whatever supplies the answer — a bootloader-side table, a firmware-side echo — the
consequence is the same and is now documented: on this rig card 0 exists in `queue[]` as a
phantom, and any I/O issued to a `c0`..`c7` node will bus-error in `initialize()`. This is also
why card ordering is fragile: the Z3660 is card 1 only because the phantom sorts below it. If
the phantom ever stopped answering, `ced0s1` would stop resolving.)*

## 6. The 128 MiB / `0x08000000` limb — refuted

The metal session's registered round-6 hypothesis was that the FPE kernel had only ever booted
at 16 MiB with load base `0x07000000`, and that 128 MiB at `0x08000000` was the untested
variable. Three independent facts refute it as the cause:

1. **The faulting address is fixed hardware.** `0x00DD0002` is not derived from the load base,
   the RAM size, or any kernel address. It is a motherboard I/O address, compared against a
   compiled-in literal `#0x00DD0000` at `d556`.
2. **The pointer is run-time-written and its holder did not move relative to anything.**
   `device` is `.bss+0x3d68` in every kernel in this lineage (§5).
3. **The control isolates it.** The known-good ran on the same card, same CPU, same clock, same
   ratified timings, same 128 MiB, same load base and the same root image, and reached multiuser
   at t+46 s. The only variable was the kernel — and within the kernel, the only relevant
   difference is the root-storage family.

The cheap discriminator round 6 proposed (boot the same FPE kernel at `amix_ram 16`) is
therefore **withdrawn**: it would have cost a metal session to test a variable that is not in the
causal path. `amix_ram 16` would panic identically.

## 7. The defect that is `relink-040-fpe.sh`'s own — and the fix

`relink-040-fpe.sh` is base-parameterized by design (`IN="${1:-$HERE/build/unix-040}"`), and
`FPE-GLUE-DESIGN.md` §8.4 is explicit that the `*_fpe_orig` aliases are `nm`-derived from
whatever base is handed in. That design is sound and is not what failed — it was verified
against the metal base in the course of this analysis (§8).

What failed is that **the script prints the base's sha256 and then says nothing else about it.**
All fifteen registered assertions (`FPE-GLUE-DESIGN.md` §8.5) are about the FPE glue: the
pinned tarball, the 396-byte `.bss`, the override count, unresolved symbols, `ucp_magic`,
section alignment, the relocation checks. Not one of them looks at what kind of kernel the base
*is*. So an FPE build inherits its root-storage family silently, and the one fact a deployment
decision needs — which controller this kernel will mount root through — is the one fact absent
from its own build log.

That omission is what round 6 cashed in. It is not specific to the FPE lane, and it would bite
any base: the same script, handed any card-0 kernel, will cheerfully produce an artifact for a
rig that cannot boot it.

**The fix, registered here before it is written.**

* New `src/check_root_family.py`. Decodes, from the artifact and not from the recipe:
  `rootdev` → major / minor / card / target / slice / node name; `bo_name` (the swap node);
  the `scsicard[]` table the `lea` relocation at `.text+0xd74c` actually names; that table's
  row count from its symbol size; the loop bound byte at `.text+0xd79f`; and which of
  `a3091queue` / `a2090queue` / `a2091queue` / `z3660queue` are linked. Prints one FAMILY line.
* It **asserts**, and fails closed on:
  1. `bo_name`'s controller digit == `rootdev` minor & 0x0F — the same consistency rule
     `tools/stamp-card1.py:230-234` enforces at stamp time, now re-checked at link time;
  2. loop bound + 1 == the named table's row count (`size / 12`) — the pairing
     `patch_z3660.py` establishes, so a retargeted table with a stale bound cannot ship;
  3. `rootdev`'s card is `< SDCARDS` (2), and every row the loop will scan names a `*queue`
     symbol that is actually defined;
  4. an optional `--expect <family>`, so a build that knows its target rig refuses a base of the
     wrong family instead of discovering it on the bench.
* `relink-040-fpe.sh` runs it as step 0.5 — **on the base, before any work** — and again on the
  finished artifact, and prints the family in the closing "expect" block. `FPE_EXPECT_FAMILY`
  passes the expectation through.

What it deliberately does **not** do is decide which family is right. It cannot: whether card 0
is a real A3000 controller or a phantom is a property of the rig, not of the image. It makes the
family loud and machine-checkable, and it makes the *internally incoherent* combinations
impossible to build.

The `ucp_magic` gate's diagnostic is also corrected: it names `src/ucz_dbg.s`, but `ucp_magic`
is defined by `src/ucp_dbg.s:386`, `src/ucp2_dbg.s:434` and `src/ucz_dbg.s:382` alike, so the
message can name the wrong file — as it did in §8. The gate itself is unchanged.

## 8. The base for the round-7 artifact, and the assertion that could not be satisfied

The designed-for answer — run the FPE second pass over the metal known-good — was attempted
first, over `build/unix-060-f8a1-CARD1-ced0s1` itself. Log:
`Amix/tmp/2026-08-27-fpe-r7-kernels/logs/00-attempt-over-f8a1.log`.

Everything about the glue passed. In particular the §8.4 override discipline is demonstrably
intact against the metal base — every `*_fpe_orig` alias resolved to the base's own arm, and
each of the seven overrides landed past the base's `.text` end:

```
      fpuinit -> fpuinit_fpe_orig @ 0x000da7e4        ...     fpuinit overridden (0xfef44, past the base's .text end)
      fpu_save -> fpu_save_fpe_orig @ 0x000da658      ...     fpu_save overridden (0xfee20, …)
      fpu_restore -> fpu_restore_fpe_orig @ 0x000da6f2
      fpu_setup -> fpu_setup_fpe_orig @ 0x000da78a
      fpu_setup_gated -> fpu_setup_gated_fpe_orig @ 0x000da8ec
      setregs -> setregs_fpe_orig @ 0x000dbd6e
[OK] no unresolved symbols
```

Those six addresses are **identical in `build/unix-040`, `build/unix-040-f7vs` and
`build/unix-060-f8a1-CARD1-ced0s1`**, because all three carry the same `relink-040.sh` 060 arms
inside the shared 1,004,392-byte prefix. The chain ours → this port's 060 arm → the stock body
is the same chain on the metal base as on the bench base. `M68Kvec[11]` names `fpsp_vec11` in
the metal base — `patch_fpe_vec11.py`'s `ALLOWED_PREV` precondition is satisfied, verified and
not assumed, so the FPSP integration is present and the decline path will be given it.

Then:

```
[FAIL] src/ucz_dbg.s is linked into this kernel and must not be -- see
       FPE-GLUE-DESIGN.md section 7.
```

**This is the registered assertion "`ucp_magic` absent" (§8.5) doing its job, and it is not
weakened here.** The unit actually linked into `f8a1` is `src/ucp2_dbg.s` (attempt-8 ARM I), not
`ucz_dbg.s` — but all three ucontext arms define `ucp_magic`, and §7 of the design document is
explicit about why the gate is symbol-shaped rather than reasoning-shaped: "the two units cannot
coexist in one image regardless of what either file's internal gates do."

So the base is moved one link back up the same chain, to the **direct parent** of the metal
known-good:

**`build/unix-040-f7vs`** — `d43a59ccb7df2ebcdf611a7fa322dd84a4c2166fa9d491078025ef4f9e0fa889`

| property | value |
|---|---|
| relation to the metal known-good | its `.text` is a **0-difference prefix**; `f8a1` = `f7vs` + `ucp2_dbg.o` |
| Z3660 driver | `z3660queue`, `z3660_scsicard` (4 rows), bound `3` — present |
| `z3660_cache` | `D` (defined), i.e. `--cache 60` applied — the arm `relink-040-f7.sh:20-22` calls "the difference between reaching userland and stopping at swapconf's lookup" |
| campaign instruments carried | `uft_have`, `swa_magic`, `kvd_aud_n` — all census-only |
| `ucp_magic` | **absent** — the FPE gate passes |
| `M68Kvec[11]` | → `fpsp_vec11` |
| `rootdev` / `cputype` | card 0 / 40 — restamped after the FPE pass, exactly as the metal lineage does |

`build/unix-040-f7base` was rejected as the base: `z3660_cache` is still `C` (COMMON) there, so
the cache arm has not been applied.

`f7vs` has not itself been booted — it is an intermediate, and its descendants `f7vsu`, `f7vsm`
and `f8a1` are what the campaign booted. That is stated plainly rather than glossed: the round-7
FPE artifact is the metal known-good **minus a pure-observation ucontext arm, plus the FPE
lane**, and every other byte of the proven kernel is preserved.

The pipeline, in the metal lineage's own order (stamps last):

```
sh relink-040-fpe.sh build/unix-040-f7vs build/unix-040-fpe-metal
python3 tools/stamp-card1.py   build/unix-040-fpe-metal  build/unix-040-fpe-metal-CARD1-ced0s1
python3 tools/stamp-cputype.py build/unix-040-fpe-metal-CARD1-ced0s1 \
                               build/unix-060-fpe-metal-CARD1-ced0s1 --set 60
```

and the same two stamps over `f7vs` itself produce the **A/B control**: a kernel differing from
the FPE artifact only by the FPE second pass.

`FPE=0 sh relink-040-fpe.sh build/unix-040-f7vs …` reproduces `f7vs` byte for byte under the
script's own sha gate — run before anything else, and recorded in §10.

## 9. A stock defect, named and not fixed: the panic handler dies on the dead controller

```
PANIC:        pc=0x800D578  initialize+0x5c        Bus Error
DOUBLE PANIC: pc=0x807199A  s5flushsb+0x18         Bus Error
```

`xpanic` drives the superblock flush through the same controller the panic was taken on, and
takes a second bus error. Any AMIX panic whose cause is an unreachable root controller loses its
own postmortem this way — the second fault arrives before the first one's state has been
reported. It is stock behaviour, it is not in this lane's blast radius, and it is **left
unfixed and recorded here** so the next reader of a `DOUBLE PANIC` screen does not spend the
session on it.

## 10. Pre-registered expectations for the metal retry

Deployment note and artifacts: `Amix/tmp/2026-08-27-fpe-r7-kernels/`.

**Stage** `unix-060-fpe-metal-CARD1-ced0s1` into the boot slice, root image unchanged, and boot
`unix_boot040`. The control kernel `unix-060-f7vs-CARD1-ced0s1` is provided for a same-session
A/B if the FPE row fails.

Registered before the boot:

| # | expectation | rationale |
|---|---|---|
| r1 | **The a3091 probe is not reached at all.** No `initialize()`, no `0x00DD0002` write, no bus error at `pc=0x800D578`. | root is card 1; a3091 is `queue[0]` and receives no I/O (§3.2). The compare at `d556` is *not* expected to be evaluated and take the other branch — the routine is expected never to be entered |
| r2 | `no fpu detected` → `fpu emulation enabled`, in that order | round 6 measured both on this silicon; the lane is unchanged |
| r3 | multiuser (TCP:23), t+40…t+70 s | att9's A/B band for this image and clock; the known-good measured t+46 s |
| r4 | `fpe_cputype_amix = 0x3C` (60), `fpe_cputype = 3`, `fpe_cputype_bad_n = 0` | round 6's first metal read, unchanged by the base swap |
| r5 | `fpe_magic = "FPE!"`, `fpe_enable = 1`, `fpe_armed = 1`, `fpe_setup_n ≥ 1` | as round 6 |
| r6 | `fpe_entry_n` and `fpe_done_n` **large and rising** once userland runs | the row round 6 could not take: FPU-less silicon reaching multiuser must emulate |
| r7 | `fpe_panic_n = fpe_panic_hard_n = fpe_fmtx_n = fpe_super_n = fpe_v11_fmtx_n = 0` | the abort block, as on the bench |
| r8 | `fpe_advmiss_n = 0`, `fpe_advnofetch_n = 0` with `fpe_advctl_n` large — **non-vacuously**, i.e. read only after `fpe_entry_n > 0` | round 6's readings were true but vacuous at `entry_n = 0`; this is the round-5 bench claim's first real metal corroboration |
| r9 | `fpi_savedvec` = the address of `fpe_vec11`; `fpi_nofpu_n = 1` | the arm installed and the probe answered no-FPU |
| r10 | `z3660_cache`, `uft_have`, `swa_magic`, `kvd_aud_n` present and reading as they do under the known-good | the base carries the campaign instruments; they are census-only and must not have changed behaviour |
| r11 | the acceptance ladder b1–b6 (`awk` int/float, `printf %f`, `df -k`, `uptime`, `dz` → SIGFPE code 3) and the FP-dhrystone row, band 65–75 k | blocked in round 6; unblocked by r3 |

**Falsification.** If r1 fails — a bus error at `initialize+0x5c` again — the family analysis
above is wrong and this document is refuted at its root. If r1 passes and r3 fails elsewhere,
the family was necessary but not sufficient and the new stop is a fresh finding.

---

## 11. Artifacts

Built after §1–§10 were committed; the expectations in §10 were registered first. Logs, counter
addresses and a `SHA256SUMS` over all of it: `Amix/tmp/2026-08-27-fpe-r7-kernels/`, with the
deployment note in its `DEPLOY.md`.

| artifact | size | sha256 |
|---|---|---|
| `build/unix-040-f7vs` *(the base)* | 1,878,585 | `d43a59ccb7df2ebcdf611a7fa322dd84a4c2166fa9d491078025ef4f9e0fa889` |
| `build/unix-040-fpe-metal` | 1,931,791 | `4480ad14d81aadb6fd701d9f5bfd79f5a444de5fa8ac5a20925e4bd426f651fc` |
| `build/unix-040-fpe-metal-CARD1-ced0s1` | 1,931,791 | `247285fe954b645dd7020fe29f05b3dc9dd06fd4b466395ef6e4fecc26d8eaa2` |
| **`build/unix-060-fpe-metal-CARD1-ced0s1`** *(stage this)* | 1,931,791 | `b34408152d4f5d405bc6f3d47573e203da4d8626b55e424538592886779251e7` |
| `build/unix-040-f7vs-CARD1-ced0s1` *(control)* | 1,878,585 | `59d45d8dd26da2a67756786e7a8970bbec7b5be60bcdd225f4d46a29ef5070e1` |
| `build/unix-060-f7vs-CARD1-ced0s1` *(control)* | 1,878,585 | `7202172e5c21640b2ba82c1c09cbc2eaf591b7350e10246f6c94c379b20f0fc3` |

`buildid` is `" 68040-260827-61"`, announced as **`68060-260827-61`** at `cputype` 60 — the same
substitution the metal known-good's `68040-260825-70` string makes to `68060-260825-70`.

Every FPE assertion passed against `f7vs` (`logs/02-fpe-over-f7vs.log`): tarball
integrity, 20/20 objects with `.bss` exactly 396 B, all seven overrides with exactly one strong
definition past the base's `.text` end, no unresolved symbols, `ucp_magic` absent,
`M68Kvec[11] → fpe_vec11` with `fpe_decline → fpsp_vec11`, text/data contiguous, both section
sizes 4-aligned, `check_fpe_relocs.py` and the loader simulation clean. `FPE=0` over the same
base reproduces it byte for byte (`logs/01`, and `cmp` independently).

Three identities worth keeping, because they are what §1's argument rests on and they were
re-measured on the finished artifacts (`logs/08`):

```
unix-060-f7vs-CARD1-ced0s1 -> unix-060-fpe-metal-CARD1-ced0s1   .text prefix 1,014,192   0 diffs
unix-060-f7vs-CARD1-ced0s1 -> unix-060-f8a1-CARD1-ced0s1        .text prefix 1,014,192   0 diffs
unix-040                   -> unix-060-fpe-metal-CARD1-ced0s1   .text prefix 1,004,392   1 diff @0xd79f
```

The FPE artifact and the metal known-good therefore share every byte of `f7vs`; they differ only
in what each appends — the FPE lane in one, the attempt-8 ucontext arm in the other.

The new gate, run against the round-6 artifact that failed on metal, refuses it:

```
$ python3 src/check_root_family.py …/unix-060-fpe --require-queue z3660queue --require-card 1
   FAMILY    root=card0(/dev/dsk/c6d0s1) queues=a3091queue+a2090queue+a2091queue
REFUSED: --require-queue z3660queue: not among the rows this kernel scans
         (a3091queue+a2090queue+a2091queue). This image cannot serve a rig whose root is on
         that controller, at any RAM size and any load base -- the capability is absent, not
         merely unselected.
REFUSED: --require-card 1: rootdev names card 0 (/dev/dsk/c6d0s1)
```

and passes the metal known-good and all four artifacts above.
