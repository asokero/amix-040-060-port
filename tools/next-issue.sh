#!/bin/sh
# next-issue.sh -- print the next free issue number IN YOUR BLOCK.
#
# This exists so that the natural question -- "what number do I take?" -- has a mechanical
# answer at the moment it is asked.  That moment is when the mistake happens: on 2026-08-19
# two lines each opened KNOWN-ISSUES.md, saw a ledger ending at 45, and took 46.  Both were
# reasoning correctly from what was in front of them.  The fix is not to ask people to
# remember a rule; it is to make the easy path give the right answer.
#
# Blocks come from CONTRACTS.md via tools/blocks.py, keyed on `git config user.email`.
#
# Usage: tools/next-issue.sh
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
LEDGER="$ROOT/KNOWN-ISSUES.md"

set -- $(python3 "$HERE/blocks.py" issues)
LO=$1; HI=$2
WHO=$(python3 "$HERE/blocks.py" whoami)

[ -f "$LEDGER" ] || { echo "next-issue: ERROR: $LEDGER not found" >&2; exit 1; }

# "Used" is the union of two things, and the union matters.  The ledger headings are the
# authority, but a number is often minted into a source comment before its ledger entry is
# written -- so a number referenced anywhere in tracked files is taken too.  Taking the max
# of the ledger alone would hand out a number that is already in somebody's .s file.
USED=$( { grep -E '^#+ ' "$LEDGER" | grep -oE 'ISSUE-[0-9]+' | grep -oE '[0-9]+'
          cd "$ROOT" && git grep -hoE 'ISSUE-[0-9]+' -- . 2>/dev/null || true
        } | grep -oE '[0-9]+' | sort -un )

n=$LO
while [ "$n" -le "$HI" ]; do
	echo "$USED" | grep -qx "$n" || break
	n=$((n + 1))
done

if [ "$n" -gt "$HI" ]; then
	echo "next-issue: ERROR: block $LO-$HI is exhausted for $WHO." >&2
	echo "next-issue:        Claim another block in CONTRACTS.md rather than spilling into" >&2
	echo "next-issue:        someone else's -- a spill is silent, an extra row is not." >&2
	exit 1
fi

echo "$n"
echo "next-issue: $WHO holds issues $LO-$HI; $n is the next free one." >&2
echo "next-issue: add its ledger entry as '## ISSUE-$n: <one line>' in KNOWN-ISSUES.md." >&2
