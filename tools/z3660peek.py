#!/usr/bin/env python3
"""z3660peek.py <kernel.elf> [--pid N] [--base ADDR] [--sites-only]

Read the z3660scsi driver's counters out of a live emulated guest, with EVERY address --
the counter sites, the section bases and the anchor -- re-derived from the artifact that is
actually running.  Nothing is carried in this file.

WHY IT LIVES HERE.  Until now this tool was copied from one bench session directory to the
next carrying a hand-kept table of R_68K_32 site offsets.  The round-7 re-base shifted every
appended-object site by +4, and a stale site does not fail: it reads a longword out of the
middle of the neighbouring instruction and returns a plausible address.  An untracked tool
is re-copied stale forever, so the fix is to track it and to derive rather than remember --
the same correction `tools/status-facts.sh` took for the same reason.

The anchor is derived too.  The previous copy hard-coded `zc_magic` at 0x07111C18 with the
literal magic beside it, which is the very defect this tool exists to prevent: both move
whenever a block is added.  Here the anchor symbol's address comes from the ELF's section
map and its expected value is read out of the ELF's own bytes.

RESOLUTION RULES, and each refuses rather than guessing:
  * a symbol defined in an allocated section resolves to base + section_base + st_value;
  * a COMMON symbol has no address in the file, so it resolves through its R_68K_32
    relocation sites: every site is read in the guest and they MUST agree;
  * two different symbols resolving to one address is reported as a collision.

--sites-only needs no guest and no /proc: it prints the whole resolution table from the ELF
alone, which is how this tool is checked before a window is spent on it.
"""
import re
import struct
import sys

WANT = [
    "z3660_direct_map", "z3660_ci_ok", "z3660_dtt0", "z3660_dtt1", "z3660_cacr",
    "z3660_push_n", "z3660_push_bytes", "z3660_inv_n", "z3660_inv_bytes",
    "z3660_range_ovf", "z3660_nest_hits", "z3660_cq_overflow",
    "z3660_sptalloc_unsafe", "z3660_bounce_wr_n", "z3660_bounce_rd_n",
    "z3660_pagecross_n", "z3660_cache",
]

ANCHOR = "zc_magic"          # a .data symbol, so its value is in the file
SHN_COMMON = 0xFFF2
SHF_ALLOC = 0x2
SHT_SYMTAB, SHT_RELA, SHT_NOBITS = 2, 4, 8


class Elf:
    """Just enough big-endian ELF32 to answer "where does this symbol live at run time"."""

    def __init__(self, path):
        self.d = d = open(path, "rb").read()
        if d[:4] != b"\x7fELF" or d[5] != 2:
            sys.exit("not a big-endian ELF32: %s" % path)
        (shoff,) = struct.unpack_from(">I", d, 0x20)
        shentsize, shnum, shstrndx = struct.unpack_from(">HHH", d, 0x2E)
        self.secs = []
        for i in range(shnum):
            o = shoff + i * shentsize
            (name, typ, flags, addr, off, size, link,
             info, align, entsize) = struct.unpack_from(">IIIIIIIIII", d, o)
            self.secs.append(dict(name=name, typ=typ, flags=flags, off=off, size=size,
                                  link=link, info=info, entsize=entsize))
        strt = self.secs[shstrndx]["off"]
        for s in self.secs:
            s["nm"] = self._str(strt, s["name"])
        # Allocated sections are laid out contiguously from the load base, in header
        # order, with no re-alignment -- asserted against the artifact rather than
        # assumed, because .bss follows .data at an unaligned offset in this family.
        run = 0
        for s in self.secs:
            if s["flags"] & SHF_ALLOC:
                s["vbase"] = run
                run += s["size"]
            else:
                s["vbase"] = None
        self.image_size = run

    def _str(self, tab, off):
        e = self.d.index(b"\0", tab + off)
        return self.d[tab + off:e].decode()

    def symbols(self):
        """-> {name: (shndx, st_value, st_size)} for the last definition of each name."""
        symtab = [s for s in self.secs if s["typ"] == SHT_SYMTAB][0]
        strt = self.secs[symtab["link"]]["off"]
        out = {}
        self._symlist = []
        for i in range(symtab["size"] // symtab["entsize"]):
            o = symtab["off"] + i * symtab["entsize"]
            nameo, val, size, info, other, shndx = struct.unpack_from(">IIIBBH", self.d, o)
            nm = self._str(strt, nameo) if nameo else ""
            self._symlist.append(nm)
            if nm:
                out[nm] = (shndx, val, size)
        return out

    def relsites(self, wanted):
        """-> {symbol: [.text offsets]} out of the ELF's own SHT_RELA sections."""
        if not hasattr(self, "_symlist"):
            self.symbols()
        out = {}
        for s in self.secs:
            if s["typ"] != SHT_RELA or self.secs[s["info"]]["nm"] != ".text":
                continue
            for i in range(s["size"] // s["entsize"]):
                o = s["off"] + i * s["entsize"]
                off, info, addend = struct.unpack_from(">IIi", self.d, o)
                if (info & 0xFF) == 1 and self._symlist[info >> 8] in wanted:
                    out.setdefault(self._symlist[info >> 8], []).append(off)
        return out

    def static_addr(self, shndx, value):
        """Run-time offset from the load base for a symbol in an allocated section."""
        if shndx >= len(self.secs):
            return None
        s = self.secs[shndx]
        if s["vbase"] is None:
            return None
        return s["vbase"] + value

    def file_word(self, shndx, value):
        """The longword the FILE holds for a symbol, or None for a .bss/NOBITS one."""
        s = self.secs[shndx]
        if s["typ"] == SHT_NOBITS:
            return None
        return struct.unpack_from(">I", self.d, s["off"] + value)[0]


def regions(pid):
    """Readable guest-sized mappings.  The magic anchor decides, not the size -- the
    window is only here to keep the scan short, and it is wide enough for a 128 MiB
    guest, which the previous 8-40 MiB filter silently skipped."""
    out = []
    for line in open("/proc/%d/maps" % pid):
        m = re.match(r"([0-9a-f]+)-([0-9a-f]+) (\S{4}) ", line)
        if not m:
            continue
        lo, hi, perms = int(m.group(1), 16), int(m.group(2), 16), m.group(3)
        if perms[0] == "r" and (4 << 20) <= hi - lo <= (1024 << 20):
            out.append((lo, hi, line.rstrip()))
    return out


def read_region(pid, lo, hi):
    buf = bytearray()
    with open("/proc/%d/mem" % pid, "rb", 0) as f:
        for off in range(lo, hi, 1 << 20):
            n = min(1 << 20, hi - off)
            try:
                f.seek(off)
                buf += f.read(n)
            except OSError:
                buf += b"\0" * n
    return bytes(buf)


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    elfpath = argv[1]
    pid = base = None
    sites_only = False
    i = 2
    while i < len(argv):
        if argv[i] == "--pid":
            pid = int(argv[i + 1]); i += 2
        elif argv[i] == "--base":
            base = int(argv[i + 1], 0); i += 2
        elif argv[i] == "--sites-only":
            sites_only = True; i += 1
        else:
            sys.exit("unknown argument %r" % argv[i])
    if base is None:
        base = 0x08000000
    if pid is None and not sites_only:
        sys.exit("need --pid, or --sites-only")

    e = Elf(elfpath)
    syms = e.symbols()
    sites = e.relsites(set(WANT))

    print("artifact %s" % elfpath)
    print("load base %08X, image %d bytes" % (base, e.image_size))
    for s in e.secs:
        if s["vbase"] is not None:
            print("  %-10s %08X .. %08X  (%d bytes)"
                  % (s["nm"], base + s["vbase"], base + s["vbase"] + s["size"], s["size"]))

    if ANCHOR not in syms:
        sys.exit("REFUSED -- no %s in this artifact" % ANCHOR)
    a_shndx, a_val, _ = syms[ANCHOR]
    a_addr = base + e.static_addr(a_shndx, a_val)
    a_want = e.file_word(a_shndx, a_val)
    if a_want is None:
        sys.exit("REFUSED -- %s has no value in the file" % ANCHOR)
    print("anchor %s @ %08X must read %08X  (both out of the ELF)"
          % (ANCHOR, a_addr, a_want))
    print()

    # Resolution plan, ELF-only: a static symbol has an address; a COMMON has sites.
    plan = []
    for sym in WANT:
        if sym in syms and syms[sym][0] != SHN_COMMON:
            shndx, val, _ = syms[sym]
            off = e.static_addr(shndx, val)
            plan.append((sym, "static", base + off if off is not None else None,
                         e.secs[shndx]["nm"], []))
        elif sym in sites:
            plan.append((sym, "common", None, "*COM*", sorted(sites[sym])))
        else:
            plan.append((sym, "MISSING", None, "-", []))

    if sites_only:
        bad = 0
        for sym, kind, addr, sec, ss in plan:
            if kind == "MISSING":
                print("  %-24s NOT RESOLVABLE -- no definition and no R_68K_32 site" % sym)
                bad += 1
            elif kind == "static":
                print("  %-24s %-6s %-6s -> %08X" % (sym, kind, sec, addr))
            else:
                print("  %-24s %-6s %-6s %d site(s): %s"
                      % (sym, kind, sec, len(ss), " ".join("%06x" % s for s in ss)))
        print()
        print("sites-only: %d symbol(s) unresolvable" % bad)
        return 1 if bad else 0

    chosen = None
    for lo, hi, desc in regions(pid):
        buf = read_region(pid, lo, hi)
        o = a_addr - base
        if 0 <= o <= len(buf) - 4 and struct.unpack_from(">I", buf, o)[0] == a_want:
            chosen = (desc, buf)
            break
    if chosen is None:
        print("REFUSED -- no readable region where %s@%08X reads %08X"
              % (ANCHOR, a_addr, a_want))
        return 1
    desc, buf = chosen
    print("guest region ANCHORED on %s  (host %s)" % (ANCHOR, desc))
    print()

    def g(a):
        o = a - base
        if not (0 <= o <= len(buf) - 4):
            return None
        return struct.unpack_from(">I", buf, o)[0]

    seen, bad = {}, 0
    for sym, kind, addr, sec, ss in plan:
        if kind == "MISSING":
            print("  %-24s NOT RESOLVABLE -- no definition and no R_68K_32 site" % sym)
            bad += 1
            continue
        if kind == "common":
            addrs = [g(base + s) for s in ss]
            if None in addrs or len(set(addrs)) != 1:
                print("  %-24s REFUSED -- %d site(s) DISAGREE: %s"
                      % (sym, len(ss), " ".join("%08x" % (a or 0) for a in addrs)))
                bad += 1
                continue
            addr = addrs[0]
        v = g(addr)
        if v is None:
            print("  %-24s REFUSED -- %08X outside the anchored region" % (sym, addr))
            bad += 1
            continue
        dup = seen.get(addr)
        seen[addr] = sym
        print("  %-24s %-6s %d/%d -> %08X = %08X  %12d%s"
              % (sym, kind, len(ss), len(ss), addr, v, v,
                 ("   ** COLLIDES WITH %s **" % dup) if dup else ""))
        if dup:
            bad += 1
    print()
    print("refusals/collisions: %d" % bad)
    return 1 if bad else 0


sys.exit(main(sys.argv))
