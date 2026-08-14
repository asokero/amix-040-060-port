#!/usr/bin/env python3
# patch_nfs_getpage.py -- ISSUE-36: the NFS read side's minimum safe four-site repair.
#
# THE DEFECT, PROVEN ON REAL HARDWARE 2026-07-27
# Touching a byte in the last PARTIAL page of an mmap'd NFS file raises SIGBUS.  read() of the
# same file is fine and the same length on local UFS is fine, so the RPC path works and the
# page-in path does not.  Evidence: test-tools/issue36-nfs-mmap-tail-sigbus-260727.txt, minimal
# repro test-tools/rdmin.c, KNOWN-ISSUES.md ISSUE-36.
#
# WHERE IT COMES FROM (Codex, docs/contracts/NFS-READSIDE-ISSUE36-SITE.md, c95fd8c)
# nfs_getpage's EOF allowance still adds the 2 KiB PAGEOFFSET:
#
#   0x8b6b6  movel %a2@(184),%d1     d1 = rp->r_size
#   0x8b6ba  addil #2047,%d1         + PAGEOFFSET   <-- stale
#   0x8b6c2  cmpl  %d0,%d1           d0 = off + len
#   0x8b6c4  bccw  0x8b72c           accept -> provider
#   0x8b726  moveq #14,%d0           else EFAULT
#
# With a one-page segvn fault (off = page-aligned, len = 4096) and r = file_size mod 4096, the old
# gate accepts only when 4096 <= r + 2047, i.e. r >= 2049.  So the exact predicate is:
#
#   r == 0          full final page        accepted
#   r in 1..2048    partial final page     REJECTED with EFAULT -> FC_MAKE_ERR(14) = 0xE05 -> SIGBUS
#   r in 2049..4095 partial final page     accepted
#
# That is sharper than our field observation and it corrects our own characterisation: we wrote
# "NFS mmap does not work for any non-multiple-of-4096 length".  The binary says upper-half
# remainders already work.  Both observed cases (+123) sit in the rejected range.  The acceptance
# test must therefore cover remainders 1, 2048, 2049 and 4095 -- 2048 and 2049 are the boundary
# and they are the two that tell this model apart from any other.
#
# WHY THE ONE-LINE FIX IS NOT SAFE ALONE -- two independent consequences of the same stale geometry
#
# 1. INCOMPLETE PAGE INITIALIZATION.  Converted pvn_kluster allocates roundup(123,4096) = 4096
#    bytes of page, but the provider's own primary round-up is still (123+2047)&~2047 = 2048, and
#    that becomes bp->b_bcount.  do_bio reads 123 bytes and zeroes only up to 2048, while pvn_done
#    advances its completion walk by 4096 and marks the whole page done.  Bytes 2048..4095 are
#    never initialized by that I/O, which violates the source's requirement that an EOF page-in
#    zero the entire page.  So the io_len add and mask must land WITH the EOF allowance.
#
# 2. PAGE-LIST RETURN CONTRACT.  The loop that fills the caller's pl[] is bounded ONLY by a
#    byte countdown, because SVR4 page_t cluster lists are CIRCULAR -- verified in the
#    disassembly, the loop stores the pointer before following p_next:
#
#      8b262  addqw #1,%a0@(2)          hold
#      8b266  movel %a0,%a2@+           pl[i++] = pp
#      8b268  moveal %a0@(16),%a0       pp = pp->p_next   (wraps around the ring)
#      8b26c  addil #-2048,%fp@(-20)    sz -= PAGESIZE    <-- stale: half a page
#      8b274  tstl %fp@(-20)
#      8b278  bgtw 8b262
#
#    With an 8 KiB cluster of two 4 KiB pages and sz = 8192 the old countdown emits
#    A, B, A, B, NULL where A, B, NULL is the contract.  Duplicate pointers, duplicate holds,
#    entries overwritten on a later iteration and unbalanced release ownership all follow.
#    Relaxing the EOF gate can NEWLY EXPOSE this on the second page of a partial NFS block, so
#    the countdown has to land in the same commit as the gate.
#
# THE MINIMUM SAFE ATOMIC UNIT IS THESE FOUR, AND HALF STATES ARE ALL INVALID
#   EOF alone                    -> admits a page whose upper half can stay uninitialized
#   EOF + io_len, no countdown   -> can admit a two-page cluster with a malformed return list
#   countdown/io_len without EOF -> does not repair the reported hard failure at all
# So this script verifies ALL FOUR before writing ANY, and refuses a partially applied image.
#
# THE OTHER NINE SITES ARE DELIBERATELY NOT TOUCHED and are asserted unchanged as canaries.
# They are genuine Model-B residuals but none produces this hard failure: read-ahead I/O geometry
# (0x8b406/0x8b40c -- real, but the last partial block cannot satisfy the read-ahead condition
# blkoff + bsize < r_size), statistics/accounting (0x8b360/0x8b366/0x8b46c/0x8b472), the
# resident-hit r_nextr advance (0x8b50c, read-ahead policy), the segkmap one-page-beyond-EOF
# synthesis (0x8b1c0, not an in-file user fault), and the direct-vs-pvn_getpages dispatch
# (0x8b72c).  0x8b72c must NEVER be converted without 0x8b26c: direct dispatch exposes the
# caller's larger page-list capacity to the stale countdown.  The canaries make that a build
# failure rather than a code review someone has to remember.
#
# ACCEPTANCE -- and "no SIGBUS" is NOT sufficient, for the same reason ISSUE-35 taught us
#   1. remainders 1, 2048 (rejected before) and 2049, 4095 (accepted before) all readable
#   2. the tail page's bytes past EOF must read as ZERO -- that is consequence 1 above, and a
#      test that only touches sz-1 cannot see it
#   3. content compared against server-derived truth, not against a same-client read
#   4. one NFS-resident ELF binary executed cold (Codex: 85 of 524 scanned vanilla binaries have
#      a PT_LOAD whose last mapped page begins within 2048 bytes of EOF, so exec reaches this
#      exact provider through nfs_map -> segvn_fault -> nfs_getpage)
# test-tools/nfstail.c + test-tools/nfstail-gen.py implement 1-3; nfselftest.sh implements 4.
#
# Idempotent; asserts old bytes; fails closed.  Usage:
#   python3 src/patch_nfs_getpage.py [kernel]              apply   (default build/unix-040)
#   python3 src/patch_nfs_getpage.py --revert <kernel>     un-apply, atomically
#
# WHY --revert EXISTS: Codex's acceptance item 1 requires the OLD body to be run first, so that
# remainders 1/2048 are seen to FAIL and 2049/4095 are seen to PASS.  That is the step that
# CONFIRMS OR REFUTES the boundary model, and without it a green run on the new kernel proves
# only that nothing is broken today -- not that we fixed what we think we fixed.  Reverting a
# copy of the very same build gives an A/B pair differing in exactly these four immediates plus
# the build id, so the comparison cannot be contaminated by anything else in the image.
# Re-stamp the reverted copy (src/stamp_buildid.py) so `uname -m` distinguishes them --
# two kernels with the same id in one hardware session is its own kind of bug.

import sys, os

args = [a for a in sys.argv[1:] if a != "--revert"]
REVERT = "--revert" in sys.argv[1:]
KERNEL = args[0] if args else "build/unix-040"
TEXT_OFF = 0x34

# (vaddr, old, new, name) -- ATOMIC: all four verified before any write
SITES = [
    (0x8b6ba, b"\x06\x81\x00\x00\x07\xff", b"\x06\x81\x00\x00\x0f\xff",
     "nfs_getpage:EOF allowance   rp->r_size + 2047 -> + 4095   (the direct SIGBUS producer)"),
    (0x8b26c, b"\x06\xae\xff\xff\xf8\x00\xff\xec", b"\x06\xae\xff\xff\xf0\x00\xff\xec",
     "nfs_getapage:pl[] countdown sz -= 2048 -> 4096            (return-list contract)"),
    (0x8b282, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff",
     "nfs_getapage:io_len round   + 2047 -> + 4095              (full-page initialization)"),
    (0x8b288, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00",
     "nfs_getapage:io_len mask    andiw #-2048 -> #-4096        (full-page initialization)"),
]

# (vaddr, expected_bytes, why) -- the remaining nine of the thirteen, NOT part of this fix
CANARIES = [
    (0x8b1c0, b"\x06\x80\xff\xff\xf8\x00", "segkmap one-page-beyond-EOF synthesis -- not an in-file user fault"),
    (0x8b360, b"\x06\x80\x00\x00\x07\xff", "primary statistics round add -- accounting only"),
    (0x8b366, b"\x7a\x0b",                 "primary statistics shift -- accounting only"),
    (0x8b406, b"\x06\x80\x00\x00\x07\xff", "async read-ahead I/O round add -- real residual, cannot produce ISSUE-36"),
    (0x8b40c, b"\x02\x40\xf8\x00",         "async read-ahead I/O mask -- ditto"),
    (0x8b46c, b"\x06\x80\x00\x00\x07\xff", "read-ahead statistics add -- accounting only"),
    (0x8b472, b"\x7a\x0b",                 "read-ahead statistics shift -- accounting only"),
    (0x8b50c, b"\x06\x85\x00\x00\x08\x00", "resident-hit r_nextr advance -- read-ahead policy"),
    (0x8b72c, b"\x0c\x84\x00\x00\x08\x00", "direct-vs-pvn_getpages dispatch -- MUST NOT convert without 0x8b26c"),
]


def main():
    if not os.path.isfile(KERNEL):
        raise SystemExit("ABORT: kernel not found: %s" % KERNEL)
    with open(KERNEL, "rb") as f:
        img = bytearray(f.read())

    if REVERT:
        # Same atomicity rule in reverse: all four or none.  A half-reverted image is one of the
        # known-bad half states, not a milder version of either endpoint.
        todo = []
        for va, old, new, name in SITES:
            off = va + TEXT_OFF
            got = bytes(img[off:off + len(new)])
            if got == old:
                print("  [skip]   @0x%05x already original  %s" % (va, name))
                continue
            if got != new:
                raise SystemExit("ABORT: @0x%x is %s, expected the converted %s (%s)\n"
                                 "       NOTHING was written." % (va, got.hex(), new.hex(), name))
            todo.append((off, va, new, old, name))
        for off, va, cur, orig, name in todo:
            img[off:off + len(orig)] = orig
            print("  [rev]    @0x%05x %s -> %s  %s" % (va, cur.hex(), orig.hex(), name))
        if todo:
            with open(KERNEL, "wb") as f:
                f.write(img)
        print("patch_nfs_getpage: REVERTED %d sites -> %s  (this image now has the ISSUE-36 bug\n"
              "                   ON PURPOSE, as the A/B control -- re-stamp its build id)"
              % (len(todo), KERNEL))
        return

    for va, want, why in CANARIES:
        off = va + TEXT_OFF
        got = bytes(img[off:off + len(want)])
        if got != want:
            raise SystemExit(
                "ABORT: canary @0x%x is %s, expected %s (%s)\n"
                "       Either this is not the image the four-site unit was derived against, or\n"
                "       one of the other nine sites has been converted.  If 0x8b72c in particular\n"
                "       was converted, direct dispatch now exposes the caller's page-list capacity\n"
                "       to the countdown and the minimum-unit reasoning must be redone."
                % (va, got.hex(), want.hex(), why))
        print("  [canary] @0x%05x %-16s unchanged -- %s" % (va, want.hex(), why))

    # ---- phase 1: verify ALL FOUR; write nothing (every half state is invalid) ----
    todo = []
    already = 0
    for va, old, new, name in SITES:
        off = va + TEXT_OFF
        got = bytes(img[off:off + len(old)])
        if got == new:
            print("  [skip]   @0x%05x already converted  %s" % (va, name))
            already += 1
            continue
        if got != old:
            raise SystemExit(
                "ABORT: @0x%x is %s, expected %s (%s)\n"
                "       NOTHING was written -- these four only make sense applied together."
                % (va, got.hex(), old.hex(), name))
        todo.append((off, va, old, new, name))

    if todo and already:
        raise SystemExit(
            "ABORT: the four-site unit is PARTIALLY applied (%d already, %d pending).\n"
            "       Every half state is a known-bad kernel: an EOF gate without the io_len pair\n"
            "       admits a page whose upper 2 KiB is uninitialized, and without the countdown\n"
            "       it can hand a malformed page list to segvn.  Restore the kernel and re-run."
            % (already, len(todo)))

    # ---- phase 2: all verified, now write ----
    for off, va, old, new, name in todo:
        img[off:off + len(new)] = new
        print("  [ok]     @0x%05x %s -> %s  %s" % (va, old.hex(), new.hex(), name))

    if todo:
        with open(KERNEL, "wb") as f:
            f.write(img)
    print("patch_nfs_getpage: %d patched, %d already, %d canaries intact (ISSUE-36) -> %s"
          % (len(todo), already, len(CANARIES), KERNEL))


if __name__ == "__main__":
    main()
