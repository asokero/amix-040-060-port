#!/usr/bin/env python3
"""blocks.py -- resolve the calling machine's allocation blocks from CONTRACTS.md.

This is the ONLY parser of the block registry.  Every consumer -- tools/next-issue.sh,
tools/check-blocks.sh, src/stamp_buildid.py -- calls this script rather than reading the
table itself, so the table has one reader and cannot be interpreted two ways.  That is the
same reasoning that put the table in one file to begin with: the defect this whole
mechanism exists to prevent was two lines applying the same rule to different data.

Identity comes from `git config user.email`, which is already present on every machine,
already used by git for authorship, and survives both a fresh clone and a lost session --
the three properties a rule needs if nobody is going to be told it.

Usage:
    blocks.py issues   [email]      -> "100 199"
    blocks.py buildseq [email]      -> "50 99"
    blocks.py whoami                -> the resolved email

Exit 3 means the identity is not in the registry.  That is not a crash: it is the signal
to claim a block by adding a row to CONTRACTS.md, and the message says so.
"""
import os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
CONTRACTS = os.path.join(HERE, os.pardir, 'CONTRACTS.md')

def die(msg, code=1):
    sys.exit(f"blocks: ERROR: {msg}")

def git_email():
    try:
        out = subprocess.run(['git', 'config', 'user.email'],
                             capture_output=True, text=True, check=True).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        out = ''
    if not out:
        die("`git config user.email` is empty -- set it, or pass the address explicitly")
    return out.lower()

def registry():
    """Every row of the block table, as {email: (issues, buildseq)}.

    A row is recognised by its first cell containing '@'.  That deliberately ignores the
    header, the separator, and any prose table elsewhere in the file, so the registry can
    move around inside CONTRACTS.md without breaking this parser.
    """
    if not os.path.exists(CONTRACTS):
        die(f"{CONTRACTS} not found -- the block registry lives there")
    rows = {}
    rng = re.compile(r'^\s*(\d+)\s*-\s*(\d+)\s*$')
    for line in open(CONTRACTS, encoding='utf-8'):
        if not line.lstrip().startswith('|'):
            continue
        cells = [c.strip() for c in line.strip().strip('|').split('|')]
        if len(cells) < 3 or '@' not in cells[0]:
            continue
        email = cells[0].strip('`* ').lower()
        mi, mb = rng.match(cells[1]), rng.match(cells[2])
        if not (mi and mb):
            die(f"registry row for {email} has an unparseable range: {line.strip()}")
        rows[email] = ((int(mi.group(1)), int(mi.group(2))),
                       (int(mb.group(1)), int(mb.group(2))))
    if not rows:
        die(f"no registry rows found in {CONTRACTS} -- has the table moved or changed shape?")
    return rows

def lookup(email):
    rows = registry()
    if email not in rows:
        known = ', '.join(sorted(rows)) or '(none)'
        sys.stderr.write(
            f"blocks: `{email}` is not in the block registry in CONTRACTS.md.\n"
            f"blocks: registered: {known}\n"
            f"blocks: Claim a block before opening your first issue or building an image:\n"
            f"blocks:   add a row taking the next free hundred (issues) and fifty (build-id seq).\n"
            f"blocks: That is self-service by design -- you do not need anyone's permission,\n"
            f"blocks: you need the row to exist so the next person can see it is taken.\n")
        sys.exit(3)
    return rows[email]

def main():
    if len(sys.argv) < 2:
        die(f"usage: {sys.argv[0]} issues|buildseq|whoami [email]")
    what = sys.argv[1]
    email = (sys.argv[2] if len(sys.argv) > 2 else git_email()).lower()
    if what == 'whoami':
        print(email); return
    issues, buildseq = lookup(email)
    if what == 'issues':
        print(f"{issues[0]} {issues[1]}")
    elif what == 'buildseq':
        print(f"{buildseq[0]} {buildseq[1]}")
    else:
        die(f"unknown query `{what}` -- expected issues, buildseq or whoami")

if __name__ == '__main__':
    main()
