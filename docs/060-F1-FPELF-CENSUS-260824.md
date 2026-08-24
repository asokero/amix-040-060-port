# The FP-required-ELF gate, and the userland it is supposed to gate

`getelfhead` refuses to exec a binary that claims to require hardware floating point when
`fpu_present` is zero. On a 68LC060 that is either the difference between a system that installs
and one that cannot run its own tools, or a branch that never executes. Which one it is depends
on a single bit that either is or is not set in the binaries we actually have, and that is
answerable without a build, without hardware, and without an opinion.

## What the kernel actually tests

Decoded from the pinned image at `getelfhead+0x76` (the census records it by the address of its
`fpu_present` reference, `0x000b859c`; the function begins at `0x000b851a`):

```text
btst  #0,ehdr+39      e_flags bit 0
beq   +0xe            not set -> nothing to check, carry on
tstl  fpu_present
beq   getelfhead+0xc2 set, and no FPU -> the error exit, which returns ENOEXEC (8)
```

Byte 39 is the low byte of `e_flags` in a 32-bit big-endian ELF header. So the whole policy is
one bit, and the question is whether the AMIX toolchain ever sets it.

## The census

`tools/fpelf-census.py` counts headers rather than instructions, which is the thing this gate
inspects. Run 2026-08-24 against the staged AMIX 2.1 `/usr` tree held on this machine:

```text
m68k ELF objects examined: 262
   ET_REL   123
   ET_EXEC  130
   ET_DYN     9
distinct e_flags values seen:
   0x00000000  262 file(s)
FP-REQUIRED (e_flags bit 0 set): 0
```

Widened to every m68k ELF file on this machine — the staged userland, the whole port build tree,
and everything the cross toolchain has ever emitted here — **4,194 objects, and `e_flags` is
zero in all of them.** Among the 262 are `df`, which the soft-FPU survey names as one of the two
install-critical FP-dependent programs, and `libc.so.1`, which carries the six `fmovecr` that
make `printf %f` floating point at all. Neither is marked.

## What follows

**The gate has no known trigger in this userland, so nothing about it changes at F1-M1.** The
FP-ELF policy question (whether `getelfhead` should keep refusing) stays where the plan put it:
deferred, and settled by measurement rather than by argument when it is taken up.

The interesting consequence is the opposite of the one that was feared. A binary full of
floating point that is *not* marked is not refused at exec — it runs until it traps, one
instruction at a time. So on a part with no FPU the exec gate protects nothing, and the whole
question moves to what happens at vector 11. That is a different front, and it starts with a
runtime trap census.

## What this does not establish

* **The tree is partial.** It holds `/usr` only: no `/bin`, no `/sbin`, and therefore no `sh`,
  `awk`, `ls`, `init` or `pkgadd` — several of which are exactly the install-critical names the
  question is about. "Zero FP-required binaries" is measured over 262 files, not over an
  installed system.
* Before anyone leans on this, run the same script against a **complete installed image**. It
  needs no build and no hardware; it needs the tree.
* Nothing here says a binary does not *use* floating point. It says the binary does not
  *announce* that it needs it, which is a different claim and a weaker one.
