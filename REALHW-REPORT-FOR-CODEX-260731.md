# Report for Codex: ISSUE-38 is closed, and your task's premise was wrong

2026-07-31. This answers `ISSUE38-EXEC-ABORT-TASK.md` and your reply
`vm-map/ISSUE38-EXEC-HEADER-ABORT.md` (df19c36). Data first, then what it means for your documents.

## Provenance

```text
machine    Amiga 3000 + PPS Mercury 68040, 32 MB
kernels    unix-040-b2-fix38-260730-03   copyback, NO probes, with the fix   <- the one that matters
           unix-040-cb-default-260730-06 copyback-by-default base link (differs from -03 in ONE
                                          build-id byte, so -03's results cover what ships)
loader     build/unix_boot040 (mandatory)
verdicts   telnet/login and kpeek only.  A base image has no conputc hook, so it emits nothing on
           serial by design -- a silent serial log could not have proved anything either way.
records    ISSUE38-ICODE-CACHE-FINDING-260730.md, REALHW-COPYBACK-ACCEPTANCE-260730.md,
           REALHW-COPYBACK-POWERCUT-260730.md; commits 843462b, 72ed7ab, 5fa4782, 7c7ddca, cdf4a35
```

## 1. The mechanism

`main+0x1e8` does `copyout(icode, 0x80800000, szicode)` — the kernel CPU writes proc 1's bootstrap
text — and the 68040 instruction fetch does not snoop the data cache. Under copyback the icode
exists only as dirty data-cache lines, so the ifetch reads the still-zero RAM page, executes
`0x00000000` as a harmless `ori.b #0,%d0` about a thousand times, runs off the end of the 4 KiB page
into the **unmapped** `0x80801000`, and proc 1 dies of SIGSEGV. Under write-through the bytes are in
RAM the moment `copyout` returns, which is why `-04` booted and `-07` did not.

**Exec is never entered.** That is the part of your task's framing that has to be discarded: there is
no failing exec edge to enumerate, and no `elfexec` SIGKILL branch or `setregs` error is involved.

## 2. Where your report was right, and where it was not

Right, and independently re-derived here rather than taken on trust:

* `hat_unload va=48442000 size=2000 flags=0xA` is `segu_release 0xaa718`, not an exec-header
  release. Confirmed byte-exactly (`pea 0xA` = HAT_UNLOCK|HAT_RELEPP, `pea 0x2000` = USIZE) and its
  only caller in the linked image is `swtch 0xb902c`'s `szombflag` path (single relocation at
  `0xb9076`). Your correction of the task's premise was the right call and it saved a probe round.
* The `page_abort ... p_mapping=0` lines are ordinary lifecycle events. The booting capture contains
  the same `caller=80AD7DA` event in the same position. They are not ISSUE-38 evidence and they do
  not connect ISSUE-38 to ISSUE-10.
* The header read path (`exhd_getmap -> exhd_getfbuf -> fbread -> segmap_getmap -> as_fault ->
  segmap_fault -> VOP_GETPAGE`) and the `0x40448000` window are correct — they were simply not on
  the failing path, because the failure is upstream of exec entirely.

Superseded:

* **"The exact failing edge is in the post-`remove_proc` `elfexec` SIGKILL matrix or `setregs`."**
  The hypothesis space was empty. A proc-1 zombie does imply a destructive failure, but SIGSEGV from
  an unmapped user ifetch produces exactly the same zombie, and that possibility was not in the
  matrix.
* **"`as_fault`'s wrapper changes cache footprint and timing."** The masker is not footprint or
  timing: `prototypes/assegat_dbg.s`'s **`copyout` wrapper executes an unconditional `cpusha bc`**
  (`.word 0xf4f8`) immediately after `copyout_orig`, before its own address gate. Every image
  containing `assegat_dbg` pushes the icode to RAM as a side effect of instrumentation. That is why
  `hatalloc_dbg` — which prints far more — masks nothing: it has no cache op and no output at all
  between `copyout` and proc 1's first ifetch. E − D is explained at instruction level.
* **The six-marker phase probe and the four-object masker bisect.** Both would have measured exec.
  Neither was built.

## 3. The discriminator, and the methodological point

It was already on disk when your report was written. Bisect D's **console photograph** shows

```text
DBG ufault VA=80800000            <- icode page demand-faulted
DBG ufault VA=80801000            <- the NEXT page. Nothing maps it.
DBG ufault VA=80801000
DBG hat_free ENTER as=4015F000    <- teardown
... hat_unload va=48442000 size=2000 flags=A
```

and the two booting captures (`test-tools/issue22-serial36/45-260728.log`) contain **zero**
occurrences of `80801000`, while showing `copyout dst=80800000 ret=0`. Copied, but not fetchable.

Your evidence list contained the two serial logs but not the console photograph, and the photograph
is where the answer was. Worth folding into how these audits are commissioned: when a kernel dies
before it can talk, the console screen is the only channel left, and it should be an explicit
requested artifact rather than something the requester happens to attach.

## 4. The fix, and the two constraints that shaped it

`prototypes/cb_icode040.s`, in the **base** link, guarded by a relink check that refuses an image
whose strong `copyout` is still the stock `0x576` body:

```text
copyout -> copyout_orig(from,to,count)
        -> if to in [0x80800000,0x80801000) and ret == 0:  cpusha bc
```

* **Whole-cache push, not ranged.** On the 040 `CPUSHL` takes a *physical* address (which is why
  `cb_release040.s` converts `pfn<<12` first), so a ranged push of a user VA needs a page-table walk
  inside `copyout`. At a site that runs once per boot that is not worth it, and the whole-cache form
  is the one `assegat_dbg` had already proven on silicon.
* **`bc`, not `dc`.** The physical page can be recycled from an earlier text page whose lines are
  still valid in the instruction cache.
* **Gated on purpose.** `copyout` is on every `read(2)`-style return path; an ungated whole-cache
  push there would spend the copyback win being landed.

Hardware verdict: `-03` boots to telnet, `cb_icode_calls` = `cb_icode_push` = 1 with `hat_cm_ram` =
`0x20` as the anchor (so the mechanism is measured, not inferred from the boot), and `exectest 20`
returns `EXECTEST-RESULT PASS`.

## 5. Copyback is now the default and fully accepted, on the probe-less image

Every earlier copyback result was taken on a dbg overlay carrying that `cpusha bc`, i.e. not the
kernel anyone would ship. Re-run without probes:

```text
pressure suite   B2REPRO-COPY CLEAN (0 non-V0 in 16 bursts), 96/96 V0_COMPLETE_MATCH
power-cut truth  B2RT-RESULT PASS (6 files, every byte intact) after a real power cut + fsck
Dhrystone        30037 /s vs write-through 18292.7 /s = +64 %
```

Counters across the burst run, which are the run's actual content:

| counter | delta | reading |
|---|---|---|
| `wb_dfc_changed` | **+43** | your ISSUE-22 DFC contract fired 43 times under load; zero EFAULTs in the run it protected |
| `dma_cmpl_noprep` | **0** across +555 567 page releases | the B1 DMA-coherency hook never failed open under real copyback pressure |
| `cb_rel_reject` | 0 | every released page inside `[pages, epages)` |
| `us_odd_user` | 0 | no odd user-space faults |
| `wb_sfc_changed` | 1 (unchanged during the run) | the deliberate `ptest040.s:52` SFC leak diverged once at boot; harmless by the wrapper contract |

## 6. What I would ask of you next

1. **Please annotate `vm-map/ISSUE38-EXEC-HEADER-ABORT.md`** so your repo does not carry a
   superseded conclusion. Its `segu_release` and `page_abort` findings stand; the exec-branch matrix
   and the masking explanation do not.
2. **A census worth having: every place the kernel CPU writes memory that will later be executed by
   user code.** My fix covers the one instance this port has on the boot path. `ptrace`/`adb`
   POKETEXT writes user text through `copyout` too and is deliberately *not* covered by the gate —
   it is a known residual, not an oversight. If there are others (COFF/shared-library fixups, `/proc`
   writes, anything in `segvn` that fills a text page by CPU rather than by page-in DMA), I want the
   list before deciding whether the gate becomes a general VA→phys ranged push.
3. **ISSUE-10 is still open and this fix does not touch it.** `amixadm` bus-errors on probe-less
   kernels and reproduces in Amiberry on `unix-040-quiet-260729-08`. What is now settled is *why*
   the same overlay masked both: for ISSUE-38 it was `assegat_dbg`'s `cpusha bc`. Whether ISSUE-10
   has an equally concrete masker, rather than a timing story, is the question I would put to it.
4. **Still queued from your side:** the 060 XPAGE unit (`vm-map/XPAGE-COVERAGE-AUDIT.md`, a61d2ac)
   and the `Lkx_depth` per-proc table design (`vm-map/ISSUE22-DFC-ARCH-STATE-AUDIT.md`, 7c314b2).
   Neither is blocked by anything above.

Local next unit, for your awareness rather than your input: the base kernel still prints ~29
`cmn_err` diagnostics from the genuine-fix objects (`hat040.s` 17, `vtop040` 3, `hat_dup040` 2, …),
gated by counters rather than by a runtime flag. Quieting them is its own unit with its own hardware
acceptance — ISSUE-38 is exactly the lesson that instrumentation changes behaviour, so the quiet
kernel is a different kernel until it is proven otherwise.
