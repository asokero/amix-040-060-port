#!/usr/bin/env python3
"""tftp_onesock.py -- minimal read-only TFTP server that replies FROM THE
LISTENING PORT (1069).  slirp NAT drops replies from an ephemeral port, which
is why the stock runtime-tests/tftp_server.py stalls; this one works through
Amiberry slirp.  Serves files from the directory given as argv[1] (default .).
Guest usage:  tftp 10.0.2.2 1069  ->  binary; get <name> /tmp/<name>; quit
"""
import os, socket, struct, sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
PORT = 1069

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("0.0.0.0", PORT))
print("tftp_onesock: serving %s on UDP %d" % (os.path.abspath(ROOT), PORT))

sessions = {}  # addr -> (data, blocks_sent)

while True:
    pkt, addr = sock.recvfrom(2048)
    if len(pkt) < 4:
        continue
    op = struct.unpack("!H", pkt[:2])[0]
    if op == 1:  # RRQ
        parts = pkt[2:].split(b"\x00")
        name = parts[0].decode("latin1")
        base = os.path.basename(name)
        path = os.path.join(ROOT, base)
        if not os.path.isfile(path):
            sock.sendto(struct.pack("!HH", 5, 1) + b"file not found\x00", addr)
            print("RRQ %s from %s: NOT FOUND" % (base, addr))
            continue
        data = open(path, "rb").read()
        sessions[addr] = data
        print("RRQ %s from %s: %d bytes" % (base, addr, len(data)))
        chunk = data[0:512]
        sock.sendto(struct.pack("!HH", 3, 1) + chunk, addr)
    elif op == 4:  # ACK
        blk = struct.unpack("!H", pkt[2:4])[0]
        data = sessions.get(addr)
        if data is None:
            continue
        total_blocks = len(data) // 512 + 1
        if blk >= total_blocks:
            print("done: %s (%d blocks)" % (addr, blk))
            del sessions[addr]
            continue
        nxt = blk + 1
        chunk = data[(nxt - 1) * 512: nxt * 512]
        sock.sendto(struct.pack("!HH", 3, nxt) + chunk, addr)
