# Capturing the full AMIX boot log over the Amiga serial port

The AMIX kernel console renders to the native Amiga display, which **wraps after ~40
lines**. A full boot (banner → root mount → daemons → scheduler) exceeds that, so
screenshots can never show the whole boot, and post-scheduler output is lost. This
makes debugging the 040 port (where the boot diverges late) very painful.

**Solution: mirror every console character to the Amiga serial port, and capture that
byte stream on the host to a file.** You then read the complete boot log as text — no
wrap, no scroll, no guessing. This works under fs-uae (and WinUAE) with no extra
hardware.

This was built for the 68040 port but is useful for **anyone** debugging AMIX / Amiga
Unix boot behaviour.

---

## 1. Kernel side — `src/serdbg.s` (a `conputc` hook)

### The key insight (don't hook `putchar`!)

AMIX console output does **not** funnel through `putchar`. The real path is:

```
printf / cmn_err  ->  message buffer + SVR4 STREAMS console-log  ->  (*conputc)(c)  ->  coputc()  -> screen
```

- `conputc` (`amiga/kernel/support.c`, a `void (*)()` pointer, statically initialised
  `conputc = coputc`) is the single funnel that **everything** visible goes through —
  the banner, every `cmn_err`/`printf`, the STREAMS log drain, and `putchar`.
- `coputc` (`amiga/console/c0.c`, global `T`) is the actual screen-rendering routine.
- `putchar` (`support.c`) is only **one** caller of `(*conputc)` (used for synchronous,
  high-IPL output such as a marker printed from inside `swtch`/idle). **Hooking
  `putchar` captures only that synchronous trickle — NOT the banner or buffered output.**
  (We learned this the hard way: a `putchar` hook produced a log with only the idle
  marker in it.)

So: **hook `conputc`**, not `putchar`.

### How `serdbg.s` works

`serdbg.s` provides a strong `conputc = serdbg_putc` (overriding the kernel's via
`--weaken-symbol conputc`). `serdbg_putc(c)`:

1. one-shot: set `serper` (`0xDFF032`) to a 9600-baud divisor (`DATA8(0)|0x174`) so the
   emulated UART actually emits;
2. write `STOPBIT(0x100) | c` to `serdat` (`0xDFF030`) — **unconditionally** (write
   first; do NOT gate on `TBE` — some emulator serial states never set it and you'd drop
   every byte);
3. a **bounded** busy-wait on `serdatr & TBE (0x2000)` to pace the next char without
   hanging if `TBE` never sets;
4. call the real `coputc(c)` so the screen still works.

Custom-chip registers used (base `0xDFF000`): `serdatr @+0x18` (read; `TBE`=transmit
ready), `serdat @+0x30` (write), `serper @+0x32` (baud).

### Building it in

It is added by `relink-040-dbg.sh`:

```sh
m68k-cbm-sysv4-gcc -m68040 -c src/serdbg.s -o build/serdbg.o
# ... objcopy --weaken-symbol conputc ... on the kernel stage ...
m68k-cbm-sysv4-ld -r -o build/unix-040-dbg ... build/serdbg.o
```

`coputc` is global `T`, so `serdbg.o`'s `jsr coputc` binds directly. Verify after the
relink: `nm build/unix-040-dbg | grep conputc` should show a single `D conputc` whose
`.data` reloc points at `serdbg_putc` (not `coputc`).

---

## 2. fs-uae side — route the serial port to a host PTY and log it

fs-uae's `serial_port` accepts a device path or `tcp://host:port`. The PTY method (see
fs-uae issue #78) is the most reliable on Linux:

**In the fs-uae config** (e.g. `~/Documents/FS-UAE/Configurations/a3000ux.fs-uae`):

```
serial_port = /tmp/vser
```

**On the host, before launching fs-uae**, create the PTY and log the byte stream:

```sh
socat pty,raw,echo=0,link=/tmp/vser - | tee /tmp/amix-boot.log
```

`socat` makes `/tmp/vser` a PTY (which fs-uae opens as the Amiga serial port) and copies
everything the Amiga transmits to stdout; `tee` saves it to `/tmp/amix-boot.log` while
showing it live.

> Note the byte stream is **raw** — the Amiga emits LF without CR, so a live terminal
> shows a "staircase". That's cosmetic; the **file** is clean. Always read the FILE, not
> the scrolling terminal.

Then boot the kernel from the Amiga CLI (`unix_boot040 unix-040-dbg`), let it run to
where it hangs/idles, stop `socat` (Ctrl-C), and read `/tmp/amix-boot.log`.

### Sanity-checking the path independent of the kernel

If the log is empty, isolate the layers:

- **fs-uae log** (`~/Documents/FS-UAE/Cache/Logs/fs-uae.log.txt`) should show
  `amiga_enable_serial_port` / `serial port device: /tmp/vser`.
- **From AmigaOS** (the Shell that runs `unix_boot`), `echo >SER: "TEST"` should appear
  in the capture — that proves the fs-uae↔socat path works, decoupled from the kernel.

---

## 3. Result

With the `conputc` hook + this fs-uae setup, `/tmp/amix-boot.log` contains the **entire**
boot, banner included, as plain text. Example (baseline 040 build, scheduler-spin probe):

```
UNIX(R) System V Release 4.0 AT&T Amiga (Unlicensed) Version 2.1c 0800430
... Copyright lines ...
WARNING: DBG ... (markers) ...
WARNING: DBG sched ENTRY maxrunpri=4F
```

If a build's log is **missing** output that appears in the baseline, that absence is real
(not a capture artifact) — i.e. the boot genuinely isn't producing it. That alone is a
strong diagnostic for "how far does this build actually get?".
