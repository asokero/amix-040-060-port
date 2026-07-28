# Rautasession ajolista — ISSUE-36 (NFS read side) hyväksyntä, 2026-07-28 yön työ

Tämä on **itsenäinen ajolista**. Kaikki on rakennettu, ristikäännetty, emu-savustettu ja
NAS:iin viety valmiiksi — aamulla ei tarvitse buildata mitään. Korpus on jo NAS:issa.

Yön työ tehtiin **Opus 5:llä**, koska Fable-creditit loppuivat (muisti
`feedback-delegate-coding-to-fable` on päivitetty: sääntö on tauolla, ei kumottu).

---

## ✅ TULOKSET RAUDALLA 2026-07-28, kerneli 68040-260728-12

Ajettu oikealla A3000 + Mercury 040:llä, NFS `nasu:Public`, korpus tunniste `t280209`.

| kohta | tulos |
|---|---|
| **ISSUE-36 NFS-häntä** (7 tiedostoa) | **7/7 PASS** — ml. `r=1`, `r=123`, `r=2048` jotka ennen SIGBUSasivat |
| — jokainen rivi | `all bytes match` **ja** `past-EOF zero` (kaikki kolme ehtoa) |
| **Altis ELF NFS:ltä** (`uname`, 1 altis PT_LOAD) | **toimii**, rc=0, banneri tulostui |
| **Kontrolli-ELF NFS:ltä** (`pwd`) | **toimii**, rc=0 |
| **Paikallinen kontrollikorpus** | **7/7 PASS** |
| **ISSUE-35 regressio** (tavuntotuus palvelimelta) | **6/6 PASS** |

**Vielä tekemättä, ja molemmat vaativat sinua:**

1. **A/B:n VANHA puoli** = boottaa `unix-040-dbg-pre36` (**260728-13**) ja aja sama `nfstail`.
   Se on se ajo joka **vahvistaa tai kumoaa** Codexin rajamallin: odotus `r=1,123,2048` → SIGBUS,
   `r=0,2049,4095` → PASS. Uuden kernelin vihreä ajo yksin todistaa vain ettei mikään ole rikki.
   Kernelin vaihto vaatii kädet (loader ajetaan AmigaOS:n puolelta).
2. **`pl[]`-probe (kohta D)**: `DBG pvn`-rivit menivät konsoliin ja serialiin, ja serial oli
   sinun omassa `cat /dev/ttyUSB0` -kaappauksessasi (PID 624823, klo 9:37). Koneella ei ole
   `/var/adm/messages`ia, joten en pääse niihin. Liitä rivit tänne, tai putkita kaappaus
   tiedostoon (`cat /dev/ttyUSB0 | tee /tmp/amix-serial.log`) niin luen sen itse.
   Odotus korjatulla kernelillä: **`n <= cap`** eikä `p0 == p2`.

### ⚠ Kaksi omaa virhettä jotka korjattiin ajon aikana

* **Kontrolli-ELF oli kelvoton.** Valintalogiikkani poimi kontrolliksi minkä tahansa tiedoston
  joka ei läpäise altisehtoa — myös 64-bittisen little-endian ELFin (`^?ELF^B^A^A^C`), jota AMIX ei
  voi ajaa. Shell tulkitsi sen skriptinä eikä kontrolli todistanut mitään. Korjattu: kontrollin on
  oltava **aito big-endian m68k ELF** jossa on PT_LOADeja mutta ei altista. Uusi kontrolli = `pwd`.
* SVR4:n `grep` ei tue `-E`:tä (tämä on jo `CLAUDE.md`:ssä, ja unohdin sen silti).

## ▶ Artefaktit

| Vie tämä | buildid | Sisältää |
|---|---|---|
| `build/unix-040` | **68040-260728-03** | base + FPSP + ISSUE-35 + **ISSUE-36** + sysconfig, ei probeja |
| **`build/unix-040-dbg`** | **68040-260728-11** | + probet + **pvn-probe** + **ISSUE-37-probe** — **hyväksyntä tällä** |
| **`build/unix-040-dbg-pre36`** | **68040-260728-13** | **A/B-KONTROLLI**: sama kuin -11 mutta ISSUE-36 peruttu |
| `build/unix-040-rtg` | 68040-260728-10 | base + Xsvga (67) + VA2000 (68) |
| `build/unix-040-rtg-dbg` | 68040-260728-12 | dbg + molemmat ajurit — **wolf3d/ISSUE-37 tällä** |
| `build/unix_boot040` | (loader) | **pakollinen kaikelle** |

**A/B-pari on todistettavasti puhdas:** `-11` ja `-13` eroavat **täsmälleen 5 tavussa** — neljä
immediatea (`0x8b270`, `0x8b286`, `0x8b28a`, `0x8b6be`) ja yksi buildid-tavu. Mikään muu kuvassa
ei eroa, joten ennen/jälkeen on attribuoitavissa vain näihin neljään siteen.

Ja `-03` on todistettavasti vanha pinnattu base + nämä neljä sitea: se eroaa Codexin pinnaamasta
`260727-07`:stä (sha256 `5df4158b…`, verifioitu) vain **2 tavussa**, molemmat buildid-merkkijonossa.

---

## ▶ Mitä korjattiin ja mistä se tiedetään

Codexin analyysi `amix-kernel-analysis/vm-map/NFS-READSIDE-ISSUE36-SITE.md` (c95fd8c).
**Verifioin kaikki 13 sitea itse kuvasta ennen patchia — täsmäsivät tavulleen**, ja luin
semantiikan disassemblystä erikseen.

Minimikorjaus on **neljä sitea atomisesti** (`prototypes/patch_nfs_getpage.py`, 9 kanaria):

```
0x8b6ba  rp->r_size + 2047 -> + 4095     EOF-sallinta   <- SIGBUSin suora tuottaja
0x8b26c  sz -= 2048 -> 4096              pl[]-laskuri
0x8b282  io_len + 2047 -> + 4095         sivun täysi alustus
0x8b288  andiw #-2048 -> #-4096          sivun täysi alustus
```

**Miksi ei pelkkä yksi rivi:** EOF-portin avaaminen yksin päästää läpi sivun jonka **ylempää
2 KiB:tä I/O ei alusta** (`(123+2047)&~2047 = 2048` menee `b_bcount`iin, mutta `pvn_done` merkkaa
4096 valmiiksi), ja se voi **paljastaa** rikkinäisen `pl[]`-palautuksen. Vahvistin `pl[]`-osan
disassemblystä itse: silmukka `8b262` tallentaa pointterin **ennen** `p_next`-seurantaa, ja koska
SVR4:n `page_t`-listat ovat **renkaita**, laskuri on silmukan ainoa raja → 2048:lla se tuottaa
`A, B, A, B, NULL` kun sopimus on `A, B, NULL`.

**Vika koskee tarkasti jäännöksiä `r = koko mod 4096`:**

```
r == 0            hyväksyttiin ennenkin
r in 1..2048      HYLÄTTIIN -> EFAULT -> 0xE05 -> SIGBUS
r in 2049..4095   hyväksyttiin ennenkin
```

⚠ **Tämä korjaa oman karakterisointimme.** Kirjasimme "NFS:n mmap ei toimi millään ei-4096:n
monikerralla". Binääri sanoo että **ylemmän puolikkaan jäännökset toimivat jo**.

---

## ▶ Korpus on jo NAS:issa — älä generoi uudelleen

`nasu:Public/amix/issue36/`, ajotunniste **`t280209`**. Kirjoitettu **hostilta SMB:llä**, joten
client ei ole koskaan kirjoittanut niitä tavuja (sama erottelu joka teki ISSUE-35:n tuomiosta
luotettavan). Kuvio `((o ^ (o>>8) ^ (o>>16)) & 0xfe) + 1` **ei ole koskaan nolla** — siksi
nolla tiedoston sisällä = kadonnutta dataa ja ei-nolla EOF:n jälkeen = vanhentunut sivu.

```
tail_t280209_24576_r0      r=0     kontrolli
tail_t280209_24577_r1      r=1     hylättiin ennen
tail_t280209_24699_r123    r=123   alkuperäinen rautahavainto
tail_t280209_26624_r2048   r=2048  RAJA, viimeinen hylätty
tail_t280209_26625_r2049   r=2049  RAJA, ensimmäinen hyväksytty
tail_t280209_28671_r4095   r=4095  toimi ennen, ei saa rikkoutua
tail_t280209_28795_r123    8192*3+4096+123 -> takautuva klusterointi (Codexin kohta 3)
elfx_t280209_uname         ALTIS ELF (1 PT_LOAD), NFS:ltä ajettava
elfc_t280209_atopcat       kontrolli-ELF, ei altis
```

Alttiuden skanneri **toisti Codexin luvun riippumattomasti: 85/524**. (Ensin sain 0 — oma bugi,
tarkistin `EI_DATA == 1` mikä on little-endian; m68k on 2. Luku 0 vs 85 paljasti sen heti.)

---

## ▶ Ajojärjestys — fail-fast

### Vaihe A — VANHA kerneli ensin (`unix-040-dbg-pre36` = 260728-13)

**Tämä vaihe on se joka VAHVISTAA TAI KUMOAA mallin.** Ilman sitä vihreä ajo uudella kernelillä
todistaa vain ettei mikään ole rikki — ei sitä että korjasimme sen mitä luulemme.

```
mount -F nfs nasu:Public /mnt/nasu          # ei säily bootissa
cp /mnt/nasu/amix/issue36/nfstail.c /root/  # jos ei jo siellä
cd /root && cc -o nfstail nfstail.c
./nfstail /mnt/nasu/amix/issue36 tail_t280209_manifest
```

**Odotus:** `r=1`, `r=123`, `r=2048` → **SIGBUS**; `r=0`, `r=2049`, `r=4095` → **PASS**.

* Jos tuo täsmää → Codexin rajamalli **vahvistui**, jatka vaiheeseen B.
* **Jos `r=2049` kaatuu myös → malli on VÄÄRÄ.** Älä selitä sitä pois, älä luota patchiin, kirjaa
  ja pysähdy. Testi tulostaa tämän muistutuksen itse.

`nfstail` **nappaa SIGBUSin ja jatkaa**, joten yksi ajo antaa koko taulukon eikä yhtä bittiä.

### Vaihe B — UUSI kerneli (`unix-040-dbg` = 260728-11)

Sama komento. **Odotus: 7/7 PASS**, ja jokaisesta rivistä pitää lukea kaikki kolme:
`all bytes match` **ja** `past-EOF zero`. Pelkkä "ei SIGBUSia" ei riitä — se oli ISSUE-35:n oppi.

### Vaihe C — ELF NFS:ltä (Codexin kohta 5, uusi polku: `nfs_map → segvn_fault → nfs_getpage`)

```
chmod 755 /mnt/nasu/amix/issue36/elfx_t280209_uname /mnt/nasu/amix/issue36/elfc_t280209_atopcat
/mnt/nasu/amix/issue36/elfx_t280209_uname        # ALTIS  -> pitää toimia
/mnt/nasu/amix/issue36/elfc_t280209_atopcat </dev/null   # kontrolli
```

**`chmod` on pakollinen:** SMB:n läpi kirjoitetut tiedostot tulevat moodilla 666 eikä
`chmod` onnistunut hostilta. Ilman sitä `exec` kaatuu EACCES:iin ja mittaisimme jaon oikeuksia
eikä kernelin sivutuspolkua.

Kontrolli on siksi että altiin binäärin kaatuminen erottuu "NFS-exec ei toimi ollenkaan":sta.

### Vaihe D — `pl[]`-sopimus (Codex: mustan laatikon summa EI korvaa tätä)

Molemmat dbg-kernelit kantavat `prototypes/pvn_probe.s`:ää. Se kääriin `pvn_getpages`in
(**globaali `T`**; `nfs_getapage`/`nfs_getpage` ovat **lokaaleja `t`** eikä niitä voi kääriä
`--weaken-symbol`illa, ja detourit kaatuvat 040:llä — tämä oli pakko, ei valinta) ja tulostaa:

```
DBG pvn n=<lkm> cap=<ceil(plsz/4096)> plsz=<x> off=<x> p0=.. p1=.. p2=.. p3=..
DBG pvn   poff0=.. poff1=.. poff2=.. poff3=..
```

**Rikkomus on `n > cap`.** Ennustettu allekirjoitus näkyy ilman logiikkaa: `p0 == p2` ja
`p1 == p3`. **Emu-perustaso (UFS, terve):** `n=2 cap=2 plsz=2000 poff0=0 poff1=1000`, eri
pointterit — eli oikea palautus. Aja probe **vaiheessa A ja B**: A todistaa rikkomuksen, B sen
sulkeutumisen. Tulosta kaappaa serial.

**Rajoite rehellisesti:** probe ei näe yhden sivun **suoraa dispatchia** (`nfs_getpage`in
`0x8b72c`-haara ohittaa `pvn_getpages`in). Codexin mukaan rikkomus on klusteroidussa polussa.

### Vaihe E — regressiot (nämä eivät saa rikkoutua)

1. **ISSUE-35 palvelintotuus:** `nfstruth.c` + `nfstruth-verify.py` → 6/6 PASS.
2. **3 MB NFS→paikallinen summa.**
3. **Paikallinen kontrollikorpus:** `cc -o nfstail-mk nfstail-mk.c && ./nfstail-mk /root/c36 loc &&
   ./nfstail /root/c36 tail_loc_manifest` → 7/7. Erottaa "häntäsivu rikki" tapauksesta
   "NFS-tarjoaja rikki". **Emussa jo ajettu: 7/7 PASS sekä 040:llä että 060:llä.**

---

## ▶ ISSUE-37 (wolf3d) — probe on valmis, mutta se on ERI ASIA

Aja vain jos ISSUE-36 on hoidettu. `unix-040-rtg-dbg` = **260728-12**. Käynnistä `/root/wolf3d`;
kone jumittuu kuten ennenkin, mutta nyt serialiin tulee ensin:

```
DBG segat LOOP addr=<x> seg=<x> base=<x> size=<x> ops=<x>
```

`ops` nimeää ajurin: `segdev b380 / segkmem b3c4 / segmap b408 / segu b450 / segvn b494`
(+ ajonaikainen `.data`-kanta). **Portitettu toistoon (4096 samaa osoitetta putkeen), ei
laskuriin** — kynnys on mitattu eikä arvattu: 64:llä se laukesi terveessä bootissa, koska
**segmap kierrättää slotteja jatkuvasti ja sama VA faulttaa uudestaan täysin normaalisti**.
Terve boot on nyt hiljainen (verifioitu), ja silmukka ylitti 8192 sekunnissa.

**★ Yön löydös: emussa laukennut väärä hälytys jo VASTASI ISSUE-37:n avoimeen kysymykseen.**
`ops=0x080F2AB8` → dbg-kernelin ajonaikainen `.data`-kanta (`0x08000000 + .text 0xE76B0`) →
`.data`-offset **`0xB408` = `segmap_ops`**, ja ikkuna `0x40440000..0x422BFFFF` (30,5 MB)
**sisältää `0x408F4FFF`:n**. Segmentti on siis **segmap MITATTUNA**, ei poissuljettuna — juuri
se mitä neljä epäonnistunutta käyttäjätila-toisintoa teki välttämättömäksi.

---

## ▶ Mitä yöllä EI voitu tehdä, ja miksi

* **ISSUE-36:ta ei voi varmentaa emussa.** Amiberryn slirp ei välitä RPC:tä ulos
  (`rpcinfo -p nasu`: "can't contact portmapper"), joten guest ei saa NFS-mounttia. Nimenselvitys
  saatiin kuntoon (`/etc/hosts` + nimi, ei IP — SVR4:n RPC ajaa IP:nkin `n2a`:n läpi), mutta
  portmapper ei vastaa. **Siksi vaiheet A–D ovat rautatyötä.**
* Emussa varmennettiin: **040 boot, 060 boot** (`68060-260728-04`, sama binääri), `relocs 0`,
  `.data` 4-tasattu, paikallinen korpus **7/7 molemmilla CPU:illa**, pvn-probe elää, ISSUE-37-probe
  hiljainen.

**Havainto joka pitää mainita rehellisesti:** yhdessä kuudesta emu-bootista tuli
`BUS ERROR at 4D455404 PC:C101D6C8 FAULT:6 PID:159 CMD:/usr/amiga/lib/scrmon`. Sama kerneli
toisella bootilla: puhdas. Faulttiosoite on ASCII-tekstiä (`MET\x04`), eli data luettu
pointterina. **Ei korreloi muutokseeni** (ainoa ero edelliseen boottiin oli probe-kynnysvakio),
mutta **en väitä sen syytä** — jäljittämätön, satunnainen, kirjattu.
