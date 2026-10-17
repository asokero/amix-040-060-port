#!/usr/bin/env python3
# kelf.py -- the ET_REL reader the relink patchers share: section headers, symbols, the
# relocations of one section, and .text bytes, from a kernel image read big-endian.
#
# The RTH1, page-out reserve and ISP patchers use it.  It is the reader the driver line's a4091
# pass carries, split out so those patchers run on a tree that does not have that pass.
# Read-only: a patcher edits e.b itself and writes the file back.

import struct

R_68K_32, STT_SECTION = 1, 3


def u16(b, o): return struct.unpack(">H", b[o:o + 2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o + 4])[0]
def i32(b, o): return struct.unpack(">i", b[o:o + 4])[0]


class Elf(object):
    def __init__(self, path):
        self.b = bytearray(open(path, "rb").read())
        b = self.b
        so, se, sn, ss = u32(b, 32), u16(b, 46), u16(b, 48), u16(b, 50)
        self.sh = [dict(name=u32(b, so + i * se), offset=u32(b, so + i * se + 16),
                        size=u32(b, so + i * se + 20), link=u32(b, so + i * se + 24),
                        entsize=u32(b, so + i * se + 36)) for i in range(sn)]
        base = self.sh[ss]["offset"]
        self.names = [b[base + s["name"]:b.index(b"\0", base + s["name"])].decode() for s in self.sh]
        self.sec = dict(zip(self.names, self.sh))
        st = self.sec[".symtab"]
        self.syo, self.sye, self.syn = st["offset"], st["entsize"], st["size"] // st["entsize"]
        self.stro = self.sh[st["link"]]["offset"]

    def sym(self, i):
        o = self.syo + i * self.sye
        n = u32(self.b, o)
        return dict(name=self.b[self.stro + n:self.b.index(b"\0", self.stro + n)].decode("latin1"),
                    value=u32(self.b, o + 4), info=self.b[o + 12], shndx=u16(self.b, o + 14))

    def index(self, name):
        for i in range(self.syn):
            s = self.sym(i)
            if s["name"] == name and s["shndx"] != 0:
                return i
        raise SystemExit("ABORT: no defined symbol %s" % name)

    def rela(self, secname):
        s = self.sec[secname]
        out = {}
        for i in range(s["size"] // s["entsize"]):
            o = s["offset"] + i * s["entsize"]
            info = u32(self.b, o + 4)
            out[u32(self.b, o)] = (o, info >> 8, info & 0xFF, i32(self.b, o + 8))
        return out

    def target(self, symidx, addend):
        """(section, offset, symbol name, is_global_named)"""
        s = self.sym(symidx)
        sec = self.names[s["shndx"]] if 0 < s["shndx"] < len(self.names) else None
        if s["info"] & 0xF == STT_SECTION:
            return sec, addend, None, False
        return sec, s["value"] + addend, s["name"], (s["info"] >> 4) == 1 and addend == 0

    def text(self, off, n):
        t = self.sec[".text"]["offset"]
        return bytes(self.b[t + off:t + off + n])
