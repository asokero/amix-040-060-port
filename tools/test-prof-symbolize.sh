#!/bin/sh
# test-prof-symbolize.sh -- regression test for tools/prof-symbolize.py.
#
#     sh tools/test-prof-symbolize.sh          # exits 0 if every case passes
#
# WHY THIS FILE EXISTS
#
# The symbolizer's job is to be right about a capture that nobody can re-take cheaply: a
# profiling run costs a firmware flash, a boot, and minutes of 115200 serial.  Every failure
# mode it guards against is one that produces a plausible-looking number rather than an
# error, which is the failure a measuring instrument must not have -- so each of them gets a
# synthetic capture here that provokes it deliberately.
#
# Nothing here needs a board, a kernel image, or a cross toolchain.  The fixtures are built
# by tools/prof-fixtures.py into a temporary directory, including a small hand-assembled
# m68k ELF, so that BOTH symbol paths -- the ELF parser used against a real build/unix-040
# and the `nm`-dump fallback -- are actually executed.  A branch that never ran is not a
# branch that works.
#
# The case that matters most is "weighting inverts the ranking".  A symbolizer that counts
# samples instead of summing WEIGHT still produces a full, well-formatted, confidently wrong
# profile, and nothing else in this file would catch it: fixture_hot has ten times the
# samples of fixture_stall and a twentieth of the time.
#
# Three later cases are here because the tool got each of them wrong against real metal
# captures, and each wrong answer looked like a right one:
#
#   * the probe subtraction inherited the firmware's 2x over-pricing (probe_cyc prices a
#     PAIR; TRANSITIONS counts each enter and each exit), which made the correction demand
#     more cycles out of LOOP than LOOP contains;
#   * the translation cross-check computed ATC_HIT + ATC_MISS, a sum with no meaning in
#     this format, so it fired on every intact dump and named the wrong cause;
#   * seven provably-intact captures were refused over a logger's timestamps and a header
#     line whose "[PROF] " the UART ate, while their payloads were complete.
#
# The refusals must survive all three repairs, which is why capture-hdrgone (the same damage
# with a field actually missing) sits next to capture-dirty.
#
# WIRE VERSION 2 doubled the size of this file, and the shape of its cases is different.  v1
# is frozen -- old captures cannot be re-taken, so every v1 assertion here is a regression
# lock and none of them may move.  The v2 cases are not regression locks: they exist because
# v2 CORRECTED three numbers that v1 mislabelled, and a mislabelled number is worse than a
# wrong one because arithmetic built on it still balances.  So each v2 assertion pins a
# figure that a tool still applying v1's rules would get DIFFERENTLY rather than fail to
# produce -- half the probe cost, an ATC rate off the wrong counter, a tail reported at
# 7.50 % when it is 20.00 %.  Any of those would come out as a full, well-formatted,
# confidently wrong report.
#
# The three "capture disagrees with itself" cases are worth their own note: none of them is
# corrupt.  Every field is present and well formed, and each simply answers the version
# question twice.  They are here because that is what a hand-edited capture, a mixed-firmware
# paste, or a generator that bumped a number without bumping a format actually looks like.

HERE=$(cd "$(dirname "$0")/.." && pwd)
TOOL="$HERE/tools/prof-symbolize.py"
GEN="$HERE/tools/prof-fixtures.py"
pass=0
fail=0

check() {   # check <name> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
		printf '  ok    %-58s %s\n' "$1" "$3"
	else
		fail=$((fail + 1))
		printf '  FAIL  %-58s expected %s, got %s\n' "$1" "$2" "$3"
	fi
}

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
FX="$TMP/fx"

python3 "$GEN" "$FX" || { echo "FAIL: fixture generation"; exit 1; }

run() {     # run <fixture> [extra args...] -> output in $TMP/o, status in $st
	f=$1
	shift
	python3 "$TOOL" "$FX/$f" "$@" > "$TMP/o" 2> "$TMP/e"
	st=$?
	cat "$TMP/e" >> "$TMP/o"
}

has() {     # has <name> <count> <pattern>   -- exact count of matching lines.  Use when the
            # count is the assertion: 0 for "must not appear", N for "appears in N places".
	check "$1" "$2" "$(grep -c -- "$3" "$TMP/o")"
}

present() { # present <name> <pattern>       -- appears at least once.  Use when a figure is
            # deliberately repeated across tables and pinning the count would only make the
            # test brittle against adding a table.
	check "$1" "yes" "$(grep -q -- "$2" "$TMP/o" && echo yes || echo no)"
}

K="--kernel $FX/kernel.elf"

echo
echo "-- the format contract: refuse what this tool does not implement -----------------"

run capture-badmagic.txt
check "bad magic is refused"                    "1" "$st"
has   "  ...and says which magic"               "1" "magic is 'Z3P2', not 'Z3P1'"

run capture-badversion.txt
check "unknown version is refused"              "1" "$st"
has   "  ...and names it"                       "1" "reports version 9"
has   "  ...and refuses rather than guesses"    "1" "Refusing rather than guessing"

run capture-badrecsize.txt
check "a different rec_size is refused"         "1" "$st"

run capture-nodumps.txt
check "a capture with no dump is an error"      "1" "$st"

echo
echo "-- a capture that disagrees with ITSELF about its version ------------------------"
# None of these is corrupt: every field is present and well formed.  Each answers the
# version question twice and gives two answers, and the two answers are not
# interchangeable -- v1 and v2 price probe_cyc in different units and disagree about what
# counter id 12 and bucket id 8 are called.  Picking a side does not raise an error further
# down; it produces a plausible wrong number, which is the failure this tool exists to not
# have.  So all three are refused, and each names what contradicts what.

run capture-v2magic1.txt
check "v2 header carrying the v1 magic is refused" "1" "$st"
has   "  ...naming both spellings"              "1" "magic is 'Z3P1', not 'Z3P2'"
has   "  ...and saying the magic encodes the version" "1" "The magic encodes the wire version"

run capture-v1v2grammar.txt
check "ver=2 in the v1 grammar is refused"      "1" "$st"
has   "  ...naming the contradiction"           "1" "declares version 2 but is written in the version-1 grammar"
has   "  ...and why guessing is worse than refusing" "1" "it produces a plausible wrong number"

run capture-v2v1grammar.txt
check "ver=1 in the v2 grammar is refused too"  "1" "$st"
has   "  ...the other way round"                "1" "declares version 1 but is written in the version-2 grammar"

echo
echo "-- wire version 2: it parses, and the three v1 defects are gone ------------------"
# The whole point of the version bump. Each assertion below is a number a tool still
# applying v1's rules would get DIFFERENTLY -- not a number it would fail to produce.

run capture-v2valid.txt $K
check "a v2 capture parses"                     "0" "$st"
has   "  ...and says which version it read"     "1" "wire version    2  (14 buckets, 20 counters)"
has   "  ...and reads the v2 boot line"         "1" "v2, ARM clock 666666666 Hz (clk=cfg), probe 46 cyc/transition"
has   "  ...with the v2 magic on the ring"      "1" "magic Z3P2  version 2"
has   "the renamed bucket 8 is TAILADV"         "2" "  8  TAILADV "
has   "  ...and the three appended tail buckets" "2" " 11  TAILSAMP "
has   "the renamed counter 12 is XLATE_OK"      "1" " 12  XLATE_OK "
has   "  ...and ATC_HIT has moved to id 19"     "1" " 19  ATC_HIT "

echo
echo "-- v2 probe: priced PER TRANSITION, and never halved -----------------------------"
# 13354050 transitions x 46 cyc = 614286300.  A tool applying v1's rule would print
# 307143150 and call the instrument half as heavy as it is.  The count itself is the v2
# shape too: the tail split adds four transitions per instruction to v1's 9354050.

has   "the probe prices transitions, not pairs" "1" "probe overhead inside the totals: 614286300 cyc"
has   "  ...showing the arithmetic without a divisor" "1" "(13354050 transitions x 46 cyc/transition"
has   "  ...and nothing is halved"              "1" "Nothing is halved here"
has   "  ...and the halved v1 figure appears nowhere" "0" "307143150"
has   "  ...and the v1 double-count text is gone" "0" "double-counts by exactly"
has   "the model reproduces the v2 transition count" "1" "13354050 transitions predicted from the counters vs 13354050 measured"
has   "  ...so the subtraction is applied"      "1" "within tolerance, subtraction applied"
has   "  ...with nothing clamped"               "0" "CLAMPED"

# An impossible probe at the firmware's own price.  v1 answered this shape by clamping each
# overflowing bucket at zero, which is exactly how the 2x over-pricing produced a full and
# plausible table.  v2 must WITHHOLD and say so.
run capture-v2probeover.txt
check "an over-total probe still reports"       "0" "$st"
has   "  ...naming the impossibility"           "1" "THE MODELLED PROBE COST EXCEEDS THE MEASURED TOTAL: 2670810000 cyc"
has   "  ...against the measured total"         "1" "2000000000 cyc measured, 133.54% of it"
has   "  ...and withholds instead of clamping"  "1" "NOTHING IS SUBTRACTED and the adjusted columns are WITHHELD"
has   "  ...clamping nothing at all"            "0" "CLAMPED"
has   "  ...naming both possible culprits"      "2" "the probe calibration"
has   "  ...and it reaches the warnings"        "1" "EXCEEDS the measured total"
has   "  ...without blaming the landing model"  "1" "the model is fine -- the subtraction is withheld"

# A v1 boot line above a v2 dump: one capture spanning a reflash.  The boot line's figure is
# per PAIR and this dump's rules are per TRANSITION, so the fallback must DECLINE.
run capture-v2bootv1.txt
check "a cross-version probe fallback still reports" "0" "$st"
has   "  ...but refuses the boot line's figure" "1" "is wire version 1 against this dump's version 2"
has   "  ...and says the overhead is unpriceable" "1" "probe overhead inside the totals: UNAVAILABLE"
has   "  ...not that it is zero"                "1" "This is NOT a claim that the overhead is zero"

echo
echo "-- v2 tail: four ids, and the instrument broken out ------------------------------"
# v1's single TAIL is v2's TAILADV+TAILSAMP+TAILPOLL+TAILSPEC.  A reader who takes v2's id 8
# for "the tail" sees 7.50% where the tail is 20.00% and reports a saving that never
# happened -- so the rollup, not the raw row, is the answer.

run capture-v2valid.txt $K
has   "the tail rolls up from four ids"         "1" "TAIL                  400000000     20.00%    100.00%"
has   "  ...and id 8 alone is only the residue" "1" "  8  TAILADV               150000000      7.50%     37.50%"
has   "  ...with TAILSAMP marked as instrument" "1" "INSTRUMENT COST, not interpreter"
has   "  ...and subtracted, not ranked"         "1" "the tail WITHOUT the instrument: 280000000 cyc =  14.00%"
has   "  ...and the probe taken off it too"     "1" "the tail with neither the instrument nor the probe"
has   "the firmware's own t line cross-checks"  "1" "the firmware's own '\[PROF\] t' line agrees -- 400000000 == 400000000"

# The firmware's t line and its b lines come off the same accumulators in the same dump, so
# they cannot disagree over one span.  If they do, the capture is two states spliced.
run capture-v2tailmismatch.txt
check "a disagreeing t line still reports"      "0" "$st"
has   "  ...as a failed cross-check"            "1" "CROSS-CHECK FAILED: the firmware's '\[PROF\] t' line says 399000000"
has   "  ...naming the difference"              "1" "sum to 400000000 -- a difference of +1000000"
has   "  ...and it reaches the warnings"        "2" "did not come off the same state"

echo
echo "-- v2 ATC: the rate comes from id 19, never from id 12 ---------------------------"
# XLATE=70000, ATC_MISS=7000, ATC_HIT(id 19)=63000, XLATE_OK(id 12)=69975.  The two are
# DIFFERENT numbers, deliberately: a tool reading id 12 as an ATC rate would print 99.96%
# where the ATC hit rate is 90.00%.

run capture-v2valid.txt $K
has   "the ATC hit rate is 90.00%"              "1" "ATC hit                               90.00%   63000 of 70000"
has   "  ...taken from the real counter"        "1" "= ATC_HIT / XLATE   \[counter id 19 -- the real one\]"
has   "  ...and NOT from id 12"                 "0" "= (XLATE - ATC_MISS) / XLATE"
has   "XLATE_OK gets its own line"              "1" "XLATE_OK (translate success)          99.96%   69975 of 70000"
has   "  ...labelled as not an ATC rate"        "1" "NOT an ATC rate"
has   "  ...and tied back to the v1 name"       "1" "this is the counter v1 called ATC_HIT"
has   "the v2 identities are checked"           "1" "XLATE_OK + FAULTS == XLATE *ok"
has   "  ...including the one v1 could not state" "1" "ATC_HIT + ATC_MISS == XLATE (when no translate faulted) *ok"
has   "  ...and v1's misnomer text is absent"   "0" "version-2 misnomer"

run capture-v2atcbroken.txt
check "an over-sum ATC identity still reports"  "0" "$st"
has   "  ...as a MISMATCH, over by the excess"  "1" "OVER by 27000"
present "  ...naming why a partition cannot exceed its set" "cannot EXCEED"

# A shortfall is LEGAL -- translates that faulted before the walk decision -- but is bounded
# by FAULTS, because every one of them threw and every throw reached the CATCH.  That bound
# is a check the firmware itself does not make.
run capture-v2atcshort.txt
check "an over-large shortfall still reports"   "0" "$st"
has   "  ...as a MISMATCH naming the shortfall" "2" "short 23000"
has   "  ...bounded by FAULTS"                  "1" "exceed FAULTS (25)"
present "  ...and says why FAULTS bounds it"    "every throw reached the CATCH"

echo
echo "-- v2 on the 68030: two absences, and neither is a zero --------------------------"
# The 030 has no tier-0 counters AND no XLATE_OK site.  Both read zero and zero means
# ABSENT: "0.00% returned an address" would claim every translate faulted.  ATC_HIT (id 19)
# on the 030 was always genuine, so that rate is real.

run capture-v2-030.txt
check "the v2 68030 capture parses"             "0" "$st"
has   "  ...tier 0 absent, not zero"            "3" "no tier-0 page-cache counters on the 68030 path"
has   "  ...XLATE_OK absent, not zero"          "1" "no XLATE_OK site on the 68030 path (absent, not zero)"
has   "  ...and its identity is n/a, not a mismatch" "1" "XLATE_OK + FAULTS == XLATE *n/a"
has   "  ...but the real ATC rate still works"  "1" "ATC hit                               98.46%"
has   "  ...and that identity does hold"        "1" "ATC_HIT + ATC_MISS == XLATE (when no translate faulted) *ok"
has   "  ...with no 0.00% translate-success claim" "0" "0.00%   0 of 2600000"

echo
echo "-- v2 clk=: the one number nothing else in the dump can check --------------------"
# CPU:global-timer is a fixed 2:1 in silicon, so cyc_span and wall_ticks scale TOGETHER and
# an error in the absolute rate cancels out of the wrap cross-check's ratio.  That check
# passes to three decimals while the clock is 65% wrong.  It must say so where the clean
# result is, not only in the warnings.

run capture-v2valid.txt $K
has   "clk=cfg is surfaced"                     "2" "clk=cfg -- the rate core0 published"
has   "  ...and the wrap check disclaims the clock" "1" "this is a WRAP check, not a CLOCK check"

run capture-v2bsp.txt
check "a clk=bsp capture still reports"         "0" "$st"
has   "  ...flagged on both dumps"              "2" "THE COMPILE-TIME BSP CONSTANT, NOT THE RUNNING CLOCK"
has   "  ...saying the wrap check cannot see it" "2" "AND THE WRAP CROSS-CHECK CANNOT SEE IT"
has   "  ...and warning per dump"               "2" "the ARM clock is the COMPILE-TIME BSP constant"
present "  ...naming the blindness in the warning" "STRUCTURALLY BLIND"
has   "  ...and quantifying the risk"           "2" "1.65x"

# A clk= value no version defines.  Unsafe-by-default is right; reporting it AS `bsp` would
# not be, because that names a specific origin this tool cannot know it had.
run capture-v2clkodd.txt
check "an unrecognised clk= still reports"      "0" "$st"
has   "  ...named as unrecognised"              "1" "clk=pll -- UNRECOGNISED"
has   "  ...listing what the version does define" "1" "this version defines only cfg and bsp"
has   "  ...and still treated as the unsafe case" "1" "NOT KNOWN TO BE THE RUNNING CLOCK"
present "  ...with the drift in the warnings"   "is neither"

echo
echo "-- truncation: a lost serial line must never become a shorter profile ------------"

run capture-truncated.txt
check "a short ring dump is a hard error"       "1" "$st"
has   "  ...naming the capture line"            "1" "capture line 38: '\[PROF\] ring end n=40'"
has   "  ...and how many lines were lost"       "1" "lost 7 line(s)"

run capture-hdrmismatch.txt
check "header vs terminator mismatch is fatal"  "1" "$st"
has   "  ...naming rec_count"                   "1" "header promised rec_count=40"

run capture-noend.txt
check "a capture cut off inside the ring"       "1" "$st"
has   "  ...says it was never closed"           "1" "never closed by a"

run capture-mangled.txt
check "a mangled sample line is fatal"          "1" "$st"
has   "  ...and quotes the line"                "1" "S 0800000 4e71 0101"

echo
echo "-- delivered dirty: repair what is intact, refuse what is missing ----------------"
# capture-dirty is capture-valid's own bytes with a logger timestamp on every line and a
# 'ring hdr' line run together with the console echo, its '[PROF] ' eaten -- the two defects
# every metal C1 capture arrived with.  Nothing is missing, so the report must be the same
# report; that identity, not a spot check, is the assertion.

run capture-dirty.txt $K
check "a timestamped, header-damaged capture parses" "0" "$st"
has   "  ...announcing the stripped line prefix" "1" "carry a logger line prefix"
has   "  ...and the repaired header line"       "1" "arrived without its literal '\[PROF\] ' prefix"
has   "  ...and it is still checked afterwards" "1" "cross-checks still have to pass"
sed -n '/supervisor flat profile/,/TOTAL (/p' "$TMP/o" > "$TMP/dirty-profile"
sed -n '/stage attribution \/ counters/,/^-- WEIGHT histogram/p' "$TMP/o" > "$TMP/dirty-body"
run capture-valid.txt $K
sed -n '/supervisor flat profile/,/TOTAL (/p' "$TMP/o" > "$TMP/clean-profile"
sed -n '/stage attribution \/ counters/,/^-- WEIGHT histogram/p' "$TMP/o" > "$TMP/clean-body"
check "the repaired profile is the clean one"   "same" \
      "$(cmp -s "$TMP/dirty-profile" "$TMP/clean-profile" && echo same || echo DIFFERENT)"
check "  ...and so are its buckets and coverage" "same" \
      "$(cmp -s "$TMP/dirty-body" "$TMP/clean-body" && echo same || echo DIFFERENT)"

run capture-hdrgone.txt $K
check "the same damage with a field LOST is refused" "1" "$st"
has   "  ...and says the payload is what is gone" "1" "one lost payload, which nothing in the"

echo
echo "-- WEIGHT: the failure that produces a confident wrong answer -------------------"
# fixture_hot   30 samples x weight   1 = 30
# fixture_stall  3 samples x weight 200 = 600
# Counting samples ranks fixture_hot first.  Weighting ranks fixture_stall first, by 20x.

run capture-weighted.txt $K
check "weighted capture parses"                 "0" "$st"
check "rank 1 is the STALL, not the hot loop"   "fixture_stall" \
      "$(awk '/^ +1 +600 /{print $NF}' "$TMP/o" | head -1)"
check "rank 2 is the loop with 10x the samples" "fixture_hot" \
      "$(awk '/^ +2 +30 /{print $NF}' "$TMP/o" | head -1)"
present "the stall is 93.75% of time"              "600   93.75%"
has   "  ...on 6.98% of the samples"            "1" "6.98%  fixture_stall"
has   "the hot loop is 69.77% of the samples"   "1" "69.77%  fixture_hot"

echo
echo "-- both symbol paths, and they must agree ---------------------------------------"

run capture-weighted.txt --symbols "$FX/kernel.nm" --text-size 0x2000
check "the nm path parses"                      "0" "$st"
sed -n '/supervisor flat profile/,/TOTAL (/p' "$TMP/o" > "$TMP/nm-profile"
run capture-weighted.txt $K
sed -n '/supervisor flat profile/,/TOTAL (/p' "$TMP/o" > "$TMP/elf-profile"
check "nm and ELF paths give the same profile" "same" \
      "$(cmp -s "$TMP/nm-profile" "$TMP/elf-profile" && echo same || echo DIFFERENT)"

run capture-weighted.txt --symbols "$FX/kernel.nm"
check "--symbols without --text-size refuses"   "1" "$st"
has   "  ...and explains why it needs it"       "1" "both counted from zero"

echo
echo "-- symbol table hygiene --------------------------------------------------------"

run capture-valid.txt $K
check "the valid capture parses"                "0" "$st"
present "aliased symbol resolves deterministically" "fixture_alias$"
has   "  ...and never to the _orig alias"       "0" "fixture_alias_orig"
has   "a PC in .data is flagged, not named"     "1" "EXECUTING IN kernel .data/.bss"
has   "SUPER without AMIX is not given kernel names" "1" "rom/amigaos:00f80000"
has   "the flat profile groups by symbol"       "1" "35.00%  fixture_hot"

echo
echo "-- coverage, drops, and the wrap cross-check ------------------------------------"

has   "a complete dump says so"                 "1" "complete: every sample taken"
has   "a consistent span reports no missed wrap" "1" "No PMCCNTR wrap was missed"

run capture-wrapped.txt
check "a wrapped ring still reports"            "0" "$st"
has   "  ...but says it is the TAIL of the run" "1" "THE RING WRAPPED"
has   "  ...and detects exactly one wrap"       "1" "approximately 1 MISSED PMCCNTR WRAP"
has   "  ...and says the PC map survives it"    "1" "PC map, the mode split and the WEIGHT totals below are UNAFFECTED"

run capture-stopgap.txt
check "a stop-to-dump gap still reports"        "0" "$st"
has   "  ...is NOT called a missed wrap"        "0" "MISSED PMCCNTR WRAP"
has   "  ...and is explained in seconds"        "1" "3.000 s of un-sampled wall time"

echo
echo "-- WEIGHT histogram and saturation ---------------------------------------------"

run capture-valid.txt $K
has   "the weight histogram is reported"        "1" "what the sampler could NOT see"
has   "  ...with the weight>1 share called out" "1" "carrying  82.92% of all observed time"
has   "  ...and saturation marked as a floor"   "1" "SATURATED: a floor, not a measure"
has   "  ...and warned about"                   "1" "saturated at WEIGHT=255"
has   "reserved flag bits are masked and noted" "1" "reserved flag bits 4..7 set"
has   "interleaved console traffic survives"    "1" "non-sample line(s) interleaved"

echo
echo "-- stage buckets and the probe-cost subtraction ---------------------------------"

has   "the probe model reproduces TRANSITIONS"  "1" "9354050 transitions predicted from the counters vs 9354050 measured"
has   "  ...so the subtraction is applied"      "1" "within tolerance, subtraction applied"
# The subtraction must MOVE a share.  LOOP pays for every exit back into it, so its share
# falls from 6.67% to 4.09%; a distribution proportional to cycles could not do that.
has   "LOOP raw share"                          "1" "LOOP                   60000000    6.67%"
has   "  ...and its adjusted share differs"     "1" "34699863    4.09%"

# THE UNIT.  probe_cyc=11 prices an enter/exit PAIR and TRANSITIONS=9354050 counts each
# enter and each exit, so the priced quantity is 4677025 pairs and the overhead is
# 4677025 x 11 = 51447275 cyc -- not the 102894550 the firmware's own line prints.  Both
# numbers are on the report, labelled, because the firmware's is what a reader coming from
# the console has in front of them.
has   "the probe total prices PAIRS, not transitions" "1" "probe overhead inside the totals: 51447275 cyc"
has   "  ...showing the division and the unit"  "1" "(9354050 transitions / 2 = 4677025 enter/exit pairs x 11 cyc/pair"
has   "  ...and the per-transition cost"        "1" "= 5.50 cyc per transition; one enter/exit pair is 2 transitions"
has   "  ...and the firmware's doubled figure, named as such" "1" \
      "prints TRANSITIONS x probe_cyc = 102894550 cyc"
has   "  ...saying by how much it double-counts" "1" "double-counts by exactly 2x"
# and the parts sum to the whole: 900000000 - 51447275, up 2 cycles of per-bucket integer
# truncation.  At the old doubled figure this row could not balance at all -- the LOOP
# subtraction alone exceeded LOOP, and the clamp absorbed the difference invisibly.
has   "the adjusted column sums to total - probe" "1" "51447275        848552727"
has   "  ...and nothing was clamped at this price" "0" "CLAMPED"

# The clamp is how an over-priced probe announces itself, so it must not be silent: at the
# firmware's own doubled figure it was, which is what let 82.65% of a run look subtractable
# out of buckets that did not contain it.
run capture-valid.txt $K --probe-cost 200
has   "an impossible subtraction is disclosed"   "1" "2 bucket(s) were CLAMPED at zero"
has   "  ...as evidence about the PRICE"         "1" "evidence the probe PRICE is too high"
has   "  ...and it reaches the warnings"         "1" "bucket(s) clamped at zero"
has   "  ...with the price attributed to the override" "1" "price from --probe-cost"

run capture-badmodel.txt
has   "a model that does not hold is withheld"  "1" "adjusted' columns are WITHHELD"
has   "  ...with the raw numbers left intact"   "1" "Raw cycles and shares above are unaffected"

run capture-stackovf.txt
has   "STACK_OVF != 0 is called untrustworthy"  "1" "This dump is not trustworthy"
present "a profiling build of the wrong loop"   "profiling build of the DIAGNOSTIC loop"

echo
echo "-- counter-derived rates -------------------------------------------------------"

run capture-valid.txt $K
has   "ipagecache hit rate"                     "1" "ipagecache hit                        97.50%"
has   "dpagecache read hit rate"                "1" "dpagecache read hit                   97.14%"
has   "ATC hit rate"                            "1" "ATC hit                               90.00%"
has   "table walk rate"                         "1" "tier 2 -- table walk rate             10.00%"
has   "  ...derived without ATC_HIT"            "1" "= (XLATE - ATC_MISS) / XLATE"

# The old check computed ATC_HIT + ATC_MISS and called a mismatch "the two tiers disagree".
# In this format that sum has no meaning -- ATC_HIT counts translates that SUCCEEDED -- so
# the check fired on every intact dump and named a cause that was not the cause.
has   "the two identities that do hold are checked" "1" "ATC_HIT + FAULTS == XLATE"
has   "  ...and the tier-0 one with them"       "1" "IPAGE_MISS + DPAGE_RMISS + DPAGE_WMISS == XLATE"
has   "  ...and ATC_HIT is named as the misnomer" "1" "ATC_HIT is a version-1 misnomer"
has   "the meaningless sum is not computed"     "1" "ATC_HIT + ATC_MISS is therefore a meaningless sum"
has   "  ...and its wrong reason is gone"       "0" "the two tiers disagree"

run capture-atcbroken.txt
check "a broken ATC_HIT identity still reports" "0" "$st"
has   "  ...as a MISMATCH on that identity"     "1" "ATC_HIT + FAULTS == XLATE *MISMATCH  *12370 vs 70000"
present "  ...with the right reason"                "ATC_HIT counts translates that SUCCEEDED"
present "  ...and the rates said not to depend on it" "do not depend on it"
has   "  ...and the tier-0 identity still passes" "1" "DPAGE_WMISS == XLATE *ok"

run capture-tier0broken.txt
check "a broken tier-0 identity still reports"  "0" "$st"
has   "  ...as a MISMATCH on that identity"     "1" "DPAGE_WMISS == XLATE *MISMATCH  *71000 vs 70000"
present "  ...naming what XLATE counts"             "XLATE counts the calls into mmu_translate"
has   "  ...and the ATC_HIT identity still passes" "1" "ATC_HIT + FAULTS == XLATE *ok"

run capture-030.txt
has   "68030: tier 0 is absent, not zero"       "3" "no tier-0 page-cache counters on the 68030 path"
has   "  ...but the ATC tiers are still there"  "1" "ATC hit                               98.46%"
has   "  ...and its identity is n/a, not a mismatch" "1" "DPAGE_WMISS == XLATE *n/a"

echo
echo "-- several dumps in one capture ------------------------------------------------"

run capture-two.txt $K
check "a capture with two ring dumps parses"    "0" "$st"
has   "  ...and both are found"                 "1" "ring dumps found         2"
has   "  ...and both are reported"              "2" "^ring dump #"
run capture-two.txt $K --dump 2
has   "--dump selects one of them"              "1" "^ring dump #2"
has   "  ...and only that one"                  "0" "^ring dump #1"

echo
echo "-- the output is evidence, so it must be stable ---------------------------------"

python3 "$TOOL" "$FX/capture-valid.txt" $K > "$TMP/a" 2>&1
python3 "$TOOL" "$FX/capture-valid.txt" $K > "$TMP/b" 2>&1
check "two runs are byte-identical"             "same" \
      "$(cmp -s "$TMP/a" "$TMP/b" && echo same || echo DIFFERENT)"
check "no trailing whitespace in the report"    "0" \
      "$(grep -c '[ 	]$' "$TMP/a")"

echo
echo "-- the real artifact, when this machine has one ---------------------------------"
# build/unix-040 is gitignored, so a fresh clone has nothing to point at.  This is a SKIP
# and not a pass: it is the only case that exercises the ELF parser against a genuine
# ET_REL kernel of the size and symbol-table shape the tool exists for.
if [ -f "$HERE/build/unix-040" ]; then
	run capture-valid.txt --kernel "$HERE/build/unix-040"
	check "a real kernel image symbolizes"          "0" "$st"
	has   "  ...with its true .text extent"         "1" "\.text runtime range 08000000\.\.080F5190"
	has   "  ...and assembler labels filtered out"  "1" "assembler-local label(s) filtered out"
	has   "  ...so a function name wins, not a marker" "0" "gcc_compiled%"
	run capture-valid.txt --kernel "$HERE/build/unix-040" --all-symbols
	present "--all-symbols puts the markers back"   "gcc_compiled%"
else
	printf '  SKIP  %s\n' "build/unix-040 absent -- the real-artifact ELF case did NOT run"
fi

echo
echo "prof-symbolize: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
