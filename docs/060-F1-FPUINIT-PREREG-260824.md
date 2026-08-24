# 060 F1 — the three-regime `fpuinit`: expectations registered before the code

This is a **pre-registration**, written and committed before the implementation it will be
judged by. `AGENTS.md`: *"Write down what you expect before you measure. A prediction that fails
is the useful result; a prediction made afterwards is not a prediction."* Nothing below is to be
rewritten to match an outcome; a miss stays on the page with the reason beside it.

The bench runs themselves are a separate session. This file is what that session is scored
against.

## 1. The problem, in one table

The kernel decides *once*, at boot, whether it owns a floating-point unit, and every FP path
downstream trusts that decision. There are three ways the hardware can answer and the port
currently handles one of them.

| regime | the part | today | evidence |
|---|---|---|---|
| **1** | FPU present and **enabled** at probe | works; eager save/restore through the fixed u-area | Mercury `fpc_save_n 8059` / `fpc_rest_n 7647`, `68060-260812-06` accepted 2026-08-12 |
| **2** | FPU present but **disabled** (PCR bit 1 set) | probe fails honestly, `fpu_present = 0`, `swtch` does no save/restore — **while userland runs live FP on the hardware anyway**, because the FPSP disabled call-out re-enables it and re-executes. Unmanaged FP context across context switches | our own 060 bench: banner `no fpu detected` **and** `awk` printing `3.75` in the same boot (2026-08-18) |
| **3** | **no FPU at all** (68LC060 / EC) | the disabled call-out clears PCR bit 1 and re-executes; on a part with no FPU the clear does not stick, so it re-executes forever | `amix-060-lc.uae` hangs at the Commodore copyright line, 85 s (2026-08-18) |

Regime 2 is the one that matters most for *already-banked results*: every multi-process FP
number taken on the 060 bench rig is formally suspect until the PCR write lands, because
Amiberry forces `regs.pcr |= 2` at reset for a 68060 with no accelerator board and offers no
config lever (`amiberry/src/newcpu.cpp:3609-3617`, read 2026-08-24). Mark those results; do not
delete them.

## 2. What is being changed

Per `docs/contracts/FPU-TIER1-ENABLE-SPEC.md:212-243`, ten steps, in order, and its own
pre-refutation of the shortcut at `:238-240` — *"Do not simply clear PCR bit 1 and declare
success. A 68LC060 or EC variant can lack usable hardware FP, and vector 11 remains the
authoritative negative probe."*

* an `fpuinit` override (the fourth strong symbol of the override surface; the other three have
  existed since ISSUE-43) that probes rather than assumes;
* `fpu_present` gates inside the 060 arms of `fpu_setup` / `fpu_save` / `fpu_restore`;
* a gate at the `sendsig` call site;
* a regime-3 arm in the FPSP disabled call-out, so that a part with no FPU gets an answer
  instead of a loop.

## 3. The registered expectations

### Rig A — `amix-060-lc.uae` (synthetic LC060, `fpu_model=0`) — regime 3

The rig that hangs today. **This is the primary gate.**

```text
boots to multiuser login                      (today: hangs at the copyright line, 85 s)
banner contains        no fpu detected
fpu_present            = 0
fpi_magic              = "FPI!"    read this FIRST; a mismatch makes every number below noise
fpi_n                  = 1         fpuinit's 060 arm ran exactly once
fpi_trap_n             = 1         the temporary vector-11 handler fired -- the negative probe
fpi_nofpu_n            = 1
fpi_pcr_pre  bit 1     = SET
fpi_pcr_post bit 1     = SET       <-- the part refusing our clear.  NOT a failure of our code
fpc_setup_n            = 0         the 060 FP bodies never ran
fpc_save_n             = 0
fpc_rest_n             = 0
fpi_ss_skip_n          > 0         after the first delivered signal
f60_fpudis_nofpu_n     = f60_fpudis_n   and the machine is still alive
```

`fpi_pcr_post` keeping bit 1 is a **prediction about the emulator, not about our write**:
`amiberry/src/newcpu_common.cpp:172-178` masks a `movec` to PCR down to bits 0x40/2/1 and then
re-sets bit 1 whenever `fpu_model <= 0`. On real LC silicon the bit is expected to read back set
for the same reason and by a different mechanism — the part has no FPU to enable. Either way the
probe, not the PCR readback, is the decider.

`fpi_ss_skip_n > 0` is F1-M2's gate and it is deliberately a **counter, not the absence of a
crash**: it says signal delivery asked for FP setup and was refused, which "the machine did not
hang" does not say.

**If Rig A still hangs**, the first two numbers to read are `fpi_magic` and `fpi_n`. `fpi_n = 0`
means the hang precedes `fpuinit` and the mechanism is not the one this work fixes — that is a
bug report back into F1, not a re-scope.

### Rig B — `amix-060-poc.uae` (68060, `fpu_model=68060`) — regime 2 today, regime 1 after

```text
banner does NOT contain  no fpu detected
fpu_present              = 1
fpi_pcr_pre  bit 1       = SET
fpi_pcr_post bit 1       = CLEAR    the write sticks here, because the FPU exists
fpi_frame byte 2         = 0x00     a post-reset NULL frame
fpi_badfmt_n             = 0
fpi_trap_n               = 0
fpc_save_n / fpc_rest_n  climb under process load   (today: both 0 -- nothing was managed)
awk still prints 3.75, and now for the right reason
```

Amiberry's own log should print `68060 FPU state: enabled` once
(`newcpu_common.cpp:178`). That line is independent corroboration that the PCR write landed.

This rig is also the **regime-1 control the bench can reach**: after the clear it *is* a
present-and-enabled FPU. It does not replace silicon (see §5).

### Rig C — the 040 arm

```text
baseline unix-040 sha256   332422fbc24837800c466011946e9d907aee3786d1e6734ecb05e182616b6756
                           build id " 68040-260824-01", tree at the pre-registration commit
FPUINIT060=0 sh relink-040.sh   reproduces that image byte for byte except the 16-byte
                                build-id field -- the spec's own rollback switch (:460-462)
with the unit linked in:   every fpi_* and fpc_* counter reads 0 on an 040 boot
                           fpuinit's first instruction is the cputype compare; the 040 arm is
                           a tail jump to the byte-asserted stock body at 0x19bac
```

Adding a linked object necessarily changes the image, so "the 040 arm is byte-identical" is
proven the two ways this repository already proves it (`ACCEPTANCE.md` §3): the *other CPU's
path* is unchanged in the disassembly, and the *build-time control* reproduces the baseline
bytes.

### Rig D — the negative control

An unstamped `unix-040` on the 060 rig still panics pid 3, exactly as it does today
(`cputype = 60` is mandatory and is poked by the loader). This work does not touch it, and if it
changes, something else changed too.

### Relink assertions (host gates, every build)

```text
5 fpu_save / 3 fpu_restore / 3 fpu_setup call relocations
init_tbl carries exactly one relocation, to fpuinit
fpu_ptr still relocates to fixed u + 0x9c
fpu_present remains the existing global object
the sendsig call site at 0x5921c names the gated wrapper
TOTAL complaints: 0, bindings failing: 0
```

## 4. Kill criterion

**Three build rounds without Rig A booting and without a *named* mechanism ⇒ stop**, write the
bug report, hand it over with the rig. "We think something might be wrong" is not a named
mechanism; the defect has to be named. A miss with a named mechanism is not a kill — it is the
next round.

## 5. What this will not establish

Registered in advance, because this is where the next reader finds out which claims they may
lean on.

* **No LC060 silicon result.** `amix-060-lc.uae` is a synthetic part: Amiberry with
  `fpu_model=0`. It reproduces the *hang*, which is why it can prove the *fix*, and it proves
  nothing about a real 68LC060.
* **Amiberry is not evidence** for enabled IEEE FP exceptions, for which instructions the
  silicon traps as unimplemented, or for the copyback data cache (`AGENTS.md`). Rig B's
  regime-1 arm is a logic test, not an FP-correctness test.
* **Regime 1 on hardware is untouched and unproven by this round.** The Mercury-accepted path is
  carried by the 040 control and the counters until real silicon runs again.
* Nothing here says anything about *userland* floating point without an FPU. That is a separate
  front and it starts with a trap census, not with an engine.
