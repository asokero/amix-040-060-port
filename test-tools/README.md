# test-tools/ — emulator test-cycle helpers

Host-side scripts for driving the AMIX kernel under Amiberry. Companions to
`../emu-reset-boot.sh` (the deterministic golden-image reset + boot launcher).
Persisted here (2026-07-15) so they survive across sessions — they previously
lived only in the ephemeral scratchpad.

Machine-specific constants baked in (adjust if the environment changes):
- Amiberry IPC socket `/run/user/12044/amiberry.sock` (uid 12044)
- serial `TCP://0.0.0.0:1234`, inbound telnet `localhost:2323` (slirp redir)
- guest sees the host as `10.0.2.2`; TFTP served on UDP 1069

## Reading the serial log: how to tell "booted" from "hung"
The kernel's `login:` prompt goes to the CONSOLE, **not** to serial — waiting for
`login:` in the serial log never returns. The reliable "reached idle / fully booted"
signal is the proc-table dump emitted by `mainmarks.s`'s idle hook:

    W <pid>:<p_stat>:<p_wchan> <pid>:<p_stat>:... 

(`p_stat` 1 = SSLEEP). A healthy multiuser boot shows ~22 entries. Wait for two of
these before priming the console.

The other high-volume marker is `sigkill_dbg.s`'s clock sampler, `C<pid>:<PC>:<SR>`
(capped at 1024). A wall of `C00000000:<addr>:00002000` means proc 0 is in the idle
loop — i.e. **idle, not hung**. Don't mistake it for a spin.

Grep gotcha: these markers are packed with hex digits, so a pattern like
`grep -ao "DBG FOO.\{0,120\}"` silently truncates at the first `C`/`A`/`E`. Use a
plain byte count and `cat -v`, not a negated character class.

## Test programs — what to run, and what each one actually proves

Most are K&R C for the native AMIX `cc`. Build on the guest with `cc -o NAME NAME.c`.
Push the sources with `tftp_onesock.py` (the guest disk is wiped by every
`emu-reset-boot.sh`). **`/tmp` is cleared on every AMIX boot** — put anything that has
to survive a reboot under `/` (the two-phase tests use `/pgc`).

**Exceptions — cross-build-only, NOT native-`cc` buildable.** Some tools here must be built with
the m68k-cbm-sysv4 cross toolchain on the host and transferred as binaries, because they use GNU C
or GNU-syntax assembly the guest's 1991 AT&T `cc`/`as` cannot compile. **Do not read the native
compile/assemble error as a result** — it is a toolchain mismatch. This is the whole list. It used
to name two of them and wave at the rest, which is how a reader who picked `isp61ea` or `fpimm60`
instead met exactly the error the paragraph exists to pre-empt:

| Tool | Why the guest cannot build it | Recipe of record |
|---|---|---|
| `fp060probe.c` | GNU C `__asm__ volatile`; native `cc` answers "undefined symbol: `__asm__`" | `m68k-cbm-sysv4-gcc -m68040 -o fp060probe fp060probe.c` (`mk060.sh`:16, `../docs/ACCEPTANCE.md`:201). The file's own header gives `-m68020 -m68881` instead; the two recipes have never been reconciled |
| `fpimm60.c` | GNU C `__asm__`, same reason | `m68k-cbm-sysv4-gcc -O0 -o fpimm60 fpimm60.c` (`../docs/contracts/FPE-R10-VEC60.md`:668). **`-O0` is mandatory**, not a preference: gcc 2.7.2.3 constant-folds floating point at every other level and silently replaces the thing under test |
| `ftunimp0.c` + `ftunimp0_asm.s` | the assembler half is GNU syntax (`#` immediates); `/usr/ccs/bin/as` answers "invalid instruction name" | its header gives `m68k-cbm-sysv4-gcc -m68040 -o ftunimp0 ftunimp0.c ftunimp0_asm.s`, but `../docs/REALHW-260807-11-ACCEPTANCE.md`:433 records that the SVR4 cross-assembler rejects the `.s` too — assemble it with `m68k-linux-gnu-gcc -c -x assembler` and link the object with `m68k-cbm-sysv4-gcc` |
| `isp61ea.c` + `isp61ea_asm.s` | GNU-syntax assembler half | `m68k-linux-gnu-as -m68040 isp61ea_asm.s -o isp61ea_asm.o` then `m68k-cbm-sysv4-gcc -m68040 -o isp61ea isp61ea.c isp61ea_asm.o` (`mk060.sh`:17-18, `../docs/ACCEPTANCE.md`:202-203) |
| `fpenab060.c` + `fpenab060_asm.s` | GNU-syntax assembler half **and** cpp macros — `fpenab060_asm.s`:35, 50, 59 are `#define`s with line continuations, which a bare assembler cannot expand | assemble through the preprocessor: `m68k-linux-gnu-gcc -m68060 -c -x assembler-with-cpp -o x.o fpenab060_asm.s`, then `m68k-cbm-sysv4-gcc -m68020 -m68881 -O -o fpenab060 fpenab060.c x.o` (`../docs/archive/NEXT-SESSION-PROMPT-260812.md`:105-106) |
| `ftest060` | not a guest build at all: Motorola's `dist/ftest.sa` image plus a 128-byte call-out section, assembled by `m68k-linux-gnu-gcc` and linked by `m68k-cbm-sysv4-gcc` | `sh ../build-ftest060.sh` → `build/ftest060`; push that binary |

Two entries in that table correct documents elsewhere, and the correction is worth stating rather
than leaving as a discrepancy for the next reader to re-derive:

* **`fpenab060` is not unresolved.** `mk060.sh`:19-20 and `../docs/ACCEPTANCE.md`:206 say its
  recipe "is still unknown". That is true only of a bare assembler: the file is cpp-macro
  assembly, so `as` dies at the first continuation line, which is the `line 36` in `mk060.sh`'s
  note. Routed through `gcc -x assembler-with-cpp` it builds, and it has — the silicon run in
  `f3-m4-enabled-hw-260811.txt` (kernel 68060-260810-03, 2026-08-11) was made with that binary.
* **`isp61xf` is NOT cross-build-only**, despite sitting beside `isp61ea` in the same lane.
  `isp61xf_asm.s` is SVR4-dialect assembly — every immediate in it is `&`, not `#` (the `#`
  forms in that file are inside `|` comments quoting a GNU disassembly), so the guest's own
  assembler takes it. Likewise `isp61test_asm.s` and `isp61neg_asm.s`.

`fputest060.c` is not in the table either: its header records that the AT&T chain died on it, but
that was measured in the F0 era before the 68060 FPSP existed, and `mk060.sh`:9 records the later
measurement — `/usr/ccs/bin/cc` builds it on the guest. `mk060.sh` builds one of its four tools
for exactly the reasons tabulated above.

Model-B / VM correctness (all added 2026-07-25 unless noted):

| Program | Proves | Discriminating signal |
|---|---|---|
| `proctest.c` | ISSUE-17/18 — /proc process memory | pre-fix kernel PANICS in `prfastmapin`; T1 reads the child's pattern where the parent's own page is zeros |
| `mlocktest.c` | ISSUE-28 — `memcntl`/`plock` mlock bitmap | T1: `memcntl(base+2048, MC_LOCK)` must return EINVAL; pre-fix returns 0 |
| `pgcold.c` | ISSUE-27 — `segmap_pagecreate` tail | **modes D/E**: 24/24 files lose valid data pre-fix, 0/24 post-fix. Modes A/B/C are kept as the record of three probe designs that could NOT see it |
| `pgcreatetest.c` | ISSUE-27, superseded | the spec's original probe; inert on this filesystem (see the COLD-PROOF evidence file for why) |
| `trunctest.c` | ISSUE-30 — `pvn_vptrunc` tail | truncate + regrow; **does not reproduce** (truncate frees the very blocks the term fails to clear) |
| `bmaptest.c` | ISSUE-31 — `ufs_bmap` | direct/fragment-growth/indirect/sync-write, whole-file byte check; the 4097..6144 interval is where the read is now skipped |
| `exectest.c` | ISSUE-32 — ELF exec mapping | verifies its OWN data+BSS and re-execs itself 20 generations; "the binary runs" would pass on a broken kernel |
| `devmaptest.c` | ISSUE-33 — device mmap PFN | maps `/dev/mem` at the kernel base: pre-fix 0/4096 non-zero bytes, post-fix 3186/4096 |

Older, still useful:

| Program | Proves |
|---|---|
| `bigargv.c` | 4500 B argv byte-exact across `exec` (`exec_initialstk` + `extractarg`) |
| `msynctst.c` | `mmap` MAP_SHARED + `msync(MS_SYNC)` → `ufs_putpage` disk truth |
| `swapls.c` | `swapctl(SC_LIST)` slot count (proved PAGES 25600, not the 51199 double) |
| `fputest.c` | FPU/FPSP: `fmovecr`+`fintrz` emulation, fork FP context |
| `mincoretst.c` | generic `mincore` vector |
| `shmband.c` | whether SysV `shmget` still builds its anon map in 2 KiB units while every consumer counts in 4 KiB. The signal is a **band, not a threshold**: sizes with `sz mod 4096` in 1..2048 should reach `segvn_create`'s `amp->size >= seg->s_size` check and **PANIC**, the rest survive. Prints each size and flushes *before* the attach, so on a kernel with the mismatch the last console line names the size that did it. `-n` gets + `IPC_STAT` only and never attaches, which is the safe half |
| `b2verify.c` | B2 copyback counters |
| `svgaprobe.c`, `va2000probe.c` | RTG board probes (VA2000 is **not** emulatable — expect a clean ENXIO) |

Two-phase tests need a **soft `reboot` inside the guest**, never `emu-reset-boot.sh`:
that restores the golden image and destroys the files the first phase created.

```sh
./pgcold D 24 /pgc      # phase A: create, sync
sync; sync; reboot      # cold the page cache
cc -o pgcold pgcold.c   # /tmp was cleared, rebuild
./pgcold E 24 /pgc      # phase B: probe.  PASS = PRESERVED
```

## proctest.c — /proc process-memory acceptance test (ISSUE-17/18)
Forks a child and reads+writes its memory through `/proc/<pid>` in three regions that
hit three different kernel paths (resident-private, COW, never-touched), plus a
page-crossing read. `cc -o proctest proctest.c; ./proctest` as root. Prints
`PROCTEST-RESULT PASS|FAIL`. On a kernel without the ISSUE-17 fix this **panics**.

Trap worth remembering for any /proc tooling: procfs uses the file OFFSET as the
virtual address, and user VAs (>= 0x80000000) are NEGATIVE as a signed `off_t`. A
single `lseek()` to them is rejected, so seek in two positive steps — and test for
failure with `== -1`, never `< 0`, because a *successful* high offset is negative.

## emu.py — telnet command runner (emulator)
`python3 emu.py 'cmd1' 'cmd2' ...` — logs in as root (NO password on the
emulator), runs each command, prints output. `--wait-login` just polls for the
login prompt. Does minimal telnet option negotiation (the AMIX telnetd waits
for an IAC answer before printing `login:`, so a bare raw socket hangs).
Sentinel gotcha handled internally via a quote-split marker.
## hw.py — the same runner, for the real machine
`python3 hw.py 'cmd1' 'cmd2' ...` — identical telnet handling to `emu.py`, but it
logs in with a password and reads the host and credentials from
`../local/secrets.env`, which is gitignored (`local/secrets.env.example` shows the
shape). **No credential appears anywhere in this repository**, which is the rule
this split exists to keep; earlier versions of this file said there was
deliberately no real-machine runner at all, which stopped being true when the
credentials moved into an untracked file instead of into the script.

## sendkeys.py — console keystrokes via Amiberry IPC SEND_KEY
`python3 sendkeys.py 'root' RET 'ping 10.0.2.2' RET` — types on the emulated
console (rawkey map). Use for console login / priming the aen/slirp MAC-learn
(one guest-originated packet is needed after each Amiberry start before inbound
telnet 2323 works). `RET` = Return.

## tftp_onesock.py — slirp-safe read-only TFTP server
`python3 tftp_onesock.py <dir>` serves files on UDP 1069, REPLYING FROM THE
LISTENING PORT (the stock ephemeral-reply TFTP servers get dropped by Amiberry
slirp NAT). Guest: `tftp 10.0.2.2 1069` → `binary; get <name> /tmp/<name>`.
Guest disk state is wiped every `emu-reset-boot.sh` run (golden-image reset), so
re-push test binaries each cycle.
