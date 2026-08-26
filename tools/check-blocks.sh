#!/bin/sh
# check-blocks.sh -- verify that issue numbers were minted inside their author's block.
#
# A rule with no instrument is a wish.  This is the instrument, and it is only possible
# because the blocks are far apart: before the partition, one line's ISSUE-46 and the
# other's ISSUE-46 were indistinguishable and no check could have existed.  Afterwards an
# out-of-block number is wrong at a glance, which means it is also checkable.
#
# TWO CHECKS, and the distinction between them is the whole design:
#
#   1. MINTING.  A number is minted by adding a '## ISSUE-N:' heading to KNOWN-ISSUES.md,
#      and only there.  That heading must lie in the block of the commit's author.
#      References anywhere else are NOT minting and are not checked against the author --
#      citing another line's issue is normal and correct (main's ACCEPTANCE.md cites
#      ISSUE-47 from the Zorro III line, and must keep doing so).  Checking references
#      against the author would flag exactly that legitimate case.
#
#   2. ORPHANS.  Every ISSUE-N referenced anywhere in tracked files must have a ledger
#      heading.  This catches the typo and the number that was used in a source comment
#      and never written down -- the second of which is how a number gets minted twice.
#
# WHERE IT IS MEANT TO BE RUN: on a branch from another line, BEFORE merging it.  There its
# verdict is actionable -- "these numbers are out of block, renumber them before this lands",
# which is exactly what it would have said on 2026-08-19 had it existed.
#
# Run over history that predates the partition (2026-08-25) it will report the pre-partition
# mints as failures, and it is right to: those commits did mint out of block, and the fix came
# later as a renumbering commit rather than by rewriting them.  That is history being accurate,
# not the check being wrong.  Judge a merged branch by its tree, which check 2 covers.
#
# IT ALSO FLAGS THE RENUMBERING COMMIT ITSELF, and that one IS a limitation rather than
# accuracy.  Check 1 asks "did this commit introduce a ledger heading outside its author's
# block", and it cannot tell minting from RELOCATING somebody else's entry.  c67d4ca moved the
# z3660 line's issues into 100-106; the author of that commit holds 1-99, so all seven are
# reported.  Nothing is wrong with the tree.  Expect this whenever one line tidies another's
# entries, and read check 2 -- which looks at the tree rather than at authorship -- as the one
# that says whether the ledger is actually sound.
#
# Usage: tools/check-blocks.sh [<base>..<tip>]     (default: origin/main..HEAD)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
RANGE="${1:-origin/main..HEAD}"
LEDGER="$ROOT/KNOWN-ISSUES.md"
fail=0

cd "$ROOT"

echo "check-blocks: range $RANGE"
echo "== 1. minting: new ledger headings must be in their author's block =="
minted=0
for c in $(git rev-list "$RANGE" 2>/dev/null); do
	email=$(git log -1 --format='%ae' "$c" | tr 'A-Z' 'a-z')
	nums=$(git show --format= --unified=0 "$c" -- KNOWN-ISSUES.md 2>/dev/null \
	       |  grep -E '^\+#+ ' | grep -oE 'ISSUE-[0-9]+' | grep -oE '[0-9]+' || true)
	[ -n "$nums" ] || continue
	if ! set -- $(python3 "$HERE/blocks.py" issues "$email" 2>/dev/null); then
		echo "  [FAIL] $(git log -1 --format='%h' "$c"): author $email holds no block (CONTRACTS.md)"
		fail=1
		continue
	fi
	lo=$1; hi=$2
	for n in $nums; do
		minted=$((minted + 1))
		if [ "$n" -lt "$lo" ] || [ "$n" -gt "$hi" ]; then
			echo "  [FAIL] $(git log -1 --format='%h' "$c"): ISSUE-$n minted by $email, whose block is $lo-$hi"
			fail=1
		else
			echo "  ok     $(git log -1 --format='%h' "$c"): ISSUE-$n in $email's block $lo-$hi"
		fi
	done
done
[ "$minted" -eq 0 ] && echo "  (no ledger headings introduced in this range)"

echo "== 2. orphans: every referenced ISSUE-N must have a ledger heading =="
have=$(grep -E '^#+ ' "$LEDGER" | grep -oE 'ISSUE-[0-9]+' | grep -oE '[0-9]+' | sort -un)
refs=$(git grep -hoE 'ISSUE-[0-9]+' -- . | grep -oE '[0-9]+' | sort -un)
orphans=0
for n in $refs; do
	echo "$have" | grep -qx "$n" || { echo "  [FAIL] ISSUE-$n is referenced but has no ledger entry"; orphans=$((orphans+1)); fail=1; }
done
[ "$orphans" -eq 0 ] && echo "  none -- every referenced number is in the ledger"

[ "$fail" -eq 0 ] && echo "CHECK-BLOCKS-RESULT PASS" || echo "CHECK-BLOCKS-RESULT FAIL"
exit $fail
