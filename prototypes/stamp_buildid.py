#!/usr/bin/env python3
"""stamp_buildid.py -- write the build id into inituname040's `buildid` string.

Usage: stamp_buildid.py <kernel-elf>

Writes " 68040-<yymmdd>-<nn>" (exactly 16 chars) into the global `buildid`
string that inituname040.o appends to utsname.machine at boot.  <nn> is a
per-day counter kept in <builddir>/.build-seq, shared across the 040 variants
so any two kernels built the same day are distinguishable
(e.g. " 68040-260709-01", " 68040-260709-02", ...).

The reserved literal in inituname040.s is " 68040-000000-00" (16 chars); this
script overwrites those 16 chars in place (the trailing NUL is left intact), so
the field length never changes.  It resolves the `buildid` symbol and the .data
file offset from the ELF at stamp time -- no hardcoded offsets -- and refuses to
write unless the current content starts with " 68040-".
"""
import struct, subprocess, sys, os, re, datetime

PREFIX = b" 68040-"
FIELD_LEN = 16                          # len(" 68040-YYMMDD-NN")

def die(msg):
    sys.exit(f"stamp_buildid: ERROR: {msg}")

def data_offset(path):
    with open(path, 'rb') as f:
        eh = f.read(52)
        if eh[:4] != b'\x7fELF':
            die(f"{path} is not ELF")
        e_shoff = struct.unpack('>I', eh[32:36])[0]
        e_shentsize, e_shnum, e_shstrndx = struct.unpack('>HHH', eh[46:52])
        f.seek(e_shoff)
        sh = [f.read(e_shentsize) for _ in range(e_shnum)]
        so, ss = struct.unpack('>II', sh[e_shstrndx][16:24])
        f.seek(so); st = f.read(ss)
        for s in sh:
            n = struct.unpack('>I', s[0:4])[0]
            if st[n:st.index(b'\0', n)] == b'.data':
                return struct.unpack('>I', s[16:20])[0]
    die(f"{path}: no .data section")

def sym_value(path, name):
    out = subprocess.run(['m68k-linux-gnu-nm', path],
                         capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        m = re.match(rf'([0-9a-f]+) [A-Za-z] {re.escape(name)}$', line)
        if m:
            return int(m.group(1), 16)
    die(f"{path}: no `{name}` symbol (inituname040.o not linked?)")

def next_seq(builddir, today):
    seqfile = os.path.join(builddir, '.build-seq')
    date, seq = None, 0
    if os.path.exists(seqfile):
        try:
            date, s = open(seqfile).read().split()
            seq = int(s)
        except ValueError:
            pass
    seq = seq + 1 if date == today else 1
    with open(seqfile, 'w') as f:
        f.write(f"{today} {seq}\n")
    return seq

def main():
    if len(sys.argv) != 2:
        die(f"usage: {sys.argv[0]} <kernel-elf>")
    path = sys.argv[1]
    today = datetime.date.today().strftime('%y%m%d')
    seq = next_seq(os.path.dirname(path) or '.', today)
    field = f" 68040-{today}-{seq:02d}".encode()
    if len(field) != FIELD_LEN:
        die(f"stamp too long: {field!r} ({len(field)} != {FIELD_LEN})")

    off = data_offset(path) + sym_value(path, 'buildid')
    with open(path, 'r+b') as f:
        f.seek(off)
        cur = f.read(FIELD_LEN)
        if not cur.startswith(PREFIX):
            die(f"{path}: `buildid` content {cur!r} at 0x{off:x} does not start "
                f"with {PREFIX!r} -- layout changed? refusing to stamp")
        f.seek(off)
        f.write(field)
    print(f"stamp_buildid: {path}: buildid = \"{field.decode()}\" (@0x{off:x})")

if __name__ == '__main__':
    main()
