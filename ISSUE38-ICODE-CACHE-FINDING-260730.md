# ISSUE-38 named and CLOSED: the boot icode was invisible to the 68040 instruction fetch under copyback

2026-07-30. Named from measurements already in hand — **no new hardware boot was spent to reach the
diagnosis**. The fix is `prototypes/cb_icode040.s` in the base link, and it is **hardware-verified**:
`unix-040-b2-fix38-260730-03` — copyback, no probes — boots to telnet on the A3000, with the
mechanism confirmed by its own counters rather than inferred from the boot (§6).

---

## 1. The mechanism in one paragraph

`main+0x1e8` does `copyout(icode, 0x80800000, szicode)`: the kernel CPU writes proc 1's bootstrap
text into a fresh user page, and `_start` then rte's proc 1 to user mode at `0x80800000`, where the
icode runs `lea stack,sp; moveq #11,d0; trap #0` = `exec("/sbin/init")`. On the 68040 the
instruction fetch does **not** snoop the data cache (M68040UM: software must push dirty data before
executing it). With `hat_cm_ram=0x00` (write-through) the icode is in RAM the moment `copyout`
returns, so this never mattered. With `hat_cm_ram=0x20` (copyback) the icode exists only as dirty
data-cache lines: the ifetch reads the still-zero RAM page, executes `0x00000000` as a harmless
`ori.b #0,%d0` about a thousand times, runs off the end of the 4 KiB page into the **unmapped**
`0x80801000`, and proc 1 dies of SIGSEGV **before exec is ever entered**. AMIX icode has no other
exit, so proc 1 becomes a zombie and `swtch`'s delayed cleanup calls `segu_release` — which is the
terminal console line every hanging image ends on.

## 2. The evidence, per observation

**The 0x80801000 fault is the discriminator.** Bisect D's console (photo `IMG_20260729_205911747`,
20:59, identified as D by the `pp=400AD254` / `pp=400AD290` pair quoted in the resume file) shows,
immediately after the icode page is faulted in:

```text
DBG ufault VA=80800000        <- icode page demand-faulted
DBG ptload va=80800000 ... hat_pteload Lballoc leaf va=80800000
DBG ufault VA=80801000        <- NEXT page. Nothing maps it.
DBG ufault VA=80801000
DBG hat_free ENTER as=4015F000        <- address space torn down
... segvn_unmap 80800000 / C07FF000 ...
DBG hat_unload va=48442000 size=2000 flags=A   <- segu_release: proc 1 is a zombie
```

The two booting captures contain **zero** occurrences of `80801000`
(`grep -c` over `test-tools/issue22-serial36-260728.log` and `issue22-serial45-260728.log`), and
there the same window instead reads:

```text
DBG copyout dst=80800000 ret=0 urp=9EE7000 caller=8059994   <- the copy SUCCEEDED
i4FFB0170 ...                                              <- user[0x80800000] = the icode's lea
T8080002A 8080000C                                         <- u_trap: usp set, trap PC = icode's trap#0
... gexec pid=1 ... H 00000000 40448000 7F454C46 ...        <- exec, ELF magic good
```

So the bytes *were* copied (`ret=0`, and main's failure `cmn_err` never prints) and yet execution
ran forward off the page. Copied but not fetchable is a cache-visibility defect, not a VM defect.

**Every row of the bisect table follows from the one mechanism:**

| image | why |
|---|---|
| `-04` write-through, no probes: **boots** | write-through leaves no dirty lines |
| `-07` copyback, no probes: **hangs** | icode stays dirty; two-byte A/B |
| `-09` copyback + serial mirror: **hangs** | `serdbg` adds no cache op |
| `-06` copyback + full overlay: **boots** | overlay contains `assegat_dbg` |
| bisect D (`mainmarks`+`hatalloc_dbg`): **hangs** | neither object touches the caches |
| bisect E (D + `assegat_dbg`): **boots** | see below |
| Amiberry: **boots** | does not model the 040 copyback data cache |

**The masker is a cache instruction, not timing.** `prototypes/assegat_dbg.s`'s `copyout` wrapper
executes an unconditional `cpusha bc` (`.word 0xf4f8`) immediately after `copyout_orig` — before its
own address gate. Any image containing `assegat_dbg` therefore pushes the icode to RAM as a side
effect of instrumentation. `hatalloc_dbg` prints far more and masks nothing because it has no cache
op, and no output at all, between `copyout` and proc 1's first ifetch. E − D = `assegat_dbg` is
explained at instruction level; no appeal to cache footprint or replacement timing is needed.

## 3. Where the earlier reading was wrong

* The terminal `hat_unload va=48442000 size=2000 flags=A` is **not** the exec-header segmap slot. It
  is `segu_release 0xaa718` reclaiming the 8 KiB u-area slot of a process that is already a zombie;
  verified byte-exactly here (`pea 0xA` = HAT_UNLOCK|HAT_RELEPP, `pea 0x2000` = USIZE, `jsr
  hat_unload`), and its only caller in the linked image is `swtch 0xb902c`'s `szombflag` path
  (single relocation at `0xb9076`). Codex's correction (`vm-map/ISSUE38-EXEC-HEADER-ABORT.md`,
  df19c36) is right on both points and was independently re-derived here rather than taken on trust.
* Codex's remaining framing — "the failing edge is in the post-`remove_proc` `elfexec` SIGKILL matrix
  or `setregs`" — is **ruled out**: exec is never entered at all. Its own report contains the reason
  the exec-branch enumeration could not converge: the D log has no exec-layer evidence in it.
* The `page_abort ... p_mapping=0` lines are, as Codex said, ordinary lifecycle paths: the booting
  capture contains the same `caller=80AD7DA` event in the same position. They are not ISSUE-38
  evidence and do not connect ISSUE-38 to ISSUE-10.
* The six-marker phase-probe plan and the four-object masker bisect Codex proposed are **not needed**
  and should not be built: they would have measured exec, which never runs.

## 4. The fix

`prototypes/cb_icode040.s`, linked into the **base** build (`relink-040.sh`), with a hard check that
refuses to ship an image whose strong `copyout` is still the stock body at `0x576`:

```text
copyout  -> copyout_orig(from,to,count)
         -> if to in [0x80800000,0x80801000) and ret == 0:  cpusha bc   (.word 0xf4f8)
```

* `cpusha bc`, not a ranged `cpushl`: on the 040 `CPUSHL` takes a **physical** address (which is why
  `cb_release040.s` converts `pfn<<12` first), so a ranged push of a user VA would need a page-table
  walk in `copyout`. This site runs once per boot, and the whole-cache form is the one already proven
  on hardware by `assegat_dbg`.
* `bc`, not `dc`: the physical page can be recycled from an earlier text page whose lines are still
  valid in the instruction cache, so the IC must be invalidated too.
* **Gated, deliberately.** `copyout` is on every `read(2)`-style return path; a whole-cache
  push+invalidate there would throw away the copyback win being landed. The icode page is the only
  user *text* the kernel CPU writes in this port — all other user text arrives by page-in DMA, whose
  prepare/complete hooks already maintain coherency.
* **Known residual, on purpose:** `ptrace`/`adb` text pokes (POKETEXT) also write user text through
  `copyout` and are *not* covered by the gate. A general fix needs the VA→phys walk above; that is a
  separate unit and must not ride along with the ISSUE-38 A/B.
* Return-value transparent: `d0` is untouched after `copyout_orig` returns; the gate uses `d1` and
  two memory counters.

## 5. Artifacts (NAS `nasu:Public/amix/hwtest-260730/`, `SHA256SUMS-fix38.txt`)

```text
unix-040-fix38-260730-02          base, write-through, no probes, WITH the fix
unix-040-b2-fix38-260730-03       base, COPYBACK, no probes, WITH the fix   <- THE CANDIDATE
unix-040-b2-quiet-fix38-260730-05 copyback + serial mirror, WITH the fix    <- fallback, has serial
```

`-02` vs `-03` differ in exactly two bytes (`hat_cm_ram` `0x00 -> 0x20` at file offset 1033804, plus
one build-id character), so the copyback A/B stays a two-byte A/B. `-03` vs the hanging `-07` differ
by exactly one mechanism: this fix. `unix_boot040` remains the mandatory loader.

Counter runtime addresses in `-03` (recompute after any relink: `0x08000000 + textsize + .data
offset`; read `hat_cm_ram` in the same `kpeek` range as the anchor — it must read `0x20`, which
simultaneously proves copyback was live):

```text
cb_icode_calls 0x080FC9B4      copyouts into the icode window   (expect 1)
cb_icode_push  0x080FC9B8      pushes actually performed        (expect 1)
hat_cm_ram     0x080FC614      ANCHOR, must read 0x00000020
```

In `-05` (quiet): `cb_icode_calls 0x080FCA20`, `cb_icode_push 0x080FCA24`, `hat_cm_ram 0x080FC680`.

## 6. HARDWARE VERDICT — 2026-07-30, ISSUE-38 CLOSED

`unix_boot040 unix-040-b2-fix38-260730-03` on the A3000 + Mercury 040. Verdict taken from telnet,
never from serial (a base image has no `conputc` hook and emits nothing on the serial line by
design; the port's single stale reader was left untouched precisely because it could prove nothing
here).

```text
uname -m                  Amiga (Unlimited) 68040-260730-03    <- copyback, NO probes, reaches login
kpeek 080FC9B4  (calls)   00000001    the gate matched main's icode copyout exactly once
kpeek 080FC9B8  (push)    00000001    the cpusha bc actually executed
kpeek 080FC614  (ANCHOR)  00000020    hat_cm_ram: copyback really was live
kpeek 080FC9A4  (cb_rel)  000042F2    17138 page releases: the B2 release barrier is running
```

The counters matter as much as the boot: a boot with `cb_icode_push == 0` would have meant the image
booted for some other reason. The mechanism is measured, not inferred.

Usability of the fixed image, same session: 30 consecutive `/bin/echo` execs, the native `cc`
compiling a test program, and

```text
/tmp/exectest 20 /tmp/exectest
EXECTEST-RESULT PASS (data+bss verified across every generation)
```

i.e. the exec path that ISSUE-38 broke now survives 20 generations with data and bss verified, on a
probe-less copyback kernel. The copyback default flip (`hat_cm_ram = 0x20` in the base link) is
therefore unblocked; it and the postponed power-cut disk-truth run are separate units.

## 7. What was verified before the boot, and what only hardware could settle

Verified: the mechanism's every step against the linked image (`main+0x1e8`, `segu_release`, `swtch`,
`assegat_dbg`'s push), the good/bad log contrast, and that the fix does not break `copyout` — the
`-05` image boots to a banner and forks userland in Amiberry (`68040-260730-05`, pids 117-128).

Only hardware could settle whether the fix works: Amiberry does not model the copyback data cache,
which is the entire mechanism. It did settle the one thing it can — that the wrapper does not break
`copyout` — and §6 records the hardware verdict that closes the issue.

Residuals deliberately left open (each a separate unit, none of them blocking):

* `ptrace`/`adb` POKETEXT writes user text through `copyout` and is not covered by the gate.
* `ISSUE-10` (amixadm bus error on probe-less kernels) is untouched by this fix and remains open;
  the two were masked by the same overlay, but for different reasons — this one by `assegat_dbg`'s
  `cpusha bc`, and that is now explained rather than suspicious.
