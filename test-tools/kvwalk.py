#!/usr/bin/env python3
"""kvwalk.py -- walk the LIVE 040 kernel translation chain for a kernel VA via
Amiberry IPC READ_MEM (non-halting), root -> pointer -> leaf, and decode the pfn.

Built for the ISSUE-10 memwatch hunt: a COPYIN into kvseg VA 0x404F2xxx was seen
landing in sh's data frame 0x9E19000 => suspicion that a kvseg leaf PTE holds the
WRONG PFN (KMA/STREAMS buffer double-backing).  This tool answers "what does the
kvseg chain for VA X say RIGHT NOW, and does the leaf pfn == sh's data frame?"

Tables (src/pstart040.s): kroot040/kptr040 are .data globals holding the
PHYS bases of the kernel root table and the contiguous pointer-table region for
root entries 32..63 (kvseg).  Kernel phys base 0x08000000 (identity DTT0), so a
.data symbol at nm-offset D reads at 0x08000000 + .text-size + D.

BUILD-SPECIFIC defaults below are for unix-040-dbg build 260717-06
(.text 0xdd090; nm: kptr040=0xfed4 kroot040=0xfed8 g_shdatabase=0x18af0).
Override with env KVWALK_TEXTSIZE / KVWALK_KPTR / KVWALK_KROOT / KVWALK_SHDATA
(nm section offsets) after a relink changes the layout.

Usage: kvwalk.py 0x404F2000 [more VAs...]
"""
import os, socket, sys

SOCK = "/run/user/12044/amiberry.sock"
KBASE = 0x08000000

TEXTSIZE = int(os.environ.get("KVWALK_TEXTSIZE", "0xdd090"), 0)
OFF_KPTR = int(os.environ.get("KVWALK_KPTR", "0xfed4"), 0)
OFF_KROOT = int(os.environ.get("KVWALK_KROOT", "0xfed8"), 0)
OFF_SHDATA = int(os.environ.get("KVWALK_SHDATA", "0x18af0"), 0)

ADDR_KPTR = KBASE + TEXTSIZE + OFF_KPTR
ADDR_KROOT = KBASE + TEXTSIZE + OFF_KROOT
ADDR_SHDATA = KBASE + TEXTSIZE + OFF_SHDATA


def ipc(cmd):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK)
    s.sendall((cmd + "\n").encode())
    s.settimeout(3)
    try:
        r = s.recv(4096)
    except socket.timeout:
        r = b""
    s.close()
    return r.decode("latin1", "replace").strip()


def read32(addr):
    r = ipc("READ_MEM\t0x%08X\t4" % addr)
    parts = r.split("\t")
    if len(parts) < 2 or parts[0] != "OK":
        raise RuntimeError("READ_MEM 0x%08X failed: %r" % (addr, r))
    return int(parts[1]) & 0xFFFFFFFF


UDT = {0: "INVALID", 1: "INVALID", 2: "RESIDENT", 3: "RESIDENT"}
PDT = {0: "INVALID", 1: "RESIDENT", 2: "INDIRECT", 3: "RESIDENT"}


def walk(va, kroot, kptr, quiet=False):
    """Walk va through the kernel tree; returns (leaf_pte, pfn) or (None, None)."""
    ri = (va >> 25) & 0x7F
    pi = (va >> 18) & 0x7F
    li = (va >> 12) & 0x3F
    rdesc_a = kroot + ri * 4
    rdesc = read32(rdesc_a)
    out = ["VA 0x%08X  idx root=%d ptr=%d leaf=%d" % (va, ri, pi, li),
           "  root  @0x%08X = 0x%08X  [%s]" % (rdesc_a, rdesc, UDT[rdesc & 3])]
    if (rdesc & 3) < 2:
        if not quiet:
            print("\n".join(out) + "\n  -- STOP: root descriptor invalid")
        return None, None
    ptab = rdesc & 0xFFFFFE00
    pdesc_a = ptab + pi * 4
    # cross-check against the kvm_init fill formula for the kvseg region
    if 32 <= ri < 64:
        alt = kptr + ((va >> 18) - 4096) * 4
        mark = "" if alt == pdesc_a else "  !! MISMATCH kptr040-formula=0x%08X" % alt
    else:
        mark = "  (outside kptr040 region)"
    pdesc = read32(pdesc_a)
    out.append("  ptr   @0x%08X = 0x%08X  [%s]%s" % (pdesc_a, pdesc, UDT[pdesc & 3], mark))
    if (pdesc & 3) < 2:
        if not quiet:
            print("\n".join(out) + "\n  -- STOP: pointer descriptor invalid")
        return None, None
    ltab = pdesc & 0xFFFFFF00
    lpte_a = ltab + li * 4
    pte = read32(lpte_a)
    pfn = pte >> 12
    out.append("  leaf  @0x%08X = 0x%08X  [%s]  pfn=0x%X phys=0x%08X flags=0x%03X"
               % (lpte_a, pte, PDT[pte & 3], pfn, pfn << 12, pte & 0xFFF))
    if not quiet:
        print("\n".join(out))
    return pte, pfn


def main():
    vas = [int(a, 0) for a in sys.argv[1:]] or [0x404F2000]
    kroot = read32(ADDR_KROOT)
    kptr = read32(ADDR_KPTR)
    shdata = read32(ADDR_SHDATA)
    print("kroot040=0x%08X kptr040=0x%08X g_shdatabase=0x%08X (sh pfn 0x%X)"
          % (kroot, kptr, shdata, shdata >> 12))
    for va in vas:
        pte, pfn = walk(va, kroot, kptr)
        if pfn is not None and pfn == (shdata >> 12):
            print("  ** LEAF PFN == SH DATA FRAME (0x%X) -- the wrong-PFN aliasing is LIVE **" % pfn)


if __name__ == "__main__":
    main()
