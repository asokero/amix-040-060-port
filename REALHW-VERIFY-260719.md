# Real-HW-040-verifypaketti (koottu 2026-07-19, emu-hyväksynnän jälkeen)

Emu-040-hyväksyntä on puhdas (build 260719-01/-02: ISSUE-10 swap-in-korjaus,
burst4 ALLBURSTS-DONE, ei 4AFC005F:ää — test-tools/issue10-swapin-fix-260719.txt).
Seuraava HW-sessio A3000 + Mercury 68040:llä ajaa TÄMÄN listan järjestyksessä.
Kaikki artefaktit ovat repossa / NAS-siirtovalmiita — mitään ei tarvitse rakentaa
sessiossa.

## Staus (NAS tai levyke → /tmp)

| Artefakti | Lähde | Huom |
|---|---|---|
| `build/unix-040` + `build/unix-040-dbg` | repo build/ | 260719-01/-02; loader DH2:sta tai kopioi |
| `pressure.sh`, `burst4.sh` | tftp-dir (scratchpad add0cd4f…/tftp) tai evidenssitiedoston kuvaus | tekstiä, siirto vapaa |
| `hat_dup_cow` (8071 B) | amix-kernel-analysis/runtime-tests/ | **BINÄÄRISIIRTO** — tftp:ssä AINA `binary` ensin! |
| `payload.bin` (sum **1570 8192**) | tftp-dir | **BINÄÄRISIIRTO**; verifioi sum ennen testejä |
| `msynctst.c` | test-tools/ | käännetään koneessa (`cc -o msynctst msynctst.c`) |
| `crash`-työkalu | AMIX:n oma | crash(1M)-ajoon |

## Ajolista (järjestyksessä; jokaisen jälkeen kirjaa tulos)

1. **Boot + login** (unix-040-dbg): banneri `68040-260719-02`, ei guruja.
   Serial-kaappaus päälle jos mahdollista (SERIAL-DEBUG.md).
2. **Staus-verifiointi**: `sum /payload.bin` → **1570 8192**; `sum /tmp/hat_dup_cow`
   koko 8071 B. Väärä summa = siirto rikkoi tiedoston (netascii!) — älä jatka.
3. **hat_dup_cow 64** solo → RESULT PASS.
4. **pressure.sh** → PRESSURE-DONE + sum 1570 8192 ×6, ei bus-virheitä konsolissa.
5. **burst4.sh** → ALLBURSTS-DONE + summat joka burstissa. HUOM: emulla burstit 3–4
   kestivät ~10 min/kpl (laillista thrashia) — älä tulkitse jumiksi ennen ~15 min.
6. **Writeback disk-truth** (WRITEBACK-TASK.md-protokolla): pressuren jälkeen
   unclean-kill (virtakatkaisu) → fsck → boot → `sum /press*.bin` yhä 1570 8192
   (Model-B pfn-kirjoitukset oikeisiin blokkeihin myös oikealla SCSI:llä).
7. **msync-roundtrip**: käännä msynctst.c, aja (emu-referenssi: MSYNC-OK +
   cold-cache sum 32895 128, b217506).
8. **crash(1M) re-run** (ISSUE-13:n jäännös): `dd if=/dev/kmem` unmapatusta
   osoitteesta → siisti ENXIO (emu-verifioitu; HW-vahvistus puuttuu).
9. **UFS-geometria** (amix-root-fs-geometry-muistin aukko): `df -g /` tai
   fstyp/dumpfs-vastine → varmista fs_bsize 8192 / frag 1024 myös HW-levyllä
   (mountfs-portti hylkää < 2048 — jos HW-root poikkeaa, writeback-oletukset
   tarkistettava).
10. **Caches Step A writeback-verify** (CACHES-ON-PLAYBOOK.md): IC päällä
    (CACR 0x8000) — boot + fork/exec-churn + pressure IC:n kanssa realilla.
    Step B (DC) EI tässä sessiossa: vaatii hat_pteload CM-bitit + DTT0-kavennuksen
    + DMA-cpusha-auditin (playbookin mukaan).

## Hyväksymiskriteerit

- Kohdat 1–5: identtiset emu-tuloksiin (summat, PASSit, ei 4AFC005F:ää).
- Kohta 6: summat säilyvät unclean-killin yli.
- Poikkeama MISSÄ TAHANSA kohdassa → kirjaa serial/kuva + keskeytä lista;
  emulaattori-vs-HW-delta on itsessään löydös (vrt. ISSUE-7/8-historia:
  HW-only-viat ovat todellisia).

## Tunnetut HW-riskit tälle listalle

- ISSUE-20: hat_swapout-miina — EI vaikuta (sched-override estää; älä palauta).
- swapadd 2× slot-yliallokaatio: vaaraton alle 100 MB swap-käytöllä (emu-todettu);
  burst4 pysyy reilusti alle.
- hardbus XPAGE -toistotaajuus kasvoi emulla paineessa (n=3→B) — jos HW:llä
  XPAGE-viestit vyöryvät, ota serial-loki talteen (eri ajoitusprofiili).
