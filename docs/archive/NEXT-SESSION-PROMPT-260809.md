# Prompt for the next session — F3 M5: take the 68060 FPSP to hardware

Copy everything between the lines into the new session.

---

Lue ENSIN nämä, äläkä johda mitään niiden ulkopuolelta:
`amix-040-060-port/060-F3-FPSP-PLAN-260807.md` (F3:n suunnitelma, M0–M2b sisällä),
`amix-040-060-port/test-tools/f3-m2b-emu-verify-260808.txt` (M2b:n täysi emulaattorihyväksyntä),
`amix-040-060-port/REALHW-260806-06-ACCEPTANCE.md` (edellinen rautahyväksyntä = baseline).
Taustaksi `docs/060-CAMPAIGN-PLAN-260805.md` ja
`amix-kernel-analysis/vm-map/F3-FPSP060-CALLOUT-CONTRACT.md` (Codexin kontrakti).

**Tilanne yhdellä rivillä:** 68060:llä on nyt FP-tukipaketti. `fmovecr` palauttaa oikean vakion,
`fsin/fetox/flogn` emuloituvat bitilleen oikein, `x = 1.0;` ei enää tapa prosessia. Kaikki tämä on
mitattu **emulaattorissa molemmilla CPU:illa**; **raudalla ei mitään.**

**TÄMÄN SESSION TYÖ: M5 eli rautahyväksyntä.**

## Puun tila

* `FPSP060` on **oletuksena 1**. `sh relink-040.sh` tuottaa paketin sisältävän imagen; uudelleen
  käännetty image erosi hyväksytystä **kahdella tavulla**, jotka molemmat ovat build-id:n numeroita.
* Escape hatch on yhä yksi muuttuja: `FPSP060=0 sh relink-040.sh`.
* Rautabaseline on `68060-260806-06`. **Jos M5 kaatuu, palaa siihen** — älä debuggaa raudalla
  pitkään, vaan tuo oire emulaattoriin.
* SetPatch AmigaOS:ssä ENNEN `unix_boot`ia on 060:n esiehto.

## Ajolista

1. **Identiteetti ja laskurien osoitteet.** `uname -a`; laske `f60`-lohko ITSE tälle imagelle
   (`0x08000000 + textsize + nm(.data)`), lue `f60_magic` = `46503630` ennen kuin uskot mitään muuta.
2. **`fp060probe`.** Odotus: 7/7 `OK`, `0 ulp`, `bad=0`. Laskurit: `entry 4 / mem 4 / done 4`,
   `real 0`, `access 0`, `memfail 0`, `kvp_vec[11]` ei liiku.
3. **`fputest060` (-O-build!) Test A ja Test C.** `-O0` EI tuota `fmovecr`ia päähaaralle eikä siis
   mittaa mitään — tarkista disassemblysta ennen ajoa että `fmovecrx #50` on `forktest`issä.
4. **Motorolan `ftest060 all` — tämä on session tärkein UUSI mittaus.** Emulaattori ei pysty
   ajamaan sitä: sen FPU ei säilytä `DEF_FPREGS`in laajennettua NaNia (`7FFF0000 FFFFFFFF FFFFFFFF`
   → `3FFF0000 00000000 00000000`) **ennen yhtään trappia**, ja jokainen alitesti alkaa siitä
   latauksesta. Aja ensin `ftunimp0`: jos se sanoo `nanbad=0`, rauta pystyy siihen mihin emulaattori
   ei, ja `ftest060` alkaa vasta silloin kertoa FPSP:stä. Odotus raudalla:
   * `unimp` = **passed**;
   * `enabled` = kuusi ryhmää, ja **nämä ovat täysin mittaamattomia** — `f60_arith_n` on ollut 0
     koko ajan, koska emuloitu FPU ei nosta sallittuja FP-poikkeuksia. Tässä nähdään ensimmäistä
     kertaa ajavatko `Lco_fparith`in prelude ja SIGFPE-reitti;
   * `main` = kuolee vektoriin 60 (M3, ei kytketty). Odotettu.
5. **Patteristo 11/11** (`test-tools/batteryrun6.sh` — laske ankkurit uudelleen imagelle!) ja
   **burst** (`burstloop.sh` on koneella, ei repossa; emulaattorissa sitä ei voi ajaa koska vieraan
   levy nollataan joka bootissa — tämä on syy miksi burst puuttuu M2b:stä).
6. **Virtakatkaisu-levytotuus**, kuten `-06`:ssa.
7. **Attribuutio, joka on ollut auki M0:sta asti:** aja `wolf3d` ja `xv` tämän kernelin alla ja
   katso `kvp_vec[]`. Koko F3 alkoi siitä että niiden SIGSYS oli *yhteensopiva* puuttuvan FPSP:n
   kanssa mutta todistamaton. Nyt on sekä probe että paketti — kysymys ratkeaa yhdellä ajolla.
8. Kirjaa `REALHW-<id>-ACCEPTANCE.md`.

## Mitä on auki F3:ssa M5:n jälkeen

* **M3 = vektorit 55 ja 60** (`_060_fpsp_unsupp`, `_060_fpsp_effadd`). Denormaalit ja packed decimal.
  Motorolan `ftest060 main` kuolee juuri tähän, joten kytkentä on suoraviivainen ja mitattavissa
  heti. Tee vasta jos M5 vaatii tai ftest sitä pyytää.
* **M4 = IEEE-vektorit 48–54 060:llä.** Call-out-taulu on jo olemassa; tämä on `fpsp_vec48` jne.
  -tyylinen `cputype == 60` -haara.
* `_060_real_fpu_disabled` on toteutettu Motorolan politiikalla mutta `f60_fpudis_n` on aina 0 —
  jos se joskus liikkuu, jokin sammuttaa FPU:n selän takana ja se on tutkittava, ei siedettävä.

## Mitä EI kuulu tähän sessioon

* **68040-rautasessio** — `docs/archive/NEXT-040-SESSION-RUNLIST.md`, vaatii A3640-kortinvaihdon.
* **ISSUE-42** (`wb040_replay`in fault-propagointi) — 040-työtä, samaan niputukseen.

---

# Työtavat — nämä unohtuvat joka kerta ja niihin palaa aikaa

Lue `docs/archive/NEXT-SESSION-PROMPT-260808.md`:n vastaava osio kokonaan; se pätee yhä. Lisäksi 8.8. opitut:

1. **Toinen sessio voi pitää tftp-porttia.** `pgrep -af tftp_onesock` ei riitä, koska kopiot voivat
   olla eri nimillä eri scratchpadeissa — testaa portti (`ss -uln`) ja nosta oma kopio vapaaseen.
2. **Pitkä komentorivi telnetissä katkeaa hiljaa** — sentinel jää tulostumatta ja se näyttää
   timeoutilta. Pilko: ensin siirto, sitten ajo, sitten luku.
3. **`grep -i "a\|b"` ei toimi AMIXissa** (ei `\|`, ei `-E`, ei `-e`). Yksi kuvio per kutsu. Tämä
   maksoi taas kerran: patteriston tulos näytti tyhjältä vaikka se oli 11/11.
4. **`scan060.py` raportoi datasta false positiveja.** `ftest060`issä kaksi `movepl`-osumaa olivat
   merkkijono `"\tNon-maskable overflow..."`. Tarkista osoite `objdump -s`illa ennen kuin uskot.
5. **Testibinäärin optimointitaso on osa mittaria.** `fputest060` ilman `-O` ei sisällä
   `fmovecr`ia päähaarassa, joten se "läpäisee" ilman että FPSP:tä kutsutaan kertaakaan. Laskurit
   paljastivat sen (`f60_entry_n` ei liikkunut) — ilman niitä olisin raportoinut väärän voiton.
6. **Kun vendorin testi sanoo "failed", älä usko eikä epäile — replikoi alitesti.** `ftunimp0`
   kirjoitettiin juuri tähän ja siirsi syyn meidän glueltamme emulaattorin FPU:lle yhdellä ajolla.

## Säännöt

Samat kuin `docs/archive/NEXT-SESSION-PROMPT-260808.md`:ssä. Erityisesti:
1. Jokainen 060-muutos pysyy `cputype`-gatettuna, 040-polku tavulleen sama, ja molemmat emu-CPU:t
   boottaavat ennen rautabootia. **Tämä on nyt todistettu laskurilla eikä katsomalla:** emu-040:llä
   jokainen `f60_*` on 0 patteriston ja proben jälkeen.
2. Selviytyminen ei ole oikeellisuus. `fp060probe` vertaa nyt IEEE-754-bittikuvioon.
3. Mittari on verifioitava ennen kuin sen lukemaan uskoo.

---
