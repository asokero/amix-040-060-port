# A3091 68040 B2 DMA Prepare/Complete Patch Specification

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/A3091-B2-PREPARE-PATCH-SPEC.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** `src/dma_cache040.s` and
> `src/patch_a3091_dma.py` implement this prepare/complete state machine. It is
> part of the copyback-by-default kernel accepted on 68040 and 68060 hardware;
> the recorded 68040 pressure run paired all observed operations and kept
> `dma_cmpl_noprep` at zero. A2090, A2091, and native `hd` remain deferred as
> scoped below.

## Scope and pinned target

This is the directly implementable specification that replaced the accepted B1
whole-cache read-completion invalidate with a B2-safe A3091 segment ownership
protocol. The specification itself changed no kernel file.

Pinned target:

- kernel implementation commit: `5f745d5`
- `build/unix-040` SHA-256:
  `d3e1f80a65394f951ffe894eefe2efcfe7b862786937b0eaf0154440608e8404`
- `build/unix-040-dbg` SHA-256:
  `410a6143097ce4d2394f9555d3f2c55cddbdf1c9a991126f43bf05d8676df117`
- ELF `.text` file offset: text address `+ 0x34`
- current A3091 source provenance:
  `amix-src/sys/amiga/alien/a3091.c:321..355` and `alien/sd.h:35..46`
- real-hardware pilot: A3000/Mercury 68040, A3091 host-RAM DMA only

A2090, A2091, native `hd`, Z3 devices, and real-68060 cache acceptance remain
outside this patch.

## Verdict

**Retarget both A3091 `startdma` calls to a prepare wrapper and extend the
existing stop wrapper into the matching complete owner.**

The required implementation is small and bounded:

- two start relocation retargets;
- the existing four stop retargets remain unchanged;
- one single-segment metadata/state record;
- prepare before every nonzero initial or reconnect arm;
- complete after hardware is stopped and before any callback/requeue consumer;
- range invalidation at FROM_DEVICE completion;
- no whole-cache invalidation after the B2 flip.

For the first real-040 B2 pilot, use a whole-cache `cpusha dc` at prepare and
the real per-range `cinvl` loop at FROM_DEVICE complete. This is a safe,
conservative intermediate implementation. Retain exact range metadata from
day one so prepare can later become per-range without another controller
redesign.

## Source and structure provenance

The byte-identical AMIX driver source defines:

```text
struct unit:
  +0x00 next
  +0x04 comhead
  +0x08 comtail
  +0x0c tc0
  +0x0d tc1
  +0x0e tc2

struct sdcom:
  +0x00 next
  +0x04 reading
  +0x14 addr
  +0x18 nbyte
  +0x24 intr
```

`startdma(unit *up)` reconstructs the current WD33C93 transfer count, obtains
`cp=up->comhead`, selects direction from `cp->reading`, and programs:

```text
n  = (up->tc0 << 16) | (up->tc1 << 8) | up->tc2
pa = cp->addr + cp->nbyte - n
device->sac = pa
device->sdma = 1
dma_on = 1
```

The pinned binary matches this exactly:

```text
0x0000d40a  startdma
0x0000d44c  read tc0/tc1/tc2 and assemble n
0x0000d470  return if n == 0
0x0000d474  cp = up->comhead
0x0000d478  direction = cp->reading
0x0000d4a2  cp->addr + cp->nbyte - n
0x0000d4ae  device->sac = pa
0x0000d4b2  device->sdma = 1
0x0000d4b8  dma_on = 1
```

This gives the exact physical segment and direction before hardware arm. No
generic BIO layer has equivalent reconnect visibility.

## Current B1 baseline

`a3091_stopdma_orig 0xd4cc` checks `dma_on`, issues `fdma`, polls completion,
clears the controller interrupt/reset state, and clears `dma_on` at `0xd50a`.

Four A3091 interrupt-DFA calls are already relocation-retargeted to
`dma_a3091_stopdma 0xd9fce`:

| Stop relocation field | File offset | Current assertion |
|---:|---:|---|
| `0xd170` | `0xd1a4` | `R_68K_32 dma_a3091_stopdma` |
| `0xd1c8` | `0xd1fc` | same |
| `0xd2ce` | `0xd302` | same |
| `0xd34a` | `0xd37e` | same |

The wrapper snapshots `dma_on`, calls the original stop body, then executes:

```text
0xd9fc4  f4 58                   cinva dc
0xd9fc6  52 b9 00 00 00 00       dma_cmpl_count++
```

That global invalidate was accepted for B1 because no dirty CB lines existed.
It is forbidden after `hat_cm_ram=0x20`: unrelated CPU work can become dirty
while DMA is active, and a completion-time `cinva dc` would discard it.

## Start relocation patch

Relocation enumeration finds five symbols named `startdma` across several
controllers, but exactly two refer to A3091's local body at `0xd40a`.

| Purpose | Call opcode | Relocation field | File opcode/field | Current bytes | Current relocation | Replacement relocation |
|---|---:|---:|---:|---|---|---|
| initial arm from `startany` | `0xd0b0` | `0xd0b2` | `0xd0e4` / `0xd0e6` | `4e b9 00 00 00 00` | `R_68K_32 startdma` value `0xd40a` | `R_68K_32 dma_a3091_startdma` |
| reconnect/re-arm | `0xd218` | `0xd21a` | `0xd24c` / `0xd24e` | `4e b9 00 00 00 00` | same | same wrapper |

Extend the proven `patch_a3091_dma.py` relocation-retarget mechanism rather
than patching resolved absolute addresses. Required assertions:

```python
A3091_STARTDMA_CALLS = [0x0000d0b2, 0x0000d21a]
ORIGINAL_STARTDMA = 0x0000d40a
START_WRAPPER = "dma_a3091_startdma"
```

For each entry, assert the preceding opcode is `0x4eb9`, relocation type is
`R_68K_32`, and current symbol/value names this A3091 `startdma`. Abort on any
mismatch. Do not retarget the A2090/A2091 sites at `0xc2b8`, `0xc87e`, or
`0xca2a`.

The relink symbol map must preserve the original local body under a callable
global alias, parallel to the B1 stop arrangement:

```text
a3091_startdma_orig = .text:0x0000d40a, function, global
a3091_stopdma_orig  = .text:0x0000d4cc, function, global   # already present
```

## Metadata and state

One A3091 hardware segment can be active because `dma_on` is global and the
driver serializes the interrupt DFA. Allocate one record in the appended
machine-dependent object:

```c
struct a3091_dma_segment {
        uint32_t pa;
        uint32_t len;
        uint32_t seq;
        uint8_t  direction;       /* TO_DEVICE or FROM_DEVICE */
        uint8_t  state;           /* EMPTY, PREPARING, PREPARED */
        uint16_t reserved;
};
```

`PREPARED` means cache ownership has been transferred and the original arm
may be active. Do not set a new `ARMED` state after calling the original body:
the device can interrupt and complete between the original arm and the
wrapper's return. The record must already be consumable before the call.

Required debug counters:

```text
prepare_to_device
prepare_from_device
complete_to_device
complete_from_device
zero_length_arm
reconnect_arm
prepare_while_owned
complete_without_prepare
double_complete
range_overflow
whole_cache_prepare
rounded_lines_total
max_segment_length
sequence
```

Retain the last `pa`, `len`, direction, and sequence after a failure so a
diagnostic names the exact segment.

## Start-wrapper algorithm

The wrapper receives the same `unit *` argument as the original and preserves
the driver's ABI-visible registers.

```text
dma_a3091_startdma(up):
        n = (u8(up+0x0c) << 16) |
            (u8(up+0x0d) << 8) |
             u8(up+0x0e)

        if n == 0:
                zero_length_arm++
                call a3091_startdma_orig(up)
                return

        cp = *(up+0x04)
        assert cp != 0
        direction = (*(u8 *)(cp+0x04) != 0) ? FROM_DEVICE : TO_DEVICE

        end = *(u32 *)(cp+0x14) + *(u32 *)(cp+0x18)
        assert no addition underflow/overflow
        assert end >= n
        pa = end - n
        len = n
        assert pa + len does not wrap

        assert state == EMPTY
        state = PREPARING
        store pa, len, direction, ++sequence

        dma_cache_prepare(pa, len, direction)
        state = PREPARED

        call a3091_startdma_orig(up)
        return
```

The metadata must be stored before cache maintenance, and `PREPARED` must be
visible before hardware arm. A short interrupt exclusion or the driver's
existing serialization must cover record publication; hardware is not yet
armed during `PREPARING`.

`n` is the currently programmed segment length, not necessarily the original
request length. On reconnect, the Save Data Pointers path has updated
`up->tc0..2`; `pa=addr+nbyte-n` therefore points at the remaining suffix. The
second retarget at `0xd21a` prepares that exact suffix again.

## Stop-wrapper algorithm

Replace the B1 global-completion helper inside the existing wrapper; keep all
four stop relocations targeting it.

```text
dma_a3091_stopdma():
        was_on = dma_on
        if was_on:
                assert state == PREPARED
                snapshot pa, len, direction, sequence

        call a3091_stopdma_orig()       /* quiesce first; clears dma_on */

        if not was_on:
                return                  /* stock spurious-stop behavior */

        dma_cache_complete(pa, len, direction)
        direction-specific complete counter++
        assert sequence still matches
        state = EMPTY
        return
```

Completion must occur after `fdma`/poll/cint/srst and before the wrapper
returns to the interrupt DFA. All four current call sites therefore complete
before callback invocation, requeue visibility, `startany`, or reconnect arm.

Call complete even on controller error or partial transfer. Hardware may have
written a prefix. Conservatively invalidating the whole **programmed** segment
is safe because prepare transferred ownership of the rounded range and the CPU
must not touch it until complete.

TO_DEVICE complete normally performs no cache instruction, but it must still
consume the state record and increment its pairing counter.

## Range operations

Both CPUs have a 16-byte cache line. Validate and round with unsigned
overflow checks:

```text
first = pa & ~0x0f
last  = (pa + len + 0x0f) & ~0x0f    /* first byte after final line */
lines = (last - first) >> 4
```

Reject zero length in the common range helper; the wrapper handles it before
ownership transfer. The CPU must not access any byte in the rounded first/last
line while the device owns the range. This is the required partial-line rule,
not an optional optimization.

### Production range prepare

```text
TO_DEVICE prepare:
        for each line: cpushl dc,(line)

FROM_DEVICE prepare:
        for each line: cpushl dc,(line)
        ensure the line is invalid before arm

FROM_DEVICE complete:
        for each line: cinvl dc,(line)
```

Verified opcodes for the assembler/toolchain are:

| Instruction | Opcode |
|---|---|
| `cpushl dc,(a0)` | `f4 68` |
| `cinvl dc,(a0)` | `f4 48` |
| `cpusha dc` | `f4 78` |
| `cinva dc` | `f4 58` |

On 68040, `CPUSHL` pushes a dirty line and invalidates it, so it supplies the
FROM_DEVICE pre-arm state as well as TO_DEVICE writeback. An explicit `CINVL`
after `CPUSHL` is harmless and makes the intended state obvious.

On 68060, CPUSH invalidation depends on CACR.DPI: DPI clear pushes and
invalidates; DPI set pushes while leaving the line valid. The current CACR
value `0x80008000` has DPI clear, but a shared future helper must either assert
that invariant or issue an explicit `CINVL` wherever invalid state is part of
the contract. This specification recommends explicit post-push invalidation
for FROM_DEVICE and leaves real-060 acceptance separate.

### Physical address and aliases

The segment address is the same physical address written to A3091 SAC. Cache
line operations are selected by physical line, so they cover high KVA/user CB
aliases of that RAM. Retained DTT0 also makes the low identity address usable
for the helper. Do not substitute a temporary `bp_map` VA and do not infer
ownership from mapping lifetime.

## Recommended 040 pilot intermediate

For the first real-hardware B2 session, implement:

| Direction | Prepare | Complete |
|---|---|---|
| TO_DEVICE | `cpusha dc` | state completion only |
| FROM_DEVICE | `cpusha dc` | per-range `cinvl` after stop |

Reasons this is safe:

- prepare occurs before the device is armed;
- `cpusha dc` writes every dirty line to RAM and invalidates it on 68040; it
  does not lose unrelated data as `cinva dc` would;
- A3091 is the only host-RAM DMA owner in the scoped machine, so no other
  host-RAM device range is concurrently exposed;
- completion is still range-only, avoiding the fatal B2 global-invalidate
  problem while unrelated CPU work may be dirty.

The performance tradeoff is acceptable for a correctness pilot. The 68040
data cache is 4 KiB / 256 lines; a 4 KiB or larger segment already makes a
line loop inspect at least a cache's worth of physical range, while the global
instruction has fixed hardware cost. Short request-sense transfers and small
reconnect suffixes will over-flush, so counters must record segment lengths.

Recommendation:

1. ship the first 040 B2 test build with global prepare plus range complete;
2. require byte-correct disk truth and arm/complete counters;
3. measure segment-size distribution and throughput;
4. replace global prepare with the production range loop after correctness is
   established, without changing metadata or controller ownership.

Do not use global `cinva dc` anywhere in a B2-reachable completion path.

## Patch layout

The implementation should extend `prototypes/dma_cache040.s` and
`prototypes/patch_a3091_dma.py` rather than add a second ownership subsystem.

Required exported/internal symbols:

```text
dma_a3091_startdma
dma_a3091_stopdma                  # existing name, extended body
a3091_startdma_orig
a3091_stopdma_orig                 # existing
dma_cache_prepare
dma_cache_complete
a3091_dma_segment
debug counters listed above
```

Required patcher phases:

1. assert the pinned image hash or a caller-supplied accepted hash;
2. locate exactly the two A3091 start relocation fields;
3. assert both preceding `4eb9` opcodes and target `startdma@0xd40a`;
4. retarget both to `dma_a3091_startdma`;
5. assert all four stop sites still target `dma_a3091_stopdma`;
6. assert no A3091 direct call to original start/stop remains except wrapper
   calls;
7. require the appended object and original aliases in the relink map;
8. fail closed on symbol count, address, type, or old-byte mismatch.

## Disconnect, error, and residual cases

| Case | Required behavior |
|---|---|
| initial request | derive full current `n`, prepare, publish metadata, arm |
| target disconnect | stop wrapper quiesces and completes the programmed range before requeue |
| reconnect | `0xd21a` wrapper derives updated remaining suffix and prepares it before re-arm |
| partial/error status | complete the full programmed range conservatively; device may have written a prefix |
| zero transfer count | call original no-arm path; do not create ownership state |
| spurious stop with `dma_on==0` | original no-op semantics; no complete; counter optional |
| prepare while state nonempty | diagnostic panic/fail-fast in debug build; never overwrite metadata |
| completion without PREPARED | diagnostic panic/fail-fast; do not run unbounded cache operation |

Overlapping invalidation on disconnect/reconnect is harmless: the first
prepare already pushed endpoint bytes and the CPU is forbidden to modify the
owned rounded range. Completion invalidates it, and the reconnect prepare
establishes ownership again for the remaining suffix.

## Static acceptance

Reject the B2 image unless:

1. both start relocation fields target `dma_a3091_startdma` and no other
   controller's `startdma` was changed;
2. all four stop fields still target the extended stop wrapper;
3. every nonzero original start is preceded by a PREPARED metadata record and
   cache prepare;
4. stop quiesces hardware before FROM_DEVICE invalidation;
5. callbacks/requeue/re-arm cannot run before complete;
6. range rounding is 16-byte, overflow checked, and uses the stored programmed
   segment rather than request-global state;
7. no reachable B2 completion executes `cinva dc`;
8. the build either uses the recommended global prepare or implements both
   direction-correct line loops;
9. the final cache-op census and relocation list are archived with the build.

## Runtime acceptance

Emulation can verify pairing and control flow but cannot accept data-cache
coherency. Before the real-040 session, use an emulator build to require:

- two start sites observed;
- reconnect count increments under a workload that disconnects;
- every nonzero prepare sequence has exactly one complete;
- no state-overwrite, double-complete, overflow, or missing-metadata counter;
- existing 040/060 `hat_dup_cow` and disk/network smoke tests still pass.

Real A3000/Mercury 68040 acceptance:

1. baseline smoke before the CM flip;
2. B2 boot with `hat_cm_ram=0x20` and read-back of CACR/DTT/representative PTEs;
3. sustained reads and writes through buffer cache, page I/O, swap, raw I/O,
   and disconnect/reconnect paths;
4. NFS-to-local and local-disk copies with checksums;
5. power-cut disk-truth verification after dirty writeback;
6. `burst4`, `hat_dup_cow` 1/32/256, swap pressure, and Dhrystone delta;
7. archived counters showing balanced ownership in both directions.

## Closure-search record

Three independent searches support the patch:

1. source-first comparison of byte-identical `a3091.c`/`sd.h` with the current
   disassembly establishes structure offsets and segment arithmetic;
2. relocation enumeration distinguishes the two A3091 starts, four already
   wrapped stops, and unrelated same-named controller functions;
3. mechanical cache-op and byte census proves the current B1 body has only a
   global completion `cinva dc` and no hidden line-range implementation.

## Bottom line

The A3091 already exposes the exact B2 ownership boundary. Wrap its two arm
sites, record `pa/len/direction` before hardware starts, and consume that
record in the existing four-site stop wrapper after hardware stops. Use global
`cpusha dc` prepare plus range FROM_DEVICE completion for the first real-040
pilot, then optimize prepare to `cpushl` ranges without changing the state
machine. A completion-time whole-cache invalidate must not survive the B2
flip.
