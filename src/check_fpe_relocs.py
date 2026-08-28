#!/usr/bin/env python3
# check_fpe_relocs.py -- the soft-FPU lane's relink assertions, run on the finished kernel
# (2026-08-26).  The FPE counterpart of src/check_fpu_relocs.py, which stays exactly as it is:
# that one guards the Tier-1 FP-state surface, this one guards what the emulator adds on top.
#
# Every check here is something that would otherwise be a silent wrong answer rather than a
# build failure, which is the only kind of check worth the line:
#
#   1. fpu_present is STILL a plain global object.  Frozen decision 9 keeps it meaning "real
#      silicon" and this lane must never write it.  If some future arm did, the whole
#      never-engage regression bar (fpe_entry_n == 0 wherever an FPU exists) evaporates.
#   2. fpu_emul exists, is a global object, and is NOT fpu_present.  Two flags, two meanings.
#   3. fpu_ptr still relocates to u + 0x9c.  src/fpe_glue.c hands the emulator a struct
#      fpframe pointer computed as a fixed bias off it; if fpu_ptr moved, the emulator would
#      write eight FP registers somewhere else in the u-area and nothing would say so.
#   4. M68Kvec[11] names fpe_vec11 -- the arm is actually installed.
#   5. fpe_decline names the handler the arm displaced, and in particular does NOT name
#      fpe_vec11.  A decline that loops back into the arm is an unbreakable loop on the very
#      first bad F-line word in the system.
#   6. init_tbl still carries exactly one relocation to fpuinit, which is the only thing that
#      arms the lane.
#   7. fpe_sigpend reads u + 0x730 and nothing else.  That is u.u_procp, the pointer u_trap
#      itself works from, and the three proc fields the gate then tests are what decide whether
#      issig() is called at all.  A wrong base here is a gate that silently never fires, and
#      round 3 measured what that costs: a pure-FP loop that cannot be killed.
#   8. M68Kvec[60] names fpe_vec60 -- the round-10 arm is actually installed.  Without it the
#      two twelve-byte immediate formats keep taking the 68060 package's FPU-disabled exit and
#      dying SIGSYS, which is the failure that round measured and no fpe_* counter recorded.
#   9. fpe_decline60 names the handler THAT arm displaced, and in particular does NOT name
#      fpe_vec60 or fpe_vec11.  Naming fpe_vec60 is a loop on the first declined frame; naming
#      fpe_vec11 is the loop docs/contracts/FPE-R10-VEC60.md 4 rejects the obvious fix for --
#      fpe_vec11's own decline reaches the 68060 package, which calls back out to exactly the
#      path that would return here.
#
# Usage: python3 src/check_fpe_relocs.py <kernel>

import struct, sys

R_68K_32 = 1
U_FPU_INFO = 0x9c
U_PROCP = 0x730
ALLOWED_DECLINE = ("fpsp_vec11", "nullvect")
ALLOWED_DECLINE60 = ("fpsp_vec60", "nullvect")


def u16(b, o): return struct.unpack(">H", b[o:o + 2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o + 4])[0]


def main():
    path = sys.argv[1]
    b = open(path, "rb").read()
    e_shoff = u32(b, 32); e_shentsize = u16(b, 46)
    e_shnum = u16(b, 48); e_shstrndx = u16(b, 50)
    sh = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        sh.append(dict(name=u32(b, o), offset=u32(b, o + 16), size=u32(b, o + 20),
                       link=u32(b, o + 24), entsize=u32(b, o + 36)))
    shstr = sh[e_shstrndx]["offset"]

    def nm(s):
        e = b.index(b"\0", shstr + s["name"]); return b[shstr + s["name"]:e].decode()

    byname = {nm(s): s for s in sh}
    symtab = byname[".symtab"]; strtab = sh[symtab["link"]]
    so, se = symtab["offset"], symtab["entsize"]
    sn = symtab["size"] // se
    stroff = strtab["offset"]

    def symname(i):
        n = u32(b, so + i * se); e = b.index(b"\0", stroff + n)
        return b[stroff + n:e].decode()

    syms = {}
    for i in range(sn):
        o = so + i * se
        syms.setdefault(symname(i), (u32(b, o + 4), b[o + 12], u16(b, o + 14)))

    def relocs(sec):
        s = byname[sec]
        n = s["size"] // s["entsize"]
        out = {}
        for i in range(n):
            o = s["offset"] + i * s["entsize"]
            info = u32(b, o + 4)
            addend = struct.unpack(">i", b[o + 8:o + 12])[0]
            out.setdefault(u32(b, o), []).append((symname(info >> 8), info & 0xff, addend))
        return out

    rtext = relocs(".rela.text")
    rdata = relocs(".rela.data")
    fails = []

    # 1 + 2: the two flags
    for name in ("fpu_present", "fpu_emul"):
        s = syms.get(name)
        if not s:
            fails.append("%s not found" % name)
        elif s[1] != 0x11:
            fails.append("%s st_info is 0x%02x, expected 0x11 (global object)" % (name, s[1]))
        else:
            print("      %-12s global object at 0x%08x" % (name, s[0]))
    if "fpu_present" in syms and "fpu_emul" in syms:
        if syms["fpu_present"][0] == syms["fpu_emul"][0]:
            fails.append("fpu_present and fpu_emul are the SAME object -- decision 9 keeps "
                         "fpu_present meaning real silicon and nothing else")

    # 3: the FP state pointer has not moved
    if "fpu_ptr" not in syms:
        fails.append("fpu_ptr not found")
    else:
        s = byname[".rela.data"]
        n = s["size"] // s["entsize"]
        found = None
        for i in range(n):
            o = s["offset"] + i * s["entsize"]
            if u32(b, o) == syms["fpu_ptr"][0]:
                info = u32(b, o + 4)
                found = (symname(info >> 8), struct.unpack(">i", b[o + 8:o + 12])[0])
                break
        if found != ("u", U_FPU_INFO):
            fails.append("fpu_ptr initializer is %s, expected u + 0x%x" % (found, U_FPU_INFO))
        else:
            print("      fpu_ptr      -> u + 0x%02x (fpu_info, unmoved)" % U_FPU_INFO)

    # 4: the vector
    if "M68Kvec" not in syms or "fpe_vec11" not in syms:
        fails.append("M68Kvec or fpe_vec11 not found")
    else:
        off = syms["M68Kvec"][0] + 11 * 4
        got = rtext.get(off)
        if not got:
            fails.append("no .rela.text reloc at M68Kvec[11] 0x%06x" % off)
        elif got[0][0] != "fpe_vec11":
            fails.append("M68Kvec[11] names %s, expected fpe_vec11" % got[0][0])
        elif got[0][1] != R_68K_32:
            fails.append("M68Kvec[11] reloc type %d != R_68K_32" % got[0][1])
        else:
            print("      M68Kvec[11]  -> fpe_vec11 (the arm is installed)")

    # 5: the decline
    if "fpe_decline" not in syms:
        fails.append("fpe_decline not found")
    else:
        base = syms["fpe_decline"][0]
        hit = [rtext[o] for o in rtext if base <= o < base + 6]
        if len(hit) != 1:
            fails.append("fpe_decline carries %d relocations, expected exactly 1 "
                         "(one jmp with a patchable operand)" % len(hit))
        else:
            tgt = hit[0][0][0]
            if tgt == "fpe_vec11":
                fails.append("fpe_decline names fpe_vec11 -- the decline path loops back "
                             "into the arm")
            elif tgt not in ALLOWED_DECLINE:
                fails.append("fpe_decline names %s, expected one of %s"
                             % (tgt, "/".join(ALLOWED_DECLINE)))
            else:
                print("      fpe_decline  -> %s (the displaced handler)" % tgt)

    # 6: the one arming site
    if "init_tbl" not in syms:
        fails.append("init_tbl not found")
    else:
        it = syms["init_tbl"][0]
        hits = [o for o, rs in rdata.items() for r in rs if r[0] == "fpuinit" and o == it]
        others = [o for o, rs in rdata.items() for r in rs if r[0] == "fpuinit" and o != it]
        if len(hits) != 1:
            fails.append("init_tbl+0 has %d relocations to fpuinit, expected 1" % len(hits))
        elif others:
            fails.append("fpuinit is also reached from .data offsets %s"
                         % ["0x%x" % o for o in others])
        else:
            print("      init_tbl+0   -> fpuinit (the only place the lane arms)")

    # 7: the signal gate's base.  fpe_sigpend's ONLY relocation must be u + U_PROCP.
    if "fpe_sigpend" not in syms:
        fails.append("fpe_sigpend not found -- the success path has no signal gate")
    else:
        base = syms["fpe_sigpend"][0]
        hit = [(o, rtext[o]) for o in rtext if base <= o < base + 6]
        if len(hit) != 1:
            fails.append("fpe_sigpend carries %d relocations, expected exactly 1 "
                         "(the u.u_procp load)" % len(hit))
        else:
            tgt, _typ, addend = hit[0][1][0]
            if (tgt, addend) != ("u", U_PROCP):
                fails.append("fpe_sigpend reads %s + 0x%x, expected u + 0x%x (u.u_procp)"
                             % (tgt, addend, U_PROCP))
            else:
                print("      fpe_sigpend  -> u + 0x%03x (u.u_procp, u_trap's own gate base)"
                      % U_PROCP)

    # 8: the round-10 vector, same two checks the vector-11 pair gets
    if "M68Kvec" not in syms or "fpe_vec60" not in syms:
        fails.append("M68Kvec or fpe_vec60 not found")
    else:
        off = syms["M68Kvec"][0] + 60 * 4
        got = rtext.get(off)
        if not got:
            fails.append("no .rela.text reloc at M68Kvec[60] 0x%06x" % off)
        elif got[0][0] != "fpe_vec60":
            fails.append("M68Kvec[60] names %s, expected fpe_vec60" % got[0][0])
        elif got[0][1] != R_68K_32:
            fails.append("M68Kvec[60] reloc type %d != R_68K_32" % got[0][1])
        else:
            print("      M68Kvec[60]  -> fpe_vec60 (the unimplemented-<ea> arm is installed)")

    # 9: and its decline, which may not name either arm
    if "fpe_decline60" not in syms:
        fails.append("fpe_decline60 not found")
    else:
        base = syms["fpe_decline60"][0]
        hit = [rtext[o] for o in rtext if base <= o < base + 6]
        if len(hit) != 1:
            fails.append("fpe_decline60 carries %d relocations, expected exactly 1 "
                         "(one jmp with a patchable operand)" % len(hit))
        else:
            tgt = hit[0][0][0]
            if tgt in ("fpe_vec60", "fpe_vec11"):
                fails.append("fpe_decline60 names %s -- the decline path loops back into an "
                             "arm" % tgt)
            elif tgt not in ALLOWED_DECLINE60:
                fails.append("fpe_decline60 names %s, expected one of %s"
                             % (tgt, "/".join(ALLOWED_DECLINE60)))
            else:
                print("      fpe_decline60-> %s (the displaced handler)" % tgt)

    if fails:
        for f in fails:
            print("[FAIL] %s" % f)
        sys.exit(1)
    print("FPE relink assertions pass")


main()
