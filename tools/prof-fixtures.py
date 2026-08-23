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
# The rung-1d bucket set: the SAME wire version 2, appended to and renamed at id 0.  Carried
# in full for the same reason as the two above, and with one extra reason of its own -- the
# only thing that distinguishes this shape from the one above is the id-0 NAME, so a fixture
# that built it by appending three entries to the v2 list would silently keep `LOOP` at id 0
# and be exactly the dump the symbolizer must not see.
BUCKET_NAMES_V2_1D = ["LOOPRES", "FETCHOP", "FETCHEX", "READ", "WRITE",
                      "XLATE", "WALK", "HANDLER", "TAILADV", "FAULT", "PROF",
                      "TAILSAMP", "TAILPOLL", "TAILSPEC",
                      "DOPCFIND", "DOPCFILL", "BLKREC"]
COUNTER_NAMES_V2 = ["INSNS", "INSNS_SUPER", "FETCH", "READ", "WRITE",
                    "IPAGE_HIT", "IPAGE_MISS", "DPAGE_RHIT", "DPAGE_RMISS",
                    "DPAGE_WHIT", "DPAGE_WMISS", "XLATE", "XLATE_OK", "ATC_MISS",
                    "MISALIGN_R", "MISALIGN_W", "FAULTS", "TRANSITIONS", "STACK_OVF",
                    "ATC_HIT"]
# Ids 20..38, appended to version 2 WITHOUT a version bump.  They are a separate list here
# for the same reason the two version tables are separate lists: a firmware that predates
# them emits 20 counter rows and one that has them emits 39, and both are legal v2 dumps.
# A generator that could only produce the longer one could not build the fixture that proves
# a tool tells "this firmware never had it" apart from "this counter measured zero".
COUNTER_NAMES_APPENDED = ["IFETCH_CALLS",
                          "BLK_HIT", "BLK_INSNS", "BLK_BYTES",
                          "DOPC_HIT", "DOPC_MISS", "DOPC_EXT", "DOPC_INVAL",
                          "IV_FLUSH", "IV_ROOT", "IV_DMA", "IV_TABLE", "IV_KNOB",
                          "IV_WRAP", "IV_MAP", "IV_PFLUSH", "IV_PFLUSHA", "IV_CACR",
                          "IV_CACR_SKIP"]
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
                transitions=None, stack_ovf=0, xlate=None, xlate_ok=None, atc_hit=None,
                loop_split=None):
    """The version-2 counter block: id 12 is XLATE_OK, id 19 is a REAL ATC_HIT.

    The two are given SEPARATE defaults on purpose, and they differ, because that
    difference is the whole v1 defect:

        XLATE_OK = XLATE - FAULTS      translates that returned an address
        ATC_HIT  = XLATE - ATC_MISS    translates served without a walk

    In v1 the second quantity did not exist and the first was printed under its name.  A
    fixture that set them equal would let a tool reading id 12 as an ATC rate pass, which is
    exactly the bug being guarded against.

    `loop_split` is rung 1d's three ENTRY counts (DOPCFIND, DOPCFILL, BLKREC).  They go into
    TRANSITIONS at two apiece, because that is what the split actually charges the run loop
    and because sum(spans) == TRANSITIONS has to hold on the fixture the way it holds on a
    board -- a rung-1d capture whose transition count was still the pre-1d one would have its
    whole `s` block refused before any identity in it could be checked."""
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
        if loop_split is not None:
            entries += sum(loop_split)      # DOPCFIND + DOPCFILL + BLKREC (rung 1d)
        transitions = 2 * entries
    return [insns, int(insns * 0.35), fetch, read, write,
            ipage[0], ipage[1], dpr[0], dpr[1], dpw[0], dpw[1],
            xlate, xlate_ok, walks, misalign[0], misalign[1], faults,
            transitions, stack_ovf, atc_hit]


def counters_appended(fetch=1600000, insns=1000000, faults=25,
                      blk=(2000, 600000, 1800000),
                      dopc=(900023, 100002, 400000, 2000),
                      iv=(1200, 100, 20, 0, 0, 0, 0, 180, 480, 20),
                      cacr_skip=2000, ifetch=None, with_skip=True):
    """Counter ids 20..38, wired so that every identity a symbolizer should check HOLDS.

    A fixture whose identities do not hold cannot tell a tool that checks them from one that
    does not, so the defaults here are chosen against the arithmetic rather than for round
    numbers:

      IFETCH_CALLS == FETCH                     identically -- every ENTER_IFETCH site
                                                increments FETCH exactly once
      DOPC_HIT + DOPC_MISS == INSNS + FAULTS    a dispatch either retires (INSNS) or throws
                                                (FAULTS), and consults the cache exactly once
      sum(IV_*) == DOPC_INVAL                   with the cache on, every request that
                                                reaches the invalidator performs one
      BLK_INSNS / BLK_HIT                       300, well clear of the ~8 floor below which
                                                the recognizer test is paid per iteration

    `with_skip=False` builds the 38-counter firmware -- the one whose narrowing lives at a
    call site it cannot see, which is the shape that made a real verdict unscoreable."""
    if ifetch is None:
        ifetch = fetch
    out = [ifetch, blk[0], blk[1], blk[2],
           dopc[0], dopc[1], dopc[2], dopc[3]] + list(iv)
    if with_skip:
        out.append(cacr_skip)
    return out


# Per-bucket transition spans, in bucket-id order, for the `[PROF] s` block.
#
# Two constraints, and they are what make this list what it is rather than round numbers.
# It must sum to exactly the fixture's TRANSITIONS (13354050), because `sum(spans) ==
# TRANSITIONS` holds by construction on any intact dump and a symbolizer must refuse a block
# where it does not.  And every bucket must stay POSITIVE at the TOP of the price bracket
# (57 cyc/span), because the clean case has to be clean before a clamped one means anything
# -- LOOP and TAILADV are the two that clamp first on metal, so both are given room.
#
# FAULT and PROF get zero spans, which is not an omission: an unwind charges FAULT cycles
# and counts no span, and PROF is only entered by a dump.
SPANS_V2 = [5043850, 260000, 600000, 570000, 410000, 22000, 4200,
            2430000, 2000000, 0, 0, 1000000, 1000000, 14000]

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

# ---------------------------------------------------------------- the rung-1d LOOP split
#
# THE ENTRY COUNTS ARE NOT FREE PARAMETERS.  Every one of them is pinned by an identity the
# firmware states and the symbolizer checks, so the fixture is built from the identities
# outwards rather than from round numbers inwards:
#
#   DOPCFIND spans == DOPC_HIT + DOPC_MISS == INSNS + FAULTS   1000025  -- one lookup per
#                                                              dispatch, and a dispatch
#                                                              either retires or throws
#   DOPCFILL spans == DOPC_MISS                                 100002  -- one fill per miss
#   BLKREC   spans <= DOPCFIND spans                            900000  -- at most one
#                                                              recognizer call per dispatch
#
# A fixture whose identities merely happened to hold could not tell a tool that checks them
# from one that does not; these hold because they are where the numbers came from.
DOPC_FIND_SPANS = 1000025
DOPC_FILL_SPANS = 100002
BLKREC_SPANS = 900000
SPLIT_ENTRIES = (DOPC_FIND_SPANS, DOPC_FILL_SPANS, BLKREC_SPANS)

# The residue's own span count.  Entering a nested stage CLOSES a span in its parent, so each
# of the three costs the loop one span of its own as well as one of the callee's -- which is
# exactly the "two transitions per span of the three" the firmware prices the split at.  The
# pre-split figure is SPANS_V2[0].
SPANS_V2_1D = ([SPANS_V2[0] + sum(SPLIT_ENTRIES)] + SPANS_V2[1:]
               + [DOPC_FIND_SPANS, DOPC_FILL_SPANS, BLKREC_SPANS])

# And the cycles.  TWO constraints, and the second is what forces the totals to be bigger
# than the pre-split fixture's rather than a re-slicing of them:
#
#   the ROLLUP lands at 800000000 / 3016000000 -- 26.52 % as the firmware truncates it and
#   26.53 % as the report rounds it, either way inside the 26.38-26.54 % the C2 attack map
#   quotes LOOP at.  So the report's guard is demonstrated against the real figure and not
#   against an invented one.  Id 0 alone is 15.92 %, and the ten-point gap between those two
#   numbers IS the mistake this shape makes available.
#
#   every bucket stays POSITIVE at the TOP of the price bracket (57 cyc/span).  LOOPRES
#   carries 7043877 spans -- the three new stages' exits land on it -- which is 401500989 cyc
#   of probe on its own, so a residue sized like the pre-split fixture's LOOP would clamp on
#   arrival and the clean case would never be clean.
BUCKETS_V2_1D = [480000000,                                        # 0  LOOPRES
                 280000000, 150000000, 360000000, 170000000,       # 1..4
                 130000000, 56000000, 480000000, 210000000,        # 5..8
                 11000000, 17000000,                               # 9..10
                 170000000, 154000000, 28000000,                   # 11..13
                 210000000, 50000000, 60000000]                    # 14..16 the split

# The cache-OFF arm of the same shape.  Both new brackets are then entered once per DISPATCH
# -- the lookup returns before it can count, and the fill's bracket sits on the now-universal
# miss arm -- so DOPCFILL's span count jumps to the dispatch count while DOPC_MISS reads a
# true zero.  That divergence is the whole point of the fixture: it is a fact about the
# switch, and a tool that warns about it is wrong.
SPANS_V2_1D_OFF = ([SPANS_V2[0] + 2 * DOPC_FIND_SPANS + BLKREC_SPANS] + SPANS_V2[1:]
                   + [DOPC_FIND_SPANS, DOPC_FIND_SPANS, BLKREC_SPANS])
BUCKETS_V2_1D_OFF = (BUCKETS_V2_1D[:14]
                     + [BUCKETS_V2_1D[14], 70000000, BUCKETS_V2_1D[16]])
BUCKETS_V2_1D_OFF[0] = 520000000        # 7943900 spans x 57 = 452802300; keep it positive


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


def _span_block(buckets, spans, price, trans, drop_rows=(), stated_sum=None, names=None):
    """The `[PROF] s` block exactly as the firmware writes it.

    The firmware prices these rows at the SAME probe_cyc its aggregate line uses, so the two
    agree by construction and `sum(corrected) == corrected total`.  Reproducing that here
    rather than inventing a second price is the point: the fixture has to be a dump, and a
    dump whose two corrections disagree is a firmware bug, not a test case.

    `drop_rows` builds the capture that lost `s` lines in transit.  Its stated total stays
    the TRUE one, which is what makes the loss detectable: the rows that arrived no longer
    sum to it.  A tool that used such a block would credit the missing buckets with zero
    probe cost, i.e. would INFLATE exactly the ones whose evidence is gone."""
    out = ["[PROF] === per-bucket spans and the corrected shares (price %d cyc/span; sweep "
           "to the boot line's in-bucket figure) ===" % price]
    corr = [max(buckets[i] - spans[i] * price, 0) for i in range(len(buckets))]
    ctotal = sum(corr)
    for i, name in enumerate(names or BUCKET_NAMES_V2):
        if i in drop_rows:
            continue
        out.append("[PROF] s %-2d %-8s spans=%-14s corrected_cyc=%-16s %s%%"
                   % (i, name, spans[i], corr[i], fw_pct(corr[i], ctotal)))
    out.append("[PROF] s -- corrected_total=%d  spans=%d  (must equal TRANSITIONS %d -- an "
               "unwind charges FAULT cycles and no span, so FAULT reads uncorrected)"
               % (ctotal, sum(spans) if stated_sum is None else stated_sum, trans))
    return out


def _loop_block(buckets, spans, cnts, appended, loop_cyc=None):
    """The `[PROF] l` block exactly as the firmware writes it: rollup, cost, and verdict.

    All three are computed from the same arrays the `b` and `s` rows are printed from,
    because that is what the board does -- the rollup out of the accumulators, the cost out
    of the three buckets' OWN spans, and the identities out of the spans against the DOPC_
    counters.  A fixture that computed any of them independently would be able to disagree
    with its own rows, which is a state no firmware can produce and therefore not a test
    case.  `loop_cyc` overrides the rollup to build the one capture that IS that state.

    The verdict line is the firmware's own branch: with the cache ON a broken identity is a
    WARNING, and with it OFF the two counter identities do not apply at all and the line is a
    `note:` saying so."""
    total = sum(buckets)
    trans = cnts[17]
    loop = sum(buckets[i] for i in (0, 14, 15, 16)) if loop_cyc is None else loop_cyc
    find, fill, brec = spans[14], spans[15], spans[16]
    split = 2 * (find + fill + brec)
    out = ["[PROF] l whole loop (LOOPRES+DOPCFIND+DOPCFILL+BLKREC) cyc=%d %s%% -- this is "
           "what v2 reported as LOOP" % (loop, fw_pct(loop, total)),
           "[PROF] l split cost: %d transitions (%s%% of %d) -- 2 per span of the three; a "
           "capture taken before rung 1d has none of them"
           % (split, fw_pct(split, trans).strip(), trans)]
    hi = appended[4] if appended is not None and len(appended) > 5 else 0
    mi = appended[5] if appended is not None and len(appended) > 5 else 0
    if hi + mi:
        if find != hi + mi:
            out.append("[PROF] l WARNING: DOPCFIND spans=%d but DOPC_HIT+DOPC_MISS=%d -- the "
                       "lookup bracket and the dispatch counters disagree" % (find, hi + mi))
        if fill != mi:
            out.append("[PROF] l WARNING: DOPCFILL spans=%d but DOPC_MISS=%d -- the fill "
                       "bracket and the miss counter disagree" % (fill, mi))
    elif find:
        out.append("[PROF] l note: DOPCFIND spans=%d with DOPC_HIT+DOPC_MISS=0 -- the cache "
                   "was OFF for this window, so these two buckets price the two switch tests "
                   "and nothing else" % find)
    return out


def stats_dump_v2(buckets=None, cnts=None, build=0x04, probe_cyc=PROBE_CYC_V2, hz=HZ,
                  clk="cfg", version=2, tail_cyc=None, grammar=2,
                  appended=None, spans=None, drop_span_rows=(), span_sum=None,
                  span_trans=None, rung1d=False, loop_cyc=None, wall_ticks=None,
                  bnames=None):
    """The version-2 PROFD block, emitted exactly as the firmware writes it.

    `grammar` exists to build the one capture that must be REFUSED without being corrupt:
    a dump whose `ver=` line declares one version while being written in the other's
    format.  That is not a hypothetical -- it is what a hand-edited capture, or a fixture
    generator that bumped a number without bumping a format, produces -- and the two
    grammars price `probe_cyc` in different units, so a reader that reconciles them instead
    of refusing gets a plausible number rather than an error.

    `rung1d` selects the SHAPE rather than the version: the same wire version 2 with the
    dispatch loop decomposed, which is carried by the bucket NAMES and by nothing else.
    `bnames` overrides that table outright, and exists for one fixture -- the dump that
    answers the shape question twice by naming id 0 `LOOP` while carrying `DOPCFIND` at
    id 14.  No firmware writes that, which is exactly why a generator has to be able to."""
    if bnames is None:
        bnames = BUCKET_NAMES_V2_1D if rung1d else BUCKET_NAMES_V2
    if buckets is None:
        buckets = BUCKETS_V2_1D if rung1d else BUCKETS_V2
    cnts = counters_v2() if cnts is None else cnts
    total = sum(buckets)
    # Sized so the buckets account for 90% of the elapsed span, same shape as the v1
    # fixture: a run-loop residency of exactly 100% would say core1 never once left the run
    # loop, which no real capture shows and which would make the shape check meaningless.
    if wall_ticks is None:
        wall_ticks = total * 10 // 18
    out = ["[PROF] === stage attribution ==="]
    if grammar == 2:
        out.append("[PROF] ver=%d build=0x%02X cpu_hz=%d clk=%s hz=%d period_cyc=%d "
                   "probe_cyc_per_transition=%d"
                   % (version, build, CPU_HZ, clk, hz, PERIOD, probe_cyc))
    else:
        out.append("[PROF] ver=%d build=0x%02X cpu_hz=%d hz=%d period_cyc=%d probe_cyc=%d"
                   % (version, build, CPU_HZ, hz, PERIOD, probe_cyc))
    out.append("[PROF] total_cyc=%d wall_ticks=%d wall_hz=%d" % (total, wall_ticks, WALL_HZ))
    for i, name in enumerate(bnames):
        out.append("[PROF] b %-2d %-8s cyc=%-16s %s%%"
                   % (i, name, buckets[i], fw_pct(buckets[i], total)))
    # The whole-tail rollup: the firmware's OWN sum of ids 8+11+12+13, printed so a v2
    # capture can be laid beside a v1 one.  `tail_cyc` overrides it to build the capture
    # where that line and the bucket rows disagree -- which cannot happen on a board and is
    # therefore proof the two came off different states.
    tail = sum(buckets[i] for i in (8, 11, 12, 13)) if tail_cyc is None else tail_cyc
    out.append("[PROF] t whole tail (TAILADV+TAILSAMP+TAILPOLL+TAILSPEC) cyc=%d %s%% "
               "-- this is what v1 reported as TAIL" % (tail, fw_pct(tail, total)))
    # Rung 1d's own block, printed where the firmware prints it: after the tail rollup and
    # before the probe line.  It exists only on a dump that HAS the split -- the firmware
    # that has no ids 14..16 has no `l` line either, which is what makes the older captures
    # still readable and still comparable.
    if rung1d and spans is not None:
        out.extend(_loop_block(buckets, spans, cnts, appended, loop_cyc))
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
    if spans is not None:
        out.extend(_span_block(buckets, spans, probe_cyc,
                               cnts[17] if span_trans is None else span_trans,
                               drop_span_rows, span_sum, bnames))
    out.append("[PROF] === counters ===")
    names = list(COUNTER_NAMES_V2)
    vals = list(cnts)
    if appended is not None:
        names += COUNTER_NAMES_APPENDED[:len(appended)]
        vals += list(appended)
    for i, name in enumerate(names):
        out.append("[PROF] c %-2d %-12s %d" % (i, name, vals[i]))
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
    # The decoded-op cache's own derived rows.  The tool does not parse them -- it computes
    # its own -- but the fixture has to be a DUMP, and a dump that omits lines the firmware
    # writes is not one.  They are also the rows a reader compares the tool's against.
    if appended is not None and len(appended) >= 8:
        hi, mi, iv = appended[4], appended[5], appended[7]
        req = sum(appended[8:18])
        sk = appended[18] if len(appended) > 18 else None
        if hi + mi:
            out.append("[PROF] r dopc %s%% of %d dispatches"
                       % (fw_pct(hi, hi + mi).strip(), hi + mi))
        if iv:
            out.append("[PROF] r dopc %d.%02u misses and %d.%02u dispatches per "
                       "invalidation -- a figure that does NOT track the workload's code "
                       "footprint is re-warm, not capacity"
                       % (mi // iv, (mi * 100 // iv) % 100,
                          (hi + mi) // iv, ((hi + mi) * 100 // iv) % 100))
        if sk is not None and req + sk:
            out.append("[PROF] r dopc %d invalidation requests, %d performed, %d narrowed "
                       "at the call site (%s%%)"
                       % (req + sk, iv, sk, fw_pct(sk, req + sk).strip()))
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


CAL_PAIRS = 1024
# The three calibration spans, chosen so the firmware's own arithmetic comes out at exactly
# the bracket [46, 57]:  (armed - unarmed) / 2048 == 46  and  (armed - empty) / 2048 == 57.
# The scaffolding term is then 11, and 46 + 11 == 57 -- which is the relation a reader is
# meant to be able to check on the line, so the fixture has to satisfy it.
CAL_EMPTY = 2048
CAL_ARMED = CAL_EMPTY + 57 * 2 * CAL_PAIRS          # 118784
CAL_UNARMED = CAL_ARMED - PROBE_CYC_V2 * 2 * CAL_PAIRS   # 24576
PROBE_IN_BUCKET = 57


def probe_cal(passes=3, marginal=PROBE_CYC_V2, in_bucket=PROBE_IN_BUCKET,
              armed=CAL_ARMED, unarmed=CAL_UNARMED, empty=CAL_EMPTY, bracket=True,
              bracket_lo=None, bracket_hi=None):
    """The calibration and price-bracket lines, in both the shapes metal has produced.

    `passes=2` is the older firmware: no `empty` pass, so no in-bucket figure and no bracket
    line at all.  It is not a degenerate case of the three-pass line -- it is a capture that
    supports ONE price, and a tool that reported its bracket as a range of width zero would
    be claiming the instrument had answered a question it was never asked."""
    if passes == 2:
        return ["[PROF] probe calibration: armed %d cyc, unarmed %d cyc, %d pairs -> %d "
                "cyc/transition marginal" % (armed, unarmed, CAL_PAIRS, marginal)]
    lines = ["[PROF] probe calibration: armed %d cyc, unarmed %d cyc, empty %d cyc, %d "
             "pairs -> %d cyc/transition marginal, %d in-bucket"
             % (armed, unarmed, empty, CAL_PAIRS, marginal, in_bucket)]
    if bracket:
        lines.append("[PROF] price bracket: %d (bodies only, what PROFB gates) .. %d (bodies "
                     "+ the call scaffolding, which is inside the buckets too) "
                     "cyc/transition -- sweep it, do not pick"
                     % (marginal if bracket_lo is None else bracket_lo,
                        in_bucket if bracket_hi is None else bracket_hi))
    return lines


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

    # -------------------------------------------- the post-v2 append: spans and rungs 0/1/1b/1c
    #
    # Counter ids 20..38 and the `[PROF] s` block were appended to wire version 2 WITHOUT a
    # bump, so these captures are the same version as capture-v2valid and carry nineteen
    # more counters and a whole extra block.  They are separate fixtures rather than an
    # upgrade of capture-v2valid precisely BECAUSE both are legal v2: a tool has to read the
    # short one without inventing zeros and the long one without ignoring the block, and one
    # fixture cannot test both.
    #
    # The `s` block is what turns a corrected share from an upper bound into a number, and
    # the whole reason it exists is that the estimate it replaces -- `2 x IFETCH_CALLS` for
    # the fetch buckets' transitions -- is REFUTED, not merely bettered: with a decoded-op
    # cache upstream a hit never enters FETCHOP at all, so the bucket is entered once per
    # MISS and not once per fetch.  The fixture encodes that (FETCHOP spans 260000 against
    # DOPC_MISS 100002 -- no relation to IFETCH_CALLS 1600000), because a fixture where the
    # two happened to agree could not tell a tool using the right one from a tool using the
    # wrong one.
    full = counters_appended()
    write(d, "capture-v2spans.txt",
          ["Z3660 firmware boot"] + boot_v2() + probe_cal() + [ARMED]
          + stats_dump_v2(appended=full, spans=SPANS_V2))

    # sum(spans) != TRANSITIONS.  Every transition charges exactly one span and an unwind
    # charges neither, so on an intact dump these are equal BY CONSTRUCTION -- a mismatch
    # means the `s` lines and the `c` lines did not come off one state, and a corrected
    # column built from them would balance while being wrong.  The spans must be refused and
    # the modelled landing must take over, not silently.
    bad_spans = list(SPANS_V2)
    bad_spans[0] -= 50000
    write(d, "capture-v2spansbad.txt",
          boot_v2() + probe_cal() + stats_dump_v2(appended=full, spans=bad_spans))

    # The same block with ROWS LOST in the capture.  Its own stated total is still the true
    # one, which is what makes the loss detectable at all.  This is not the conservative
    # failure it looks like: a missing row reads as a bucket that pays no probe, so it
    # INFLATES exactly the buckets whose evidence is gone.
    write(d, "capture-v2spanslost.txt",
          boot_v2() + probe_cal()
          + stats_dump_v2(appended=full, spans=SPANS_V2, drop_span_rows=(0, 7)))

    # The two-pass calibration: no `empty` span, so no in-bucket figure and no bracket line.
    # One price, and the report must say that rather than present a zero-width range.
    write(d, "capture-v2cal2.txt",
          boot_v2() + probe_cal(passes=2) + stats_dump_v2(appended=full, spans=SPANS_V2))

    # A calibration line whose stated marginal figure is not what its own three spans give.
    # Both are printed from the same measurement in the same boot, so they cannot disagree;
    # the tool checks the arithmetic rather than repeating the quotient on faith.
    write(d, "capture-v2calbad.txt",
          boot_v2() + probe_cal(marginal=44) + stats_dump_v2(appended=full))

    # IFETCH_CALLS != FETCH.  These are identically equal in any firmware that has both --
    # each of the five ENTER_IFETCH sites is followed immediately by one FETCH increment --
    # so a divergence means a fetch site was added to one path and not the other.  That is
    # the drift no reviewer catches and no arithmetic check objects to.
    write(d, "capture-v2ifetchdrift.txt",
          boot_v2() + probe_cal()
          + stats_dump_v2(appended=counters_appended(ifetch=1600400)))

    # A recognizer that fires and does not pay: mean chunk length 2.  The fast path pays its
    # test ONCE PER CHUNK, so a mean of 2 means it is being paid per iteration and the whole
    # saving is gone -- the pre-registered failure mode, and the thing to check is the
    # TRIGGER rather than the host operation.
    write(d, "capture-v2blkstall.txt",
          boot_v2() + probe_cal()
          + stats_dump_v2(appended=counters_appended(blk=(300000, 600000, 1800000))))

    # The decoded-op cache switched OFF for the whole window.  The four DOPC_ counters read
    # exactly zero -- the lookup returns before it can count -- and that is a MEASUREMENT,
    # not an absence.  The IV_* counters still move, because they count what the GUEST asked
    # for and the guest issues CPUSHL and PFLUSH whatever the switch says, which is what
    # makes a cache-off arm a free measurement of the guest's own invalidation rate.
    write(d, "capture-v2dopcoff.txt",
          boot_v2() + probe_cal()
          + stats_dump_v2(appended=counters_appended(dopc=(0, 0, 0, 0))))

    # The 38-counter firmware: a narrowing that decides at its CALL SITE, and no counter that
    # can see it.  `sum(IV_*) - DOPC_INVAL` does NOT recover it -- a request refused before
    # the invalidator increments nothing at all -- so the report must refuse to score a
    # narrowing from these rows rather than quietly under-report one.
    write(d, "capture-v2noskip.txt",
          boot_v2() + probe_cal()
          + stats_dump_v2(appended=counters_appended(with_skip=False)))

    # DOPC_HIT + DOPC_MISS against INSNS + FAULTS, broken.  Every dispatch consults the cache
    # exactly once and every dispatch either retires or throws, so this holds exactly on a
    # window taken entirely with the cache on; if it does not, the hit rate above it is a
    # rate of something else.
    write(d, "capture-v2dopcskew.txt",
          boot_v2() + probe_cal()
          + stats_dump_v2(appended=counters_appended(dopc=(900023, 90002, 400000, 2000))))

    # sum(IV_*) LESS than DOPC_INVAL, which is impossible: every invalidation performed was
    # requested and attributed to a cause.  Either a cause id is out of range or a call site
    # reaches the invalidator without going through the attribution.
    write(d, "capture-v2ivshort.txt",
          boot_v2() + probe_cal()
          + stats_dump_v2(appended=counters_appended(
              iv=(700, 100, 20, 0, 0, 0, 0, 180, 480, 20))))

    # ------------------------------------------------------- rung 1d: the LOOP split
    #
    # THE SAME WIRE VERSION, AND THE ONLY THING THAT SAYS SO IS A NAME.  Rung 1d brackets the
    # decoded-op lookup, the decoded-op fill and the block-idiom recognizer out of the
    # dispatch loop into ids 14..16 and leaves id 0 holding the residue -- so id 0 stops
    # meaning what every earlier capture's id 0 meant, and the firmware deliberately does NOT
    # bump the version for it.  It moves the printed name instead (`LOOP` -> `LOOPRES`),
    # exactly as v1's `TAIL` became v2's `TAILADV`, because a bump would make every existing
    # tool refuse a capture it can read correctly.
    #
    # These fixtures are therefore built to break a tool that keys on the version number: the
    # magic is Z3P2, the `ver=` line says 2, the header and the sample record are untouched,
    # and the ONLY difference is three appended rows and one renamed one.
    #
    # The cycle totals are sized so the ROLLUP lands at 26.52 % -- inside the 26.38-26.54 %
    # the C2 attack map quotes LOOP at -- while id 0 alone is 15.91 %.  A tool that reports id
    # 0 against the map's figure gets a clean, well-formatted, ten-point saving that no code
    # change produced, and no arithmetic anywhere in its report objects.
    cnt1d = counters_v2(loop_split=SPLIT_ENTRIES)
    lines_1d = (["Z3660 firmware boot"] + boot_v2() + probe_cal() + [ARMED]
                + stats_dump_v2(cnts=cnt1d, appended=full, spans=SPANS_V2_1D, rung1d=True))
    write(d, "capture-v21d.txt", lines_1d)

    # The cache OFF, in the rung-1d shape.  Two of the four identities then do NOT hold and
    # neither divergence is a defect: the lookup returns before it can count, so DOPCFIND
    # goes on being entered every pass against a DOPC_HIT+DOPC_MISS of zero, and DOPCFILL's
    # bracket sits on the now-universal miss arm and prices the fill's own switch test per
    # dispatch instead of per miss.  The firmware says so on a `note:` line rather than a
    # WARNING, and a tool that warns here is telling the reader to go and fix a switch
    # setting they chose on purpose.  `tcnt[DOPCFIND] == INSNS + FAULTS` still holds, because
    # a dispatch enters the bracket whichever way the switch is set.
    write(d, "capture-v21doff.txt",
          boot_v2() + probe_cal()
          + stats_dump_v2(cnts=counters_v2(loop_split=(DOPC_FIND_SPANS, DOPC_FIND_SPANS,
                                                       BLKREC_SPANS)),
                          appended=counters_appended(dopc=(0, 0, 0, 0)),
                          buckets=BUCKETS_V2_1D_OFF, spans=SPANS_V2_1D_OFF, rung1d=True))

    # A lookup bracket that does not agree with the dispatch counters, with the cache ON.
    # The lookup touches no guest memory, so its span cannot be abandoned by an unwind and
    # the count is EXACT -- which is why the firmware WARNS here rather than noting, and why
    # the tool must surface the board's own warning as well as failing the identity itself.
    # The 50000 spans are moved to LOOPRES rather than deleted, so sum(spans) == TRANSITIONS
    # still holds: a block refused for its total would never reach the identity at all.
    skew = list(SPANS_V2_1D)
    skew[14] -= 50000
    skew[0] += 50000
    write(d, "capture-v21dskew.txt",
          boot_v2() + probe_cal()
          + stats_dump_v2(cnts=cnt1d, appended=full, spans=skew, rung1d=True))

    # The firmware's own `l` rollup disagreeing with the four bucket rows it is computed
    # from.  Same impossibility as the `t` line's, one bucket over.
    write(d, "capture-v21dloopmismatch.txt",
          boot_v2() + probe_cal()
          + stats_dump_v2(cnts=cnt1d, appended=full, spans=SPANS_V2_1D, rung1d=True,
                          loop_cyc=799000000))

    # A rung-1d dump whose `s` block lost the DOPCFIND row in transit.  The block is refused
    # (its rows no longer sum to its own stated total), and the identities are stated over
    # SPANS -- so they become UNAVAILABLE rather than being computed from whatever else is to
    # hand.  The rollup and the guard survive, because they come off the `b` rows.
    write(d, "capture-v21dspanslost.txt",
          boot_v2() + probe_cal()
          + stats_dump_v2(cnts=cnt1d, appended=full, spans=SPANS_V2_1D, rung1d=True,
                          drop_span_rows=(14,)))

    # A dump that answers the shape question twice and disagrees: `LOOP` at id 0 -- the name
    # that says there is no split -- while carrying DOPCFIND at id 14, which only exists
    # where there is.  No firmware writes this; a hand-edit or a mixed paste does.  The id-0
    # name stands, ids 14..16 stay uninterpreted, and neither answer is silently preferred.
    write(d, "capture-v21dnameclash.txt",
          boot_v2() + probe_cal()
          + stats_dump_v2(cnts=cnt1d, appended=full, spans=SPANS_V2_1D, rung1d=True,
                          bnames=["LOOP"] + BUCKET_NAMES_V2_1D[1:]))

    # The stats dump whose "=== stage attribution ===" banner was eaten by the console
    # collision -- the SAME shared-UART defect the `ring hdr` repair exists for, arriving on
    # a different line.  Five of the 2026-08-22/23 metal captures were refused for this while
    # every byte of their payload was present, so the damage is reproduced here verbatim in
    # shape: the echo of the request and the firmware's first line interleaved, then the
    # remainder of the banner on its own line.
    #
    # The payload after it is capture-v2spans's own bytes, so the assertion is the IDENTITY
    # of the two reports and not a spot check.
    spans_lines = (["Z3660 firmware boot"] + boot_v2() + probe_cal() + [ARMED]
                   + stats_dump_v2(appended=full, spans=SPANS_V2))
    banner_i = spans_lines.index("[PROF] === stage attribution ===")
    write(d, "capture-v2bannergone.txt",
          spans_lines[:banner_i]
          + ["PROF DUMP requested (stage buckets + count[PeROrF]s =)== s",
             "tage attribution ==="]
          + spans_lines[banner_i + 1:])

    # The same damage with the `ver=` line gone TOO.  That line is what carries the dump's
    # identity -- version, build flags, clock, clock source, probe price -- so this one must
    # still be refused: the banner carries nothing, and repairing its absence is cheap
    # precisely because the line beneath it is checked.  Losing both leaves nothing to check.
    noident = list(spans_lines)
    del noident[banner_i + 1]
    noident[banner_i] = "PROF DUMP requested (stage buckets + count[PeROrF]s =)== s"
    write(d, "capture-v2bannerident.txt", noident)

    # The same collision over a RUNG-1D dump's bytes.  The repair keys on `[PROF] ver=` and
    # never on the banner, so it cannot care which shape follows it -- and this fixture is
    # what says so rather than what assumes it.  The assertion is again the IDENTITY of the
    # two reports: the capture session that needs the loop split is the next one, and it will
    # be taken over the same shared UART that ate five of the last one's banners.
    b1d = lines_1d.index("[PROF] === stage attribution ===")
    write(d, "capture-v21dbanner.txt",
          lines_1d[:b1d]
          + ["PROF DUMP requested (stage buckets + count[PeROrF]s =)== s",
             "tage attribution ==="]
          + lines_1d[b1d + 1:])

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
