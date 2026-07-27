#!/usr/bin/env python3
"""nfstail-gen.py -- HOST side of the ISSUE-36 acceptance test: build the NFS test corpus.

WHY THE HOST WRITES THESE FILES
The defect is on the NFS READ path, so the client must never have written the bytes it is
checking. Everything here is produced by the host, over SMB, and AMIX only ever reads them --
the same separation that made the ISSUE-35 verdict trustworthy. A run tag in every filename
also means no page the client cached in an earlier run can mask a later one.

THE SIZES ARE NOT ARBITRARY -- they come from Codex's static predicate for the old gate
(vm-map/NFS-READSIDE-ISSUE36-SITE.md). With r = file_size mod 4096, the OLD nfs_getpage accepts
the final page only when r == 0 or r >= 2049, so:

    r == 0            full final page          accepted before the fix
    r in 1..2048      partial final page       REJECTED -> EFAULT -> 0xE05 -> SIGBUS
    r in 2049..4095   partial final page       accepted before the fix

So this corpus deliberately straddles the 2048/2049 boundary. That boundary is the whole point:
it is what tells Codex's model apart from "any partial page fails", which is what we originally
(wrongly) recorded from the field. A run where 1/123/2048 fail and 0/2049/4095 pass on the old
kernel CONFIRMS the model; a run where 2049 also fails REFUTES it and the analysis must be redone
before the patch is trusted.

The 28795 case exists for a different reason -- Codex's acceptance item 3. Its size is
8192*3 + 4096 + 123, so its last 8 KiB NFS block holds two 4 KiB pages of which the second is
partial. Faulting its tail first makes pvn_kluster scan backward and return both pages, which is
the input shape that exposes the pl[] return-list defect the EOF repair could otherwise unmask.

PATTERN: pat(o) = ((o ^ (o>>8) ^ (o>>16)) & 0xfe) + 1, so it is NEVER ZERO. That is deliberate:
a zero byte inside the file therefore means lost data, and the bytes between EOF and the end of
the final page MUST read as zero. One pattern gives us both checks, and the second check is the
only way to see the incomplete-page-initialization half of the defect (an EOF fix without the
io_len pair leaves bytes 2048..4095 of the tail page uninitialized -- reachable, wrong, silent).

usage: nfstail-gen.py <outdir> [runtag]
       nfstail-gen.py --elf <outdir> <vanilla-root> [runtag]     ELF-from-NFS corpus (item 5)
"""
import os, sys, struct


def pat(o):
    return (((o ^ (o >> 8) ^ (o >> 16)) & 0xFE) + 1) & 0xFF


# (size, note) -- r is size mod 4096, shown so the expectation table is readable on the console
CASES = [
    (24576, "r=0     full final page          -- control, worked before the fix too"),
    (24577, "r=1     partial                  -- REJECTED by the old gate"),
    (24699, "r=123   partial                  -- the originally observed hardware failure"),
    (26624, "r=2048  partial, BOUNDARY        -- last size the old gate rejects"),
    (26625, "r=2049  partial, BOUNDARY        -- first size the old gate accepts"),
    (28671, "r=4095  partial                  -- accepted before, must stay working"),
    (28795, "r=123 in the 2nd page of a partial 8K block -- backward clustering (item 3)"),
]


def gen_data(outdir, tag):
    os.makedirs(outdir, exist_ok=True)
    names = []
    for size, note in CASES:
        r = size & 0xFFF
        name = "tail_%s_%d_r%d" % (tag, size, r)
        path = os.path.join(outdir, name)
        buf = bytearray(size)
        for o in range(size):
            buf[o] = pat(o)
        with open(path, "wb") as f:
            f.write(buf)
        got = os.path.getsize(path)
        if got != size:
            raise SystemExit("ABORT: %s came back %d bytes, wanted %d -- the SMB/NAS write "
                             "path truncated it, so the corpus is invalid" % (path, got, size))
        names.append((name, size, r, note))
        print("  %-40s %7d bytes  %s" % (name, size, note))

    manifest = os.path.join(outdir, "tail_%s_manifest" % tag)
    with open(manifest, "w") as f:
        f.write("# ISSUE-36 acceptance corpus, run tag %s\n" % tag)
        f.write("# pattern: ((o ^ (o>>8) ^ (o>>16)) & 0xfe) + 1   (never zero)\n")
        f.write("# expectation on the OLD kernel: r in 1..2048 SIGBUS; r 0/2049/4095 pass\n")
        for name, size, r, note in names:
            f.write("%s %d %d\n" % (name, size, r))
    print("\n  manifest: %s" % manifest)
    print("  AMIX side: cc -o nfstail nfstail.c && ./nfstail <dir> tail_%s_manifest" % tag)


def exposed_loads(path):
    """Codex's predicate, per nonempty PT_LOAD of a big-endian m68k ELF:
         last_page = floor((p_offset + p_filesz - 1) / 4096) * 4096
         1 <= st_size - last_page <= 2048
    i.e. the segment's last mapped file page begins within 2048 bytes of the vnode's EOF.
    The comparison is against the WHOLE FILE SIZE, not p_filesz -- trailing ELF data masks the
    defect, which is why 'has a partial last page' is not the right test."""
    try:
        st = os.path.getsize(path)
        with open(path, "rb") as f:
            d = f.read(64)
            if len(d) < 52 or d[:4] != b"\x7fELF" or d[5] != 2:   # EI_DATA 2 = ELFDATA2MSB
                return 0
            if struct.unpack(">H", d[18:20])[0] != 4:             # EM_68K
                return 0
            phoff, = struct.unpack(">I", d[28:32])
            phentsize, phnum = struct.unpack(">HH", d[42:46])
            f.seek(phoff)
            ph = f.read(phentsize * phnum)
        n = 0
        for i in range(phnum):
            e = ph[i * phentsize:(i + 1) * phentsize]
            if len(e) < 32:
                continue
            p_type, p_offset, p_vaddr, p_paddr, p_filesz = struct.unpack(">IIIII", e[:20])
            if p_type != 1 or p_filesz == 0:                       # PT_LOAD, nonempty
                continue
            last_page = ((p_offset + p_filesz - 1) // 4096) * 4096
            if 1 <= st - last_page <= 2048:
                n += 1
        return n
    except Exception:
        return 0


def chmod_note(path):
    """Best effort: an SMB/NFS share commonly refuses chmod (Operation not supported), and a
    file written through the share arrives mode 666 -- not executable.  So the AMIX side MUST
    chmod it on the mount before exec, or exec fails with EACCES and the test measures the
    share's permissions instead of the kernel's page-in path."""
    try:
        os.chmod(path, 0o755)
    except OSError:
        print("      (chmod refused by the share -- AMIX must: chmod 755 <file> on the mount)")


def gen_elf(outdir, vanilla, tag):
    """Item 5: one EXPOSED binary executed from NFS, plus a non-exposed control."""
    os.makedirs(outdir, exist_ok=True)
    roots = ["bin", "sbin", "etc", "usr/bin", "usr/sbin", "usr/lib"]
    exposed, clean = [], []
    scanned = 0
    for rel in roots:
        base = os.path.join(vanilla, rel)
        if not os.path.isdir(base):
            continue
        for dirpath, _dirs, files in os.walk(base):
            for fn in files:
                p = os.path.join(dirpath, fn)
                if not os.path.isfile(p) or os.path.islink(p):
                    continue
                scanned += 1
                n = exposed_loads(p)
                if n > 0:
                    exposed.append((p, n))
                elif p.endswith(("ls", "cat", "echo", "date", "pwd")):
                    clean.append(p)
    print("  scanned %d files: %d exposed, %d candidate controls" % (scanned, len(exposed), len(clean)))
    if not exposed:
        print("  NO exposed binary found -- item 5 cannot run from this tree")
        return
    # Prefer something that does real work after entry and then EXITS on its own, so a fault on
    # its data path can surface without needing input.  Explicit preference order, because sorting
    # by name picked /sbin/su first -- setuid root and interactive, the worst possible choice for
    # an automated cold-exec test.
    PREF = ["uname", "pwd", "echo", "date", "ls", "ps", "mkdir", "hostname"]
    def rank(t):
        b = os.path.basename(t[0])
        return (PREF.index(b) if b in PREF else len(PREF), t[0])
    exposed.sort(key=rank)
    pick = exposed[0][0]
    dst = os.path.join(outdir, "elfx_%s_%s" % (tag, os.path.basename(pick)))
    with open(pick, "rb") as s, open(dst, "wb") as d:
        d.write(s.read())
    chmod_note(dst)
    print("  EXPOSED  -> %s  (from %s, %d exposed PT_LOAD)" % (dst, pick, exposed[0][1]))
    if clean:
        c = clean[0]
        dstc = os.path.join(outdir, "elfc_%s_%s" % (tag, os.path.basename(c)))
        with open(c, "rb") as s, open(dstc, "wb") as d:
            d.write(s.read())
        chmod_note(dstc)
        print("  CONTROL  -> %s  (from %s)" % (dstc, c))
    print("\n  AMIX side: run BOTH cold from the NFS mount; the exposed one is the test and the")
    print("  control proves a failure is about exposure and not about NFS exec in general.")


def main():
    a = sys.argv[1:]
    if a and a[0] == "--elf":
        if len(a) < 3:
            raise SystemExit(__doc__)
        gen_elf(a[1], a[2], a[3] if len(a) > 3 else "r1")
        return
    if not a:
        raise SystemExit(__doc__)
    gen_data(a[0], a[1] if len(a) > 1 else "r1")


if __name__ == "__main__":
    main()
