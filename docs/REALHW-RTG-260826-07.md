# RTG variant on hardware: `68060-260826-07` — 2026-08-26

The VA2000 kernel built from the LC060-merge base, so it carries everything the base does:
FPSP, the a3091 `badhardware` interposer, the LC060 FPU gates, plus the 26 VA2000 symbols.

**Artifact** `build/unix-040-va2000`, sha256
`95fe1204792b62f63b943b62419a6828bde1f56f2c5347571ee3f695108dc967`
**Loader identity** `image checksum = 0fc1fe21 (278597 longs)` — different from the base's
`0d8a0168`, as it must be.

`/dev/va2000` present as major 68. **The VA2000 is on Zorro III firmware**: `bootinfo` reports
`board[4] mfg=6d6e prod=01 addr=40000000 size=02000000`.

## Applications

X11 started and stopped, then wolf3d and Quake, all reported working by the operator.

## The structural evidence applications cannot give

Change D's cache-class census, read from the live kernel:

| | after X11 | after wolf3d + Quake |
|---|---|---|
| `cmf_fb_n` (framebuffer → `NC`) | 900 | **976** |
| `cmf_ncs_n` (registers → `NCS`) | 22 | **26** |

`cmf_magic` reads `434d4642` throughout, so the addresses are the right ones.

The shape is what the design predicts and what "it looked fine" cannot distinguish: the games
add framebuffer classifications and barely touch the register window. **An application would look
identical if the whole aperture were classified serialised** — only slower. This says the range
check separated them, on Zorro III.

## The interposer

`a3d_ran` stayed `0` through the whole graphics run. First graphics session with it armed.

## One finding, filed as ISSUE-52

After the games, `uptime` reports

    load average: -2854062.34, 6910653.78, 1705065.05

**frozen** — three reads five seconds apart gave identical figures, and `w` agrees. Every earlier
reading that day, on several kernels over hours, was `0.00, 0.00, 0.00`.

The clock itself is fine: `up N mins` advances. Nothing in the day's acceptance depends on the
load average — the power-cut precondition uses `uptime`'s duration, which read correctly.

Whether this is new is **unknown**: the 2026-08-19 acceptance ran the same three applications and
nobody read `uptime` afterwards. There is no baseline, and the issue says so rather than
implying the merge or the RTG driver caused it.
