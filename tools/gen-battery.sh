#!/bin/sh
# gen-battery.sh -- generate the guest battery driver from tools/status-facts.sh.
#
# WHY THIS EXISTS.  The battery driver is a list of counter-block addresses, and every one of
# them moves when the kernel is relinked.  Until now each driver was produced by copying the
# previous one and editing the addresses against a fresh `status-facts.sh` run -- a hand-written
# third pass over numbers that were already correct twice, and the place where an error gets
# through without failing: a stale address returns a plausible number instead of an error.
# `batteryrun-260827-13.sh` also shows the shape of the failure, in a smaller way -- it uses the
# name `A3D_N` for two different things (a block length, then a counter address) and only works
# because one assignment happens after the last read of the other.  Generated names do not
# collide by accident.
#
# The addresses come from `tools/status-facts.sh`, which derives them from the artifact.  This
# script parses that output, emits the driver, and then CHECKS WHAT IT EMITTED against the ELF
# again before printing anything: every `chk` line's address is converted back to a .data file
# offset and the four bytes there must equal the magic constant on the same line.  That does not
# make the arithmetic independent -- it is the same formula -- but it does make the transcription
# checked, which is the step that was being done by hand.
#
# usage:  sh tools/gen-battery.sh <kernel-image> <load-base> > test-tools/batteryrun-<id>.sh
#           sh tools/gen-battery.sh build/unix-040-quiet 0x07000000    # A3640: no local RAM
#           sh tools/gen-battery.sh build/unix-040       0x08000000    # accelerator with RAM
#
# THE LOAD BASE IS NOT OPTIONAL HERE.  status-facts.sh defaults to 0x08000000 because that is
# what every accelerator with its own RAM gives; an A3640 runs from motherboard RAM at
# 0x07000000 and every address below would be wrong by 16 MiB.  Read it from the loader's own
# boot output (`kernel: entry=07000000 tvaddr=07000000 ...`) rather than assuming it.
#
# The generated driver is Bourne sh for the GUEST: backticks, no $(...), no [[ ]], and no
# `grep -q` -- see AGENTS.md, "Code that runs on AMIX itself".
set -e

HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$(cd "$(dirname "$0")" && pwd)/config-load.sh"

IMG="$1"
BASE="$2"
if [ -z "$IMG" ] || [ -z "$BASE" ]; then
	echo "usage: sh tools/gen-battery.sh <kernel-image> <load-base>" >&2
	echo "       both arguments are required -- see the header of this script" >&2
	exit 2
fi
[ -f "$IMG" ] || { echo "ERROR: no such image: $IMG" >&2; exit 1; }

# status-facts goes to a temporary file rather than down a pipe: `python3 - <<PY` already uses
# stdin for the program text, and a second writer there is read as more program.
FACTS=$(mktemp)
trap 'rm -f "$FACTS"' EXIT INT TERM
sh "$HERE/tools/status-facts.sh" "$IMG" "$BASE" > "$FACTS"

python3 - "$IMG" "$BASE" "$FACTS" <<'PY'
import re, struct, subprocess, sys

img, base = sys.argv[1], int(sys.argv[2], 0)
facts = open(sys.argv[3]).read()

# ---------------------------------------------------------------- parse status-facts output
ident = {}
for k in ('build id', 'sha256', 'text', 'image'):
    m = re.search(r'^%s\s+(.+)$' % re.escape(k), facts, re.M)
    if m:
        ident[k] = m.group(1).strip()
if 'build id' not in ident:
    sys.exit('ERROR: could not read the build id out of status-facts output')
buildid = ident['build id'].split()[0]
# The file is named for the image, not for the CPU: `68040-260830-06` and `68060-260830-06` are
# the same image seen from two accelerators -- the prefix is what `uname -m` printed on the
# machine it was read from.  See KNOWN-ISSUES.md, "the build-id prefix is a CPU readout".
stem = buildid.split('-', 1)[1] if buildid.split('-', 1)[0] in ('68040', '68060') else buildid
sha = ident['sha256']
textsize = int(re.search(r'^text\s+(\d+)', facts, re.M).group(1))

magics = []                                    # (block, addr, magic-hex)
for m in re.finditer(r'^\| `(\w+)_magic` \| `([0-9A-F]{8})` \| `([0-9a-f]{8})` \|', facts, re.M):
    magics.append((m.group(1), int(m.group(2), 16), m.group(3)))

blocks = {}                                    # block -> [(addr, symbol), ...]
cur = None
for line in facts.splitlines():
    h = re.match(r'^\*\*`(\w+)` block\*\*', line)
    if h:
        cur = h.group(1); blocks[cur] = []; continue
    if cur:
        f = re.match(r'^\s+\+\S+\s+(\w+)\s+@\s+([0-9A-F]{8})$', line)
        if f:
            blocks[cur].append((int(f.group(2), 16), f.group(1)))
        elif line.startswith('##'):
            cur = None

if not magics:
    sys.exit('ERROR: status-facts printed no magic table -- refusing to emit an empty driver')

# ---------------------------------------------------------------- runs: how kpeek reads a block
# kpeek takes an address and a LONGWORD COUNT, so a block is read as its byte extent and not as
# its member count: a member may be a byte field, a 16-byte frame or an array, and the members
# either side of it are still worth reading.  The two are not the same number -- `smu` has 37
# named members spanning 44 longwords -- and the older hand-written drivers used the extent.
#
# A block is split into more than one read only where the gap is larger than GAP_MAX bytes.
# That is what separates `dma_on`, which sits 20 KiB away from the rest of its block, from
# `smu_bitpop`, which is an eight-longword array in the middle of one.  Without the split the
# driver would ask kpeek for five thousand longwords; without the tolerance it would issue a
# separate call for every array.
GAP_MAX = 64

def runs(members):
    out = []
    for addr, name in members:
        if out and addr - out[-1][-1] <= GAP_MAX:
            out[-1].append(addr)
        else:
            out.append([addr])
    return [(r[0], (r[-1] - r[0]) // 4 + 1) for r in out]

# ---------------------------------------------------------------- symbol lookup for the zeros
sym = {}
for blk, members in blocks.items():
    for addr, name in members:
        sym[name] = addr

def need(name):
    if name not in sym:
        sys.exit('ERROR: symbol %s is not in this image -- the driver would read a hole' % name)
    return sym[name]

# The two must-stay-zero groups.  Both are read FROM THE DEVICE and not grepped out of the log,
# because a grep pattern in this file can match the line this file itself printed -- which is
# what happened to five separate checks on 2026-08-26.
ZERO_A3W = ['a3w_nodev', 'a3w_other', 'a3w_dead_n', 'a3d_n']
READ_A3W = [('a3w_calls', 'every level-2 interrupt'), ('a3w_own', 'INT_P set at entry'),
            ('a3w_eint_only', 'pure SDMAC events -- ISSUE-53 closes when this is nonzero'),
            ('a3w_eint_acked', 'CINT strobes issued')]
ZERO_A3P = ['a3p_d_quar', 'a3p_d_badphase', 'a3p_d_badstat', 'a3p_d_notowner']
READ_A3P = [('a3p_d_try', 'drains attempted'), ('a3p_d_bytes', 'bytes discarded'),
            ('a3p_d_sent', 'ABORT messages sent'), ('a3p_d_busfree', 'clean bus-free seen'),
            ('a3p_d_failed', 'requests retired EIO')]

TESTS = [('proctest', 'PROCTEST-RESULT PASS'), ('fputest', 'FPUTEST Test A PASS'),
         ('mlocktest', 'MLOCKTEST-RESULT PASS'), ('msynctst', 'MSYNC-OK'),
         ('mincoretst', 'MINCORE PASS'), ('bigargv', 'BIGARGV PASS'),
         ('ptracepoke', 'PTRACEPOKE-RESULT PASS'), ('bmaptest', 'BMAPTEST-RESULT PASS'),
         ('devmaptest', 'DEVMAPTEST-RESULT PASS'), ('exectest 20', 'EXECTEST-RESULT PASS'),
         ('mul64test', 'MUL64-RESULT PASS'), ('protfault a', 'PROTFAULT-RESULT PASS'),
         ('protfault b', None)]

# ---------------------------------------------------------------- emit
o = []
w = o.append
w("# batteryrun-%s.sh -- GENERATED, do not edit by hand." % stem)
w("#   sh tools/gen-battery.sh %s %s > test-tools/batteryrun-%s.sh"
  % (ident.get('image', img), '0x%08X' % base, stem))
w("#")
w("#   artifact   %s" % ident.get('image', img))
w("#   build id   %s" % buildid)
w("#   sha256     %s" % sha)
w("#   load base  0x%08X   <- from the loader's boot output, not assumed" % base)
w("#   text       %d (0x%x)" % (textsize, textsize))
w("#")
w("# Relinking bumps the build id and the sha256 every time, and moves these addresses whenever a")
w("# counter block is added, removed or resized.  Regenerate rather than edit: `uname -m` on the")
w("# guest must print the build id above, and the magic check below is what proves the addresses")
w("# belong to the kernel that is actually running.")
w("#")
w("# %d BLOCKS, %d CHECKS.  A block whose magic does not read back aborts the run: every"
  % (len(magics), len(magics)))
w("# other number taken from a wrong address is plausible, and none of it is a measurement.")
w("#")
w("#   (nohup sh -c \"sh /tmp/batteryrun-%s.sh /tmp/battery.log > /tmp/battery.log 2>&1\" &)" % stem)
w("K=/kpeek")
w("")

names = {}
asn = []
for blk, addr, magic in magics:
    v = re.sub(r'[^A-Za-z0-9]', '_', blk).upper()
    names[blk] = v
    rs = runs(blocks.get(blk, [(addr, blk + '_magic')]))
    asn.append(("%s=%08X" % (v, addr),
                "" if len(rs) == 1 else "the block is not contiguous: %d reads" % len(rs)))
    for i, (a, n) in enumerate(rs):
        asn.append(("%s_R%d=%08X" % (v, i + 1, a), ""))
        asn.append(("%s_N%d=%d" % (v, i + 1, n), "%d longwords" % n))
wid = max(len(t) for t, _ in asn) + 2
for tok, note in asn:
    w(tok if not note else "%-*s# %s" % (wid, tok, note))
w("")

w('echo "=== IDENTITY ==="')
w("uname -m")
w('echo "=== MAGIC CHECK (%d blocks, %d checks) ==="' % (len(magics), len(magics)))
w("chk() {")
w("\tm=`$K $1 1 | sed \"s/.*= //;s/ .*//\"`")
w("\tif [ \"$m\" != \"$2\" ]; then")
w("\t\techo \"ABORT: $3 = $m, expected $2\"; exit 1")
w("\tfi")
w("}")
for blk, addr, magic in magics:
    w("chk $%-14s %s %s_magic" % (names[blk], magic, blk))
w('echo "all %d magics OK"' % len(magics))
w("")

w("dump() {")
for blk, addr, magic in magics:
    v = names[blk]
    rs = runs(blocks.get(blk, [(addr, blk + '_magic')]))
    for i in range(len(rs)):
        label = blk + ':' if i == 0 else blk + ' (cont):'
        w("\techo \"%-16s\" ; $K $%s_R%d $%s_N%d" % (label, v, i + 1, v, i + 1))
w("}")
w("")

w('echo "=== COUNTERS BEFORE ==="')
w("dump")
w('echo "=== BATTERY ==="')
w("cd /tmp")
for t, _ in TESTS:
    w('echo "---- %s"; ./%s' % (t, t))
w('echo "=== COUNTERS AFTER ==="')
w("dump")
w("")

w('echo "=== VERDICT ==="')
w("# The verdict greps the log this run is being written to.  Passing the path as $1 lets the")
w("# caller redirect anywhere; if that file does not exist the check ABORTS rather than")
w("# reporting twelve MISSING, which is what it did on 2026-08-27 when the run was redirected")
w("# to one name while this line still said another.  A check that reads nothing must not be")
w("# able to print a verdict.")
w("L=${1:-/tmp/battery.log}")
w("if [ ! -f \"$L\" ]; then")
w("\techo \"ABORT: verdict log $L does not exist -- pass the log path as \\$1\"")
w("\texit 1")
w("fi")
w("bad=0")
w("want() {")
w("\tif grep \"$1\" $L > /dev/null 2>&1; then")
w("\t\techo \"  ok      $2\"")
w("\telse")
w("\t\techo \"  MISSING $2   (expected: $1)\"; bad=`expr $bad + 1`")
w("\tfi")
w("}")
for t, pat in TESTS:
    if pat:
        w('want "%s" %s' % (pat, t.split()[0]))
w("if [ $bad -eq 0 ]; then")
w("\techo \"BATTERY-RESULT PASS\"")
w("else")
w("\techo \"BATTERY-RESULT FAIL ($bad missing)\"")
w("fi")
w("")

w("# Must-stay-zero readings, taken from the device rather than from the log so that no pattern")
w("# in this file can match a line this file printed.  Addresses are spelled out because AMIX")
w("# `expr` cannot do hex arithmetic, and they carry a Z_ prefix so that no counter address can")
w("# collide with a block length above.")
for n in ZERO_A3W + [x for x, _ in READ_A3W] + ZERO_A3P + [x for x, _ in READ_A3P] + ['a3w_ran']:
    w("Z_%s=%08X" % (n.upper(), need(n)))
w("")
w("peek1() { $K $1 1 | sed \"s/.*= //;s/ .*//\"; }")
w("zbad=0")
w("iszero() {")
w("\tv=`peek1 $1`")
w("\tif [ \"$v\" != \"00000000\" ]; then")
w("\t\techo \"  NONZERO $2 = $v\"; zbad=`expr $zbad + 1`")
w("\telse")
w("\t\techo \"  zero    $2\"")
w("\tfi")
w("}")
w("")
w('echo "=== ISSUE-53 A3091 SOURCE CLASSIFIER ==="')
w("r=`peek1 $Z_A3W_RAN`")
w("if [ \"$r\" = \"41335752\" ]; then")
w("\techo \"  ran     a3w_ran = $r\"")
w("else")
w("\techo \"  NOT-RUN a3w_ran = $r, expected 41335752\"; zbad=`expr $zbad + 1`")
w("fi")
for n, why in READ_A3W:
    w('echo "  READING %-16s = `peek1 $Z_%s`   (%s)"' % (n, n.upper(), why))
for n in ZERO_A3W:
    w("iszero $Z_%-16s %s" % (n.upper(), n))
w("")
w('echo "=== ISSUE-54 STAGE D DRAIN ==="')
for n, why in READ_A3P:
    w('echo "  READING %-16s = `peek1 $Z_%s`   (%s)"' % (n, n.upper(), why))
for n in ZERO_A3P:
    w("iszero $Z_%-16s %s" % (n.upper(), n))
w("")
w("if [ $zbad -eq 0 ]; then")
w("\techo \"MUST-STAY-ZERO-OK\"")
w("else")
w("\techo \"MUST-STAY-ZERO-BAD ($zbad wrong)\"")
w("fi")

driver = "\n".join(o) + "\n"

# ---------------------------------------------------------------- check before printing
# Convert every emitted chk address back to a .data file offset and read the four bytes there.
# This is the same arithmetic status-facts used, deliberately: what is being checked is that the
# number in the generated file is the number the artifact carries, which is the step that used
# to be a copy by hand.
f = open(img, 'rb').read()
def u16(x): return struct.unpack('>H', f[x:x+2])[0]
def u32(x): return struct.unpack('>I', f[x:x+4])[0]
e_shoff, e_shentsize, e_shnum, e_shstrndx = u32(32), u16(46), u16(48), u16(50)
secs = []
for i in range(e_shnum):
    b = e_shoff + i * e_shentsize
    secs.append(dict(nameoff=u32(b), addr=u32(b + 12), off=u32(b + 16), size=u32(b + 20)))
shstr = secs[e_shstrndx]['off']
for s in secs:
    p = shstr + s['nameoff']; s['nm'] = f[p:f.index(b'\0', p)].decode('latin1')
data = next(s for s in secs if s['nm'] == '.data')

bad = 0
for line in driver.splitlines():
    m = re.match(r'^chk \$(\w+)\s+([0-9a-f]{8}) (\w+)_magic$', line)
    if not m:
        continue
    var, want, blk = m.group(1), m.group(2), m.group(3)
    am = re.search(r'^%s=([0-9A-F]{8})' % re.escape(var), driver, re.M)
    if not am:
        print('CHECK: %s has no address assignment' % var, file=sys.stderr); bad += 1; continue
    addr = int(am.group(1), 16)
    off = data['off'] + (addr - base - textsize) - data['addr']
    if not (0 <= off < len(f) - 4):
        print('CHECK: %s @ %08X is outside the file' % (blk, addr), file=sys.stderr); bad += 1; continue
    got = '%08x' % u32(off)
    if got != want:
        print('CHECK: %s @ %08X reads %s in the artifact, driver says %s'
              % (blk, addr, got, want), file=sys.stderr); bad += 1

if bad:
    print('ABORT: %d of %d magic lines do not match the artifact -- nothing emitted'
          % (bad, len(magics)), file=sys.stderr)
    sys.exit(1)
# Say what this proved and what it did not.  The check subtracts the same load base it was
# given, so a WRONG base cancels out of it entirely and still reports "all agree": what is
# verified is the transcription, not the base.  The base is proved on the guest, by the magic
# check in the driver itself, against the kernel that is actually running.
print('checked %d magic addresses against %s -- all agree (transcription only: a wrong '
      'load base cancels out here and is caught by the magic check on the guest)'
      % (len(magics), img), file=sys.stderr)
sys.stdout.write(driver)
PY
