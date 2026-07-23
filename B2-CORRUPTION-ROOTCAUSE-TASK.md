# Codex-toimeksianto: B2-copyback hiljaisen levykorruption root-cause

**Määritelty 2026-07-23, B2:n rautakontrollikokeen JÄLKEEN.** B2-copyback
(`hat_cm_ram=0x20`) todettiin **rautakontrollivertailussa** korruptoivan
tiedostoja levyllä HILJAISESTI paineessa; identtinen WT-baseline (sama
hook-ryhmä, `hat_cm_ram=0x00`) EI korruptoi. Tämä toimeksianto etsii
koherenssiaukon ja tuottaa korjausspeksin. **EI kernel-muutoksia — puhdas
analyysi + patch-speksit asserteilla; Fable toteuttaa.**

## Ratkaiseva evidenssi (täysi kuvaus: `test-tools/b2-cb-realhw-CONTROL-260723.txt`)

Kontrolloitu vertailu, sama workload (`burstloop.sh R=4` = 16 burstia = 96
rinnakkaista 4 MiB kopiota + hat_dup_cow 64/bursti), sama levy/fs/NAS-payload,
**ainoa muuttuva muuttuja `hat_cm_ram`:**

| kernel | burstia | ISSUE-22 EFAULT (puhdas abortti) | **B2 HILJAINEN levykorruptio** |
|---|---|---|---|
| -07 WT (0x00) | 16 | 1 (`cp: read: Bad address`, tiedosto puuttuu) | **0** |
| -10 B2 (0x20) R=4 | 16 | 0 | **1** (press5: `32757 5328` + read error) |
| -10 B2 (0x20) aiempi | 8 | 1 (tiedosto puuttuu) | **1** (press6: `18645 7648` + read error) |

**Kaksi ERI ilmiötä, erotettu:**
1. **ISSUE-22 EFAULT** (pre-existing, EI B2): `read: Bad address` → cp aborttaa
   siististi, tiedostoa EI synny, cp RAPORTOI virheen. Molemmilla kerneleillä.
2. **B2 hiljainen korruptio** (VAIN -10): tiedosto SYNTYY, cp EI raportoi
   virhettä, mutta levyllä lyhyt + väärä checksum + **read error takaisinluvussa**.
   Toistui kahdella eri -10-bootilla; 0 kertaa 16 puhtaassa -07-burstissa.

**Signature-tulkinta:** lyhyt tiedosto + väärä checksum + read error (ei pelkkä
väärä data) viittaa **fs-metadatan** (inode/indirect/cg-lohkot) tai lohkokartan
epäjohdonmukaisuuteen, EI pelkkään datasivun väärään sisältöön.

## Kriittinen rajaus: asennetut hookit toimivat oikein

Laskurit -10-ajojen jälkeen (`/dev/kmem`): `dma_prep_to==dma_cmpl_to`,
`dma_prep_from==dma_cmpl_from` (TÄYDELLINEN pariutus), ja KAIKKI
diagnostiikkalaskurit 0 (`dma_prep_owned`/`dma_cmpl_noprep`/`dma_range_ovf`/
`cb_rel_reject`). `cb_rel_count` kasvaa joka page-freellä. **Eli A3091
prepare/complete-protokolla JA cb_page_release-barrier ovat sisäisesti eheät —
aukko EI ole hookatun polun väliin jäänyt prepare/complete.** Korruptio tulee
joko (a) disk-write/read-polusta jota nykyiset hookit EIVÄT kata, tai (b)
hienovaraisemmasta racesta.

## Kohde ja pinnaus

- Kernelrepo commit: `4fd4132` (B2-CB-HOOKS 0b84a65 + docs)
- `build/unix-040` (base, hat_cm_ram=0x00) SHA-256:
  `11b4f21f8a97d651730b631afb6e7eeafe8a2315055178226ed00f0965b26125`
- `build/unix-040-b2` (hat_cm_ram=0x20) SHA-256:
  `562eccaced6ad9276aeb2513d5b6d1c0af97d79d61475aad84a53dac4bb3dfec`
- Nykytila: CACR=0x80008000 (IC+DC), DTT0=0x003fc060 (säilyy), A3091 startdma
  prepare (0xd0b2/0xd21a → dma_a3091_startdma[_reconn]) = koko-cache `cpusha dc`,
  stopdma complete (4×) = FROM_DEVICE range-`cinvl`; cb_page_release =
  cpushl×256 page-freellä.
- Pohjadokumentit (analyysirepo vm-map/): DMA-INITIATOR-CENSUS.md,
  DMA-PREPARE-COMPLETE-CONTRACT.md, A3091-B2-PREPARE-PATCH-SPEC.md,
  CB-PAGE-LIFECYCLE-CLOSURE.md, BIO-PFN-PHYS-KVA-CENSUS.md.
- Toteutuslähteet: `prototypes/dma_cache040.s`, `prototypes/cb_release040.s`,
  `prototypes/patch_a3091_dma.py`, `prototypes/patch_cb_release.py`.

## Tuotos 1: `DISK-WRITE-DMA-RECENSUS.md` — kirjoituspolun täysi DMA-census

B1-DMA-census keskittyi FROM_DEVICE-completion-invalidointiin (luku). B2 vaatii
symmetrisen **KIRJOITUS**puolen censuksen. Kysymys: **kulkeeko JOKAINEN
host-RAM→levy-DMA A3091 startdma-preparen läpi, ja onko sen pa/len oikea
arm-hetkellä?**

1. **Buffer-cache-kirjoituspolku**: `bwrite 0x3c304` / `bdwrite 0x3c378` /
   `bawrite 0x3c3b0` → `strategy 0xafa4` → `ddstrategy 0xbe84` → sd/A3091.
   Todista kulkeeko UFS-metadatan (inode/indirect/cg/dir-lohko) kirjoitus tätä
   kautta A3091 startdma:han. Metadata-buffer on KVA (buffer-cache) — sen
   dirty cache-rivi PITÄÄ pushata ennen sen DMA-kirjoitusta. Koko-cache
   `cpusha dc` preparessa KATTAISI sen — VAHVISTA että metadata-write todella
   armaa A3091 startdma:n (eikä ohita sitä esim. PIO:lla tai eri initiatorilla).
2. **physio/raw-polku** (`physio 0x52400`): raakakirjoitus — sama kysymys.
3. **pageout/putpage-kirjoitus** (spec/ufs/anon): kulkeeko A3091:n kautta?
4. **Onko KIRJOITUS-initiaattoreita jotka EIVÄT ole startdma?** B1-census
   luetteli host-RAM-DMA-omistajat luvun kannalta; risti se KIRJOITUKSEN
   kannalta. Erityisesti: onko A3091:llä muuta arm-kohtaa kuin 0xd40a startdma
   (esim. erillinen write-setup, scatter-gather, tai SDMAC-rekisterikirjoitus
   joka käynnistää siirron ilman startdma:ta)?
5. **Matriisi rivi/polku**: initiaattori, suunta, kulkeeko startdma-preparen
   läpi (kyllä/ei + osoite), pa/len oikeellisuus arm-hetkellä, verdict.

## Tuotos 2: `B2-COHERENCY-GAP-ANALYSIS.md` — aukon paikannus + hypoteesit

Signature (metadata/blokkikartan korruptio, hiljainen) vasten mekanismia.
Analysoi ainakin nämä, kukin todistettuna tai kumottuna binääri/lähde-evidenssillä:

1. **FROM_DEVICE-metadata-luvun invalidointiaukko**: UFS lukee inode/indirect-
   lohkon A3091 FROM_DEVICE-DMA:lla; jos completion-`cinvl`-range EI kata sitä
   bufferia (väärä pa/len, tai buffer ei ole se jonka stopdma-wrapper tuntee),
   CPU näkee VANHAN cachetun metadatan → väärä lohkoallokaatio → lyhyt tiedosto
   + read error. Onko completion-invalidointi sidottu OIKEAAN segmenttiin
   kaikissa neljässä stop-kohdassa myös metadata-luvuille?
2. **Async-DMA-race**: prepare tekee koko-cache `cpusha dc`:n JA armaa; DMA
   siirtää asynkronisesti CPU:n jatkaessa muuta koodia. Voiko toinen prosessi/
   keskeytys liata rivin joka osuu DMA-kohdesivulle (buffer-cache-uudelleen-
   käyttö samaan cache-riviin/sivuun) siirron AIKANA → eviktio yli tuoreen
   datan? Contract varoitti tästä ("CPU must not read or write the owned range
   between prepare and complete") — onko tuo invariantti oikeasti taattu vai
   voiko buffer-cache/pageout rikkoa sen?
3. **cb_page_release pa-matematiikka**: `cpushl dc,(pa)` pushaa fyysisesti
   tagatun rivin; jos `pa = pages_base + (pp-pages)/60 << 12` laskee VÄÄRÄN
   pfn:n jollekin pp:lle, oikean sivun dirty-rivi jää pushamatta → uudelleen-
   käytössä korruptio. reject=0 todistaa vain että kaikki pp:t olivat
   [pages,epages)-välissä — EI että pfn oli oikea. Vahvista pages/pages_base/60
   ja että (pp-pages) on aina 60:n monikerta tässä imagessa; tarkista ettei
   divul-truncation tuota väärää pfn:ää.
4. **hat_unload(HAT_RELEPP)-reorder**: uusi järjestys (leaf-clear+cpusha dc+
   pflusha ennen page_freetä) — voiko se jättää datasivun likaisen rivin
   pushaamatta (cpusha dc pushaa KOKO cachen, joten ei pitäisi) tai vapauttaa
   sivun jonka cb_page_release myöhemmin käsittelee väärin?
5. **Partial-line/endpoint**: FROM_DEVICE-range-`cinvl` pyöristää 16 tavuun; jos
   metadata-luku ei ole linja-alignattu, endpoint-rivin osittaisdata voi kadota.
   Kattaako nykyinen pyöristys sen (contractin partial-line-säännöt)?

Anna kullekin: **todennäköisyys + todiste/kumous + miten se selittää (tai ei)
juuri lyhyt+read-error-signaturen.** Nimeä TODENNÄKÖISIN root cause.

## Tuotos 3: `B2-CORRUPTION-FIX-SPEC.md` — korjaus + tiukempi reprodusointi

1. **Korjausspeksi** todennäköisimmälle root causelle, old-byte-asserteilla,
   samalla mekanismilla kuin nykyiset patchit (relokaatio-retarget / bsr.l-island
   / .s-override). Jos root cause on FROM_DEVICE-metadata-invalidointi →
   todennäköisesti prepare/complete pitää muuttaa koko-cache-muodosta oikeaan
   per-range `cpushl`/`cinvl`-muotoon KAIKILLE poluille (spec jo luonnosteli
   tämän "production range" -muotona) TAI kattaa puuttuva initiaattori.
2. **Instrumentointispeksi** juurisyyn vahvistamiseen raudalla: laskurit/kaappaus
   joka kertoo KORRUPTOITUNEESTA tapauksesta — mikä tiedosto/inode, onko
   korruptoitunut lohko metadata vai data, mikä DMA-segmentti (pa/len/suunta)
   sitä edelsi, meninkö preparen läpi. (dbg-gated, ei häiritse base/quiet.)
3. **Tiukempi reprodusointi** kuin burst4 (~1 korruptio/16 burstia, 40 min/ajo):
   ehdota kohdennettua workloadia joka maksimoi metadata-turbulenssin
   (esim. paljon pieniä tiedostoja luonti/poisto + fsync + rinnakkaisuus, tai
   suora inode-intensiivinen kuorma) niin että korruptio toistuu tiheämmin ja
   nopeammin — nopeuttaa fix-verifiointisykliä.

## Sulkeumavaatimukset

Vähintään kolme riippumatonta hakua ristiin: (1) kirjoitus-initiaattori-
symbolireferenssit (bwrite/strategy/ddstrategy/physio → startdma), (2) mekaaninen
cache-op- ja DMA-arm-opcode-census kirjoituspolulla, (3) 3b2-lähdekontraktin
diffi buffer-cache/UFS-metadata-writebackista (source-first). Kaikki osoitteet
tästä imagesta (SHA:t yllä), old-byte-ikkunat mukaan.

## Rajaukset (non-goals)

- EI kernel-muutoksia — speksit + assertit; Fable toteuttaa.
- ISSUE-22 (EFAULT) = ERI, pre-existing bug (esiintyy WT:lläkin) — EI tähän;
  oma jahtinsa (KNOWN-ISSUES ISSUE-22).
- B1 (writethrough) on rautahyväksytty eikä muutu.
- real-060-DC = oma myöhempi milestone.
- DTT0-kavennus (N1/N2) = eri physmap-milestone.

## Hyväksyntäkriteerit

1. Kirjoituspolun DMA-census täydellinen: jokainen host-RAM→levy-siirto joko
   todistetusti kulkee startdma-preparen läpi oikealla pa/len:llä, TAI on
   nimetty kattamattomaksi aukoksi.
2. Todennäköisin root cause nimetty ja perusteltu, ja se selittää juuri
   havaitun signaturen (lyhyt+väärä-checksum+read-error, hiljainen).
3. Korjausspeksi toteutettavissa old-byte-asserttien kanssa; instrumentointi
   erottaa metadata- vs. datakorruption ja sitoo sen DMA-segmenttiin.
4. Tiukempi reprodusointi määritelty fix-verifiointia varten.
5. Kaikki osoitteet verifioitu pinnattua imagea vasten.

## Hyväksyntä korjauksen jälkeen (Fablen sykli, tuleva rautasessio)

Sama kontrollivertailu: -07 WT vs korjattu -b2, `burstloop R>=4` molemmilla.
Vaatimus: korjattu -b2 antaa **0 hiljaista korruptiota >=16 burstissa** (kuten
WT), ennen kuin virtakatkaisu-disk-truthia tai `hat_cm_ram`-flippiä edes
harkitaan tuotantoon.
