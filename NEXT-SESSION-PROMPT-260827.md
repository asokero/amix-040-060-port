# Next session — start here (written 2026-08-27, end of a long day)

## The one task, if you only do one

**Implement the A3091 interrupt-source demultiplex wrapper.** The design is settled, the analysis
is done, and every pinned value has already been verified against this tree's image.

Read first: `amix-kernel-analysis/vm-map/A3091-SPURIOUS-COMPLETION-AUDIT.md` (Codex, 2026-08-27),
then `docs/A3091-WEDGE-CAPTURED-260826.md` — **including its corrections**, which record two
things this line asserted and the audit refuted.

### Why

`a3091intr` tests SDMAC `ISTR` bit 4 (`INT_P`) and then reads WD `SS` **unconditionally**.
`INT_P` is an aggregate: WD `INTS`, SDMAC `E_INT`, FIFO errors. So a pure SDMAC event is admitted
as a WD event and dispatched on status the data sheet does not define. `atab[IDLE][8]` then
returns `DEAD`, from which there is no recovery, and the machine needs a power cycle. **Four times
on 2026-08-26**, across three kernels.

NetBSD's `sys/arch/amiga/dev/ahsc.c` and Linux's `drivers/scsi/a3000.c` both separate the sources
before reading WD status. Two independent implementations for the same hardware.

### Verified against `build/unix-040` on 2026-08-27 — re-verify, do not trust this table

| property | value |
|---|---|
| table symbol | `int2_tbl`, `.data+0x998c`, size 24, GLOBAL |
| relocation | `.rela.data` `r_offset=0x9998`, `R_68K_32` |
| current target | `a3091intr` + 0, `.text+0xd0e0` |
| neighbours in the table | `aciaaintr`, `jbintr`, `a2091intr`, **ours**, `aenintr` |

Retarget that one relocation to a wrapper, exactly as `src/patch_a3091_dma.py` and
`src/patch_segdev_ops.py` already do elsewhere. `a3091intr` stays callable by name; no weakening.

### Wrapper policy (from the audit, §"Atomic source-demultiplex wrapper")

Take **one snapshot** of `ISTR` at entry, before anything else:

1. `INT_P` clear → count `not_ours`, return as stock does.
2. `INTS` set → call stock `a3091intr`; afterwards re-read `ISTR` and issue `CINT` if a residual
   `E_INT` remains.
3. `INTS` clear and only `E_INT` → issue SDMAC `CINT`, count it, return **without reading WD `SS`
   and without touching the DFA**.
4. underrun / overrun / `INTX` / unclassified → count and report **loudly**. Keep fail-stop.

Check whether the level-2 dispatcher needs a return value; the stock function is C `void`.
Preserve every callee-saved register.

### Explicitly rejected — do not revisit without new evidence

* **`atab[IDLE][8]` → no-op.** A genuine WD `0x16` at IDLE would have action 0 dereference
  `curunitp->comhead` and complete the **wrong** request. Action 1 is a fail-stop guard.
* **`btst #4` → `btst #6`.** Leaves pure `E_INT` unacknowledged: interrupt storm.
* **`srst` as a reset.** It is the `SP_DMA` stop strobe.
* **A `DEAD` → `IDLE` recovery path.** No such path exists in AMIX; building one means resetting
  the controller and settling every active, queued and disconnected request. Not a byte edit.

### Instrument it the way everything else here is instrumented

Counters with **denominators**, magic word first and static. `sdc_*` in `src/segdevchk040.s` is
the model, and today proved why: `sdc_setprot_bad = 0` beside a denominator of 0 said nothing,
and only became evidence once `segdevprot` took the path.

Note `a3d_istr` (added 2026-08-27) is sampled **after** `a3091intr` reads `SS`, which clears WD
`INTRQ`. A surviving `E_INT` there is strong evidence; `INTS=0` proves nothing. The wrapper is
what can classify the entry.

---

## State at the end of 2026-08-27

`main` is **6 commits ahead of `origin/main`**, working tree clean, nothing pushed since the last
time the user pushed. 79 commits on 2026-08-26 alone.

**Three merges landed and hardware-accepted:** `wip/zorro3`, the z3660 line's 73 commits, and the
LC060 line's 54. On `68060-260826-06`: 32/32 magics, battery 11/12, all five CPU tests including
both Motorola entry points, burst 96/96, power cut 6/6 byte-exact.

**ISSUE-49's bridge landed** and `devmaptest` passes on silicon for the first time. The battery
has **not** yet been run to completion on a bridge kernel — the A3091 wedge interrupted it — so
**12/12 has never been seen** and is the first thing to try once the machine is stable.

### Open, roughly in priority order

1. **A3091 wrapper** — above.
2. **Battery to completion on a bridge kernel.** Expect 12/12. If `devmaptest` is MISSING there,
   that is a regression, not the familiar red.
3. **ISSUE-51** — a burst read returned wrong bytes silently and the file was intact afterwards
   (95/96). One event; the next step is rate, not theory.
4. **ISSUE-52** — the load average freezes on garbage after FP-heavy graphics. Whether it is new
   is **unknown**; the cheapest thing that would date it is running something FP-heavy on `-04`,
   which predates the LC060 merge.
5. **`/dev/screen` hardening** for DPaint — 4 KiB base alignment plus a rounded, owned, zeroed
   extent. `MEMF_PAGEB` only aligns to 2 KiB. This is *not* generic ISSUE-49 and must not be
   described as closing it.
6. **ISSUE-50** — `hat_dup_cow` has no source; five copies survive on the NAS
   (`amix/hwtest-260801/`). Step 6 cannot run from a clean clone.
7. **The friend's NetBSD FPU emulator** — brief written, `scratchpad/message-to-jussi-fpe.md`.

---

## Recipes that cost time today

**Talking to the machine.** `scratchpad/real.py` (deliberately not in the repo; reads
`local/secrets.env`). `REAL_TIMEOUT=<seconds>` overrides the 120 s per-command limit.

**Keep commands short.** AMIX's tty truncates at ~250 characters, silently, and it looks exactly
like a slow compile. Anything longer goes in a `.sh` on the NAS; slow work behind
`(nohup sh -c "… > /tmp/x.log 2>&1" &)`. The tell is the echoed command line — the machine echoes
what it actually received.

**AMIX `grep` has no `-E`, no `\|`, and `-q` does not work.** Redirect to `/dev/null` instead.

**Emulator:** `sh emu-reset-boot.sh 060 /tmp/x.log build/unix-040`, then prime the console with
`sendkeys.py 'root' RET` and `'ping 10.0.2.2' RET` before telnet answers. **If a second Amiberry
is running, ours may be on `amiberry_1.sock`** — `AMIBERRY_SOCK` overrides it, and
`ss -ltnp | grep 2323` says which pid actually owns the port you are talking to.

**Identity.** The banner reports the **CPU**, not the image. Use the sha256, or the loader's
`image checksum` line — which is a *file* identity: the same file prints the same value in the
emulator and on hardware, and it reaches the serial log even from a kernel that is otherwise
silent there. A bare build id from 2026-08-19 to 08-25 is **ambiguous** (two build directories).

**Issue numbers:** `tools/next-issue.sh`. Never by hand. `CONTRACTS.md` has the registry.

**The wedge, so you recognise it:** ping works, telnet accepts but never gives a shell (login
needs the disk). The console shows three `a3091dbg` lines. It needs a power cycle, and `fsck`
afterwards reports the benign class only.

## Traps that bit today, all five the same shape

A grep matching text the tool itself produced: a background waiter that found `TIMEOUT` in its own
diagnostic line; the orphan checker flagging the illustrative issue number in its own
documentation; a historical reference in the collision document; `burstloop11.sh`'s wrong-sums
check matching its own header — **and the first fix for that reintroduced it from the other side**.

When a tool searches a stream it also writes to, its own words are in the haystack. Pick a pattern
that cannot occur in prose, and word the heading **without** the literal the grep looks for.
