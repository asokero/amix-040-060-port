# Prompt for the next session — one hardware session for the `260806-06` line

Copy everything between the lines into the new session.

---

Lue ENSIN nämä kolme, äläkä johda mitään niiden ulkopuolelta:
`kernelsupport/SEGVN-PAGEPROT-PANIC-260806.md` (ISSUE-41, mitä korjattiin ja miksi),
`kernelsupport/SIGINFO-TRANSLATION-260806.md` (F4, 060:n far-sivun signaalipolku),
`kernelsupport/REALHW-F2-ACCEPTANCE-260806.md` (mitä rauta tällä hetkellä takaa).
Taustaksi `060-CAMPAIGN-PLAN-260805.md` §0b (tilanne F0–F2:n jälkeen) ja Codexin
`amix-kernel-analysis/vm-map/XPAGE-FPROT-CONTRACT.md`. 040-portti ja ISSUE-40 ovat suljettuja
eikä niitä avata tässä sessiossa.

**Tilanne yhdellä rivillä:** A3000:ssa on 66 MHz 68060, F2 (vektori 61) on rautahyväksytty ja
**koneessa on taas toimiva GCC** — mutta rauta ajaa yhä `68060-260806-02`:ta, koska sen jälkeen
löytyi ja korjattiin stock-AMIXin VM-vika joka kaataa koneen millä tahansa osasivun
`mprotect`illa, ja se korjaus on toistaiseksi vain emu-verifioitu.

**TÄMÄN SESSION TYÖ: yksi rautasessio, joka nostaa rautabaselinen `260806-02` → `260806-06`.**
Ei uutta kernelikoodia ennen kuin tämä on ajettu — kaksi yksikköä odottaa raudan tuomiota.

## Kerneli

`build/unix-040`, build id **`68040-260806-06`**, textsize **`0xe4bb8`**.
Bannerin ja `uname -m`:n PITÄÄ raudalla lukea **`68060-260806-06`** — emulaattorin 040-konfigilla
sama image lukee `68040-260806-06`, eikä se ole eri image. Mekanismi (`prototypes/inituname040.s:32`):
`stamp_buildid.py` kirjoittaa aina staattisen `" 68040-"`-etuliitteen, ja kerneli kääntää bootissa
tavun `buildid+4` kuutoseksi jos `cputype` on 60. Etuliite on siis **CPU:n mittari, ei imagen** —
älä siis päättele `strings`illä imagesta mitä banneri tulostaa, se ei erota näitä.
Boottaa `unix_boot040`:llä.
**SetPatch on ajettava AmigaOS:ssä ENNEN `unix_boot`ia** — muuten AttnFlags ei kerro 060:stä,
loader kirjoittaa `cputype = 40` ja kerneli paniikkaa `ptestr`:ssä. Tämä on mitattu, ei arvaus.

Mitä `-06` sisältää `-02`:n päälle (kaksi yksikköä, molemmat emu-verifioituja kummallakin CPU:lla):
1. `prototypes/segvn_prot040.s` — SVR4:n per-sivu-suojaustarkistus takaisin `segvn_faultpage`iin.
   **Ei cputype-gatettu**, koska vika koskee molempia prosessoreita. ISSUE-41.
2. `wb040.s`:n `Lu_siginfo` — far-sivun `faultcode_t` → `u_trap`in `k_siginfo_t`. Vain
   käyttäjäpolku; `krnxmemflt` koskematta.

Laskuriosoitteet (`0x08000000 + textsize + nm(.data)`), **lue magic-sana ensin**:

```text
segvn_prot_magic 0x080FD194 (0x53564E21)   segvn_prot_pp_n 0x080FD198   segvn_prot_n 0x080FD19C
isp61_magic      0x080FD200 (0x49363121)   cputype 0x080FD1F8 (0x3c)    pcr_boot 0x080FD1FC
x60-lohko        0x080FD158, 13 longia (fmt4,ma,compat,rd,wr,farfail,fa,fslw,fprot,ok,fail,afret,psr2)
x60_far_addr     0x080FD18C                x60_siginfo_n 0x080FD190
hat_cm_ram       0x080FCEB8 (0x20)         fpu_present 0x080E9B94
cb_icode_calls   0x080FD614   kdbg_on 0x080FD61C   hat_pfnmiss_n 0x080FD620   hat_badaslot_n 0x080FD624
i39_magic        0x080FD650   i40_magic 0x080FD688   ptd_magic 0x080FD6BC (0x50544421)
ptd-lohko        0x080FD6BC..0x080FD6E4 (11 longia)
```

`kpeek` ottaa osoitteen **ilman `0x`-prefiksiä**: `/kpeek 080FD194 5`.

## Ajolista järjestyksessä

1. **Banneri, `uname -m`, `cputype` = 0x3c, `segvn_prot_magic`, `isp61_magic`.** Jos magic ei
   täsmää, osoitteet ovat vanhat — pysähdy siihen.
2. **`protfault` (a, b, c).** Session tärkein mittaus. Ennalta kirjattu:
   * **a ja b PASS (SIGSEGV)** — b on se tapaus joka *kaatoi koneen* ennen ISSUE-41:n korjausta,
     eikä siinä ole sivunylitystä.
   * **c PASS (SIGSEGV)** — emussa 060 läpäisee, mutta tämä on ensimmäinen kerta oikealla
     piillä: se on samalla `M68060-XPAGE-ACCEPTANCE.md`:n puuttuva testi 3.
   * `segvn_prot_n` +1 (tai +2 jos c menee saman polun kautta), `x60_siginfo_n` +1,
     `x60_far_addr` = suojattu sivu, `x60_last_afret` = **4** (as_fault palauttaa itse FC_PROT).
   * `x60_fprot_fail_n` **pitäisi pysyä 0** — se on verify-then-fail-varakeino jota ei enää
     tarvita. Jos se liikkuu raudalla, `as_fault` käyttäytyy siellä eri tavalla kuin emussa ja
     se on oma löydöksensä.
3. **Patteristo** (`mkall.sh` gcc:llä + `batteryrun4.sh`, uudelleenosoitettuna tälle imagelle).
   Ennalta kirjattu: **11/11**, `hat_pfnmiss_n` **+2 tarkalleen**, `i40_bad/err` ja
   `ptd_keep0/keepn/meta/badlink` nollassa. Ja ratkaiseva pari: **`segvn_prot_pp_n` selvästi
   yli tuhat, `segvn_prot_n` vain se yksi tarkoituksellinen hylkäys.** Jos `pp_n` on 0, koko
   11/11 on tyhjä tulos — tarkistus ei ajanut.
4. **Burst** (`burstrepeat`, 2 suitea riittää regressioksi). Ennalta kirjattu **96/96 per suite**.
   Raudalla `payload.bin` on olemassa ja summa on `1570 8192`; emussa se luotiin uudelleen ja
   kuvio oli `0 8192` — älä sekoita näitä.
5. **Virtakatkaisu-levytotuus**, jos aikaa on. Se on ainoa hyväksyntäkriteeri jota ei ole ajettu
   kertaakaan tälle linjalle.

## Jos kaikki menee läpi

`260806-06` korvaa `260806-02`:n rautabaselinena, ISSUE-41 sulkeutuu raudalla ja XPAGE-hyväksyntä
on kokonaan katettu. Kirjaa `REALHW-260806-06-ACCEPTANCE.md` ja päivitä muisti.

## Säännöt (samat kuin koko kampanjassa, plus kaksi uutta)

1. Prosessorinvaihto on yksisuuntainen per sessio: jokainen 060-muutos pysyy `cputype`-gatettuna
   niin että 040-polku on tavulleen sama — **paitsi `segvn_prot040.s`, joka on tarkoituksella
   yhteinen**, koska vika koskee molempia. Molemmat emu-CPU-konfiguraatiot boottaavat ennen
   jokaista rautabootia.
2. Laske laskuriosoitteet joka imagelle uudelleen ja lue magic-sana ensin.
3. "Se boottasi" ei ole todiste siitä että polku ajettiin — laskurin on näytettävä se.
   `segvn_prot_pp_n` on tässä sessiossa juuri se laskuri.
4. Älä niputa mount+kopiot+käännös yhteen `real.py`-komentoon. `AMIX_CMD_TIMEOUT=900`
   käännöksille, pitkät ajot irrotettuna: `(nohup sh -c "sh /tmp/x.sh > /tmp/x.log 2>&1" &)` —
   pelkkä `&` lopussa rikkoo sentinelin ja komento jää hiljaa ajamatta.
5. `/tmp` tyhjenee joka bootissa; `/kpeek` ja `/pgc` säilyvät juuressa;
   `mount -F nfs nasu:Public /mnt/nasu` ei säily.
6. Konsoli sanoo asioita joita laskurit eivät — pyydä kuva jos jokin näyttää oudolta.
   Nimenomaan: `NOTICE: User BUS ERROR ... FAULT:1` tarkoittaa että signaalinumero ei kulkenut.
7. Kirjaa kumotut hypoteesit. Tässä sessiossa niitä syntyi kolme yhdessä illassa ja jokainen
   kavensi ongelmaa.
8. **UUSI: `xpagetest` T3 on poistettu käytöstä** — se niputti kolme eri vikaa ja kaatoi koneen.
   Käytä `protfault a|b|c`. Jokainen tapaus on oma lapsiprosessi ilman käsittelijää: lapsen on
   tarkoitus kuolla, ja kuolintapa on tulos.
9. **UUSI: `grep -E` ja `grep "a\|b"` eivät toimi AMIXin grepissä.** Yksi kuvio per kutsu.
   `sed`in osoitealueet `/x/,$p` menevät myös sekaisin — käytä `head`/`tail`.

## Avoimet asiat, jotka EIVÄT kuulu tähän sessioon

* **ISSUE-42** — `wb040_replay` vie kirjoituksen läpi suojatulle sivulle 68040:llä
  (`protfault c` = protection bypass siellä). Kontraktikysymys, ei koodikysymys:
  *pitäisikö replayn konsultoida suojausta, vai pitäisikö write-backit hylätä kun fault on
  todettu fataaliksi?* → Codex-analyysi samalla kaavalla joka toimi kahdesti 6.8.
* Kampanjan **F3** (vektori 11 / 060 FPSP, ISSUE-34b) ja **F4** (060-D: branch cache; huomaa
  että ESS on jo päällä, joten Dhrystonen 2,0× kaipaa yhä selitystä).
* Burst emu-060:llä (ajettu vain 040:llä).

---
