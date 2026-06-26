# usrxmemflt040 -- 68040 COW-fault classification port (design)

**Goal:** make `do_reloc`'s user-mode write to libc.so.1's read-only GOT page fault as a COW
(`F_PROT`) fault instead of a demand (`F_INVAL`) fault, so `segvn_fault` copies-on-writes the
page and the relocation store lands.  This is THE blocker stopping the dynamic linker from
relocating its GOT (the linker then jsr's a raw GOT slot and `_exit(0)`s before init's `_start`).

## Root cause (confirmed)

`usrxmemflt` (0x5aede) chooses `as_fault(F_INVAL=0)` vs `as_fault(F_PROT=1)` purely from the
`ptest` MMUSR result (stored at `fp@(-20)`):

```
5af6e  MMUSR & 0x8000 (030 B, bus err)  -> SIGSEGV err 9
5af8c  MMUSR & 0x2000 (030 S, supv)     -> err 11
5afb2  MMUSR & 0x4400 (030 L|I)         -> SET:  F_INVAL demand path (5aff6, stackfault/grow,
                                                  as_fault type = fp@(-44) = 0)
                                           CLEAR: fall through to 5b040
5b040  MMUSR & 0x0800 (030 W, wr-prot)  -> SET:  continue to 5b050  (the COW path)
                                           CLEAR: 5b0f2 hardbus
5b050  (frame+72 SSW & 0x140)==0x100    -> uvatosde + modified bit -> as_fault type = #1 = F_PROT
                                           else: 5b0f2 hardbus
```

`ptest` (0x3a8) is the 030 `ptestr #1,(a0),7` + `pmove psr` sequence.  On the 68040 it is an
illegal F-line instruction, so `patch_pmmu_040.py` **stubs it to return a constant 0x400**
(030 bit10 = I = invalid).  Therefore the `& 0x4400` test at 5afb2 *always* matches -> every
fault takes the F_INVAL demand path.  The read-only GOT page is treated as "not present", gets
demand-re-read instead of COW'd, and the user store is silently lost (rexit GOT dump: all 40
slots raw).  030-golden generates `type=1 F_PROT rw=2` faults here; 040 generates ZERO.

(The earlier "-0x800 .rela.data" smoking gun was a red herring -- libc's LOAD segments are
`align 0x2000`, `p_offset==p_vaddr`, and .rela.data is in the offset-0 text segment, so the
file-offset arithmetic is exact; see memory `amix-040-init-userpage-pfn`.)

## Already in place

* **rw bit (5af14)** -- a69d3ea byte-patched it to read the 040 SSW at `frame+76` bit 8
  (1=read/0=write) instead of the 030 `frame+72` bit 6.  Stays.
* **wb040.s** -- after `usrxmemflt_orig` resolves the fault it `pflusha`es and re-issues the
  pending write-back store (the 68040 does not re-run a faulted write on `rte`).  Stays; it
  *composes* with this fix (ptest040 makes the page writable, wb040 lands the store).

## The fix -- two parts

### Part 1: `ptest040.s` (new) -- real 040 ptest, faithful 030-form result

Replace `ptest` via `--weaken-symbol ptest` (it is GLOBAL; `nm` confirm).  Both callers
(`usrxmemflt`, `krnxmemflt`) get a correct 030-form PSR, so nothing downstream changes.
The assembler (`m68k-cbm-sysv4-gcc`) does NOT know the 040 PMMU mnemonics, so emit them as
`.word` (same as wb040's `pflusha`).

Verified encodings (fs-uae `cpummu.cpp` mmu_op_real + assembler):
* `ptestr (%a0)` = `0xF568` (PTEST: `(op & 0x0FD8)==0x0548`; bit5=1 -> read; bits2-0 = An=0).
  fs-uae takes the function code from **DFC** (`super=dfc&4`, `data=(dfc&3)!=2`).
* `movec %mmusr,%d0` = `0x4E7A, 0x0805` (movec ctrl->Dn; ctrl reg MMUSR = 0x805, Dn=0).
* `movec %d0,%dfc` assembles natively (DFC = ctrl 0x001).
* 040 MMUSR bits (cpummu.h): R=bit0(0x001) resident, W=bit2(0x004) write-protected,
  B=bit11(0x800) bus error/invalid, M=bit4(0x010) modified.

Logic (return value in `%d0`, matching stock ptest's calling convention):

```
ptest:                        | weak override; arg = VA at sp@(4)
    moveq   &1,%d0
    movec   %d0,%dfc          | FC = 1 (user data); fs-uae reads DFC for ptest
    movec   %d0,%sfc          | harmless; in case of DFC/SFC ambiguity on real HW
    moveal  %sp@(4),%a0       | a0 = fault VA
    .word   0xf568            | ptestr (%a0)  -- walk current URP, fill MMUSR
    .word   0x4e7a,0x0805     | movec %mmusr,%d0
    | translate 040 MMUSR -> 030-form PSR
    moveq   &0,%d1
    btst    &0,%d0            | R (resident)?
    beqs    Lnp               |   R==0 -> not present
    btst    &2,%d0            | W (write-protected)?
    beqs    Lret              |   R==1 && W==0 -> present+writable -> 030 = 0 (no fault bits)
    movew   &0x0800,%d1       |   R==1 && W==1 -> 030 W (write-protect) -> COW path
    bras    Lret
Lnp:
    movew   &0x0400,%d1       | 030 I (invalid/not present) -> F_INVAL demand path
Lret:
    movel   %d1,%d0
    rts
```

Notes:
* not-present returns `0x400` (030 I) NOT `0x8000` (030 B) on purpose: F_INVAL demand-faults
  the page in; a real B would SIGSEGV.
* keep FC=1 for both callers (stock ptest hardcoded `#1`); during a user fault URP already
  points at the faulting proc, so ptestr tests exactly the page we care about.
* `ptest0` (0x3c0) stays NOP'd by patch_pmmu_040 (it returns 0 regardless; no caller depends
  on its result).

### Part 2: byte-patch 5b050 (in `patch_modelb.py`) -- the second SSW read

5b050 still reads `frame+72` (= the 040 *effective address*, garbage), so even after Part 1
puts us on the COW path the `(EA & 0x140)==0x100` test fails for our GOT VA and mis-routes to
5b0f2/hardbus.  Mirror a69d3ea: test the 040 SSW at `frame+76` bit 8, branch to 5b0f2 only on
a READ fault.

Original (24 bytes, 0x5b050..0x5b067), branch target 0x5b0f2:
```
20 6e 00 08              moveal %fp@(8),%a0
20 28 00 48              movel  %a0@(72),%d0
02 80 00 00 01 40        andil  #0x140,%d0
0c 80 00 00 01 00        cmpil  #0x100,%d0
66 00 00 8c              bnew   0x5b0f2
```
Replacement (same 24 bytes; nop pad):
```
20 6e 00 08              moveal %fp@(8),%a0
70 01                    moveq  #1,%d0
c0 28 00 4c              andb   %a0@(76),%d0     | SSW bit8 (1=read)
66 00 00 96              bnew   0x5b0f2          | read fault -> hardbus
4e 71 4e 71 4e 71 4e 71 4e 71   | 5x nop pad
```
(`bnew` disp = 0x5b0f2 - 0x5b05c = 0x96.)

## Build wiring (relink-040.sh)

* assemble `prototypes/ptest040.s` -> `build/ptest040.o`
* `--weaken-symbol ptest` on unix-stage1
* add `build/ptest040.o` to the `ld -r` line
* keep `patch_pmmu_040.py` (it still NOPs `ptest0` and patches the other PMMU sites); the
  weak `ptest` override means its 0x3ac stub is dead code (the strong ptest040 wins) -- verify
  the override resolves to ptest040 in the post-link symbol dump.
* add the 5b050 site to `patch_modelb.py` with a byte-verify of the original.

## Test / expected result

Boot `unix-040-dbg`, capture serial.  Expected: the rexit GOT dump now shows RELOCATED slots
(e.g. +0x58 = C101116E `_rtmalloc`, not raw 0001116E), the linker does NOT `_exit` early, and
init's `_start` (0x80000034 region) finally runs.  If it works, drop the rexit GOT/RAM probes.

## Risk / open points

* DFC-vs-SFC for the 040 ptest function code: fs-uae uses DFC (confirmed); we set both.
* If `ptest040` returns W for a page that segvn decides is a true protection violation
  (maxprot has no WRITE), `as_fault(F_PROT)` returns an error and usrxmemflt SIGSEGVs -- correct
  behaviour (same as 030).
* `ptest` is also called by `krnxmemflt` and possibly elsewhere; the 030-form result is faithful
  so those paths are unaffected (they previously got the bogus constant 0x400).
```
