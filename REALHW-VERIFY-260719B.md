# Real-HW-040-verifypaketti B (koottu 2026-07-19 ilta — Model-B-jäännösryhmät)

Delta edelliseen (REALHW-VERIFY-260719.md, ajettu ja hyväksytty HW:lla 260719-01/-02):
tämä paketti verifioi NELJÄ uutta Model-B-ryhmää (commitit 1475e16 / 7f8ac6e / 7f36144 /
9c4139c) + jatkaa ISSUE-22-jahtia. Emu-hyväksyntä puhdas per ryhmä JA kaikki yhdessä
(buildit 260719-13/-14/-15; 0 bus-virhettä, 0 4AFC005F:ää koko illassa).

## Staus (NAS tai levyke → /tmp)

| Artefakti | Lähde | Huom |
|---|---|---|
| `build/unix-040` / `-dbg` / `-quiet` | repo build/ | 260719-13/-14/-15 (kaikki 4 ryhmää) |
| `swapls.c` | test-tools/ | käännä koneessa: `cc -o swapls swapls.c` |
| `bigargv.c` | test-tools/ | sama |
| `mincoretst.c` | test-tools/ | sama |
| `pressure.sh`, `burst4.sh`, `hat_dup_cow`, `payload.bin` | kuten paketti A | **BINÄÄRISIIRTO** — tftp: AINA `binary`! sum-referenssit 1570 8192 / 18025 16 |

## Ajolista

1. **Boot + login** (unix-040-dbg): banneri `68040-260719-14`, ei guruja.
   HUOM ISSUE-21: boot-musta-ruutu ~1/4 — retry-boot on tunnettu workaround, kirjaa esiintymät.
2. **Siirtoverifiointi**: `sum /payload.bin` → **1570 8192**, `sum /tmp/hat_dup_cow` → **18025 16**.
3. **RYHMÄ 1 -probe**: `./swapls` → `PAGES 25600` (100 MiB c6d0s2). 51199/51200 = FAIL.
   `swap -l` blocks/free saa poiketa emusta, PAGES ei.
4. **RYHMÄ 2 -probe**: `./bigargv` ×3 → `BIGARGV PASS 45 args 4500 bytes` joka kerta.
5. **BONUS-probe**: `./mincoretst` → `MINCORE VEC rc 0 changed 8 tail intact` +
   `MINCORE ALIGN2K rc -1 errno 22` + `MINCORE PASS`.
6. **hat_dup_cow 64** → RESULT PASS.
7. **pressure.sh** (at-jonossa! telnetd HUPpaa ryhmät) → PRESSURE-DONE, sum 1570 8192 ×6.
8. **burst4.sh** (at-jonossa) → ALLBURSTS-DONE, 24/24 summaa. **RYHMÄ 3 -mittari:
   burstin kesto.** Emu-referenssi: ~1,4 min/bursti (ennen ryhmää 3: ~8 min/bursti,
   freemem jäätyi 129:ään). HW:lla odotus = selvästi nopeampi kuin edelliskäynnin
   burst-ajat; jos thrash-platoo palaa, kirjaa freemem (crash/sar) ja keskeytä.
9. **ISSUE-22-jahti** (kirjattu resepti KNOWN-ISSUES): kylmä boot → VÄLITTÖMÄSTI
   pressure.sh, toista ≥6 kylmää sykliä bare basella (260719-13). Edellinen esiintymä:
   yksi siisti EFAULT (read: Bad address) ensimmäisessä paineessa bootista. Kirjaa
   esiintymätiheys uusilla patcheilla — swapadd-geometria + exec-stack voivat olla
   osallisia; muutos taajuudessa on signaali.
10. **Regressiot paketti A:sta** (pikakierros): writeback disk-truth virtakatkaisulla
    (`sum /press*.bin` säilyy fsck:n yli) + `dd if=/dev/kmem` unmapatusta → ENXIO.

## Hyväksymiskriteerit

- Kohdat 3–5: probet täsmälleen odotusarvoihin — nämä ovat uusien ryhmien HW-totuus.
- Kohdat 6–8: identtiset emu-tuloksiin (PASSit, summat, ei 4AFC005F:ää).
- Kohta 8: burst-kesto kirjataan vaikka läpäisisi — se on RYHMÄ 3:n mittari.
- Poikkeama → serial/kuva talteen, keskeytä lista, kirjaa KNOWN-ISSUESiin.
