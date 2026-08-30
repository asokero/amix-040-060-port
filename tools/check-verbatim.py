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
import hashlib, os, re, subprocess, sys

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


SPAN_ID = re.compile(r'^[0-9a-f]{12}$')


def span_id(text):
    """A stable identifier for one matched span.

    IT IS A HASH, NOT THE TEXT, AND THAT IS THE POINT.  The allowlist records decisions about
    quotations from a reference tree; writing the quotation into the allowlist would put the
    borrowed text into this repository in order to record that we had decided not to put it
    there.  The hash names the span without reproducing it, and it changes if the span changes
    -- so an edited quotation comes back for a fresh decision instead of inheriting the old one.
    """
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:12]


# ---------------------------------------------------------------- joined-stream pass ---
# WHY A SECOND PASS.  The line pass above compares a LINE of ours to a LINE of the reference,
# which is blind to the one edit an author actually makes to a pasted sentence: breaking it
# across a line so it fits.  Measured on 2026-08-30: `src/segvn_prot040.s` carried eight lines
# of SVR4 C, and this checker reported zero on it for as long as it existed -- the reference
# puts one statement per line and our comment put three on one, so no line equalled any line.
# Removing every line break on BOTH sides deletes exactly the difference that hid it.
#
# The pass is anchored on a short window (SHINGLE tokens), then EXTENDED as far as the two
# streams agree, so what gets reported is the whole shared run rather than the window.
SHINGLE = 3

# Tokens that two programs written against the same C library will produce identically without
# either author having seen the other.  This is the joined-stream form of the MIN_TOKENS rule:
# a run must carry identifiers that were CHOSEN, not ones the language and the standard headers
# dictate.  Without it the pass is unusable as a gate -- on this tree it reported 167 `#include`
# runs and 126 K&R `main` prologues, which is 74% of its output and none of it authorship.
STOCK = set("""
auto break case char const continue default do double else enum extern float for goto if int
long register return short signed sizeof static struct switch typedef union unsigned void
volatile while include define ifdef ifndef endif undef pragma main argc argv

printf fprintf sprintf sscanf scanf fscanf puts fputs putc getc fopen fclose fread fwrite
fseek ftell setbuf stdin stdout stderr perror exit abort malloc calloc realloc free
memcpy memset memcmp strcpy strncpy strcat strcmp strncmp strlen strchr strstr atoi atol
open close read write lseek stat fstat unlink errno fd usage
O_RDONLY O_WRONLY O_RDWR O_CREAT O_TRUNC O_APPEND NULL EOF
""".split())
# The second block is the C standard library and the POSIX I/O calls, and it is here on the
# SAME principle as the keywords rather than as a convenience: `if (argc < 3) { fprintf(stderr,
# "usage:` is not authorship in any sense, and eight of this gate's first 38 findings were that
# line or its sibling.  The test for whether widening this set is legitimate is whether it could
# hide the category the gate exists to find -- and it cannot, because a borrowed passage is
# borrowed for the author's OWN names: protchk, MAXBOFFSET, alloc_only, to_filesize.  None of
# those is dictated by anything.  Widen this set only by that argument, never to quieten output.
ANGLED = re.compile(r'<[^<>]*>')


def stream_tokens(lines):
    """One continuous token stream from many lines, with the line number each token came from."""
    toks, at = [], []
    for n, line in enumerate(lines, 1):
        s = COMMENT_LEAD.sub('', line.rstrip('\n')).strip()
        if not s:
            continue
        for t in s.split():
            toks.append(t)
            at.append(n)
    return toks, at


def substantial(run):
    """True if a joined run carries enough CHOSEN identifiers to be worth a human's eye."""
    text = ' '.join(run)
    if len(text) < MIN_CHARS:
        return False
    bare = ANGLED.sub(' ', text)                       # <sys/types.h> is not authorship
    bare = re.sub(r'"(?:[^"\\]|\\.)*"', ' ', bare)     # nor is a string literal's content
    ids = [t for t in re.findall(r'[A-Za-z_][A-Za-z_0-9]*', bare) if t not in STOCK]
    return len(set(ids)) >= MIN_TOKENS


def joined_hits(streams, trees):
    """Return {(label, line): (run-text, [(ref, line), ...])} for shared runs.

    `streams` is {label: (tokens, line-numbers)} so that a commit message, which is not a file,
    goes through exactly the same pass as a tracked blob.
    """
    index = {}                                          # shingle -> [(label, pos)]
    for f, (toks, at) in streams.items():
        for i in range(len(toks) - SHINGLE + 1):
            index.setdefault(tuple(toks[i:i + SHINGLE]), []).append((f, i))

    found = {}
    for tree in trees:
        for dirpath, _, names in os.walk(tree):
            if ".git" in dirpath.split(os.sep):
                continue
            for name in names:
                if not name.endswith(REF_EXT):
                    continue
                rp = os.path.join(dirpath, name)
                try:
                    with open(rp, encoding="latin1") as fh:
                        rtoks, rat = stream_tokens(fh)
                except OSError:
                    continue
                j = 0
                while j <= len(rtoks) - SHINGLE:
                    key = tuple(rtoks[j:j + SHINGLE])
                    posts = index.get(key)
                    if not posts:
                        j += 1
                        continue
                    best = 0
                    for f, i in posts:
                        toks, at = streams[f]
                        k = SHINGLE
                        while (i + k < len(toks) and j + k < len(rtoks)
                               and toks[i + k] == rtoks[j + k]):
                            k += 1
                        run = toks[i:i + k]
                        if substantial(run):
                            key2 = (f, at[i])
                            prev = found.get(key2)
                            if prev is None or len(' '.join(run)) > len(prev[0]):
                                found[key2] = (' '.join(run), [(rp, rat[j])])
                            elif (rp, rat[j]) not in prev[1]:
                                prev[1].append((rp, rat[j]))
                        best = max(best, k)
                    j += max(1, best - SHINGLE + 1)
    return found


def allowlist():
    """Return (prefixes, spans) from tools/check-verbatim.allow.

    Two forms, and the difference is deliberate:
      * `path/prefix/` alone -- every match under it is allowed.  Blunt, for the case where a
        whole file is interface by construction.
      * `path <span-id>`    -- one span in one file.  This is the normal form: each line is a
        decision about a single quotation, and nothing else is exempted by it.
    """
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check-verbatim.allow")
    prefixes, spans = [], set()
    if not os.path.exists(p):
        return prefixes, spans
    for line in open(p, encoding="utf-8"):
        if line.startswith("#") or not line.strip() or line[0].isspace():
            continue
        # The span id is the LAST field before the reason, not the second: a scan unit's label
        # may contain spaces -- `commit 13544a9 message` is one -- and a parser that assumed
        # two fields would read such a line as a path prefix called "commit" and exempt every
        # commit message in the repository.
        head = line.split("\t")[0].rstrip().split()
        if len(head) >= 2 and SPAN_ID.match(head[-1]):
            spans.add((" ".join(head[:-1]), head[-1]))
        else:
            prefixes.append(head[0])
    return prefixes, spans


def commit_messages(rng=None):
    """Yield (label, [lines]) for every commit message.

    WHY MESSAGES ARE SCANNED AT ALL.  A commit message is prose an author writes freely, and a
    quotation lands there as easily as in a file -- but nothing had ever looked.  The first run
    that did, on 2026-08-30, found five spans in four messages.  They matter more than a file
    does, not less: a file can be edited, and a pushed message cannot be changed without
    rewriting published history.  So the gate should see one BEFORE it is pushed.
    """
    sep = "\x00"
    args = ["git", "log", "-z", "--format=%h%n%B"]
    if rng:
        args.append(rng)
    out = subprocess.run(args, capture_output=True, text=True, errors="replace").stdout
    for rec in out.split(sep):
        if not rec.strip():
            continue
        lines = rec.splitlines()
        yield "commit %s message" % lines[0].strip(), lines[1:]


def tracked_files(paths):
    out = subprocess.run(["git", "ls-files", "-z"] + list(paths),
                         capture_output=True, text=True).stdout
    files = [f for f in out.split("\0") if f]
    # Reproduced on purpose: THIRD_PARTY_NOTICES/ carries licence texts in full because the
    # licences require it, and LICENSE and NOTICE carry our own MIT text and the upstream
    # copyright lines we are obliged to state.  All of it matches reference trees for the same
    # reason it matches every other repository -- it is the same standard text, copied from the
    # same standard source by everyone, which is what the text is for.
    skip = ("THIRD_PARTY_NOTICES/", "LICENSE", "NOTICE")
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
    scan_messages = "--no-messages" not in args
    if not scan_messages:
        args.remove("--no-messages")

    targets = tracked_files(args)
    units = {}                                    # label -> list of lines
    for f in targets:
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                units[f] = fh.read().splitlines()
        except (IsADirectoryError, PermissionError, OSError):
            continue
    nfiles = len(units)
    if scan_messages and not args:                # a path-limited run scans those paths only
        for label, lines in commit_messages():
            units[label] = lines

    candidates = {}
    streams = {}
    for label, lines in units.items():
        for n, line in enumerate(lines, 1):
            k = normalise(line)
            if k:
                candidates.setdefault(k, []).append((label, n))
        streams[label] = stream_tokens(lines)

    print("checking %d distinct lines from %d tracked files%s" % (
        len(candidates), nfiles,
        (" and %d commit messages" % (len(units) - nfiles)) if len(units) > nfiles else ""))
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

    allowed_prefixes, allowed_spans = allowlist()

    def classify(rows):
        a, b = [], []
        for f, line, k, refs in rows:
            sid = span_id(k)
            ok = any(f.startswith(p) for p in allowed_prefixes) or (f, sid) in allowed_spans
            (a if ok else b).append((f, line, k, refs, sid))
        return a, b

    line_rows = [(f, line, k, refs)
                 for k, refs in sorted(hits.items()) for f, line in candidates[k]]
    allowed, failing = classify(line_rows)

    joined = joined_hits(streams, trees)
    jrows = [(f, line, text, refs) for (f, line), (text, refs) in sorted(joined.items())]
    jallowed, jfailing = classify(jrows)

    def show(rows, with_id=False):
        for f, line, k, refs, sid in rows:
            print("%s:%d%s" % (f, line, ("   [%s]" % sid) if with_id else ""))
            print("    %s" % k[:110])
            print("    also in %s:%d%s" % (refs[0][0], refs[0][1],
                                           ("  (+%d more)" % (len(refs) - 1)) if len(refs) > 1 else ""))

    if allowed or jallowed:
        print("KNOWN AND DEFENDED (tools/check-verbatim.allow) -- reported, not failing:")
        print()
        show(allowed)
        show(jallowed)
        print()
    if failing:
        print("UNEXPLAINED (line pass -- a line of ours identical to a line of theirs):")
        print()
        show(failing, with_id=True)
        print()
    if jfailing:
        print("UNEXPLAINED (joined-stream pass -- line breaks removed on both sides):")
        print()
        show(jfailing, with_id=True)
        print()
    failing = failing + jfailing
    allowed = allowed + jallowed
    if failing:
        print("To record a decision about one of these, add a line to tools/check-verbatim.allow.")
        print("One line allows ONE span in ONE file, and the same span elsewhere still fails:")
        print()
        seen = []
        for f, _, _, _, sid in failing:
            if (f, sid) not in seen:
                seen.append((f, sid))
        for f, sid in seen[:3]:
            print("    %s %s\t<why this text is dictated rather than chosen>" % (f, sid))
        if len(seen) > 3:
            print("    ... and %d more distinct spans" % (len(seen) - 3))
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
