# Building the AMIX 68040/68060 Port

This is the generic build guide. It assumes nothing about your machine except Linux and a shell.

**Read this first:** this repository does not contain a kernel. It contains a patch and override
layer that is applied to the kernel binary from **your own** Amiga UNIX installation. Nothing here
works without that file, and what you build you build from your own copy — no kernel binary is
distributed here. See `NOTICE` for how this was made and what it does and does not contain.

---

## 1. What you need

### Mandatory

| What | Why | Where |
|---|---|---|
| **AMIX cross toolchain** (`m68k-cbm-sysv4-gcc`, `-ld`) | produces the SVR4 m68k objects the AMIX linker accepts | <https://github.com/isoriano1968/gcc-cross-amix> — build it, then use its `build/env.sh`. **See ISSUE-55 first**: this line was not sufficient until 2026-08-28 |
| **GNU m68k binutils + gcc** (`m68k-linux-gnu-*`) | symbol surgery, relocation inspection, ELF checks, and assembling the GNU-syntax units | Debian/Ubuntu: `apt install binutils-m68k-linux-gnu gcc-m68k-linux-gnu` |
| **Python 3** | the byte-patchers and the relocation validator | any |
| **`patch`, `sha256sum`, standard coreutils** | | any |
| **Your AMIX installation**, mounted or unpacked | the kernel this port patches | AMIX SVR4 2.1c; the file needed is `stand/unix` |
| **NetBSD source tarball** (`syssrc.tgz`) | Motorola's 68040/68060 support packages and the FPE are extracted from it — they are not vendored here | **NetBSD 10.1 exactly**, pinned; see below |

**The tarball is pinned, not "any recent release".** Motorola's FPSP, the 060SP and NetBSD's
floating-point emulator are extracted *at build time* rather than vendored, so the tarball is a
build input exactly like a source file in this tree, and a different release is a different
kernel. Every script that extracts vendor source from the tarball verifies its checksum first,
against the single pin in `tools/netbsd-pin.sh`, and refuses a tarball it does not recognise —
and `tools/check-env.sh` checks the same pin at pre-flight — so the requirement is enforced
rather than documented. The one release the pin knows:

```
https://cdn.netbsd.org/pub/NetBSD/NetBSD-10.1/source/sets/syssrc.tgz
79497697 bytes
sha256  76a600e703d2e964753323e264d3ec07d0c6cbe134648fc8f0f13ed9faaa1be4
sha512  766ac21f33cfe0e701dfedb894fa07f36d811da1a12e979181e8fca7af4e627852680ce42a7b29e97dd3e2e402ddf9ae7bfba60c8d7dc6b8a3354d8ce8c06926
```

That this matters is a measurement, not a precaution. Between NetBSD 9.4 and 10.1 seventeen of
the extracted files changed; sixteen of those changes are RCS version lines and comment spelling,
but `fpe/fpu_explode.c` 1.15 → 1.16 deletes two arms of the operand-conversion switch. That
particular change turns out to be unreachable code — `docs/contracts/FPE-R10-VEC60.md` §13 proves
it and measures both tarballs' emulators against each other — but "unreachable" is a conclusion
someone had to reach. The next difference between two releases will not announce which kind it is.

The build scripts are POSIX `sh` and POSIX `awk`, deliberately: **no bash and no gawk**. They used
to call `strtonum()`, a GNU awk extension, which on a Debian or Ubuntu machine — where `awk` is
mawk — is a hard error rather than a wrong answer. The hex arithmetic is done by the shell now, and
the whole build is verified under `mawk` as well as `gawk`.

### The cross compiler needs repairs that were not in its repository until 2026-08-28

Building `gcc-cross-amix` as the table above says produced, until that date, a **different
compiler** from the one every kernel and every hardware acceptance in this project was made
with. The difference was sixty-six lines of assembler-syntax repairs that lived only as an
uncommitted working-tree change in one clone plus the installed copy beside it — see ISSUE-55.

They are committed now and offered upstream
(`isoriano1968/gcc-cross-amix`, from `asokero:fixes-2026-08-asokero`). Until that lands, a clone
built from upstream will fail to assemble anything this port compiles at `-m68040`: gcc emits
`FSxxx`/`FDxxx`, `fdmov`, `fmovm.l` and `mov &N,%dN`, and the assembler drops each one with
*statement ignored* rather than stopping — so the failure is an object with instructions missing,
not a build error.

### Optional

| What | Needed for |
|---|---|
| **Amiberry**, built locally | booting the kernel in an emulator. A *local build* is required: the packaged 8.2.2 cannot deliver host→guest network frames, which the test cycle uses |
| `nc`, `xdotool` | serial capture and console keystrokes during emulator testing |
| **Xsvga object** / **VA2000 driver source** | the graphics kernels (`relink-040-rtg.sh` and friends) |
| **Ghidra** | `tools/ghidra-decomp.sh`, for analysing the stock binary |
| `7z` | only the separate loader project (`amix-unix-boot`) needs it |

### Two notes on the cross toolchain

Its `Makefile` default for `AMIX_ROOT` points somewhere unhelpful; set it explicitly. And AMIX
disk images are usually mounted root-owned with unreadable `usr/lib` daemons, which the sysroot
build trips over — skip that directory:

```sh
make all AMIX_ROOT=/path/to/your/amix AMIX_USR_LIB=/nonexistent
```

---

## 2. Configure

```sh
cp config.sh.example config.sh
$EDITOR config.sh          # every variable is documented in place
sh tools/check-env.sh
```

`check-env.sh` verifies everything above, separates mandatory from optional, and exits non-zero
if a build would fail. It also checks the **sha256 of your `stand/unix`**:

```
7d26cb6f04991be5776d9e5361259b20b413d97e3da33bf88e6f312e7be2ec23
```

If yours differs, the build stops. That is deliberate and it is the most important safety
property here — see §5.

---

## 3. Build

```sh
sh relink-040.sh
```

One image boots both CPUs: `unix_boot040` pokes `cputype` from AmigaOS's `AttnFlags`, and every
CPU-specific path is gated on it. Output: `build/unix-040`.

Two lines of the output matter:

```
[*] stock kernel verified: .../stand/unix
TOTAL complaints: 0
```

The second is the relocation validator simulating the AMIX loader's `rel.c` over the relinked
image. **A non-zero count means the kernel would be rejected at boot**, so treat it as fatal.

Useful switches:

```sh
FPSP=0     sh relink-040.sh     # without Motorola's FP support package (A/B bisecting)
FPSP060=0  sh relink-040.sh     # 68060 back on the pre-FPSP path
```

### Variants

| Script | Produces |
|---|---|
| `relink-040.sh` | the base kernel — **this is the one** |
| `relink-040-dbg.sh` | base + debug probes |
| `relink-040-quiet.sh` | base + serial console mirror |
| `relink-040-rtg.sh` | base + **both** RTG drivers (Xsvga on cdevsw 67, VA2000 on 68) |
| `relink-040-xsvga.sh`, `relink-040-va2000.sh` | one driver each, for bisecting a driver problem |

**Always pass the base explicitly to a variant:**

```sh
sh relink-040-rtg.sh build/unix-040 build/unix-040-rtg
```

The default input is the emulator's staging slot, and taking it by accident is how a graphics
kernel once got built from a base containing none of that day's fixes.

---

## 4. Verify

```sh
sh tools/status-facts.sh                          # kernel loaded at 0x08000000
sh tools/status-facts.sh build/unix-040 0x07000000   # ...or wherever your loader binds it
```

This prints the build id, sha256, text size, **every counter block's runtime address with the
magic word it must read**, and a both-directions check of the override bindings (`bindings
failing: 0`).

The load base is not always `0x08000000`. The loader binds the kernel into the **largest non-chip
memory region** it finds, so an accelerator with its own RAM gives `0x08000000` while a card
without any — an A3640, for instance — gives `0x07000000`. Read `tvaddr` from the loader's own
boot output and pass it.

### What happens when a patch target has moved

Each of the 43 byte-patch scripts asserts the **old** bytes before writing the new ones. If an
assertion fails the script aborts, and the build stops there with the failing command named and
its full output printed — it does not continue and it does not print `[OK] built`. The output
file at that point is partially patched; do not boot it, rebuild.

That is the correct behaviour and it is newer than the checks themselves: until 2026-08-14 every
patcher was invoked through `| tail -n`, and a pipeline's exit status in POSIX sh is its *last*
command's. `set -e` never saw the failures. See ISSUE-45 in `KNOWN-ISSUES.md` — including the
measurement of what the old build did with a deliberately broken patch site.

### Self-tests

```sh
sh tools/test-build-step.sh        # 15 cases; the build must stop when a step fails
python3 tools/check-verbatim.py    # 0 unexplained
```

**`test-build-step.sh`** exists because the fix for ISSUE-45 was a fix *to a check*, and a check
that silently stops working is the failure this repository has spent the most effort learning to
refuse. It asserts, among other things, that a failing step reports its own exit status rather
than the shell's — which is the bug the first version of that fix actually had.

**`check-verbatim.py`** is the provenance gate.

This port was written with historical System V sources open as a reference for documented
behaviour. Citing them — file, line, function, the shape of an algorithm — is not copying;
pasting their lines is. The distinction is easy to state and easy to lose across a hundred
documents, so it is checked rather than remembered: every tracked line is compared against the
reference trees, and anything that matches has to be either rewritten as a description or
argued for in `tools/check-verbatim.allow`. The check only runs where those trees are unpacked,
and it says so when they are not, rather than passing silently.

### Reproducibility

Rebuilding the same tree twice produces images differing **only in the build-id stamp** (a date
and a per-day counter, 16 bytes at a known offset). That is the regression test for the build
system itself: after changing anything infrastructural, rebuild and diff.

---

## 5. Why the stock-kernel hash check is not negotiable

The patch scripts address the kernel by **hard-coded byte offsets** — `fpu_save` at `0x132`,
`hardbus` at `0x5b3c2`, specific relocation `r_offset`s, byte-pattern assertions. Against a
different build of `stand/unix` those offsets do not point at nothing; they point at *something
else*. The build would succeed and produce a kernel patched at the wrong bytes.

So the guarded failure is not "the build breaks" but "the build works and the result is quietly
wrong". If your 2.1c genuinely carries a different image, that is worth reporting — and you can
proceed at your own risk:

```sh
AMIX_ALLOW_UNKNOWN_STOCK=1 sh relink-040.sh
```

---

## 6. Booting it

Copy `build/unix-040` to the Amiga's AmigaOS volume and boot with the patched loader:

```
unix_boot040 unix-040
```

* **`unix_boot040` is mandatory**, for three independent reasons — any one of them is sufficient.
  It is a separate project: `amix-unix-boot`.

  1. **The stock loader traps before the kernel runs.** Its `copyit.s` disables the MMU with
     unguarded 68030 `pmove tc/crp/srp`, which is illegal on a 68040/68060. This was the first
     bring-up blocker of the whole port.
  2. **`cputype` is poked into the kernel by the loader**, not by the kernel itself. Without it a
     68060 keeps the built-in default of 40, and every CPU-gated path — `fpu_save`/`fpu_restore`/
     `fpu_setup`, `isp61_vec`, the FPSP 060 call-outs — takes the 68040 branch on 68060 silicon.
     Nothing about that failure is loud.
  3. **The stock `rel.c` mis-applies PC-relative relocations.** Measured on the current build:
     `FPSP=1` has 330 of them (PC32 106, PC16 223, PC8 1) out of 29 857 relocations; `FPSP=0` has
     **zero**. So this reason, alone, does not apply to a `FPSP=0` bisect build — which is why
     that build used to print an instruction to use the stock loader. Reasons 1 and 2 still do,
     so it no longer does.
* **On a 68060, run SetPatch first.** It is a boot precondition, not an optimisation.
* **`arp.library` is not needed** by `unix_boot040`. Markus Wild's readme lists it and the
  *prebuilt* loader in his archive does reference it, but the sources do not and neither does the
  binary built from the patches — measured: zero references to `arp.library` or `ArpBase` in
  `unix_boot040`, three in the shipped executable. It matters only if you run his original.
* On a 68040 the loader sets `cputype = 40`; verify it reads `0x28` rather than assuming.

---

## 7. How the port works, in one page

Worth reading before changing anything, because the mechanism is unusual.

The stock kernel is a **binary**, so a replacement routine cannot simply be linked in. Instead:

1. `objcopy --globalize-symbol` any file-local function our code needs to call;
2. `objcopy --weaken-symbol` each stock routine being replaced, and `--add-symbol NAME_orig=.text:0xADDR`
   so the original body stays reachable;
3. `m68k-cbm-sysv4-ld -r` links our override objects over the weakened image — our strong
   definitions win, every existing call site rebinds, and CPU-gated units tail-jump to `*_orig`
   for the path they do not implement;
4. Python byte-patchers fix what cannot be expressed as a symbol override — vector table slots,
   individual instructions, page-size constants;
5. the relocation validator simulates the AMIX loader over the result.

Rules learned the hard way, all of them enforced by the script:

* **Do not reorder the link and patch phases.** There are two `ld -r` runs, not one. The order is:
  core override link → byte patches against stock offsets → the FPSP link → the FPSP and ISP
  vector retargets. The first link places our `.text` first, which is what keeps every byte-patch
  address valid; the second must not be moved ahead of those patches, and nothing may relink
  after the final retargets, because that supersedes them.
* **Every override object's section ends with `.balign 4`.** The loader places `.bss` at
  `data_end` *unaligned*.
* **`--weaken-symbol`, never `--redefine-sym`** for replacing a routine.
* **Confirm with `nm` that the symbol actually moved.** `ld -r` does not fail when an override
  object is missing or its definition was dropped — it simply leaves the stock body strong, and
  the result links cleanly. `status-facts.sh` checks this in both directions for the units that
  matter, and `relink-040.sh` asserts it at link time.
  *(This bullet used to say the relink does not abort on an assembler error and still prints
  `[OK] built`. That stopped being true on 2026-08-14 — measured, by putting an illegal
  instruction in `src/config040.s`: the build exits 1 and prints no `[OK]`. See ISSUE-45.)*
* **Counter addresses change on every build** (`load_base + textsize + nm .data offset`). Never
  carry one over from an older document; generate them, and read the magic word first.

---

## 8. External drivers

Graphics drivers are the main extension point and live in their own repositories:

| Driver | Repository | Registered on |
|---|---|---|
| MNT VA2000 | `va2000-amix` | `cdevsw[68]`, `/dev/va2000` |
| Xsvga (Piccolo / Picasso II) | `xrtg-amix` | `cdevsw[67]`, `/dev/svga` |

Point `VA2000_SRC` and `XSVGA_EXP` at them in `config.sh`, then:

```sh
sh relink-040-rtg.sh build/unix-040 build/unix-040-rtg
mknod /dev/va2000 c 68 0     # on the Amiga
mknod /dev/svga   c 67 0
```

Adding a *new* driver follows the same shape as `relink-040-va2000.sh`: cross-compile it against
the Model-B header set, register it by retargeting a `cdevsw` relocation, and let the reloc
validator confirm nothing else moved.

---

## 9. Emulator testing

```sh
sh emu-reset-boot.sh 060 /tmp/emu.log build/unix-040   # 040 | 060
```

The guest's disk is reset from a golden image every run, so test binaries have to be transferred
each time (`test-tools/tftp_onesock.py` on the host, `tftp` on the guest).

**What the emulator cannot decide**, each learned by measurement, and the list is not closed:

* it raises **no enabled IEEE FP exceptions**, so those tests are *unexercised* there rather than
  passing — and its FPU does not preserve the extended NaN Motorola's fixtures need;
* it never sets **WB1S valid**, so one third of the 68040 write-back replay path cannot run;
* it **does not model the 68040's copyback data cache**, so a cache or DMA-coherency result from
  the emulator is not a result at all — ISSUE-38 could only be found on silicon for that reason;
* it is not evidence for **FSLW.MA** behaviour, or for which instructions the CPU traps as
  unimplemented: a UAE core may execute what real silicon refuses.

A green emulator run is necessary and not sufficient. Anything CPU-exception-shaped needs
hardware.
