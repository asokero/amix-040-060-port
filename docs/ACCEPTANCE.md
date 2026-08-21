# How a kernel is tested and accepted here

This is the procedure, in one place. It existed as tacit knowledge and as twelve dated acceptance
records, which is fine while one person runs the hardware and stops being fine the moment two
people do.

`AGENTS.md`'s "Before you claim you are finished" list is **host build gates only**. Passing it
means the kernel links and the overrides bind. It does not mean the kernel works, and nothing in
this repository said so until now.

> **This document is reconstructed** from `docs/REALHW-*-ACCEPTANCE-*.md` — from what was actually
> run, not from what ought to have been. Pass criteria and ordering are the owner's knowledge and
> should be corrected here rather than carried in anyone's head.

## 1. Say which platform, always

Every claim names where it was measured. The classes are not interchangeable and must not be
collapsed into "it works".

| class | what it means |
|---|---|
| `EMU` | Amiberry, 040 or 060 core |
| `HW` | real silicon: a Mercury (68040 or 68060) or an A3640, named |
| a third platform | e.g. a Z3660's own 68040 emulation — **its own class, neither of the above** |

`AGENTS.md` lists four things Amiberry is **not evidence for** — no enabled FP exceptions, never
sets the first write-back slot valid, does not model the 68040 copyback data cache, and is not
proof of which instructions a CPU traps as unimplemented. ISSUE-38 could only be found on silicon
for exactly that reason.

**A new platform must arrive with its own such list.** Only whoever built it knows what it does
not model, and without that list its results will be read as stronger than they are. Ask for it
before accepting results from it.

## 2. Read the identity before believing any number

A stale address does not fail. It returns a plausible number from whatever now lives there.

1. `uname -m` — the build id. Note that the prefix reports the **CPU**, not the image: the same
   file reads `68040-…` on one card and `68060-…` on another.
2. **Every counter block's magic word**, before any counter in it. `sh tools/status-facts.sh`
   prints the runtime addresses and the magic read out of the artifact.
3. If a magic does not match, **stop**. Every other reading from that block is noise.

**The battery driver is generated for the image and its load base, never reused.** Counter
addresses are `load_base + textsize + nm(.data offset)`, and the load base is not constant: a
Mercury binds at `0x08000000` and an A3640 at `0x07000000`, so every address moves by 16 MiB
between them. The generated driver aborts on a magic mismatch before reading a single counter.

## 3. Choose the level by blast radius

Not everything needs silicon. Deciding this first is what keeps work from queueing behind hardware
sessions.

| what the change touches | what it needs |
|---|---|
| a variant relink script, or glue only that variant links | the host gates, and the variant builds clean |
| shared tooling (`tools/`, `test-tools/`) | host gates + one emulator boot |
| **the base** (`src/*.s`, patchers used by `relink-040.sh`) | **host gates + emulator on both CPUs + silicon** |

Two standing rules for base changes, both checkable without hardware:

* a `cputype`-gated change must leave **the other CPU's path byte-identical** — check it in the
  disassembly, not by argument;
* if a change should not affect the base at all, prove it: the image should differ only in the
  build-id stamp.

## 4. Host gates

```sh
git ls-files --others --exclude-standard   # must print nothing
sh tools/check-env.sh                      # exit 0
sh tools/test-build-step.sh                # exit 0
python3 tools/check-verbatim.py            # 0 unexplained.  EXIT 2 IS NOT A PASS
sh relink-040.sh                           # exit 0 and TOTAL complaints: 0
sh tools/status-facts.sh                   # exit 0 and bindings failing: 0
```

`ld -r` does not fail on a missing override definition, so the exit status proves nothing on its
own — `bindings failing: 0` is the evidence.

## 5. The battery

Nine programs, run from a generated driver (`test-tools/batteryrun*.sh`). Each prints
`<NAME>-RESULT PASS` or `FAIL`, so the reading is mechanical: **grep the log for `-RESULT` and
require no `FAIL` anywhere.**

```
  proctest        /proc process memory            T1-T7, both child cases
  fputest         FP arithmetic                   "Test A PASS" on a 68040
  msynctst        msync                           MSYNC-OK
  bigargv         large argv/env                  45 args, 4500 bytes
  ptracepoke      ptrace poke path
  mul64test       64-bit multiply                 the 68060 vector-61 path
  bmaptest        block map
  exectest 20     exec across generations         data+bss verified each generation
  leaktest 50 1   fork+exec pressure              fork_failures=0
```

Others are run when their area is touched rather than every time: `devmaptest` (device mmap page
geometry), `mlocktest`, `mincoretst`, `xpagetest`, `codepub`, `protfault` (denied-write-back and
partial-page protection), `swapls`, `segwrite`, `nfstruth` / `nfsreadtruth` (NFS integrity measured
in **bytes from the server**, never in file size).

`test-tools/README.md` documents what each program measures. Build on the guest with
`cc -o NAME NAME.c` — they are compiled by the native 1991 SVR4 `cc`, so they are K&R C.

## 6. What the CPU adds

**68060 only:**

```
  fp060probe        7/7 bit-exact, 0 ulp, bad=0
  ftest060 unimp    "Unimplemented FP instructions ... passed", died=0
  ftest060 main     four sub-tests passed, died=0
  isp61ea           7/7 addressing modes, bad=0
  fpenab060 <CLASS> all six enabled exception classes bit-exact, bad=0
  fputest060 fork   FP state across fork
```

**68040 only:** `fputest` "Test A PASS" — the FPSP on the 040 path.

⚠ Motorola's `ftest060` **cannot pass under Amiberry**: the emulated FPU does not preserve the
extended NaN in `DEF_FPREGS`. Do not read its "failed" there as an FPSP defect.

## 7. Durability — silicon only, and worth the time

* **Burst suite** — sustained disk and network transfer with byte comparison. The recorded results
  are `96/96` sums with every anomaly counter at zero, and `72/72` on the A3640.
* **Power-cut disk truth** — write files, pull the power, `fsck`, compare every byte:
  `B2RT-RESULT PASS (6 files, every byte intact) after a real power cut + fsck`. Recorded as `6/6`
  and `8/8` across sessions. This is the only test that speaks to write-back and cache-mode
  correctness under a real failure.

Neither can be replaced by the emulator, which models neither the copyback data cache nor a power
cut.

## 8. Graphics kernels

A graphics variant (`relink-040-va2000.sh`, `-xsvga`, `-rtg`) is accepted by running real clients,
because a cache-class or mapping mistake does not crash — it puts intermittent garbage on screen.

```
  X11              starts and is usable
  wolf3d           plays, no corruption during sustained drawing
  Quake            plays, no corruption
```

For cache-class or aperture work, add the structural evidence, which the applications cannot give.
**The two instruments below arrive with the Zorro III branch** (`wip/zorro3`) and are not on `main`
yet; until it merges, this subsection describes the intended practice rather than something a fresh
clone can run:

* `cmfcensus <cmf_magic-addr> <device> <offsets…>` — reads the **live leaf PTE** for a page and
  decodes its cache mode. Fault one page at a time with X stopped; require a **positive** counter
  delta, never exactly one, because the retained 2 KiB `segdev` stepping classifies the same 4 KiB
  leaf twice.
* `busbench -r` **first**, then the aperture with its framebuffer offset. The reference is
  per-session and absolute numbers do not compare across images. Pass the framebuffer's offset —
  mapping from the aperture base measures the register window, and on some firmware the undecoded
  gap between them kills the process (ISSUE-47, likewise on the Zorro III branch).

## 9. Counters: an invariant beats a passing test

Diff every counter block before and after the run. **What did not move is as informative as what
did**: a counter at zero after a run that should have exercised it means the path was not reached,
not that it passed. Two counters that cannot both be true have caught defects here that green test
suites did not.

## 10. Record it

A measurement without a document is a measurement that will be lost. Write
`docs/REALHW-<image>-ACCEPTANCE-<date>.md` containing:

* the machine, the CPU card, the image and its build id;
* the identity readings — `uname -m` and the magic words — before anything else;
* **the expectation, registered before the run**. A prediction that fails is the useful result; one
  written afterwards is not a prediction;
* every test and its result, including the ones that were skipped and why;
* and a section headed **what this does not establish**. That section is not modesty. It is where
  the next reader finds out which of your claims they may lean on.

Refuted conclusions stay in the record, labelled refuted (`STATUS.md` §7). Do not tidy them away —
the reason a hypothesis failed has repeatedly outlived the hypothesis here.
