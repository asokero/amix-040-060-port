# Prompt for the next session — F3 M2b: finish the 68060 FPSP

Copy everything between the lines into the new session.

---

Lue ENSIN nämä kolme, äläkä johda mitään niiden ulkopuolelta:
`kernelsupport/060-F3-FPSP-PLAN-260807.md` (F3:n suunnitelma, M0/M1/M2a-tulokset sisällä),
`kernelsupport/060-FPU-STATE-260807.md` (miksi F3 on olemassa — mitattu SIGSYS-mekanismi),
**Codexin vastaus tehtävään `kernelsupport/F3-CALLOUT-CONTRACT-CODEX-TASK.md`** (call-out-kontrakti).
Taustaksi `060-CAMPAIGN-PLAN-260805.md` ja `REALHW-260806-06-ACCEPTANCE.md`.

**Tilanne yhdellä rivillä:** 68060:llä ei ole FP-tukipakettia, joten `x = 1.0;` riittää tappamaan
prosessin (`fmovecr` → SIGSYS). Motorolan M68060 FPSP on rakennettu ja kytketty — vektori 11 menee
pakettiin — mutta AMIX-puolen call-outit ovat väärin ja ensimmäinen loukkaava käsky kaataa koneen.

**TÄMÄN SESSION TYÖ: M2b eli oikeat call-outit, Codexin kontraktivastauksen pohjalta.**

## Mistä jatketaan

| vaihe | tila |
|---|---|
| M0 vektoriprobe | ✅ `prototypes/kvecprobe040.s`, mittasi `kvp_vec[11]` 0→4 |
| M1 paketti | ✅ `build-fpsp060.sh` → `fpsp060.o` 53 KiB / `pfpsp060.o` 27 KiB |
| M2a kytkentä | ⚠ todistettu toimivaksi, **paniikkaa** — ks. alla |
| M2b call-outit | ⏳ tämä sessio |
| M3/M4 | vain jos mittaus vaatii |

**M2a:n paniikki, joka on M2b:n lähtökohta:**

```text
PANIC: KERNEL FAULT psw=0x2004, pc=0x80E6C6E, fmt=0x2, vector=0x6 (CHK, CHK2)
PC = fpsp060_image + 0x1fb6   -> purkautuu DATANA, ei koodina
```

Johtava epäilty on **omissa stubeissani**: `_060_real_*` päättyvät `jmp nullvect`iin, mutta
`nullvect` on CPU:n sisääntulo joka odottaa **raakaa poikkeuskehystä `(sp)`:ssä** ja lukee
`sp@(60)`. Call-outin ajankohtana pinossa on paketin kehys. Muististubit epäonnistuvat
tarkoituksella (`d1 != 0`), mikä ajaa paketin `_060_real_access`iin heti.

## ⚠ Puun tila — lue tämä ennen kuin käännät mitään

* **`FPSP060` on oletuksena 0.** Oletusbuild EI sisällä 060-pakettia ja on turvallinen.
  Opt-in: `FPSP060=1 sh relink-040.sh` — **vain emulaattoriin**, ei raudalle ennen kuin M2b on
  hyväksytty.
* 060-haara `fpsp_vec11`:ssä on `#ifdef HAVE_FPSP060` -vartijan takana, ja relink määrittelee sen
  vain kun paketti oikeasti linkitetään. Ilman vartijaa `FPSP060=0`-build jätti `jmp
  fpsp060_vec11`in **ratkaisemattomaksi** (reloc-validaattori: 1 valitus) — 060 olisi hypännyt
  toteuttamattomalla FP-käskyllä tyhjään, mikä on huonompi kuin alkuperäinen SIGSYS.
* Rautabaseline on **`68060-260806-06`** eikä sitä saa vaarantaa. Koneessa on 68060.
* Rauta ajaa parhaillaan käyttäjän itse kääntämää RTG-kerneliä `68060-260807-02`.

## Ajolista

1. **Lue Codexin vastaus ja kirjoita M2b:n muotoilu siitä**, älä omista muistikuvistani.
   Kysymykset olivat: missä tilassa `_060_real_*` saavutetaan (Q1), mitä `_060_real_access`in on
   toimitettava (Q2), miten SVR4-kernelissä reititetään signaaliin (Q3), puuttuuko sisääntulosta
   setup kuten CACR (Q4), ja täysi vai supistettu paketti (Q5).
2. **Muistiperhe ensin** (11 funktiota). Sopimus on jo tiedossa eikä sitä tarvitse selvittää:
   `a0` = osoite, `a6@(0x4)` bitti 5: 1 = supervisor / 0 = user, `d0` = data, `d1` = 0 onnistui.
   AMIX-toteutus on `moves` + `u_nofault`-landing pad, eli `Lwb_do`:n kuvio `wb040.s`:ssä.
3. **`real_*`-ulostulot** Codexin vastauksen mukaan.
4. **Mittaa `fp060probe`lla.** Ennalta kirjattu M2b:lle: `fsin/fetox/flogn/fmovecr` **survive**,
   ja `fmovecr`in kohdalla on tarkistettava **arvo**, ei vain hengissä selviäminen — laajenna
   testiä. Se on `protfault`in opetus: selviytyminen ei ole oikeellisuus.
5. **`fputest060 fork` (Test C) ajautuu loppuun.** Se kuolee nyt ennen ensimmäistä `printf`iä,
   joten FP-kontekstin vaihto kuormassa tulee mitatuksi ensimmäistä kertaa 060:llä.
6. **Motorolan oma `dist/ftest.s`** ristiinkäännettynä.
7. **D2 mittaamalla:** aja `fp060probe` sekä `fpsp060.o`:ta että `pfpsp060.o`:ta vastaan. Niiden
   entry-taulut ovat tavulleen identtiset, joten valintaa EI voi tehdä katsomalla.
8. Patteristo 11/11 ja burst molemmilla emu-CPU:illa, ja **040-polku tavulleen ennallaan**:
   emu-040 boottaa ja kaikki `f60_*`-laskurit pysyvät nollassa.

## Laskurit

`f60_magic` = `0x46503630` ("FP60"), `kvp_magic` = `0x4b565021` ("KVP!"),
`segvn_prot_magic` = `0x53564e21`, `isp61_magic` = `0x49363121`.

`f60`-lohko: `f60_magic, f60_entry_n, f60_mem_n, f60_real_n, f60_access_n, f60_done_n,
f60_reserved_n, f60_last_co`. `kvp`-lohko: `kvp_magic, kvp_on, kvp_n, kvp_user_n, kvp_super_n,
kvp_over_n, kvp_last_vec, kvp_last_pc, kvp_vec[64]`.

**Laske osoitteet ITSE joka imagelle:** `0x08000000 + textsize + nm(.data)`, ja lue magic-sana
ensin. Älä kanna osoitteita tästä dokumentista — textsize muuttuu joka buildissa.

---

# Työtavat — nämä unohtuvat joka kerta ja niihin palaa aikaa

## Kääntäminen

```sh
export PATH=/home/asokero/opt/amix-cross/bin:$PATH   # muuten m68k-cbm-sysv4-gcc ei löydy
cd ~/kehitys/amix-playground/kernelsupport
sh relink-040.sh                    # oletus, EI 060-pakettia
FPSP060=1 sh relink-040.sh          # 060-paketti mukaan (emulaattori!)
```

* Reloc-validoinnin on sanottava **`TOTAL complaints: 0`**. Muu on vika, ei kohinaa.
* Build id kasvaa automaattisesti per päivä. **Banneri kertoo ajavan CPU:n, ei imagea:** sama image
  lukee raudalla `68060-…` ja emu-040:llä `68040-…`, koska `inituname040.s:32` kääntää tavun
  `buildid+4`. `strings`/`nm` näyttää aina `" 68040-"` eikä siis erota näitä.

## Emulaattori

```sh
sh emu-reset-boot.sh 060 /tmp/emu.log build/unix-040    # 040 | 060 | a3640
```

Nollaa levyn golden-imageen ja käynnistää Amiberryn. **Boottiin menee ~100 s.**

* **Base-image on HILJAINEN sarjaportissa** (ei `serdbg`-symboleja). Sarjaloki loppuu riviin
  `image checksum = …` eikä se ole kaatuminen. Älä tulkitse sitä paniikiksi.
* **Telnet 2323 ei vastaa ennen kuin vieras lähettää paketin ulos** (slirp). Kirjaudu konsolilta ja
  pingaa:
  ```sh
  cd test-tools
  python3 sendkeys.py 'root' RET
  python3 sendkeys.py 'ping 10.0.2.2' RET
  python3 emu.py --wait-login
  ```
  `sendkeys.py` käyttää SAKSALAISTA näppäinkarttaa; kirjaimet ja numerot menevät oikein.
* **Ruutukaappaus vain Amiberryn ikkunasta**, ei koko työpöydästä:
  ```sh
  W=$(DISPLAY=:1 xdotool search --name 'Amiberry' | head -1)
  DISPLAY=:1 import -window $W /tmp/shot.png
  ```
  `-window root` kaappaa käyttäjän koko työpöydän — älä tee sitä.
* Vieraan tila **pyyhitään joka ajolla**; siirrä binäärit tftp:llä uudelleen.
* Konsoli kertoo asioita joita laskurit eivät. Jos jokin näyttää oudolta, ota kuva.

## tftp

Isäntä tarjoilee: `python3 test-tools/tftp_onesock.py <hakemisto>` (portti 1069).
**Tarkista ensin `pgrep -af tftp_onesock`** — toinen sessio voi jo pitää porttia; nosta oma
kopio toiseen porttiin (`sed 's/^PORT = 1069/PORT = 1070/'`).

Vieraassa, aina `binary` ensin, ja aja komennot tiedostosta:

```sh
cd /tmp; echo binary > t.in
echo "get x.tar /tmp/x.tar" >> t.in
echo quit >> t.in
tftp 10.0.2.2 1070 < t.in        # emulaattori (slirp)
tftp 10.0.10.182 1070 < t.in     # oikea rauta (LAN; isäntä on 10.0.10.182)
```

Monta tiedostoa: tee tarball isännällä ja pura vieraassa — yksi kierros monen sijaan.

## Oikea rauta

* `10.0.10.10`, root / `REDACTED-see-local-secrets-env`, telnet. Ajuri: kirjoita `hw.py` scratchpadiin (`emu.py` + salasana).
  **Älä committoi sitä** — se kantaa tunnuksen, ja siksi `real.py` ei ole koskaan ollut repossa.
* `/kpeek` ja `/pgc` säilyvät juuressa. `/tmp` tyhjenee joka bootissa. `/payload.bin` on olemassa,
  summa `1570 8192`.
* NAS ei säily: `mount -F nfs nasu:Public /mnt/nasu`.
* SetPatch AmigaOS:ssä ENNEN `unix_boot`ia on **060:n** esiehto, ei 040:n.

## Mittaaminen — nämä ansat maksoivat aikaa 7.8.

1. **Sentinel-kaiku.** `case "$R" in *DONE*)` osui komennon KAIKUUN eikä tulosteeseen, joten
   käännös näytti valmistuvan sekunnissa. Pollaa kuviolla jota komentorivi ei sisällä:
   `tail -1 /tmp/x.log` ja vertaa merkkijonoon.
2. **AMIXin grep ei tue `-E`, `-e` eikä `\|`.** Yksi kuvio per kutsu. `sed`in osoitealueet menevät
   myös sekaisin — käytä `head`/`tail`.
3. **Irrotettu ajo:** `(nohup sh -c "sh /tmp/x.sh > /tmp/x.log 2>&1" &)`. Pelkkä `&` lopussa rikkoo
   sentinelin. **Varmista että lokitiedosto ilmestyy** ennen kuin uskot käynnistyksen onnistuneen.
4. **`scan060.py` lukee DISASSEMBLY-LISTAUKSEN, ei binääriä.** Binäärin antaminen tulostaa hiljaa
   `CLEAN` ja `0 decoded lines`. Oikein: `LC_ALL=C m68k-linux-gnu-objdump -d bin > l.dis` ensin.
   Käytä `LC_ALL=C` kaikissa objdump-putkissa — tulosteet ovat muuten lokalisoituja.
5. **`kpeek` ottaa osoitteen ILMAN `0x`-etuliitettä:** `/kpeek 080FD194 3`.
6. **Peräkkäiset kpeek-luvut eivät ole atominen tilannekuva** — laskurit liikkuvat lukujen välissä
   (näin `kvp_user_n > kvp_n`, mikä on mahdotonta yhtäaikaisesti).
7. **Shellin cwd säilyy kutsujen välillä.** Käytä absoluuttisia polkuja tai `cd` joka kerta.
8. **`build/unix-040` on ET_REL:** raakatavut näyttävät nollia siellä missä on relokaatio. Älä
   päättele hyppykohteita `objcopy -O binary` -tulosteesta linkkaamattomassa kernelissä.

## Säännöt

1. Jokainen 060-muutos pysyy `cputype`-gatettuna niin että 040-polku on tavulleen sama, ja
   **molemmat emu-CPU-konfiguraatiot boottaavat** ennen jokaista rautabootia.
2. Laske laskuriosoitteet joka imagelle uudelleen ja lue magic ensin.
3. "Se boottasi" ei ole todiste siitä että polku ajettiin — laskurin on näytettävä se.
4. Selviytyminen ei ole oikeellisuus. `protfault` päätteli "store onnistui" siitä että lapsi jäi
   henkiin; mittaus osoitti päinvastaista. Mittaa lopputulos, älä johda sitä oireesta.
5. Mittari on verifioitava ennen kuin sen lukemaan uskoo. Emu-040 ei voi erottaa väitettä joka
   koskee 060:tä; `scan060.py` väärin käytettynä sanoo "CLEAN".
6. Kirjaa kumotut hypoteesit. Muutaman jälkeen vaihda lukemiseen tai spesifikaatioon.
7. Älä anna raudalle imagea jota ei ole ajettu molemmilla emu-CPU:illa.

## Mitä EI kuulu tähän sessioon

* **68040-rautasessio** — `NEXT-040-SESSION-RUNLIST.md`, vaatii A3640-kortinvaihdon. Niputettu
  tarkoituksella; älä vaihda korttia yhden kohdan vuoksi.
* **ISSUE-42:n toteutus** (`wb040_replay`in fault-propagointi) — kontrakti on Codexin vastaama,
  mutta se on 040-työtä ja kuuluu samaan 040-sessioon.
* ISSUE-40, ISSUE-41, 040-VM-portti: suljettuja.

---
