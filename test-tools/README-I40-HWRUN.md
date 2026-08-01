# ISSUE-40 part 1 — hardware run sheet (2026-08-01)

Kernel `unix-040-260801-12`. This run is **diagnostic + safety**, not the acceptance battery:
the pre-registered ISSUE-40 criterion cannot pass with half the fix in, so 9/9 and burst 96/96
wait for the session where the `ptdat` half is also present.

## What is being asked

1. **Is the new edge safe on the real memory map?** It calls a retained stock body
   (`hat_growsdt` → `hat_sdtfree`) this port had never invoked, on every process exit.
2. **Does the real machine agree that it returns zero pages?** The emulator says
   `i40_pgfreed_n = 0`, `i40_held_n = 434`, residual `p_sdtbits = 0x7FFC0000`.
3. **How many `ptdat` crumbs pin a page on THIS machine?** `i40_last_bits` sizes the second half.

Predictions are pre-registered inside `issue40d.sh` so the run can fail.

## Steps

`/tmp` empties on every boot, so everything is compiled again. `/kpeek` and `/pgc` live in `/`
and survive. **Do not bundle mount + copy + compile into one command** — the native `cc`
outruns the driver's timeout and it sends `^C` mid-compile. Use `AMIX_CMD_TIMEOUT=900` for
compiles and run both scripts **detached**.

```sh
# 0. get unix-040-260801-12 onto the boot volume the usual way for this machine
#    (it is on the NAS as amix/hwtest-260801b/unix-040-260801-12, with
#    unix_boot040 and SHA256SUMS-260801b.txt beside it), then boot it:
#        unix_boot040 unix-040-260801-12          <- unix_boot040 is MANDATORY
#    Everything below assumes that kernel is running; the anchors prove it.

# 2. NAS (does not survive a boot)
mount -F nfs nasu:Public /mnt/nasu

# 3. copy (one command, no compile in it)
cp /mnt/nasu/amix/hwtest-260801b/*.c /mnt/nasu/amix/hwtest-260801b/*.sh /tmp/
cp /mnt/nasu/amix/hwtest-260801b/hat_dup_cow /tmp/
chmod +x /tmp/hat_dup_cow

# 4. compile, one at a time, AMIX_CMD_TIMEOUT=900
cd /tmp && cc -o leaktest leaktest.c
cd /tmp && cc -o kpoke kpoke.c
cd /tmp && cc -o exectest exectest.c
cd /tmp && cc -o devmaptest devmaptest.c
cd /tmp && cc -o kpeek kpeek.c        # only if / kpeek is missing; then use /tmp/kpeek

# 5. SAFETY first -- detached
nohup sh /tmp/i40regr.sh > /tmp/i40regr.log 2>&1 &
#    ... then read /tmp/i40regr.log

# 6. MEASUREMENT -- detached, ~15-20 min with the settling sleeps
nohup sh /tmp/issue40d.sh > /tmp/i40d.log 2>&1 &
#    ... then read /tmp/i40d.log
```

Both scripts refuse to run unless `i40_magic` reads `49343021` and (for `issue40d.sh`)
`i39_magic` reads `49333921`. That guard is the whole reason the addresses can be trusted:
they are `0x08000000 + textsize(0xe46ec) + nm(.data)` for **this image only**.

## Address table — `unix-040-260801-12` ONLY

| symbol | address | expected |
|---|---|---|
| `i40_magic` | `0x080FD138` | `49343021` (anchor) |
| `i40_on` | `0x080FD13C` | `1` (A/B gate) |
| `i40_calls` | `0x080FD140` | teardowns reaching the edge |
| `i40_sec2_n` | `0x080FD144` | section-2 objects released |
| `i40_sec3_n` | `0x080FD148` | section-3 objects released |
| `i40_empty_n` | `0x080FD14C` | sections with nothing allocated |
| `i40_bad_n` | `0x080FD150` | **must be 0** |
| `i40_err_n` | `0x080FD154` | **must be 0** |
| `i40_pgfreed_n` | `0x080FD158` | pages actually returned |
| `i40_held_n` | `0x080FD15C` | releases that returned nothing |
| `i40_last_n` | `0x080FD160` | units of the last object |
| `i40_last_base` | `0x080FD164` | its physical base |
| `i40_last_bits` | `0x080FD168` | residual `p_sdtbits` |
| `i39_magic` | `0x080FD100` | `49333921` (anchor) |
| `i39_availrmem_p` | `0x080FD108` | **pointer** — read it, then read what it points at |
| `i39_availsmem_p` | `0x080FD10C` | **pointer** |
| `pages_pp_kernel` | `0x080EFC14` | plain `.data`, direct |
| `hat_pfnmiss_n` | `0x080FD0D0` | +2 per `devmaptest`, nothing else |
| `hat_badaslot_n` | `0x080FD0D4` | should be far below the old ~499/boot |
| `hat_sdtfail_n` | `0x080FD0D8` | ISSUE-39 counter |
| `cb_rel_reject` | `0x080FD0B8` | must stay 0 |
| `hat_cm_ram` | `0x080FC9EC` | `0x00000020` (copyback) |

`i40_magic .. i40_last_bits` are 13 contiguous longs, so `kpeek 080FD138 13` reads the lot.

All `kpeek` output is **hex**.

## If something goes wrong

* `i40_bad_n > 0` — the shape guard rejected a descriptor. Stop and report the number: it means
  sections 2/3 alias something real on this memory map and the contract's "A4..A7 are never
  native" argument does not hold here. The guard turned that into a skipped free instead of a
  freed live pointer table, which is the whole reason it exists.
* A panic in teardown — boot `unix-040-260801-04` (previous NAS dir) to confirm it is ours, then
  the same image with `i40_on` poked to 0 at the boot prompt is not possible; use `-04`.
* `i40_pgfreed_n > 0` — the emulator's story does not hold here and the `ptdat` scoping needs
  rechecking before Codex answers.
