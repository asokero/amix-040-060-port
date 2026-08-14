# Codex-toimeksianto: DTT0-kavennuscensus + fyysisen-ikkunan koherenssispeksi

**Määritelty 2026-07-22 (ISSUE-21:n ratkaisun jälkeen, kernel 2d22ea8).
Tämä on caches Step B:n (WT/DC-enable, rautasessio) VIIMEINEN avoin analyysi-gate.**
CM-B1-ryhmä (Lcm_sel + hat_cm_ram + segkmem-julkaisu) ja A3091-DMA-hook ovat jo
landattu dormanttina ja emu-verifioitu; DMA-census on tehty (58f1cda). DC:tä EI
kuitenkaan voi kytkeä päälle — edes writethrough-tilassa — niin kauan kuin **DTT0
(`0x003fc060`) pakottaa koko data 0–1 GB:n cache-inhibitiin**: se maskaa KAIKEN
per-sivun CM:n (Lcm_sel:n WT 0x00 / CB 0x20 ei näy). Tämä census tuottaa turvallisen
DTT0-kavennuksen (tai -disabloinnin) speksin + luokittelee jokaisen fyysistä RAMia
DTT0-ikkunan kautta koskettavan polun, ettei kavennus synnytä incoherentteja aliaksia.

**Ei liity ISSUE-21:een:** varhaisboot-cache-blokkeri oli peritty INSTRUCTION cache ja
se on korjattu (config040.s; varhaiskoodi ajaa CACR=0, pstart040 'D' palauttaa IC:n).
DTT0 koskee DATA-cachea ja on erillinen, yhä avoin asia.

## Kohde ja pinnaus

- Kernelrepo commit: `2d22ea8` (ISSUE-21-fix + CM-B1 + A3091-DMA-hook mukana)
- `build/unix-040` SHA-256: `fff91777831d2e917baf3cb7692b06385374a08ac80b1dfe5ff10d5ebb2dcabe`
- Vanilla-referenssi: `vanilla/stand/unix` (`7d26cb6f...`, ET_REL) + MI-lähteet
  SVR4 3b2 -referenssistä (ppcopy/pagezero/hat-perhe) — lue kontrakti lähteestä ENSIN
  (feedback: source-first-before-binary-re), diffaa sitten m68k-portti.
- **DTT/ITT-nykytila (`src/pstart040.s:322–329`, movec-arvot):**
  - ITT0 = `0x003fc000` — 0–1 GB **code**, CM=00 (WT-cacheable), AKTIIVINEN (IC on)
  - DTT0 = `0x003fc060` — 0–1 GB **data**, CM=11 (cache-INHIBITED) ← kavennettava
  - DTT1 = `0x807fa060` — ≥`0x80000000` I/O, CM=11, S=01 (supervisor) ← SÄILYY
  - TTR-granulariteetti: base = bitit 31–24, maski = bitit 23–16 (16 MB askel);
    mielivaltaista aluetta EI voi rajata — tämä on kavennuksen reunaehto (alla).
- Pohjadokumentit (analyysirepo vm-map/): CACHE-STEP-B-PRESTUDY.md,
  CM-PTE-WRITER-MATRIX.md (DTT0-huomiot + stage-taulukko),
  HAT-FLUSH-COHERENCY-AUDIT.md, HAT-UNLOAD-COHERENCY-AUDIT.md,
  BIO-PFN-PHYS-KVA-CENSUS.md (fyysinen vs KVA -aliakset).

## Miksi (stage-kohtainen fysiikka — censuksen luokitteluperuste)

040:n DC-linja on 16 tavua; DC ei snoopaa väylää. Fyysinen sivu 0–1 GB voidaan
saavuttaa KAHDELLA tavalla:
- **(a) DTT0-identiteetti-ikkuna** — CPU koskee fyysistä osoitetta suoraan; TÄNÄÄN aina
  uncached (CM=11).
- **(b) Normaali sivukartoitus** — kvseg/segmap/bp_map/user-VA, jonka leaf-PTE:n CM
  muuttuu WT:ksi (B1) / CB:ksi (B2) heti kun DTT0 lakkaa maskaamasta.

**Hasardi:** jos sama fyysinen sivu koskettaan MOLEMPIEN aliasten kautta eri
cacheability-luokassa, syntyy incoherentti alias (toinen polku cachettaa, toinen ei →
vanhentunut data). DTT0:n blanket-inhibit takaa tänään että (a) on aina uncached;
kavennus poistaa tuon takuun. Siksi census EI saa perustella millään "DTT0 hoitaa" —
sen on kirjattava per polku, mitä aliasta se käyttää ja mikä sen CM on kavennuksen JÄLKEEN.

**Erityistapaus — MMU:n laitteistotaulukävely + page-table-muisti.** SRP/URP osoittavat
fyysisiin root-tauluihin; 040:n table-search lukee deskriptorit RAMista ja kirjoittaa
U/M-bitit takaisin, ja nuo accessit voivat allokoitua DC:hen jos page-table-sivut ovat
cacheable. Ohjelmisto-deskriptorikirjoittajat (hat_pteload/hat_unload/krnxmemflt040/
segkmem_setprot) saivat B1:ssä `cpusha dc`-julkaisun (WT-tyylinen). Census MÄÄRITTÄÄ:
riittääkö tuo julkaisu kun DTT0 ei enää inhiboi page-table-sivuja, VAI pitääkö
page-table-muisti pitää CI:nä (oma leaf-CM tai säilytetty CI-ikkuna)? — tämä on
raskain kohta ja oma matriisirivinsä.

## Tuotokset (analyysirepo vm-map/)

1. **`DTT0-PHYS-WINDOW-CENSUS.md`** — täysmatriisi, rivi per fyysistä RAMia koskettava polku:

   | kenttä | sisältö |
   |---|---|
   | polku | ppcopy, pagezero/pzero, gen_strategy (b_addr/PFN<<12), hat_pteload-leaf-kävely, hat_unload/pagesync-kävely, krnxmemflt040-kävely, bp_map040-ghost-alias, sysseginit/kvm_init varhais-phys, raw /dev/mem+vtop, muut closure-haun löytämät |
   | access-tyyppi | read / write / rmw fyysiseen RAMiin |
   | miten RAM saavutetaan | **(a) DTT0-identiteetti (phys-osoite)** / **(b) oma kernel-VA (mikä?)** / **laitteisto-tablewalk** — TODISTETTAVA, ei oletettava |
   | mitä dataa | user-sivu / page-table-deskriptori / DMA-puskuri / kernel-struct / u-area |
   | co-alias | onko sama phys-sivu SAMANAIKAISESTI kartoitettu oikealla VA:lla; sen per-sivun CM (WT/CB/NC) |
   | hasardi kavennuksen jälkeen | incoherentti-alias / tablewalk-deskriptori-cache / ei mitään |
   | B1-vaade (WT) | tarvittava käsittely WT:ssä (flush-tyyppi cpush/cinv + paikka + laajuus, TAI "koherentti, ei tarvita" perusteltuna) |
   | B2-vaade (CB) | lisäkäsittely copybackissa (push-ennen-lukua-toisen-aliaksen-kautta yms.) |
   | koodiosoite + old bytes | funktio/osoite; patch-ankkuri jos flush/CM-muutos tarvitaan; tavuassertit |

2. **`DTT0-NARROWING-SPEC.md`** — varsinainen kavennuspäätös + perustelu:
   - **Kavennus vai disablointi?** Arvio: koska phys-ikkunan käyttäjät koskettavat
     MIELIVALTAISIA PFN:iä koko RAMissa eikä TTR-maski salli mielivaltaista aluetta
     (16 MB granula), 16 MB-ikkunaan rajaaminen EI todennäköisesti onnistu → oletettu
     tuomio on **DTT0 E=0 (disable)**, jolloin data 0–1 GB menee page-taulujen kautta ja
     per-sivun CM on auktoritatiivinen. Census VAHVISTAA tai KUMOAA tämän ja antaa tarkan
     movec-arvon (jos säilytettävä CI-scratch-ikkuna löytyy TTR-lausuttavana, esitä se).
   - **DTT1 säilyy** (`0x807fa060`, I/O ≥`0x80000000` CI) — perustele että mikään
     RAM-alue ei osu DTT1:een. ITT0 (code WT) EI muutu (IC-koherenssi hoidettu Step A:ssa).
   - **Ordering CACR-DC-enablen kanssa:** missä järjestyksessä DTT0-E=0, pflusha,
     mahdolliset phys-ikkuna-konversiot ja CACR-DC-bitti tehdään turvallisesti
     (pstart040 'D' vs runtime — ottaen huomioon että p1int–p6int lataavat CACR:n
     `sup_cacr`-globaalista joka entryssä).
   - **Jäljelle jäävät phys-ikkuna-konversiot:** jokaiselle matriisin (a)-DTT0-polulle
     joka jää eloon E=0:n jälkeen — konkreettinen speksi (transientti CI-sivukartoitus /
     flush-parit / dedikoitu copy-window-VA), old-byte-assertein tai override-suosituksin.
   - **Page-table-muistin tuomio:** WT-julkaisu riittää / vaatii CI-leafin — perusteltuna
     040-tablewalk-semantiikasta.

## Sulkeumavaatimukset (census closure — kuten PTE- ja DMA-matriiseissa)

Vähintään neljä toisistaan riippumatonta hakua, tulokset ristiin:
1. **Fyysisen osoitteen synty**: kaikki paikat joissa PFN muunnetaan osoitteeksi ilman
   sivukartoitusta (`<<12`/`ctob`/`ptob`-tyyliset + suora phys-poke) → mitkä lukevat/
   kirjoittavat sen kautta.
2. **HAT/MMU-taulukävelijät**: jokainen sdt/pdt/leaf-deskriptorin luku/kirjoitus
   (hat_pteload/unload/pagesync/chgprot/krnxmemflt040/segkmem_setprot/hat_alloc/free)
   → koskeeko page-table-muistia phys-ikkunan vai KVA:n kautta; nykyinen cache-op.
3. **Copy/zero-primitiivit**: ppcopy, pagezero/pzero, bcopy/bzero-varhais-phys-käyttö,
   fork/COW/pagein-polkujen sivukopiot → mikä VA/alias.
4. **DTT0/TTR-riippuvuudet suoraan**: kaikki `0x003fc0`/`movec …dtt0`/phys-identiteettiin
   nojaavat oletukset koodissa + kommenteissa; risti DMA-census + BIO-PFN-PHYS-KVA-census
   -löydöksiin (poikkeamat kirjattava).

## Rajaukset (non-goals)

- EI kernel- tai binäärimuutoksia — puhdas analyysi + patch-speksit asserteilla.
- CACR-DC-flipin varsinainen ajaminen + hyväksyntä = rautasessio (Amiberry ei mallinna
  DC:tä); tämä census tuottaa vain staattisen speksin + hyväksyntälistan.
- B2:n low-physical-alias-POLITIIKAN lopullinen viritys (partial-line-hasardit yms.)
  saa jäädä B2-vaade-sarakkeeseen FAKTOINA; toteutuspäätös on B2-milestone.
- Z3-user-mmap / segdev-CM = oma ryhmä (Z3-USER-MMAP-PFN-AUDIT.md); tähän vain jos
  jokin segdev-polku koskee RAMia DTT0-ikkunan kautta.

## Hyväksyntäkriteerit tälle censukselle

1. Jokainen closure-haun löytämä fyysistä RAMia koskettava polku esiintyy täsmälleen
   yhdellä matriisirivillä (tai eksplisiittisellä "ei osu DTT0:aan, oma-VA"-rivillä).
2. Jokaisen (a)-DTT0-polun kohdalla on kavennuksen-jälkeinen tuomio: koherentti /
   tarvitsee flushin (paikka+laajuus+assertit) / tarvitsee säilytetyn CI-mappauksen.
3. DTT0-kavennus/disablointi annettu konkreettisena movec-arvona + ordering CACR-DC:n
   kanssa, perusteltuna TTR-granulariteetista ja p1int–p6int CACR-reloadista.
4. Page-table-muistin koherenssituomio annettu (WT-julkaisu riittää vs CI-leaf) 040-
   tablewalk-semantiikkaan nojaten.
5. Target-hashit verifioitu; kaikki osoitteet linkatun 040-imagen (SHA yllä) .text-osoitteita.
