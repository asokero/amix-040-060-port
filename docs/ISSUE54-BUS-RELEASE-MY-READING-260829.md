# My reading of the WD bus release, from NetBSD's `sbic.c` — written before the task was sent

Recorded **before** `private/A3091-BUS-RELEASE-CODEX-TASK.md` was written, and the task
deliberately does not contain any of it, so the two answers can be compared rather than one
confirming the other. If they disagree, that is the useful outcome.

Source: `sys/arch/amiga/dev/sbic.c` and `sbicreg.h`, pinned NetBSD 10.1.

## The answer is not "Abort or Disconnect". It is both, in order, with two guards.

`sbicabort()`, on a chip that is still selected:

1. **Drain the data buffer first.** While `ASR & DBR`: read the data register; if `DBR` is
   still set afterwards, the buffer wanted the other direction, so *write* the data register
   instead. Loop until `DBR` clears. NetBSD's own comment says it does not know which direction
   is needed — it tries a read and infers from whether `DBR` cleared.
2. Wait for `CIP` to clear.
3. Issue **`ABORT` = 0x01**.
4. Wait for `CIP` to clear again.
5. **Check `ASR & (BSY|LCI)`.** If either is set the abort did not take, and NetBSD escalates to
   a full chip reset and gives up on a clean release.
6. Issue **`DISC` = 0x04**.
7. Poll until `CSR` reads `DISC` 0x41, `DISC_1` 0x85, or `CMD_INVALID` 0x40.

Values, from `sbicreg.h`: `CMD_RESET` 0x00, `CMD_ABORT` 0x01, `CMD_DISC` 0x04,
`CMD_SEL_ATN_XFER` 0x08. `ASR`: `INT` 0x80, `LCI` 0x40, `BSY` 0x20, `CIP` 0x10, `DBR` 0x01.
`a3091.c` already defines `CIP (1<<4)` and `DBR (1<<0)` identically, so the register model
carries over unchanged; `COM` is 0x18, `AS` is 0x1F, `DR` is 0x19.

## Two things I would flag about porting it

**It is built out of spin loops, and we refused those on purpose.** `WAIT_CIP` and `SBIC_WAIT`
both busy-wait on the chip. The classification instrument deliberately does not `cipwait`,
because a spin loop in an interrupt handler on a machine that is already in trouble is how a
diagnostic becomes the hang it was written to explain. A bus release has more claim to waiting
than a diagnostic does — it has to finish — but the same hazard applies and the bound has to be
explicit rather than `while (1)`.

**And I think the obvious fix dies one interrupt later.** This is the part I am least sure of
and the reason the task exists.

`DISC` completes by producing a disconnect interrupt. `itab[0x85] = 3`, and:

```
             in0  in1  in2  in3  in4  in5  in6  in7  in8
  IDLE         1    1    1    1    3    1    1    1    1
  STARTING     5    1    6    7    2    8    1    9    0
```

`atab[IDLE][3]` is **1** — `badhardware()`, `DEAD`. So if the fix is "action 5's body", which
ends at `istate = IDLE; startany()`, then the `0x85` that the release itself provokes arrives at
`IDLE` and kills the driver anyway, unless `startany()` happened to start another request first
and moved the state to `STARTING`, where input 3 is action 7 and handled.

That would make the fix depend on whether the queue was empty — which is not a property anyone
should be relying on.

**The morning's capture is consistent with this.** Its second line is `ss=85 istate=3`: a
`DISC_1` did arrive, on its own, after the mismatch. The target released the bus without being
asked. That is evidence the release may be less of a problem than the *state the driver is in
when the disconnect interrupt lands*.

So my reading is: the bus release is `ABORT` then `DISC`, and the harder half of the problem is
not issuing them but surviving the interrupt they cause.
