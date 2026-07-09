#!/usr/bin/env python3
"""stamp_version.py -- stamp a build id into the kernel's utsname.version field.

Usage: stamp_version.py <kernel-elf> <variant-tag>
  e.g. stamp_version.py build/unix-040 040
       stamp_version.py build/unix-040-dbg 040d
       stamp_version.py build/unix-040-quiet 040q

Writes "<tag>-<yymmdd>-<nn>" (e.g. "040-260709-01") into the utsname 'version'
field (offset +771 = 3*SYS_NMLN, SYS_NMLN=257) of the ET_REL kernel binary.
The boot banner prints it ("UNIX(R) System V Release %s AT&T %s Version %s" =
release, machine, version) and `uname -v` / `uname -a` report it, so a running
system always identifies which build it is.

<nn> comes from a per-day counter in build/.build-seq (shared across variants:
every stamp of a given day gets the next number, so any two kernels built the
same day are distinguishable).

Safety: refuses to write unless the current field content is the vanilla "?"
or a previous stamp (starts with the tag prefix pattern) -- so a layout change
in the binary can't be silently corrupted.
"""
import struct, subprocess, sys, os, re, datetime

SYS_NMLN = 257
VERSION_OFF = 3 * SYS_NMLN          # utsname.version
FIELD_MAX = SYS_NMLN - 1

def die(msg):
    sys.exit(f"stamp_version: ERROR: {msg}")

def elf_data_offset(path):
    """Return the .data section's file offset of an ELF32 BE ET_REL file."""
    with open(path, 'rb') as f:
        eh = f.read(52)
        if eh[:4] != b'\x7fELF':
            die(f"{path} is not ELF")
        # ELF32 big-endian header fields
        e_shoff = struct.unpack('>I', eh[32:36])[0]
        e_shentsize, e_shnum, e_shstrndx = struct.unpack('>HHH', eh[46:52])
        f.seek(e_shoff)
        shdrs = [f.read(e_shentsize) for _ in range(e_shnum)]
        # section-name string table
        sh = shdrs[e_shstrndx]
        stroff, strsize = struct.unpack('>II', sh[16:24])
        f.seek(stroff)
        strtab = f.read(strsize)
        for sh in shdrs:
            name_off = struct.unpack('>I', sh[0:4])[0]
            name = strtab[name_off:strtab.index(b'\0', name_off)]
            if name == b'.data':
                return struct.unpack('>I', sh[16:20])[0]  # sh_offset
    die(f"{path}: no .data section")

def utsname_value(path):
    """Section-relative value of the D symbol `utsname` (via nm)."""
    out = subprocess.run(['m68k-linux-gnu-nm', path],
                         capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        m = re.match(r'([0-9a-f]+) D utsname$', line)
        if m:
            return int(m.group(1), 16)
    die(f"{path}: no D utsname symbol")

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
    if len(sys.argv) != 3:
        die(f"usage: {sys.argv[0]} <kernel-elf> <variant-tag>")
    path, tag = sys.argv[1], sys.argv[2]
    today = datetime.date.today().strftime('%y%m%d')
    seq = next_seq(os.path.dirname(path) or '.', today)
    stamp = f"{tag}-{today}-{seq:02d}"
    if len(stamp) > FIELD_MAX:
        die(f"stamp too long: {stamp!r}")

    off = elf_data_offset(path) + utsname_value(path) + VERSION_OFF
    with open(path, 'r+b') as f:
        f.seek(off)
        cur = f.read(FIELD_MAX).split(b'\0')[0]
        if not (cur == b'?' or re.match(rb'^040[a-z]?-\d{6}-\d{2}$', cur)):
            die(f"{path}: unexpected utsname.version content {cur!r} "
                f"at 0x{off:x} -- layout changed? refusing to stamp")
        f.seek(off)
        # write stamp + NUL, then zero out the rest of the old content
        pad = max(len(cur), len(stamp)) + 1 - len(stamp)
        f.write(stamp.encode() + b'\0' * pad)
    print(f"stamp_version: {path}: utsname.version = \"{stamp}\" (@0x{off:x})")

if __name__ == '__main__':
    main()
