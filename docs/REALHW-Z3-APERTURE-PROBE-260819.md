# Probing a real Zorro III aperture: the kernel builds the right mapping, the bus does not answer

**Machine:** Amiga 3000, Mercury 68060 @ 66 MHz, **Piccolo RAM board jumpered into Zorro III**
(`0893:05 @ 0x40000000`, 16 MB) with the VA2000 in Zorro II at the same time.
**Image:** `68060-260819-13`
**Date:** 2026-08-19
**Why:** the firmware swap on the VA2000 would open three unknowns at once — the kernel mapping
mechanism, the Zorro III address space, and the card's own Zorro III firmware. This machine
already carries a Zorro III aperture, so two of the three can be settled first.

`test-tools/z3probe.c` maps a physical address through `/dev/mem` from userspace. It refuses to
report anything until it has proved itself: it maps an address whose contents can be obtained by
an independent path (`lseek`+`read` on the same device) and requires the two to agree.

## Result 1 — ISSUE-46 is fixed, proven on hardware

```
Z3 selftest phys 08000000: lseek=46fc2700 mmap=46fc2700  AGREE
```

Before the fix the same self-test read `2f004eb9`, the longword the image holds one page higher.
Both paths now read `46fc 2700`, the kernel's first instruction. `mmmmap` truncates.

## Result 2 — the kernel builds a correct Zorro III PTE

The probe mapped physical `0x40000000` at `c1033000` and touched it. From the debug kernel's
serial console:

```
WARNING: DBG hardbus pid=283 addr=C1033000 pte=40000049 ret=0 upc=80000B74 uva=48478000 n=800
```

`pte=40000049` decodes as **pfn `0x40000`** — physical `0x40000000`, exactly what was asked for —
with status `0x49`: resident, referenced, `CM=0x40` NCS. So the whole producer chain works for a
Zorro III address: `mmmmap` → `segdev` → `hat_devload` → `hat_pteload` → `Lcm_sel`.

This confirms on silicon what the static audit predicted: **there is no high-PFN ceiling** in that
chain. It is the first time a Zorro III page frame has been mapped correctly on this machine.

## Result 3 — the access itself bus-errors

`hardbus` is the port's bus-error handler, and `n=0x800` is 2048 occurrences on that one address.
The mapping is right; the **cycle is not terminated by the Zorro III bus**.

Why is not established, and the candidates are not equal:

* **Most likely: the card has not been initialised.** The same Piccolo in the same slot in the same
  machine works in Zorro III under AmigaOS, where its own driver brings the board up. Nothing does
  that under AMIX — its AMIX driver cannot even open the board in Zorro III mode, which is the
  original defect this whole track exists to fix.
* Less likely, but not excluded: A3000 Zorro III bus behaviour for an aperture nobody has enabled.

So this is **not** evidence that Zorro III is unreachable on this machine. It is evidence that a
Zorro III aperture belonging to an uninitialised card does not answer — which is unsurprising, and
which leaves the kernel side looking good rather than bad.

## Result 4 — a new defect: a user-mode bus error retries forever

`ret=0` and a climbing count mean `hardbus` treats the fault as handled and the instruction is
restarted. The process burned CPU indefinitely (`18%`, `0:07` and rising), never returned, and
**never received a signal** — the probe's `SIGBUS` and `SIGSEGV` handlers were both armed and
neither fired. The machine stayed responsive throughout and `kill -9` worked, so it is a normal
fault-retry loop in user context, not a stalled bus cycle.

The correct behaviour for an unresolvable bus error on a user access is to signal the process.
Recorded as **ISSUE-47**.

It matters beyond Zorro III: any user mapping of a non-responding physical address hangs the
process forever instead of failing.

## What the instrument earned

Three separate things went wrong in a way that would have produced a confident wrong answer, and
each was caught by a property built in on purpose rather than by luck:

1. the self-check against an independent path caught ISSUE-46, which would otherwise have made
   every number below it wrong by one page;
2. unbuffered output meant the line naming the failing access survived the failing access — the
   first version buffered, died, and left an empty file;
3. the cache-class census could be sampled *during* the loop and showed `cmf_ncs_n` frozen, which
   ruled out "faulting and re-installing the PTE forever" before the serial line named the real
   mechanism.

## Where this leaves the firmware swap

Two of the three unknowns are now closed. The kernel maps a Zorro III page frame correctly, and
the address space is reachable in the sense that the CPU issues the cycle to it. What remains is
whether a card that has been **initialised** answers — and the VA2000 with Zorro III firmware
would be initialised by its own driver, which is the case the swap is for.
