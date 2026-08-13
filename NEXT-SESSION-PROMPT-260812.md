# Prompt for the next session — ISSUE-43: the 68060 FP state path

Copy everything between the lines into the new session.

---

Lue ENSIN nämä, äläkä johda mitään niiden ulkopuolelta:
`kernelsupport/KNOWN-ISSUES.md` **ISSUE-43** (tiedoston lopussa — oire, juurisyy, kaksi
epäonnistunutta korjausyritystä, ja speksattu korjaus),
`amix-kernel-analysis/vm-map/FPU-LAZY-CONTRACT-AUDIT.md` (Codexin auditti, commit `64b55cf` —
**tämä on korjauksen spesifikaatio, älä improvisoi sen ohi**),
`kernelsupport/test-tools/f3-m4-enabled-hw-260811.txt` (kolme mittauskierrosta, myös se missä
olin väärässä).

**Tilanne yhdellä rivillä:** 68060:n FPSP on valmis ja rautahyväksytty — Motorolan `ftest060
main` ja `unimp` läpäisevät kokonaan, ja kuudesta sallitusta IEEE-poikkeusluokasta **viisi on
bitilleen oikein raudalla**. Kuudes, divide-by-zero, menettää fp0-7:n signaalin yli, ja syy on
**yhden tavun siirtymävirhe stock-kernelissä**.

## TÄMÄN SESSION TYÖ: ISSUE-43:n korjaus, kohdat 2–4

Kohta 1 on tehty (`c13d3b8`). Jäljellä auditin luvusta "D. Contract-derived CPU-specific state
implementation":

2. **68060 `fpu_save` / `fpu_restore` testaamaan `fp+0x72`** (ei tavua 0), `UFPRWRT`-semantiikka
   ja peritty haarajärjestys **ennallaan**. Älä aseta äläkä nollaa `UFPRWRT`:tä uusissa haaroissa.
3. **Täysi 12 tavun 68060-reset-frame** `fpu_setup`-polkuun.
4. **68040-polku tavulleen ennallaan.**

Tämä on polku jota **jokainen kontekstinvaihto ja jokainen signaali** kulkee. Se on jo kerran
rikottu tässä (5/6 → 0/6), joten:

* `cputype`-gate, ja 040-haaran käskykoodit tavulleen samat kuin stockissa;
* oma laskuri uudelle haaralle, tai et tiedä ajoiko se;
* **molemmat emu-CPU:t ennen rautaa** — tällä kertaa oikeasti, edellisessä sessiossa rauta ehti
  ensin kahdesti.

## Puun tila

* `build/unix-040` = **`68040-260811-06`**, reloc `TOTAL complaints: 0`. Motorolan prelude
  palautettu, oma virheellinen vahti purettu. Tämä on hyvä lähtökohta.
* **Raudalla ajaa `-05`**, joka on toiminnallisesti sama (5/6). `-06` on kääntämättä raudalle.
* Puu puhdas, kaikki committoitu. Viimeisin: `bd92206`.

## Hyväksyntä — mitä pitää mitata, ja mitä lukemien pitää olla

Mittari on **`test-tools/fpenab060`**, joka on jo kirjoitettu ja rautatodistettu. Se ajaa yhden
lapsen per luokka ja vertaa bittikuvioita.

```
odotus korjauksen jälkeen:   FPENAB060 bad=0    (nyt bad=1, vain DZ)
DZ v50:  fp0 40000000:80000000:00000000   fpsr 02000410   fpiar = käskyn oma osoite
viisi muuta:                  ennallaan bitilleen
uusi haaralaskuri:            liikkuu   <- ilman tätä korjaus ei ajanut
emu-040:                      kaikki f60_* = 0, patteristo 11/11
```

Regressiot samalla bootilla: `fp060probe` `bad=0`, `ftest060 unimp` `died=0`,
`ftest060 main` neljä alitestiä **passed**, `isp61ea` `bad=0`.

---

# Työtavat — nämä maksavat aikaa joka kerta jos ne pitää löytää uudestaan

## Osoitteet

**Laskuriosoitteet muuttuvat JOKA KÄÄNNÖKSESSÄ.** Laske ne itse:
`0x08000000 + textsize + nm(.data offset)`, ja **lue magia ensin**:

```sh
TEXT=$(m68k-linux-gnu-size build/unix-040 | awk 'NR==2{print $1}')
v=$(m68k-linux-gnu-nm build/unix-040 | awk '$3=="f60_magic" && $2 ~ /[DdBb]/ {print $1}')
printf "0x%08X\n" $((0x08000000 + TEXT + 0x$v))     # pitää lukea 46503630 = "FP60"
```

`isp61_magic` = `49363121`, `segvn_prot_magic` = `53564e21`. Jos magia ei täsmää, **kaikki muut
lukemat ovat roskaa** — tämä on osunut tässä projektissa useammin kuin kerran.

## Kääntäminen

```sh
export PATH=/home/asokero/opt/amix-cross/bin:$PATH
sh relink-040.sh                     # FPSP060 = 1 oletuksena
```

* Reloc-validoinnin on sanottava **`TOTAL complaints: 0`**.
* **⚠ relink EI kaadu assembler-virheeseen.** Se jatkaa ja linkittää stock-rungon. Varmista aina
  `nm`:llä että symboli todella vaihtui:
  `m68k-linux-gnu-nm build/unix-040 | grep -w fpu_save` — jos se on `0x132`, override EI ole mukana.
* `prototypes/*.s` käännetään **`m68k-cbm-sysv4-gcc`**illa → **immediate on `&`, ei `#`**
  (`btst &0,...`, `cmpil &60,...`). `#` antaa "operands mismatch".
* `test-tools/*_asm.s` käännetään **`m68k-linux-gnu-gcc -x assembler-with-cpp`**illa (siellä `#`
  toimii) ja linkitetään `m68k-cbm-sysv4-gcc`illa. Sekoitus on tämän repon vakiokäytäntö.
* **cpp-makron parametria ei saa nimetä rekisterin mukaan:** parametri `fpcr` korvautuu myös
  `%fpcr`:ssä. Äläkä välitä immediatea makroparametrina — `#enab` muuttuu symboliviitteeksi.

## Testibinäärit — käännösohjeet, jotta ei tarvitse kokeilla

```sh
SP=<scratchpad>
# 060-mittarit (ristikäännös, lähde sanoo -m68020 -m68881)
m68k-cbm-sysv4-gcc -m68020 -m68881 -O -o $SP/fp060probe test-tools/fp060probe.c
m68k-cbm-sysv4-gcc -m68020 -m68881 -O -o $SP/fputest060 test-tools/fputest060.c
# asm + C -parit
m68k-linux-gnu-gcc -m68060 -c -x assembler-with-cpp -o $SP/x.o test-tools/fpenab060_asm.s
m68k-cbm-sysv4-gcc -m68020 -m68881 -O -o $SP/fpenab060 test-tools/fpenab060.c $SP/x.o
# ftest060 on valmiina: build/ftest060 (build-ftest060.sh)
```

**Argumentit, jotka on helppo unohtaa ja jotka tekevät ajosta merkityksettömän:**

* `fputest060 fork` — ilman `fork`ia Test C **ei aja** ja laskurit eivät liiku.
* `fpenab060 DZ` — yksi luokka kerrallaan; ilman argumenttia kaikki kuusi.
* `ftest060 main` | `unimp` | `enabled`.
* `isp61ea` — ei argumentteja.

## Emulaattori

```sh
sh emu-reset-boot.sh 060 /tmp/emu060.log build/unix-040     # 040 | 060
```

Boottiin ~100–120 s. Vieraan levy nollataan joka ajolla → siirrä binäärit uudelleen.
Telnet 2323 **ei vastaa** ennen kuin vieras lähettää paketin ulos:

```sh
cd test-tools
python3 sendkeys.py 'root' RET ; sleep 8
python3 sendkeys.py 'ping 10.0.2.2' RET ; sleep 12
python3 emu.py 'uname -m'
```

* **Jos näppäimet eivät mene perille**, aktivoi ikkuna ensin:
  `DISPLAY=:1 xdotool windowactivate $(DISPLAY=:1 xdotool search --name Amiberry | head -1)`.
* **`emu.py`:ssä ei ole `--timeout`ia** ja sen komentoraja on 120 s → pilko pitkät odotukset
  useaksi `sleep 100`-komennoksi samaan kutsuun.
* Ruutukaappaus vain Amiberryn ikkunasta, ei `-window root`.

## Rauta

* `10.0.10.10`, root, password in `local/secrets.env`. Kirjoita `hw.py` scratchpadiin (`test-tools/emu.py` + salasana,
  `HOST=10.0.10.10`, `PORT=23`, `--timeout`-tuki). **Älä committoi sitä.**
* Bootin jälkeen ping vastaa ennen telnetiä — **odota porttia 23**, älä pingiä.
* `/kpeek` ja `/pgc` säilyvät juuressa; `/tmp` tyhjenee joka bootissa (`cp /kpeek /tmp/kpeek`).
* tftp: `tftp 10.0.10.182 1071 < t.in`, **`binary` ensin**, komennot tiedostosta.
  **Portit 1069 ja 1070 ovat usein varattuja toisilta sessioilta** — testaa `ss -uln`, älä
  `pgrep`. Oma kopio: `sed 's/^PORT = 1069/PORT = 1071/' test-tools/tftp_onesock.py`.
* NAS ei säily bootissa: `mount -F nfs nasu:Public /mnt/nasu`. Se on myös tapa saada iso tiedosto
  koneelta POIS (tftp-palvelin vain tarjoilee).

## Mittaaminen — ansat jotka ovat oikeasti laukenneet

1. **AMIXin `grep` ei tue `-E`, `-e` eikä `\|`.** Yksi kuvio per kutsu. Tämä on maksanut aikaa
   kolmesti, viimeksi 11.8.
2. **Sentinel-kaiku:** komennon kaiku sisältää sentinelin. `hw.py`/`emu.py` hoitavat sen
   lainausjaolla; jos kirjoitat oman pollin, älä hae kuviota jonka komentorivi sisältää.
3. **Irrotettu ajo:** `(nohup sh -c "sh /tmp/x.sh > /tmp/x.log 2>&1" &)`. **Varmista että
   lokitiedosto ilmestyy** — mutta jos se ei ilmesty, tarkista myös **kirjoittaako skripti eri
   nimellä** kuin luulet (11.8.: ajo oli terve, nimi oli vanha).
4. **Uudelleenosoitettu patteristoajuri: auditoi JOKAINEN osoite `nm`:ää vasten**, ei vain niitä
   joita muokkasit — ja tarkista myös lokin nimi ja sentinel. Substituutio on juuri se paikka
   jossa vanhentunut osoite selviää hengissä.
5. **Patteristo EI ole mittari FP- eikä ISP-yksiköille.** Sen `MUL64` maksaa nolla vektori-61-
   trappia ja koko ajo nolla FP-trappia. Regressioverkko, ei mittari.
6. **Emulaattori ei nosta sallittuja FP-poikkeuksia lainkaan.** M4 on siellä *harjoittamaton*,
   ei läpäisty. Kaikki `enabled`-luokkien verdiktit ovat raudan velkaa.
7. **Emulaattorin FPU ei säilytä `DEF_FPREGS`in laajennettua NaNia**, joten Motorolan `ftest` ei
   voi läpäistä siellä. Älä lue sen "failed" FPSP:n viaksi.

## Säännöt

1. **Lue sopimus ennen kuin kirjoitat käskyn.** Tässä sessiossa kaksi korjausyritystä
   epäonnistui, ja molemmat siksi että päättelin merkityksen koodin muodosta: lipun semantiikan
   ja kehyksen tavusiirtymän. Kumpikin oli luettavissa lähteestä.
2. **Ennakkorekisteröi odotus ennen ajoa.** Se on toistuvasti erottanut "korjaus toimi" ja
   "koodi ei ajanut" toisistaan — ja kerran se kertoi että hypoteesini oli väärä, mikä oli
   ajon arvokkain tulos.
3. **Mittari on verifioitava ennen kuin sen lukemaan uskoo.** Väärä tavu antaa uskottavia lukuja.
4. Jokainen 060-muutos `cputype`-gatettuna, 040-polku tavulleen sama, molemmat emu-CPU:t ennen
   rautaa.

---

# Muu auki oleva, prioriteettijärjestyksessä

* **ISSUE-43** — tämän session työ, yllä.
* **RAM > 32 MB:** kone tarjoaa **48 MB kahdessa alueessa** (32 MB @`0x08000000` + 16 MB
  @`0x07000000`, B on A:n ALAPUOLELLA) ja AMIX laskee vain sen johon kerneli on ladattu.
  Codexin analyysi valmis: `vm-map/RAM-BEYOND-16MB-ANALYSIS.md` — **teknistä kattoa ei ole**,
  alue B jää pois koska `MemHeader` vie alueen alusta 32 tavua ja nykyinen algoritmi ei tunnista
  A:ta ja B:tä yhtenäiseksi. Rajattu boot/startup-muutos, EI pelkkä laskurin kasvatus.
* **Zorro III:** mitattu 10.8., palkinto on aito — Z2-aukko **3,09 MB/s vs paikallinen 28,66
  MB/s**, ja leveystesti sanoo että **väylä on kylläinen** eikä serialisointi.
  `Z3-BUSBENCH-Z2-MEASUREMENT-260810.md`. Järjestys: VA2000-ajurin osoitekorjaus
  (va2000-amix-repo) → testaa **Z2-tilassa** → `Lcm_sel`-framebufferluokka → vasta sitten
  firmware. `Lcm_sel` ei ole itsenäinen voitto Z2:lla — se on mitattu.
* **ISSUE-42** — 040:n hiljaa revennyt store. Vaatii A3640-kortinvaihdon;
  `NEXT-040-SESSION-RUNLIST.md`.
* **`/proc prsetfpregs` ei aseta `UFPRWRT`:tä** siinä missä `procxmt` asettaa — latentti aukko,
  löytyi ISSUE-43:n auditin sivutuotteena.
* **Ylläpidettävyys:** 69 override-yksikköä + 43 patch-skriptiä stock-binäärin päällä.
  Lähdekoodin palautus on arviolta 20–30 sessiota eikä ole aloitettu.
