# `src/` — the port itself

Everything that changes the kernel lives here. Two mechanisms, and which one a change uses is
decided by how much of the stock routine survives.

*(Until 2026-08-14 this file still described the directory as "Prototypes" and documented
`copyit.s`, which is a loader file and moved to the `amix-unix-boot` repository long before that.
If you are looking for the loader, it is not here.)*

## 1. Override units — 69 × `.s`

A whole replacement routine, assembled and linked in with `m68k-cbm-sysv4-ld -r`. The stock symbol
is weakened with `objcopy --weaken-symbol` so ours becomes the strong definition; where the
override still needs the original body, `--add-symbol NAME_orig=.text:0xADDR` exposes it at its
measured address and the unit tail-jumps there.

    hat040.s  kvm040.s  pstart040.s        MMU, page tables, bootstrap paging
    wb040.s                                68040 write-back replay (ISSUE-11, -22, -42)
    fpu060.s  fpsp060_glue.s  fpsp_glue040.s   FP context and the Motorola packages
    isp61_060.s  lmul060.s                 68060 unimplemented-integer emulation
    runtime040.s  config040.s  dma_cache040.s  resume, cache handoff, DMA coherence

Rules that are not optional:

* **every linked override section ends with `.balign 4`** (68 of the 69 files; the exception is
  `fpsp060_head.s`, which is *concatenated* rather than linked and has to be exactly 128 bytes).
  A misaligned `.data` total shifts the whole kernel `.bss` at runtime, and the SDMAC DMA engine
  has no `A[1:0]` — the symptom is a root mount that fails, nowhere near the cause;
* **`ld -r` runs last**, after every byte patch, or a later relink supersedes the retarget;
* CPU-specific code gates on `cputype` (40 or 60, poked in by the loader) with a memory-immediate
  compare that touches no register.

`*_dbg.s`, `*_probe.s`, `kvecprobe040.s`, `serdbg*.s` are instruments, not fixes: they exist to
make a claim falsifiable and are built into the debug overlays.

## 2. Byte patches — 43 × `patch_*.py`

For changes too small or too scattered for a whole routine: a shift count, a page-size constant, a
relocation retargeted to a different symbol. Each script **asserts the old bytes before writing the
new ones** and aborts if they are not there, because these address the kernel by hard-coded offsets
and a moved target would otherwise be patched silently and wrongly.

Since 2026-08-14 an abort actually stops the build — see ISSUE-45 in `../KNOWN-ISSUES.md` for what
it did before, measured.

## 3. Tools

| | |
|---|---|
| `check_relink_relocs.py` | simulates the loader's `rel.c` binding over the linked image and refuses relocations it would abort on. Takes the image as an argument; exits non-zero on complaints |
| `stamp_buildid.py` | writes the build id into `utsname.machine`, so the banner and `uname -m` identify the running image |
| `detect_pagesize.py` | scans the whole `.text` disassembly for the 2 KiB page idioms, i.e. finds the Model-B patch sites rather than trusting a list of them |
| `check_page_geometry.sh` | asserts in the **compiled bytes** that an object uses the 4 KiB shift — the cross toolchain injects its own sysroot first, so a wrong header is silent otherwise |
| `check_vproc.py` | asserts `v.v_proc == 200`, the invariant `krnxmemflt040.s`'s per-process depth table is sized against |
| `mk_modelb_sysroot.sh` | the Model-B header mirror; the cross toolchain injects its own sysroot first, so the vanilla headers never actually reach a kernel compile |
| `va2000_modelb.py`, `z3660_modelb.py` | convert a hard-coded `>>11` in third-party driver sources |

## 4. Counter blocks

Nine of the override units carry a counter block in `.data` whose first word is a magic string —
`fpc_magic` "FPC!", `wbf_magic` "WBF!", `f60_magic` "FP60", and so on. Read the magic first: a
counter block at a stale address does not fail, it returns a plausible number from whatever now
lives there. `../tools/status-facts.sh` prints every block's current runtime address and the magic
word read out of the artifact itself.

Full list with what each one measures: `../STATUS.md`.
