# Hardware run-list — ISSUE-43, the 68060 FP context path (`68060-260812-01`)

**Status: written 2026-08-12 with the machine powered down (10.0.10.10 gave "no route to host").
Nothing below has been run on silicon. Every expectation here is PRE-REGISTERED — it was written
before any hardware number existed, which is the only way the run can tell "the fix worked" from
"the code never ran".**

The emulator half is done and recorded in `140e0c0`: both CPUs, one image, the 060 path exercised
10 080 times and the 040 path untouched. What the emulator **cannot** decide is the actual defect:
it raises no enabled IEEE FP exceptions at all, so all six `fpenab060` classes are unexercised
there. DZ is owed to hardware.

## 0. The artifact, checked on the file before it is booted

| Item | Value |
|---|---|
| file | `kernelsupport/build/unix-040` |
| build id | `68040-260812-01` (the banner reads `68060-` on the 060 — that is the CPU, not the image) |
| sha256 | `249a54e35374bc677628a7908e9f0483ff125ea7f3f4a432b128a84941ca1fcd` |
| textsize | `0xf2910` (993 552) |
| loader | `unix_boot040` — **mandatory**, after SetPatch |
| previous hardware baseline | `68060-260807-11`; the machine last ran `-05`, which is 5-of-6 |

Preserve whatever kernel currently sits on the Amiga's AmigaOS boot volume **by name** before
staging this one. `-06` was lost from the build host exactly this way.

## 1. Read the magic before believing any number

Counter addresses are computed for THIS image (`0x08000000 + textsize + nm(.data)`) and change
with every build:

| block | address | first long must read |
|---|---|---|
| `fpc_magic` … `fpc_setup_n`, **13 longs** | `0810AF94` | `46504321` = "FPC!" |
| `f60_magic` … `f60_effadd_n`, 18 longs | `0810B5AC` | `46503630` = "FP60" |
| `isp61_magic`, 15 longs | `0810AF58` | `49363121` |
| `segvn_prot_magic` | `0810AEEC` | `53564e21` |

If a magic does not match, the addresses are stale and **every other reading in this file is
noise** — stop and recompute. This has bitten this project more than once.

`fpc` block layout, in order from `0810AF94`:

```
+00 fpc_magic        +04 fpc_save_n       +08 fpc_save_wrt_n   +0c fpc_null_n
+10 fpc_idle_n       +14 fpc_excp_n       +18 fpc_odd_n        +1c fpc_last_frame
+20 fpc_rest_n       +24 fpc_rest_live_n  +28 fpc_rest_null_n  +2c fpc_rest_wrt_n
+30 fpc_setup_n
```

## 2. The one measurement this session exists for

```
/tmp/fpenab060                 <- all six classes, one child each
```

**Pre-registered expectation:**

```
FPENAB060 bad=0
  DZ    v50  OK  fp0 40000000:80000000:00000000  fpsr 02000410  fpiar <its own label>  sigs 1
  OPERR v52  OK  fp0 ffff0000:00000000:00000000  fpsr 01002080   unchanged from -05
  OVFL  v53  OK  fp0 7fff0000:00000000:00000000  fpsr 02001048   unchanged
  UNFL  v51  OK  fp0 00000000:40000000:00000000  fpsr 00000800   unchanged
  INEX  v49  OK  fp0 50000000:80000000:00000000  fpsr 00000208   unchanged
  SNAN  v54  OK  fp0 7fff0000:80000000:00000001  fpsr 01004080   unchanged
```

and, in the same boot, the counters that say the new code ran:

```
fpc_save_n, fpc_rest_n, fpc_setup_n   all non-zero and large (thousands after a boot)
fpc_excp_n                            NON-ZERO -- this is the new one.  On the emulator it
                                      stayed 0 because no enabled exception ever occurs there;
                                      on hardware each fpenab060 class should leave an 0xe0
                                      exception frame for fpu_save to find.
fpc_odd_n                             0  -- any other format byte is an invariant failure
fpc_save_wrt_n, fpc_rest_wrt_n        0  -- UFPRWRT's only setter is old ptrace
```

### How to read each outcome

| Outcome | What it means |
|---|---|
| `bad=0` and `fpc_excp_n` moved | The fix works and it is the fix that did it. Close ISSUE-43. |
| `bad=0` but `fpc_save_n` = 0 | The override is not on the path — the result is somebody else's. Do not close. |
| DZ still wrong, `fpc_excp_n` moved | The discriminator is right and something else eats the state. New evidence, not a rerun. |
| DZ still wrong, `fpc_excp_n` = 0 | fpu_save never saw an exception frame: look at what the FPSP exit leaves, not at fpu_save. |
| any class regressed from OK | Revert. The 060 body is wrong somewhere the emulator cannot see. |

## 3. Regressions, same boot

```
/tmp/fp060probe                bad=0, 7/7 bit-exact, 0 ulp
/tmp/ftest060 unimp            died=0          <- Motorola's own suite
/tmp/ftest060 main             four sub-tests passed
/tmp/fputest060 fork           <- WITHOUT `fork` Test C does not run and nothing is measured
/tmp/isp61ea                   bad=0
```

`f60_fpudis_n` must stay `0`. A non-zero value is a different ownership/enable fault and must not
be hidden by this change (audit gate 9).

The battery is a regression net, not an FP instrument: its `MUL64` costs zero vector-61 traps and
the whole run costs zero FP traps. Run it for the net, not for a verdict.

## 4. Owed, and deliberately not done here

* **Audit gate 6 — old-ptrace FP-register writes.** No instrument exists for it. Two branches of
  the new 060 code (`fpu_save`'s UFPRWRT early return, and `fpu_restore`'s null-frame + UFPRWRT
  republish) are therefore unexercised on both CPUs; their counters read 0 by construction. The
  instructions are the inherited ones, so this is a coverage gap rather than a suspected defect.
  Writing `fpwrt060` needs `procxmt`'s u-area address convention read out of the binary first.
* **Audit gate 7 — `/proc prsetfpregs` against a true-null target.** The audit found that
  `prsetfpregs` never sets `UFPRWRT` where `procxmt` does. Separate latent gap, separate probe.
* **Audit gate 8** — true-null frames entering an enabled arithmetic call-out. Expected 0; the
  `fpc_null_n`/`fpc_excp_n` split measures the save side of it, not the call-out side.

## 5. Working notes that cost time when rediscovered

* AMIX `grep` has no `-E`, no `-e`, no `\|`. One pattern per call.
* tftp: `binary` FIRST, commands from a file, and **one `get` per invocation** — a multi-`get`
  script silently produced an empty transfer on the emulator this session and cost two round
  trips. Ports 1069/1070/1071 are often held by other sessions; test with `ss -uln`.
* The tftp server must be started **unbuffered** (`python3 -u`) or its log tells you nothing
  about whether the request ever arrived.
* `/kpeek` and `/pgc` survive in the root directory on hardware; `/tmp` is wiped every boot.
* After a hardware boot, ping answers before telnet does. Wait for port 23, not for ping.
