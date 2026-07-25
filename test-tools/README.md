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
NOTE: there is deliberately NO `real.py` here — the real machine needs
credentials that must NEVER be committed. Recreate it from this file + the creds
in `~/kehitys/CLAUDE.md` when a real-HW session is needed.

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
