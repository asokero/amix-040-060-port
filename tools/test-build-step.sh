#!/bin/sh
# test-build-step.sh -- regression test for tools/build-step.sh.
#
#     sh tools/test-build-step.sh          # exits 0 if every case passes
#
# WHY THIS FILE EXISTS
#
# build-step.sh is the thing that decides whether a failed byte patch stops the build.  Before
# 2026-08-14 that decision was made by a shell pipeline and was always "no" (ISSUE-45).  A fix
# to a check needs its own check, or the next regression is invisible in exactly the same way.
#
# Case 3 is the one that matters most and is the reason the failure banner prints a status at
# all: the first version of run_step reported "exit status 0" for every failure, because `$?`
# after an `if` is the status of the IF, not of the command it ran.  The test caught it; nothing
# else would have, because the build still stopped.

HERE=$(cd "$(dirname "$0")/.." && pwd)
pass=0
fail=0

check() {   # check <name> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
		printf '  ok    %-46s %s\n' "$1" "$3"
	else
		fail=$((fail + 1))
		printf '  FAIL  %-46s expected %s, got %s\n' "$1" "$2" "$3"
	fi
}

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- success paths
sh -c ". '$HERE/tools/build-step.sh'; run_step 2 sh -c 'printf \"a\nb\nc\nd\ne\n\"'" > "$TMP/o" 2>&1
check "mode <n> prints the last n lines" "d e" "$(tr '\n' ' ' < "$TMP/o" | sed 's/ *$//')"

sh -c ". '$HERE/tools/build-step.sh'; run_step all sh -c 'printf \"x\ny\n\"'" > "$TMP/o" 2>&1
check "mode all prints everything" "x y" "$(tr '\n' ' ' < "$TMP/o" | sed 's/ *$//')"

sh -c ". '$HERE/tools/build-step.sh'; run_step indent sh -c 'echo z'" > "$TMP/o" 2>&1
check "mode indent indents by six" "      z" "$(cat "$TMP/o")"

sh -c ". '$HERE/tools/build-step.sh'; run_step quiet sh -c 'echo noise'" > "$TMP/o" 2>&1
check "mode quiet prints nothing" "0" "$(wc -c < "$TMP/o" | tr -d ' ')"

# ---------------------------------------------------------------- the failure path
# A failing step must: stop the caller, report the COMMAND's status (not the if's), and show
# the output that explains why -- including anything the step wrote to stderr.
sh -c ". '$HERE/tools/build-step.sh'
	run_step 3 sh -c 'echo context; echo \"ABORT patch_x @0x1234: found dead expected beef\" >&2; exit 7'
	echo REACHED-AFTER-FAILURE" > "$TMP/o" 2>&1
st=$?
check "a failed step stops the caller"        "1"   "$st"
check "  ...and nothing after it runs"        "0"   "$(grep -c REACHED-AFTER-FAILURE "$TMP/o")"
check "  ...and the command's status is shown" "1"  "$(grep -c 'exit status 7' "$TMP/o")"
# The banner echoes the command line too, so both strings appear more than once; what matters
# is that the step's own captured output block contains them.
check "  ...and stdout of the step is shown"   "1"  "$(grep -c '^    context$' "$TMP/o")"
check "  ...and stderr of the step is shown"   "1"  "$(grep -c '^    ABORT patch_x' "$TMP/o")"

# Distinct statuses must survive, not be flattened to 1.
for want in 2 3 42; do
	sh -c ". '$HERE/tools/build-step.sh'; run_step 1 sh -c 'exit $want'" > "$TMP/o" 2>&1
	check "status $want is reported verbatim" "1" "$(grep -c "exit status $want" "$TMP/o")"
done

# A step that does not exist is a failure, not a crash.
sh -c ". '$HERE/tools/build-step.sh'; run_step 1 /nonexistent/command" > "$TMP/o" 2>&1
check "a missing command fails the build" "yes" \
	"$(grep -q '\[FAIL\] build step failed' "$TMP/o" && echo yes || echo no)"

# ---------------------------------------------------------------- the real caller
check "relink-040.sh sources it" "1" "$(grep -c 'tools/build-step.sh' "$HERE/relink-040.sh")"
check "no patcher is still piped into tail" "0" \
	"$(grep -h 'python3.*| *tail' "$HERE"/relink-*.sh 2>/dev/null | wc -l | tr -d ' ')"

echo
echo "build-step: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
