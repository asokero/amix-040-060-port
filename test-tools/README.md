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

All are K&R C for the native AMIX `cc`. Build on the guest with `cc -o NAME NAME.c`.
Push the sources with `tftp_onesock.py` (the guest disk is wiped by every
`emu-reset-boot.sh`). **`/tmp` is cleared on every AMIX boot** — put anything that has
to survive a reboot under `/` (the two-phase tests use `/pgc`).

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
