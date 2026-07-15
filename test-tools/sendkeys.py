#!/usr/bin/env python3
"""sendkeys.py -- type a string on the emulated Amiga console via Amiberry IPC
SEND_KEY <rawkey> <state>.  Usage: sendkeys.py 'root' RET 'ping 10.0.2.2' RET
Each arg is typed literally; the literal arg RET sends Return.  TAB-separated
IPC commands; key down (1) then up (0) with small delays.

The AMIX golden image's console keymap is GERMAN (discovered 2026-07-15: raw
US-position sends garbled every special char -- '/'->'-', '-'->'ss', y<->z).
Default layout here is therefore 'de': each ASCII char is translated to the
(rawkey, shift) pair that PRODUCES it under the guest's German keymap.
Pass --us as the first arg for the old US-position behaviour."""
import socket, sys, time

SOCK = "/run/user/12044/amiberry.sock"
LSHIFT = 0x60
RET = 0x44

# Amiga rawkey positions (layout-independent physical codes)
US = {
    'a':0x20,'b':0x35,'c':0x33,'d':0x22,'e':0x12,'f':0x23,'g':0x24,'h':0x25,
    'i':0x17,'j':0x26,'k':0x27,'l':0x28,'m':0x37,'n':0x36,'o':0x18,'p':0x19,
    'q':0x10,'r':0x13,'s':0x21,'t':0x14,'u':0x16,'v':0x34,'w':0x11,'x':0x32,
    'y':0x15,'z':0x31,
    '1':0x01,'2':0x02,'3':0x03,'4':0x04,'5':0x05,'6':0x06,'7':0x07,'8':0x08,
    '9':0x09,'0':0x0A,
    ' ':0x40,'.':0x39,'/':0x3A,'-':0x0B,'=':0x0C,',':0x38,';':0x29,"'":0x2A,
}

# char -> (rawkey, shift) under the guest's GERMAN keymap.
# Letters: y/z physically swapped; the rest match US positions.
DE = {}
for ch, code in US.items():
    if ch in "abcdefghijklmnopqrstuvwx0123456789 .,":
        DE[ch] = (code, 0)
DE['y'] = (0x31, 0)   # US 'z' position
DE['z'] = (0x15, 0)   # US 'y' position
DE['-'] = (0x3A, 0)   # US '/' position
DE['_'] = (0x3A, 1)
DE['/'] = (0x07, 1)   # shift+7
DE['&'] = (0x06, 1)
DE['('] = (0x08, 1)
DE[')'] = (0x09, 1)
DE['='] = (0x0A, 1)   # shift+0
DE['!'] = (0x01, 1)
DE['"'] = (0x02, 1)
DE['$'] = (0x04, 1)
DE['%'] = (0x05, 1)
DE[':'] = (0x39, 1)   # shift+.
DE[';'] = (0x38, 1)   # shift+,
DE['?'] = (0x0B, 1)   # shift+ß (US '-' position)
DE['<'] = (0x30, 0)   # ISO key left of 'y' row
DE['>'] = (0x30, 1)
DE['+'] = (0x1B, 0)   # US ']' position
DE['*'] = (0x1B, 1)
DE['#'] = (0x2B, 0)   # key left of Return
DE["'"] = (0x2B, 1)   # shift+#

def ipc(cmd):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK)
    s.sendall((cmd + "\n").encode())
    s.settimeout(2)
    try: r = s.recv(256)
    except socket.timeout: r = b""
    s.close()
    return r.decode("latin1", "replace").strip()

def press(code, state):
    ipc("SEND_KEY\t%d\t%d" % (code, state))

def key(code, shift=0):
    if shift:
        press(LSHIFT, 1); time.sleep(0.05)
    press(code, 1)
    time.sleep(0.06)
    press(code, 0)
    if shift:
        time.sleep(0.05); press(LSHIFT, 0)
    time.sleep(0.09)

args = sys.argv[1:]
layout = "de"
if args and args[0] == "--us":
    layout = "us"; args = args[1:]

for arg in args:
    if arg == "RET":
        key(RET)
        time.sleep(0.5)
        continue
    for ch in arg:
        if layout == "us":
            c = US.get(ch.lower())
            if c is None:
                print("SKIP unsupported char %r" % ch); continue
            key(c)
        else:
            lo = ch.lower()
            if ch.isalpha() and ch.isupper():
                ent = DE.get(lo)
                if ent is None:
                    print("SKIP unsupported char %r" % ch); continue
                key(ent[0], shift=1)
            else:
                ent = DE.get(ch)
                if ent is None:
                    print("SKIP unsupported char %r" % ch); continue
                key(ent[0], shift=ent[1])
print("done")
