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
#   capture-badmagic       magic=Z3P2 in a version=1 header: the two disagree.
#   capture-badversion     version=9: a version no firmware has ever emitted.
#   capture-badrecsize     rec_size=12.
#   capture-badmodel       TRANSITIONS the probe-landing model cannot reproduce.
#   capture-030            the 68030 path: tier-0 page-cache counters absent, not zero.
#   capture-stackovf       STACK_OVF non-zero, and a profiling build of the DIAGNOSTIC loop.
#   capture-dirty          INTACT but delivered dirty, exactly as the metal captures were:
#                          a logger timestamp on every line AND a `ring hdr` line whose
#                          literal "[PROF] " the UART ate, run together with the console
#                          echo ahead of it.  Same bytes as capture-valid otherwise, so the
#                          repaired report must be identical to capture-valid's.
#   capture-hdrgone        the same header damage with a FIELD missing from the payload:
#                          not repairable, and must still be refused.
#   capture-atcbroken      ATC_HIT + FAULTS != XLATE.
#   capture-tier0broken    IPAGE_MISS + DPAGE_RMISS + DPAGE_WMISS != XLATE.
#
# WIRE VERSION 2 -- the same discipline against the three numbers v1 mislabelled.  Each of
# these is built so that a tool still applying v1's rules produces a DIFFERENT answer rather
# than an error, because that is the failure mode being guarded against:
#
#   capture-v2valid        a complete v2 capture: probe priced per TRANSITION, the tail
#                          split four ways summing to 20.00%, id 12 XLATE_OK and id 19 a
#                          real ATC_HIT with DIFFERENT values, and a probe-landing model
#                          that reproduces TRANSITIONS to the digit.
#   capture-v2bsp          clk=bsp -- the clock is the compile-time BSP constant and the
#                          wrap cross-check is structurally blind to it.
#   capture-v2clkodd       a clk= value no version defines: unsafe by default, but named as
#                          unrecognised rather than reported as `bsp`.
#   capture-v2probeover    TRANSITIONS x probe_cyc EXCEEDS total_cyc.  v2 must withhold and
#                          report; clamping is what made v1's 2x over-pricing look like a
#                          result.
#   capture-v2tailmismatch the firmware's own '[PROF] t' line disagreeing with the four
#                          bucket rows it is computed from.
#   capture-v2atcbroken    ATC_HIT + ATC_MISS EXCEEDING XLATE: a partition summing to more
#                          than the set it partitions.
#   capture-v2atcshort     the same sum SHORT by more than FAULTS.  A shortfall is legal
#                          (translates that faulted before the walk decision) but is bounded
#                          by FAULTS, because every one of them threw.
#   capture-v2-030         the 68030 path: no tier-0 counters AND no XLATE_OK site.  Both
#                          read zero and zero means ABSENT -- a printed "0.00% returned an
#                          address" would claim every translate faulted.
#
#   capture-v2magic1       version=2 carrying magic=Z3P1.
#   capture-v1v2grammar    ver=2 written in the version-1 grammar.
#   capture-v2v1grammar    ver=1 written in the version-2 grammar.  All three are captures
#                          that answer the version question twice and disagree with
#                          themselves; none is corrupt, and all must be refused rather than
#                          resolved in favour of one field.
#   capture-v2bootv1       a v1 boot line above a v2 dump with no probe_cyc of its own --
#                          one capture spanning a reflash.  The boot line's per-PAIR figure
#                          must NOT be fed to a per-TRANSITION rule.
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

# Version 2 renames two ids and appends four.  The generator carries BOTH name tables in
# full rather than patching one into the other, because the symbolizer's name-drift check
# compares them entry for entry -- and a fixture built by mutating the v1 list would agree
# with a tool that had made the same mutation, which is not a test of anything.
BUCKET_NAMES_V2 = ["LOOP", "FETCHOP", "FETCHEX", "READ", "WRITE",
                   "XLATE", "WALK", "HANDLER", "TAILADV", "FAULT", "PROF",
                   "TAILSAMP", "TAILPOLL", "TAILSPEC"]
COUNTER_NAMES_V2 = ["INSNS", "INSNS_SUPER", "FETCH", "READ", "WRITE",
                    "IPAGE_HIT", "IPAGE_MISS", "DPAGE_RHIT", "DPAGE_RMISS",
                    "DPAGE_WHIT", "DPAGE_WMISS", "XLATE", "XLATE_OK", "ATC_MISS",
                    "MISALIGN_R", "MISALIGN_W", "FAULTS", "TRANSITIONS", "STACK_OVF",
                    "ATC_HIT"]
MAGICS = {1: "Z3P1", 2: "Z3P2"}

# Flag bases.  SUPER|MMU|AMIX|CPU040 is an AMIX kernel sample on the 68040 run loop.
K = 0x000F          # kernel:  SUPER MMU AMIX CPU040
U = 0x000A          # user:    MMU CPU040
R = 0x0009          # rom:     SUPER CPU040 -- AmigaOS supervisor, before AMIX is armed


def S(pc, op, base, weight):
    return "S %08x %04x %04x" % (pc, op, (base | (weight << 8)) & 0xFFFF)


# ------------------------------------------------------------------ the stage/counter dump

def counters(insns=1000000, fetch=1600000, read=700000, write=300000,
             ipage=(1560000, 40000), dpr=(680000, 20000), dpw=(290000, 10000),
             walks=7000, misalign=(1200, 400), faults=25,
             transitions=None, stack_ovf=0, xlate=None, atc_hit=None):
    # XLATE is by definition the tier-0 miss traffic: a page-cache hit never reaches
    # mmu_translate.  On the 68030 path there is no tier 0 at all, so the caller passes
    # XLATE explicitly -- every access translates there.
    if xlate is None:
        xlate = ipage[1] + dpr[1] + dpw[1]
    # ATC_HIT is misnamed in the version-1 wire format: it counts translates that
    # SUCCEEDED, so ATC_HIT + FAULTS == XLATE and it carries no ATC information at all.
    # The fixtures encode that, because a fixture that encoded the name instead would make
    # the tool's cross-check pass on data no firmware produces.  `walks` (ATC_MISS) is the
    # independent quantity, and the real ATC hit rate is (XLATE - ATC_MISS) / XLATE.
    if atc_hit is None:
        atc_hit = xlate - faults
    if transitions is None:
        # The probe-landing model's own prediction: two transitions (an enter and an exit)
        # for every time a bucket is entered.  Setting TRANSITIONS to exactly this makes the
        # residual zero, which is what a real dump should be close to.
        entries = (insns                    # FETCHOP
                   + max(fetch - insns, 0)  # FETCHEX
                   + read + write
                   + xlate                  # XLATE
                   + walks                  # WALK
                   + insns                  # HANDLER
                   + insns                  # TAIL
                   + faults)                # FAULT
        transitions = 2 * entries
    return [insns, int(insns * 0.35), fetch, read, write,
            ipage[0], ipage[1], dpr[0], dpr[1], dpw[0], dpw[1],
            xlate, atc_hit, walks, misalign[0], misalign[1], faults,
            transitions, stack_ovf]


def counters_v2(insns=1000000, fetch=1600000, read=700000, write=300000,
                ipage=(1560000, 40000), dpr=(680000, 20000), dpw=(290000, 10000),
                walks=7000, misalign=(1200, 400), faults=25,
                transitions=None, stack_ovf=0, xlate=None, xlate_ok=None, atc_hit=None):
    """The version-2 counter block: id 12 is XLATE_OK, id 19 is a REAL ATC_HIT.

    The two are given SEPARATE defaults on purpose, and they differ, because that
    difference is the whole v1 defect:

        XLATE_OK = XLATE - FAULTS      translates that returned an address
        ATC_HIT  = XLATE - ATC_MISS    translates served without a walk

    In v1 the second quantity did not exist and the first was printed under its name.  A
    fixture that set them equal would let a tool reading id 12 as an ATC rate pass, which is
    exactly the bug being guarded against."""
    if xlate is None:
        xlate = ipage[1] + dpr[1] + dpw[1]
    if xlate_ok is None:
        xlate_ok = xlate - faults
    if atc_hit is None:
        atc_hit = xlate - walks
    if transitions is None:
        # v2 nests TAILSAMP and TAILPOLL inside the tail and both are entered once per
        # instruction, so the split adds exactly four transitions per instruction to v1's
        # count -- which is the figure the firmware's own documentation prices it at.
        entries = (insns                    # FETCHOP
                   + max(fetch - insns, 0)  # FETCHEX
                   + read + write
                   + xlate                  # XLATE
                   + walks                  # WALK
                   + insns                  # HANDLER
                   + insns                  # TAILADV
                   + faults                 # FAULT
                   + insns                  # TAILSAMP
                   + insns)                 # TAILPOLL   (TAILSPEC is spcflags-gated: 0)
        transitions = 2 * entries
    return [insns, int(insns * 0.35), fetch, read, write,
            ipage[0], ipage[1], dpr[0], dpr[1], dpw[0], dpw[1],
            xlate, xlate_ok, walks, misalign[0], misalign[1], faults,
            transitions, stack_ovf, atc_hit]


BUCKETS = [60000000, 120000000, 70000000, 150000000, 70000000,
           90000000, 40000000, 220000000, 68000000, 2000000, 10000000]

# The v2 bucket set is NOT the v1 one with the tail split: it is sized so that the probe
# subtraction at a realistic per-transition price leaves every bucket positive, because the
# clean case has to be clean before an over-priced one means anything.  v2 carries ~43%
# more transitions than v1 for the same work (the tail split's four per instruction), so a
# fixture that reused v1's cycle totals would clamp on arrival and never exercise the
# ordinary path.  The whole tail is 400M of 2000M = exactly 20.00%, which is the share the
# C2 attack map measured and could not break down.
BUCKETS_V2 = [420000000, 200000000, 110000000, 260000000, 120000000,
              90000000, 40000000, 340000000, 150000000, 8000000, 12000000,
              120000000, 110000000, 20000000]
PROBE_CYC_V2 = 46          # per TRANSITION; metal's own figure, and inside the 45.5..58
                           # window the firmware's documentation predicts


def fw_pct(part, whole):
    """The firmware's own integer percentage, reproduced so the fixture looks like a dump
    and not like something a float formatter produced."""
    if not whole:
        return "  0.00"
    h = part * 10000 // whole
    return "%3u.%02u" % (h // 100, h % 100)


def stats_dump(buckets=None, cnts=None, build=0x04, probe_cyc=11, hz=HZ, version=1):
    buckets = BUCKETS if buckets is None else buckets
    cnts = counters() if cnts is None else cnts
    total = sum(buckets)
    out = ["[PROF] === stage attribution ===",
           "[PROF] ver=%d build=0x%02X cpu_hz=%d hz=%d period_cyc=%d probe_cyc=%d"
           % (version, build, CPU_HZ, hz, PERIOD, probe_cyc)]
    wall_ticks = 500000000
    out.append("[PROF] total_cyc=%d wall_ticks=%d wall_hz=%d" % (total, wall_ticks, WALL_HZ))
    for i, name in enumerate(BUCKET_NAMES):
        out.append("[PROF] b %-2d %-8s cyc=%-16s %s%%"
                   % (i, name, buckets[i], fw_pct(buckets[i], total)))
    # The firmware's own overhead line, reproduced with its own 2x over-pricing:
    # probe_cyc prices an enter/exit PAIR while TRANSITIONS counts each enter and each exit,
    # so TRANSITIONS x probe_cyc counts every pair twice.  The fixture carries what the
    # firmware really prints; the symbolizer is what has to be right about it.
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


def stats_dump_v2(buckets=None, cnts=None, build=0x04, probe_cyc=PROBE_CYC_V2, hz=HZ,
                  clk="cfg", version=2, tail_cyc=None, grammar=2):
    """The version-2 PROFD block, emitted exactly as the firmware writes it.

    `grammar` exists to build the one capture that must be REFUSED without being corrupt:
    a dump whose `ver=` line declares one version while being written in the other's
    format.  That is not a hypothetical -- it is what a hand-edited capture, or a fixture
    generator that bumped a number without bumping a format, produces -- and the two
    grammars price `probe_cyc` in different units, so a reader that reconciles them instead
    of refusing gets a plausible number rather than an error."""
    buckets = BUCKETS_V2 if buckets is None else buckets
    cnts = counters_v2() if cnts is None else cnts
    total = sum(buckets)
    # Sized so the buckets account for 90% of the elapsed span, same shape as the v1
    # fixture: a run-loop residency of exactly 100% would say core1 never once left the run
    # loop, which no real capture shows and which would make the shape check meaningless.
    wall_ticks = 1111111111
    out = ["[PROF] === stage attribution ==="]
    if grammar == 2:
        out.append("[PROF] ver=%d build=0x%02X cpu_hz=%d clk=%s hz=%d period_cyc=%d "
                   "probe_cyc_per_transition=%d"
                   % (version, build, CPU_HZ, clk, hz, PERIOD, probe_cyc))
    else:
        out.append("[PROF] ver=%d build=0x%02X cpu_hz=%d hz=%d period_cyc=%d probe_cyc=%d"
                   % (version, build, CPU_HZ, hz, PERIOD, probe_cyc))
    out.append("[PROF] total_cyc=%d wall_ticks=%d wall_hz=%d" % (total, wall_ticks, WALL_HZ))
    for i, name in enumerate(BUCKET_NAMES_V2):
        out.append("[PROF] b %-2d %-8s cyc=%-16s %s%%"
                   % (i, name, buckets[i], fw_pct(buckets[i], total)))
    # The whole-tail rollup: the firmware's OWN sum of ids 8+11+12+13, printed so a v2
    # capture can be laid beside a v1 one.  `tail_cyc` overrides it to build the capture
    # where that line and the bucket rows disagree -- which cannot happen on a board and is
    # therefore proof the two came off different states.
    tail = sum(buckets[i] for i in (8, 11, 12, 13)) if tail_cyc is None else tail_cyc
    out.append("[PROF] t whole tail (TAILADV+TAILSAMP+TAILPOLL+TAILSPEC) cyc=%d %s%% "
               "-- this is what v1 reported as TAIL" % (tail, fw_pct(tail, total)))
    # PER TRANSITION in v2, and the firmware's line and this tool's arithmetic agree.
    # Omitted entirely when there is no calibration, exactly as the firmware omits it.
    probe = cnts[17] * probe_cyc
    if probe_cyc > 0 and total:
        out.append("[PROF] probe overhead inside the totals: %d cyc = %s%% (%d transitions "
                   "x %d cyc/TRANSITION, out-of-line calibrated) -- subtract per bucket by "
                   "its share of transitions" % (probe, fw_pct(probe, total).strip(),
                                                 cnts[17], probe_cyc))
        if probe > total:
            out.append("[PROF] WARNING: the modelled probe cost EXCEEDS the measured total. "
                       "The calibration or the transition count is wrong; do not subtract.")
    out.append("[PROF] === counters ===")
    for i, name in enumerate(COUNTER_NAMES_V2):
        out.append("[PROF] c %-2d %-12s %d" % (i, name, cnts[i]))
    ih, im = cnts[5], cnts[6]
    out.append("[PROF] r ipagecache hit %s%%" % fw_pct(ih, ih + im).strip())
    out.append("[PROF] r dpagecache read hit %s%%" % fw_pct(cnts[7], cnts[7] + cnts[8]).strip())
    out.append("[PROF] r dpagecache write hit %s%%" % fw_pct(cnts[9], cnts[9] + cnts[10]).strip())
    xl, xo, am, ah = cnts[11], cnts[12], cnts[13], cnts[19]
    out.append("[PROF] r of %d translates, %s%% had to walk the tables"
               % (xl, fw_pct(am, xl).strip()))
    out.append("[PROF] r ...and %s%% were satisfied from the ATC without a walk"
               % fw_pct(ah, xl).strip())
    # Silent on the 68030, where XLATE_OK has no site at all.  A printed 0.00% would read
    # as "every translate faulted", which is a worse answer than no answer.
    if xo:
        out.append("[PROF] r ...and %s%% returned an address (the rest faulted)"
                   % fw_pct(xo, xl).strip())
    if xl and ah + am != xl:
        out.append("[PROF] r note: ATC_HIT+ATC_MISS=%d vs XLATE=%d -- the difference is "
                   "translates that faulted before the walk decision" % (ah + am, xl))
    out.append("[PROF] r supervisor instructions %s%% of %d"
               % (fw_pct(cnts[1], cnts[0]).strip(), cnts[0]))
    out.append("[PROF] === end ===")
    return out


# ------------------------------------------------------------------------- the ring dump

def ring_dump(samples, rec_count=None, promised=None, magic=None, version=1,
              rec_size=8, drops=0, taken=None, cyc_span=None, wall_ticks=None,
              build=0x04, hz=HZ, noise=(), noise_after=None, end=True,
              probe_cyc=PROBE_CYC_V2, clk="cfg"):
    # The magic ENCODES the version, so it defaults from it and is only ever passed
    # explicitly to build a header that contradicts itself -- which is a case the
    # symbolizer must refuse rather than resolve in favour of one field.
    # A version with no magic of its own (9, say) gets "Z3P" + digit anyway, so that the
    # unknown-version fixture is refused for its VERSION and not incidentally for its magic.
    magic = MAGICS.get(version, "Z3P%d" % version) if magic is None else magic
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
    # v2 spends v1's two reserved header words on probe_cyc and clk_src; the header stays
    # 80 bytes and every earlier field keeps its offset, so the ASCII line is purely
    # additive after `build=`.
    tail = (" probe_cyc=%d clk=%s" % (probe_cyc, clk)) if version >= 2 else ""
    out = ["[PROF] ring hdr magic=%s version=%d rec_size=%d rec_count=%d ring_entries=%d "
           "hz=%d period_cyc=%d cpu_hz=%d"
           % (magic, version, rec_size, n, RING_ENTRIES, hz, PERIOD, CPU_HZ),
           "[PROF] ring hdr samples=%d drops=%d cyc_span=%d wall_ticks=%d wall_hz=%d "
           "build=0x%02X%s" % (taken, drops, cyc_span, wall_ticks, WALL_HZ, build, tail),
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


def boot_v2(clk="cfg", probe_cyc=PROBE_CYC_V2):
    """The v2 boot line: every unit spelled out and the clock's SOURCE on it.

    Both were scars.  v1 printed `enter/exit pair 91 cyc` next to a per-transition count,
    and `ARM clock 666667585 Hz (measured)` seven seconds after the same console announced
    a PLL configured for 1100 MHz.  Neither was catchable from the line itself, and the
    line is the only place a reader looks."""
    lines = ["[PROF] profiling build v2: ARM clock %d Hz (clk=%s, PMU:wall 2.00), "
             "probe %d cyc/transition (%d cyc/pair), ring %d x 8 B"
             % (CPU_HZ, clk, probe_cyc, probe_cyc * 2, RING_ENTRIES)]
    if clk != "cfg":
        lines.append("[PROF] WARNING: clk=bsp -- core0 published no ARM rate, so this is "
                     "the COMPILE-TIME constant. If the board retuned its PLL, every Hz "
                     "and every seconds figure below is wrong by that ratio.")
    return lines


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
    valid_lines = (["Z3660 firmware boot", BOOT, ARMED]
                   + stats_dump()
                   + ring_dump(v, noise=["[Z3660] piscsi: unit 6 read 4 blocks",
                                         "z3660eth: link up 100BaseTX"], noise_after=25)
                   + ["[PROF] stopped: %d samples, 0 dropped" % len(v)])
    write(d, "capture-valid.txt", valid_lines)

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
    write(d, "capture-badrecsize.txt", [BOOT] + ring_dump(small_samples(8), rec_size=12))

    # A version nobody has announced: refused as unknown, naming the number.
    write(d, "capture-badversion.txt", [BOOT] + ring_dump(small_samples(8), version=9))

    # ------------------------------------------------------------------ wire version 2
    #
    # v2 is implemented, so the interesting fixtures are no longer refusals -- they are the
    # three numbers v1 got wrong, each built so that a tool still applying v1's rules gets a
    # visibly different answer:
    #
    #   the probe is priced PER TRANSITION      a v1 reader halves it and reports half the
    #                                           instrument's weight
    #   id 12 is XLATE_OK, id 19 is ATC_HIT     a v1 reader takes the ATC rate off id 12,
    #                                           which is a rate about something else
    #   id 8 is the tail RESIDUE, not the tail   a v1 reader reports 7.5% where the tail is
    #                                           20.0%, and calls it an improvement
    v2 = valid_samples()
    write(d, "capture-v2valid.txt",
          ["Z3660 firmware boot"] + boot_v2() + [ARMED] + stats_dump_v2()
          + ring_dump(v2, version=2)
          + ["[PROF] stopped: %d samples, 0 dropped (data KEPT -- PROFD/PROFR read it)"
             % len(v2)])

    # clk=bsp: the ARM clock is the compile-time BSP constant.  Every Hz below it is
    # suspect, AND the wrap cross-check is structurally unable to notice -- CPU:global-timer
    # is a fixed 2:1, so both spans scale together and the error cancels out of the ratio.
    # The capture must say that where the clean cross-check result is, not only in passing.
    write(d, "capture-v2bsp.txt",
          boot_v2(clk="bsp") + stats_dump_v2(clk="bsp")
          + ring_dump(small_samples(40), version=2, clk="bsp"))

    # A clk= value this version does not define: a wire drift the version field did not
    # catch.  It must be treated as the unsafe case -- an unrecognised provenance is not
    # evidence of a good clock -- but NAMED as unrecognised rather than reported as `bsp`,
    # which would assert something specific this tool cannot know.
    write(d, "capture-v2clkodd.txt",
          boot_v2(clk="pll") + stats_dump_v2(clk="pll"))

    # An impossible subtraction at the firmware's OWN price: 13354050 transitions x 200 cyc
    # = 2670810000 against a 2000000000-cycle run.  v1 answered this shape by clamping each
    # overflowing bucket at zero, which is how an over-priced probe produced a full and
    # plausible table.  v2 must WITHHOLD and report: the instrument claiming more cycles
    # than the run contains is a fault in the instrument, not a rounding detail.
    write(d, "capture-v2probeover.txt",
          boot_v2(probe_cyc=200) + stats_dump_v2(probe_cyc=200))

    # The firmware's own whole-tail line disagreeing with the four bucket rows it is
    # computed from.  This cannot happen on a board -- both come off the same accumulators
    # in the same dump -- so it is proof the capture's `b` lines and its `t` line were taken
    # from different states, and the cross-check exists to say so.
    write(d, "capture-v2tailmismatch.txt",
          boot_v2() + stats_dump_v2(tail_cyc=399000000))

    # ATC_HIT + ATC_MISS EXCEEDING XLATE.  Those two partition the translates, so their sum
    # cannot be larger than the set they partition; a shortfall is legal (translates that
    # faulted before the walk decision) and an overshoot is not.
    write(d, "capture-v2atcbroken.txt",
          boot_v2() + stats_dump_v2(cnts=counters_v2(atc_hit=90000)))

    # A shortfall LARGER than FAULTS.  The missing translates faulted before the walk
    # decision, every one of them threw, and every throw reached the run loop's CATCH -- so
    # the shortfall cannot exceed FAULTS.  This is a check the firmware does not make.
    write(d, "capture-v2atcshort.txt",
          boot_v2() + stats_dump_v2(cnts=counters_v2(atc_hit=40000)))

    # The 68030 path under v2.  Two absences, not one: no tier-0 counters at all, and no
    # XLATE_OK site either -- the 030 translate is a bare ATC probe called from fourteen
    # accessors with no single success point.  Both read zero, and zero means ABSENT: a
    # printed "0.00% returned an address" would say every translate faulted.  ATC_HIT (id
    # 19) on the 030 was always genuine, so the ATC rate is real here.
    write(d, "capture-v2-030.txt",
          boot_v2() + stats_dump_v2(cnts=counters_v2(ipage=(0, 0), dpr=(0, 0), dpw=(0, 0),
                                                     xlate=2600000, walks=40000,
                                                     xlate_ok=0)))

    # ------------------------------------------------- captures that disagree with themselves
    #
    # Neither of these is corrupt: every field is present and well formed.  They are
    # captures that answer the version question twice and give different answers, and the
    # only safe reading of one is to refuse it -- v1 and v2 price probe_cyc in different
    # units and disagree about what two ids are called, so picking a side does not raise an
    # error further down, it produces a plausible wrong number.
    write(d, "capture-v2magic1.txt",
          [BOOT] + ring_dump(small_samples(8), version=2, magic="Z3P1"))
    write(d, "capture-v1v2grammar.txt",
          [BOOT] + stats_dump_v2(version=2, grammar=1))
    write(d, "capture-v2v1grammar.txt",
          [BOOT] + stats_dump_v2(version=1, grammar=2))

    # A v1 boot line above a v2 dump whose own probe_cyc is absent (0) -- one capture
    # spanning a reflash.  The boot line's probe figure is per PAIR and the dump's rules are
    # per TRANSITION, so the fallback must DECLINE rather than convert: this is the same
    # class of error v2 exists to fix, and a stated "unavailable" costs a column while a
    # silent conversion costs the answer.
    write(d, "capture-v2bootv1.txt", [BOOT] + stats_dump_v2(probe_cyc=0))

    # A TRANSITIONS count the probe-landing model cannot reproduce: the adjusted columns
    # must be withheld rather than printed from a model that does not hold.
    write(d, "capture-badmodel.txt",
          [BOOT] + stats_dump(cnts=counters(transitions=3000000)))

    # The 68030 path: tier-0 page-cache counters are absent upstream, not zero by accident.
    # The tier-0 identity is therefore unverifiable here and must report n/a, not MISMATCH.
    write(d, "capture-030.txt",
          [BOOT] + stats_dump(cnts=counters(ipage=(0, 0), dpr=(0, 0), dpw=(0, 0),
                                            xlate=2600000, walks=40000)))

    # STACK_OVF non-zero, in a profiling build of the DIAGNOSTIC loop rather than the lean
    # one -- two independent reasons to distrust the dump, and both must be said out loud.
    write(d, "capture-stackovf.txt",
          [BOOT] + stats_dump(cnts=counters(stack_ovf=3), build=0x07))

    # The two translation identities, broken one at a time.  Each is a counter set that
    # cannot have come off one span, and the warning has to say WHICH identity failed and
    # why it holds -- the old `ATC_HIT + ATC_MISS == XLATE` check said neither, and fired on
    # every intact dump because that sum has no meaning in this format.
    write(d, "capture-atcbroken.txt",
          [BOOT] + stats_dump(cnts=counters(atc_hit=12345)))
    write(d, "capture-tier0broken.txt",
          [BOOT] + stats_dump(cnts=counters(ipage=(1560000, 41000), xlate=70000)))

    # ---------------------------------------------------------------- delivered dirty
    #
    # Both defects the metal C1 captures arrived with, in one file, over the SAME bytes as
    # capture-valid: a logger timestamp ahead of every line, and a `ring hdr` line run
    # together with the console echo of the command that asked for the dump, its literal
    # "[PROF] " eaten by the collision in the one UART.  Nothing is missing, so the report
    # must be identical to capture-valid's -- that identity is the assertion.
    def ts(i):      # a logger clock that advances, so no line's prefix is special
        s = 18 * 3600 + 26 * 60 + 11 + i // 6
        return "%02d:%02d:%02d " % (s // 3600, (s // 60) % 60, s % 60)

    dirty = list(valid_lines)
    hdr_i = next(i for i, ln in enumerate(dirty) if "ring hdr magic=" in ln)
    dirty[hdr_i] = ("PROF RING (full) requested: up to 65535 samples, ~2 min of seri[lROF] "
                    + dirty[hdr_i].split("[PROF] ")[1])
    write(d, "capture-dirty.txt", [ts(i) + ln for i, ln in enumerate(dirty)])

    # The same damage with a field actually missing from the payload.  A repair that could
    # absorb this would be worse than a refusal: it would turn a hard error into a profile.
    gone = list(valid_lines)
    gone[hdr_i] = dirty[hdr_i].replace(" rec_count=%d" % len(v), "")
    write(d, "capture-hdrgone.txt", gone)

    write_nm(os.path.join(d, "kernel.nm"))
    write_elf(os.path.join(d, "kernel.elf"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
