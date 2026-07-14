#!/usr/bin/env python3
"""sendkeys.py -- type a string on the emulated Amiga console via Amiberry IPC
SEND_KEY <rawkey> <state>.  Usage: sendkeys.py 'root' RET 'ping 10.0.2.2' RET
Each arg is typed literally; the literal arg RET sends Return.  TAB-separated
IPC commands; key down (1) then up (0) with small delays."""
import socket, sys, time

SOCK = "/run/user/12044/amiberry.sock"
RAW = {
    'a':0x20,'b':0x35,'c':0x33,'d':0x22,'e':0x12,'f':0x23,'g':0x24,'h':0x25,
    'i':0x17,'j':0x26,'k':0x27,'l':0x28,'m':0x37,'n':0x36,'o':0x18,'p':0x19,
    'q':0x10,'r':0x13,'s':0x21,'t':0x14,'u':0x16,'v':0x34,'w':0x11,'x':0x32,
    'y':0x15,'z':0x31,
    '1':0x01,'2':0x02,'3':0x03,'4':0x04,'5':0x05,'6':0x06,'7':0x07,'8':0x08,
    '9':0x09,'0':0x0A,
    ' ':0x40,'.':0x39,'/':0x3A,'-':0x0B,'=':0x0C,',':0x38,';':0x29,"'":0x2A,
}
RET = 0x44

def ipc(cmd):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK)
    s.sendall((cmd + "\n").encode())
    s.settimeout(2)
    try: r = s.recv(256)
    except socket.timeout: r = b""
    s.close()
    return r.decode("latin1", "replace").strip()

def key(code):
    ipc("SEND_KEY\t%d\t1" % code)
    time.sleep(0.06)
    ipc("SEND_KEY\t%d\t0" % code)
    time.sleep(0.09)

for arg in sys.argv[1:]:
    if arg == "RET":
        key(RET)
        time.sleep(0.5)
        continue
    for ch in arg:
        c = RAW.get(ch.lower())
        if c is None:
            print("SKIP unsupported char %r" % ch); continue
        key(c)
print("done")
