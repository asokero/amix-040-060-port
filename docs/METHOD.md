# How this port was made

*A working method for changing a proprietary binary you cannot read, on hardware you can rarely
touch, with an AI assistant that is confidently wrong often enough to matter.*

---

## The problem shape

Amiga UNIX is Commodore's 1991 System V Release 4 for the Amiga 3000. It runs on a 68030 and
nothing else. The sources are lost to the public; what exists is the shipped kernel binary, its
headers, and a 3B2 SVR4 source tree that shares ancestry but not this machine's code.

Porting it to a 68040 and a 68060 therefore meant editing a binary: 69 replacement routines linked
over the original with weakened symbols, 43 byte-patch scripts for what a symbol override cannot
express, and no compiler ever seeing most of the kernel it modifies.

Four properties made this different from ordinary systems work, and the method is a response to
all four.

**There is no test suite and no oracle.** Nothing says whether a change is correct. The kernel
either boots and behaves, or it does something subtle three days later.

**The feedback loop is expensive and rationed.** The hardware is one Amiga 3000 that has to be
powered on by a human, sometimes needs a CPU card swapped, and is available for an hour at a time.
A hardware session that discovers "we forgot to measure X" costs a day.

**The emulator lies in specific, discoverable ways.** Amiberry boots the kernel and runs the
userland, but it raises no enabled IEEE floating-point exceptions and never sets the 68040's WB1S
write-back valid bit. Two entire code paths cannot execute there. A green emulator run is
necessary and not sufficient, and knowing *exactly* where it stops being evidence took
measurement.

**The assistant is fast, tireless, and wrong in a particular way.** Not randomly wrong — wrong by
producing a plausible mechanism and then treating it as a measurement. Every serious error in this
project has that shape.

---

## The method

Nine practices. Each one exists because something specific went wrong.

### 1. Build the instrument before the fix

Every unit in this port carries counters in kernel `.data`: how many times each branch ran, what
it classified, what it last saw. Nine such blocks exist. They are not debugging leftovers — they
are the acceptance criterion, and they are written *before* the change they measure.

The reason is blunt: on this system, "the test passed" and "the code never ran" look identical.

### 2. Every counter block starts with a magic word

`"FPC!"`, `"WBF!"`, `"FP60"`, `"I61!"`. Counter addresses are `load_base + textsize + nm offset`
and therefore change on every build. A stale address does not fail — it returns a plausible number
from whatever now lives there.

So the first word of every block is a constant, and no reading from a block is believed until its
magic reads correctly. This has caught a wrong-address read more than once, most memorably when a
stale emulator instance was answering telnet and the "kernel" being measured was not the one that
had just booted.

### 3. Pre-register the expectation, in writing, before the run

Before every hardware session: what each number should read, and — the part that matters — **what
each possible outcome would mean**, including the outcomes that say "the fix did not run" rather
than "the fix did not work".

This is cheap and it repeatedly separated two things that produce identical logs. It also does
something less comfortable: it makes your wrong predictions permanent. Three are recorded in this
repository. Each was more useful than the ones that were right, because a surprise that was
written down in advance is a finding, and a surprise that was not is a story.

### 4. "Did it run?" is a separate question from "did it work?"

Every unit has an entry counter. A fix that produces the right answer while its counter reads zero
has not been validated — something else produced that answer.

The inverse matters just as much. When the emulator reported six of six floating-point classes
failing, the counters said the classes had never been exercised at all: the emulator raises no
enabled FP exceptions. Six unexercised cases and six failures look the same in the output and are
opposite in meaning.

### 5. Prefer invariants that span two counters

A single counter tells you a number. Two counters with a fixed relationship tell you when the
world stopped making sense.

`f60_entry_n == f60_arith_n + f60_bsun_n + ...` — one package entry produces exactly one call-out
exit. That invariant found a defect while four of six tests were green (§ISSUE-44 below). No
passing test would have found it, because the tests that failed were failing for the *right*
reason and the ones that passed had nothing to say.

### 6. Make the build system byte-exactly reproducible, then use it as a regression test

Rebuilding a given tree twice produces images differing only in a 16-byte build-id stamp. That
turned out to be worth far more than tidiness: it is the acceptance test for every infrastructural
change. The entire release refactoring — moving 495 references, rewriting git history, replacing
59 hard-coded paths — was verified by rebuilding and confirming **exactly one byte** differed.

A refactor that changes no code byte is not an opinion about a refactor.

### 7. The platform is part of every claim

Not "the FP exception handling passes" but "passes on 68060 silicon; unexercised on the emulator
because it raises no enabled IEEE exceptions". The canonical status document has four columns —
040 emulator, 040 hardware, 060 emulator, 060 hardware — and the interesting information is where
a row is green in one and blank in another.

Two emulator/silicon divergences were found by measurement, and both would have been invisible
without it: the write-back replay pointer reads one byte further along under Amiberry than on real
68040 silicon (the post-increment has been applied on one and not the other), and the 68060's
null-versus-idle FP frame ratio is 8048:17 on hardware against 9229:855 emulated. Neither changes
a verdict; both change what a number means.

### 8. Record refuted conclusions, prominently

The canonical status document has a section titled *"Conclusions that have been refuted — do not
restart from these"*. Seven entries. It includes claims this project believed for weeks, wrote
down, built on, and then disproved.

Deleting them would be tidier and much worse: the next reader would re-derive them. A reader who
cannot see the wrong turns cannot judge the right ones.

### 9. Use a second opinion as a distinct role, not as a rubber stamp

Three static-analysis audits by a different model, each answering a written question about a
contract — *what does this flag mean, who owns it, what does the architecture require* — with file
and line citations, pinned to a specific commit and binary hash.

Two of the three **overturned conclusions this project had already committed**. That is the value:
not more code, but an independent reading of the same sources by something that did not write the
first version and has no attachment to it.

---

## Four cases, with numbers

### ISSUE-43 — a one-byte offset, two failed fixes, and an audit

**Symptom.** On the 68060, five of six enabled IEEE floating-point exception classes returned
Motorola's exact post-state. Divide-by-zero returned the FPU's reset state: the process lost
`fp0-fp7` across the signal.

**Two fixes that failed.** The first saved the registers and set a flag so the restore path would
reload them — and turned five-of-six into **zero**-of-six on hardware, because the flag meant the
opposite of what was assumed: in `fpu_save`, "set" means *skip saving*. Reverted within the hour.
The second added a guard that classified a zero source operand as an empty frame — the same
misreading, now in our own code.

**The audit.** An external static analysis established, from the AMIX headers, NetBSD's m68k
support and Motorola's package, that the 68060 frame discriminator is at **`frame + 2`**, not at
byte zero. Byte zero belongs to the extended source operand and carries its exponent.

Which explains everything at once: the measured words `0x7fff`, `0x4000`, `0x0000` were the
exponents of the test's own operands — `-Inf`, `+2`, `0`. Divide-by-zero is exactly the class
whose operand is zero, so byte zero read as zero and stock code concluded "no live FP state". The
five that passed had passed by accident.

**Result:** six of six bit-exact on silicon, including every FPIAR.

**The lesson is not about the 68060.** Both failed fixes came from inferring meaning from the
shape of code rather than reading the contract. Both were readable in sources that were sitting
on the disk.

### ISSUE-44 — an invariant found what four green tests could not

The day after ISSUE-43's fix landed, the first hardware boot showed five of six classes correct
and one wrong in a single bit — the FPSR NaN condition bit.

The counters named the cause without a hypothesis being needed:

```
f60_entry_n +1     one package entry
f60_arith_n +1     the class call-out ran
f60_bsun_n  +1     ... and then the BSUN body ran too
f60_real_n  +2     against entry +1 -- the invariant broken by exactly the fall-through
```

The previous day's commit had removed a guard whose block *ended in the exit's own jump*. Every
arithmetic call-out was falling through into the BSUN handler, which clears the NaN condition bit
— correct for a real BSUN, wrong for everyone else. Nothing crashed, because the BSUN prelude's
stack arithmetic happens to balance.

Four of six classes were green. The only thing that said otherwise was the ratio between two
counters that nobody expected to move.

### ISSUE-42 — a pre-registered prediction that was wrong, and the defect it exposed

A denied 68040 write-back was being swallowed: half of a misaligned store landed, the denied half
was discarded, and the process continued believing the store had completed. A silently torn store.

The fix propagates the denial as a signal. Before running it, the expected values were written
down — including that `si_addr` would be page-aligned, the first byte of the protected page.

It came back **one byte higher**. The replay loop is `moves.b %d1,%a3@+`, and the post-increment
has already been applied when the trap is taken, so the landing pad's register is not the failing
address. The signal would have reported an address that was wrong — *on the right page*, where no
test would ever have caught it.

The fix: take the address from the CPU's own fault-address field, and keep the register value only
as a **counted** fallback. Which is why, when real silicon later turned out to behave the opposite
way — no post-increment applied — the address was correct on both platforms, and the counter
proved the fallback was never used.

The robustness came from distrusting the register, not from predicting the CPU correctly. The
prediction was wrong; the practice of writing it down first is what produced the better design.

### The clock that was wrong for months

Every performance document said the reference 68040 ran at 33 MHz. It runs at **35** — a 70 MHz
oscillator at half clock, a fact known only to the person who fits the oscillators.

Two conclusions moved. One was deleted: a "6.5 % memory penalty" for a card with no local RAM,
which had been measured an hour earlier and explained with a plausible and entirely real
mechanism. At the correct clock the difference is 0.8 %, i.e. nothing that benchmark can see. The
mechanism was real, the number did not exist.

The other conclusion improved. A recorded finding — *"the 68060 is +102 %, almost exactly the
clock ratio, so scalar dispatch leaves nothing to explain"* — became: the clock ratio is 1.886,
the measured ratio 2.019, so there is a **+7.1 % surplus per clock**, and superscalar dispatch was
separately measured as *enabled*. A superscalar 68060 only 7 % faster per clock than a 68040 is a
low figure that wants an explanation — and the same document already records two disabled CACR
bits as the candidates.

An input correction from the human deleted one finding and created a better one. Both were worth
having.

---

## What the AI did, and what it did not

This section exists because "AI-assisted" is a claim readers cannot check, and the repository's
own history contradicts the strong version of it.

**What the assistant did.** Wrote the override units and the patch scripts. Read disassembly at a
volume no human would sustain. Built the instruments. Ran the emulator cycles. Drove the hardware
sessions over telnet, transferred binaries, read counters, wrote the acceptance records and this
document.

**What the human did.** Owned the hardware — every boot, every card swap, every power cut. Set
priorities and, more than once, declined work the assistant thought was interesting. Supplied
facts the assistant could not obtain: that the accelerator's oscillator is halved, that a
particular test needs the RTG kernel, that the memory work was not worth doing. Caught errors.

**What a second model did.** Overturned two conclusions this one had already committed, including
one where the assistant had written the fix, tested it, and recorded it as correct.

**What the discipline did.** Every serious error in this project shares one shape: a plausible
mechanism, treated as a measurement. The flag that meant the opposite. The guard built on the
wrong byte offset. The memory penalty that was a clock error. The `si_addr` that was off by one.
None was caught by being careful in the moment — being careful is what produced them. They were
caught by counters that said "this branch never ran", by invariants that said "these two numbers
cannot both be true", and by expectations written down before the run.

The honest claim is narrow and, I think, more interesting than the broad one: **AI-assisted work
on a 34-year-old proprietary kernel is feasible when it is held to a measurement discipline, and
most of the value comes from the discipline rather than from the generation.** Publishing the
failures is what makes that claim checkable.

---

## If you are starting something similar

* **Write the instrument first.** If you cannot measure whether your change ran, you are not
  debugging, you are guessing with extra steps.
* **Put a magic word at the front of every block of numbers you will read later.**
* **Write down what you expect before you run it**, including what each wrong outcome would mean.
  It costs two minutes and it is the difference between a finding and a story.
* **Prefer invariants over thresholds.** "These two counters must be equal" survives refactoring
  and finds things nobody was looking for.
* **Make the build byte-reproducible early.** It becomes the regression test for everything you do
  to the build system afterwards.
* **Say which platform every claim came from.** Emulators are not lying to you on purpose; they
  just do not implement the part you are about to depend on.
* **Keep your refuted conclusions.** They are the cheapest thing you own and the most expensive to
  rediscover.
* **Get a second reading of anything you are certain about.** Certainty is where the audits paid
  for themselves.

---

*Project: 628 commits over eight weeks, 61 issue records, 69 override units, 43 byte-patch
scripts, 53 purpose-built test programs, 22 hardware acceptance documents, 129 contract and audit
documents, 9 counter blocks. One Amiga 3000, two CPU cards, and a great deal of writing things
down before finding out.*
