#!/usr/bin/env python3
"""emu.py -- raw-socket command runner for the EMULATED AMIX (localhost:2323).

AMIX telnetd sends IAC DO TERMINAL-TYPE and WAITS for an answer before printing
"login:" -- so we do minimal telnet negotiation: refuse every option
(DO->WONT, WILL->DONT) and strip IAC sequences from the data stream.
Sentinel gotcha: the echoed command line contains the sentinel text, so build
it with a quote split (echo CMD''DONE -> output CMDDONE).

Usage: emu.py 'cmd1' 'cmd2' ...          (root login, no password on emulator)
       emu.py --wait-login               (just poll until login prompt appears)
"""
import socket, sys, time

HOST, PORT = "localhost", 2323
IAC, DONT, DO, WONT, WILL, SB, SE = 255, 254, 253, 252, 251, 250, 240

def pump(sock, buf_state):
    """Read available bytes; answer negotiation; return cleaned new data."""
    try:
        chunk = sock.recv(4096)
    except socket.timeout:
        return b"", False
    if not chunk:
        return b"", True
    data = buf_state["pending"] + chunk
    buf_state["pending"] = b""
    out, reply = bytearray(), bytearray()
    i = 0
    while i < len(data):
        b = data[i]
        if b != IAC:
            out.append(b); i += 1; continue
        if i + 1 >= len(data):
            buf_state["pending"] = data[i:]; break
        cmd = data[i+1]
        if cmd == IAC:
            out.append(IAC); i += 2; continue
        if cmd in (DO, DONT, WILL, WONT):
            if i + 2 >= len(data):
                buf_state["pending"] = data[i:]; break
            opt = data[i+2]
            if cmd == DO:   reply += bytes([IAC, WONT, opt])
            elif cmd == WILL: reply += bytes([IAC, DONT, opt])
            i += 3; continue
        if cmd == SB:  # skip subnegotiation to IAC SE
            j = data.find(bytes([IAC, SE]), i + 2)
            if j < 0:
                buf_state["pending"] = data[i:]; break
            i = j + 2; continue
        i += 2  # other 2-byte command
    if reply:
        sock.sendall(bytes(reply))
    return bytes(out), False

def read_until(sock, needles, timeout):
    buf, state = b"", {"pending": b""}
    end = time.time() + timeout
    sock.settimeout(2)
    while time.time() < end:
        data, eof = pump(sock, state)
        buf += data
        for n in needles:
            if n in buf:
                return buf, n
        if eof:
            break
    return buf, None

def main():
    wait_only = sys.argv[1:] == ["--wait-login"]
    cmds = [] if wait_only else sys.argv[1:]
    s = socket.create_connection((HOST, PORT), timeout=10)
    out, hit = read_until(s, [b"login:"], 60 if wait_only else 180)
    if hit is None:
        print("NO-LOGIN-PROMPT; got %d bytes:" % len(out))
        print(out[-400:].decode("latin1", "replace"))
        sys.exit(1)
    print("[login prompt seen]")
    if wait_only:
        sys.exit(0)
    s.sendall(b"root\n")
    out, hit = read_until(s, [b"# ", b"$ ", b"assword"], 60)
    if b"assword" in out:
        print("UNEXPECTED password prompt on emulator"); sys.exit(1)
    if hit is None:
        print("NO-SHELL-PROMPT; got:", out[-400:].decode("latin1", "replace")); sys.exit(1)
    print("[shell prompt seen]")
    for i, cmd in enumerate(cmds):
        tag = "CMD%dEND" % i
        s.sendall(cmd.encode() + ("; echo %s''%s\n" % (tag[:4], tag[4:])).encode())
        out, hit = read_until(s, [tag.encode()], 120)
        text = out.decode("latin1", "replace")
        print("===== %s" % cmd)
        print(text.split(tag)[0].strip())
        if hit is None:
            print("[TIMEOUT waiting sentinel %s]" % tag)
            break
    s.sendall(b"exit\n")
    time.sleep(1)
    s.close()

if __name__ == "__main__":
    main()
