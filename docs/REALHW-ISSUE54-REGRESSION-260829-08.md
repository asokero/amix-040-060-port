# Regression: the ISSUE-54 classifier costs nothing — `68060-260829-08`, 2026-08-29

`build/unix-040-quiet`, the serial-mirror twin, on the Amiga 3000 / Mercury 68060, after the
power cycle and `fsck` that the classification capture required. The question this answers is
narrow and was open: the classifier is new code in the **base** kernel, and it had only ever
been shown inert in the emulator. The one hardware run it had was a *provoked* one — a machine
being deliberately killed is not evidence about a healthy machine.

## The classifier never ran

```
a3p_magic   0810EAE0   41335021  "A3P!"
a3p_ran     0810EAE4   0
a3p_seen    0810EAE8   0
a3d_n       0810EA94   0          the driver never shut down
```

Addresses are the **quiet** image's, not the base image's: the serial-mirror unit shifts every
block, `a3p_magic` moving `0810EA74` → `0810EAE0`. The magic is what makes that safe to say.

## With a denominator large enough to mean something

`test-tools/burst4.sh` from the NAS (`hat_dup_cow` staged with it — ISSUE-50, still no source):
4 bursts × 6 concurrent 4 MiB copies, each burst overlapped with 64 rounds of fork/COW pressure.

```
                    before        after      delta
  dma_prep_to         2227        30881
  dma_prep_from       2618        15702
  dma_cmpl_to         2227        30881      == prep_to
  dma_cmpl_from       2618        15702      == prep_from
  dma_cmpl_count      4845        46583      +41738
```

`prep_to + prep_from == cmpl_to + cmpl_from == dma_cmpl_count` exactly, at both ends — 46583 on
each side after the run. **24/24 checksums `1570 8192`** and `ALLBURSTS-DONE`.

So the zeros above are earned: 41738 DMA events passed through the driver while the classifier
sat in it, and it neither fired nor cost a byte of integrity.

## What is still unverified, and it is the reason this kernel was booted

**The serial mirror has not been shown to work.** `/dev/ttyUSB0` is present on the build host
(the cable was attached at 11:08 today), the host is set to 9600 raw, which matches `serdbg.s`'s
`serper = 0x0174`, and a capture is running. Nothing has arrived.

The test that produced that nothing was invalid, not the port: it wrote to `/dev/console` from
userland, which goes through the tty driver and never reaches the kernel `conputc` that
`serdbg.s` overrides. The mirror covers the kernel's own `printf`, the banner and panics.

The valid test is the next clean boot, where the banner goes through the mirrored path. Until
that has been seen, a wedge capture on this kernel would still depend on photographing the
screen, which is what this boot was meant to end.

## Machine state

Healthy. Root filesystem checked after the earlier capture; NAS mounted at `/mnt/nasu`;
`/burst-260829.log` and six `/pressN.bin` left in place.
