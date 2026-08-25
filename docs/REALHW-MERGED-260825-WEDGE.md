# `68060-260825-02` wedged after the burst — open, session ended 2026-08-26

The machine was powered off while wedged. **The power-cut test did not run**: its write phase
never executed, so this shutdown is not that test and produces no verdict about it.

## What was completed first, and passed

| step | result |
|---|---|
| 1 host gates, second build, byte diff | ✅ `TOTAL complaints: 0`, `bindings failing: 0`, one differing byte (build-id) |
| 2 identity + magics | ✅ **30/30** |
| 3 battery | **11/12** — the miss is ISSUE-49, character-identical to `68060-260819-13` |
| counter deltas | ✅ three invariants exact |
| 4 CPU-specific | ✅ `fp060probe bad=0`, `isp61ea bad=0`, `fputest060 fork`, Motorola `unimp` and `main` 4/4 |
| 6 burst | ✅ **72/72** (3 rounds — `R=${1:-3}`, run with no argument), zero anomalies |

## The wedge

After the burst the machine answered **ping** but telnet returned **no login prompt at all**
(0 bytes, repeatedly). The console was alive and showed a `login:` prompt.

**The user's reading, which fits the evidence better than anything else considered:** the A3091
SCSI driver has jammed. The network stack is interrupt-driven and lives in memory, so ping keeps
working; `telnetd` forks a login shell that must read from disk, so every inbound session hangs
before printing anything. That is exactly the observed asymmetry.

Console, in order:

    WARNING: DBG krnxflt FAILEXIT w=2 va=434D4642 rw=1 depth=1
    NOTICE: User BUS ERROR at C1033000, PC:80000AF2 FAULT:6 PID:847 CMD:./protfault a
    NOTICE: User BUS ERROR at C1034040, PC:80000AF2 FAULT:6 PID:849 CMD:./protfault b
    u_trap WARNING: SIGKILL sent to pid 1136 (./isp61ea ) because of vector 0xF4, pc=0x80000608
    a3091: 0x16 0 0x8112B84

The two `protfault` NOTICEs are the battery's own deliberate faults and are expected.

### `a3091: 0x16 0 0x8112B84`

The format is `a3091: 0x%x %d 0x%x`, in the stock driver (binary only — `a3091.c` is not in
this tree). The string sits at `0xd650`, immediately before a symbol named `badhardware`, which
is suggestive but **not yet evidence**: the call site was not located before the session ended.
Decoding the three fields is the first job next time.

### `FAILEXIT w=2 va=434D4642` — probably worth more than it looks

`w=2` means, per `krnxmemflt040.s`'s own probe legend, **"no kas segment owns the fault
address"** — a kernel access to an address no kernel segment covers. And `kdbg040.s` says of this
message: *"NOT GATED (never fires on a healthy boot = a real warning, and its silence is what
makes it worth reading)"*. So it is a real warning by the project's own standard.

**`0x434D4642` is ASCII `CMFB`** — the value of `cmf_magic`, the change-D census block's magic
word. An address that is exactly a magic word means something used the *value* as a pointer.

Two hypotheses, neither tested:

1. **It is a misdecoded fault address.** There is precedent: `060-F0-MEASUREMENT-260805.md`
   records `FAILEXIT w=2 va=FFFFFFFA rw=1 depth=1` where the `va` was garbage read out of a
   format-4 frame by an 040-shaped decode. If the same misdecode happens here, `CMFB` is just
   whatever lay at that offset and means nothing.
2. **Something genuinely dereferenced the magic.** The census only ever *writes* `%a4` into its
   block, so no obvious path in change D reads it back — but "no obvious path" is not a check.

Distinguishing them is cheap and should be done before anything else is concluded: the frame
format is in the fault frame, and hypothesis 1 predicts the address is not reproducible while
hypothesis 2 predicts it is.

### `SIGKILL … (./isp61ea) because of vector 0xF4`

`isp61ea` nevertheless printed `ISP61EA bad=0` and `ISP61EA-DONE`, and its last line is
`postinc muls.l (a0)+ declined (status 0x9) -- expected on a 68060`. So this is plausibly a child
process deliberately killed by the declining case. Plausible is not measured; it is on the list.

## State the machine was left in

Wedged, then powered off. The filesystem was not cleanly unmounted, so the next boot will `fsck`.
The burst left `/press1.bin` … `/press6.bin` (6 × 4 MiB) and `/payload.bin` on the root
filesystem, plus the battery's binaries in `/tmp` — which the boot clears.

## Next session, in order

1. Boot and read `fsck`'s output before anything touches the disk.
2. Decode `a3091: 0x16 0 0x8112B84` from the disassembly — the call site near `0xd650`.
3. Decide between the two `FAILEXIT` hypotheses.
4. Determine whether the wedge reproduces, and whether the burst is what provokes it. `dma_zero_arm`
   and `dma_reconn_arm` in `dma_cache040.s` are anomaly counters on the A3091 DMA path; both read
   **zero** in the pre-burst dormancy check, so reading them after a burst is the obvious first
   measurement and it has never been taken.
5. Only then the power-cut test, which still has not been run on this image.
