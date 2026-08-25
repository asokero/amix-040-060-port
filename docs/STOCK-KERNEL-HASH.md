# The staged stock kernel is a different 2.1c relink, and that is the expected case

`tools/verify-stock.sh` pins one sha256 for AMIX SVR4 2.1c `/stand/unix`:

```
expected  7d26cb6f04991be5776d9e5361259b20b413d97e3da33bf88e6f312e7be2ec23
ours      80a1204f4ec422f3c785fe646f3dc48be4fcb72c9c4b552018b6236be52aa098
```

Every kernel on this branch was therefore built with `AMIX_ALLOW_UNKNOWN_STOCK=1`. This document
says why that is not a warning being ignored.

## Why the hashes differ

**2.1c is a relink kit, not a shipped binary.** The `/stand/unix` on any 2.1c installation is that
machine's own link output, so two installations that are the same release still differ in bytes —
link order, padding, and the build stamp all move. A hash equality test asks "is this the same
*file*", when what the patchers actually require is "is this the same *layout*".

`verify-stock.sh` already says as much, and invites exactly this report:

> The reference is the `/stand/unix` of AMIX SVR4 2.1c as distributed. Whether every 2.1c
> installation carries this exact image is NOT established -- so a mismatch asks for a report
> rather than assuming the user is wrong.

## What was measured

Independently relinked 2.1c kernels **differ in bytes and agree in layout across 100% of the
patched surface** (measured 2026-08-18). Every offset this port hard-codes lands on the same
symbol in both.

The control for that comparison is **`fpu_setup` at `0x19b50`** — chosen because it
discriminates: retail 2.1 does *not* place it there, and an independently relinked 2.1c does.
Verified on the image this branch was built from:

```
$ m68k-linux-gnu-nm build/.../amix-2.1c/stand/unix | grep -w fpu_setup
00019b50 T fpu_setup
```

So the risk `verify-stock.sh` guards against — "the build works and the result is quietly
wrong" — is real for a *different release*, and does not arise for a *different relink of the
same release*.

## What is the operative gate on this tree

Not the hash. Two checks that read the image itself, and that a wrong-layout kernel could not
pass:

* **the patchers' own byte-level assertions.** Each `src/patch_*.py` asserts the exact bytes,
  opcode words and symbol values it expects at the site before it writes. A kernel whose layout
  had moved would fail these rather than be patched at the wrong bytes.
* **`relink-040.sh` printing `TOTAL complaints: 0`** from the relocation validator.

Both pass on this branch. That is the evidence the hash was standing in for.

## The ask

**Gate `verify-stock.sh` on a hash *set* of known-good 2.1c relinks rather than a single hash**,
keeping the hard refusal for anything outside the set. That preserves the guarantee that matters
(refuse a different release) without refusing a legitimate 2.1c installation, and it turns
`AMIX_ALLOW_UNKNOWN_STOCK=1` back into what it should be — an escape hatch, not the normal path.

`80a1204f4ec422f3c785fe646f3dc48be4fcb72c9c4b552018b6236be52aa098` is offered as the second
member of that set. If a layout control is wanted alongside the hashes, `fpu_setup == 0x19b50` is
the one this project has used.

## Related: the other CPU path is byte-identical, just not yet in record form

`ACCEPTANCE.md` §3 requires a `cputype`-gated change to leave the other CPU's path
byte-identical. For the ISSUE-10 cure that check has been run: the 030 line
(`relink-030-i10d.sh`) reads the same staged stock image, which is byte-identical before and
after (`80a1204f…` both times), builds `rc 0`, and links exactly one object — the
CPU-independent `i10dtrace030.o` — with none of the cure or fix objects in its link list. What
does not yet exist is that result written up in the form §10 asks for.
