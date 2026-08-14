# Debugger user-text cache-publication patch specification

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/DEBUGGER-TEXT-PUBLICATION-PATCH-SPEC.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** `src/dbgpublish040.s` and
> `src/patch_dbgpublish.py` implement this three-relocation unit. Real 68040
> copyback acceptance observed four successful POKETEXT publications and both
> procfs publications with the corresponding counters balanced; later
> hardware batteries retain `ptracepoke` as a regression test.

## Scope

This is the implementation specification for the two active debugger writers
identified by `USER-EXECUTABLE-CACHE-PUBLICATION-CENSUS.md`:

1. ptrace `POKETEXT`/`POKEDATA` through `procxmt -> suword`;
2. `/proc/<pid>` process-memory writes through `prusrio -> uiomove`.

It specifies the small relocation-retargeted wrapper unit used by the current
68040/68060 relink. The specification itself does not modify the kernel.

## Pinned input

```text
kernel repository HEAD       a7007ed
build/unix-040 build id      68040-260731-02
build/unix-040 SHA-256       572d8a0b58215d11bbed96dafb8b6aa56091486bd09faa4b9fc4e6ea6feffeca
.text SHA-256                4d048182366f1697b1bdd26be222c71e5946e549cbc7ab9ff8a3f40a8002ccc2
```

Canonical addresses are ELF `.text` offsets. The image remains `ET_REL`, so
the relocation target, not the zero placeholder in the JSR operand, is the
authoritative call identity.

## Verdict

Implement one atomic unit named **DBG-TEXT-PUBLISH**:

- add two private wrappers in one new 040 assembly object;
- retarget exactly three existing `R_68K_32` call relocations to them;
- after every target-write attempt, execute `cpusha bc` (`0xf4f8`) because an
  error return does not prove that no prefix or crossing bytes changed;
- retain all original return values and error paths.

Whole-cache publication is the correct first implementation. These are
debugger/control paths, not ordinary I/O paths. It avoids a new target-AS
table walker, covers physical aliases and cross-process I-cache lines, and is
already hardware-proven by the proc-1 icode fix. A line-range optimization is
optional only after the acceptance tests pass.

## Current call sites

| Owner | Call opcode | Relocation offset | Current target | New target |
|---|---:|---:|---|---|
| ptrace writable path | `0x47eb6` | `0x47eb8` | `suword @0x4ae` | `dbg_suword_publish` |
| ptrace temporary-write path | `0x47ee8` | `0x47eea` | `suword @0x4ae` | `dbg_suword_publish` |
| procfs page chunk | `0x64624` | `0x64626` | `uiomove @0x43abc` | `dbg_uiomove_publish` |

All three opcodes are `4e b9 00 00 00 00`; the four zero operand bytes are
filled by the loader from the relocation. A patch that writes a raw absolute
operand but leaves the relocation unchanged is invalid: the loader will
overwrite it.

## Ptrace contract

`procxmt 0x47d78` dispatches requests 4 and 5 to the common store block at
`0x47e6e`. The two paths are:

```text
already writable:
    suword(target_va=d3, ipc.ip_data) @0x47eb6

temporarily writable:
    as_setprot(old|WRITE)             @0x47ed0
    suword(target_va=d3, ipc.ip_data) @0x47ee8
    as_setprot(old)                   @0x47efc
```

Both calls feed their result into `d2`; nonzero reaches the normal ptrace
error exit. POKETEXT and POKEDATA share the block and the request register is
reused before the common success tail. Publishing both is therefore the
smallest robust patch and is harmless: four-byte debugger data writes are
rare, and the cache operation changes no data.

Wrapper ABI:

```text
dbg_suword_publish(addr, value):
    ret = suword(addr, value)
    cpusha bc
    dbg_ptrace_publish++
    return ret unchanged
```

Do not move publication to the common success branch unless displaced-flow
and request-lifetime proof is added. Relocation retargeting preserves the
entire stock control flow and handles both protection branches symmetrically.

## Procfs contract

`prwrite 0x64d62` calls:

```text
prusrio(target_proc, UIO_WRITE=1, uio) @0x64db4
```

For each at-most-4-KiB target chunk, `prusrio` obtains a direct kernel alias
in `d2`, then calls:

```text
uiomove(alias=d2, len=fp-44, rw=fp+12, uio=fp+16) @0x64624
```

Mapout occurs only afterward at `0x6464c` or `0x6466e`. Retargeting this one
relocation therefore places publication after bytes are written and while
the mapping/hold contract is still live.

Wrapper ABI:

```text
dbg_uiomove_publish(kaddr, len, rw, uio):
    ret = uiomove(kaddr, len, rw, uio)
    if rw == UIO_WRITE:
        cpusha bc
        dbg_procfs_publish++
    return ret unchanged
```

`UIO_READ=0`, `UIO_WRITE=1` is confirmed by installed `sys/uio.h` and by
`prwrite` pushing literal 1. The direction gate is mandatory: the same
`prusrio` body serves reads, and a target-to-debugger read creates no user
instruction bytes.

Publishing every successful procfs write, rather than trying to classify the
target segment as executable, is intentional. The 040 PTE has no execute
bit, AMIX data mappings are commonly RWX, and procfs writes are bounded
control operations. An execute-intent query would add uncertainty without a
meaningful performance win.

## Assembly shape

The object should use the same SVR4 ABI style as the current overrides:

```asm
        .text
        .globl  dbg_suword_publish
dbg_suword_publish:
        linkw   %fp,&0
        movel   %fp@(12),%sp@-
        movel   %fp@(8),%sp@-
        jsr     suword
        addqw   &8,%sp
        .word   0xf4f8             | cpusha bc
        addql   &1,dbg_ptrace_publish
        moveal  %d0,%a0
        unlk    %fp
        rts

        .globl  dbg_uiomove_publish
dbg_uiomove_publish:
        linkw   %fp,&0
        movel   %fp@(20),%sp@-
        movel   %fp@(16),%sp@-
        movel   %fp@(12),%sp@-
        movel   %fp@(8),%sp@-
        jsr     uiomove
        lea     %sp@(16),%sp
        cmpil   &1,%fp@(16)        | UIO_WRITE
        bnew    Ldu_out
        .word   0xf4f8             | cpusha bc
        addql   &1,dbg_procfs_publish
Ldu_out:
        moveal  %d0,%a0
        unlk    %fp
        rts
```

The counters belong in aligned `.data`. An optional `dbg_publish_on` gate can
support an A/B, but the default must be enabled and the disabled image must
be clearly stamped. Neither wrapper may call a range walker or fault while
holding a procfs page: the whole-cache opcode is non-faulting and preserves
that property.

## Relocation-retarget patch

Follow the proven mechanism in `patch_config_cachefix.py`:

1. parse ELF section, symbol, and relocation tables as big-endian ELF32;
2. locate new wrapper symbols by exact name;
3. for each row below, assert `R_68K_32`, JSR opcode `0x4eb9`, current target
   name and value;
4. replace only the symbol index in `r_info`;
5. accept an already-retargeted row as idempotent;
6. abort if any one of the three rows mismatches; the group is atomic.

Old-byte/relocation assertions:

| Reloc offset | Opcode address | Expected target |
|---:|---:|---|
| `0x47eb8` | `0x47eb6` = `4eb9` | `suword`, `st_value=0x4ae` |
| `0x47eea` | `0x47ee8` = `4eb9` | `suword`, `st_value=0x4ae` |
| `0x64626` | `0x64624` = `4eb9` | `uiomove`, `st_value=0x43abc` |

After linking and patching, require
`prototypes/check_relink_relocs.py build/unix-040` to report zero complaints.

## Ordering and error rules

1. Publish after every ptrace store attempt and every procfs `UIO_WRITE`
   attempt. `suword` crossing a boundary or `uiomove` returning after a
   partial copy can have changed bytes despite a nonzero result.
2. Publish before procfs mapout/softunlock and before the stopped process can
   resume.
3. Preserve the original return in `d0` and the C-compatible mirror in `a0`.
4. Do not turn a failed partial `uiomove` into success. Preserve its error,
   but still publish any prefix it may have written.
5. Do not use `cinva` alone. Under copyback it would discard the new target
   bytes. `cpusha bc` pushes dirty D-cache data and invalidates stale
   instruction lines.

## Acceptance

### Static

- exactly two ptrace `suword` relocations and exactly one procfs `uiomove`
  relocation target the wrappers;
- all other `suword` and `uiomove` call sites remain stock;
- unresolved-symbol and relocation checks are clean;
- counters are aligned and default to zero.

### Runtime

1. Real 68040 copyback: use ptrace POKETEXT to insert a breakpoint into a
   repeatedly executed text line, resume and hit it, restore the original
   word, resume and execute the original instruction. Repeat across line and
   page boundaries where ptrace permits.
2. Real 68040 copyback: perform the equivalent cycle through GDB's
   `/proc/<pid>` writer; require `dbg_procfs_publish` to advance.
3. Verify failed ptrace/procfs writes retain their original error and still
   increment the applicable publication counter.
4. Verify POKEDATA still succeeds and increments the ptrace counter; this is
   the deliberate bounded over-publication.
5. Run the same functional cycles in emulated 040 and 060 modes, while
   retaining real 060 cache acceptance as a later hardware milestone.
6. Re-run `hat_dup_cow` 1/32/256 and the normal copyback smoke suite; debugger
   publication must not affect ordinary copyout or I/O counters.

## Optional later optimization

Only after acceptance, replace whole-cache publication with a common
physical-line helper. The helper must translate the target process's VA via
`uvatopte040`, split at every 4-KiB page, align to 16-byte cache lines, push
dirty D lines, and invalidate corresponding I lines. The procfs path may use
its already-known direct physical alias, but ptrace still requires a target-AS
walk. This optimization has more failure modes than its expected debugger
performance benefit and is not part of the first patch.

## Confidence

High confidence in the call-site ownership, direction, relocation anchors,
ordering, and whole-cache mechanism. Runtime acceptance is still required
because the current hardware suite has not exercised debugger text mutation
under copyback.
