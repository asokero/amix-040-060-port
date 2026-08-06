# The 68060 campaign — plan of record, 2026-08-05

The CPU swap happened. A 66 MHz 68060 on a Mercury adapter is in the A3000, and it **booted an
older RTG kernel straight to a login**, with Dhrystone running in userland. That is the campaign's
starting position, and it is better than the plan assumed: the "measurement boot — where does it
stop" datapoint has effectively been taken, and it did not stop.

This file supersedes the 060 sections of `RESUME-HERE-260801.md` §5 and `RESUME-HERE-260731.md` §7.
The engineering baseline is `68060-prestudy.md` (Phase 060-B, emulator-complete since 2026-07-10);
the static acceptance baseline is `amix-kernel-analysis/vm-map/M68060-XPAGE-ACCEPTANCE.md` and
`M68060-SUPPORT-LANDSCAPE.md`.

---

## 0. What is already done, and therefore not work

Phase 060-B landed on 2026-07-10 and has been carried in every kernel since, in **one dual-CPU
binary** whose 040 behaviour is byte-identical:

| unit | file | what it does on the 060 |
|---|---|---|
| fmt-4 fault address | `prototypes/getfault040.s` | FA at frame+72 instead of the 040's fmt-7 offsets |
| fmt-4 user/kernel classify | `prototypes/userspace040.s` | FSLW at +76, TM = bits 18–16 |
| SSW synthesis | `wb040.s wb060_sswsynth` | 060 FSLW → 040-style SSW, so the stock classifier stays correct (locked RMW must classify as *write*) |
| crossing-page resolve | `wb040.s wb060_xpage` | FSLW.MA tier + a compatibility tier for `FA & 0xfff >= 0xff8` |
| `ptest` | `prototypes/ptest040.s` | software URP walk when `cputype == 60` (the 060 has no PTEST/MMUSR) |
| 64-bit `muls.l` in the kernel | `prototypes/lmul060.s` | portable rewrite, used on both CPUs |
| CPU identity | `prototypes/cputype060.s` + loader poke | `unix_boot040` writes 40/60 from AttnFlags; banner and `uname -m` follow |
| `framesz[4] = 16` | `prototypes/patch_framesz060.py` | fmt-4 frame size, inert on 030/040 |

Everything else — Model B, the HAT, MMU programming, CPUSH/CINV, the loader, the relink machinery
— is bit-identical between the two CPUs and needs no 060 work at all.

## 0b. Status as of 2026-08-06 (added after the first three phases ran)

| phase | state |
|---|---|
| **F0** measurement boot | ✅ done on hardware, `060-F0-MEASUREMENT-260805.md` |
| **F1** fault-path counters | ✅ landed, `060-COUNTERS-UNIT-SPEC-260805.md`; found the XPAGE defect immediately |
| **F2** vector 61 | ✅ **accepted on real hardware**, `REALHW-F2-ACCEPTANCE-260806.md` — the machine has a working GCC again |
| F3 vector 11 / 060 FPSP | not started |
| F4 060-D caches | not started; F0 changed its premise, see below |
| F5 `cpuinfo` + PCR | partially done — PCR is read at boot into `pcr_boot` |

**A naming collision to be aware of.** Work done on 2026-08-06 is labelled `F3` and `F4` *inside*
`prototypes/wb040.s` comments, but those refer to the XPAGE far-page classification and the
`k_siginfo_t` translation — **not** to this plan's F3 (vector 11) and F4 (caches). That work was
unplanned: it came out of F1's instrumentation. This plan's numbering is unchanged; read the
source labels as "the third and fourth units of 6 August", nothing more.

**What F0 changed in the plan.** `pcr_boot = 0x04300601` on every boot, i.e. **ESS = 1**:
superscalar dispatch is already on, because SetPatch enables it and the kernel never writes PCR.
§5's premise that we are running scalar during bring-up is therefore wrong, and the Dhrystone
ratio of exactly 2.0× the 040 is *not* explained by dispatch. Branch cache (still off) and the
33 MHz bus are the remaining candidates, which makes 060-D more interesting, not less.

**Unplanned work that came out of F1, and its consequence for item A.** Instrumenting the fault
path exposed a generic VM defect that had nothing to do with the 060: `segvn_faultpage` was
missing SVR4's per-page permission check, so any partial `mprotect` followed by a denied write
panicked the kernel on **both** CPUs (ISSUE-41, fixed). The 060 half — translating a far-page
`faultcode_t` into `u_trap`'s `k_siginfo_t` — is also done, and `protfault` now passes 3/3 on the
emulated 060. Item A's remaining hardware test 3 is therefore *ready* to run rather than blocked.
One defect is still open from that work: ISSUE-42, a protection bypass in `wb040_replay` on the
**040**.

## 1. What is genuinely open

| # | item | state | why it matters |
|---|---|---|---|
| A | **XPAGE runtime acceptance** | static PASS, hardware unproven | Amiberry is explicitly not accepted as proof that a real format-4 frame sets and delivers FSLW.MA |
| B | **Vector 61 (unimplemented integer)** | `nullvect` → SIGKILL | ISSUE-34a: any 64-bit `muls.l`/`divs.l` kills the process. Scope is disputed — see §2 |
| C | **Vector 11 on the 060** | `fpsp_vec11` gates `cputype == 40` → `nullvect` → SIGSYS | the 060 FPU implements *less* than the 040's; this is the likely identity of ISSUE-34b |
| D | **060 fault-path counters** | do not exist | nothing in the kernel counts fmt-4 frames, MA hits, or compat-tier hits. A is unmeasurable until they do |
| E | **060-D caches: branch cache and store buffer** | off | one bit each, with a defined invalidation rule (§5) |
| F | `cpuinfo` userland tool, PCR revision read | not written | tells full 060 vs LC060, and the mask revision |

## 2. The cheapest measurement in the campaign, and it goes first

ISSUE-34a is proven: one cross-compiled instruction (`mulsl #1374389535,%d2,%d1`) runs on the 040
and is killed on the 060, 6/6 correlation across the suite. What is **not** established is whose
compiler emits it.

* Every repro that died was **cross-compiled** with the m68k-cbm-sysv4 toolchain, which targets
  68020+ and therefore emits the 64-bit form for constant division.
* The **guest's own** toolchain scanned *clean* of 060-unimplemented instructions across
  `gcc`, `cc1`, `cpp`, `libc.so.1`, `libc.a` and `ld.so.1` (KNOWN-ISSUES §ISSUE-34).
* `test-tools/mkall.sh` compiles the whole battery **natively on the guest with `cc`**.
* And an old kernel just ran Dhrystone on the 060 without dying.

If the guest's `cc` does not emit the 64-bit form, then **the entire test battery is usable on the
060 today**, and the ISP becomes a correctness item rather than a blocker on measurement. If it
does emit it, vector 61 blocks everything and moves to the front of the queue.

**The discriminator is one compile and one run:** build `test-tools/mul64test.c` natively on the
guest and execute it. PASS → native codegen is 060-safe. Killed → vector 61 is the immediate gate.
Disassemble the native binary either way; the instruction is the evidence, not the exit status.

Do this before anything else. It decides the order of §3 and §4.

## 3. Phase 060-F0 — measurement boot (first hardware session)

Kernel: **`build/unix-040`, build id `68040-260802-01`**, textsize `0xe4868` — the fully accepted
ISSUE-40 base. Rationale: newest accepted image, no third-party drivers anywhere near the fault
path, and the leak fix in it is CPU-independent so the 060 inherits it. The banner should read
`68060-260802-01` and `uname -m` should agree; that is the first assertion of the session.

Runtime addresses for that image (`0x08000000 + textsize + nm .data offset`):

```text
cputype          0x080FCE58     must read 60
fpu_present      0x080E9844     0 = no FPU found by chk_fpu
buildid          0x080FCE44
kdbg_on          0x080FD248
hat_pfnmiss_n    0x080FD24C     the calibration instrument: exactly +2 per devmaptest
hat_badaslot_n   0x080FD250
i39_magic        0x080FD27C     0x49333921 -- memwatch's self-check
i40_magic        0x080FD2B4     0x49343021
i40_on           0x080FD2B8
ptd_magic        0x080FD2E8     0x50544421
ptd_on           0x080FD2EC
```

RTG twin, if X is wanted on the 060: **`build/unix-040-rtg-020826`, `68040-260802-04`**, textsize
`0xed894` — `cputype 0x08105E84`, `fpu_present 0x080F2870`, `i39_magic 0x081062A8`,
`hat_pfnmiss_n 0x08106278`, `i40_magic 0x081062E0`, `ptd_magic 0x08106314`. Boot it **second**:
one variable at a time.

Run list, in order:

1. Banner + `uname -m` + `cputype` == 60. Loader must print `kernel cputype set to 60`.
2. `fpu_present` — full 060 or LC060. This single word decides how much of §4/C matters.
3. `mul64test` natively compiled (§2). **This is the gate that orders the rest.**
4. `mkall.sh`, then the standard battery (`batteryrun2.sh`) and burst (`burstrepeat2.sh`), read
   against the 040 numbers from `REALHW-ISSUE40-ACCEPTANCE-260802.md`: battery 10/10,
   burst 96/96, `hat_pfnmiss_n` +2 per `devmaptest` and unmoved by anything else.
5. `memwatch` baseline — ISSUE-40's fix is CPU-independent, so `availrmem` should be as flat on
   the 060 as it now is on the 040 (~0.2 pages/min). A different slope on the 060 is a finding.
6. Read CACR back on the 060 and decode it (§5). Record the value; do not change it yet.
7. Dhrystone, both CPUs' numbers recorded properly this time, with the kernel build id noted.

**Do not read a green battery as "the 060 works".** It means those tests pass. That exact sentence
is in KNOWN-ISSUES for a reason: the earlier clean 060 line was luck of instruction selection, not
coverage.

## 4. Phase 060-F1 — instrument, then take Codex's acceptance

Item A cannot be accepted without item D. Nothing counts fmt-4 frames today, so a boot that "works"
proves the paths were *survived*, not that they were *exercised* — the same trap the port has paid
for repeatedly.

New unit, `wb040.s` counters (same shape as `wb_dfc_*`, `.data`, address computed per image):

```text
x60_fmt4_n        format-4 frames seen by the wrappers
x60_ma_n          MA tier taken (the architecture contract)
x60_compat_n      compat tier taken (MA clear, FA & 0xfff >= 0xff8)
x60_rw_read_n     pure read crossings      -> far as_fault got S_READ
x60_rw_write_n    write and locked RMW     -> far as_fault got S_WRITE
x60_far_fail_n    far-page resolve failed and was propagated
x60_last_fa       last faulting FA
x60_last_fslw     last FSLW, unmodified
```

Pre-registered reading, straight from `M68060-XPAGE-ACCEPTANCE.md` §"Remaining acceptance tests":

1. A crossing access whose operand begins **before** `page+0xff8` must produce `x60_ma_n` > 0 with
   `x60_compat_n` unchanged. That is the hardware answer the document is waiting for.
2. Read, write and locked-RMW crossings must land in `x60_rw_read_n` / `x60_rw_write_n` /
   `x60_rw_write_n` respectively.
3. A protected or unmapped far page after a valid near page must terminate through the normal
   signal/nofault path — `x60_far_fail_n` > 0, no retry loop.
4. The 040 ISSUE-37 crossing test stays a dual-CPU regression; the format-7 helper must still run
   exactly once.

If hardware ever shows a crossing frame with **MA clear**, that is new evidence and the acceptance
verdict reopens — the document says so explicitly, and that clause is the reason the compat tier
exists.

Workloads that already produce crossings: `segspan`, `readtail`, the wolf3d ISSUE-37 case.

## 5. Phase 060-D — caches, with one verified fact and one open bit

Verified against NetBSD's own definitions (`m68k/include/cpu.h`, extracted from `syssrc.tgz`):

```text
IC40_ENABLE  0x00008000    same bit on the 68060
DC40_ENABLE  0x80000000    same bit on the 68060
IC60_EBC     0x00800000    enable branch cache      -- NOT set today
IC60_CABC    0x00400000    clear all branch cache   -- NOT set today
DC60_ESB     0x20000000    enable store buffer      -- NOT set today
CACHE60_ON = CACHE40_ON | IC60_CABC | IC60_EBC | DC60_ESB
```

So the CACR word this kernel writes, `0x80008000` (`pstart040.s:383`), means **exactly the same
thing on the 060 as on the 040**: instruction cache on, data cache on. The comment in that file is
right. What the 060 additionally has and we are not using is the **branch cache** and the **store
buffer**.

That makes 060-D small and well-shaped:

* **Branch cache**: one enable bit, plus the invalidation rule — `CABC` on anything that changes
  the mapping under a user address, i.e. wherever the port already flushes/pushes. Cheap, and the
  first real 060 performance knob.
* **Store buffer**: changes write ordering for I/O. Leave off until the DMA/driver audit says
  otherwise; the project already has a DMA census to lean on.
* Copyback is already the 040 default and is CPU-common; ISSUE-38's lesson (the 040 does not snoop
  its own instruction fetches, so freshly written code must be pushed) applies unchanged to the
  060. `cb_icode040` covers it.

Acceptance shape is the copyback one, unchanged: burst 96/96, power-cut disk truth, Dhrystone
delta, `exectest 20`.

## 6. Phase 060-SP — vectors 61 and 11

Order depends on §2. Two separate packages, two separate vectors, and the landscape audit already
mapped the collisions: ISP owns 61; FPSP owns 11, 48–55 and 60; our 040 hooks sit on 11, 48 and
51–55; 49, 50, 60 and 61 are still `nullvect`. CPU-dispatch shims are the correct shape.

* **Vector 61 (ISP)** — either Motorola's 060SP integer half wired to 61, or a targeted emulator
  for just the 64-bit `mul`/`div` forms. The arithmetic for the multiply half **already exists and
  is validated** (`lmul060.s`, 202 500 cases against a `muls.l` model); what is missing is trap
  frame handling, instruction decode and result write-back. That glue is the work, not the maths.
* **Vector 11 (FPSP for the 060)** — and here is the hypothesis worth recording, because it is new
  and it is cheap to test: **ISSUE-34b is probably this.** `cc1` dies with SIGSYS (12) on the 060
  and works on the 040; the whole compiler chain is provably clean of unimplemented *integer*
  instructions; and vector 11 is exactly what becomes SIGSYS (`moveq #12,d4` at `0x5a6b6`) when
  `fpsp_vec11`'s `cputype == 40` gate sends the 060 to `nullvect`. The 68060 FPU implements a
  smaller set than the 040's — `fmovecr` and `FScc` alone appear 287 and 26 times in the installed
  userland — so an 060 with our 040-gated FPSP produces precisely this signature. **Verify with the
  trap probe KNOWN-ISSUES already specifies** (log the vector number from the frame's format word
  and the faulting PC in `nullvect`); do not reason further without it.

## 7. Rules for this campaign

1. **The swap is one-way per session.** While the 060 is in, no 040 hardware regression exists.
   Therefore: every 060 change stays `cputype`-gated so the 040 path is byte-identical, and both
   emulator CPU configs boot before any hardware boot. `emu-reset-boot.sh [040|060]`.
2. **Recompute every counter address per image.** Base and RTG differ (`0xe4868` vs `0xed894`).
   Read the magic word first (`i39_magic`, `i40_magic`, `ptd_magic`) and refuse to believe numbers
   if it does not match.
3. **"It booted" is not evidence that a path ran.** A counter has to show it. This is the rule the
   whole 040 port was built on and the 060 has no exemption.
4. **Amiberry is not proof for FSLW.MA, for cache behaviour, or for unimplemented-instruction
   traps.** UAE cores may execute what real silicon traps. That caveat is in the pre-study and it
   is the reason item A exists at all.
5. **A green battery means those tests passed.** Nothing more, until vector 61 and vector 11 are
   settled.
6. Long runs detached — `(nohup sh /tmp/x.sh > /tmp/x.log 2>&1 &)`, parentheses included: the
   driver appends `; echo TAG`, and a bare trailing `&` turns that into a silent no-op.
7. `/tmp` empties on every boot. Sources live on the NAS; `/kpeek` and `/pgc` are in the root and
   survive.

## 8. Sequence

```text
F0  measurement boot on 68040-260802-01, native mul64test first   <- DONE 2026-08-05
F1  060 fault-path counters -> XPAGE runtime acceptance (item A)  <- DONE 2026-08-05
F2  vector 61 (ISP or targeted emulator), order set by F0         <- DONE, hardware-accepted 08-06
--  unplanned, out of F1: ISSUE-41 segvn fix (both CPUs) + siginfo translation (060)  <- DONE in emu
==> NEXT: one hardware session for the 260806-06 line (battery, burst, power-cut, protfault a/b/c)
F3  vector 11 / 060 FPSP; closes ISSUE-34b if the hypothesis holds
F4  060-D: branch cache, then a store-buffer decision (ESS is ALREADY on -- see §0b)
F5  cpuinfo tool + PCR revision (PCR half done: pcr_boot is read at boot)
--  ISSUE-42: wb040_replay protection bypass on the 040 -- analysis task, not a coding task
```

Everything before F2 is measurement and instrumentation on a kernel that already boots. That is
deliberate: the campaign's first job is to find out what the 060 actually does, not to write code
for what it was predicted to do.
