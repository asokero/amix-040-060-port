#!/usr/bin/env python3
"""hw.py -- raw-socket command runner for the REAL AMIX machine over telnet.

Same protocol handling as emu.py; the difference is that this one logs in with a password
and reads its host and credentials from local/secrets.env (gitignored).

AMIX telnetd sends IAC DO TERMINAL-TYPE and WAITS for an answer before printing
"login:" -- so we do minimal telnet negotiation: refuse every option
(DO->WONT, WILL->DONT) and strip IAC sequences from the data stream.
Sentinel gotcha: the echoed command line contains the sentinel text, so build
it with a quote split (echo CMD''DONE -> output CMDDONE).

Usage: hw.py 'cmd1' 'cmd2' ...          (root login WITH a password -- see local/secrets.env)
       hw.py --wait-login               (just poll until login prompt appears)
"""
import socket, sys, time

# Credentials and host come from local/secrets.env, which is gitignored.  Nothing in this
# repository contains a credential; see local/secrets.env.example.
def _load_env():
    import os
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "..", "local", "secrets.env")
    env = {}
    try:
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    except IOError:
        sys.exit("hw.py: %s not found -- copy local/secrets.env.example to it and fill it in"
                 % os.path.normpath(path))
    return env

_ENV = _load_env()
HOST = _ENV.get("AMIX_HOST", "")
PORT = int(_ENV.get("AMIX_PORT", "23"))
USER = _ENV.get("AMIX_USER", "root")
PASSWORD = _ENV.get("AMIX_PASS", "")
if not HOST or not PASSWORD:
    sys.exit("hw.py: AMIX_HOST and AMIX_PASS must be set in local/secrets.env")
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
    args = sys.argv[1:]
    tmo = 120
    if args and args[0] == "--timeout":
        tmo = int(args[1]); args = args[2:]
    wait_only = args == ["--wait-login"]
    cmds = [] if wait_only else args
    s = socket.create_connection((HOST, PORT), timeout=10)
    out, hit = read_until(s, [b"login:"], 60 if wait_only else 180)
    if hit is None:
        print("NO-LOGIN-PROMPT; got %d bytes:" % len(out))
        print(out[-400:].decode("latin1", "replace"))
        sys.exit(1)
    print("[login prompt seen]")
    if wait_only:
        sys.exit(0)
    s.sendall(USER.encode() + b"\n")
    out, hit = read_until(s, [b"# ", b"$ ", b"assword"], 60)
    if b"assword" in out:
        s.sendall(PASSWORD.encode() + b"\n")
        out, hit = read_until(s, [b"# ", b"$ "], 60)
    if hit is None:
        print("NO-SHELL-PROMPT; got:", out[-400:].decode("latin1", "replace")); sys.exit(1)
    print("[shell prompt seen]")
    for i, cmd in enumerate(cmds):
        tag = "CMD%dEND" % i
        s.sendall(cmd.encode() + ("; echo %s''%s\n" % (tag[:4], tag[4:])).encode())
        out, hit = read_until(s, [tag.encode()], tmo)
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
