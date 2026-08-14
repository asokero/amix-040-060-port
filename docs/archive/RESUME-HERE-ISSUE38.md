# RESUME HERE — ISSUE-38 (2026-07-29): copyback hangs at init's exec without the debug probes

> **2026-07-30 — ISSUE-38 IS CLOSED ON HARDWARE. This file is a closed record; do not resume from
> it.** `unix-040-b2-fix38-260730-03` (copyback, **no probes**) boots to telnet on the A3000,
> `cb_icode_push` = 1 with `hat_cm_ram` = `0x20` as the anchor, and `exectest 20` PASSes. Next unit:
> the copyback default flip (`hat_cm_ram = 0x20` in the base link) plus the postponed power-cut
> disk-truth run (`docs/REALHW-COPYBACK-POWERCUT-260729.md`). Read
> `docs/ISSUE38-ICODE-CACHE-FINDING-260730.md`.
>
> **The title of this file is wrong.** It does not hang at
> init's exec; it dies **before** exec. `main+0x1e8`'s `copyout(icode, 0x80800000)` leaves proc 1's
> bootstrap text in dirty copyback data-cache lines, the 68040 instruction fetch does not snoop the
> data cache, so proc 1 executes the still-zero RAM page as `ori.b #0,%d0` off the end into the
> unmapped `0x80801000` and dies of SIGSEGV. The terminal `hat_unload va=48442000 flags=A` is
> `segu_release` reclaiming the resulting zombie's u-area. The masking object `assegat_dbg` masks it
> because its `copyout` wrapper does an unconditional `cpusha bc`. Every row of §2's bisect table
> follows from that one mechanism, and no new hardware boot was spent to find it.
> **Read `docs/ISSUE38-ICODE-CACHE-FINDING-260730.md` instead of §1-§4 below.** The fix is
> `src/cb_icode040.s` in the base link; its hardware verdict is still OPEN (one boot of
> `unix-040-b2-fix38-260730-03`, verdict from telnet). §5 (instrument discipline), §6 (build
> mechanics) and §8 (what is open after ISSUE-38) below remain current and correct.
> Do NOT build Codex's six phase markers or its four-object masker bisect: they measure exec, which
> never runs.

Read this file and nothing else to start. Everything here is measured unless it says otherwise, and
the open questions are marked as open. `docs/archive/RESUME-HERE-ISSUE22.md` is the previous entry point and is
now a **closed record** — do not resume from it.

---

## 0. Where the port stands in one paragraph

ISSUE-22 is closed: `wb040.s` leaked DFC into the interrupted copy, the fix saves and restores DFC
(and SFC) across every fault wrapper, injection proved causality in two seconds, and the copyback
pressure suite accepted it — 16 bursts clean, 96/96 verifications, with 13 real corruptions repaired
under way. Copyback's own acceptance is therefore complete and it measures **+63 %** (Dhrystone
30000/s vs 18292.7). Exactly one thing stands between the port and that number: **the copyback image
without debug probes does not boot.** That is ISSUE-38, and it is the whole job.

## 1. ISSUE-38 stated

| image | cache | probes | result on the A3000 |
|---|---|---|---|
| `unix-040-260729-04` | write-through | no | **boots**, telnet, `uname -m` confirms |
| `unix-040-b2-260729-07` | **copyback** | no | **HANGS** at init's exec |
| `unix-040-b2-quiet-260729-09` | copyback | serial mirror only | **HANGS** |
| `unix-040-b2-dbg-260729-06` | copyback | full overlay | boots; ran a 72-min acceptance clean |

`-04` and `-07` differ in **exactly two bytes**: `hat_cm_ram` `0x00 → 0x20` at file offset 1033728,
and one build-id character. The hang is attributable to copyback and to nothing else.

**Exec aborts; it does not stall.** The machine is alive — with `mainmarks` linked it spins in the
scheduler printing its proc-table dump forever, i.e. "no runnable process". The last console line on
every hanging image is the **release** of the 8 KiB exec-header segmap slot:

```text
WARNING: DBG hat_unload va=48442000 size=2000 flags=A        <- last line, then nothing
```

A booting kernel instead keeps that slot and continues:

```text
DBG execmap vaddr=80000034 filesz=66D4 off=34 prot=D         <- mapping init's ELF from disk
```

That contrast is the single most useful fact in this file.

## 2. The bisect, and why it points at the exec path

Five hardware boots, deterministic verdict each time, **every verdict taken from telnet/login**, not
from the serial line:

```text
full dbg overlay (14 probe objects)                               boots
A  = serdbg + ddopen,blkatoff,mainmarks,assegat,execmark,
              hatalloc,sigkill                                    boots   (uname 260729-12)
B  = A minus hatalloc, keeping assegat                            LOADER GURU D245 4C41 (broken link, see §6)
B2 = serdbg + mainmarks,ddopen,blkatoff,execmark                  HANGS
D  = serdbg + mainmarks,hatalloc                                  HANGS
E  = D + assegat_dbg                                              boots   (uname 260729-22)
quiet = serdbg only                                               hangs
```

**E − D is exactly `assegat_dbg`.** What does NOT mask it is `hatalloc_dbg`, which prints heavily and
wraps `page_get` / `page_free` / `hat_ptalloc`. So masking is neither chatter nor page-allocation
instrumentation — it is specifically the wrapping of **`as_fault`, `as_segat` and `execmap`**, each
an ordinary link / save d2-d3,a2-a3 / forward args / call `*_orig` wrapper.

Two lines appear around the release in `D`'s log (⚠ see the provenance caveat in §5 before relying
on their ordering):

```text
DBG page_abort crash pp=400AD254 p_mapping=0 caller=80AD7DA (0=>SKIPs hat_pageunload, PTE stays)
DBG page_abort crash pp=400AD290 p_mapping=0 caller=80AD7DA
```

(Another hanging image shows the same shape with `caller=80B1EFE`.) A page released with its PTE left
in place is the stale-PTE / page-recycling family — the same family as ISSUE-10. Cause, consequence
or coincidence here: **not established.**

## 3. Ruled out by measurement — do not re-derive these

* **The DMA prepare/complete fail-open did not fire.** `dma_cmpl_noprep` read live from `/dev/mem` on
  a running machine: **0**, with `dma_cmpl_to` 2402 + `dma_cmpl_from` 3153 = `dma_cmpl_count` 5555
  exactly. Every completion had a PREPARED record, so the range `cinvl` ran every time. This does not
  clear the *range* from being wrong — only that the path executed.
* **The copyback page-release hooks are wired identically** in base, quiet and dbg: `patch_cb_release.py`
  reports `page_free @0xafb08 -> cb_pgfree_enter` already present in all three.
* **`.data` is 4-aligned** in every image (the base link's own guard passes) — not the 2026-07-09
  `.bss`-misalignment / SDMAC class.
* **It boots in Amiberry**, which does not model the 040 copyback data cache. Consistent with a
  cache-coherency or timing mechanism, and the reason this could only be found on silicon.

## 4. The two tracks open right now

**Track 1 — Codex.** The brief is written, on the NAS, and committed: `docs/archive/ISSUE38-EXEC-ABORT-TASK.md`
(commit 19b00ea). It asks four things, the starred first one being a byte-exact enumeration of the
exec-header paths that release the slot and abort without reaching `execmap`. Requested deliverable:
`amix-kernel-analysis/vm-map/ISSUE38-EXEC-HEADER-ABORT.md`. **Check whether that file exists in
`~/kehitys/amix-playground/amix-kernel-analysis` before building anything.**

**Track 2 — a targeted exec probe, mine to build.** The question is no longer *what hides it* but
*why exec aborts*. A small object wrapping the exec header path and logging return values, linked
into an otherwise probe-less copyback image. **One build, one boot.** Known bodies:

```text
exece 0x56444   gexec 0x576c0   elfexec 0xb80f2
exhd_getmap 0x5704e   execmap 0x57a4c   page_abort 0xaf8d6
```

The risk to respect: the probe must be small enough not to become the next `assegat_dbg` and mask
the very thing it measures. Prefer counters in `.data` read afterwards via `kpeek` over `cmn_err`
chatter — the masking evidence says chatter is not what hides it, but call-frame and store traffic
might be, so keep both minimal.

**Do not narrow further inside `assegat_dbg` with more bisects.** It is one large object with several
wrappers and each step costs a hardware boot.

## 5. Instrument discipline — these rules cost real days

* **Bracket the serial meter with a known `kill -9` before AND after every run.** Silence proves
  nothing from an unverified instrument.
* **`lsof /dev/ttyUSB0` before every run.** Multiple readers SPLIT the byte stream; the tell is
  garbling (lines breaking mid-word and continuing with another line's content), not absence. This
  is how the `-20` and `-22` captures were lost: three readers from 20:59 onward. Those two captures
  are **incomplete** — the lines quoted from them are real, but ordering and completeness are not
  established. `-07`, `-09`, `-16` and the `-07` console photograph were taken with a single reader
  and are sound.
* **Build the verdict on a channel a shared port cannot corrupt** — the bisect verdicts rest on
  telnet/login, which is why they survived the split stream.
* **Do not log in to the machine during a measurement run.**
* **The driver must kill the remote workload on timeout** (send `\x03`), or every later command
  queues behind it and the post-run counters are never read. This has already cost one long run.
* **Userland console writes do NOT reach the serial mirror** — only kernel `conputc` output does. A
  silent log from a base image means the instrument was absent, not that the bug was.

## 6. Build and boot mechanics

```sh
sh relink-040.sh                        # base, write-through, no probes
python3 patch_b2_flip.py <image>        # hat_cm_ram 0x00 -> 0x20  (the two-byte copyback delta)
sh relink-040-quiet.sh                  # base + serial mirror only
DBG_OBJS="serdbg mainmarks hatalloc" sh relink-040-dbg.sh    # parameterised probe subset
```

`relink-040-dbg.sh` **fails closed** on unresolved symbols after linking. That guard exists because
dropping `hatalloc_dbg` while keeping `assegat_dbg` left `g_shdatabase`/`g_shdataleaf`/`g_shdatapp`
dangling and the loader answered with guru **D245 4C41 ("RELA")** — one wasted hardware boot. Object
dependencies: `mainmarks` ← everything; `hatalloc_dbg` ← `assegat_dbg` ← `sigkill_dbg`.

Every override `.s` section ends `.balign 4`. `unix_boot040` is the mandatory loader.

## 7. Artifacts — `nasu:Public/amix/hwtest-260728/` (`SHA256SUMS-issue22.txt`, `SHA256SUMS-b2.txt`)

```text
unix-040-260729-04          base, write-through, no probes      BOOTS
unix-040-b2-260729-07       base, COPYBACK, no probes           HANGS   <- the image that must boot
unix-040-b2-quiet-260729-09 copyback + serial mirror            HANGS
unix-040-b2-dbg-260729-06   copyback + full overlay             BOOTS   <- the ACCEPTED image
unix-040-b2-dbg-260729-03   the DFC injection kernel
unix-040-quiet-260729-08    write-through + mirror (ISSUE-10 emulator repro)
unix-040-b2-bisect{A,B,B2,C,D,E}-260729-{12,14,16,18,20,22}
unix_boot040                MANDATORY loader
kpeek.c kpoke.c dfcinject.c cofault.c kdepthmax.c   (also in test-tools/)
```

Counter addresses in **260729-06** — recompute after any relink (`0x08000000 + textsize + .data
offset`) and always read a known anchor in the same `kpeek` range; every reading in the ISSUE-22 work
was taken with `xpage_on == 1` and the string `segkmem_ptes` bracketing the counters:

```text
us_calls 080FFDE0  us_odd_user 080FFDE4  us_odd_kern 080FFDE8
wb_dfc_on 080FFF04  wb_dfc_n 080FFF08  wb_dfc_changed 080FFF0C
wb_dfc_lastold 080FFF10  wb_dfc_lastnew 080FFF14
wb_replay_n 080FFF18  wb_replay_odd 080FFF1C
wb_dfc_force 080FFF20  wb_dfc_force_n 080FFF24  wb_dfc_forced 080FFF28
wb_sfc_changed 080FFF2C
Lkx_fn 080FFFB4  xpage_on 080FFFB8 (=1, ANCHOR)  Lkx_depth 080FFFBC
```

## 8. Also open, in priority order after ISSUE-38

* **ISSUE-10 is reproducible again, and locally.** `amixadm` bus-errors on probe-less kernels,
  byte-identical to July (`4AFC0003, PC:800023FC`), and it reproduced on the first try in Amiberry on
  `unix-040-quiet-260729-08`. July's "trigger retired" verdict was taken on a dbg image — the trigger
  never decayed, the instrument hid it. Iteration is now ~4 minutes locally
  (`test-tools/emu-amixadm-test.sh`). **Caveat: it must be run interactively; `amixadm < /dev/null`
  does not reproduce, because the interactive menu path is what allocates.** Note the shape shared
  with ISSUE-38: two symptoms, both masked by the same overlay, both involving page reuse. Whether
  they are one defect is unproven and worth an hour.
* **Copyback default flip** (`hat_cm_ram = 0x20` in the base link) — frozen until ISSUE-38 resolves.
  Today copyback images are still produced by `patch_b2_flip.py`.
* **Power-cut disk truth** — `docs/REALHW-COPYBACK-POWERCUT-260729.md`, written and ready, kernel `-07`.
  Postponed with ISSUE-38: there is no point hardening a kernel that cannot boot.
* **`Lkx_depth`** — a machine-wide counter compared against a per-context limit, held across a
  sleeping `as_fault`. Refuted as ISSUE-22's cause, real as a latent defect. Codex's design: a
  private 200-entry `proc *`-keyed table (`vm-map/ISSUE22-DFC-ARCH-STATE-AUDIT.md`, 7c314b2).
* **`ptest040.s:52` leaks SFC=1** and is deliberately left in place as insurance against DFC/SFC
  ambiguity on real silicon; the leak was made harmless by the wrapper contract instead
  (`wb_sfc_changed` measured 0 across a boot and 105k replays).
* **b2repro stalls** — 120–125 s baseline bursts interrupted by stalls of 200–900 s, present since
  before any DFC work and on fresh boots. My memory-pressure guess recurred on a fresh boot and is
  therefore weakened. Cheap first checks: root-fs free space and fragmentation after ~1 GB of burst
  writes; paging pressure from 6 × 4 MiB copies plus a 4 MiB verify buffer on a 32 MB machine.

## 9. Machine state at the time of writing

On `68040-260729-22` (bisectE, copyback + `mainmarks`/`hatalloc_dbg`/`assegat_dbg`), reachable by
telnet, usable. The serial port was cleaned back to a single reader. Working tree clean at 19b00ea.
