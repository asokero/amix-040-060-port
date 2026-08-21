#!/bin/sh
# status-facts.sh -- print the VOLATILE facts of the current tree and kernel artifact, in a
# form that pastes straight into STATUS.md.
#
# WHY THIS EXISTS.  Every number that identifies a build changes on every build: the build id,
# the sha256, the text size, and -- the one that has cost this project real time more than once
# -- every counter address, because they are `0x08000000 + textsize + nm(.data offset)`.  A
# status document that carries those numbers by hand is wrong the day after it is written, and
# a stale counter address does not fail loudly: it returns a plausible number from whatever now
# lives there.  So STATUS.md carries the JUDGEMENT and this script carries the FACTS.
#
# The magic words are not hard-coded here either.  They are read out of the artifact's own
# .data, so "what the counter block must read at runtime" always comes from the thing that will
# actually be booted.
#
# usage:  sh tools/status-facts.sh [kernel-image] [load-base]
#           sh tools/status-facts.sh                        build/unix-040 at 0x08000000
#           sh tools/status-facts.sh build/unix-040-rtg
#           sh tools/status-facts.sh build/unix-040 0x07000000
#
# THE LOAD BASE IS NOT ALWAYS 0x08000000.  Counter addresses are `load_base + textsize +
# nm(.data)`, and the loader binds the kernel into the LARGEST non-chip memory region it finds
# (unix_boot/src/bind.c).  Every machine this project has used so far had an accelerator with its
# own RAM at 0x08000000, so that base has been constant -- but an A3640 has no local memory and
# runs from the A3000 motherboard RAM at 0x07000000.  On such a machine every address this script
# prints would be wrong by 16 MiB unless the base is passed.
#
# Take the base from the loader's own boot output rather than from an assumption:
#     kernel: entry=08000000 tvaddr=08000000 tsize=000f2910 ...
#                            ^^^^^^^^ this is the load base
#
# Requires the cross binutils on PATH:
#         export PATH=$AMIX_CROSS/bin:$PATH
set -e

HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$(cd "$(dirname "$0")" && pwd)/config-load.sh"
IMG="${1:-$HERE/build/unix-040}"
BASE="${2:-0x08000000}"
NM=m68k-linux-gnu-nm
SIZE=m68k-linux-gnu-size

command -v $NM >/dev/null 2>&1 || {
	echo "ERROR: $NM not on PATH -- export PATH=$AMIX_CROSS/bin:\$PATH"; exit 1; }
[ -f "$IMG" ] || { echo "ERROR: kernel image not found: $IMG"; exit 1; }

cd "$HERE"

echo "# status facts -- generated $(date +%Y-%m-%d\ %H:%M) by tools/status-facts.sh"
echo

# ---------------------------------------------------------------- repository
echo "## Repository"
echo
echo '```'
printf "commit    %s\n" "$(git rev-parse HEAD 2>/dev/null || echo '(not a git tree)')"
printf "date      %s\n" "$(git log -1 --format=%ad --date=short 2>/dev/null || echo '?')"
printf "branch    %s\n" "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
	printf "worktree  DIRTY -- the facts below do not correspond to any commit\n"
	git status --porcelain | sed 's/^/          /'
else
	printf "worktree  clean\n"
fi
printf "tags      %s\n" "$(git tag --points-at HEAD 2>/dev/null | tr '\n' ' ')"
echo '```'
echo

# ---------------------------------------------------------------- artifact
BID=$(strings -a "$IMG" | grep -oE '6806?0-[0-9]{6}-[0-9]{2}' | head -1 || true)
[ -n "$BID" ] || BID=$(strings -a "$IMG" | grep -oE '68040-[0-9]{6}-[0-9]{2}' | head -1 || true)
SHA=$(sha256sum "$IMG" | cut -d' ' -f1)
TEXT=$($SIZE "$IMG" | awk 'NR==2{print $1}')
DATA=$($SIZE "$IMG" | awk 'NR==2{print $2}')
BSS=$($SIZE "$IMG" | awk 'NR==2{print $3}')

echo "## Artifact"
echo
echo '```'
printf "image     %s\n" "$IMG"
printf "build id  %s   (the banner shows 68060- on a 060: that is the CPU, not the image)\n" "${BID:-UNSTAMPED}"
printf "sha256    %s\n" "$SHA"
printf "text      %s (0x%x)   data %s   bss %s\n" "$TEXT" "$TEXT" "$DATA" "$BSS"
printf "loader    unix_boot040 is MANDATORY (PC-rel reloc fix, amix-unix-boot v1.0-040-060)\n"
printf "load base %s   <- addresses below assume this; read tvaddr from the boot output\n" "$BASE"
echo '```'
echo

# ------------------------------------------------- magics, counters, bindings
# The ELF work is one python block: it needs the symbol table, the section headers and the
# .data bytes at once, and doing that in sh with readelf+od is where transcription errors live.
python3 - "$IMG" "$TEXT" "$BASE" <<'PY'
import struct, subprocess, sys

img, textsize = sys.argv[1], int(sys.argv[2])
BASE = int(sys.argv[3], 0)               # load base: where the loader bound the kernel

f = open(img, 'rb').read()
def u16(o): return struct.unpack('>H', f[o:o+2])[0]
def u32(o): return struct.unpack('>I', f[o:o+4])[0]

e_shoff, e_shentsize, e_shnum, e_shstrndx = u32(32), u16(46), u16(48), u16(50)
secs = []
for i in range(e_shnum):
    b = e_shoff + i*e_shentsize
    secs.append(dict(name=u32(b), type=u32(b+4), flags=u32(b+8), addr=u32(b+12),
                     off=u32(b+16), size=u32(b+20)))
shstr = secs[e_shstrndx]['off']
for s in secs:
    o = shstr + s['name']; s['nm'] = f[o:f.index(b'\0', o)].decode('latin1')
data = next((s for s in secs if s['nm'] == '.data'), None)

syms = {}
out = subprocess.run(['m68k-linux-gnu-nm', img], capture_output=True, text=True).stdout
for line in out.splitlines():
    p = line.split()
    if len(p) == 3:
        syms.setdefault(p[2], []).append((int(p[0], 16), p[1]))

def one(name, kinds=None):
    for v, t in syms.get(name, []):
        if kinds is None or t in kinds:
            return v, t
    return None, None

# ---- runtime counter blocks, keyed by their magic word -------------------------------------
print("## Counter blocks (runtime addresses = load base 0x%08X + textsize + nm .data offset)" % BASE)
print()
print("Read the magic FIRST. If it does not match, every other reading from that block is noise")
print("-- a stale address returns a plausible number instead of failing.")
print()
print("| block | runtime address | magic must read | ASCII |")
print("|---|---:|---|---|")
for name in sorted(n for n in syms if n.endswith('_magic')):
    val, typ = one(name, 'DdBb')
    if val is None or data is None:
        continue
    addr = BASE + textsize + val
    off = data['off'] + (val - data['addr'])
    magic = u32(off) if 0 <= off < len(f) - 4 else 0
    asc = ''.join(chr(b) if 32 <= b < 127 else '.' for b in struct.pack('>I', magic))
    print("| `%s` | `%08X` | `%08x` | `%s` |" % (name, addr, magic, asc))
print()

# ---- every counter block, in order, so a reader can kpeek each in one call ------------------
# Driven by the *_magic symbols rather than a hand-kept list: a block that gains a counter, or
# a new block entirely, appears here without anyone remembering to add it.
for block in sorted(n[:-6] for n in syms if n.endswith('_magic')):
    members = []
    for n, entries in syms.items():
        for v, t in entries:
            if t in 'DdBb' and n.startswith(block + '_'):
                members.append((v, n))
    if len(members) < 2:
        continue
    members.sort()
    base = members[0][0]
    contiguous = all(members[i+1][0] - members[i][0] == 4 for i in range(len(members)-1))
    print("**`%s` block** — %s:" % (block,
          "`kpeek %08X %d` reads it in one call, in this order" % (BASE + textsize + base, len(members))
          if contiguous else "NOT contiguous, so read the addresses individually"))
    print()
    print('```')
    for i, (v, n) in enumerate(members):
        print("  +%-5s %-20s @ %08X" % ("0x%x" % (v - base), n, BASE + textsize + v))
    print('```')
    print()

# ---- override bindings ---------------------------------------------------------------------
# Each entry: symbol, the STOCK address it must have moved off, and whether an *_orig alias
# must still point at that stock body.  These are the overrides whose silent absence would
# produce a kernel that looks built and behaves like stock.
OVERRIDES = [
    # symbol,          stock addr, retained-alias name (or None), why it matters
    ("resume",           0x0009c, None,                  "native fixed-u remap -- stock cannot context-switch"),
    ("hardbus",          0x5b3c2, "hardbus_orig",        "crossing-page reads loop forever in stock"),
    ("copyout",          0x00576, "copyout_orig",        "ISSUE-38: icode never published to RAM under copyback"),
    ("fpu_save",         0x00132, "fpu_save_orig",       "ISSUE-43: 68060 frame discriminator is at frame+2"),
    ("fpu_restore",      0x00158, "fpu_restore_orig",    "ISSUE-43"),
    ("fpu_setup",        0x19b50, "fpu_setup_orig",      "ISSUE-43: full 12-byte 060 reset frame"),
    ("vtop",             0xb7568, "vtop_orig",           "040 page-table walker"),
    ("mprotect",         0x58550, "mprotect_orig",       "ISSUE-41 / XPAGE"),
    ("segvn_faultpage",  0xac01a, "segvn_faultpage_orig","ISSUE-41: per-page permission check"),
    ("krnxmemflt",       0x5b140, "krnxmemflt_stock",    "native 040 kernel fault resolver (krnxmemflt_orig binds to OURS on purpose)"),
    ("usrxmemflt",       0x5aede, "usrxmemflt_orig",     "040 user fault path"),
    ("nullvect",         0x011b4, "nullvect_orig",       "kvecprobe wrapper"),
    ("sync",             0x5d21a, None,                  "ISSUE-46: stock sync() walks a NULL vsw_vfsops -- any pre-vfsinit panic double-faults"),
    ("page_init",        0xaf42a, "page_init_orig",      "ISSUE-48: the page-frame database is mapped-in DRAM and nothing zeroes it"),
    ("setregs",          0x58b62, "setregs_orig",        "ISSUE-52: measure the USP handoff at the moment setregs writes it"),
]
print("## Override bindings")
print()
print("Both directions are checked: the strong symbol must have MOVED OFF the stock address,")
print("and where an `*_orig` alias exists it must still point AT it (the CPU-gated 040 paths")
print("tail-jump there).  `ld -r` does not fail when an override definition is missing -- it")
print("leaves the stock body strong and links cleanly -- so this table, not the build's exit")
print("status, is what says the override actually took.")
print()
print("| symbol | stock | strong def | retained alias | verdict |")
print("|---|---:|---:|---|---|")
bad = 0
for name, stock, alias, why in OVERRIDES:
    v, t = one(name, 'Tt')
    ov, _ = one(alias) if alias else (None, None)
    ok = v is not None and v != stock
    if alias:
        ok = ok and ov == stock
    bad += 0 if ok else 1
    print("| `%s` | `%05x` | %s | %s | %s |" % (
        name, stock,
        ("`%08x`" % v) if v is not None else "**MISSING**",
        ("—" if not alias else
         ("`%s`=`%08x`" % (alias, ov)) if ov is not None else "**%s MISSING**" % alias),
        "ok" if ok else "**CHECK**"))
print()
print("bindings failing: **%d**" % bad)
print()

# ---- FPSP / package presence ---------------------------------------------------------------
print("## Support packages linked")
print()
print('```')
for s in ("fpsp_vec11", "fpsp060_vec11", "fpsp060_top", "fpsp_fline", "isp61_vec", "cputype"):
    v, t = one(s)
    print("  %-16s %s" % (s, ("%08x %s" % (v, t)) if v is not None else "ABSENT"))
print('```')

# Exit non-zero when a binding failed.  Until 2026-08-17 this script printed "bindings failing: N"
# and exited 0 regardless, so a caller that trusted the exit status was told nothing -- the same
# shape as ISSUE-45, in the tool whose whole job is to say whether the overrides took.
sys.exit(1 if bad else 0)
PY
