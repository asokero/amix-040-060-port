# Codex-toimeksianto: DMA-initiaattoritäyscensus + prepare/complete-omistajuus

**Määritelty 2026-07-20 (CM-B1:n landauksen jälkeen, kernel 8c0772a).
Tämä on caches Step B:n (WT/DC-enable, rautasessio) viimeinen analyysi-gate:
CM-PTE-WRITER-MATRIX.md:n B1-ryhmän kohta 8 ("Add DMA-read completion
invalidation before enabling the data cache") jäi tietoisesti odottamaan tätä
censusta. Ilman tätä DC-enablea ei saa tehdä edes WT-tilassa.**

## Kohde ja pinnaus

- Kernelrepo commit: `8c0772a` (CM-B1 landattu; segkmem040.s + patch_segkmem.py mukana)
- `build/unix-040` SHA-256: `ef63f751c5059245d4ffd0696bde338cbab08d5b7d98c54f1b3e1a19d53edc03`
- Vanilla-referenssi: `vanilla/stand/unix` (7d26cb6f...) + ajurilähteet
  `vanilla/usr/sys/amiga/driver/` (READ-ONLY mount) — hd.c (WD33C93+SDMAC),
  audio.c (Paula), amiga.c (custom-chip glue), bb/ben/cl/jb/ql/par/acia/sl/
  slip/ram/tiga + aen/-alihakemisto (A2065) + kdb.
- Pohjadokumentit (analyysirepo vm-map/): CACHE-STEP-B-PRESTUDY.md,
  BIO-PFN-PHYS-KVA-CENSUS.md, HAT-FLUSH-COHERENCY-AUDIT.md,
  CM-PTE-WRITER-MATRIX.md (stage-taulukko + DTT0-huomiot),
  Z3-KERNEL-MMIO-WINDOW-AUDIT.md.

## Miksi (stage-kohtainen fysiikka — censuksen luokitteluperuste)

040:n DC-linja on 16 tavua. DMA ei snoopaa CPU:n välimuistia (A3000:n SDMAC
kirjoittaa suoraan RAMiin; custom-chipit lukevat/kirjoittavat chip-RAMia).

- **B1 (WT, RAM CM=00):** CPU-storet menevät aina RAMiin asti → **write-DMA
  (RAM→laite) on turvallinen ilman hookkeja**. Sen sijaan **read-DMA
  (laite→RAM) jättää DC:hen STALE-mutta-VALID linjoja** puskurin alueelta →
  CPU lukee vanhaa dataa. Vaadittu operaatio: **invalidointi (cinv/cpush)
  puskurin alueelle DMA-completessa** (tai konservatiivisesti ennen käyttöä).
- **B2 (CB, RAM CM=01):** lisäksi **write-DMA vaatii cpush ENNEN käynnistystä**
  (likaiset linjat eivät ole RAMissa), ja read-DMA-invalidointi EI saa tapahtua
  cpushl/cpushp-muodossa likaisille naapurilinjoille completen jälkeen (dirty
  writeback puskurin päälle). → jaettujen 16 B -linjojen hasardit on kirjattava.
- DTT0 (0–1 GB identity, CI) EI muutu tässä vaiheessa: DTT0-ikkunan KAUTTA
  tehdyt CPU-accessit ovat uncached — mutta sama fyysinen sivu voi olla
  SAMANAIKAISESTI kernel-VA:lla WT/CB-luokassa (kvseg/bp_map/segmap/user).
  Censuksen on kirjattava per initiaattori, MITÄ aliasta CPU käyttää puskurin
  lukemiseen/kirjoittamiseen — pelkkä "DTT0 hoitaa" ei kelpaa perusteluksi.

## Tuotokset (analyysirepo vm-map/)

1. **`DMA-INITIATOR-CENSUS.md`** — täysmatriisi, rivi per initiaattori × suunta:

   | kenttä | sisältö |
   |---|---|
   | initiaattori | esim. SDMAC/WD33C93 (hd), Paula audio, floppy/trackdisk-vastine, bitplane/copper, blitter, A2065 aen, muut löytyvät |
   | suunta | read-DMA (laite→RAM) / write-DMA (RAM→laite) / molemmat |
   | puskurin lähde | buf-cache b_addr / bp_map-alias / physio+user-sivut / kernel-static / chip-RAM |
   | CPU-alias(t) | millä VA:lla CPU koskee puskuria ennen/jälkeen (kvseg WT? DTT0-ikkuna? bp_map 0x19-alias? user-VA?) |
   | käynnistyskohta | koodiosoite + funktio, jossa DMA armataan (esim. SDMAC WTC/ACR-kirjoitukset) |
   | complete-kohta | keskeytyskäsittelijän osoite + polku biodoneen/vastaavaan |
   | nykyiset cache-opit | (odote: ei mitään) |
   | B1-vaade | read-DMA: invalidointitapa + -paikka + laajuus; write-DMA: "ei tarvita" perusteltuna |
   | B2-vaade | push-ennen-write / invalidoi-read + partial-line-hasardit |
   | linjajakohasardi | onko puskuri aina 16 B -linjarajattu; kuka allokoi; voiko naapuridata jakaa linjan |
   | patch-site + old bytes | mihin hook mahtuu / trampoliinitarve; tavuassertit |

2. **`DMA-PREPARE-COMPLETE-CONTRACT.md`** — omistajuusanalyysi:
   - SVR4:ssä ei ole DDI prepare/complete -rajapintaa → **choke-point-tuomio**:
     voidaanko B1-invalidointi keskittää harvoihin pisteisiin (kandidaatit:
     gen_strategy, physio, bp_map/bp_mapout, hd.c:n start/intr-parit,
     biodone-hookki) vai tarvitaanko per-ajuri-sitet? Suositus + perustelu.
   - Puskurin elinkaari per luokka: kuka allokoi, kuka kierrättää, missä
     kohtaa omistajuus siirtyy laitteelle ja takaisin (= mihin hook KUULUU,
     jotta se ei kilpaile page-reusen/copyn kanssa).
   - bp_map040:n ghost-mapping-kontrakti (ei p_mapping-kirjanpitoa) vs
     invalidointivastuu — kumpi omistaa: bp_mapout vai biodone-polku?
   - aen (A2065): väite "CPU/PIO, ei host-DMA:ta" on TODISTETTAVA censuksessa
     (lance-rengaspuskurit ovat kortin omassa RAMissa? vai host-RAMissa?) —
     älä peri vanhaa johtopäätöstä asserttaamatta.

## Sulkeumavaatimukset (census closure — samaan tapaan kuin PTE-matriisissa)

Vähintään neljä toisistaan riippumatonta hakua, tulokset ristiin:
1. **Vektoripöytä/keskeytyskäsittelijät**: kaikki autovector/portia-käsittelijät
   → mitkä kuittaavat DMA-completen.
2. **Custom-chip-rekisterikirjoituscensus**: DMACON/DSKPT/AUDxLC/BPLxPT/
   COPxLC/blitter-rekisterit koko imagesta (0xDFFxxx-accessit + amiga.h:n
   symbolit) — jokainen kirjoittaja luokiteltava.
3. **SDMAC/WD33C93-rekisterialueen accessit** (0xDD0000-alue / hd.c:n pohjalta)
   — arm/complete-parit.
4. **bdevsw/cdevsw + strategy-funktiot**: jokaisen linkatun ajurin strategy →
   kuljettaako buf-osoitteen DMA-enginelle vai kopioiko PIO:lla.
Poikkeamat aiempiin dokumentteihin (esim. BIO-PFN-PHYS-KVA-CENSUS) kirjattava.

## Rajaukset (non-goals)

- EI kernel- tai binäärimuutoksia — puhdas analyysi + patch-speksit asserteilla.
- Z3-korttien (VA2000/Picasso) ajureita ei ole AMIXissa → ulkopuolella; A2088
  ISA-sillan mahdollinen DMA vain jos linkatussa kernelissä on sille koodia.
- B2:n low-physical-alias-POLITIIKKA (ppcopy/pagezero/gen_strategy-ikkunat) =
  oma myöhempi päätös; tähän censukseen vain FAKTAT siitä, mitä aliaseja
  DMA-puskureihin kohdistuu.
- Emulaattorivalidointi ei kuulu tehtävään (Amiberry ei mallinna DC:tä);
  hyväksyntä = staattiset assertit (rivimäärät, tavuassertit, closure-haut).

## Hyväksyntäkriteerit tälle censukselle

1. Jokainen closure-haun löytämä DMA-kirjoittaja/lukija esiintyy täsmälleen
   yhdellä matriisirivillä tai eksplisiittisellä "ei-DMA, PIO"-rivillä.
2. Jokaisella read-DMA-rivillä on toteutuskelpoinen B1-invalidointispeksi
   (paikka + laajuus + old-byte-assertit tai override-suositus).
3. Choke-point-tuomio annettu (keskitetty vs per-ajuri) perusteluineen.
4. aen-PIO-väite todistettu tai kumottu.
5. Target-hashit verifioitu; kaikki osoitteet linkatun 040-imagen .text-osoitteita.
