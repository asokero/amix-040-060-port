# 040 `pstart` — Draft 1 (no-paging bring-up probe)

Produces `build/unix-040` from the stock `unix` kernel by neutering `pstart`'s
68030 MMU-enable so a 68040 can get past it.

## What it does
`prototypes/patch_pstart_040.py` patches 16 bytes at kernel offset `0xfd6`
(pstart+0x292), replacing:

    pmove %a0@,%srp / pflusha / pmove tc_on,%tc      (030, illegal on 040)

with:

    pflusha (040, f518) ; bra.w 0xfe6  (skip MMU-enable, jump to `jsr vstart`)

The MMU is left **disabled** — copyit already cleared TC, so the 040 runs flat
1:1, and the kernel (bound to a physical address, run 1:1) keeps executing.
pstart still builds all its tables/globals; we only skip turning paging on.

The `tc_on` R_68K_32 relocation at `0xfe2` is left untouched: the patch places
it inside the `bra.w`-skipped dead region, so unix_boot applies it into bytes
that never execute (no ELF/reloc surgery, no boot-time warning).

## Build
    python3 prototypes/patch_pstart_040.py
    # -> build/unix-040

## Test (fs-uae, 68040)
1. Copy `build/unix-040` to the AmigaDOS volume next to the kernel.
2. Boot it with the 040-aware loader:  `unix_boot unix-040`
   (keep the name distinct from `unix` to avoid loading the wrong file).

### Expected
- copyit hands off (040 movec path, already validated).
- pstart no longer traps at 0xfd6.
- Boot proceeds **with paging off** into `vstart` / `mlsetup` and crashes at the
  *next* 030-ism or the first place paging is genuinely required. Record where
  (fs-uae log `B-Trap`/`Illegal`, or the guru) — that is the next blocker.

## Not done yet (future drafts)
Real 040 paging needs `pstart` to build 040-format tables (4 KB, 7/7/6,
4-byte descriptors) **and** the binary-only HAT/VM layer
(`hat_pteload`/`hat_asload`/`vatopte`) converted to the same format — a
VM-wide change. This draft only proves how far AMIX boots flat on a 040.
