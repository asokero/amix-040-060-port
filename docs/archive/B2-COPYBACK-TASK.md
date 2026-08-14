# Codex-toimeksianto: B2-copyback-suunnittelukierros (3 tuotosta)

**Määritelty 2026-07-23, heti B1-WT-rautahyväksynnän jälkeen (commit bc27d81 +
docs 56f6cc2, tagit `pre-dc-enable`/`b1-dc-enable`). B1 on HYVÄKSYTTY oikealla
A3000+Mercury040:llä** (Dhrystone +59 %, burst4 24/24, virtakatkaisu-disk-truth
7/7 — evidenssi `test-tools/b1-dcwt-verify-260723.txt`). B2 = managed-RAM:n
CM-luokan flippi writethrough→copyback (`hat_cm_ram` 0x00→0x20, yksi
.data-longi). Flippi itsessään on triviaali — **kaikki riski on kolmessa
asiassa jotka B1-censukset EKSPLISIITTISESTI lykkäsivät B2:een.** Tämä
toimeksianto tuottaa niiden speksit; toteutus tehdään vasta niiden valmistuttua.

## Kohde ja pinnaus (UUSI — ankkurit siirtyneet B1:n jäljiltä!)

- Kernelrepo commit: `bc27d81` (B1-DC-ENABLE; docs-tila `56f6cc2`)
- `build/unix-040` (base 260723-03) SHA-256:
  `d3e1f80a65394f951ffe894eefe2efcfe7b862786937b0eaf0154440608e8404`
- `build/unix-040-dbg` (dbg 260723-04, rautahyväksytty image) SHA-256:
  `410a6143097ce4d2394f9555d3f2c55cddbdf1c9a991126f43bf05d8676df117`
- **HUOM: pstart040 kasvoi B1:ssä 16+6 tavua → kaikki 0xd75xx+ .text-ankkurit
  siirtyivät** (esim. hat_pagesync-tail 0xd87c8→0xd87d8). Vanhojen censusten
  osoitteet on RE-PINNATTAVA tähän imageen ennen käyttöä.
- Nykytila: CACR=`0x80008000` (WT-DC + IC), DTT0=`0x003fc060` (SÄILYY),
  `hat_cm_ram`=0x00, A3091 FROM_DEVICE koko-cache `cinva dc` completessa
  (dma_cache040.s + patch_a3091_dma.py stopdma-retarget).

## Pohjadokumentit (analyysirepo vm-map/ — ÄLÄ tee uusiksi, RAKENNA näiden päälle)

- `DMA-PREPARE-COMPLETE-CONTRACT.md` — B2-suuntataulukko, partial-line-säännöt,
  A3091-insertiopisteet (startdma 0xd40a / device->sac 0xd4ae / sdma 0xd4b2 /
  stopdma-return 0xd510), instrumentointilaskurit. TUOMIO JO KIRJATTU:
  koko-cache-invalidointi EI kelpaa B2:ssa (asynkroninen DMA + likaiset
  epäliittyvät CB-rivit) → range/line-opit.
- `CM-PTE-WRITER-MATRIX.md` — per-kirjoittaja B2-target-sarake + vaateet
  ("B2 clean DATA before page reuse", "final-only push is not a sufficient
  ownership proof", hat_dup shared-leaf "assert parent class matches stage").
- `DTT0-PHYS-WINDOW-CENSUS.md` + `DTT0-NARROWING-SPEC.md` — page-table-tuomio:
  "Do not classify descriptor pages as ordinary copyback RAM. B2 needs either a
  permanent NC table alias/class or a separately proved descriptor publication
  and reclamation protocol. The B1 census is not acceptance for that change."
- `DMA-INITIATOR-CENSUS.md` — A3091 = ainoa host-RAM-DMA-omistaja tässä koneessa
  (A2090/A2091/hd lykätty, ankkurit kirjattu).

## Tuotos 1: `PT-MEMORY-B2-POLICY.md` — page-table-muistin B2-politiikka

Ratkaistava kysymys: voiko root/pointer/leaf-taulusivuille KOSKAAN syntyä
copyback-aliasta `hat_cm_ram`-flipin jälkeen?

1. **Provenance-census**: mistä `hat_ptalloc` (0xb688e-perhe; re-pinnaa) saa
   sivunsa (page_get? kmem? oma pooli?); mihin ne vapautuvat (`hat_ptfree`);
   onko allokaatio/vapautuspolulla KVA-aliasta (kvseg/segkmem) ja mikä sen CM
   on flipin jälkeen (huom: segkmem_alloc/mapin JÄÄVÄT WT:ksi B2-pilotissa —
   playbookin scope-cut segdev-ryhmään). Sama user-rootille (`hat_alloc` →
   `kmem_zalloc` → kvseg-WT) ja staattisille (`mmu040_buf`, D0-NC).
2. **Tuomio**: (a) "ei CB-aliasta mahdollinen → flippi turvallinen sellaisenaan,
   softa-access D0-NC + HW-tablewalk CI-RMW riittävät", TAI (b) speksaa NC-
   taululuokka / julkaisu+reclaim-protokolla old-byte-ankkurein. Perustele
   040-tablewalk-semantiikasta (ordinary table-search read = WT-non-allocating;
   U/M-RMW = CI, dislodgeaa matchaavan rivin).
3. Kirjaa myös `bp_map`-alias-konstruktorin ja `hat_dup`-private-leafin
   (molemmat lukevat hat_cm_ram → alkavat emittoida 0x20) taulusivu- vs.
   datasivu-erottelu.

## Tuotos 2: `CB-PAGE-LIFECYCLE-CLOSURE.md` — likaisen CB-sivun elinkaarisulkeuma

Uusi hasardiluokka jota WT:ssä ei ole: likainen rivi voi elää VAIN cachessa, ja
sen myöhempi eviktio kirjoittaa RAMiin. Suljettava kolme polkuluokkaa, rivi per
polku, ankkurit + old bytes + vaadittu op (cpusha dc / per-range cpushl / ei
mitään perusteltuna):

1. **Free→reuse**: CB-sivu vapautuu (hat_pageunload / hat_unload / hat_free /
   pvn_done / page_free) likaisin cache-rivein → sivu uusiokäytetään toiseen
   tarkoitukseen → vanha eviktio ylikirjoittaa UUDEN sisällön. Missä on
   choke-point (per-sivu push ennen free-listalle vientiä vs. nykyisten
   teardown-cpushien kattavuus)? CM-matriisin "clean DATA before page reuse"
   -rivit konkreettisiksi sitekohtaisiksi vaateiksi.
2. **TO_DEVICE-writeback**: pageout/putpage/swap kirjoittaa CB-sivun levylle →
   DMA lukee RAMia → likaiset rivit on pushattava ennen armia. Tämä saa
   nojata tuotoksen 3 A3091-prepareen — tässä varmistetaan SULKEUMA: ettei ole
   CPU→levy-polkua joka ohittaa startdman (PIO-polut koherentteja CPU:n kautta;
   listaa ja perustele).
3. **D0-NC-uusiokäyttö**: ppcopy/pagezero/ramstrategy koskevat CB-sivua matalan
   NC-aliaksen kautta — 040-sääntö dislodgeaa matchaavat rivit (push ensin jos
   dirty) → todennäköisesti "koherentti, ei tarvita", mutta KIRJAA se per polku
   faktana (060-ero omaan sarakkeeseen, ei tämän pilotin este).

## Tuotos 3: `A3091-B2-PREPARE-PATCH-SPEC.md` — prepare/complete-patchi tavutasolla

Kontraktin A3091-osio konkreettiseksi patch-speksiksi (sama malli kuin B1:n
stopdma-retarget patch_a3091_dma.py — se on todistettu mekanismi):

1. **Arm-puoli**: startdma 0xd40a -relokaatioiden retarget wrapperiin (montako
   jsr-sitea, osoitteet, old-byte-assertit tässä imagessa); wrapper lukee
   sdcom-osoitteen/pituuden/suunnan ENNEN armia ja tallettaa
   segmenttimetadatan (osoite+pituus+suunta) — kontraktin vaatimus "store
   explicit segment metadata at arm time".
2. **Range-opit**: per-range `cpushl %dc,(%a0)`-silmukka (16 t/rivi;
   line-pyöristys + partial-line-säännöt kontraktista): TO_DEVICE = push;
   FROM_DEVICE = push+invalidoi ennen armia. Complete-puoli: nykyisen
   dma_a3091_stopdma-wrapperin muutos koko-cache-cinvasta talletetun
   segmentin range-invalidoinniksi. Disconnect/reconnect-re-arm (d21a) ja
   virhe/partial-residual -tapaukset käsiteltävä eksplisiittisesti.
3. **040/060-ero**: cpushl-semantiikka molemmilla (060: DPI-bitti / cpush-
   invalidointikäytös) — pilotti on 040-only mutta speksiin faktat.
4. **Instrumentointi**: kontraktin laskurilista (prepare/complete per suunta,
   arm-without-prepare, double-complete...) dbg-buildiin.
5. **Vaihtoehtoarvio kirjattava**: kelpaako pilotissa yksinkertaisempi
   "koko-cache `cpusha dc` prepare-hetkellä + range-invalidointi completessa"
   -välimuoto (cpusha on turvallinen toisin kuin cinva — ei hävitä dataa),
   vai onko se liian hidas per-I/O (koko cachen push jokaisella armilla)?
   Anna suositus datalla (cache 4 KiB / 256 riviä vs. tyypillinen I/O-koko).

## Sulkeumavaatimukset

Vähintään kolme riippumatonta hakua ristiin per tuotos (kuten aiemmissa):
symbolireferenssit (page_free/hat_ptalloc/ptfree-kutsujat), mekaaninen
opcode-haku (cpusha/cinva/cpushl-esiintymät driver+HAT-textissä), ja
3b2-lähdekontraktin diffi (source-first-sääntö). Kaikki osoitteet TÄSTÄ
imagesta (SHA:t yllä), old-byte-ikkunat mukaan.

## Rajaukset (non-goals)

- EI kernel-muutoksia — puhtaat speksit asserteilla; Fable toteuttaa.
- DTT0-kavennus (N1/N2) = erillinen physmap-milestone, EI tänne.
- A2090/A2091/native-hd = lykätty (eivät tässä koneessa; kontraktissa ankkurit).
- segkmem_alloc/mapin CB-staging + mapin-MMIO-NCS = segdev/Z3-ryhmä (kvseg
  JÄÄ WT:ksi B2-pilotissa — pienentää flipin sädettä).
- real-060-DC-hyväksyntä = oma myöhempi milestone (myös B1:lle).
- Lopullinen hyväksyntä = rautasessio (emu ei mallinna DC:tä): burst4 +
  hat_dup_cow + virtakatkaisu-disk-truth + Dhrystone-delta, kuten B1:ssä.

## Hyväksyntäkriteerit tälle kierrokselle

1. Tuotos 1 antaa yksiselitteisen tuomion (flippi turvallinen / NC-luokka
   speksattu) 040-tablewalk-semantiikkaan ja provenance-censukseen nojaten.
2. Tuotos 2:n jokainen free/reuse/writeback-polku on täsmälleen yhdellä
   rivillä tuomiolla (op+paikka+assertit TAI "koherentti, perustelu").
3. Tuotos 3 on suoraan toteutettavissa: retarget-listat, wrapper-pseudokoodi,
   old-byte-assertit, laskurit, ja koko-cache-vaihtoehdon suositus.
4. Kaikki osoitteet verifioitu pinnattua imagea vasten (SHA:t yllä).
