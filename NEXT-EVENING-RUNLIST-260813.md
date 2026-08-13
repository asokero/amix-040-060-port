# Evening run-list — A3640, 2026-08-13

Two kernels, and they are not interchangeable. Every address below is generated for **load
base `0x07000000`** — the A3640 has no local RAM, so nothing from an earlier document applies.

## Kernel A — `build/unix-040`, build id `68040-260812-06`
Accepted today on this card. Use it for the burst suite.
```
 f60_magic  0710B8B4  46503630  FP60 
 fpc_magic  0710B29C  46504321  FPC! 
 i39_magic  0710B810  49333921  I39! 
 i40_magic  0710B848  49343021  I40! 
 isp61_magic  0710B260  49363121  I61! 
 kvp_magic  0710B2D0  4b565021  KVP! 
 ptd_magic  0710B87C  50544421  PTD! 
 segvn_prot_magic  0710B1F4  53564e21  SVN! 
 wbf_magic  0710B128  57424621  WBF! 
```

## Kernel B — `build/unix-040-rtg`, build id `68040-260813-01`  (BUILT TODAY)
Base + Xsvga (cdevsw 67) + VA2000 (cdevsw 68). **Required for wolf3d and X11** — the base
kernel has no RTG driver. Built explicitly from the accepted base, not from the `-dbg` slot:
that default is what produced the 2026-07-25 near-miss.
```
 f60_magic  071148E0  46503630  FP60 
 fpc_magic  071142C8  46504321  FPC! 
 isp61_magic  0711428C  49363121  I61! 
 segvn_prot_magic  07114220  53564e21  SVN! 
 wbf_magic  07114154  57424621  WBF! 
```
Devices: `mknod /dev/svga c 67 0` and `mknod /dev/va2000 c 68 0`.

## 1. Burst suite — kernel A

```
NAS amix/hwtest-260801/: burst4.sh, hat_dup_cow, and a 4 MiB /payload.bin
driver: test-tools/burstloop11.sh   (AMIX-grep-safe; the old one's anomaly line is inert)
  (nohup sh /tmp/burstloop11.sh 3 > /tmp/burstloop11.log 2>&1 &)
expect: 24 good sums per round, every anomaly count 0
```

**Pre-registered, and this is the interesting part:** every previous burst acceptance ran on a
Mercury card with **32 MiB**. This machine has **12.7 MiB** of `availrmem`. Six concurrent 4 MiB
copies plus `hat_dup_cow 64` is therefore a substantially heavier memory-pressure regime than the
suite has ever run in.

* If **ISSUE-39** (`hat_sdtalloc` out of contiguous memory) fires here, that is a **finding, not a
  regression** — it was characterised as fragmentation rather than pressure, and this is the first
  time the suite has run with half the RAM. Read `i39_fail_n` before concluding anything.
* If the sums come out clean, that is copyback + burst holding on a card whose memory topology
  differs from the one they were accepted on.

Read before and after: `i39` (fragmentation), `ptd` (teardown invariant), `wbf` (must stay 0 —
ordinary load never reaches the write-back denial path), `kvp`.

## 2. wolf3d and X11 — kernel B only

Requires the RTG kernel and the right board physically present. On the 68040 this is a *different*
test from the 68060 one: wolf3d's 68060 failure was vector 61 (`muls.l`), which a 68040 executes
in hardware, so `isp61_*` must stay at 0 throughout. What is under test here is the graphics path
plus ISSUE-37's misaligned-access handling.

Watch: `isp61` block stays 0, `segvn_prot` stays 0, `wbf` stays 0.

## 3. If time remains

* `hat_dup_cow 1 / 32 / 256` on its own — fork/COW at three widths.
* A second `protfault` run after the burst load, to show the ISSUE-42 path still behaves when the
  machine is not freshly booted.

## Not in this session

Anything requiring the 68060. The card is out; nothing 060-specific is measurable until it goes
back, and this run-list deliberately contains no 060 item.
