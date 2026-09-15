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

**The battery driver is image- and load-base-specific, prepared from generated status facts —
never reused from an earlier run.** Counter addresses are `load_base + textsize + nm(.data offset)`,
and the load base is not constant: a Mercury binds at `0x08000000` and an A3640 at `0x07000000`, so
every address moves by 16 MiB between them. `tools/status-facts.sh` generates the addresses; the
`batteryrun*.sh` drivers are then assembled or re-addressed by hand. There is no generator for the
driver itself, and calling it "generated" claims more than exists.

> ⚠ **The driver does not necessarily check every block it reads, and it says it does.**
> `test-tools/batteryrun10.sh` reads **nine** counter blocks and verifies **eight** magic words —
> `segvn_prot` at `0710B1F4` is read (lines 36 and 56) and never checked — while its own header
> line 4 states "Each block's magic is checked before its counters are believed". This is a
> regression rather than an omission: `batteryrun6.sh` did verify `segvn_prot_magic`
> (`docs/REALHW-260807-11-ACCEPTANCE.md` §5).
>
> Consequence: `docs/REALHW-A3640-260813-ACCEPTANCE.md` §6 says "it did not abort, so all **nine**
> blocks were addressed correctly". Eight were. **Count the magic checks against the blocks read
> before trusting any driver**, and fix the driver rather than the sentence. This deserves a
> numbered issue once the open branches converge.

## 3. Choose the level by blast radius

Not everything needs silicon. Deciding this first is what keeps work from queueing behind hardware
sessions.

| what the change touches | what it needs |
|---|---|
| a variant relink script — build wiring only, no new executable code | the host gates, and the variant builds clean |
| **glue a variant links** — MMU, FPSP, cache or device code | host gates **+ a boot of that variant + a test aimed at what the glue does** |
| `tools/` (host build/verification) | host gates; a broken host tool cannot reach the kernel |
| `test-tools/` (runs on the guest) | host gates + run the changed tool on the emulator; a wrong instrument reports a wrong result, which is worse than no result |
| **the base** (`src/*.s`, patchers used by `relink-040.sh`) | **host gates + emulator on both CPUs + silicon** |

The second row is the one that is easy to get wrong. "It only touches the variant" is a statement
about *linkage*, not about *execution*: code that runs in supervisor mode on a real MMU needs a
boot and a targeted test whichever script links it.

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

**Then rebuild and diff** (`AGENTS.md`, end of the same section). Two builds of the same tree differ
only in the build-id stamp. After any infrastructural change that byte-for-byte comparison is the
regression test for the build system itself: a change that alters other bytes has done something
unintended, and that is worth finding out before going further.

## 5. The battery

### The pass oracle: match a per-test line, never a generic pattern

**Do not grep for `-RESULT` and require no `FAIL`.** That rule is wrong and it fails the dangerous
way — green on a broken battery. Checked against the sources:

| tool | prints | why the generic rule misses it |
|---|---|---|
| `fputest` | `FPUTEST Test A PASS` / `... FAIL` | no `-RESULT` at all: a **failure is invisible** to a `-RESULT` grep |
| `mul64test` | `MUL64-RESULT PASS` / `MUL64-RESULT WRONG` | the failure word is `WRONG`, so a `FAIL` grep misses it |
| `msynctst`, `bigargv`, `leaktest` | no `RESULT` token anywhere | not covered by the convention at all |

Every one of them also **`exit(0)` regardless of outcome**, and `batteryrun*.sh` does not stop on a
test's exit status. So neither the exit code nor a generic grep is an oracle.

**The rule is: each test has one expected success line, matched exactly; a missing line is a
`FAIL`, not a pass.** These are the lines an accepted run actually produced
(`docs/REALHW-260807-11-ACCEPTANCE.md` §5):

```
  PROCTEST-RESULT PASS
  FPUTEST Test A PASS
  MLOCKTEST-RESULT PASS
  PTRACEPOKE-RESULT PASS
  DEVMAPTEST-RESULT PASS
  MUL64-RESULT PASS
  MSYNC-OK path=/msync_test.dat sz=65536
  MINCORE PASS
  BIGARGV PASS 45 args 4500 bytes
  BMAPTEST-RESULT PASS
  EXECTEST-RESULT PASS (data+bss verified across every generation)
  PROTFAULT-RESULT PASS  (a and b)
```

The driver should end with a single `BATTERY-RESULT PASS|FAIL` derived from those matches, so that
one line can be believed. It does not do that yet.

### Which battery

Two different sets have been called "the battery", and conflating them makes old records
unreadable.

**Historical `11/11`** — the recurring set, and what `11/11` means in every record that uses the
phrase: `proctest`, `fputest`, `mlocktest`, `msynctst`, `mincoretst`, `bigargv`, `ptracepoke`,
`bmaptest`, `devmaptest`, `exectest`, `mul64test`. `protfault` (a and b) is run alongside it.

**The A3640 run's nine** (`docs/REALHW-A3640-260813-ACCEPTANCE.md` §6) was *that session's*
configuration, not a standard: it drops `mlocktest`, `mincoretst` and `devmaptest` and adds
`leaktest`. An earlier draft of this document presented it as the battery. It is not.

**Current minimum common battery: the historical eleven.** Anything dropped from it in a given run
is a deliberate choice and belongs in that run's record, with the reason.

Run when their area is touched rather than every time: `xpagetest`, `codepub`, `swapls`,
`segwrite`, `nfstruth` / `nfsreadtruth` (NFS integrity measured in **bytes from the server**, never
in file size), `leaktest`.

⚠ **`leaktest 50 1` with `fork_failures=0` does not establish that nothing leaks.** It establishes
that fifty fork+exec pairs completed. A one-page leak per exec passes it. To make it a leak test,
read `availrmem` before and after — that is the ISSUE-40 contract — and run both `50 0` and `50 1`
so fork and exec are separated. It also requires both arguments; invoked without them it prints a
usage line and does nothing, which an unattended driver will not notice.

⚠ `protfault`'s **case c has historically been dangerous** and belongs in a separate supervised
run, not in the routine battery. Cases a and b are the ones the records report.

`test-tools/README.md` documents what each program measures.

### Building them on the guest: `/usr/ccs/bin/cc`, not `cc`

**`cc` is wrong on the 68060 and will not tell you politely.** `/usr/bin/cc` is a shell wrapper
around gcc 2.7.2.3, and gcc's own `cpp` and `cc1` contain 64-bit `muls.l` — which the 68060 does
not implement, so the compiler itself dies on vector 61. Measured, not assumed: the console printed
`SIGKILL sent to pid 263 (.../cpp ...) because of vector 0xF4`
(`test-tools/mkall060.sh` header).

Use the original AT&T SVR4 driver, which predates gcc's magic-multiply optimisation:

```sh
/usr/ccs/bin/cc -o NAME NAME.c
```

`test-tools/mkall6.sh` builds the whole battery that way and ends with `MKALL6-DONE`; require
**12/12 built, 0 errors** before running anything. The sources are K&R C for that 1991 compiler —
see `AGENTS.md`, "Code that runs on AMIX itself".

**Not everything can be built on the guest, and the failures are not obvious.** Measured
2026-08-21: `fp060probe` uses `__asm__ volatile`, which the 1991 compiler answers with "undefined
symbol: `__asm__`"; `isp61ea_asm.s` and `fpenab060_asm.s` are GNU assembler syntax (`#`
immediates) and `/usr/ccs/bin/as` answers "invalid instruction name". Those are **cross-built on
the host and transferred as binaries**:

```sh
m68k-cbm-sysv4-gcc -m68040 -o fp060probe fp060probe.c
m68k-linux-gnu-as  -m68040 isp61ea_asm.s -o isp61ea_asm.o
m68k-cbm-sysv4-gcc -m68040 -o isp61ea isp61ea.c isp61ea_asm.o
```

`test-tools/mk060.sh` carries these notes at the site. `fpenab060_asm.s` needs one step more than
the three above, and the recipe is recorded: it is **cpp-macro assembly** — lines 35, 50 and 59
are `#define`s with `\` continuations — so a bare `as` reads the first continuation as an
instruction and dies at line 36. Preprocess it rather than assembling it:

```sh
m68k-linux-gnu-gcc -m68060 -c -x assembler-with-cpp -o x.o test-tools/fpenab060_asm.s
m68k-cbm-sysv4-gcc -m68020 -m68881 -O -o fpenab060 test-tools/fpenab060.c x.o
```

That is how the instrument was built and run on silicon on 2026-08-11 against kernel
`68060-260810-03`: `test-tools/f3-m4-enabled-hw-260811.txt`, recipe at
`docs/archive/NEXT-SESSION-PROMPT-260812.md:105-106`. The sentence that stood here until
2026-09-14 — “has no recorded recipe” — was written before that run and was never revisited
after it.

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

The power-cut run is the only **post-power-loss on-disk durability** test here; it is not the only
evidence about caches. Neither it nor the burst suite can be replaced by the emulator, which models
neither the copyback data cache nor a power cut.

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

* the machine, the CPU card, the image and its build id — **and the artifact's full SHA-256, the
  repository commit it was built from, and the loader version**, because `uname -m` reports the CPU
  rather than the image and two different builds can carry the same visible tag;
* the identity readings — `uname -m` and the magic words — before anything else;
* **the expectation, registered before the run**. A prediction that fails is the useful result; one
  written afterwards is not a prediction;
* every test and its result, including the ones that were skipped and why;
* and a section headed **what this does not establish**. That section is not modesty. It is where
  the next reader finds out which of your claims they may lean on.

Refuted conclusions stay in the record, labelled refuted (`STATUS.md` §7). Do not tidy them away —
the reason a hypothesis failed has repeatedly outlived the hypothesis here.

## 11. Order of the run

Order matters, and mostly for one reason: the destructive and the slow go last, so that a failure
early does not cost the whole session.

1. **Host gates, a second build, and a diff.** Archive the artifact's SHA-256 before it boots.
2. **Boot identity**: `uname -m`, every magic word that will be used, and the counters' baseline.
3. **The cheap common battery**, to catch gross breakage before anything expensive.
4. **CPU- and change-specific tests**, each with its own counter delta rather than one delta for
   everything.
5. **Device and graphics tests.** `cmfcensus` with X stopped; `busbench -r` before any aperture.
6. **Burst and stress.** ⚠ `burstloop11.sh` invokes `/tmp/hat_dup_cow`, for which **this
   repository has no source** — see ISSUE-50. A fresh clone cannot execute this step; it runs only
   where an earlier session left the binary. Check for it before planning a session around it.
7. **Power cut last.** The first actions of the next boot are identity, `fsck`, and the byte
   comparison — in that order, before anything else touches the disk.

`protfault` a and b can be run targeted, before the stress. Case c and any other probe known to be
able to hang the machine belong in a separate supervised run.

### Anything longer than a short command belongs in a script

Measured 2026-08-25, and it cost fifteen minutes before it was recognised. A `for` loop sent to
the machine as one telnet line was **silently truncated** at roughly 250 characters — AMIX's tty
line discipline has a canonical-input limit — so the shell sat waiting for the rest of a
`for … do` block that never arrived. Nothing compiled, no sentinel came back, and the only
visible symptom was a command that did not return.

**It looks exactly like a slow compile.** The tell is in the echoed command: the machine echoes
what it actually received, so compare the echo against what you sent. Here it ended mid-word at
`cc -o $f $f.c > `, which is the whole diagnosis in one line.

This is why the guest-side tooling in `test-tools/` is written as `.sh` files invoked with a
short command rather than as command lines — `mk060.sh`, `batteryrun-*.sh`, `burstloop11.sh` all
follow that shape. Copy the script over, then run `sh /tmp/name.sh`, and use
`(nohup sh -c "… > /tmp/name.log 2>&1" &)` for anything slow so the run survives the connection.
A remote shell that is holding your only session is not a good place to keep a fifteen-minute
compile.
