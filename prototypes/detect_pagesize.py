#!/usr/bin/env python3
# detect_pagesize.py -- AUTO-DETECTOR for Model B (4KB page frame) byte-patch sites.
#
# Scans the WHOLE kernel .text disassembly for the PAGESIZE (2KB) idioms that Model B
# must flip to 4KB, attributes each hit to its function, applies the known
# false-positive exclusions, and annotates which hits are already COVERED by the two
# hand-built patch tables (patch_modelb.py = Tier-0/1, patch_modelb_pager.py = Tier-2)
# vs NEW.  Output is a review report + a ready-to-paste Python patch table for the NEW
# sites.  This tool DOES NOT patch -- it only reports.
#
# IDIOMS DETECTED (the 2KB page-size constants):
#   * #2047 / #-2047           page round-up / mask-1   (addil/andil/cmpil ...)
#   * #2048 / #-2048           page size / negative step (movel/addil/cmpil/addaw ...)
#   * @(-2048) / @(2048)       page-step DISPLACEMENT    (pea/lea/move ea)
#   * moveq #11,%dN  ... FOLLOWED BY a shift on %dN   = PAGESHIFT (btop/ptob)
#   * bf{extu,ins,clr,...} ...,O,21,...               = PTE pfn bitfield width 21 -> 20
#
# FALSE POSITIVES EXCLUDED (flagged, not emitted as NEW-to-patch):
#   * moveq #11 NOT followed by a shift          = NDADDR "12 direct blocks" / unrelated
#   * the PAGE_HASH >>11 in the hash functions   = uniform hash, MUST stay >>11
#       (page_find/page_enter/page_lookup/page_exists/page_hashin/page_hashout/
#        segmap_unlock@a901e) -- byte-identical to a real PAGESHIFT, only context tells
#   * bset/bclr/bchg/btst #17 / #21              = B_ flag bits, not a bitfield width
#   * moveq #9 (>>9 sector) / #13 (>>13 MAXBSIZE)= different value, never matched (we
#       only key on #11), listed here for the record.
#
# Usage:  python3 detect_pagesize.py [kernel]    (default: vanilla stock unix)
#         MODELB_DETECT_ALL=1  also lists COVERED sites (default: NEW + excluded only)

import re, sys, os, subprocess
import os

STOCK = os.environ.get("AMIX_ROOT", "") + "/stand/unix"   # AMIX_ROOT comes from config.sh
KERNEL = sys.argv[1] if len(sys.argv) > 1 else STOCK
OBJDUMP = "m68k-linux-gnu-objdump"
HERE = os.path.dirname(os.path.abspath(__file__))

# Hash functions whose `moveq #11 ; lsr` is the PAGE_HASH index (keep >>11).
HASH_FUNCS = set("""page_find page_enter page_lookup page_exists page_create
                    page_hashin page_hashout page_reclaim segmap_unlock
                    segmap_pagecreate""".split())
# segmap_pagecreate/segmap_unlock DO have real #2048 rounds too -- only their >>11
# (if any) is a hash term; we exclude only the PAGESHIFT class for HASH_FUNCS, never
# the immediate classes.

def known_vaddrs():
    """Parse the (0xVADDR, ...) entries from the two hand patch tables."""
    cov = {}
    for fn in ("patch_modelb.py", "patch_modelb_pager.py"):
        p = os.path.join(HERE, fn)
        if not os.path.exists(p): continue
        for m in re.finditer(r"\(0x([0-9a-fA-F]+),\s*b\"", open(p).read()):
            cov[int(m.group(1), 16)] = fn
    return cov

LINE = re.compile(r"^\s*([0-9a-f]+):\t([0-9a-f ]+?)\s*\t(.*)$")
HEAD = re.compile(r"^([0-9a-f]+) <([^>]+)>:")

def disasm(kernel):
    out = subprocess.check_output(
        [OBJDUMP, "-d", "-j", ".text", kernel], text=True)
    insns = []          # (vaddr, bytes_str, asm, func)
    func = "?"
    for ln in out.splitlines():
        h = HEAD.match(ln)
        if h:
            func = h.group(2).split("+")[0]
            continue
        m = LINE.match(ln)
        if not m: continue
        va = int(m.group(1), 16)
        by = m.group(2).replace(" ", "")
        asm = m.group(3).strip()
        # skip objdump's ".short"/".long" data-as-instruction noise
        if asm.startswith(".short") or asm.startswith(".long") or asm.startswith("Address"):
            insns.append((va, by, asm, func)); continue
        insns.append((va, by, asm, func))
    return insns

# immediate / displacement matchers on the disassembled operand text
IMM = re.compile(r"#(-?\d+)\b")
DISP = re.compile(r"@\((-?\d+)")
SHIFT = re.compile(r"^(ls[lr]|as[lr]|ro[lr]|rox[lr])[bwl]?\s")
BF = re.compile(r"^bf(extu|exts|ins|clr|set|tst)\b")

# Confidence model.  A bare positive #2048 (=0x800=bit 11) is an extremely common
# FLAG bit (DMACON DMAEN, STREAMS msg flags, ...), NOT a page size.  So we use two
# passes: a function is "page-touching" only if it contains a HIGH-confidence page
# idiom (#2047, #-2047, #-2048 mask/step, DISP +/-2048, PAGESHIFT non-hash, bitfield
# width 21).  Bare positive #2048 (page-size as a size arg / compare) is accepted ONLY
# inside page-touching functions; elsewhere it is dropped as a flag bit.
HIGH_IMMS = {2047, -2047, -2048}     # these decimals are page-specific (0x7ff/0xf800)

def first_pass(insns):
    """Return (hits, pagefuncs): high-confidence hits + the set of page-touching funcs."""
    hits = []; pagefuncs = set()
    for i, (va, by, asm, func) in enumerate(insns):
        nxt = insns[i+1][2] if i+1 < len(insns) else ""
        # --- PAGESHIFT: moveq #11,%dN followed by a shift on %dN ---
        m = re.match(r"moveq #11,%(d[0-7])", asm)
        if m:
            reg = m.group(1)
            if SHIFT.match(nxt) and ("%"+reg) in nxt.split(",")[0]:
                if func in HASH_FUNCS:
                    hits.append((va,"PAGESHIFT",asm,func,"EXCLUDE:page_hash>>11 -> next:"+nxt))
                else:
                    hits.append((va,"PAGESHIFT",asm,func,"next:"+nxt)); pagefuncs.add(func)
            else:
                hits.append((va,"moveq#11",asm,func,"EXCLUDE:not-shift -> next:"+nxt))
            continue
        # --- bitfield width 21 (PTE pfn field) ---
        if BF.match(asm) and (re.search(r",\s*21\b", asm) or re.search(r":21\b", asm)):
            hits.append((va,"BITFLD21",asm,func,"width 21->20")); pagefuncs.add(func); continue
        if re.match(r"b(set|clr|chg|tst)", asm):
            continue
        # --- high-confidence immediates ---
        got = False
        for mm in IMM.finditer(asm):
            v = int(mm.group(1))
            if v in HIGH_IMMS:
                hits.append((va,"IMM%d"%v,asm,func,"")); pagefuncs.add(func); got=True; break
        if got: continue
        # --- displacement -2048 page step (only NEGATIVE: a backward page step like
        #     pvn_kluster's pea -2048(a0).  POSITIVE @(2048) is a struct field offset,
        #     e.g. coffcore's %a2@(2048) -- NOT a page step) ---
        for mm in DISP.finditer(asm):
            if int(mm.group(1)) == -2048:
                hits.append((va,"DISP-2048",asm,func,"")); pagefuncs.add(func); break
    return hits, pagefuncs

def second_pass(insns, pagefuncs):
    """Bare positive #2048 (page size as size/compare arg), only in page-touching funcs."""
    hits = []
    for va, by, asm, func in insns:
        if func not in pagefuncs:
            continue
        if re.match(r"b(set|clr|chg|tst)", asm) or BF.match(asm):
            continue
        for mm in IMM.finditer(asm):
            if int(mm.group(1)) == 2048:
                hits.append((va,"IMM2048",asm,func,"size/cmp (page-touching fn)")); break
    return hits

def classify(insns):
    h1, pagefuncs = first_pass(insns)
    h2 = second_pass(insns, pagefuncs)
    return sorted(h1 + h2)

def main():
    cov = known_vaddrs()
    insns = disasm(KERNEL)
    hits = classify(insns)
    show_all = os.environ.get("MODELB_DETECT_ALL")

    by_func = {}
    for va, cls, asm, func, note in hits:
        by_func.setdefault(func, []).append((va, cls, asm, note))

    n_new = n_cov = n_excl = 0
    new_sites = []
    print("=== Model B PAGESIZE auto-detector: %s ===" % KERNEL)
    print("    legend: [C]=covered by a patch table  [N]=NEW  [X]=excluded false-positive\n")
    for func in sorted(by_func, key=lambda f: min(h[0] for h in by_func[f])):
        rows = sorted(by_func[func])
        # decide if the function has any actionable (non-excluded) hit
        act = [r for r in rows if not r[3].startswith("EXCLUDE")]
        if not act and not show_all:
            # function only has excluded hits -- still show a one-liner for the record
            n_excl += len(rows)
            print("  %-22s : %d excluded-only (moveq#11 NDADDR / hash)" % (func, len(rows)))
            continue
        print("  %s:" % func)
        for va, cls, asm, note in rows:
            if note.startswith("EXCLUDE"):
                tag = "X"; n_excl += 1
            elif va in cov:
                tag = "C"; n_cov += 1
                if not show_all:
                    continue
            else:
                tag = "N"; n_new += 1
                new_sites.append((va, cls, asm, func))
            print("    [%s] %06x  %-9s  %-32s %s" % (tag, va, cls, asm, note))
    print("\n=== SUMMARY: %d NEW, %d covered, %d excluded ===" % (n_new, n_cov, n_excl))

    if new_sites:
        print("\n=== NEW sites (review, then add to a Tier-3 patch table) ===")
        for va, cls, asm, func in new_sites:
            print("  0x%05x  %-9s  %-30s  # %s" % (va, cls, asm, func))

main()
