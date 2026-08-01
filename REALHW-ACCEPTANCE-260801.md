# Real-hardware acceptance 2026-08-01 — base `68040-260801-04`

A3000 + Mercury 040, root `/dev/dsk/c6d0s1` (X11R5 disk), copyback (`hat_cm_ram` = `0x20`).
This is the first full acceptance on a base carrying `codepub040` (USER-CODE-PUBLISH) and
`issue39_040`. Every counter address was recomputed for this build
(`0x08000000 + textsize 0xe4588 + .data offset`) and the anchor was read before every reading.

## Result: 9/9 battery + burst 96/96 + the publication ABI accepted

| test | result |
|---|---|
| `exectest 20` | **PASS** — data+bss verified across every generation |
| `proctest` | **PASS** — fails=0, T1–T7 incl. CHILD-PRIV-WRITE and CHILD-COW-WRITE |
| `fputest` | **PASS** — 040 hardware FP correct, native `cc` compiled it |
| `mlocktest` | **PASS** — fails=0, skipped=0; T1 still returns EINVAL at base+2048 |
| `msynctst` | **PASS** — `MSYNC-OK sz=65536` |
| `mincoretst` | **PASS** — vector correct, 2 KiB-offset call correctly EINVAL |
| `bigargv` | **PASS** — 45 args, 4500 bytes |
| `bmaptest /pgc` | **PASS** — fails=0, all 11 cases incl. the 4097..6144 interval and fragment growth |
| `devmaptest` | **PASS** — 3194/4096 non-zero in the kernel-base window, canaries clobbered = 0 |
| `ptracepoke` | **PASS** — 4 POKETEXTs at `0x80000584`, word `0x4e560000`, 0 fails |
| burst battery | **96/96**, zero anomalies (4 rounds × 4 bursts, ~22 min) |
| `codepub` A/B | **accepted** — see `USER-CODE-PUBLISH-260801.md` |

The battery ran detached in **under two minutes** including nothing but the runs themselves
(compiles done separately). No panics, no traps, no console noise.

## The instruments, and one exact confirmation

```text
hat_cm_ram      0x20  before and after everything          (the anchor)
codepub_on      1
codepub  calls  0x137 -> 0x13b   exec 0x131 -> 0x135   push 0x12c -> 0x130
                +4 / +4 / +4  -- gap held at exactly 5, every publication performed
hat_pfnmiss_n   0x0a -> 0x0c    == +2
hat_badaslot_n  0x1c6b -> 0x1c99  (+46)
hat_sdtfail_n   0        i39_fail_n  0
```

**`hat_pfnmiss_n` moved by exactly +2, and only devmaptest could have done it.** The 2026-07-31
calibration says the counter advances by exactly 2 per `devmaptest` run and by zero from
everything else. This run put ten programs through it — nine of them plus `bmaptest`'s 200
fragment appends — and the counter moved by two. A calibrated instrument reporting exactly what
it was calibrated to report is worth more than a test that passes.

The publication counters also say the whole battery cost **4** publications, i.e. the barrier is
as absent from real workloads on hardware as the 100-exec measurement said it was.

## Test-environment notes, so a later reader does not misread a FAIL

* `/pgc` is created by `batteryrun.sh` before `bmaptest` runs. Without it `bmaptest` reports FAIL
  from an empty test environment, which is not a kernel result.
* `va2000probe` is deliberately **not** in this battery: its version reading is garbage even when
  the card works, so it can only mislead.
* Dhrystone is not on this root disk; the +64 % copyback figure was not re-measured. The
  publication barrier's cost was settled by counting instead — 100 execs and a full `cc` compile
  produced zero publications.

## RTG kernel — `unix-040-rtg-260801-05`, the Model-B header set's hardware exposure

The same base with both graphics drivers linked in, and the **first kernel ever compiled through
the Model-B mirror sysroot** (`MODELB-HEADERS-260801.md`). Booted 18:05.

Its `.text` is `0xed5b4` against the base's `0xe4588`, so **every counter address moves**;
`rtgcheck.sh` reads the two anchors first and refuses to continue if either is wrong.

| check | result |
|---|---|
| boot to multiuser | **`68040-260801-05`** |
| anchors | `hat_cm_ram` @`0x081058B4` = `0x20`; `i39_magic` @`0x08105FC8` = `0x49333921` |
| `devmaptest` | **PASS** — 3194/4096 non-zero, canaries clobbered 0 |
| `exectest 20` | **PASS** |
| `hat_pfnmiss_n` | 10 → 12, **exactly +2** — the 31.7. calibration now holds on a *different kernel* |
| Xsvga driver on the physical Piccolo | `CardID=3 (Piccolo) FrameBufSize=2097152 MaxPixClk=85 Blitter=1 Panning=1` |
| VA2000 driver | `open(/dev/va2000) OK, fd=3` — `cdevsw[68]` live |
| **X11R5 on the Piccolo** | **PASS — `twm` and `xterm` on screen, keyboard and mouse responding** |
| `codepub` under X | 98 → 178, `calls == exec == push` throughout |
| `hat_sdtfail_n` | 0 |

`hat_pfnmiss_n` stayed at 12 **with X running**, which is what the 2026-07-31 calibration
predicts ("~10 at boot, exactly +2 per `devmaptest`, and zero from wolf3d, both X servers,
compiles and two burst suites"). Starting X made ~80 `PROT_EXEC` `mprotect` calls — the X server
and its clients are dynamically linked — and **every one of them performed the barrier**.

Two things recorded as they are, not as one would like them:

* `/dev/va2000` **did not exist** on this root disk and was created here
  (`mknod /dev/va2000 c 68 0`). `/dev/svga0` has been there since 1992 and is what `Xsvga` uses.
* **`Xrtg` is not on this root disk, nor on the NAS.** The VA2000 *kernel driver* is proven
  registered and openable; **X on top of it is not tested here**. That is a gap in coverage, not
  a failure, and it blocks nothing.

Under X at 20 minutes uptime: `availrmem` 6559, `pages_pp_kernel` 1162 — draining per ISSUE-40 as
every kernel does today, healthy otherwise. The i39 pointer resolved to `0x081263f0` on this
kernel against `0x0811c5b4` on the base, which is exactly why the pointer table exists: a
computed `.bss` offset would have been wrong.

**Verdict: the Model-B header set is accepted on hardware.** It is inert for the shipped drivers
by construction (the va2000 object is byte-identical with and without it), and the kernel built
through it boots, drives both cards, and runs X.

## Artefacts

NAS `amix/hwtest-260801/`: `battery-260801.log`, `burstloop.log`, `memwatch-burst.log`,
`codepub-ab-buserror-260801.jpg` (the A/B control run's console), and every test source.
Left staged on the machine for repeat runs: `/payload.bin`, `/pgc`, `/tmp/hat_dup_cow`,
`/tmp/burstrun.sh`, `/tmp/batteryrun.sh` and all ten test binaries.
