#!/usr/bin/env python3
# prof-symbolize.py -- turn a Z3660 "[PROF]" serial capture into a symbolized profile.
#
# usage:  python3 tools/prof-symbolize.py CAPTURE [--kernel build/unix-040] [...]
#         python3 tools/prof-symbolize.py --help
#
# WHY THIS EXISTS
#
# The profiling firmware variant emits raw records and nothing else: a guest PC, an opcode
# word, a flags word, and a header of totals.  Symbolization is this repository's business
# because this is where the kernel artifact and its symbol table live.  The output below is
# meant to be read as evidence -- fixed columns, every number labelled with what it is and
# what it is not -- rather than as a summary somebody has already interpreted.
#
# THE FOUR WAYS TO GET A WRONG ANSWER OUT OF THIS CAPTURE, AND WHAT IS DONE ABOUT EACH
#
#   1. IGNORING `WEIGHT`.  A sample is not one tick.  When core1 leaves the run loop -- a
#      STOP spin, an exception, a mailbox round trip to core0 through an emulated device --
#      the sampler cannot fire, and the first sample after re-entry carries a WEIGHT saying
#      how many tick periods it stands for.  Counting samples instead of weight deletes
#      exactly the stalls a profiler exists to find.  Everything here is weighted, the raw
#      sample count is printed beside the weight so the difference is visible, and the
#      WEIGHT histogram is reported as its own section because it is the honest measure of
#      how much of the run this instrument could not observe.
#
#   2. READING A TAIL AS A RUN.  The ring holds 65536 samples and a `PROFR` dumps the newest
#      4096 by default.  Two different losses follow and only one of them is `drops`:
#      `drops` counts samples the ring itself overwrote, and `samples - rec_count` counts
#      what this particular dump left behind even when the ring never wrapped.  Both are
#      reported; the coverage line states the fraction of the run actually in front of you.
#
#   3. A MISSED PMCCNTR WRAP.  The 64-bit cycle base is extended at each sample, so if core1
#      leaves the run loop for longer than one 32-bit wrap the base loses 2^32 cycles
#      silently.  The header carries an independent ARM global-timer span for exactly this
#      cross-check.  Note the systematic bias in it, which the firmware's own documentation
#      does not spell out: `cyc_span` stops accumulating at the LAST SAMPLE while
#      `wall_ticks` runs to the DUMP, so stopping the sampler before dumping (`PROF` to off,
#      then `PROF RING`) produces a shortfall that is not a missed wrap.  A shortfall near a
#      multiple of 2^32 is read as a wrap; one that is not is reported in seconds of
#      un-sampled wall time instead of being mislabelled.
#
#   4. A TRUNCATED SERIAL CAPTURE.  115200 baud, minutes of output, and a terminal in the
#      middle.  The dump grammar is fixed-width for this reason, and a lost line is a hard
#      error naming the capture line that proves it -- never a quietly shorter profile.
#
#      A capture that is INTACT but delivered dirty is a different thing and is repaired,
#      not refused: a logger's timestamp prefix on every line, and a `ring hdr` line whose
#      literal "[PROF] " the UART lost while its whole key=value payload survived.  Both
#      are announced in the warnings.  The refusal is for data that is actually missing.
#
# THE WIRE FORMAT IS VERSIONED and an unknown magic or version is refused rather than
# guessed at.  VERSIONS 1 AND 2 are implemented; see THE VERSION SEAM below, where every
# version-dependent decision is written down in one table.  The two versions do not merely
# differ in what they CARRY -- they differ in what three of their numbers MEAN, so a v2 dump
# read under v1 rules produces a full report and a wrong one:
#
#   * `probe_cyc` prices an enter/exit PAIR in v1 and ONE TRANSITION in v2, against a
#     TRANSITIONS count that means the same thing in both.  Halving a v2 figure the way a v1
#     figure must be halved understates the instrument's own weight by exactly 2x.
#   * counter id 12 is named `ATC_HIT` in v1 and `XLATE_OK` in v2, and XLATE_OK is what it
#     always counted.  v2 adds a REAL ATC hit counter at the new id 19.
#   * bucket id 8 is the WHOLE run-loop tail in v1 and its RESIDUE in v2, which splits the
#     rest across new ids 11..13.  Reading v2's id 8 as "the tail" understates the tail.
#
# Because the magic encodes the version ('Z3P' + digit), a header whose magic and version
# field disagree is refused as a mismatch rather than resolved in favour of one of them; the
# same goes for a `ver=` line written in one version's grammar while declaring the other's.
# The contract lives in the firmware tree as Z3660_emu/src/uae/z3660_prof.h and
# docs/profiler.md; this file is written against it and does not have to be rebuilt in step
# with the firmware.
#
# Standard library only, and no cross toolchain: a capture is often read on a machine that
# has neither.  The kernel ELF is parsed here directly (see SymbolTable) and `--symbols`
# accepts a saved `nm` dump for the case where only that was kept.

import argparse
import bisect
import os
import re
import struct
import sys

# --------------------------------------------------------------------------------------
# The wire contract.  A capture that disagrees with any of these is refused rather than
# reinterpreted.  What is version-INDEPENDENT lives here; what a version decides lives in
# WIRE_VERSIONS below and nowhere else.
# --------------------------------------------------------------------------------------

# The magic encodes the version -- 'Z3P' + digit -- so that a tool which only greps the
# magic still refuses a version it cannot read.  That redundancy is worth having only if it
# is CHECKED: a header whose magic and version field disagree is a mismatch, not a header
# with one field to believe and one to ignore.
MAGICS = {1: "Z3P1", 2: "Z3P2"}

# What a dump whose `ver=` line did not survive the capture is read as.  It is a GUESS, and
# it is announced as one wherever it is used -- v1 and v2 disagree about what three of the
# numbers below mean, so reading the wrong one is not a cosmetic error.
VERSION_ASSUMED = 1

REC_SIZE = 8                  # pc:u32 opcode:u16 flags:u16 -- identical in v1 and v2

# The sample record and every flag bit are byte-for-byte identical in v1 and v2.  This is
# the one part of the format that did NOT move, and it is stated because it is what makes a
# v1 sample decoder still correct against a v2 capture.
F_SUPER = 0x0001
F_MMU = 0x0002
F_AMIX = 0x0004
F_CPU040 = 0x0008
F_RSVD_MASK = 0x00F0          # reserved, always 0 in both versions -- masked, not trusted
F_WEIGHT_SH = 8
F_WEIGHT_MAX = 255

# Bucket and counter names in wire order, per version.  The capture carries the names too;
# these exist so that a name arriving under an id it does not belong to is caught.  That is
# a version drift the `version` field did not catch, and it would silently relabel a whole
# profile -- which is exactly what v2's two RENAMES do to a reader who assumes v1.
#
# The ids are APPEND-ONLY across versions.  Nothing was renumbered: two names were corrected
# to say what they had always counted (bucket 8, counter 12) and four entries were appended
# (buckets 11..13, counter 19).  So one set of id constants serves both versions, and the id
# constants below are named for what the id actually COUNTS rather than for what v1 called
# it -- C_XLATE_OK is id 12 in a v1 dump too, where the wire spells it `ATC_HIT`.
BUCKET_NAMES_V1 = ["LOOP", "FETCHOP", "FETCHEX", "READ", "WRITE",
                   "XLATE", "WALK", "HANDLER", "TAIL", "FAULT", "PROF"]
BUCKET_NAMES_V2 = ["LOOP", "FETCHOP", "FETCHEX", "READ", "WRITE",
                   "XLATE", "WALK", "HANDLER", "TAILADV", "FAULT", "PROF",
                   "TAILSAMP", "TAILPOLL", "TAILSPEC"]
B_LOOP, B_FETCHOP, B_FETCHEX, B_READ, B_WRITE, \
    B_XLATE, B_WALK, B_HANDLER, B_TAIL, B_FAULT, B_PROF, \
    B_TAILSAMP, B_TAILPOLL, B_TAILSPEC = range(14)
N_BUCKETS = 14                # the widest version; a narrower one simply has fewer rows

COUNTER_NAMES_V1 = ["INSNS", "INSNS_SUPER", "FETCH", "READ", "WRITE",
                    "IPAGE_HIT", "IPAGE_MISS", "DPAGE_RHIT", "DPAGE_RMISS",
                    "DPAGE_WHIT", "DPAGE_WMISS", "XLATE", "ATC_HIT", "ATC_MISS",
                    "MISALIGN_R", "MISALIGN_W", "FAULTS", "TRANSITIONS", "STACK_OVF"]
COUNTER_NAMES_V2 = ["INSNS", "INSNS_SUPER", "FETCH", "READ", "WRITE",
                    "IPAGE_HIT", "IPAGE_MISS", "DPAGE_RHIT", "DPAGE_RMISS",
                    "DPAGE_WHIT", "DPAGE_WMISS", "XLATE", "XLATE_OK", "ATC_MISS",
                    "MISALIGN_R", "MISALIGN_W", "FAULTS", "TRANSITIONS", "STACK_OVF",
                    "ATC_HIT"]
C_INSNS, C_INSNS_SUPER, C_FETCH, C_READ, C_WRITE, \
    C_IPAGE_HIT, C_IPAGE_MISS, C_DPAGE_RHIT, C_DPAGE_RMISS, \
    C_DPAGE_WHIT, C_DPAGE_WMISS, C_XLATE, C_XLATE_OK, C_ATC_MISS, \
    C_MISALIGN_R, C_MISALIGN_W, C_FAULTS, C_TRANSITIONS, C_STACK_OVF, \
    C_ATC_HIT = range(20)

BUILD_PROBES, BUILD_PERF, BUILD_PROF = 0x01, 0x02, 0x04

# Where the header's Hz figures came from.  v2 only; a v1 dump carries no such field and no
# way to find out, which is the whole reason the field exists.
CLK_BSP, CLK_CFG = "bsp", "cfg"

TWO32 = 1 << 32

# --------------------------------------------------------------------------------------
# THE VERSION SEAM.
#
# Two things about a dump cannot be read out of the dump: what `probe_cyc` PRICES, and what
# a counter MEANS where its name is wrong about it.  Both are properties of the firmware
# that emitted the dump, both are versioned by the header's `version` field, and both DID
# change between the two versions -- so they live here, in one table, instead of being
# spelled inline at the places that use them.  Everything keyed on the version number in
# this file reads WIRE_VERSIONS; nothing else tests the version directly.
#
# VERSION 1 -- the original instrument, still read as it was written.  Old captures are not
# re-takeable, so this entry is frozen: it describes a firmware that will not change again.
#
#   `probe_cyc` prices an enter/exit PAIR.  z3660_prof_calibrate_probe() times 256
#   iterations of enter() followed by exit() and divides the total by 256.  `TRANSITIONS`,
#   meanwhile, counts each enter AND each exit separately -- z3660_prof_enter() and
#   z3660_prof_exit() each do one TRANSITIONS++.  So `TRANSITIONS x probe_cyc`, which the
#   firmware itself prints and which this tool used to inherit, prices every pair twice.
#   The priced quantity is TRANSITIONS / 2 pairs, and the per-transition cost is
#   probe_cyc / 2.  The same 2 appears in probe_landing() for the same reason: one bucket
#   visit is one enter plus one exit, which is why the landing model's transition total is
#   twice its entry total.
#
#   `ATC_HIT` does not count ATC lookups that hit.  It counts translates that SUCCEEDED.
#   Two identities hold exactly on an intact version-1 dump, confirmed on four independent
#   metal spans of seven-digit size:
#
#       IPAGE_MISS + DPAGE_RMISS + DPAGE_WMISS  ==  XLATE
#       ATC_HIT + FAULTS                        ==  XLATE
#
#   so XLATE is exactly the tier-0 miss count -- the calls into mmu_translate -- and
#   ATC_HIT carries no ATC information whatsoever.  `ATC_HIT + ATC_MISS` is a meaningless
#   sum and is not computed here.  The ATC hit rate is (XLATE - ATC_MISS) / XLATE and the
#   walk rate is ATC_MISS / XLATE; neither needs ATC_HIT.
#
# VERSION 2 -- what the firmware lane shipped, and what it means here.
#
#   Both v1 defects are fixed at the source, and each fix changes what a dump PRINTS:
#
#   `probe_cyc` NOW PRICES ONE TRANSITION.  The calibration times out-of-line enter() and
#   exit() wrappers separately instead of an inlined pair, so the figure multiplies
#   TRANSITIONS directly -- transitions_per_probe_unit is 1, and halving it here the way a
#   v1 figure must be halved would understate the instrument by exactly 2x.  It follows
#   that an over-large probe is no longer this tool's arithmetic to fix: if
#   TRANSITIONS x probe_cyc exceeds the measured total the INSTRUMENT is wrong, and the
#   subtraction is withheld and reported rather than clamped.  In v1 a clamp was the right
#   disclosure, because there the tool was correcting a price it knew to be doubled and a
#   clamp said "your override is too high"; in v2 the price is the firmware's own, so a
#   clamp would hide an instrument fault behind a plausible table.  That is what
#   `probe_exceeds_total_is_fatal` selects.
#
#   ID 12 IS `XLATE_OK` AND ID 19 IS A REAL `ATC_HIT`.  Id 12 did not change what it
#   counts -- translates that returned an address -- only what it is called, which is why
#   the v1 identity survives verbatim under the corrected name.  The genuinely new counter
#   is id 19, and it is the only one the ATC hit rate may be computed from.
#
#   BUCKET 8 IS THE TAIL RESIDUE, NOT THE TAIL.  v2 nests TAILSAMP/TAILPOLL/TAILSPEC
#   (11/12/13) inside it, so the whole tail -- the quantity a v1 capture called TAIL -- is
#   the sum of all four, and the firmware prints that sum on its own `[PROF] t` line so the
#   two versions can be laid side by side.  TAILSAMP is the profiler's OWN sampler hook: it
#   is instrument cost, it was charged to LOOP in v1 where no capture could see it, and it
#   is to be subtracted rather than ranked.
#
#   The clock fields moved too, but that is not a semantics change this table has to carry:
#   cpu_hz/wall_hz are the RUNTIME rate in v2 and the header says so with `clk=cfg|bsp`.
#   `clk` is parsed and surfaced wherever it appears, and `clk=bsp` is warned about hard --
#   see _clk_note(), which also states why the wrap cross-check cannot stand in for it.
#
# WHAT A NEW ENTRY HERE DOES NOT COVER, and what has to be re-read from the firmware
# alongside it: BUCKET_PARENT and bucket_entries().  Those are the interpreter's nesting
# shape and its entry counts rather than wire facts, and a version that adds or re-parents
# a stage changes both -- v2 added three children of B_TAIL and two counters' worth of
# entries, and neither could have been derived from this table.
# --------------------------------------------------------------------------------------

WIRE_VERSIONS = {
    1: {
        "probe_unit": "enter/exit pair",
        "probe_unit_short": "pair",
        "transitions_per_probe_unit": 2,
        "probe_exceeds_total_is_fatal": False,
        "bucket_names": BUCKET_NAMES_V1,
        "counter_names": COUNTER_NAMES_V1,
        "hdr_extra_keys": (),
        "has_clk": False,
        "tail_ids": (B_TAIL,),
        "tail_instrument_id": None,
        "atc_hit_id": None,             # no counter in v1 counts ATC hits
        "id12_name": "ATC_HIT",         # what the wire spells id 12 in this version
        "atc_hit_means": "translates that SUCCEEDED, not ATC lookups that hit",
        "atc_hit_identity": "ATC_HIT + FAULTS == XLATE",
        "tier0_identity": "IPAGE_MISS + DPAGE_RMISS + DPAGE_WMISS == XLATE",
        "atc_sum_identity": None,
    },
    2: {
        "probe_unit": "phase transition",
        "probe_unit_short": "transition",
        "transitions_per_probe_unit": 1,
        "probe_exceeds_total_is_fatal": True,
        "bucket_names": BUCKET_NAMES_V2,
        "counter_names": COUNTER_NAMES_V2,
        "hdr_extra_keys": ("probe_cyc", "clk"),
        "has_clk": True,
        "tail_ids": (B_TAIL, B_TAILSAMP, B_TAILPOLL, B_TAILSPEC),
        "tail_instrument_id": B_TAILSAMP,
        "atc_hit_id": C_ATC_HIT,        # id 19, and it counts what its name says
        "id12_name": "XLATE_OK",        # the same counter v1 spells ATC_HIT
        "atc_hit_means": "translates that RETURNED AN ADDRESS",
        "atc_hit_identity": "XLATE_OK + FAULTS == XLATE",
        "tier0_identity": "IPAGE_MISS + DPAGE_RMISS + DPAGE_WMISS == XLATE",
        "atc_sum_identity": "ATC_HIT + ATC_MISS == XLATE (when no translate faulted)",
    },
}

# Versions the firmware lane has said are coming but has not published a contract for.
# Empty now that version 2 has landed and graduated into WIRE_VERSIONS above; the mechanism
# is kept because it is what made the v1->v2 refusal say something useful instead of
# "unknown version", and the next bump gets the same treatment for the same reason.
WIRE_VERSIONS_PENDING = {}


class CaptureError(Exception):
    """A capture that cannot be trusted.  Always carries the line that proves it."""


def wire_semantics(version, no, what):
    """The version-keyed semantics for a dump, or a refusal naming which unknown this is.

    `what` names the line that carried the version, because every refusal in this tool has
    to be traceable to a line of the capture."""
    sem = WIRE_VERSIONS.get(version)
    if sem is not None:
        return sem
    implemented = ", ".join(str(v) for v in sorted(WIRE_VERSIONS))
    pending = WIRE_VERSIONS_PENDING.get(version)
    if pending is not None:
        raise CaptureError(
            "capture line %d: %s reports version %d; this tool implements version %s "
            "only.\n%s\n"
            "        Refusing rather than guessing: fill in WIRE_VERSIONS[%d] in this file "
            "from\n        the firmware's z3660_prof.h and docs/profiler.md once it lands "
            "-- the seam is\n        one table entry, and every version-dependent decision "
            "here reads it."
            % (no, what, version, implemented, pending, version))
    raise CaptureError(
        "capture line %d: %s reports version %d; this tool implements version %s only.\n"
        "        Refusing rather than guessing -- the record layout, the flag bits and the\n"
        "        dump grammar are all versioned by that one number, so a guess would "
        "silently\n        relabel every row of the dump."
        % (no, what, version, implemented))


def version_grammar_mismatch(no, what, declared, written):
    """A line whose GRAMMAR belongs to one version while its `ver=`/`magic` says another.

    This is its own refusal because it is its own failure: not an unknown version, but a
    line that answers the version question twice and disagrees with itself.  It is exactly
    what a hand-edited capture, a mixed-firmware paste, or a fixture generator that bumped
    a number without bumping a format looks like -- and every one of those would otherwise
    be read under whichever of the two answers the parser happened to consult first.

    The two versions price the probe in different units and name two ids differently, so
    picking an answer here is picking a wrong number somewhere below."""
    raise CaptureError(
        "capture line %d: %s declares version %d but is written in the version-%d "
        "grammar.\n"
        "        The line says version %d and the format it is written in says version "
        "%d, and\n        those cannot both be true.  Refusing rather than believing one "
        "of them: v1 and v2\n        price `probe_cyc` in different units (a pair vs one "
        "transition) and disagree\n        about what counter id 12 and bucket id 8 are "
        "called, so guessing wrong here does\n        not produce an error further down -- "
        "it produces a plausible wrong number."
        % (no, what, declared, written, declared, written))


# --------------------------------------------------------------------------------------
# Opcode naming.
#
# A static table, checked most-specific first, with the 68k line-major group as the
# fallback.  This is deliberately NOT a disassembler: the question the opcode histogram
# answers is "which handlers would a dispatch specialisation have to cover", and a group
# name plus the exact hot singletons answers it.  Anything finer would need the extension
# words, which the 8-byte record does not carry.
# --------------------------------------------------------------------------------------

CC = ["T", "F", "HI", "LS", "CC", "CS", "NE", "EQ",
      "VC", "VS", "PL", "MI", "GE", "LT", "GT", "LE"]

# (mask, match, mnemonic).  Order is significant; the first match wins.
OPCODE_TABLE = [
    # line 4, the exact singletons first -- these are the ones a hot profile actually names
    (0xFFFF, 0x4AFC, "ILLEGAL"),
    (0xFFFF, 0x4E70, "RESET"),
    (0xFFFF, 0x4E71, "NOP"),
    (0xFFFF, 0x4E72, "STOP"),
    (0xFFFF, 0x4E73, "RTE"),
    (0xFFFF, 0x4E74, "RTD"),
    (0xFFFF, 0x4E75, "RTS"),
    (0xFFFF, 0x4E76, "TRAPV"),
    (0xFFFF, 0x4E77, "RTR"),
    (0xFFF8, 0x4840, "SWAP"),            # before PEA: same base, register-direct ea
    (0xFFF8, 0x4808, "LINK.L"),
    (0xFFF8, 0x4880, "EXT.W"),           # before MOVEM: register-direct ea
    (0xFFF8, 0x48C0, "EXT.L"),
    (0xFFF8, 0x49C0, "EXTB.L"),
    (0xFFF8, 0x4E50, "LINK.W"),
    (0xFFF8, 0x4E58, "UNLK"),
    (0xFFF8, 0x4E60, "MOVE to USP"),
    (0xFFF8, 0x4E68, "MOVE from USP"),
    (0xFFF0, 0x4E40, "TRAP"),
    (0xFFC0, 0x4840, "PEA"),
    (0xFFC0, 0x4AC0, "TAS"),
    (0xFFC0, 0x4E80, "JSR"),
    (0xFFC0, 0x4EC0, "JMP"),
    (0xFB80, 0x4880, "MOVEM"),
    (0xF1C0, 0x4100, "CHK"),
    (0xF1C0, 0x41C0, "LEA"),
    (0xFF00, 0x4000, "NEGX"),
    (0xFF00, 0x4200, "CLR"),
    (0xFF00, 0x4400, "NEG"),
    (0xFF00, 0x4600, "NOT"),
    (0xFF00, 0x4A00, "TST"),
    # line 0 -- immediates and static bit operations
    (0xF138, 0x0108, "MOVEP"),
    (0xFFC0, 0x0800, "BTST #"),
    (0xFFC0, 0x0840, "BCHG #"),
    (0xFFC0, 0x0880, "BCLR #"),
    (0xFFC0, 0x08C0, "BSET #"),
    (0xF1C0, 0x0100, "BTST"),
    (0xF1C0, 0x0140, "BCHG"),
    (0xF1C0, 0x0180, "BCLR"),
    (0xF1C0, 0x01C0, "BSET"),
    (0xFF00, 0x0000, "ORI"),
    (0xFF00, 0x0200, "ANDI"),
    (0xFF00, 0x0400, "SUBI"),
    (0xFF00, 0x0600, "ADDI"),
    (0xFF00, 0x0A00, "EORI"),
    (0xFF00, 0x0C00, "CMPI"),
    # lines 1/2/3 -- MOVE.  MOVEA is the destination-mode-001 case and is worth separating:
    # it is the address-arithmetic traffic, not the data traffic.
    (0xF1C0, 0x2040, "MOVEA.L"),
    (0xF1C0, 0x3040, "MOVEA.W"),
    (0xF000, 0x1000, "MOVE.B"),
    (0xF000, 0x2000, "MOVE.L"),
    (0xF000, 0x3000, "MOVE.W"),
    # line 5
    (0xF0F8, 0x50C8, "DBcc"),
    (0xF0F8, 0x50FA, "TRAPcc"),
    (0xF0C0, 0x50C0, "Scc"),
    (0xF100, 0x5000, "ADDQ"),
    (0xF100, 0x5100, "SUBQ"),
    # line 6
    (0xFF00, 0x6000, "BRA"),
    (0xFF00, 0x6100, "BSR"),
    # line 7
    (0xF100, 0x7000, "MOVEQ"),
    # line 8
    (0xF1F0, 0x8100, "SBCD"),
    (0xF1C0, 0x80C0, "DIVU"),
    (0xF1C0, 0x81C0, "DIVS"),
    (0xF000, 0x8000, "OR"),
    # line 9
    (0xF130, 0x9100, "SUBX"),
    (0xF0C0, 0x90C0, "SUBA"),
    (0xF000, 0x9000, "SUB"),
    # line B
    (0xF138, 0xB108, "CMPM"),
    (0xF0C0, 0xB0C0, "CMPA"),
    (0xF100, 0xB100, "EOR"),
    (0xF000, 0xB000, "CMP"),
    # line C
    (0xF1F0, 0xC100, "ABCD"),
    (0xF130, 0xC100, "EXG"),
    (0xF1C0, 0xC0C0, "MULU"),
    (0xF1C0, 0xC1C0, "MULS"),
    (0xF000, 0xC000, "AND"),
    # line D
    (0xF130, 0xD100, "ADDX"),
    (0xF0C0, 0xD0C0, "ADDA"),
    (0xF000, 0xD000, "ADD"),
    # line E -- shifts, rotates, and the 020+ bitfield block
    (0xF8C0, 0xE8C0, "bitfield"),
    (0xF0C0, 0xE0C0, "shift/rot mem"),
    (0xF000, 0xE000, "shift/rot reg"),
    # line F -- coprocessor space.  On the 040/060 this is the FPU, the MMU instructions and
    # the cache/MOVE16 group, and telling them apart matters: CPUSH/CINV traffic is a
    # cache-coherency cost and PFLUSH is a translation cost.
    (0xFFE0, 0xF620, "MOVE16"),
    (0xFF20, 0xF400, "CINV"),
    (0xFF20, 0xF420, "CPUSH"),
    (0xFFC0, 0xF500, "PFLUSH (040)"),
    (0xFFD8, 0xF548, "PTEST (040)"),
    (0xFFC0, 0xF000, "PMMU (030)"),
    (0xFFC0, 0xF200, "FPU general"),
    (0xFFC0, 0xF280, "FBcc"),
    (0xFFC0, 0xF300, "FSAVE"),
    (0xFFC0, 0xF340, "FRESTORE"),
]

LINE_NAMES = [
    "immediate / static bit",
    "MOVE.B",
    "MOVE.L / MOVEA.L",
    "MOVE.W / MOVEA.W",
    "misc (LEA/JSR/MOVEM/TST/CLR)",
    "ADDQ/SUBQ/Scc/DBcc",
    "Bcc/BSR/BRA",
    "MOVEQ",
    "OR/DIV/SBCD",
    "SUB/SUBA/SUBX",
    "line-A (unimplemented)",
    "CMP/CMPA/EOR/CMPM",
    "AND/MUL/ABCD/EXG",
    "ADD/ADDA/ADDX",
    "shift / rotate / bitfield",
    "line-F (FPU/MMU/cache)",
]


def mnemonic(op):
    """Name an opcode word.  Never raises; an unmatched word gets its line-group name."""
    for mask, match, name in OPCODE_TABLE:
        if (op & mask) == match:
            if name == "BRA" and (op & 0x00FF) == 0x00FF:
                return "BRA.L"
            return name
    line = (op >> 12) & 0xF
    if line == 0x6:                       # Bcc, with the condition spelled out
        return "B%s" % CC[(op >> 8) & 0xF]
    return "line-%X" % line


# --------------------------------------------------------------------------------------
# Symbols.
#
# The kernel is an ET_REL image whose sections all sit at vaddr 0; the loader binds it at a
# base it chooses, and the runtime address of a text symbol is `base + st_value`.  The base
# is NOT a constant -- every accelerator this project has used has its own RAM at
# 0x08000000, but an A3640 runs from A3000 motherboard RAM at 0x07000000 and every address
# here would be wrong by 16 MiB.  Take it from the loader's own boot line:
#
#     kernel: entry=08000000 tvaddr=08000000 tsize=000f2910 ...
#                            ^^^^^^^^ --load-base
#
# .data and .bss follow .text in the bound image, which is why their runtime addresses need
# the text size added.  They are tracked here not to symbolize PCs but to bound .text: with
# no upper bound, every PC past the last function is silently attributed to it, and a PC
# that landed in .data -- which is a finding, not a footnote -- would look like ordinary
# execution of whatever symbol happened to be last.
# --------------------------------------------------------------------------------------

STT_FUNC, STT_OBJECT, STT_NOTYPE = 2, 1, 0
ET_REL = 1


def is_asm_local(name, is_global):
    """A LOCAL label the assembler generated, not a function.

    The SGS assembler this kernel is built with names its internal labels with a `%` --
    `L%done`, `LC%17`, `Lsncpy%`, and the per-object `gcc_compiled%` marker.  A C
    identifier cannot contain `%`, so a LOCAL symbol that does is never a function name.

    This is not cosmetic.  1875 of the 7462 .text symbols in a current build/unix-040 are
    such labels, and they sit INSIDE functions: a PC sampled in the middle of a loop
    resolves to `L%done+0x4` instead of to the function containing it, and the flat profile
    then splits one hot function across a dozen label-named rows.  Filtering them is what
    makes the by-symbol aggregation mean anything on a real artifact.  --all-symbols turns
    it off, and the count filtered is always reported so the reader knows it happened."""
    return (not is_global) and ("%" in name or name.startswith(".L"))


class SymbolTable(object):
    def __init__(self, label):
        self.label = label
        self.text = []            # [(runtime addr, name, is_global, is_func)]
        self._addrs = []
        self.text_lo = 0
        self.text_hi = 0
        self.data_lo = 0
        self.data_hi = 0          # .data + .bss together: "not text, but inside the image"
        self.notes = []
        self.filtered = 0

    def _finish(self, keep_all=False):
        if not keep_all:
            kept = [t for t in self.text if not is_asm_local(t[1], t[2])]
            self.filtered = len(self.text) - len(kept)
            self.text = kept
        # Several symbols can share an address (`krnxmemflt` and its retained `_orig` alias
        # are the normal case here).  Pick one deterministically -- a real function first,
        # then global over local, then shortest, then lexicographic -- so two runs of this
        # tool over one capture produce byte-identical output.  A profile whose column text
        # moves between runs cannot be diffed, and diffing two profiles is most of what
        # this is for.
        best = {}
        for addr, name, is_global, is_func in self.text:
            key = (0 if is_func else 1, 0 if is_global else 1, len(name), name)
            if addr not in best or key < best[addr][0]:
                best[addr] = (key, name)
        self.text = sorted((a, v[1]) for a, v in best.items())
        self._addrs = [a for a, _ in self.text]

    def lookup(self, pc):
        """(name, offset, kind) or None.  kind is 'text', 'data' or None."""
        if self.text_lo <= pc < self.text_hi:
            i = bisect.bisect_right(self._addrs, pc) - 1
            if i >= 0:
                addr, name = self.text[i]
                return (name, pc - addr, "text")
            return ("%s+" % self.label, pc - self.text_lo, "text")
        if self.data_lo <= pc < self.data_hi:
            return ("%s .data/.bss" % self.label, pc - self.data_lo, "data")
        return None


def _elf_sections_and_syms(path):
    """Parse an ELF32 for its section table and symbol table.  Stdlib only, on purpose:
    a capture is routinely read on a host with no cross binutils installed."""
    with open(path, "rb") as fh:
        f = fh.read()
    if len(f) < 52 or f[:4] != b"\x7fELF":
        raise CaptureError("%s: not an ELF file" % path)
    if f[4] != 1:
        raise CaptureError("%s: ELFCLASS64 -- this reads 32-bit m68k images only" % path)
    end = ">" if f[5] == 2 else "<"

    def u16(o):
        return struct.unpack(end + "H", f[o:o + 2])[0]

    def u32(o):
        return struct.unpack(end + "I", f[o:o + 4])[0]

    e_type = u16(16)
    e_shoff, e_shentsize, e_shnum, e_shstrndx = u32(32), u16(46), u16(48), u16(50)
    secs = []
    for i in range(e_shnum):
        b = e_shoff + i * e_shentsize
        secs.append(dict(name=u32(b), type=u32(b + 4), addr=u32(b + 12), off=u32(b + 16),
                         size=u32(b + 20), link=u32(b + 24), entsize=u32(b + 36)))
    shstr = secs[e_shstrndx]["off"]
    for s in secs:
        o = shstr + s["name"]
        s["nm"] = f[o:f.index(b"\0", o)].decode("latin1")

    syms = []
    for s in secs:
        if s["type"] != 2:                          # SHT_SYMTAB
            continue
        strtab = secs[s["link"]]["off"]
        n = s["size"] // (s["entsize"] or 16)
        for i in range(n):
            b = s["off"] + i * 16
            st_name, st_value = u32(b), u32(b + 4)
            st_info, st_shndx = f[b + 12], u16(b + 14)
            if st_name == 0 or st_shndx == 0 or st_shndx >= 0xFF00:
                continue
            o = strtab + st_name
            name = f[o:f.index(b"\0", o)].decode("latin1")
            syms.append((name, st_value, st_info >> 4, st_info & 0xF, st_shndx))
    return e_type, secs, syms


def load_elf_symbols(path, base, label, keep_all=False):
    e_type, secs, syms = _elf_sections_and_syms(path)
    byidx = {i: s for i, s in enumerate(secs)}
    text = next((i for i, s in enumerate(secs) if s["nm"] == ".text"), None)
    if text is None:
        raise CaptureError("%s: no .text section" % path)
    tsize = secs[text]["size"]
    dsize = sum(s["size"] for s in secs if s["nm"] in (".data", ".bss"))

    st = SymbolTable(label)
    if e_type == ET_REL:
        # Relocatable: section-relative values, laid out text-then-data at the load base.
        st.text_lo, st.text_hi = base, base + tsize
        st.data_lo, st.data_hi = base + tsize, base + tsize + dsize
        st.notes.append("ET_REL image: runtime = load base 0x%08X + section offset "
                        "(.text 0x%X, .data+.bss 0x%X)" % (base, tsize, dsize))
        for name, val, bind, typ, shndx in syms:
            sec = byidx.get(shndx)
            if sec is not None and sec["nm"] == ".text" and typ in (STT_FUNC, STT_NOTYPE):
                st.text.append((base + val, name, bind == 1, typ == STT_FUNC))
    else:
        # Executable/shared: st_value is already a virtual address.  --user-base is added
        # anyway so a position-independent image loaded somewhere can still be mapped.
        lo = min((s["addr"] for s in secs if s["addr"]), default=0)
        st.text_lo = base + secs[text]["addr"]
        st.text_hi = st.text_lo + tsize
        st.data_lo, st.data_hi = st.text_hi, st.text_hi + dsize
        st.notes.append("ET_EXEC/ET_DYN image: runtime = vaddr + 0x%08X (lowest vaddr "
                        "0x%08X)" % (base, lo))
        for name, val, bind, typ, shndx in syms:
            sec = byidx.get(shndx)
            if sec is not None and sec["nm"] == ".text" and typ in (STT_FUNC, STT_NOTYPE):
                st.text.append((base + val, name, bind == 1, typ == STT_FUNC))
    st._finish(keep_all)
    if not st.text:
        raise CaptureError("%s: no .text symbols -- is the image stripped?" % path)
    return st


NM_RE = re.compile(r"^\s*([0-9a-fA-F]+)\s+([A-Za-z])\s+(\S+)\s*$")


def load_nm_symbols(path, base, text_size, label, keep_all=False):
    """The `nm` fallback, for a host that kept a symbol dump but not the artifact.

    `nm` flattens sections: a .text symbol and a .data symbol both report values counted
    from zero, so their values overlap and the text size is the only thing that says where
    text stops.  That is why --text-size is mandatory here and is not a convenience."""
    st = SymbolTable(label)
    st.text_lo, st.text_hi = base, base + text_size
    st.data_lo, st.data_hi = base + text_size, base + text_size  # unknown extent
    st.notes.append("nm dump: runtime = load base 0x%08X + nm value; .text size 0x%X given"
                    % (base, text_size))
    n = 0
    with open(path) as fh:
        for line in fh:
            m = NM_RE.match(line)
            if not m:
                continue
            n += 1
            val, kind, name = int(m.group(1), 16), m.group(2), m.group(3)
            if kind in "Tt":
                # `nm` does not report STT_FUNC vs STT_NOTYPE, so the function preference
                # is unavailable on this path; the assembler-local filter still applies.
                st.text.append((base + val, name, kind == "T", False))
    if not st.text:
        raise CaptureError("%s: no T/t symbols in %d parsed nm lines" % (path, n))
    st._finish(keep_all)
    return st


# --------------------------------------------------------------------------------------
# Capture parsing.
# --------------------------------------------------------------------------------------

# The boot line is the only proof that core1 is the profiling image at all, and it is the
# one line whose SHAPE differs between versions in a way worth matching exactly: v1 printed
# a per-PAIR probe cost with no clock source, v2 prints a per-TRANSITION cost, the pair
# figure in brackets after it, and where the clock came from.  Two exact patterns rather
# than one loose one, because the unit is carried by the wording and by nothing else.
RE_BOOT_V1 = re.compile(r"^\[PROF\] profiling build: ARM clock (\d+) Hz \(measured\), "
                        r"enter/exit pair (-?\d+) cyc, ring (\d+) x (\d+) B\s*$")
RE_BOOT_V2 = re.compile(r"^\[PROF\] profiling build v(\d+): ARM clock (\d+) Hz "
                        r"\(clk=(\w+), PMU:wall \d+\.\d+\), probe (-?\d+) cyc/transition "
                        r"\(-?\d+ cyc/pair\), ring (\d+) x (\d+) B\s*$")
RE_HDR = re.compile(r"^\[PROF\] ring hdr (.*)$")
RE_BEGIN = re.compile(r"^\[PROF\] ring begin\s*$")
RE_END = re.compile(r"^\[PROF\] ring end n=(\d+)\s*$")
RE_SAMPLE = re.compile(r"^S ([0-9a-f]{8}) ([0-9a-f]{4}) ([0-9a-f]{4})\s*$")
RE_STATS_TOP = re.compile(r"^\[PROF\] === stage attribution ===\s*$")
RE_STATS_END = re.compile(r"^\[PROF\] === end ===\s*$")
# Same story for the stats header.  v2 inserts `clk=` and spells the probe field
# `probe_cyc_per_transition=` -- the firmware renamed the key precisely so that a v1 reader
# cannot silently pick up a number in a unit it does not expect.  Honour that: a line in
# one grammar declaring the other version is refused, not reconciled.
RE_VER_V1 = re.compile(r"^\[PROF\] ver=(\d+) build=0x([0-9A-Fa-f]+) cpu_hz=(\d+) hz=(\d+) "
                       r"period_cyc=(\d+) probe_cyc=(-?\d+)\s*$")
RE_VER_V2 = re.compile(r"^\[PROF\] ver=(\d+) build=0x([0-9A-Fa-f]+) cpu_hz=(\d+) "
                       r"clk=(\w+) hz=(\d+) period_cyc=(\d+) "
                       r"probe_cyc_per_transition=(-?\d+)\s*$")
RE_TOTAL = re.compile(r"^\[PROF\] total_cyc=(\d+) wall_ticks=(\d+) wall_hz=(\d+)\s*$")
RE_BUCKET = re.compile(r"^\[PROF\] b (\d+)\s+(\S+)\s+cyc=(\d+)\s+(\d+\.\d+)%\s*$")
RE_COUNTER = re.compile(r"^\[PROF\] c (\d+)\s+(\S+)\s+(\d+)\s*$")
# v2's whole-tail rollup: the firmware's OWN sum of the four tail ids, printed so a v2
# capture can be laid beside a v1 one.  It is parsed not to be reported -- this tool can add
# four numbers -- but to be CROSS-CHECKED against the four bucket rows, which is a free
# check that the dump's `b` lines and its `t` line came off the same span.
RE_TAIL = re.compile(r"^\[PROF\] t whole tail \(([A-Z+]+)\) cyc=(\d+)\s+(\d+\.\d+)%")
RE_KV = re.compile(r"([A-Za-z_]+)=(\S+)")

# --------------------------------------------------------------------------------------
# Two repairs, for captures that are INTACT but were delivered dirty.  Both are narrow on
# purpose: a repair that can absorb a real loss is worse than a refusal, because it turns a
# hard error into a plausible number.  Neither of these can -- the record count, the header
# and the `ring end n=` terminator are still cross-checked afterwards, and they are what
# actually proves a dump whole.
#
# 1. A LOGGER LINE PREFIX.  A serial console captured through a logger (the KVM's, for one)
#    carries "HH:MM:SS " ahead of the firmware's own output on every line.  Only a
#    timestamp-shaped prefix is stripped, and only from a line that is firmware output
#    without it -- so a line with arbitrary bytes in front of it is still not a line this
#    tool will parse.
#
# 2. A `ring hdr` LINE THAT LOST ITS "[PROF] ".  The console echo of the command that
#    requested the dump and the firmware's first header line collide in the one UART, and
#    what arrives is the header with its literal prefix eaten or run together with the echo
#    ("...~2 min of seri[lROF] ring hdr magic=Z3P1 ...").  The payload is what carries the
#    dump's identity, and it is repairable only when it is COMPLETE: the recovered
#    key=value set has to be exactly one of the two header lines the format defines.  A
#    payload missing a field is not repaired: the line is not recognised as a header at
#    all, and _check_ring_header() then refuses the dump naming the fields that never
#    arrived.
# --------------------------------------------------------------------------------------

RE_LOG_PREFIX = re.compile(r"^\[?(?:\d{4}-\d{2}-\d{2}[T ])?"
                           r"\d{1,2}:\d{2}:\d{2}(?:[.,]\d{1,6})?\]?[ \t]+")
RE_HDR_SALVAGE = re.compile(r"ring hdr (\S+=\S+(?: \S+=\S+)*)\s*$")

# The `ring hdr` lines the format emits, by their exact field sets.  "Complete" means equal
# to one of these -- not "contains", so a truncated payload cannot pass as one.  Salvage
# happens before the version is known, so every version's second line is listed; which one
# a given header must have is decided afterwards, in _check_ring_header(), from the version
# the first line declares.
HDR_LINE1_KEYS = frozenset(("magic", "version", "rec_size", "rec_count",
                            "ring_entries", "hz", "period_cyc", "cpu_hz"))
HDR_LINE2_COMMON = frozenset(("samples", "drops", "cyc_span", "wall_ticks", "wall_hz"))
HDR_KEYS = [
    HDR_LINE1_KEYS,
    HDR_LINE2_COMMON | frozenset(("build",)),                          # v1
    HDR_LINE2_COMMON | frozenset(("build", "probe_cyc", "clk")),       # v2
]
# What must be present before a header is interpreted at all, independent of version.
# `build` stays out of it: it is tolerated as absent by the reader below, and adding it
# here would turn a survivable gap into a refusal.
HDR_REQUIRED_COMMON = HDR_LINE1_KEYS | HDR_LINE2_COMMON


def _strip_log_prefix(line):
    """Return (payload, prefix): a timestamp prefix removed only when what remains is
    recognisably firmware output.  Nothing in the prefix is ever used."""
    m = RE_LOG_PREFIX.match(line)
    if not m:
        return line, ""
    rest = line[m.end():]
    if (rest.startswith("[PROF]") or rest.startswith("S ")
            or re.match(r"^S[0-9a-f ]", rest) or "ring hdr " in rest):
        return rest, m.group(0)
    return line, ""


def _salvage_hdr(line):
    """The key=value payload of a `ring hdr` line whose "[PROF] " did not survive, or None.

    Returned only when the recovered field set is exactly one of the two the format
    defines; a wrong `magic` is deliberately NOT filtered here, because the caller's magic
    check gives a far better error than "the capture starts mid-dump" would."""
    m = RE_HDR_SALVAGE.search(line)
    if not m:
        return None
    payload = m.group(1)
    kv = dict(RE_KV.findall(payload))
    return payload if frozenset(kv) in HDR_KEYS else None


class Ring(object):
    def __init__(self):
        self.hdr = {}
        self.samples = []          # [(pc, opcode, flags)]
        self.first_line = 0
        self.last_line = 0
        self.noise_lines = []      # non-sample lines seen between begin and end
        self.sem = None            # WIRE_VERSIONS entry, from the header's version field


class Stats(object):
    def __init__(self):
        self.first_line = 0
        self.last_line = 0
        self.ver = None
        self.sem = None            # WIRE_VERSIONS entry, from the ver= line
        self.build = 0
        self.cpu_hz = 0
        self.hz = 0
        self.period_cyc = 0
        self.probe_cyc = 0
        self.clk = None            # v2: 'cfg' or 'bsp'; None where the version has no such
        self.total_cyc = 0
        self.wall_ticks = 0
        self.wall_hz = 0
        self.buckets = {}          # id -> cycles
        self.counters = {}         # id -> value
        self.tail_cyc = None       # v2: the firmware's own whole-tail sum, for cross-check
        self.tail_line = 0


def parse_capture(path):
    """Return (rings, stats_dumps, boot, nlines, warnings).

    Every hard error names the capture line that proves it.  The alternative -- a shorter
    profile, quietly -- is the failure mode a fixed-width grammar exists to prevent."""
    warnings = []
    boot = None
    rings, stats = [], []
    ring = None
    st = None
    pending_hdr = {}
    pending_hdr_line = 0

    prefixed, first_prefix, first_prefix_line = 0, "", 0

    with open(path, "r", errors="replace") as fh:
        lines = fh.read().split("\n")
    lines = [ln.rstrip("\r") for ln in lines]

    for no, raw in enumerate(lines, 1):
        line, prefix = _strip_log_prefix(raw)
        if prefix:
            prefixed += 1
            if not first_prefix:
                first_prefix, first_prefix_line = prefix, no

        if ring is not None:
            m = RE_SAMPLE.match(line)
            if m:
                ring.samples.append((int(m.group(1), 16), int(m.group(2), 16),
                                     int(m.group(3), 16)))
                continue
            m = RE_END.match(line)
            if m:
                promised = int(m.group(1))
                ring.last_line = no
                _close_ring(ring, promised, no, line, warnings)
                rings.append(ring)
                ring = None
                continue
            # Anything else between begin and end.  A line the firmware did not write is
            # interleaved console traffic and is survivable; a line that looks like a
            # sample but is not exactly the frozen 20-character form means the serial
            # stream dropped or inserted bytes, and nothing after it can be trusted.
            if line.startswith("S ") or re.match(r"^S[0-9a-f ]", line):
                raise CaptureError(
                    "capture line %d: malformed sample line %r.\n"
                    "        The sample-line grammar is fixed width and is IDENTICAL in v1 and\n        v2: 'S pppppppp oooo ffff'.\n"
                    "        A sample line that is not exactly that means the serial stream\n"
                    "        lost or gained bytes, and the records after it are not reliable."
                    % (no, line))
            if line.strip():
                ring.noise_lines.append((no, line))
            continue

        m = RE_BOOT_V2.match(line)
        if m:
            # The boot line's probe figure is in ITS OWN version's unit, which is not
            # necessarily the unit of a dump later in the same capture (a capture can span
            # a reflash).  The version is recorded with it so the fallback in main() can
            # refuse to cross versions rather than quietly mix a per-pair price into a
            # per-transition calculation.
            boot = dict(version=int(m.group(1)), cpu_hz=int(m.group(2)),
                        clk=m.group(3), probe_cyc=int(m.group(4)),
                        ring_entries=int(m.group(5)), rec_size=int(m.group(6)), line=no)
            wire_semantics(boot["version"], no, "boot line")
            continue
        m = RE_BOOT_V1.match(line)
        if m:
            boot = dict(version=1, cpu_hz=int(m.group(1)), clk=None,
                        probe_cyc=int(m.group(2)), ring_entries=int(m.group(3)),
                        rec_size=int(m.group(4)), line=no)
            continue

        m = RE_HDR.match(line)
        payload = m.group(1) if m else None
        if payload is None:
            payload = _salvage_hdr(line)
            if payload is not None:
                warnings.append(
                    "capture line %d: a 'ring hdr' line arrived without its literal "
                    "'[PROF] ' prefix (%r). Its key=value payload is complete -- exactly "
                    "the fields this format defines -- so the line is REPAIRED here rather "
                    "than the capture refused. Nothing ahead of 'ring hdr' was used, and "
                    "the header/terminator/record-count cross-checks still have to pass."
                    % (no, raw[:72]))
        if payload is not None:
            kv = dict(RE_KV.findall(payload))
            if not pending_hdr:
                pending_hdr_line = no
            pending_hdr.update(kv)
            continue

        if RE_BEGIN.match(line):
            if not pending_hdr:
                raise CaptureError("capture line %d: '[PROF] ring begin' with no preceding "
                                   "'[PROF] ring hdr' lines -- the capture starts mid-dump."
                                   % no)
            ring = Ring()
            ring.hdr = pending_hdr
            ring.first_line = pending_hdr_line
            _check_ring_header(ring, pending_hdr_line)
            pending_hdr, pending_hdr_line = {}, 0
            continue

        if RE_STATS_TOP.match(line):
            st = Stats()
            st.first_line = no
            continue

        if st is not None:
            m = RE_VER_V2.match(line)
            if m:
                st.ver, st.build = int(m.group(1)), int(m.group(2), 16)
                st.cpu_hz, st.clk = int(m.group(3)), m.group(4)
                st.hz, st.period_cyc = int(m.group(5)), int(m.group(6))
                st.probe_cyc = int(m.group(7))
                if st.ver != 2:
                    version_grammar_mismatch(no, "the stats dump's ver= line", st.ver, 2)
                st.sem = wire_semantics(st.ver, no, "stats dump ver= line")
                continue
            m = RE_VER_V1.match(line)
            if m:
                st.ver, st.build = int(m.group(1)), int(m.group(2), 16)
                st.cpu_hz, st.hz = int(m.group(3)), int(m.group(4))
                st.period_cyc, st.probe_cyc = int(m.group(5)), int(m.group(6))
                # A version this tool does not know gets the unknown-version refusal, which
                # is the more useful message; only a version it DOES know, arriving in the
                # wrong grammar, is a mismatch.
                if st.ver != 1 and st.ver in WIRE_VERSIONS:
                    version_grammar_mismatch(no, "the stats dump's ver= line", st.ver, 1)
                st.sem = wire_semantics(st.ver, no, "stats dump ver= line")
                continue
            m = RE_TAIL.match(line)
            if m:
                st.tail_cyc, st.tail_line = int(m.group(2)), no
                continue
            m = RE_TOTAL.match(line)
            if m:
                st.total_cyc, st.wall_ticks, st.wall_hz = (int(m.group(1)), int(m.group(2)),
                                                           int(m.group(3)))
                continue
            # The name tables come from the version seam, not from a global: a version that
            # renames a counter is caught by swapping its table entry, and a name arriving
            # under an id it does not belong to in THAT version is what this check is for.
            sem = st.sem or WIRE_VERSIONS[VERSION_ASSUMED]
            sver = st.ver if st.ver is not None else VERSION_ASSUMED
            m = RE_BUCKET.match(line)
            if m:
                bid, name, cyc = int(m.group(1)), m.group(2), int(m.group(3))
                _check_name(bid, name, sem["bucket_names"], "bucket", no, sver, warnings)
                st.buckets[bid] = cyc
                continue
            m = RE_COUNTER.match(line)
            if m:
                cid, name, val = int(m.group(1)), m.group(2), int(m.group(3))
                _check_name(cid, name, sem["counter_names"], "counter", no, sver, warnings)
                st.counters[cid] = val
                continue
            if RE_STATS_END.match(line):
                st.last_line = no
                stats.append(st)
                st = None
                continue

    if ring is not None:
        raise CaptureError(
            "capture line %d: '[PROF] ring begin' was never closed by a "
            "'[PROF] ring end n=<count>' line.\n"
            "        %d sample lines were read before the capture stopped.  A ring dump is\n"
            "        oldest-first, so a truncated one is a prefix of the newest samples and\n"
            "        cannot be presented as a profile of anything."
            % (ring.first_line, len(ring.samples)))
    if st is not None:
        warnings.append("stats dump beginning at capture line %d was never closed by "
                        "'[PROF] === end ==='; it is reported from what arrived."
                        % st.first_line)
        stats.append(st)
    if not rings and not stats:
        raise CaptureError("%s: no '[PROF]' dump found.  A capture with no ring header and "
                           "no stage attribution block has nothing to symbolize -- check "
                           "that the console log covers the PROFD/PROFR output." % path)
    if prefixed:
        warnings.append(
            "%d capture line(s) carry a logger line prefix ahead of the firmware's own "
            "output (first at line %d: %r). It is stripped before parsing and nothing in "
            "it is used. Only a timestamp-shaped prefix on a line that is firmware output "
            "without it is tolerated, so this does not weaken the truncation checks."
            % (prefixed, first_prefix_line, first_prefix))
    return rings, stats, boot, len(lines), warnings


def _check_name(idx, name, table, what, no, ver, warnings):
    if idx >= len(table):
        warnings.append("capture line %d: %s id %d is beyond the %d version %d defines "
                        "(%s) -- reported but not interpreted."
                        % (no, what, idx, len(table), ver, name))
    elif table[idx] != name:
        warnings.append("capture line %d: %s id %d is named %r here but %r in version %d. "
                        "The ids are append-only, so this is a wire-format drift the "
                        "version field did not catch; every row of this dump is suspect."
                        % (no, what, idx, name, table[idx], ver))


def _check_ring_header(ring, no):
    h = ring.hdr
    # Completeness first, so a header line that did not arrive is reported as a header line
    # that did not arrive.  A damaged-but-complete line is repaired upstream by
    # _salvage_hdr(); reaching here with fields missing means the payload itself was lost,
    # and that is not repairable from anything in the capture.
    _missing(h, HDR_REQUIRED_COMMON, no)

    # Version before magic, because the version field is what says which magic is correct.
    # A version this tool cannot read is refused here whatever the magic says.
    version = int(h.get("version", -1))
    ring.sem = wire_semantics(version, no, "ring header")

    # Now the magic, against the version that header declares.  Two different refusals, and
    # the difference matters to whoever reads it: a magic belonging to ANOTHER KNOWN VERSION
    # is a capture disagreeing with itself, which is a hand-edit or a mixed paste; a magic
    # belonging to no version at all is simply not this format.
    magic, want = h.get("magic"), MAGICS[version]
    if magic != want:
        if magic in MAGICS.values():
            other = next(v for v, m in MAGICS.items() if m == magic)
            raise CaptureError(
                "capture line %d: ring header magic is %r, not %r.\n"
                "        The magic encodes the wire version ('Z3P' + digit), and this "
                "header declares\n        version %d while its magic says version %d.  "
                "Those cannot both be true, and\n        v%d and v%d disagree about the "
                "unit of `probe_cyc` and about what two ids are\n        called -- so "
                "believing either one of them here produces a plausible wrong\n        "
                "number rather than an error.  Refusing."
                % (no, magic, want, version, other, version, other))
        raise CaptureError(
            "capture line %d: ring header magic is %r, not %r.\n"
            "        Refusing.  This is either not a z3660 profiler dump or it is a "
            "format\n        this tool has never seen." % (no, magic, want))

    # The version's own extra header fields, checked separately from the common ones so the
    # message can say WHICH version wanted them -- a v2 header missing `clk=` is a different
    # complaint from a header missing `samples=`.
    extra = ring.sem["hdr_extra_keys"]
    if extra:
        _missing(h, frozenset(extra), no, "version %d ring header" % version)

    rs = int(h.get("rec_size", -1))
    if rs != REC_SIZE:
        raise CaptureError(
            "capture line %d: rec_size is %d, not %d.  Version %d pins the sample record at "
            "%d bytes\n        (pc:u32 opcode:u16 flags:u16); a different size means a "
            "different record." % (no, rs, REC_SIZE, version, REC_SIZE))


def _missing(h, required, no, what="ring header"):
    absent = [k for k in sorted(required) if k not in h]
    if not absent:
        return
    named = ", ".join(repr(k) for k in absent[:4])
    if len(absent) > 4:
        named += " and %d more" % (len(absent) - 4)
    raise CaptureError(
        "capture line %d: %s is missing %s.\n"
        "        Both '[PROF] ring hdr' lines are required, and the capture lost one or "
        "lost part\n        of one.  A `ring hdr` line that merely lost its '[PROF] ' "
        "prefix is repaired; this\n        one lost payload, which nothing in the "
        "capture can reconstruct." % (no, what, named))


def _close_ring(ring, promised, no, line, warnings):
    rec_count = int(ring.hdr["rec_count"])
    got = len(ring.samples)
    if promised != rec_count:
        raise CaptureError(
            "capture line %d: %r -- but the ring header promised rec_count=%d.\n"
            "        The header and the terminator disagree, which means the capture lost\n"
            "        lines between them.  The dump cannot be trusted."
            % (no, line, rec_count))
    if got != promised:
        raise CaptureError(
            "capture line %d: %r -- but %d 'S' sample lines were read, not %d.\n"
            "        The serial capture lost %d line(s).  A ring dump is oldest-first and a\n"
            "        gap of unknown position cannot be repaired: the remaining samples are\n"
            "        real, but no total, share or rate computed over them would be.\n"
            "        Re-take the dump, or capture at a lower rate (PROFR instead of "
            "PROF RING)."
            % (no, line, got, promised, promised - got))
    if ring.noise_lines:
        warnings.append("ring dump at capture line %d: %d non-sample line(s) interleaved "
                        "inside the dump (first at line %d: %r). Console traffic from the "
                        "other core is harmless; check that it is not a truncated sample."
                        % (ring.first_line, len(ring.noise_lines),
                           ring.noise_lines[0][0], ring.noise_lines[0][1][:60]))


# --------------------------------------------------------------------------------------
# Formatting helpers.  Every number this prints is fixed-position on purpose: the output is
# meant to be diffed between two profiles, and a column that moves defeats that.
# --------------------------------------------------------------------------------------

def pct(part, whole):
    return 0.0 if not whole else 100.0 * float(part) / float(whole)


def fpct(part, whole):
    return "%6.2f%%" % pct(part, whole)


def rule(ch="-", n=88):
    return ch * n


def head(title):
    return "\n%s\n%s\n%s" % (rule("="), title, rule("="))


def sec(title):
    return "\n-- %s %s" % (title, "-" * max(0, 85 - len(title)))


# --------------------------------------------------------------------------------------
# The stats dump: stage buckets, the probe-cost subtraction, counters, derived rates.
# --------------------------------------------------------------------------------------

# Where a bucket is entered from.  This is the interpreter's actual nesting, and it is what
# makes the probe subtraction a mechanism rather than an apportionment: see probe_landing().
# The three v2 tail children NEST INSIDE id 8 (read out of the firmware's own run-loop
# macros, not assumed): the tail enters TAILADV, and TAILSAMP/TAILPOLL/TAILSPEC are entered
# and exited within it.  Listing them for a v1 dump is harmless -- v1 never reports those
# ids, so their entry counts are zero and they land nothing anywhere.
BUCKET_PARENT = {
    B_FETCHOP: B_LOOP, B_FETCHEX: B_LOOP, B_READ: B_LOOP, B_WRITE: B_LOOP,
    B_HANDLER: B_LOOP, B_TAIL: B_LOOP, B_PROF: B_LOOP, B_FAULT: B_LOOP,
    B_WALK: B_XLATE,
    B_TAILSAMP: B_TAIL, B_TAILPOLL: B_TAIL, B_TAILSPEC: B_TAIL,
    # XLATE is entered from whichever accessor missed the page cache; its exits are split
    # across the four of them in proportion to their own entry counts.
    B_XLATE: None,
}
XLATE_CALLERS = (B_FETCHOP, B_FETCHEX, B_READ, B_WRITE)


def bucket_entries(c, sem):
    """Model the number of times each bucket is ENTERED, from the exact counters.

    Every one of these is a counter the firmware increments on the same code path that
    enters the bucket, so this is a mapping and not an estimate -- but it is a mapping made
    here, on this side of the wire, and it is checked against the firmware's own exact
    TRANSITIONS count before any number derived from it is printed.

    The v2 tail children are added only for a version that HAS them, because their entry
    counts are what make the model's transition total match: TAILSAMP and TAILPOLL are both
    entered once per instruction -- their probe brackets sit outside the cadence gate, so
    the gate skips the WORK and not the transition -- which is exactly the four extra
    transitions per instruction the firmware's own documentation prices the split at.

    TAILSPEC is modelled at ZERO and that is a stated gap, not an oversight.  It is entered
    only when regs.spcflags is set, there is no counter for it, and it is rare per
    instruction; the residual check below is what would catch a run where it is not."""
    insns = c.get(C_INSNS, 0)
    fetch = c.get(C_FETCH, 0)
    e = {
        B_LOOP: 0,                                    # the resting bucket: never entered
        B_FETCHOP: insns,                             # one run-loop opcode fetch per insn
        B_FETCHEX: max(fetch - insns, 0),             # the rest of the instruction stream
        B_READ: c.get(C_READ, 0),
        B_WRITE: c.get(C_WRITE, 0),
        B_XLATE: c.get(C_XLATE, 0),                   # == tier-0 page-cache misses
        B_WALK: c.get(C_ATC_MISS, 0),                 # == translates that walked
        B_HANDLER: insns,
        B_TAIL: insns,
        B_FAULT: c.get(C_FAULTS, 0),
        B_PROF: 0,                                    # dumps only; negligible and bounded
    }
    if len(sem["bucket_names"]) > B_TAILSAMP:
        e[B_TAILSAMP] = insns                         # the sampler hook: every instruction
        e[B_TAILPOLL] = insns                         # the interrupt poll: likewise
        e[B_TAILSPEC] = 0                             # spcflags-gated; no counter, and rare
    return e


def probe_landing(entries):
    """How many probe TRANSITIONS each bucket pays for -- enters and exits, counted apart.

    The unit matters and is the same unit TRANSITIONS is counted in, which is half the unit
    `probe_cyc` is priced in: see THE VERSION SEAM.  A bucket visit contributes two
    transitions here, one enter and one exit, so this function's total is exactly twice its
    argument's -- which is why it can be compared to the firmware's TRANSITIONS directly.

    Read out of the firmware's enter()/exit(), not assumed.  Both stamp `last = now` BEFORE
    the rest of the probe body runs, so the probe's own cycles elapse after the stamp and
    are charged at the NEXT transition to whichever bucket is current by then:

        enter(b)  -- current becomes b        => the cost lands in b
        exit()    -- current becomes b's parent => the cost lands in the parent

    So a bucket pays for its own entries plus one exit for each entry of every bucket
    nested inside it.  LOOP therefore carries the exits of every stage it hosts, which is
    why it is not exempt despite never being entered.

    The alternative -- distributing the probe total in proportion to each bucket's CYCLE
    share -- is worth naming because it looks reasonable and is useless: it subtracts the
    same fraction from every bucket and leaves every share exactly where it was.  Shares
    are the answer this instrument gives, so a correction that cannot move one is not a
    correction."""
    land = dict((b, 0) for b in range(N_BUCKETS))
    for b, n in entries.items():
        land[b] += n                                      # its own enters
    for b, n in entries.items():
        p = BUCKET_PARENT.get(b)
        if p is not None:
            land[p] += n                                  # its exits, paid by the parent
    callers = sum(entries[b] for b in XLATE_CALLERS)
    if callers and entries[B_XLATE]:
        rem = entries[B_XLATE]
        for i, b in enumerate(XLATE_CALLERS):
            share = (entries[B_XLATE] * entries[b] // callers) if i < len(XLATE_CALLERS) - 1 \
                else rem
            land[b] += share
            rem -= share
    elif entries[B_XLATE]:
        land[B_LOOP] += entries[B_XLATE]
    return land


def _clk_note(clk, what, idx, out, warn):
    """Surface `clk=`, and warn hard when it is `bsp`.

    This is the one number in a dump that NOTHING ELSE IN THE DUMP CAN CHECK, and saying so
    is the whole point of the field.  `cpu_hz` and `wall_hz` scale together -- CPU to global
    timer is a fixed 2:1 in silicon on this part -- so a wrong absolute rate cancels out of
    the wrap cross-check's ratio, and that check passes to three decimal places while the
    clock is 65% wrong.  A reader who has been told "the cross-check is clean" will believe
    every duration in the report.  `clk=bsp` is therefore not a footnote: it is the only
    evidence in the capture that the rates are scaled by a compile-time constant the board
    may have retuned away from."""
    if clk is None:
        return
    if clk == CLK_CFG:
        out.append("clock source    clk=cfg -- the rate core0 published after retuning the "
                   "PLL (runtime)")
        return
    if clk == CLK_BSP:
        out.append("clock source    clk=bsp -- *** THE COMPILE-TIME BSP CONSTANT, NOT THE "
                   "RUNNING CLOCK ***")
    else:
        # A third value is a wire drift the version field did not catch.  It is treated as
        # the unsafe case -- an unrecognised provenance is not evidence of a good clock --
        # but it is NAMED as unrecognised rather than reported as `bsp`, which would assert
        # something specific about where the number came from that this tool cannot know.
        out.append("clock source    clk=%s -- UNRECOGNISED (this version defines only %s "
                   "and %s)," % (clk, CLK_CFG, CLK_BSP))
        out.append("                so it is treated as the unsafe case: *** NOT KNOWN TO "
                   "BE THE RUNNING CLOCK ***")
        warn.append("%s #%d: clk=%s is neither %s nor %s. The clock's provenance is "
                    "unrecognised, which is a wire drift the version field did not catch, "
                    "so it is treated as the unsafe case: the rates below are not known to "
                    "be scaled by the running clock."
                    % (what, idx, clk, CLK_CFG, CLK_BSP))
    out.append("*** Every Hz, every seconds figure and every cycle-denominated rate below "
               "is scaled by")
    out.append("*** a constant baked at build time.  If the board retuned its PLL -- which "
               "is what the")
    out.append("*** `arm_frequency` config key does -- they are all wrong by that ratio; on "
               "the rig that")
    out.append("*** produced this defect, by 1.65x.")
    out.append("*** AND THE WRAP CROSS-CHECK CANNOT SEE IT.  CPU:global-timer is a fixed "
               "2:1 in silicon,")
    out.append("*** so cyc_span and wall_ticks scale TOGETHER and the error cancels out of "
               "their ratio.")
    out.append("*** That check passes cleanly while the clock is 65% wrong; it is a wrap "
               "check, not a")
    out.append("*** clock check.  clk= is the only thing in this capture that can tell you.")
    warn.append("%s #%d: clk=%s -- the ARM clock is the COMPILE-TIME BSP constant, not the "
                "rate core0 published after retuning the PLL, so every Hz, duration and "
                "cycle-denominated rate in this dump is scaled by a constant the board may "
                "have retuned away from. The PMCCNTR wrap cross-check is STRUCTURALLY BLIND "
                "to this: CPU:global-timer is a fixed 2:1, so both spans scale together and "
                "the error cancels out of their ratio -- it passes to three decimals while "
                "the clock is 65%% wrong. Re-take on firmware whose core0 publishes the "
                "rate, or scale every Hz here by the true PLL rate."
                % (what, idx, clk))


def _report_tail(st, idx, sem, ver, total, probe_total, usable, land, modelled, out, warn):
    """The run-loop tail: one number in v1, four in v2, and the same quantity in both.

    Reported as its own section because the tail is the largest single share the C2 map
    found (20 % of guest time, 110.8 ARM cycles per guest instruction) and v1 could not see
    inside it.  Three things have to be said here and none of them is the raw bucket row:

      * THE WHOLE TAIL, so a v2 dump can be compared with a v1 one.  v2's id 8 is the
        residue, not the tail, and a reader who lays v2's TAILADV beside v1's TAIL is
        comparing a part with a whole and will report a saving that did not happen.
      * TAILSAMP IS THE INSTRUMENT, NOT THE INTERPRETER.  It is the profiler's own sampler
        hook and the INSNS counters.  It belongs in the same category as the probe cost --
        subtract it, do not rank it -- and in v1 it was charged to LOOP where no capture
        could see it, so v1's 110.8 cycles never included it in the first place.
      * THE FIRMWARE'S OWN SUM, cross-checked.  `[PROF] t` is computed on the board from
        the same accumulators the `b` lines are printed from, so if it disagrees with the
        four rows this tool added up, the dump's lines did not come off one span."""
    ids = sem["tail_ids"]
    names = sem["bucket_names"]
    inst_id = sem["tail_instrument_id"]
    tail = sum(st.buckets.get(b, 0) for b in ids)

    out.append(sec("run-loop tail rollup (the quantity v1 reported as a single TAIL)"))
    if len(ids) == 1:
        out.append("  wire version %d has no tail split: id %d IS the whole tail, and the "
                   "sampler hook" % (ver, ids[0]))
        out.append("  inside it is charged to LOOP and cannot be separated from this dump.")
    out.append("  id  name       cycles                 of total    of tail")
    out.append("  --  --------  ---------------------  ---------  ---------")
    for b in ids:
        cyc = st.buckets.get(b, 0)
        note = "   <- INSTRUMENT COST, not interpreter" if b == inst_id else ""
        out.append("  %2d  %-8s  %21d  %9s  %9s%s"
                   % (b, names[b], cyc, fpct(cyc, total), fpct(cyc, tail), note))
    out.append("      %-8s  %21d  %9s  %9s" % ("TAIL", tail, fpct(tail, total), "100.00%"))

    if inst_id is not None:
        inst = st.buckets.get(inst_id, 0)
        out.append("")
        out.append("  the tail WITHOUT the instrument: %d cyc = %s of the measured total"
                   % (tail - inst, fpct(tail - inst, total)))
        out.append("    %s is the profiler's own sampler hook and the INSNS counters.  It is "
                   "subtractable" % names[inst_id])
        out.append("    in the same sense the probe cost is: it is measurement, not "
                   "interpretation, and it")
        out.append("    is here at all only because this build is the one being measured "
                   "with.")
        if usable and modelled:
            p = sum(probe_total * land[b] // modelled for b in ids)
            out.append("  the tail with neither the instrument nor the probe: %d cyc = %s"
                       % (max(tail - inst - p, 0),
                          fpct(max(tail - inst - p, 0), total)))
            out.append("    (the four tail buckets carry %d cyc of modelled probe cost "
                       "between them)" % p)

    # The firmware's own rollup, if this version prints one.  A free consistency check.
    if st.tail_cyc is not None:
        if st.tail_cyc == tail:
            out.append("  cross-check: the firmware's own '[PROF] t' line agrees -- %d == %d"
                       % (st.tail_cyc, tail))
        else:
            out.append("  *** CROSS-CHECK FAILED: the firmware's '[PROF] t' line says %d, "
                       "the four bucket" % st.tail_cyc)
            out.append("  *** rows above sum to %d -- a difference of %+d.  Both are printed "
                       "from the same"
                       % (tail, tail - st.tail_cyc))
            out.append("  *** accumulators in the same dump, so they cannot disagree over one "
                       "span.  This")
            out.append("  *** capture's 'b' lines and its 't' line did not come off the same "
                       "state.")
            warn.append("stats dump #%d: the firmware's own whole-tail line (capture line "
                        "%d) reports %d cyc but bucket ids %s sum to %d, a difference of "
                        "%+d. Both are printed from the same accumulators in the same dump "
                        "and cannot disagree over one span; this dump's bucket rows and its "
                        "tail line did not come off the same state."
                        % (idx, st.tail_line, st.tail_cyc,
                           "+".join(str(b) for b in ids), tail, tail - st.tail_cyc))
    elif len(ids) > 1:
        out.append("  (this dump carried no '[PROF] t' line, so the rollup above is this "
                   "tool's own sum)")


def report_stats(st, idx, probe_cyc, probe_src, out, warn):
    out.append(head("stage attribution / counters -- dump #%d  (capture lines %d..%d)"
                    % (idx, st.first_line, st.last_line or st.first_line)))

    bf = st.build
    bits = []
    if bf & BUILD_PROBES:
        bits.append("run-loop probes")
    if bf & BUILD_PERF:
        bits.append("perf accumulator")
    if bf & BUILD_PROF:
        bits.append("profiler")
    out.append("build           0x%02X  (%s)" % (bf, ", ".join(bits) or "none"))
    if bf == BUILD_PROF:
        out.append("                      the shipped profiling combination: the LEAN hot "
                   "loop plus the profiler.")
    elif bf & BUILD_PROF:
        out.append("*** WARNING: this is a profiling build of the DIAGNOSTIC loop, not the "
                   "lean one.")
        out.append("***          Its stage map describes a binary that is not shipped; the "
                   "two loops were")
        out.append("***          priced 9.1% apart in guest throughput.  Rebuild with "
                   "`make profile`.")
        warn.append("stats dump #%d: build=0x%02X is a profiling build of the DIAGNOSTIC "
                    "loop, not the lean one. Its stage map describes a binary that is not "
                    "shipped." % (idx, bf))
    else:
        out.append("*** WARNING: build flags do not claim a profiler (bit 2 clear). "
                   "Numbers below are suspect.")
        warn.append("stats dump #%d: build=0x%02X does not claim a profiler (bit 2 clear)."
                    % (idx, bf))
    sem = st.sem or WIRE_VERSIONS[VERSION_ASSUMED]
    ver = st.ver if st.ver is not None else VERSION_ASSUMED
    if st.ver is None:
        out.append("*** this dump's '[PROF] ver=' line did not arrive.  It is read as wire "
                   "version %d, which" % VERSION_ASSUMED)
        out.append("*** is an ASSUMPTION: the versions disagree about the unit of probe_cyc "
                   "and about what")
        out.append("*** two ids are called, so if this capture is not v%d the rows below are "
                   "mislabelled." % VERSION_ASSUMED)
        warn.append("stats dump #%d: no '[PROF] ver=' line arrived, so the dump is read as "
                    "wire version %d by assumption. The versions disagree about the unit of "
                    "probe_cyc and about the names of counter id 12 and bucket id 8; if this "
                    "capture is not v%d, this dump is mislabelled throughout."
                    % (idx, VERSION_ASSUMED, VERSION_ASSUMED))
    bucket_names = sem["bucket_names"]
    counter_names = sem["counter_names"]
    probe_unit = sem["probe_unit"]
    unit = sem["probe_unit_short"]
    per_unit = sem["transitions_per_probe_unit"]

    out.append("wire version    %d  (%d buckets, %d counters)"
               % (ver, len(bucket_names), len(counter_names)))
    if sem["has_clk"]:
        out.append("cpu_hz          %d Hz (the RUNTIME clock -- see clock source below)"
                   % st.cpu_hz)
    else:
        out.append("cpu_hz          %d Hz (measured at arm time, not configured)" % st.cpu_hz)
    _clk_note(st.clk, "stats dump", idx, out, warn)
    out.append("sampler         %d Hz (period %d cyc)" % (st.hz, st.period_cyc))
    out.append("probe cost      %d cyc per %s   [%s]" % (probe_cyc, probe_unit, probe_src))
    if per_unit != 1:
        out.append("                = %.2f cyc per transition; one %s is %d transitions "
                   "(one enter, one exit)" % (float(probe_cyc) / per_unit, probe_unit,
                                              per_unit))
    else:
        out.append("                the unit TRANSITIONS is counted in, so it multiplies "
                   "TRANSITIONS directly")

    c = st.counters
    total = sum(st.buckets.values())
    trans = c.get(C_TRANSITIONS, 0)

    # ---- stage buckets ----------------------------------------------------------------
    out.append(sec("stage buckets (exclusive ARM cycles; sum == total by construction)"))
    if total == 0:
        out.append("   all buckets are zero: the stage buckets were never armed (PROFB).")
        out.append("   The counters below are still exact -- they are not switchable in a "
                   "profiling build.")
        warn.append("stats dump #%d: every bucket is zero -- PROFB was never on, so there "
                    "is no stage attribution in this dump. The counters are unaffected."
                    % idx)
    else:
        entries = bucket_entries(c, sem)
        land = probe_landing(entries)
        modelled = sum(land.values())
        # THE UNIT.  `probe_cyc` prices one probe_unit -- an enter/exit PAIR in version 1,
        # ONE TRANSITION in version 2 -- while TRANSITIONS counts each enter and each exit
        # in both.  The priced quantity is therefore trans / per_unit, which is trans / 2
        # for v1 and trans itself for v2.  Multiplying first keeps the integer division to a
        # single truncation at the end.
        probe_units = trans // per_unit
        probe_total = trans * probe_cyc // per_unit
        resid = trans - modelled
        resid_pct = abs(pct(resid, trans)) if trans else 100.0
        # An arithmetically impossible subtraction: the instrument claims to have spent more
        # cycles than the run contains.  In a version that prices the probe honestly this is
        # the INSTRUMENT being wrong -- a bad calibration or a bad transition count -- and
        # the answer is to say so and subtract nothing.  Clamping is how v1's 2x over-pricing
        # produced a full, plausible, impossible table instead of an error, and the firmware
        # now prints a warning of its own at the same threshold.
        probe_over = probe_cyc > 0 and total > 0 and probe_total > total
        fatal_over = probe_over and sem["probe_exceeds_total_is_fatal"]
        usable = (trans > 0 and probe_cyc > 0 and modelled > 0 and resid_pct <= 25.0
                  and not fatal_over)

        adj = {}
        clamped, clamped_cyc = 0, 0
        if usable:
            # Distribute the firmware's EXACT probe total by the modelled landing shape, so
            # the parts sum to the measured whole even where the model is imperfect.
            #
            # A bucket whose modelled probe cost EXCEEDS its measured cycles is clamped at
            # zero, and that is counted rather than swallowed: it is arithmetically
            # impossible and therefore evidence that the probe price is too high, which is
            # exactly how the firmware's 2x over-pricing announced itself -- LOOP was asked
            # for half again as many cycles as it contained.
            for b in range(len(bucket_names)):
                p = probe_total * land[b] // modelled
                raw = st.buckets.get(b, 0)
                if p > raw:
                    clamped += 1
                    clamped_cyc += p - raw
                adj[b] = max(raw - p, 0)
            adj_total = sum(adj.values())

        out.append("  id  name       cycles                 share   probe cyc          "
                   "adjusted     adj share")
        out.append("  --  --------  ---------------------  -------  ---------------  "
                   "---------------  -------")
        for b in range(len(bucket_names)):
            cyc = st.buckets.get(b, 0)
            if usable:
                p = probe_total * land[b] // modelled
                out.append("  %2d  %-8s  %21d  %7s  %15d  %15d  %7s"
                           % (b, bucket_names[b], cyc, fpct(cyc, total), p, adj[b],
                              fpct(adj[b], adj_total)))
            else:
                out.append("  %2d  %-8s  %21d  %7s  %15s  %15s  %7s"
                           % (b, bucket_names[b], cyc, fpct(cyc, total), "-", "-", "-"))
        if usable:
            out.append("      %-8s  %21d  %7s  %15d  %15d  %7s"
                       % ("TOTAL", total, "100.00%", probe_total, adj_total, "100.00%"))
        else:
            out.append("      %-8s  %21d  %7s" % ("TOTAL", total, "100.00%"))

        out.append("")
        if probe_cyc <= 0:
            # Without a price the product is zero, and printing "0 cyc = 0.00% of the
            # measured total" would state the one thing that is certainly false: that the
            # instrument is free.  An absent calibration is reported as absent.
            out.append("  probe overhead inside the totals: UNAVAILABLE -- this dump "
                       "carries no probe")
            out.append("  calibration (probe_cyc=%d), so the %d transitions it measured "
                       "cannot be priced." % (probe_cyc, trans))
            out.append("  This is NOT a claim that the overhead is zero.  Pass "
                       "--probe-cost in wire version")
            out.append("  %d's unit (%s) to supply one." % (ver, probe_unit))
            warn.append("stats dump #%d: no probe calibration (probe_cyc=%d), so the probe "
                        "overhead is UNPRICEABLE and the subtraction is unavailable. The "
                        "%d measured transitions are real; only their price is missing. "
                        "This is not a zero-overhead result."
                        % (idx, probe_cyc, trans))
            provenance = None
        else:
            out.append("  probe overhead inside the totals: %d cyc = %s of the measured "
                       "total" % (probe_total, fpct(probe_total, total)))
            provenance = ("count measured by the firmware, price from --probe-cost"
                          if probe_src == "--probe-cost"
                          else "both measured by the firmware")
        if provenance is None:
            pass
        elif per_unit != 1:
            out.append("    (%d transitions / %d = %d %ss x %d cyc/%s, %s)"
                       % (trans, per_unit, probe_units, probe_unit, probe_cyc, unit,
                          provenance))
        else:
            out.append("    (%d transitions x %d cyc/%s, %s)"
                       % (trans, probe_cyc, unit, provenance))
        if provenance is None:
            pass
        elif per_unit != 1:
            out.append("    the firmware's own line prints TRANSITIONS x probe_cyc = %d cyc "
                       "(%s of the total)," % (trans * probe_cyc,
                                               fpct(trans * probe_cyc, total).strip()))
            out.append("    which double-counts by exactly %dx: probe_cyc prices a %s while "
                       "TRANSITIONS counts" % (per_unit, unit))
            out.append("    each enter and each exit.  This tool prices the %ss.  [wire "
                       "version %d]" % (unit, ver))
        else:
            out.append("    the firmware's own line prints the SAME figure: wire version %d "
                       "prices one" % ver)
            out.append("    transition, so TRANSITIONS x probe_cyc is the whole probe cost "
                       "and this tool and")
            out.append("    the console agree.  Nothing is halved here.  [wire version %d]"
                       % ver)
        if probe_over:
            # Reported before the clamp discussion, because it subsumes it: if the WHOLE
            # subtraction is impossible, which buckets individually overflowed is a detail.
            out.append("  *** THE MODELLED PROBE COST EXCEEDS THE MEASURED TOTAL: %d cyc of "
                       "probe against" % probe_total)
            out.append("  *** %d cyc measured, %s of it.  The instrument cannot have spent "
                       "more cycles" % (total, fpct(probe_total, total).strip()))
            out.append("  *** than the run contains, so one of the two inputs is wrong: the "
                       "probe calibration")
            out.append("  *** (%d cyc per %s) or the TRANSITIONS count (%d)."
                       % (probe_cyc, unit, trans))
            if fatal_over:
                out.append("  *** NOTHING IS SUBTRACTED and the adjusted columns are "
                           "WITHHELD.  Clamping the")
                out.append("  *** overflow away is what turned this same arithmetic into a "
                           "plausible table once")
                out.append("  *** before; a measuring instrument reports an impossibility "
                           "rather than absorbing")
                out.append("  *** it.  Raw cycles and shares above are unaffected and remain "
                           "exactly what the")
                out.append("  *** firmware measured.")
            warn.append("stats dump #%d: the modelled probe cost (%d cyc) EXCEEDS the "
                        "measured total (%d cyc, %s of it). The instrument cannot have spent "
                        "more cycles than the run contains, so either the probe calibration "
                        "(%d cyc per %s) or the TRANSITIONS count (%d) is wrong.%s"
                        % (idx, probe_total, total, fpct(probe_total, total).strip(),
                           probe_cyc, unit, trans,
                           " The subtraction is WITHHELD rather than clamped; raw cycles and "
                           "shares are unaffected." if fatal_over else ""))
        if usable and clamped:
            out.append("  *** %d bucket(s) were CLAMPED at zero: the modelled probe cost "
                       "exceeded the cycles" % clamped)
            out.append("  *** actually measured in them, by %d in total.  That is "
                       "arithmetically impossible," % clamped_cyc)
            out.append("  *** so it is evidence the probe PRICE is too high -- not that "
                       "those stages are empty.")
            out.append("  *** The 'adjusted' column absorbs the excess and no longer sums "
                       "to total - probe.")
            warn.append("stats dump #%d: %d bucket(s) clamped at zero -- the modelled probe "
                        "cost exceeded their measured cycles by %d in total. The "
                        "subtraction is arithmetically impossible at this probe price; the "
                        "adjusted column absorbs the excess and the shares derived from it "
                        "are not trustworthy." % (idx, clamped, clamped_cyc))
        # The landing model and the probe price are two independent ways for the
        # subtraction to fail, and they must not be reported as each other: a withheld
        # subtraction whose model is fine is a PRICE problem, and blaming the model would
        # send a reader to re-derive an equation that is already right.
        model_ok = trans > 0 and modelled > 0 and resid_pct <= 25.0
        out.append("  probe-landing model: %d transitions predicted from the counters vs "
                   "%d measured" % (modelled, trans))
        # Three different reasons to withhold, named apart.  A reader who is told the model
        # is out of tolerance will go and re-derive the model; if the real cause was an
        # absent price or an impossible one, that is an afternoon spent on the wrong thing.
        if usable:
            why = "within tolerance, subtraction applied"
        elif not model_ok:
            why = "OUT OF TOLERANCE"
        elif probe_cyc <= 0:
            why = ("within tolerance; the model is fine, but there is no probe price to "
                   "apply it to")
        else:
            why = ("within tolerance; the model is fine -- the subtraction is withheld "
                   "because the probe exceeds the total")
        out.append("    residual %+d (%.4f%% of measured) -- %s" % (resid, resid_pct, why))
        if not usable and not model_ok:
            warn.append("stats dump #%d: the probe-cost subtraction is WITHHELD -- the "
                        "probe-landing model predicts %d transitions but the firmware "
                        "measured %d (%.2f%% apart). Raw cycles and shares are unaffected."
                        % (idx, modelled, trans, resid_pct))
            out.append("  *** the 'adjusted' columns are WITHHELD.  The firmware reports one "
                       "global transition")
            out.append("  *** count, so a per-bucket subtraction has to be modelled, and this "
                       "model does not")
            out.append("  *** reproduce the measured count.  Raw cycles and shares above are "
                       "unaffected and")
            out.append("  *** remain exactly what the firmware measured.")
        out.append("  NOTE the shares, not the rate: the instrumented instruction rate is far "
                   "below the lean")
        out.append("  build's and the two are not comparable.  See docs/PROFILER-SYMBOLIZE.md.")

        _report_tail(st, idx, sem, ver, total, probe_total if usable else 0, usable,
                     land, modelled, out, warn)

    # ---- counters ---------------------------------------------------------------------
    insns = c.get(C_INSNS, 0)
    out.append(sec("counters (exact -- not switchable, and unaffected by bucket distortion)"))
    out.append("  id  name             value                per insn")
    out.append("  --  ------------  ---------------------  ----------")
    for i in range(len(counter_names)):
        v = c.get(i, 0)
        per = ("%10.4f" % (float(v) / insns)) if insns else "         -"
        out.append("  %2d  %-12s  %21d  %s" % (i, counter_names[i], v, per))
    if c.get(C_STACK_OVF, 0):
        out.append("")
        out.append("*** STACK_OVF is %d and must be 0.  The phase stack overflowed, "
                   "transitions were" % c[C_STACK_OVF])
        out.append("*** dropped, and every bucket total above is understated by an unknown "
                   "amount.")
        out.append("*** This dump is not trustworthy.")
        warn.append("stats dump #%d: STACK_OVF=%d and must be 0. Phase transitions were "
                    "dropped; every bucket total is understated by an unknown amount and "
                    "this dump is not trustworthy." % (idx, c[C_STACK_OVF]))

    # ---- derived rates ----------------------------------------------------------------
    out.append(sec("counter-derived rates"))
    ih, im = c.get(C_IPAGE_HIT, 0), c.get(C_IPAGE_MISS, 0)
    rh, rm = c.get(C_DPAGE_RHIT, 0), c.get(C_DPAGE_RMISS, 0)
    wh, wm = c.get(C_DPAGE_WHIT, 0), c.get(C_DPAGE_WMISS, 0)
    # `xo` is id 12 -- translates that returned an address -- under whichever name this
    # version spells it; `ah` is the REAL ATC hit counter, which exists only in v2 and is
    # None where it does not.  Keeping them in separate variables is the entire fix for the
    # defect this tool was built around: v1 had one counter doing duty as both, and every
    # ATC figure derived from it was a figure about something else.
    xl, xo, am = c.get(C_XLATE, 0), c.get(C_XLATE_OK, 0), c.get(C_ATC_MISS, 0)
    fa = c.get(C_FAULTS, 0)
    atc_id = sem["atc_hit_id"]
    ah = c.get(atc_id, 0) if atc_id is not None else None

    def tier0(label, hit, miss):
        if hit + miss == 0:
            return ("  %-34s %9s   %s" % (label, "n/a",
                    "no tier-0 page-cache counters on the 68030 path (absent, not zero)"))
        return ("  %-34s %8.2f%%   %d hit / %d miss" % (label, pct(hit, hit + miss),
                                                        hit, miss))

    out.append("  tier 0 -- page caches: a hit here means mmu_translate is never called")
    out.append(tier0("ipagecache hit", ih, im))
    out.append(tier0("dpagecache read hit", rh, rm))
    out.append(tier0("dpagecache write hit", wh, wm))
    # Tier 1 is derived from XLATE and ATC_MISS and NOT from ATC_HIT, which in version 1
    # does not count what its name says (see THE VERSION SEAM).  The identities below are
    # the cross-check that used to be spelled `ATC_HIT + ATC_MISS == XLATE` -- a sum with
    # no meaning, which therefore fired on every intact dump and gave a wrong reason for a
    # real defect.
    out.append("  tier 1 -- the 4-way ATC inside mmu_translate")
    if not xl:
        out.append("  %-34s %9s   no translates recorded" % ("ATC hit", "n/a"))
    elif ah is None:
        # v1: no counter counts ATC hits, so the rate is derived from the two that are
        # trustworthy.  It is the same quantity v2 measures directly, which is why the two
        # versions' numbers are comparable even though only one of them was measured.
        out.append("  %-34s %8.2f%%   %d of %d translates did not walk"
                   % ("ATC hit", pct(xl - am, xl), xl - am, xl))
        out.append("%s= (XLATE - ATC_MISS) / XLATE" % (" " * 49))
        out.append("  %-34s %8.2f%%   %d of %d translates walked the tables"
                   % ("tier 2 -- table walk rate", pct(am, xl), am, xl))
    else:
        # v2: id 19 counts ATC hits and is the ONLY counter this rate may come from.  Id 12
        # is XLATE_OK and is reported on its own row below, because a reader who sees only
        # one "hit-shaped" number will use whichever one is in front of them.
        out.append("  %-34s %8.2f%%   %d of %d translates were served without a walk"
                   % ("ATC hit", pct(ah, xl), ah, xl))
        out.append("%s= ATC_HIT / XLATE   [counter id %d -- the real one]"
                   % (" " * 49, atc_id))
        out.append("  %-34s %8.2f%%   %d of %d translates walked the tables"
                   % ("tier 2 -- table walk rate", pct(am, xl), am, xl))
        if xo:
            out.append("  %-34s %8.2f%%   %d of %d translates returned an address"
                       % ("XLATE_OK (translate success)", pct(xo, xl), xo, xl))
            out.append("%s= XLATE_OK / XLATE  [counter id %d -- NOT an ATC rate;"
                       % (" " * 49, C_XLATE_OK))
            out.append("%s   this is the counter v1 called ATC_HIT]" % (" " * 49))
        else:
            # Zero here means ABSENT, exactly as it does for the tier-0 counters, and for
            # the same kind of reason: the 68030 translate is a bare ATC probe called from
            # fourteen accessors with no single success point to hang a counter on.
            # Printing 0.00% would state that every translate faulted, which is a worse
            # answer than no answer -- and the firmware omits its own line for this reason.
            out.append("  %-34s %9s   no XLATE_OK site on the 68030 path (absent, not "
                       "zero)" % ("XLATE_OK (translate success)", "n/a"))

    out.append("  cross-checks -- the identities an intact version-%d dump satisfies" % ver)
    idrow = "    %-49s %-9s %s"
    t0_seen = ih + im + rh + rm + wh + wm
    t0miss = im + rm + wm
    if not t0_seen:
        out.append(idrow % (sem["tier0_identity"], "n/a",
                            "no tier-0 counters on the 68030 path"))
    elif t0miss == xl:
        out.append(idrow % (sem["tier0_identity"], "ok", "%d == %d" % (t0miss, xl)))
    else:
        out.append(idrow % (sem["tier0_identity"], "MISMATCH", "%d vs %d" % (t0miss, xl)))
        out.append("  *** XLATE counts the calls into mmu_translate and every tier-0 miss "
                   "makes exactly one,")
        out.append("  *** so these cannot disagree over one span.  Treat this dump's "
                   "translation rows as suspect.")
        warn.append("stats dump #%d: %s -- measured %d vs %d. XLATE counts the calls into "
                    "mmu_translate and every tier-0 miss makes exactly one, so these "
                    "cannot disagree over one span; this dump's counters were not all "
                    "taken over the same span."
                    % (idx, sem["tier0_identity"], t0miss, xl))
    if xl:
        # Identity 2 is about id 12, and it is the SAME identity in both versions because
        # id 12 counts the same thing in both -- only its name changed.  Which is the point
        # worth making to a reader who has a v1 capture open beside a v2 one.
        if xo == 0 and sem["atc_hit_id"] is not None:
            # The 68030 again: id 12 has no site there, so the identity is unverifiable
            # rather than violated.  Reporting MISMATCH here would be the tier-0 mistake in
            # a different row -- calling an absent counter a broken one.
            out.append(idrow % (sem["atc_hit_identity"], "n/a",
                                "XLATE_OK is absent on the 68030 path"))
        elif xo + fa == xl:
            out.append(idrow % (sem["atc_hit_identity"], "ok", "%d == %d" % (xo + fa, xl)))
            if ah is None:
                out.append("    ATC_HIT is a version-%d misnomer: it counts %s."
                           % (ver, sem["atc_hit_means"]))
                out.append("    ATC_HIT + ATC_MISS is therefore a meaningless sum, and is "
                           "not computed above.")
            else:
                out.append("    this is the identity v1 states over `ATC_HIT`: id 12 did not "
                           "change what it")
                out.append("    counts, only what it is called.  A v1 capture and this one "
                           "are comparable here.")
        else:
            out.append(idrow % (sem["atc_hit_identity"], "MISMATCH",
                                "%d vs %d" % (xo + fa, xl)))
            out.append("  *** %s counts %s, so" % (sem["id12_name"], sem["atc_hit_means"]))
            out.append("  *** an intact dump satisfies that identity.  It is suspect here; "
                       "the two rates")
            out.append("  *** above come from XLATE and ATC_MISS and do not depend on it.")
            warn.append("stats dump #%d: %s -- measured %d vs %d. In wire version %d "
                        "counter id 12 (%s) counts %s, so an intact dump satisfies that "
                        "identity. It is suspect here; the ATC hit rate and the walk rate do "
                        "not depend on it."
                        % (idx, sem["atc_hit_identity"], xo + fa, xl, ver,
                           sem["id12_name"], sem["atc_hit_means"]))
        # Identity 3 exists only where a real ATC counter does.  It is NOT an equality in
        # general: a translate that faulted before the walk decision is counted by neither
        # ATC_HIT nor ATC_MISS, so the sum falls short by exactly those.  A shortfall is
        # therefore reported as satisfied-with-a-remainder, and only an OVERSHOOT -- a sum
        # larger than the set it partitions -- is impossible.  Bounding the shortfall by
        # FAULTS is a check the firmware does not make: every translate that faulted threw,
        # and every throw reached the run loop's CATCH, so it cannot exceed FAULTS.
        if sem["atc_sum_identity"] is not None:
            short = xl - (ah + am)
            if short == 0:
                out.append(idrow % (sem["atc_sum_identity"], "ok",
                                    "%d == %d" % (ah + am, xl)))
            elif 0 < short <= fa:
                out.append(idrow % (sem["atc_sum_identity"], "ok",
                                    "%d vs %d, short %d" % (ah + am, xl, short)))
                out.append("    the %d are translates that faulted before the walk decision, "
                           "counted by" % short)
                out.append("    neither ATC_HIT nor ATC_MISS.  Within FAULTS (%d), which "
                           "bounds them." % fa)
            elif short > fa:
                out.append(idrow % (sem["atc_sum_identity"], "MISMATCH",
                                    "%d vs %d, short %d" % (ah + am, xl, short)))
                out.append("  *** the shortfall is translates that faulted before the walk "
                           "decision, so it cannot")
                out.append("  *** exceed FAULTS (%d) -- every one of them threw and every "
                           "throw reached the CATCH." % fa)
                warn.append("stats dump #%d: %s -- ATC_HIT + ATC_MISS = %d against XLATE = "
                            "%d, short %d, but FAULTS is only %d. The shortfall is translates "
                            "that faulted before the walk decision and every one of those "
                            "reached the run loop's CATCH, so it cannot exceed FAULTS. These "
                            "counters were not all taken over the same span."
                            % (idx, sem["atc_sum_identity"], ah + am, xl, short, fa))
            else:
                out.append(idrow % (sem["atc_sum_identity"], "MISMATCH",
                                    "%d vs %d, OVER by %d" % (ah + am, xl, -short)))
                out.append("  *** ATC_HIT and ATC_MISS partition the translates, so their "
                           "sum cannot EXCEED")
                out.append("  *** XLATE.  The ATC hit rate printed above comes from ATC_HIT "
                           "and is suspect.")
                warn.append("stats dump #%d: %s -- ATC_HIT + ATC_MISS = %d EXCEEDS XLATE = "
                            "%d by %d. Those two partition the translates and cannot sum to "
                            "more than the set they partition; the ATC hit rate above comes "
                            "from ATC_HIT and is suspect."
                            % (idx, sem["atc_sum_identity"], ah + am, xl, -short))
    out.append("  supervisor share")
    out.append("  %-34s %8.2f%%   %d of %d instructions"
               % ("INSNS_SUPER / INSNS", pct(c.get(C_INSNS_SUPER, 0), insns),
                  c.get(C_INSNS_SUPER, 0), insns))
    if insns:
        out.append("  %-34s %8.2f%%   %d of %d + %d accesses"
                   % ("misaligned accesses", pct(c.get(C_MISALIGN_R, 0) + c.get(C_MISALIGN_W, 0),
                                                 c.get(C_READ, 0) + c.get(C_WRITE, 0)),
                      c.get(C_MISALIGN_R, 0) + c.get(C_MISALIGN_W, 0),
                      c.get(C_READ, 0), c.get(C_WRITE, 0)))

    # The wrap cross-check applies to the stats dump's own span too.
    if st.wall_hz and st.wall_ticks:
        expected = st.wall_ticks * st.cpu_hz // st.wall_hz
        out.append("  %-34s %d cyc measured vs %d cyc of wall time"
                   % ("bucket total vs wall clock", total, expected))
        out.append("  %-34s %8.2f%%   the buckets account for this much of the elapsed span"
                   % ("run-loop residency", pct(total, expected)))
        out.append("    (the remainder is time core1 spent off the run loop: it is not lost, "
                   "it was never")
        out.append("     inside a stage.  This is a shape check, not a wrap check -- the wrap "
                   "check is on the")
        out.append("     ring header, whose cycle span comes from the sampler.)")


# --------------------------------------------------------------------------------------
# The ring dump: coverage, wrap cross-check, weights, mode split, flat profile, opcodes.
# --------------------------------------------------------------------------------------

WEIGHT_BINS = [(1, 1), (2, 4), (5, 8), (9, 16), (17, 32), (33, 64),
               (65, 128), (129, 254), (255, 255)]


def report_ring(ring, idx, ksyms, usyms, args, out, warn):
    h = ring.hdr
    rec_count = int(h["rec_count"])
    samples = int(h["samples"])
    drops = int(h["drops"])
    cyc_span = int(h["cyc_span"])
    wall_ticks = int(h["wall_ticks"])
    wall_hz = int(h["wall_hz"])
    cpu_hz = int(h["cpu_hz"])
    hz = int(h["hz"])
    build = int(h.get("build", "0x0"), 16)
    sem = ring.sem or WIRE_VERSIONS[VERSION_ASSUMED]
    ver = int(h["version"])
    clk = h.get("clk")

    out.append(head("ring dump #%d  (capture lines %d..%d)"
                    % (idx, ring.first_line, ring.last_line)))
    out.append("magic %s  version %s  rec_size %s  ring_entries %s  build 0x%02X"
               % (h["magic"], h["version"], h["rec_size"], h["ring_entries"], build))
    out.append("sampler         %d Hz   period %s cyc   cpu_hz %d Hz"
               % (hz, h["period_cyc"], cpu_hz))
    if "probe_cyc" in h:
        out.append("probe cost      %s cyc per %s (from this ring header)"
                   % (h["probe_cyc"], sem["probe_unit"]))
    _clk_note(clk, "ring dump", idx, out, warn)
    if hz == 0:
        warn.append("ring dump #%d was taken with hz=0: the sampler was never armed, so "
                    "WEIGHT has no unit and every weighted figure below is uninterpretable."
                    % idx)
        out.append("*** hz=0: the sampler was never armed.  WEIGHT has no time unit here.")

    # ---- coverage: the two different losses, kept apart ---------------------------------
    out.append(sec("coverage -- is this the run, or the tail of it?"))
    out.append("  records in this dump          %12d" % rec_count)
    out.append("  samples taken since arming    %12d" % samples)
    out.append("  dropped by ring wrap          %12d" % drops)
    missing = samples - rec_count
    out.append("  NOT in this dump              %12d   (%s of the samples taken)"
               % (missing, fpct(missing, samples)))
    if drops > 0:
        out.append("")
        out.append("*** THE RING WRAPPED.  This dump is the TAIL of the run, not the run: "
                   "%d samples" % drops)
        out.append("*** were overwritten before it was taken.  Every share below is a share "
                   "of the last")
        out.append("*** %d samples only.  Presenting it as a whole-run profile is the single "
                   "easiest" % rec_count)
        out.append("*** way to get a wrong answer out of this instrument.  Re-take at a lower "
                   "rate, or dump")
        out.append("*** sooner.")
        warn.append("ring dump #%d: drops=%d -- the ring wrapped and this dump covers only "
                    "the newest %d samples." % (idx, drops, rec_count))
    elif missing > 0:
        out.append("")
        out.append("*** The ring did NOT wrap (drops=0), but this dump still carries only "
                   "%d of the %d" % (rec_count, samples))
        out.append("*** samples taken -- a partial dump (PROFR takes the newest 4096; "
                   "PROF RING takes all).")
        out.append("*** The profile below is of the newest %d samples.  drops=0 alone does "
                   "NOT mean" % rec_count)
        out.append("*** whole-run coverage.")
        warn.append("ring dump #%d: %d of %d samples are outside this dump although the ring "
                    "never wrapped (a partial PROFR)." % (idx, missing, samples))
    else:
        out.append("  -> complete: every sample taken since arming is in this dump.")

    # ---- wrap cross-check ---------------------------------------------------------------
    out.append(sec("PMCCNTR wrap cross-check (PMU span vs independent ARM global timer)"))
    if not wall_hz or not wall_ticks or not cyc_span:
        out.append("  n/a -- cyc_span=%d wall_ticks=%d wall_hz=%d.  With the sampler never "
                   "armed the" % (cyc_span, wall_ticks, wall_hz))
        out.append("  cycle base never advances and there is nothing to cross-check.")
    else:
        expected = wall_ticks * cpu_hz // wall_hz
        div = pct(cyc_span - expected, expected)
        short = expected - cyc_span
        out.append("  %-46s %20d" % ("cyc_span (PMU, extended at each sample)", cyc_span))
        out.append("  %-46s %20d" % ("expected from the ARM global timer", expected))
        out.append("    = %d tk / %d Hz x %d Hz" % (wall_ticks, wall_hz, cpu_hz))
        out.append("  %-46s %19.3f%%" % ("divergence", div))
        # State the blind spot HERE, next to the clean result, and not only in the warnings.
        # This check's clean bill of health is exactly what a reader will quote back when
        # asked whether the clock is right, and it cannot answer that question at all.
        if sem["has_clk"]:
            out.append("  NOTE this is a WRAP check, not a CLOCK check.  CPU:global-timer is "
                       "a fixed 2:1 in")
            out.append("  silicon, so both spans scale together and an error in the absolute "
                       "rate cancels out")
            out.append("  of this ratio -- it passes cleanly while the clock is 65%% wrong.  "
                       "clk=%s above is"
                       % (clk if clk else "?"))
            out.append("  the only evidence about that, and it is a separate question.")
        if abs(div) <= 1.0:
            out.append("  -> consistent.  No PMCCNTR wrap was missed; cycle totals are whole.")
        else:
            wraps = short / float(TWO32)
            near = abs(wraps - round(wraps))
            out.append("")
            out.append("*** DIVERGENCE OVER 1%%.  The two clocks disagree by %d cycles "
                       "(%.3f s at %d Hz)." % (short, short / float(cpu_hz), cpu_hz))
            if short > 0 and round(wraps) >= 1 and near < 0.10:
                out.append("*** That is %.3f x 2^32, i.e. approximately %d MISSED PMCCNTR "
                           "WRAP(S)." % (wraps, int(round(wraps))))
                out.append("*** Every CYCLE total from this dump is short by %d x 2^32 = %d."
                           % (int(round(wraps)), int(round(wraps)) * TWO32))
                warn.append("ring dump #%d: cyc_span diverges from wall time by %.3f%% "
                            "= %.2f x 2^32 -- a missed PMCCNTR wrap." % (idx, div, wraps))
            else:
                out.append("*** It is NOT close to a multiple of 2^32 (%.3f), so this is "
                           "most likely NOT a" % wraps)
                if sem["has_clk"]:
                    # v2 stamps both spans at the dump, so the v1 explanation below is not
                    # available here and offering it would send the reader after a bias that
                    # no longer exists.
                    out.append("*** missed wrap.  In wire version %d both spans are stamped "
                               "AT THE DUMP, so the" % ver)
                    out.append("*** version-1 explanation -- cyc_span stopping at the last "
                               "sample while wall_ticks")
                    out.append("*** ran on to the dump -- does not apply: that bias was "
                               "removed, not documented.")
                    out.append("*** %.3f s of span is unaccounted for and the cause is not "
                               "one this tool knows."
                               % (short / float(cpu_hz)))
                else:
                    out.append("*** missed wrap.  cyc_span stops advancing at the LAST "
                               "SAMPLE while wall_ticks runs")
                    out.append("*** to the DUMP, so stopping the sampler before dumping "
                               "(`PROF` to off, then")
                    out.append("*** `PROF RING`) leaves exactly this shortfall: %.3f s of "
                               "un-sampled wall time."
                               % (short / float(cpu_hz)))
                warn.append("ring dump #%d: cyc_span diverges from wall time by %.3f%% "
                            "(%.3f s), not a multiple of 2^32.%s"
                            % (idx, div, short / float(cpu_hz),
                               " Wire version %d stamps both spans at the dump, so this is "
                               "not the version-1 stop-to-dump gap." % ver
                               if sem["has_clk"] else ""))
            out.append("*** The PC map, the mode split and the WEIGHT totals below are "
                       "UNAFFECTED -- they do")
            out.append("*** not depend on the cycle base.  Only cycle-denominated figures "
                       "are.")

    # ---- decode the samples -------------------------------------------------------------
    rsvd_seen = 0
    total_w = 0
    for pc, op, fl in ring.samples:
        if fl & F_RSVD_MASK:
            rsvd_seen += 1
        total_w += (fl >> F_WEIGHT_SH) & 0xFF or 1
    if rsvd_seen:
        warn.append("ring dump #%d: %d sample(s) have reserved flag bits 4..7 set, which "
                    "version %d defines as always zero.  They are masked off here; if this "
                    "capture came from a newer firmware the version field should have said so."
                    % (idx, rsvd_seen, ver))
        out.append("")
        out.append("*** %d sample(s) carry reserved flag bits (0x%02X mask).  Masked off per "
                   "version %d." % (rsvd_seen, F_RSVD_MASK, ver))

    # ---- WEIGHT histogram ---------------------------------------------------------------
    out.append(sec("WEIGHT histogram -- what the sampler could NOT see"))
    out.append("  A sample stands for WEIGHT tick periods.  Weight above 1 is time core1 "
               "spent off the")
    out.append("  run loop, where the sampler structurally cannot fire: a STOP spin, an "
               "exception, a")
    out.append("  mailbox round trip to core0.  It is a disclosure, not a correction.")
    out.append("")
    out.append("  weight        samples    sam%      weight sum      wt%")
    out.append("  ---------  ----------  -------  --------------  -------")
    n_hi = 0
    w_hi = 0
    for lo, hi in WEIGHT_BINS:
        ns = 0
        ws = 0
        for _, _, fl in ring.samples:
            w = (fl >> F_WEIGHT_SH) & 0xFF or 1
            if lo <= w <= hi:
                ns += 1
                ws += w
        if lo > 1:
            n_hi += ns
            w_hi += ws
        label = str(lo) if lo == hi else "%d-%d" % (lo, hi)
        note = ""
        if lo == 255 and ns:
            note = "   <- SATURATED: a floor, not a measure"
        out.append("  %-9s  %10d  %7s  %14d  %7s%s"
                   % (label, ns, fpct(ns, rec_count), ws, fpct(ws, total_w), note))
    out.append("  %-9s  %10d  %7s  %14d  %7s" % ("TOTAL", rec_count, "100.00%",
                                                 total_w, "100.00%"))
    out.append("")
    out.append("  samples with weight > 1: %d (%s of samples) carrying %s of all observed "
               "time." % (n_hi, fpct(n_hi, rec_count), fpct(w_hi, total_w)))
    out.append("  -> a symbolizer that counted samples instead of weight would misplace that "
               "%s." % fpct(w_hi, total_w))
    if hz:
        out.append("  observed span from weights: %d periods at %d Hz = %.3f s."
                   % (total_w, hz, float(total_w) / hz))
    sat = sum(1 for _, _, fl in ring.samples if ((fl >> F_WEIGHT_SH) & 0xFF) == 255)
    if sat:
        warn.append("ring dump #%d: %d sample(s) saturated at WEIGHT=255. Their true weight "
                    "is at least 255, so every weighted total here is a LOWER BOUND."
                    % (idx, sat))

    # ---- mode split ----------------------------------------------------------------------
    out.append(sec("mode split (weighted; SUPER and user are different questions)"))
    modes = {}
    for pc, op, fl in ring.samples:
        w = (fl >> F_WEIGHT_SH) & 0xFF or 1
        key = (bool(fl & F_SUPER), bool(fl & F_MMU), bool(fl & F_AMIX), bool(fl & F_CPU040))
        s, c2 = modes.get(key, (0, 0))
        modes[key] = (s + w, c2 + 1)
    out.append("  mode                             weight     wt%      samples    sam%")
    out.append("  -----------------------  --------------  -------  -----------  -------")
    for key in sorted(modes, key=lambda k: (-modes[k][0], k)):
        su, mmu, amix, c040 = key
        label = "%s  %s %s %s" % ("SUPER" if su else "user ",
                                  "MMU" if mmu else "   ",
                                  "AMIX" if amix else "    ",
                                  "68040" if c040 else "68030")
        w, n = modes[key]
        out.append("  %-23s  %14d  %7s  %11d  %7s"
                   % (label, w, fpct(w, total_w), n, fpct(n, rec_count)))
    sup_w = sum(w for k, (w, _) in modes.items() if k[0])
    out.append("  %-23s  %14d  %7s" % ("supervisor total", sup_w, fpct(sup_w, total_w)))
    out.append("  %-23s  %14d  %7s" % ("user total", total_w - sup_w,
                                       fpct(total_w - sup_w, total_w)))

    # ---- flat profiles -------------------------------------------------------------------
    #
    # Two different tables out of the same samples, because they answer two different
    # questions and merging them answers neither:
    #
    #   BY SYMBOL is the flat profile -- which function the time is in.  A per-PC table
    #   cannot do this job: a hot loop spread over eight instruction addresses appears as
    #   eight small rows and loses to a single cold PC that happened to be sampled twice.
    #
    #   BY PC is the concentration question -- "is the guest PC distribution concentrated?",
    #   which is the same question as whether a decoded-op cache has an upside.  Here the
    #   fragmentation the flat profile must avoid IS the measurement.
    page_mask = ~((1 << args.page_bits) - 1) & 0xFFFFFFFF
    sup, usr, bypc = {}, {}, {}
    for pc, op, fl in ring.samples:
        w = (fl >> F_WEIGHT_SH) & 0xFF or 1
        if fl & F_SUPER:
            func, at = _sym_super(pc, fl, ksyms, page_mask)
            bucket = sup
        else:
            func, at = _sym_user(pc, usyms, page_mask)
            bucket = usr
        a, b = bucket.get(func, (0, 0))
        bucket[func] = (a + w, b + 1)
        key = (pc, at)
        a, b = bypc.get(key, (0, 0))
        bypc[key] = (a + w, b + 1)

    _flat(out, "supervisor flat profile", "by symbol, weighted", sup, total_w, rec_count,
          args.top, ksyms, "kernel")
    _flat(out, "user flat profile", "by symbol, weighted", usr, total_w, rec_count,
          args.top, usyms, "user")

    out.append(sec("hot individual PCs -- how concentrated is the guest PC distribution?"))
    ranked = sorted(bypc.items(), key=lambda kv: (-kv[1][0], -kv[1][1], kv[0]))
    for n in (10, 50, 200):
        if n >= len(ranked):
            out.append("  top %-4d PCs: all %d distinct PCs -- 100.00%% of observed time"
                       % (n, len(ranked)))
            break
        cum = sum(w for _, (w, _) in ranked[:n])
        out.append("  top %-4d PCs of %-6d distinct carry %s of all observed time"
                   % (n, len(ranked), fpct(cum, total_w)))
    out.append("")
    out.append("  rank        weight      wt%      samples   pc         symbol+offset")
    out.append("  ----  ------------  -------  -----------   --------   "
               "------------------------------")
    for i, ((pc, at), (w, n)) in enumerate(ranked[:args.top], 1):
        out.append("  %4d  %12d  %7s  %11d   %08x   %s"
                   % (i, w, fpct(w, total_w), n, pc, at))

    # ---- opcodes -------------------------------------------------------------------------
    ops = {}
    lines = {}
    for pc, op, fl in ring.samples:
        w = (fl >> F_WEIGHT_SH) & 0xFF or 1
        a, b = ops.get(op, (0, 0))
        ops[op] = (a + w, b + 1)
        ln = (op >> 12) & 0xF
        a, b = lines.get(ln, (0, 0))
        lines[ln] = (a + w, b + 1)

    out.append(sec("opcode histogram (weighted) -- top %d of %d distinct words"
                   % (args.opcodes, len(ops))))
    out.append("  rank  opcode  mnemonic                    weight      wt%      samples")
    out.append("  ----  ------  --------------------  ------------  -------  -----------")
    ranked = sorted(ops.items(), key=lambda kv: (-kv[1][0], -kv[1][1], kv[0]))
    for i, (op, (w, n)) in enumerate(ranked[:args.opcodes], 1):
        # The firmware writes opcode 0 when the instruction fetch itself faulted (in both
        # versions).  ORI.B #,D0
        # encodes as 0x0000 too, so the word alone cannot separate them -- say both rather
        # than pick one.
        name = "ORI / fetch faulted" if op == 0 else mnemonic(op)
        out.append("  %4d    %04x  %-20s  %12d  %7s  %11d"
                   % (i, op, name[:20], w, fpct(w, total_w), n))
    if 0 in ops:
        out.append("  note: opcode 0000 is what the firmware writes when the instruction "
                   "fetch itself faulted;")
        out.append("        ORI.B #imm,D0 has the same encoding.  %d sample(s), %s of "
                   "observed time." % (ops[0][1], fpct(ops[0][0], total_w)))

    out.append(sec("opcode line-major rollup (the dispatch-specialisation input)"))
    out.append("  line  group                               weight      wt%      samples")
    out.append("  ----  ----------------------------  ------------  -------  -----------")
    for ln in sorted(lines, key=lambda k: (-lines[k][0], k)):
        w, n = lines[ln]
        out.append("  %4X  %-28s  %12d  %7s  %11d"
                   % (ln, LINE_NAMES[ln], w, fpct(w, total_w), n))


def _resolve(pc, syms, page_mask, space):
    """(function, function+offset).  The two are separated because the flat profile groups
    by the first and the concentration table ranks by the second."""
    if syms is not None:
        hit = syms.lookup(pc)
        if hit is not None:
            name, off, kind = hit
            if kind == "data":
                lbl = "!! EXECUTING IN %s" % name
                return (lbl, "%s+0x%x" % (lbl, off))
            return (name, "%s+0x%x" % (name, off) if off else name)
        return ("%s?:%08x" % (space, pc & page_mask), "%s?:%08x" % (space, pc))
    return ("%s:%08x" % (space, pc & page_mask), "%s:%08x" % (space, pc))


def _sym_super(pc, fl, ksyms, page_mask):
    """Supervisor PC -> (function, function+offset).

    AMIX armed means the AMIX memory contract is up and the kernel's symbol table is the
    right one.  SUPER without AMIX is AmigaOS/ROM supervisor code -- a real and expected
    part of a boot profile, and NOT something to symbolize against the kernel: doing so
    would attach kernel function names to ROM addresses and the names would look plausible,
    which is worse than leaving them as addresses."""
    if not (fl & F_AMIX):
        return ("rom/amigaos:%08x" % (pc & page_mask), "rom/amigaos:%08x" % pc)
    return _resolve(pc, ksyms, page_mask, "kernel")


def _sym_user(pc, usyms, page_mask):
    return _resolve(pc, usyms, page_mask, "user")


def _flat(out, title, how, table, total_w, total_n, top, syms, what):
    subtotal_w = sum(w for w, _ in table.values())
    subtotal_n = sum(n for _, n in table.values())
    out.append(sec("%s (%s)" % (title, how)))
    out.append("  share of all observed time: %s" % fpct(subtotal_w, total_w))
    if not table:
        out.append("  (no samples)")
        return
    if syms is None:
        out.append("  No %s symbol table given, so entries are 4 KiB page buckets. Pass "
                   "--%s to name them." % (what, "kernel" if what == "kernel" else "user"))
    row = "  %4s  %12s  %7s  %8s  %11s  %7s  %s"
    out.append(row % ("rank", "weight", "wt%", "of-space", "samples", "sam%", "symbol"))
    out.append(row % ("----", "-" * 12, "-" * 7, "-" * 8, "-" * 11, "-" * 7, "-" * 30))
    ranked = sorted(table.items(), key=lambda kv: (-kv[1][0], -kv[1][1], kv[0]))
    shown_w = 0
    for i, (name, (w, n)) in enumerate(ranked[:top], 1):
        shown_w += w
        out.append(row % (i, w, fpct(w, total_w), fpct(w, subtotal_w), n,
                          fpct(n, total_n), name))
    if len(ranked) > top:
        rest_w = subtotal_w - shown_w
        rest_n = subtotal_n - sum(n for _, (_, n) in ranked[:top])
        out.append(row % ("", rest_w, fpct(rest_w, total_w), fpct(rest_w, subtotal_w),
                          rest_n, fpct(rest_n, total_n),
                          "... %d more entries" % (len(ranked) - top)))
    out.append(row % ("", subtotal_w, fpct(subtotal_w, total_w), "100.00%", subtotal_n,
                      fpct(subtotal_n, total_n), "TOTAL (%d distinct)" % len(ranked)))


# --------------------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Symbolize a Z3660 [PROF] serial capture (wire format versions 1 and 2; "
                    "a version this tool does not implement is refused, not guessed at, and "
                    "so is a capture whose magic, ver= line and grammar disagree about "
                    "which version it is).",
        epilog="The load base is not always 0x08000000: an accelerator with its own RAM "
               "uses that, an A3640 running from A3000 motherboard RAM uses 0x07000000. "
               "Read tvaddr from the loader's boot line rather than assuming.")
    ap.add_argument("capture", help="serial capture containing one or more [PROF] dumps")
    ap.add_argument("--kernel", metavar="ELF",
                    help="AMIX kernel image; symbolizes SUPER|AMIX samples")
    ap.add_argument("--load-base", metavar="ADDR", default="0x08000000",
                    help="where the loader bound the kernel (default 0x08000000)")
    ap.add_argument("--symbols", metavar="FILE",
                    help="an `nm` dump to use instead of --kernel; needs --text-size")
    ap.add_argument("--text-size", metavar="N",
                    help="size of the kernel .text, required with --symbols")
    ap.add_argument("--user", metavar="ELF",
                    help="user binary; symbolizes non-SUPER samples")
    ap.add_argument("--user-base", metavar="ADDR", default="0",
                    help="base to add to --user symbol values (default 0)")
    ap.add_argument("--probe-cost", metavar="N", type=int,
                    help="probe cost in ARM cycles, in the same unit the firmware "
                         "calibrates and prints FOR THAT DUMP'S VERSION; overrides the "
                         "capture. That unit is not the same in both: wire version 1 prices "
                         "an enter/exit PAIR (two TRANSITIONS, and the tool divides) while "
                         "version 2 prices ONE TRANSITION (and nothing is divided). The "
                         "report always states the unit it applied")
    ap.add_argument("--top", metavar="N", type=int, default=25,
                    help="flat-profile entries to print (default 25)")
    ap.add_argument("--opcodes", metavar="N", type=int, default=20,
                    help="opcode histogram entries to print (default 20)")
    ap.add_argument("--dump", metavar="N", type=int,
                    help="report only ring dump N (1-based); default is all of them")
    ap.add_argument("--page-bits", metavar="N", type=int, default=12,
                    help="page size for unsymbolized address buckets (default 12 = 4 KiB)")
    ap.add_argument("--all-symbols", action="store_true",
                    help="keep assembler-local labels (L%%..., gcc_compiled%%) in the "
                         "symbol table; by default they are filtered because they sit "
                         "inside functions and split the flat profile")
    args = ap.parse_args(argv)

    try:
        base = int(args.load_base, 0)
        ubase = int(args.user_base, 0)
    except ValueError as e:
        sys.stderr.write("ERROR: bad address: %s\n" % e)
        return 1

    try:
        rings, stats, boot, nlines, warn = parse_capture(args.capture)

        ksyms = usyms = None
        if args.kernel and args.symbols:
            raise CaptureError("--kernel and --symbols are alternatives; give one.")
        if args.kernel:
            ksyms = load_elf_symbols(args.kernel, base, "kernel", args.all_symbols)
        elif args.symbols:
            if args.text_size is None:
                raise CaptureError(
                    "--symbols needs --text-size.\n"
                    "        `nm` reports .text and .data values both counted from zero, so "
                    "they overlap;\n"
                    "        without the text size a PC that landed in .data is silently "
                    "attributed to the\n"
                    "        last function.  Take it from `size` on the same artifact the nm "
                    "dump came from.")
            ksyms = load_nm_symbols(args.symbols, base, int(args.text_size, 0), "kernel",
                                    args.all_symbols)
        if args.user:
            usyms = load_elf_symbols(args.user, ubase, "user", args.all_symbols)
    except CaptureError as e:
        sys.stderr.write("ERROR: %s\n" % e)
        return 1
    except (IOError, OSError) as e:
        sys.stderr.write("ERROR: %s\n" % e)
        return 1

    out = []
    out.append(rule("="))
    out.append("z3660 profiler capture: %s" % os.path.abspath(args.capture))
    out.append(rule("="))
    out.append("capture lines            %d" % nlines)
    out.append("ring dumps found         %d" % len(rings))
    out.append("stats dumps found        %d" % len(stats))
    if boot and boot["version"] > 1:
        out.append("boot line (line %d)      v%d, ARM clock %d Hz (clk=%s), probe %d "
                   "cyc/transition, ring %d x %d B"
                   % (boot["line"], boot["version"], boot["cpu_hz"], boot["clk"],
                      boot["probe_cyc"], boot["ring_entries"], boot["rec_size"]))
    elif boot:
        out.append("boot line (line %d)      ARM clock %d Hz measured, enter/exit pair %d "
                   "cyc, ring %d x %d B"
                   % (boot["line"], boot["cpu_hz"], boot["probe_cyc"],
                      boot["ring_entries"], boot["rec_size"]))
    else:
        out.append("boot line                ABSENT -- '[PROF] profiling build: ...' is the "
                   "only proof that")
        out.append("                         core1 is the profiling image; without it the "
                   "measured ARM clock")
        out.append("                         and the probe cost come from the dumps alone.")
    if ksyms:
        out.append("kernel symbols           %d text symbols, %s"
                   % (len(ksyms.text), ksyms.notes[0]))
        out.append("                         .text runtime range %08X..%08X"
                   % (ksyms.text_lo, ksyms.text_hi))
        if ksyms.filtered:
            out.append("                         %d assembler-local label(s) filtered out "
                       "(--all-symbols keeps them)" % ksyms.filtered)
    else:
        out.append("kernel symbols           none given (--kernel/--symbols); supervisor "
                   "samples bucket by page")
    if usyms:
        out.append("user symbols             %d text symbols, %s"
                   % (len(usyms.text), usyms.notes[0]))
        if usyms.filtered:
            out.append("                         %d assembler-local label(s) filtered out"
                       % usyms.filtered)

    # Where the probe cost comes from, in decreasing order of authority: an explicit
    # override, this dump's own measurement, then the boot line's.  The source is printed
    # because the whole probe subtraction rests on it.
    #
    # THE BOOT-LINE FALLBACK IS VERSION-GUARDED.  A boot line prices the probe in ITS
    # version's unit, and one capture can span a reflash -- a v1 boot line above a v2 dump
    # is a per-PAIR number about to be multiplied by a per-TRANSITION rule.  It is the same
    # class of error as the one v2 exists to fix, so the fallback declines across versions
    # rather than converting: a stated "unavailable" costs a column, a silent conversion
    # costs the answer.
    for i, st in enumerate(stats, 1):
        sver = st.ver if st.ver is not None else VERSION_ASSUMED
        if args.probe_cost is not None:
            pc_, src = args.probe_cost, "--probe-cost"
        elif st.probe_cyc:
            pc_, src = st.probe_cyc, "this dump's probe_cyc="
        elif boot and boot["probe_cyc"] and boot["version"] == sver:
            pc_, src = boot["probe_cyc"], "boot line"
        elif boot and boot["probe_cyc"]:
            pc_, src = 0, "unavailable"
            warn.append("stats dump #%d: no probe cost in the dump itself, and the boot line "
                        "at capture line %d is wire version %d against this dump's version "
                        "%d. The two versions price the probe in different units (a pair vs "
                        "one transition), so the boot line's figure is NOT used and the "
                        "subtraction is unavailable. Pass --probe-cost in version %d's unit "
                        "to override."
                        % (i, boot["line"], boot["version"], sver, sver))
        else:
            pc_, src = 0, "unavailable"
        report_stats(st, i, pc_, src, out, warn)

    for i, r in enumerate(rings, 1):
        if args.dump is not None and i != args.dump:
            continue
        report_ring(r, i, ksyms, usyms, args, out, warn)

    out.append(head("warnings"))
    if warn:
        for w in warn:
            out.append("  * %s" % w)
        out.append("")
        out.append("  %d warning(s).  Every number above is still what the firmware "
                   "measured; the" % len(warn))
        out.append("  warnings say what it is a measurement OF.")
    else:
        out.append("  none.")
    out.append("")

    sys.stdout.write("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
