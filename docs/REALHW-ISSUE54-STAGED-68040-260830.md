# Stage D on a 68040 — identical, and the load base moves

`68040-260830-06`, 2026-08-30. The Mercury 68060 was swapped for an A3640 with a 68040 to test
whether the day's instability follows the CPU card. Same kernel image, one variable changed.

## Stage D behaves identically

```
CD1=2  dd: read error: I/O error   0+0 records
R1=0   8+0 records in / 8+0 out
CD2=2  dd: read error: I/O error   0+0 records
R2=0   8+0 records in / 8+0 out

a3p D RETIRED busfree=1 sent=1 ss=41 bytes=1536
a3p D RETIRED busfree=2 sent=2 ss=41 bytes=1536

d_try 2  d_bytes 1536  d_sent 2  d_busfree 2  d_failed 2
d_quar 0  d_badphase 0  d_badstat 0  d_notowner 0
```

Byte for byte the same as the 68060 run: same residual, same `0x41`, same counters, no `a3091:`
line, no panic. The recovery is driver code and behaves as driver code should — the CPU is not a
variable in it. That is a second-platform confirmation nobody asked for and it was free.

## The load base moves, and that is worth its own line

```
mem[0] lower=07000020 upper=08000000
kernel: entry=07000000 tvaddr=07000000 tsize=000f65c8
Total     Unix  memory = 16773120
```

With the Mercury the kernel loaded at `0x08000000` and reported 33 550 336 bytes. With the A3640
it loads at **`0x07000000`** and reports 16 773 120. **The 32 MB region at `0x08000000` came with
the Mercury card**, and only the 16 MB region at `0x07000000` is the machine's own.

So every runtime address in this project's counter tables shifts down by `0x01000000` on this
configuration. `tools/status-facts.sh` computes them from a `0x08000000` base, which is correct
for the machine as it has been all year and wrong the moment the CPU card changes.

The magic word is what caught it. `a3p_magic` read `41335021` — `A3P!` — at `0710F6E4` on the
first try after subtracting a megabyte, and would have read nothing recognisable at the old
address. It is the fifth time in two days that reading the magic first mattered, and the first
time it confirmed a correct guess rather than rejecting a wrong one.

The two failed reads at the old addresses are in the serial log, denied by the kernel's own fault
handler and named by this port's own instrument:

```
WARNING: DBG krnxflt FAILEXIT w=2 va=810F6E4 rw=1 depth=1
WARNING: DBG krnxflt FAILEXIT w=2 va=810F7CC rw=1 depth=1
```

This also bears on the open RAM-beyond-16MB question
(`private/RAM-BEYOND-16MB-CODEX-TASK.md`): the two regions it describes are not both properties
of the machine. One of them is a property of the accelerator.
