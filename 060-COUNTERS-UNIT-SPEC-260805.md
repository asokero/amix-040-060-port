# Unit spec — 060 fault-path counters + PCR readback (F1, 2026-08-05)

One unit, two additions, one hardware boot. Written before the code, per working practice.

**Why now.** `M68060-XPAGE-ACCEPTANCE.md` is a static PASS whose runtime verdict is blocked on a
single missing thing: nothing in the kernel counts format-4 frames, so a boot that works proves the
060 paths were *survived*, not *exercised*. F0 (2026-08-05) showed the 060 does generate fmt-4
frames — the SetPatch panic's second frame was `fmt=0x4` — but that was a kernel fault on a
misconfigured `cputype`, not the user fault path under test. And F0 left one performance question
unanswerable: the kernel has no PCR access at all, so superscalar dispatch (ESS) is unmeasured.

Both are pure instrumentation: no control flow changes, no policy changes.

---

## A. Counters in `prototypes/wb040.s`

Same shape as the existing `wb_dfc_*` block: `.data` longs, `.globl`, read with `/kpeek` at
`0x08000000 + textsize + nm(.data offset)`, recomputed per image.

| symbol | incremented where | means |
|---|---|---|
| `x60_fmt4_n` | `wb060_sswsynth`, after the `cmpiw &4` succeeds | format-4 frames seen by the wrappers |
| `x60_ma_n` | `wb060_xpage` at `Lwx_ma` | MA tier taken — the architecture contract |
| `x60_compat_n` | `wb060_xpage` tier 2, after the `0xff8` window test passes | compat tier taken (MA clear) |
| `x60_rw_read_n` | MA tier, the `S_READ` branch | far `as_fault` got `S_READ` |
| `x60_rw_write_n` | MA tier, `Lwx_wr` | far `as_fault` got `S_WRITE` (write and locked RMW) |
| `x60_far_fail_n` | MA tier, after `Lwx_call` returns non-zero | far-page resolve failed and was propagated |
| `x60_last_fa` | MA tier and compat tier | last faulting FA, unmodified |
| `x60_last_fslw` | `wb060_sswsynth`, on a fmt-4 frame | last FSLW **before** sswsynth overwrites its upper word |

`x60_last_fslw` must be stored in `sswsynth`, not in `xpage`: `sswsynth` overwrites FSLW bits 31–16
in place, so by the time `xpage` runs the only surviving copy is the one carried in `d5`. Storing
it at the source also means it is captured for frames that never reach `xpage` at all.

### Constraints

* **`x60_fmt4_n` counts frames, not resolutions.** `sswsynth` runs from both `usrxmemflt` and
  `krnxmemflt`, so this counts both user and kernel fmt-4 faults. That is what we want for the
  "were the paths exercised" question; it is not a per-crossing count.
* **No register may be disturbed.** `sswsynth` documents its clobber set as d0/d1/d2 and returns
  the original FSLW in d0; `wb060_xpage` promises to preserve d2–d4/a2–a3 and returns a
  propagation flag in d0. Counter updates therefore use `addql &1,<abs>` and memory-to-memory
  `movel`, which touch no register.
* **`Lwx_call` is a subroutine used by both tiers**, so `x60_far_fail_n` is incremented in the MA
  tier *after* the `bsrw`, not inside `Lwx_call` — the compat tier deliberately discards its
  result and must not be counted as a failure.
* **040 path stays semantically identical.** Every increment sits inside a branch that only a
  format-4 frame reaches; the 040 (fmt-7) executes none of them. Addresses shift, so the image is
  not byte-identical — the invariant is that the instructions the 040 *executes* are unchanged.

### Pre-registered reading (from `M68060-XPAGE-ACCEPTANCE.md` §"Remaining acceptance tests")

1. A crossing access whose operand begins **before** `page+0xff8` → `x60_ma_n` > 0 with
   `x60_compat_n` unchanged. This is the hardware answer the document is waiting for.
2. Read, write and locked-RMW crossings → `x60_rw_read_n` / `x60_rw_write_n` / `x60_rw_write_n`.
3. A protected or unmapped far page after a valid near page → `x60_far_fail_n` > 0, terminating
   through the normal signal/nofault path, no retry loop.
4. The 040 ISSUE-37 crossing test stays a dual-CPU regression; `wb_replay_n` must still show the
   format-7 helper running exactly once.

**If hardware shows a crossing frame with MA clear** (`x60_compat_n` > 0 while `x60_ma_n` == 0 for
a known crossing), that is new evidence and the acceptance verdict reopens — the document says so
explicitly, and it is why the compat tier exists.

Workloads that already produce crossings: `segspan`, `readtail`, the wolf3d ISSUE-37 case.

---

## B. PCR readback in `prototypes/pstart040.s` + `prototypes/cputype060.s`

`movec %pcr,%d0` (control register `0x808`) exists only on the 68060 and traps as illegal on the
040, so it must be `cputype`-gated. `cputype` is loader-poked before the kernel runs, so it is
already valid this early.

* New global `pcr_boot` in `cputype060.s` (data-only file, next to `cputype`), initialised to
  `0xFFFFFFFF` so "never executed" is distinguishable from a real PCR of 0.
* In `pstart040.s`, immediately **after** the CACR enable block (the caches are then in their final
  state and nothing else has run), gated on `cputype == 60`:

```
    movel   cputype,%d0
    cmpil   &60,%d0
    bnew    Lps_nopcr
    .word   0x4e7a,0x0808        | movec %pcr,%d0
    movel   %d0,pcr_boot
Lps_nopcr:
```

Assembler does not know the 060 mnemonic, so the `.word` idiom is used exactly as `ptest040.s` and
`pstart040.s` already do for `ptestr`/`cinva`/`movec %cacr`.

Decode of what we get back:

| field | meaning |
|---|---|
| bits 31–16 | revision / ID (`0x0430` on the 68060) |
| bit 1 | EDEBUG |
| **bit 0** | **ESS — superscalar dispatch enable** |
| bit 2 (of the low byte region, per the 060 UM) | DFP — disable FPU |

This answers, in one boot, whether F0's "exactly 2.0× the 040" is simply the clock ratio of a
scalar-dispatching 060 (ESS=0, which `68060-prestudy.md` §3.4 says was the intent) or something the
cache knobs could address (ESS=1). **060-D must not start before this is known.**

### Risk note

`pstart040.s` is the most boot-critical file in the port. Five instructions behind a `cputype`
gate is small, but a mistake there is a machine that does not boot. Mitigations: the gate means the
040 executes exactly one extra compare-and-branch; both emulator CPU configs must boot before any
hardware boot; and `pcr_boot`'s `0xFFFFFFFF` sentinel makes a silently-skipped read visible.

---

## Emulator verification — DONE 2026-08-05, both CPU configs

Image `68040-260805-01`, textsize **`0xe48b8`** (the loader's own `tsize=000e48b8` confirms it
independently), `check_relink_relocs.py`: **0 complaints**. Counters read live over the Amiberry
IPC (`READ_MEM`, **tab-separated** — space separators return `Unknown command`), which needs no
guest tooling and does not halt the emulator.

| symbol | emulated 040 | emulated 060 | reading |
|---|---|---|---|
| `cputype` | 40 | 60 | loader prints `kernel cputype set to 60` |
| `pcr_boot` | **0xFFFFFFFF** | **0x04300601** | 040 gate holds; 060 revision `0x0430`, **ESS=1**, EDEBUG=0 |
| `x60_fmt4_n` | **0** | 8354 | equals `wb_dfc_n` (8354) — on the 060 essentially every fault frame is format 4 |
| `x60_ma_n` | **0** | 11 | MA tier is reached |
| `x60_compat_n` | **0** | 3 | compat tier is reached |
| `x60_rw_read_n` | **0** | 11 | all MA crossings so far were reads |
| `x60_rw_write_n` | **0** | 0 | **not yet exercised** — acceptance test 2 needs a write/RMW crossing |
| `x60_far_fail_n` | **0** | 0 | no permanent far-page failure in a clean boot |
| `x60_last_fa` | 0 | `0xC10DBFFE` | offset 0xFFE — two bytes before a page boundary |
| `x60_last_fslw` | 0 | `0x01810200` | RW field (24-23) = 11 = **locked RMW**, MA clear, TM=1 (user data) |
| `wb_replay_n` | 1944 | **0** | the format-7 helper does not run on the 060, as designed |

Both gates verified in the direction that would have caught a mistake: the 040 executed **no**
`x60_*` increment and left `pcr_boot` at its sentinel (a leaking `movec %pcr` would have taken an
illegal-instruction trap instead), and the 060 moved every counter that has a reachable path.

**Note on the emulator's PCR.** ESS=1 here is *Amiberry's* choice and says nothing about the real
machine — the hardware answer is one `/kpeek` away, which is the entire point of the unit.

**Two things the emulator run did NOT establish**, per campaign rule 4:

* **MA fidelity.** UAE cores may set MA differently from real silicon. `x60_compat_n = 3` means the
  emulator produced crossing frames with MA clear; on hardware that same reading would be new
  evidence that reopens the acceptance verdict. Here it is simply not proof either way.
* **The write/RMW path** (`x60_rw_write_n` = 0). A boot does not generate a write crossing that
  reaches the MA tier. Hardware needs a targeted workload — `segspan`, `readtail`, or the wolf3d
  ISSUE-37 case.

Aside found while running this: `emu-reset-boot.sh` prints `build id: ?` because it reads the id
from a fixed offset that this image's new `.data` symbols moved. Cosmetic, not fixed here.

## Verification order

1. Build. `check_relink_relocs.py` must report 0.
2. `emu-reset-boot.sh 040` — boots, `exectest 20` PASS, `wb_replay_n` behaves as before,
   all `x60_*` remain 0 (an 040 must never touch them), `pcr_boot` still `0xFFFFFFFF`.
3. `emu-reset-boot.sh 060` — boots, `pcr_boot` non-sentinel, `x60_fmt4_n` > 0.
   Amiberry is **not** accepted as evidence for MA behaviour; it is a regression gate only.
4. Hardware (needs SetPatch first, then `unix_boot`): battery 10/10 + burst as the regression
   floor, then the four pre-registered readings above, then `pcr_boot`.

Addresses get recomputed for the new image before anything is read, and the magic words
(`i39_magic`, `i40_magic`, `ptd_magic`) get checked first — the new `.data` symbols shift
everything after them.
