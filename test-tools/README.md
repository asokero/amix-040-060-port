# test-tools/ — emulator test-cycle helpers

Host-side scripts for driving the AMIX kernel under Amiberry. Companions to
`../emu-reset-boot.sh` (the deterministic golden-image reset + boot launcher).
Persisted here (2026-07-15) so they survive across sessions — they previously
lived only in the ephemeral scratchpad.

Machine-specific constants baked in (adjust if the environment changes):
- Amiberry IPC socket `/run/user/12044/amiberry.sock` (uid 12044)
- serial `TCP://0.0.0.0:1234`, inbound telnet `localhost:2323` (slirp redir)
- guest sees the host as `10.0.2.2`; TFTP served on UDP 1069

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
