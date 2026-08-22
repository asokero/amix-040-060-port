#!/usr/bin/env python3
# prof-fixtures.py -- build the synthetic [PROF] captures that tools/test-prof-symbolize.sh
# runs against.
#
# usage:  python3 tools/prof-fixtures.py <output-directory>
#
# WHY A GENERATOR AND NOT CHECKED-IN FILES
#
# Every fixture here exists to encode ONE property that the symbolizer must get right, and a
# fixture whose property is not written down next to it decays into a blob nobody dares
# change.  Generating them puts the property, the numbers that produce it, and the expected
# consequence in the same place -- and leaves nothing in the working tree to go stale or to
# be swept into a commit by `git add -A`.
#
# Nothing here comes off a board.  The numbers are chosen so that the arithmetic the
# symbolizer does is checkable by hand:
#
#   capture-valid          a complete, self-consistent dump: drops=0, rec_count == samples,
#                          cyc_span exactly agreeing with the wall clock, a probe-landing
#                          model that reproduces TRANSITIONS to the digit.  Also carries the
#                          awkward-but-legal cases: an aliased symbol, a PC in .data, a
#                          saturated WEIGHT, reserved flag bits, and console traffic
#                          interleaved into the middle of the ring.
#   capture-weighted       the ranking INVERTS under weighting.  fixture_hot has 30 samples
#                          of weight 1; fixture_stall has 3 of weight 200.  A symbolizer
#                          that counts samples ranks fixture_hot first and is wrong.
#   capture-wrapped        drops > 0 AND cyc_span short by exactly 2^32.
#   capture-stopgap        divergence over 1% that is NOT a wrap -- the sampler was stopped
#                          before the dump, which is what the operator is told to do.
#   capture-truncated      rec_count lines promised, fewer delivered: lost serial lines.
#   capture-hdrmismatch    header rec_count and the `ring end n=` disagree.
#   capture-noend          the capture stops inside the ring.
#   capture-mangled        an `S` line that is not the frozen fixed-width form.
#   capture-badmagic       magic=Z3P2.
#   capture-badversion     version=2.
#   capture-badrecsize     rec_size=12.
#   capture-badmodel       TRANSITIONS the probe-landing model cannot reproduce.
#   capture-030            the 68030 path: tier-0 page-cache counters absent, not zero.
#   capture-stackovf       STACK_OVF non-zero, and a profiling build of the DIAGNOSTIC loop.
#
#   kernel.nm / kernel.elf the same symbol table two ways, so both symbol paths are
#                          exercised.  A branch that never ran is not a branch that works.

import os
import struct
import sys

CPU_HZ = 666666666
WALL_HZ = 333333333
HZ = 1000
PERIOD = 666666
RING_ENTRIES = 65536
BASE = 0x08000000

# ---------------------------------------------------------------------------- symbols
#
# Deliberately synthetic names.  They say what each symbol is FOR in the test, which is what
# an assertion wants to read, and they cannot be mistaken for a real kernel's symbol table.
TEXT_SIZE = 0x2000
DATA_SIZE = 0x400
BSS_SIZE = 0x200
SYMS = [
    # (offset in .text, name, global?)
    (0x0000, "fixture_hot", True),
    (0x0400, "fixture_stall", True),
    (0x0800, "fixture_mid", True),
    (0x0C00, "fixture_cold", True),
    (0x1000, "fixture_alias", True),     # two names at one address: the dedup rule must
    (0x1000, "fixture_alias_orig", False),  # prefer the global, deterministically
    (0x1C00, "fixture_edge", True),
]
DATA_SYMS = [(0x0000, "fixture_datum", "D"), (0x0000, "fixture_bssum", "B")]

BUCKET_NAMES = ["LOOP", "FETCHOP", "FETCHEX", "READ", "WRITE",
                "XLATE", "WALK", "HANDLER", "TAIL", "FAULT", "PROF"]
COUNTER_NAMES = ["INSNS", "INSNS_SUPER", "FETCH", "READ", "WRITE",
                 "IPAGE_HIT", "IPAGE_MISS", "DPAGE_RHIT", "DPAGE_RMISS",
                 "DPAGE_WHIT", "DPAGE_WMISS", "XLATE", "ATC_HIT", "ATC_MISS",
                 "MISALIGN_R", "MISALIGN_W", "FAULTS", "TRANSITIONS", "STACK_OVF"]

# Flag bases.  SUPER|MMU|AMIX|CPU040 is an AMIX kernel sample on the 68040 run loop.
K = 0x000F          # kernel:  SUPER MMU AMIX CPU040
U = 0x000A          # user:    MMU CPU040
R = 0x0009          # rom:     SUPER CPU040 -- AmigaOS supervisor, before AMIX is armed


def S(pc, op, base, weight):
    return "S %08x %04x %04x" % (pc, op, (base | (weight << 8)) & 0xFFFF)


# ------------------------------------------------------------------ the stage/counter dump

def counters(insns=1000000, fetch=1600000, read=700000, write=300000,
             ipage=(1560000, 40000), dpr=(680000, 20000), dpw=(290000, 10000),
             atc=(63000, 7000), misalign=(1200, 400), faults=25,
             transitions=None, stack_ovf=0, xlate=None):
    # XLATE is by definition the tier-0 miss traffic: a page-cache hit never reaches
    # mmu_translate.  On the 68030 path there is no tier 0 at all, so the caller passes
    # XLATE explicitly -- every access translates there.
    if xlate is None:
        xlate = ipage[1] + dpr[1] + dpw[1]
    if transitions is None:
        # The probe-landing model's own prediction: two transitions (an enter and an exit)
        # for every time a bucket is entered.  Setting TRANSITIONS to exactly this makes the
        # residual zero, which is what a real dump should be close to.
        entries = (insns                    # FETCHOP
                   + max(fetch - insns, 0)  # FETCHEX
                   + read + write
                   + xlate                  # XLATE
                   + atc[1]                 # WALK
                   + insns                  # HANDLER
                   + insns                  # TAIL
                   + faults)                # FAULT
        transitions = 2 * entries
    return [insns, int(insns * 0.35), fetch, read, write,
            ipage[0], ipage[1], dpr[0], dpr[1], dpw[0], dpw[1],
            xlate, atc[0], atc[1], misalign[0], misalign[1], faults,
            transitions, stack_ovf]


BUCKETS = [60000000, 120000000, 70000000, 150000000, 70000000,
           90000000, 40000000, 220000000, 68000000, 2000000, 10000000]


def fw_pct(part, whole):
    """The firmware's own integer percentage, reproduced so the fixture looks like a dump
    and not like something a float formatter produced."""
    if not whole:
        return "  0.00"
    h = part * 10000 // whole
    return "%3u.%02u" % (h // 100, h % 100)


def stats_dump(buckets=None, cnts=None, build=0x04, probe_cyc=11, hz=HZ):
    buckets = BUCKETS if buckets is None else buckets
    cnts = counters() if cnts is None else cnts
    total = sum(buckets)
    out = ["[PROF] === stage attribution ===",
           "[PROF] ver=1 build=0x%02X cpu_hz=%d hz=%d period_cyc=%d probe_cyc=%d"
           % (build, CPU_HZ, hz, PERIOD, probe_cyc)]
    wall_ticks = 500000000
    out.append("[PROF] total_cyc=%d wall_ticks=%d wall_hz=%d" % (total, wall_ticks, WALL_HZ))
    for i, name in enumerate(BUCKET_NAMES):
        out.append("[PROF] b %-2d %-8s cyc=%-16s %s%%"
                   % (i, name, buckets[i], fw_pct(buckets[i], total)))
    probe = cnts[17] * probe_cyc
    out.append("[PROF] probe overhead inside the totals: %d cyc = %s%% (%d transitions x "
               "%d cyc) -- subtract per bucket by its share of transitions"
               % (probe, fw_pct(probe, total).strip(), cnts[17], probe_cyc))
    out.append("[PROF] === counters ===")
    for i, name in enumerate(COUNTER_NAMES):
        out.append("[PROF] c %-2d %-12s %d" % (i, name, cnts[i]))
    ih, im = cnts[5], cnts[6]
    out.append("[PROF] r ipagecache hit %s%%" % fw_pct(ih, ih + im).strip())
    out.append("[PROF] r dpagecache read hit %s%%" % fw_pct(cnts[7], cnts[7] + cnts[8]).strip())
    out.append("[PROF] r dpagecache write hit %s%%" % fw_pct(cnts[9], cnts[9] + cnts[10]).strip())
    out.append("[PROF] r of %d translates, %s%% had to walk the tables"
               % (cnts[11], fw_pct(cnts[13], cnts[11]).strip()))
    out.append("[PROF] r supervisor instructions %s%% of %d"
               % (fw_pct(cnts[1], cnts[0]).strip(), cnts[0]))
    out.append("[PROF] === end ===")
    return out


# ------------------------------------------------------------------------- the ring dump

def ring_dump(samples, rec_count=None, promised=None, magic="Z3P1", version=1,
              rec_size=8, drops=0, taken=None, cyc_span=None, wall_ticks=None,
              build=0x04, hz=HZ, noise=(), noise_after=None, end=True):
    n = len(samples) if rec_count is None else rec_count
    taken = n if taken is None else taken
    if cyc_span is None:
        # Weight sums to the number of tick periods observed, and a tick is PERIOD cycles.
        w = 0
        for s in samples:
            w += (int(s.split()[3], 16) >> 8) & 0xFF or 1
        cyc_span = w * PERIOD
    if wall_ticks is None:
        wall_ticks = cyc_span * WALL_HZ // CPU_HZ
    out = ["[PROF] ring hdr magic=%s version=%d rec_size=%d rec_count=%d ring_entries=%d "
           "hz=%d period_cyc=%d cpu_hz=%d"
           % (magic, version, rec_size, n, RING_ENTRIES, hz, PERIOD, CPU_HZ),
           "[PROF] ring hdr samples=%d drops=%d cyc_span=%d wall_ticks=%d wall_hz=%d "
           "build=0x%02X" % (taken, drops, cyc_span, wall_ticks, WALL_HZ, build),
           "[PROF] ring begin"]
    for i, s in enumerate(samples):
        out.append(s)
        if noise and noise_after == i:
            out.extend(noise)
    if end:
        out.append("[PROF] ring end n=%d" % (n if promised is None else promised))
    return out


BOOT = ("[PROF] profiling build: ARM clock %d Hz (measured), enter/exit pair 11 cyc, "
        "ring %d x 8 B" % (CPU_HZ, RING_ENTRIES))
ARMED = "[PROF] armed: %d Hz (%d cyc/tick), buckets ON" % (HZ, PERIOD)


# ------------------------------------------------------------------------ sample sets

def valid_samples():
    s = []
    # fixture_hot: the busiest by SAMPLE COUNT, and not the busiest by weight.
    for i in range(20):
        s.append(S(BASE + 0x0010 + (i % 4) * 2, [0x4E71, 0x2F00, 0x6100, 0x4A80][i % 4], K, 1))
    for i in range(12):
        s.append(S(BASE + 0x0800 + i * 2, 0x41F9, K, 1))          # fixture_mid, LEA
    for i in range(5):
        s.append(S(BASE + 0x0C00 + i * 2, 0x4E75, K, 1))          # fixture_cold, RTS
    for i in range(4):
        s.append(S(BASE + 0x1000 + i * 2, 0xF4F8, K, 3))          # fixture_alias, CPUSH
    for i in range(3):
        s.append(S(BASE + 0x1C00 + i * 2, 0xE188, K, 1))          # fixture_edge, shift
    s.append(S(BASE + 0x2100, 0x4E71, K, 1))                      # a PC inside .data
    s.append(S(BASE + 0x0400, 0x4E72, K, 255))                    # fixture_stall, STOP, sat.
    s.append(S(BASE + 0x0040, 0x4E71, K | 0x0030, 1))             # reserved bits set
    for i in range(6):
        s.append(S(0x00012340 + i * 2, 0x2F00, U, 1))
    for i in range(4):
        s.append(S(0x00013010 + i * 2, 0xD081, U, 1))
    s.append(S(0x00F80020, 0x4EB9, R, 1))
    s.append(S(0x00F80022, 0x0000, R, 1))                         # opcode fetch faulted
    s.append(S(0x00F80024, 0x4E75, R, 1))
    return s


def weighted_samples():
    s = []
    for i in range(30):
        s.append(S(BASE + 0x0000 + (i % 8) * 2, 0x4E71, K, 1))    # fixture_hot   30 x 1
    for i in range(3):
        s.append(S(BASE + 0x0400 + i * 2, 0x4E72, K, 200))        # fixture_stall  3 x 200
    for i in range(10):
        s.append(S(BASE + 0x0800 + i * 2, 0x2F00, K, 1))          # fixture_mid   10 x 1
    return s


def small_samples(n):
    return [S(BASE + 0x0000 + (i % 16) * 2, 0x4E71, K, 1) for i in range(n)]


# ------------------------------------------------------------------------ symbol fixtures

def write_nm(path):
    lines = []
    for off, name, is_global in SYMS:
        lines.append("%08x %s %s" % (off, "T" if is_global else "t", name))
    for off, name, kind in DATA_SYMS:
        lines.append("%08x %s %s" % (off, kind, name))
    lines.append("         U fixture_undefined")   # must be skipped, not crash the parser
    with open(path, "w") as fh:
        fh.write("\n".join(lines) + "\n")


def write_elf(path):
    """A minimal big-endian m68k ET_REL image carrying the same symbols.

    Small enough to read, real enough that the symbolizer's own ELF parser -- the path used
    against a genuine build/unix-040 -- is exercised without a cross toolchain present."""
    shnames = [b"", b".text", b".data", b".bss", b".symtab", b".strtab", b".shstrtab"]
    shstr = b"\0"
    shoff_name = {}
    for nm in shnames[1:]:
        shoff_name[nm] = len(shstr)
        shstr += nm + b"\0"

    strtab = b"\0"
    syments = [b"\0" * 16]                     # the mandatory null symbol
    for off, name, is_global in SYMS:
        nameoff = len(strtab)
        strtab += name.encode() + b"\0"
        info = (1 << 4 | 2) if is_global else (0 << 4 | 2)     # GLOBAL/LOCAL, STT_FUNC
        syments.append(struct.pack(">IIIBBH", nameoff, off, 4, info, 0, 1))
    for off, name, kind in DATA_SYMS:
        nameoff = len(strtab)
        strtab += name.encode() + b"\0"
        shndx = 2 if kind == "D" else 3
        syments.append(struct.pack(">IIIBBH", nameoff, off, 4, 1 << 4 | 1, 0, shndx))
    symtab = b"".join(syments)

    o_text = 52
    o_data = o_text + TEXT_SIZE
    o_sym = o_data + DATA_SIZE
    o_str = o_sym + len(symtab)
    o_shstr = o_str + len(strtab)
    o_sh = o_shstr + len(shstr)

    # Elf32_Shdr: name type flags addr offset size link info addralign entsize
    shdrs = [(0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
             (shoff_name[b".text"], 1, 0x6, 0, o_text, TEXT_SIZE, 0, 0, 4, 0),
             (shoff_name[b".data"], 1, 0x3, 0, o_data, DATA_SIZE, 0, 0, 4, 0),
             (shoff_name[b".bss"], 8, 0x3, 0, o_sym, BSS_SIZE, 0, 0, 4, 0),
             (shoff_name[b".symtab"], 2, 0, 0, o_sym, len(symtab), 5, 1, 4, 16),
             (shoff_name[b".strtab"], 3, 0, 0, o_str, len(strtab), 0, 0, 1, 0),
             (shoff_name[b".shstrtab"], 3, 0, 0, o_shstr, len(shstr), 0, 0, 1, 0)]

    ehdr = (b"\x7fELF\x01\x02\x01" + b"\0" * 9
            + struct.pack(">HHIIIIIHHHHHH", 1, 4, 1, 0, 0, o_sh, 0, 52, 0, 0, 40, 7, 6))
    body = (ehdr + b"\0" * TEXT_SIZE + b"\0" * DATA_SIZE + symtab + strtab + shstr
            + b"".join(struct.pack(">IIIIIIIIII", *s) for s in shdrs))
    with open(path, "wb") as fh:
        fh.write(body)


# --------------------------------------------------------------------------------- main

def write(d, name, lines):
    with open(os.path.join(d, name), "w") as fh:
        fh.write("\r\n".join(lines) + "\r\n")     # serial captures carry CR LF


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: prof-fixtures.py <output-directory>\n")
        return 2
    d = sys.argv[1]
    os.makedirs(d, exist_ok=True)

    v = valid_samples()
    write(d, "capture-valid.txt",
          ["Z3660 firmware boot", BOOT, ARMED]
          + stats_dump()
          + ring_dump(v, noise=["[Z3660] piscsi: unit 6 read 4 blocks",
                                "z3660eth: link up 100BaseTX"], noise_after=25)
          + ["[PROF] stopped: %d samples, 0 dropped" % len(v)])

    write(d, "capture-weighted.txt", [BOOT] + ring_dump(weighted_samples()))

    # One capture, several dumps -- a real session takes PROFD then PROFR then more of both,
    # and a symbolizer that reports only the first or only the last silently drops a run.
    write(d, "capture-two.txt",
          [BOOT, ARMED] + stats_dump()
          + ring_dump(weighted_samples())
          + ["[PROF] armed: %d Hz (%d cyc/tick), buckets ON" % (HZ, PERIOD)]
          + ring_dump(valid_samples()))

    # A console log that never caught a dump.  Nothing to symbolize is an error, not an
    # empty report: an empty report looks like a result.
    write(d, "capture-nodumps.txt",
          ["Z3660 firmware boot", "[SD Init] OK", "Emulation mode 4",
           "68030 MMU enabled", "z3660eth: link up 100BaseTX"])

    # drops>0 and a cycle span exactly one PMCCNTR wrap short of the wall clock.
    wt = 41234567890 * WALL_HZ // CPU_HZ
    expected = wt * CPU_HZ // WALL_HZ
    write(d, "capture-wrapped.txt",
          [BOOT] + ring_dump(small_samples(40), drops=58775, taken=124311,
                             cyc_span=expected - (1 << 32), wall_ticks=wt))

    # Over 1% divergence that is NOT a wrap: 3 s of wall time after the last sample, which
    # is what stopping the sampler before dumping produces.
    wt2 = 10000000000 * WALL_HZ // CPU_HZ
    exp2 = wt2 * CPU_HZ // WALL_HZ
    write(d, "capture-stopgap.txt",
          [BOOT] + ring_dump(small_samples(40), cyc_span=exp2 - 3 * CPU_HZ, wall_ticks=wt2))

    # Truncation: 40 promised by both the header and the terminator, 33 delivered.
    write(d, "capture-truncated.txt",
          [BOOT] + ring_dump(small_samples(33), rec_count=40, promised=40))

    # Header and terminator disagree with each other.
    write(d, "capture-hdrmismatch.txt",
          [BOOT] + ring_dump(small_samples(37), rec_count=40, promised=37))

    # The capture stops inside the ring.
    write(d, "capture-noend.txt",
          [BOOT] + ring_dump(small_samples(20), rec_count=40, end=False))

    # A sample line that is not the frozen fixed-width form.
    bad = ring_dump(small_samples(10))
    bad[5] = "S 0800000 4e71 0101"
    write(d, "capture-mangled.txt", [BOOT] + bad)

    write(d, "capture-badmagic.txt", [BOOT] + ring_dump(small_samples(8), magic="Z3P2"))
    write(d, "capture-badversion.txt", [BOOT] + ring_dump(small_samples(8), version=2))
    write(d, "capture-badrecsize.txt", [BOOT] + ring_dump(small_samples(8), rec_size=12))

    # A TRANSITIONS count the probe-landing model cannot reproduce: the adjusted columns
    # must be withheld rather than printed from a model that does not hold.
    write(d, "capture-badmodel.txt",
          [BOOT] + stats_dump(cnts=counters(transitions=3000000)))

    # The 68030 path: tier-0 page-cache counters are absent upstream, not zero by accident.
    write(d, "capture-030.txt",
          [BOOT] + stats_dump(cnts=counters(ipage=(0, 0), dpr=(0, 0), dpw=(0, 0),
                                            xlate=2600000, atc=(2560000, 40000))))

    # STACK_OVF non-zero, in a profiling build of the DIAGNOSTIC loop rather than the lean
    # one -- two independent reasons to distrust the dump, and both must be said out loud.
    write(d, "capture-stackovf.txt",
          [BOOT] + stats_dump(cnts=counters(stack_ovf=3), build=0x07))

    write_nm(os.path.join(d, "kernel.nm"))
    write_elf(os.path.join(d, "kernel.elf"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
