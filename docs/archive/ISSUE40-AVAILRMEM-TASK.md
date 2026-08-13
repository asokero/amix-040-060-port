# TASK for Codex — 2026-08-01: `availrmem` loses exactly one page per `exec`

Requested deliverable: an analysis note in `amix-kernel-analysis/vm-map/`, suggested name
`AVAILRMEM-ACCOUNTING-AUDIT.md`. **Do not patch the kernel.**

This is a measurement handing over a question, not a hypothesis looking for support. The rate is
exact, the denominator is exact, and one hypothesis has already been eliminated by measurement.

---

## Provenance

```text
kernel repo HEAD        f332ce5 (this file adds to it)
build/unix-040          68040-260801-04
  SHA-256               e956ea34dd83c77bb759151e957713b0a3d7e2148f4596126523d56f3739befb
  textsize              0xe4588   (.data offsets below are relative to it)
hardware                A3000 + Mercury 68040, copyback (hat_cm_ram = 0x20)
```

The base is fully accepted on this hardware: battery 9/9 + `ptracepoke`, burst 96/96
(`docs/REALHW-ACCEPTANCE-260801.md`). The behaviour below is **not** a regression of that acceptance —
data integrity was perfect throughout every run that measured it.

---

## 1. The fact

**Every `exec` permanently loses exactly one page of `availrmem`. `fork` loses nothing.**

`test-tools/leaktest.c` does exactly N of one or the other, so the denominator is not a guess
(the shell loops previously used were: `k=\`expr $k + 1\`` forks and execs too):

```text
                            availrmem      delta / 300
settled                          2299
300 x fork + exit                2300           +1        <- no loss
300 x fork + exit                2284          -16        <- 0.05/fork, background
300 x fork + exec + exit         1980         -304        <- -1.013 per pair
300 x fork + exec + exit         1665         -315        <- -1.050 per pair
```

It does not come back. Ten minutes of idle after a load returns nothing and the value keeps
drifting slowly down (`issue40.sh`):

```text
phase             freemem  availrmem   d(availrmem)
boot+0s              4880       6878
baseline idle        4873       6872          -6
after load 1         5606       5750       -1122
idle+10min           5293       5687         -63     <- no recovery
after load 2         4222       4643       -1044
idle+10min           4231       4607         -36     <- no recovery
```

**`freemem` is healthy the whole time** — after load 1 it stood *higher* than baseline, because
deleting the test files returned their cached pages. Real pages are freed and re-listed
correctly. Only the accounting ratchets.

Consequences observed over a 100-minute run of four identical 16-burst suites: `availrmem`
3981 → 1847 pages, near-linear at ~21 pages/min, and the suites slowed **24m37s → 27m03s →
34m56s → 45m56s** for identical work. All four were 96/96 correct.

---

## 2. Complete census of `availrmem` writers in this image

Every relocation naming `availrmem`, mapped to its containing function. **`hat_ptfree` at
`0xd860e` is OURS** (`src/hat040.s`); everything else here is a stock body.

```text
exit                0x03f51c  addql #4          <- USIZE = 4 in this kernel
kmem_allocspool     0x041bca  subql #1     0x041bf8  addql #1
kmem_allocbpool     0x041de6  subql #4     0x041e56  addql #4
kmem_alloc          0x042036  subl  %d2    0x042062  addl  %d2
kmem_free           0x04247c  addl  %d2
kmem_freepool       0x042c84  addql #4     0x042cda  addql #1
ublock              0x043086  subql #4
ubunlock            0x0430d2  addql #4
kseg                0x0a8d9e  subl  %d3
unkseg              0x0a8e6c  addl  %d4
segu_get_orig       0x0aa516  subql #4     0x0aa568  addql #4
segu_release        0x0aa78e  addql #4
segvn_softunlock    0x0abeb8  addql #1
segvn_faultpage     0x0ac0a0  subql #1     0x0ac416  addql #1
page_abort          0x0af95a  addql #1     0x0af97e  addl  %d0
page_pp_lock        0x0b08a0  movel %d0    0x0b096a  movel %d0
page_pp_unlock      0x0b0ae6  addql #1
page_addclaim       0x0b0e80  movel %d0
page_subclaim       0x0b0fa2  addql #1
page_delmem         0x0b114e  subql #1
page_addmem         0x0b11f4  addql #1
hat_sdtalloc        0x0b6464  subl  %d3    0x0b64f0  addl  %d3
hat_sdtfree         0x0b66e4 / 0x0b678c / 0x0b6834  addql #1   (three exits)
hat_ptalloc         0x0b6960  subql #1     0x0b698e / 0x0b6a30 / 0x0b6eac  addql #1
hat_ptfree (OURS)   0x0d860e  addql #1     <- one credit, on the page_free path only
```

The 3b2 contract for the same variable is in
`kernelsupport/svr4-src-3b2/usr/src/uts/3b2/`: `os/exit.c:215`, `os/lock.c:192-209`,
`vm/seg_u.c:648-671,839`, `vm/seg_kmem.c:659-692`, `vm/vm_hat.c:2224-2709`,
`vm/vm_page.c:1233-1725`, `vm/seg_vn.c:947-1332`, `os/kma.c`.

Note `#define USIZE 3 /* size of user block (*2048 bytes) */` in the 3b2 `sys/param.h`; this
kernel uses **4**, and no Model-B conversion has been applied to any of the USIZE sites above —
they all still read 4. Whether 4 is correct when a click is 4 KiB rather than 2 KiB is a
question in its own right, but note that a *uniformly* wrong magnitude cancels and cannot
produce this leak.

---

## 3. Hypothesis already eliminated — please do not re-derive it

Our `hat_ptfree` (`hat040.s`, V2.1) credits `availrmem`/`availsmem` and decrements
`pages_pp_kernel` **only** on the path that actually reaches `page_free`. It has two other
exits: `Lpf_leak` (table not page-aligned, or pfn outside `pages[]`, or keepcnt already 0) and
`Lpf_held` (another holder remains). `Lpf_leak` is even commented "leak (V1 behavior)" and its
print is capped at 8, which is exactly the shape of a defect that hides.

**It is not this.** `Lpf_n` (`.data+0x17f26`, runtime `0x080FC4AE`) reads **0** after thousands
of execs on the measured boot, so the `Lpf_leak` exit is never taken. `Lpf_held` remains
untested and has no counter.

---

## 4. What is asked

1. **Pair every debit with its credit over the `exec` path**, using the census above and the 3b2
   contract, and identify the site whose debit has no matching credit. The answer must predict
   **exactly −1 per exec and 0 per fork** — a candidate that predicts −2, or that also fires on
   fork, is refuted by §1 and should be reported as refuted rather than offered.
2. Say explicitly whether the missing credit is in **stock code** or in one of the **port's own
   overrides** (`hat040.s` hat_ptalloc/hat_ptfree/hat_alloc/hat_free, `segu_lockfix.s`,
   `segu_ubptbl040.s`, `kvm040.s`, `segkmem040.s`). The port has form here — ISSUE-7 was a lost
   `segu` keepcnt hold and ISSUE-20 is an open `hat_swapout` mine — and knowing which side owns
   it decides whether the fix is a patch or a rewrite.
3. If the answer depends on a value we can read, **name the address and the expected reading**.
   Reading `.data` longs and following the loader-resolved COMMON pointers is now routine:
   `test-tools/memwatch.c` + the `i39_*` table in `src/issue39_040.s`.
4. Note in passing whether `USIZE = 4` is correct for a 4 KiB click, and whether any USIZE site
   is a Model-B residual. This is secondary to the leak but it is the same audit.

## 5. What is NOT asked

Do not propose a fix that merely credits `availrmem` back at the point of loss. The pairing has
to be understood first: this variable gates `kmem_alloc`, `segu_get`, `ublock` and
`hat_sdtalloc` against `tune.t_minarmem`, and a wrong credit turns a slow degradation into an
over-committed machine.

---

## 6. Reproduction, if you want more data points

Everything is staged on the hardware and on the NAS (`amix/hwtest-260801/`):

```sh
/tmp/leaktest 300 0        # fork only
/tmp/leaktest 300 1        # fork + exec
A=`/kpeek 080FCFA4 1 | sed 's/.*= //;s/ .*//'`   # follow i39_availrmem_p
/kpeek $A 1
```

Logs from the runs quoted above: `issue40.log`, `issue40b.log`, `leakrun.log`,
`memwatch-repeat.log`, `burstrepeat.log`.
