#!/usr/bin/env python3
"""check-verbatim.py -- find lines in this repository that are copied verbatim from a
proprietary reference source tree.

    python3 tools/check-verbatim.py                     # every tracked file
    python3 tools/check-verbatim.py docs/contracts       # one path
    python3 tools/check-verbatim.py --min 16 FILE ...    # stricter threshold

WHY THIS EXISTS

This port was developed with historical System V sources open as a reference for documented
behaviour.  Citing them -- file, line, function, the shape of an algorithm -- is not copying.
Pasting their lines is.  The distinction is easy to state and easy to lose across a hundred
documents written over eight weeks, so it is checked mechanically rather than remembered.

The reference trees live outside git (they are in .gitignore and are nobody's to redistribute),
so this only runs on a machine that has them.  It reports what it could NOT check, because a
checker that silently skips its own inputs is worse than no checker.

WHAT COUNTS AS A HIT

A line of a tracked file whose normalised form (whitespace collapsed, comment markers stripped)
appears identically in a reference tree, and which is long enough and structured enough to carry
expression rather than fact.  Short forms -- a closing brace, `#endif`, a two-token constant, a
field name -- are not authorship and are not reported.

Exit status: 0 clean, 1 hits found, 2 no reference tree available to check against.
"""
import os, re, subprocess, sys

# The reference trees, relative to the repository root.  All gitignored.
REFERENCE_TREES = ["svr4-src-3b2", "usl-svr42", "svr4-v4", "amix-src"]
REF_EXT = (".c", ".h", ".s", ".S")

# A line must have at least this many significant characters to be considered expression.
# 36 was chosen by measurement, not taste: at 24 the output is dominated by idiomatic C that
# appears in every program ever written (`setbuf(stdout, (char *)0);`, `if (fstat(fd, &st) < 0) {`)
# and the real findings are buried.  At 36 every remaining hit on 2026-08-14 was a genuine
# category.  Lower it when auditing; do not raise it to make a hit go away.
MIN_CHARS = 36
# ...and at least this many alphanumeric tokens, so long punctuation runs do not qualify.
MIN_TOKENS = 3

# Lines that are structural boilerplate wherever they appear.  Matching one of these proves
# nothing about copying.
BOILERPLATE = re.compile(r'''^(
      \#\s*(include|endif|else|ifdef|ifndef|if|pragma)\b .*
    | \}? \s* (else|return|break|continue)? \s* [;{}]* \s*
    | /\*+ .* \*+/
    | \*+ .*
)$''', re.X)

COMMENT_LEAD = re.compile(r'^\s*(?:[#|]+\s?|//\s?|\*\s?|/\*\s?)')


def normalise(line):
    """Return the comparable form of a line, or None if it is too weak to compare."""
    s = COMMENT_LEAD.sub('', line.rstrip('\n'))
    s = s.strip()
    s = re.sub(r'\s+', ' ', s)
    if len(s) < MIN_CHARS:
        return None
    if BOILERPLATE.match(s):
        return None
    # Identifiers are counted OUTSIDE string literals.  A line that is only a table of names --
    # `"d0", "d1", "d2", ...` -- is data, and two programs naming the same registers will write
    # it the same way without either having seen the other.
    code = re.sub(r'"(?:[^"\\]|\\.)*"', '', s)
    if len(re.findall(r'[A-Za-z_][A-Za-z_0-9]*', code)) < MIN_TOKENS:
        return None
    return s


def allowlist():
    """Path prefixes whose matches are known and defended; see tools/check-verbatim.allow."""
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check-verbatim.allow")
    out = []
    if not os.path.exists(p):
        return out
    for line in open(p, encoding="utf-8"):
        if line.startswith("#") or not line.strip() or line[0].isspace():
            continue
        out.append(line.split("\t")[0].split()[0])
    return out


def tracked_files(paths):
    out = subprocess.run(["git", "ls-files", "-z"] + list(paths),
                         capture_output=True, text=True).stdout
    files = [f for f in out.split("\0") if f]
    skip = ("THIRD_PARTY_NOTICES/",)          # reproduced on purpose, under licence
    return [f for f in files if not f.startswith(skip)]


def main():
    args = sys.argv[1:]
    global MIN_CHARS
    if "--min" in args:
        i = args.index("--min"); MIN_CHARS = int(args[i+1]); del args[i:i+2]

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(root)

    trees = [t for t in REFERENCE_TREES if os.path.isdir(t)]
    missing = [t for t in REFERENCE_TREES if not os.path.isdir(t)]
    if not trees:
        print("NO REFERENCE TREE AVAILABLE -- nothing was checked.")
        print("  looked for: " + ", ".join(REFERENCE_TREES))
        print("  This check can only run where the reference sources are unpacked.")
        sys.exit(2)

    # Index what we are checking, not what we are checking against: the repository is small
    # and the reference trees are tens of thousands of files.
    candidates = {}
    for f in tracked_files(args):
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                for n, line in enumerate(fh, 1):
                    k = normalise(line)
                    if k:
                        candidates.setdefault(k, []).append((f, n))
        except (IsADirectoryError, PermissionError):
            continue

    print("checking %d distinct lines from %d tracked files" % (
        len(candidates), len(set(f for v in candidates.values() for f, _ in v))))
    print("against: %s%s" % (", ".join(trees),
                             ("   (absent: %s)" % ", ".join(missing)) if missing else ""))
    print()

    hits, scanned = {}, 0
    for tree in trees:
        for dirpath, _, names in os.walk(tree):
            for name in names:
                if not name.endswith(REF_EXT):
                    continue
                p = os.path.join(dirpath, name)
                scanned += 1
                try:
                    with open(p, encoding="latin1") as fh:
                        for n, line in enumerate(fh, 1):
                            k = normalise(line)
                            if k and k in candidates:
                                hits.setdefault(k, []).append((p, n))
                except OSError:
                    continue

    print("scanned %d reference files" % scanned)
    print()
    if not hits:
        print("VERBATIM MATCHES: 0")
        sys.exit(0)

    allowed_prefixes = allowlist()
    failing, allowed = [], []
    for k, refs in sorted(hits.items()):
        for f, line in candidates[k]:
            row = (f, line, k, refs)
            (allowed if any(f.startswith(a) for a in allowed_prefixes) else failing).append(row)

    def show(rows):
        for f, line, k, refs in rows:
            print("%s:%d" % (f, line))
            print("    %s" % k[:110])
            print("    also in %s:%d%s" % (refs[0][0], refs[0][1],
                                           ("  (+%d more)" % (len(refs) - 1)) if len(refs) > 1 else ""))

    if allowed:
        print("KNOWN AND DEFENDED (tools/check-verbatim.allow) -- reported, not failing:")
        print()
        show(allowed)
        print()
    if failing:
        print("UNEXPLAINED:")
        print()
        show(failing)
        print()
    print("VERBATIM MATCHES: %d unexplained, %d known" % (len(failing), len(allowed)))
    if failing:
        print("Each one is either a line to rewrite as a description, or a false positive worth")
        print("raising MIN_CHARS for.  Do not silence it by shortening the quote, and do not add")
        print("it to the allowlist unless the text is dictated by an interface.")
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
