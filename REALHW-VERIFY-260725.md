# Rautasession ajolista — 2026-07-25 -linja (A3000 + Mercury 68040)

Tämä on **itsenäinen ajolista**: kaikki mitä sessiossa tarvitaan on tässä
tiedostossa tai nimetyssä repo-artefaktissa. Mitään ei tarvitse rakentaa
sessiossa. Ajojärjestys on tarkoituksella **fail-fast**.

> ## ▶ 2026-07-28: AJANTASAISET ARTEFAKTIT — RTG UUDELLEENLINKITETTY
> **Vaiheet 1–3 on AJETTU JA HYVÄKSYTTY** (27.–28.7., ks. tulokset alempana ja
> `test-tools/realhw-verify-260727.txt`). Tämä taulukko on nyt "mitä koneelle kuuluu",
> ei enää "mitä vietäväksi ensi kertaa".
>
> | Vie tämä | buildid | kokoa (B) | Sisältää |
> |---|---|---|---|
> | `build/unix-040` | **68040-260727-07** | 1716532 | base + FPSP + ISSUE-35 + `sysconfig` (ei probea) |
> | **`build/unix-040-dbg`** | **68040-260727-08** | 1753723 | + probet + signaaliprobe — **testipatteri tällä** |
> | `build/unix-040-rtg` | **68040-260728-01** | 1780070 | + Xsvga (67) **ja** VA2000 (68), ei probea |
> | `build/unix-040-rtg-dbg` | **68040-260728-02** | 1817257 | sama + probet |
> | `build/unix_boot040` | (loader) | 38896 | **pakollinen kaikelle** |
>
> **⚠ MIKSI RTG NUMEROITIIN UUDELLEEN 28.7.** Kaikki aiemmat RTG-kernelit (260727-02/-03 ja
> 260724-09) linkitettiin **ennen ISSUE-35:n korjausta**, koska ne rakennettiin aamulla ja
> korjaus tuli illalla. Käytännön seuraus oli epämiellyttävä: **X11:n ajaja sai samalla
> rikkinäisen NFS-kirjoituksen.** 260728-01/-02 on linkitetty korjatun basen päälle ja
> `nfs_putpage`-pari + `sysconfig` on verifioitu tavuina kaikista neljästä artefaktista.
> Tämä on kolmas kerta kun grafiikkakerneli jäi jälkeen basestaan (vrt. 25.7. läheltä piti)
> — **RTG-kernelit on linkitettävä uudelleen aina kun base muuttuu**, ne eivät ole erillisiä
> tuotteita vaan basen johdannaisia.
>
> Kaikki 260724/260725/260726/260727-0[1-6] -kernelit ovat **historiaa** — älä vie.
>
> ### ⭐ SIGNAALIPROBE — mitä se antaa raudalla ja miten se luetaan
> `prototypes/sigkill_dbg.s` kääri `sigtoproc`in ja tulostaa **`cmn_err`illä, eli teksti menee
> sekä KONSOLILLE että serial-mirroriin** — koneella on serial-USB-kaapeli, joten **kaappaa
> serial**: se on tekstiä, ei valokuvia, eikä konsolin ~40 rivin kierto pyyhi sitä.
> (Korjaus 27.7.: aiempi versio tästä sanoi ettei kaapelia ole. Se oli vanhaa tietoa.)
>
> ```
> DBG SIG sig=<N> pid=<pid> stat=<x> psargs=<komentorivi> uret=<x> uarg2=<x> kcaller=<x> fu=<0|1>
> ```
>
> - **`sig`** = signaali. Kattaa nyt **4–12** (raja nostettiin 11→12 ISSUE-34b:n takia).
> - **`psargs`** = kuka kuoli, komentoriveineen. Tämä yksin nimesi ISSUE-34b:n.
> - **`kcaller`** = kernelin paluuosoite → ratkaise `nm`illä: `kcaller − 0x08000000` =
>   text-offset. Näin `0x0804858C` → `sigaddq+0xaa`.
> - **`fu=0`** = **KERNELI** nosti signaalin, `fu=1` = user-tason `kill()`. Tämä erottaa
>   "kerneli tappoi" ja "joku tappoi" — älä tulkitse ilman sitä.
> - Rajoitettu: **8 ensimmäistä + joka 256:s**, joten silmukka ei tulvi lokia.
> - Lisäksi: `sig==11` (SIGSEGV) laukaisee ISSUE-10:n URP-kävelyn (`SEGVDMP`/`SEGVCHAIN`)
>   ja `sig==9` oman kaappauksensa. Ne ovat vanhaa kalustoa, eivät uusia.
>
> **Kirjaa jokainen `DBG SIG`-rivi sanatarkasti.** Tämän päivän kokemus: kolme aiempaa
> hypoteesia kaatui ja vasta tämä rivi nimesi vian — `psargs` + `kcaller` + `fu` yhdessä.
>
> ### Muutokset ajolistaan alempana
> - Vaiheen 1 kerneli on **260727-01** (`uname -m` varmistaa).
> - `fputest` kuuluu **vaiheeseen 1** — FPU on nyt basessa, ei erillisessä kernelissä.
> - **Vaiheet 2–3 ajetaan SAMALLA kernelillä 260727-02**, ei erillisiä FPSP/Xsvga- ja
>   VA2000-kerneleitä. Molemmat nodet: `mknod /dev/svga c 67 0`, `mknod /dev/va2000 c 68 0`.
> - Vaiheen 9 painetestit (`hat_dup_cow`, `pressure`, `burst4`) ovat nyt emu-ajettuja
>   260726-02:lla: 3/3 PASS, 6/6 ja 24/24 tavuntarkkaa. Raudalla ne ovat vertailukohta,
>   eivät ensiajo. **Uusi `/payload.bin`-baseline: tee 4 MiB tiedosto ja kirjaa sen summa**
>   (emussa `12480 8644`, mutta se riippuu tiedostosta).
> - ⚠️ **ANSA 1 ja 2 alla ovat VANHENTUNEET.**
>
> ### Mitä EI kannata odottaa raudalta
> **ISSUE-34 on 68060-asia eikä koske tätä sessiota** (kone on 68040). Kirjattu koska se
> muuttaa 060-tulkintaa: 68060 tarvitsee 060SP:n **molemmat** puolet (ISP vektorille 61 +
> FPSP vektoreille 11/48–55). Emu-060-tulokset eivät ole väite 060:stä yleisesti.
>
> Emu-savu 260727-02: boottaa, `va2000: no board found` siististi, `/dev/svga0` →
> **Piccolo CardID=3 tunnistuu**, `exectest` PASS. `xinit` toimii (käyttäjän testaama
> 260726-03:lla, sama ajuri). Evidenssit `test-tools/fpsp-into-base-260726.txt` ja
> `issue34-060-unimpl-integer-260727.txt`.

## Miksi tämä ajetaan nyt

25.7. muutettiin **127 tavupatch-sitea + yksi uusi .s-override** UFS-kirjoituspolulla,
exec-polulla ja laitemmapissa (ISSUE-15, 17/18, 27, 28, 30, 31, 32, 33).
**Mikään niistä ei ole ajanut oikealla piillä.** Neljä oli todistettuja vikoja —
yksi oli **kernel-panikki jokaisella /proc-käytöllä**, yksi **deterministinen
voimassa olevan tiedostodatan tuhoutuminen** (24/24 → 0/24).

Historia sanoo, että rauta löytää sen mitä emulaattori ei: ISSUE-8, 11, 13 ja 21
paljastuivat kaikki VAIN oikealla raudalla.

---

## 0. Staus — mitä koneelle viedään

### Kernelit

**Yksi taulukko, ylälohkossa** (`▶ 2026-07-27`). Älä toista sitä tässä — kaksi taulukkoa
ehti eriytyä kertaalleen, ja se on juuri se ansa jota tämä tiedosto yrittää estää.
Lyhyesti: `unix-040` 260727-07, **`unix-040-dbg` 260727-08** (testipatteri),
`unix-040-rtg`/`-rtg-dbg` **260728-01/-02** (Xsvga+VA2000), + `unix_boot040`.

### Testilähteet ja binäärit

| Artefakti | Lähde | Huom |
|---|---|---|
| `test-tools/*.c` (16 ohjelmaa) | repo | käännetään koneessa: `cc -o NIMI NIMI.c` |
| `hat_dup_cow` (8071 B) | `amix-kernel-analysis/runtime-tests/` | **BINÄÄRISIIRTO** |
| `test-tools/issue10-pressure.sh` | repo | = vanha `pressure.sh` |
| burst4 | tämän tiedoston lopussa, kappale "burst4.sh" | kopioi koneelle |

### Siirto

```sh
# AMIX-koneella (mount EI säily bootissa):
mount -F nfs nasu:Public /mnt/nasu
# tai TFTP hostilta (10.0.10.182, portti 1069):
tftp 10.0.10.182 1069
tftp> binary            # ← AINA ensin, myös lähdekoodeille
tftp> get proctest.c /tmp/proctest.c
```

Kernelit menevät AmigaOS-puolelle sinne mistä `unix_boot040` ne lataa.

### Kaksi asiaa jotka maksoivat aikaa emu-sessiossa

- **`/tmp` tyhjenee JOKAISESSA AMIX-bootissa.** Kaiken minkä pitää selvitä
  reboot yli menee `/`-juureen. Kaksivaiheiset testit käyttävät hakemistoa `/pgc`
  (`mkdir /pgc` kerran).
- **Kaksivaiheiset testit vaativat pehmeän `reboot`in** koneen sisältä. Ei `init 6`
  (ISSUE-24: jää runlevel-6-limboon), ei `shutdown -i0` (ISSUE-26: bus-error-silmukka).

---

## Vaihe 1 — VM-korjausten hyväksyntä (`unix-040-dbg` = **68040-260727-01**)

Fail-fast: jos 2 tai 3 hajoaa, loppu on merkityksetöntä — kirjaa ja pysähdy.

**1. Boot + login + FPU.** `uname -m` → `68040-260727-01`. Ei guruja, ei panikkia.
**FPU on nyt basessa, joten se testataan tässä eikä grafiikkavaiheessa:**
`cc -o fputest fputest.c; ./fputest` → `FPUTEST Test A PASS`. Se että natiivi `cc`
KÄÄNTÄÄ tämän on itsessään tulos (M3): ilman FPSP:tä `cc1` kuolee SIGSYS:iin.
**Serial-kaappaus PÄÄLLE** — kone on serial-USB-kaapelin päässä (`SERIAL-DEBUG.md`).

**2. exec-polku (ISSUE-32).** Tämä ensin, koska rikkinäinen exec estää kaiken muun.
```sh
cc -o /tmp/exectest exectest.c
/tmp/exectest 20 /tmp/exectest
```
Odotus: `EXECTEST-RESULT PASS (data+bss verified across every generation)`.
Aja **kerran myös kylmänä**: kopioi binääri `/`-juureen, `reboot`, aja heti bootin
jälkeen — silloin viimeinen text/data-sivu tulee levyltä eikä sivucachesta.
Huom: "binääri käynnistyy" EI ole tulos — ohjelma verifioi oman datansa ja BSS:nsä.

**3. /proc (ISSUE-17/18).** `cc -o proctest proctest.c; ./proctest` roottina.
Odotus: `PROCTEST-RESULT PASS`.
**Korjaamattomalla kernelillä tämä PANIKOI** (`pc=0x…63504`, `prfastmapin`) — siis
puhdas ajo on itsessään pääuutinen, ei rutiini.

**4. UFS-allokointi (ISSUE-31).** `mkdir /pgc; cc -o bmaptest bmaptest.c; ./bmaptest /pgc`
Odotus: `BMAPTEST-RESULT PASS`. Kattaa direct/fragment-kasvu/indirect/sync-write ja
tarkastaa koko tiedoston tavuittain. Väli 4097..6144 on se, jossa luku nyt ohitetaan.

**5. ISSUE-27:n todiste — kaksivaiheinen, kylmä sivucache.**
```sh
cc -o pgcold pgcold.c
cp pgcold /                 # /tmp katoaa rebootissa
./pgcold D 24 /pgc          # vaihe A: luo + sync
sync; sync; reboot
# ... boot ...
./pgcold E 24 /pgc          # vaihe B: koetin
```
Odotus: **`PGCOLD-E-RESULT PRESERVED`** (emu pre-fix 24/24 tuhoutunut, post-fix 0/24).
Oikealla levyllä tämä ajaa eri fragment-/writeback-ajoituksen kuin emulaattori,
mikä on koko syy ajaa se raudalla uudestaan.

**6. Halvat.**
```sh
cc -o mlocktest mlocktest.c; ./mlocktest      # MLOCKTEST-RESULT PASS
cc -o trunctest trunctest.c; ./trunctest 8 /pgc
```
`mlocktest`in erotteleva kohta on T1: `memcntl(base+2048, MC_LOCK)` **täytyy** palauttaa
EINVAL; korjaamattomalla se palauttaa 0. `trunctest` **ei toisinna** ISSUE-30:tä
(truncate vapauttaa juuri ne lohkot) — se ajetaan regressiona, ei todisteena;
kumpi tahansa tulos ZEROED/STALE-DATA on kirjattava, ei tulkittava.

**7. Laitemmap (ISSUE-33).** `cc -o devmaptest devmaptest.c; ./devmaptest`
Odotus: `DEVMAPTEST-RESULT PASS` ja kernel-base-ikkunassa **>0 nollasta poikkeavaa
tavua** (emu: pre-fix 0/4096, post-fix 3186/4096).

**8. Levytotuus + virtakatkaisu.**
```sh
cat /stand/unix /stand/unix > /big.dat; sync; sync; sum /big.dat   # kirjaa summa
reboot
fsck -F ufs -m /dev/rdsk/...        # jos tarpeen
sum /big.dat                         # täytyy täsmätä
```
Sitten sama uudestaan mutta **KATKAISE VIRTA** puhtaan rebootin sijaan (B1-hyväksyntä
teki tämän 7/7). Kylmäboot + fsck + summat uudelleen levyltä.

**9. Regressiot aiemmilta linjoilta.**
```sh
./hat_dup_cow 1 ; ./hat_dup_cow 32 ; ./hat_dup_cow 64      # RESULT PASS × 3
sh issue10-pressure.sh                                      # PRESSURE-DONE, summat samat
sh burst4.sh                                                # ALLBURSTS-DONE, 24/24
cc -o bigargv bigargv.c ; ./bigargv
cc -o msynctst msynctst.c ; ./msynctst                      # MSYNC-OK
```
Dhrystone-vertailuluku: **18293/s** (B1, IC+WT-DC, 25.7. mittaamaton).
`issue10-pressure.sh` olettaa `/payload.bin`in ja `/tmp/hat_dup_cow`in olevan
paikallaan; jos historiallista `payload.bin`ia (sum `1570 8192`) ei ole, tee 4 MiB
tiedosto koneella ja **kirjaa sen oma summa** lähtöarvoksi — älä odota vanhaa lukua.
Huom myös: `nohup` EI selviä telnet-session päättymisestä tällä koneella — aja
synkronisesti tai at-jonon kautta (B1-sessio käytti at-jonoa juuri tästä syystä).

---

## Vaihe 2 — grafiikka ✅ **AJETTU JA LÄPÄISTY** (nyt `unix-040-rtg-dbg` = 68040-260728-02)

> **TULOS 27.–28.7.: MOLEMMAT RTG-AJURIT TOIMIVAT FYYSISELLÄ RAUDALLA.**
> * **VA2000 + X11: 27.7.** — ja **selvästi nopeampi kuin 030:lla**.
> * **Xsvga + X11 fyysisellä Piccololla: 28.7.** — toimii ja on **nopea**. Tämä oli
>   Xsvga-jäljen viimeinen avoin kohta, avoinna 24.7. lähtien.
>
> **Piccolo on ajettava Zorro II -tilassa.** Zorro III -jumpperilla `svgaprobe` → ENXIO.
> Se ei ole regressio eikä korttivika: ajurit dereferoivat `cd_boardaddr`in
> kernel-osoitteena, ja vain Zorro II on DTT0:n identity-mappauksessa. Koko mekanismi ja
> se miksi tämä on **yhden muuttujan A/B** (vain jumpperi vaihtui): `KNOWN-ISSUES.md`,
> "Zorro III -laiteaukko ei ole ajurin tavoitettavissa".

`fputest` EI ole täällä — FPU on basessa, se ajetaan vaiheessa 1.
`mknod /dev/svga c 67 0` ja `mknod /dev/va2000 c 68 0` kerran.

**10.** Natiivi self-host tällä kernelillä: käännä jokin testiohjelma. `fputest` itse
ajettiin jo vaiheessa 1 — tässä varmistetaan vain että ajurit eivät riko FPSP:tä.
**11.** `xinit` **fyysisellä Piccololla** konsolista. Emu-referenssi 1152x900 8-bit.
Jos X kaatuu: tarkista ensin onko kyse etätestaus-artefaktista (24.7. "kaatuu
disconnectissa" oli juuri se) — aja konsolilta, WM mukana.

---

## Vaihe 3 — VA2000 ✅ **AJETTU JA LÄPÄISTY 27.7.** (SAMA kerneli, nyt 68040-260728-02)

**Ei ollut savustettavissa lainkaan ennen rautaa** — kortti ei ole emuloitavissa. Nyt ajettu:
X11 toimii VA2000:lla ja on selvästi nopeampi kuin 030:lla.

**12.** `mknod /dev/va2000 c 68 0`
**13.** `./va2000probe` **ENSIN.** Emussa siitä tulee siisti ENXIO; raudalla sen
**täytyy onnistua**. Jos ei onnistu, älä jatka XRTG:hen — kirjaa ja pysähdy.
**14.** Vasta sitten XRTG / wolf3d.
**15.** `devmaptest` myös tällä kernelillä: se on ainoa testi jolla on suora yhteys
RTG-aukon mappaukseen (ISSUE-33 korjasi juuri sen PFN:n josta polku riippuu).

Tunnettu riski ennallaan: user-space-mmapattujen rekisterien luvulla ei ole vielä
PTE:n CM-polkua; kernelin puoli on CI DTT0:n kautta.

---

## Vaihe 3b — ILMAISET MITTAUKSET (ei kernelimuutosta, skippaa jos aika loppuu)

Nämä eivät testaa mitään — ne **keräävät tietoa jota ei saa muualta** ja tekevät seuraavista
töistä parempia. Kumpikaan ei muuta konetta.

**15b. NFS-perusmittaus — ennen-arvo listan kohdalle 2.** NFS on ainoa jäljellä olevista
Model-B-perheistä joka on rautatestattavissa, ja `nfs_putpage`-konversio on seuraava
toteutuskohde. Tämä on se ennen-mittaus jonka konvertointi muuten heittäisi pois:

```sh
mount -F nfs nasu:Public /mnt/nasu        # ei säily bootissa
cp /mnt/nasu/<3MB-tiedosto> /nfsbase.bin ; sync ; sum /nfsbase.bin
# toista 5 kertaa, kirjaa jokainen summa
```
Historiallinen referenssi ISSUE-13:sta on **`sum 11920 6060`** (5 peräkkäistä 3 MB kopiota
tavuntarkkoja, NFS↔local identtinen). Codex vahvisti että **se pysyy voimassa konversion
jälkeenkin** — sivukoko ei muuta tiedoston tavuja. Jos saat saman luvun nyt, meillä on
ennen/jälkeen-pari samalta koneelta.

**15c. COFF:in 76 tiedoston aukko kiinni — 5 minuuttia.** `PT_SHLIB`→`getcoffhead`-reitti on
todellinen, mutta tuottajaa ei löytynyt luettavasta aineistosta, ja **76 ohjelmatiedostoa jäi
lukukelvottomaksi** vain koska host-puolen vanilla-mounttimme on root-omisteinen read-only.
Elävällä koneella root lukee ne. Aja Codexin skripti (`amix-kernel-analysis/vm-map/
scan_exec_formats.py`, siirrä koneelle) tai vähintään:

```sh
find /usr/bin /bin /usr/lib /usr/public/lib -type f -perm -100 2>/dev/null \
  | while read f; do od -An -N2 -tx1 "$f" | grep -q ' 01 50' && echo "COFF: $f"; done
```
`0x0150` = MC68 COFF magic. **Jos osumia on nolla, COFF on todistetusti kuollut** tällä
asennuksella ja 13 sitea voi merkitä pysyvästi lykätyiksi. Jos osumia on, COFF nousee
lykätystä eläväksi. Kummin päin tahansa se on vastaus kysymykseen joka on nyt auki.

## Vaihe 4 — B2 copyback (vain jos aikaa jää)

**16.** B2-hyväksyntä (`hat_cm_ram` 0x00→0x20) on kirjoitettu mutta **ei koskaan ajettu
raudalla**. Protokolla `CACHES-ON-PLAYBOOK.md`: boottaa ENSIN WT-baseline erottaaksesi
cache-altistuksen mappausregressiosta, sitten b2-image; tarkista kmemistä
`hat_cm_ram=0x20`, laskuriparit täsmälleen yhtä suuret, nolla diagnostiikkaa, ja
virtakatkaisu-levytotuus.

---

## Vaihe 5 — pitkä soak

**17.** Jätä kone pystyyn kuorman alle tunneiksi. Kolme avointa kohtaa on
saavutettavissa **vain** näin:
- **ISSUE-9** — idle-ajan loputon bus-error-silmukka (ei koskaan kaapattu)
- **ISSUE-22** — kertaluontoinen EFAULT paineessa
- **ISSUE-29** — KMA-vapaalistaraportti (nähty emussa 3×, attribuutio todistamatta)

Serial-kaappaus päällä koko ajan. `KMEMCORRUPT`-rivit = ISSUE-29.

---

## Hyväksymiskriteerit

| Kohta | PASS |
|---|---|
| 2 exectest | `EXECTEST-RESULT PASS`, myös kylmänä |
| 3 proctest | `PROCTEST-RESULT PASS` (ei panikkia) |
| 4 bmaptest | `BMAPTEST-RESULT PASS` |
| 5 pgcold D/E | `PGCOLD-E-RESULT PRESERVED` |
| 6 mlocktest | `MLOCKTEST-RESULT PASS` (T1 = EINVAL) |
| 7 devmaptest | `DEVMAPTEST-RESULT PASS`, ikkuna >0 tavua |
| 8 levytotuus | summat säilyvät sekä rebootin ETTÄ virtakatkaisun yli |
| 9 regressiot | hat_dup_cow 3/3 PASS, ALLBURSTS-DONE, summat tavuntarkkoja |
| 1 FPU | `FPUTEST Test A PASS` ja natiivi `cc` kääntää sen |
| 10–11 grafiikka | natiivi cc toimii RTG-kernelillä, `xinit` antaa työpöydän |
| 12–13 VA2000 | `mknod` + **`va2000probe` onnistuu fyysisellä kortilla** (ENSIN, ennen XRTG:tä) |

**Poikkeama MISSÄ TAHANSA kohdassa → kaappaa serial/kuva ja KESKEYTÄ lista.**
Emulaattori-vs-rauta-delta on itsessään löydös, ei häiriö (ISSUE-7/8/11/13/21).

---

## Mitä EI saa tehdä

- **Älä testaa RFS:ää.** ISSUE-16 = 72 muuntamatonta sitea; RFS on tällä portilla
  epäturvallista, ei "todennäköisesti ok".
- **Älä ota S5:tä tai COFF:ia käyttöön** — molemmat on tarkoituksella jätetty
  muuntamatta.
- **`init 6` ei** (ISSUE-24, runlevel-6-limbo) — `reboot`.
- **`shutdown -i0` ei** (ISSUE-26, deterministinen bus-error-silmukka).
- Älä yritä `emu-reset-boot.sh`-tyyppistä "palauta golden image" -logiikkaa oikealla
  levyllä: kaksivaiheiset testit tarvitsevat pehmeän rebootin, eikä palautettavaa
  imagea ole.

---

## Kirjaaminen

Evidenssitiedosto `test-tools/realhw-verify-2607NN.txt`,
tyyliesikuva `test-tools/b1-dcwt-verify-260723.txt`. Kirjaa:

1. mitkä buildidit todella bootattiin (`uname -m`, ei oletusta)
2. jokaisen kohdan tulos sanatarkasti (RESULT-rivit, summat, laskurit)
3. **mitä EI validoitu** — tämä on tärkein kohta. Jos vaihe 3 tai 4 jäi ajamatta,
   se kirjataan yhtä näkyvästi kuin ajetut.

---

## burst4.sh

Ei ole repossa (eli scratchpadissa 23.7.); kopioi tästä koneelle.

```sh
#!/bin/sh
# 4 burstia x (6 x 4 MiB rinnakkaista kopiota + hat_dup_cow 64).
# Aja at-jonosta tai synkronisesti -- nohup EI selviä telnet-session päättymisestä.
b=1
while [ $b -le 4 ]; do
	echo BURST $b
	i=1
	while [ $i -le 6 ]; do
		cp /payload.bin /press$i.bin &
		i=`expr $i + 1`
	done
	/tmp/hat_dup_cow 64 >/dev/null 2>&1 &
	wait
	sum /press1.bin /press2.bin /press3.bin /press4.bin /press5.bin /press6.bin
	b=`expr $b + 1`
done
echo ALLBURSTS-DONE
```

Odotus: `ALLBURSTS-DONE` ja 24 identtistä summariviä
(`grep -c "<summa>" burst4.log` = 24). Emussa burstit 3–4 kestivät ~10 min/kpl —
se on laillista thrashia, älä tulkitse jumiksi ennen ~15 min.

---

## Taustaa ja lähteet

- Mitä kukin testiohjelma todistaa + erotteleva signaali: `test-tools/README.md`
- Vikojen yksityiskohdat: `KNOWN-ISSUES.md` (ISSUE-15/16/17/18/27/28/29/30/31/32/33)
- Rautalinjan historia ja koneen fysiikka: `RESUME-HERE-040-HARDWARE.md`
- Cache-linjan protokolla: `CACHES-ON-PLAYBOOK.md`
- Yhteydet ja creds: `~/kehitys/CLAUDE.md` (**ei koskaan repoon**);
  telnet 10.0.10.10, TFTP-host 10.0.10.182:1069, NAS nasu = 10.0.10.52
