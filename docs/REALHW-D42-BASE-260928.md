# The D42 service in the base, and the A3091 pilot unmoved — 2026-09-28, `68040-260928-05`

**Artifact** `build/unix-040-rtg`, sha256
`a1fa433770701aa81dad8cbdf6eabadf72440ca79f4eb2d303169d94e2f4a8f3`
**Machine** Amiga 3000, Mercury 68060, MNT VA2000 in Zorro III.
**Loader** `unix_boot040` (mandatory).

What this run accepts is narrower than what the artifact contains, and the difference is worth
stating first. Three changes went in together:

* `5882ef5` — the cross compiler's wrapper was reinstalled (ISSUE-71). The four fixes had been on
  `gcc-cross-amix` `main` since 2026-08-30; what was a month old was the installed copy.
* `ece209f` — `dma_prepare` / `dma_complete`, the generalized D42 service, added to
  `src/dma_cache040.s` beside the A3091 B2 pilot.
* `f19265a` — the service's contract, `docs/contracts/DMA040-SERVICE-RECORD.md`.

**The new service is not what this run tests.** Nothing on this machine calls it: the A3091 keeps
its own wrappers and its own global record, and the A4091 that will call it is on the other
development line. It is inert here by construction. What is tested is that adding it **did not
disturb the thing that does work**.

## Why a run was needed at all

The A3091 wrappers were not touched, and that was verified rather than assumed: `dma_a3091_stopdma`
disassembles to the same 77 instructions before and after, with only the `.data` operand addresses
moved. But the base `.text` grew by 364 bytes, which moves **every** runtime counter address, and
this port's own rule is that "it built" is not evidence.

There is also a plainer reason: the machine boots its root disk through the A3091. Reaching
multiuser is itself a substantial test of the DMA wrappers, and it did.

## The wrapper change first: byte-identical

Before anything was run on hardware, `relink-040.sh` was rebuilt under the reinstalled wrapper and
compared against the previous base. Identical size, **three differing bytes**, all inside the
build-id string at `.data+0x10ef08` (`260914-01` → `260928-03`). The four wrapper fixes — `-E`,
two link-line behaviours and an SGS bit-field spelling — change no code this kernel contains.

That is the regression test `AGENTS.md` asks for after an infrastructural change, and it means the
hardware run below is about the 364 bytes and nothing else.

## The measurement

One synchronous session, no concurrent connections. `dma_magic` was read at both ends and read
`444d4121` (`"DMA!"`) each time, so no value below is from a stale address.

Load: `dd` writing 16 MB into the root filesystem with `sync`, then `dd` reading 12 MB from the
**raw** device `/dev/rdsk/c6d0s1`, which bypasses the buffer cache so every byte comes off the
disk. Both directions on purpose — `complete` performs a cache operation only for `FROM_DEVICE`,
so a load that only wrote would leave that arm unexercised.

| counter | before | after | delta |
|---|---:|---:|---:|
| `dma_prep_to` | 5373 | 10099 | +4726 |
| `dma_cmpl_to` | 5373 | 10099 | +4726 |
| `dma_prep_from` | 3210 | 10074 | +6864 |
| `dma_cmpl_from` | 3210 | 10074 | +6864 |
| `dma_cmpl_count` | 8583 | 20173 | +11590 |
| `dma_prep_owned` | 0 | **0** | |
| `dma_cmpl_noprep` | 0 | **0** | |
| `dma_range_ovf` | 0 | **0** | |

**About 11 600 DMA transactions**, and the invariants hold exactly:

* `prep_to == cmpl_to` and `prep_from == cmpl_from` — every prepare paired;
* `10099 + 10074 = 20173 = cmpl_count` — to the longword;
* the three must-stay-zero counters stayed zero.

**The zeros are not the zeros of an unexercised branch.** The `FROM_DEVICE` arm — the one that
runs the `cinvl` range loop — moved by 6864, so it executed nearly seven thousand times while
those counters stayed at zero.

## What this does and does not establish

**Does:** the A3091 B2 pilot works unchanged at the new `.text` layout; the reinstalled wrapper
produces a kernel identical but for its stamp; the artifact boots, roots and sustains a mixed
read/write load.

**Does not:** it says nothing about `dma_prepare` / `dma_complete`, which no client calls here. The
counters in `struct dma_rec` are the instrument for the run that first does, and that run belongs
to whichever line has a second bus master.

It also does not re-accept the VA2000 monitor-switch work that the same artifact carries — that was
measured separately the same day (ISSUE-72, and the switch measurements in `KNOWN-ISSUES.md`).

## An unattributed wedge, recorded because it happened

An earlier attempt at this run ended with the machine answering ICMP at 3.5 ms while port 23 refused
connections, and it had to be rebooted. It is **not attributed** and the owner reports the same
shape of event on this machine before these changes.

Two facts are recorded rather than a conclusion. The network stack was alive, which fits an
exhausted `inetd` better than a kernel fault. And the operator had left **three concurrent
background pollers** opening telnet sessions against a 1991 `inetd`, with timeouts cutting sessions
mid-handshake — which is its own sufficient explanation and was a procedural mistake, not a
finding. The run above was repeated with a single synchronous session and completed without
incident.
