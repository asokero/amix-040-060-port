# Prompt for the next session — the 68060 campaign, phase 060-F0

Copy everything between the lines into the new session.

---

Lue ENSIN kernelsupport/060-CAMPAIGN-PLAN-260805.md kokonaan äläkä johda mitään sen ulkopuolelta.
Taustaksi docs/68060-prestudy.md (§3 ja §7 = mitä 060-tuki jo sisältää) ja Codexin kaksi analyysia
amix-kernel-analysis/vm-map/M68060-XPAGE-ACCEPTANCE.md ja M68060-SUPPORT-LANDSCAPE.md. 040-portin
tila on docs/archive/RESUME-HERE-260801.md; se on suljettu eikä sitä avata tässä sessiossa.

Tilanne yhdellä rivillä: **prosessorinvaihto on tehty — A3000:ssa on 66 MHz 68060 Mercury-
adapterilla, ja se boottasi vanhalla RTG-kernelillä suoraan loginiin ja ajoi Dhrystonen.**
040-portti on kokonaan rautahyväksytty (ISSUE-40 suljettu 2.8., patteristo 10/10, burst 96/96).

TÄMÄN SESSION TYÖ: 060-kampanjan vaihe F0 = mittausbootti. Ei uutta kernelikoodia ennen kuin
mittaukset on otettu.

Kerneli: build/unix-040, build id 68040-260802-01, textsize 0xe4868 — sama täysin hyväksytty
ISSUE-40-base joka ajettiin 2.8. Bannerin PITÄÄ lukea 68060-260802-01 ja uname -m sama.
RTG-kaksonen jos X halutaan: build/unix-040-rtg-020826 = 68040-260802-04, textsize 0xed894 —
mutta VASTA toisena bootina, yksi muuttuja kerrallaan.

Laskuriosoitteet basessa (0x08000000 + textsize + nm:n .data-offset):
  cputype 0x080FCE58 (pitää olla 60)   fpu_present 0x080E9844   buildid 0x080FCE44
  hat_pfnmiss_n 0x080FD24C             hat_badaslot_n 0x080FD250   kdbg_on 0x080FD248
  i39_magic 0x080FD27C (0x49333921)    i40_magic 0x080FD2B4     ptd_magic 0x080FD2E8
RTG:ssä: cputype 0x08105E84, fpu_present 0x080F2870, i39_magic 0x081062A8,
  hat_pfnmiss_n 0x08106278, i40_magic 0x081062E0, ptd_magic 0x08106314.

Ajolista järjestyksessä:
 1. Banneri + uname -m + cputype == 60; loaderin pitää tulostaa "kernel cputype set to 60".
 2. fpu_present — täysi 060 vai LC060. Yksi sana joka ratkaisee kuinka paljon vektori 11 merkitsee.
 3. **mul64test käännettynä NATIIVISTI guestin cc:llä ja ajettuna.** Tämä on session tärkein
    yksittäinen mittaus ja se määrää loput. ISSUE-34a on todistettu RISTIINKÄÄNNETYLLÄ binäärillä;
    guestin oma työkaluketju skannattiin puhtaaksi 060:lle toteuttamattomista käskyistä, ja
    test-tools/mkall.sh kääntää koko patteriston natiivisti. Jos natiivi cc ei emittoi 64-bittistä
    muls.l:ää, koko patteristo on käytettävissä 060:llä JO NYT ja ISP siirtyy oikeellisuus-
    asiaksi. Jos emittoi, vektori 61 on välitön este. Disassembloi binääri kummassakin
    tapauksessa — käsky on todiste, ei exit-status.
 4. mkall.sh, sitten batteryrun2.sh ja burstrepeat2.sh. Vertailuluvut 040:ltä ovat
    docs/REALHW-ISSUE40-ACCEPTANCE-260802.md:ssä: patteristo 10/10, burst 96/96, hat_pfnmiss_n
    tarkalleen +2 per devmaptest eikä muusta.
 5. memwatch-perustaso: ISSUE-40:n korjaus on CPU-riippumaton, joten availrmem:n pitäisi olla yhtä
    tasainen 060:llä (~0,2 sivua/min). Eri kaltevuus on löydös.
 6. Lue CACR takaisin ja pura se. Varmistettu NetBSD:n omista määrittelyistä: 0x80008000
    tarkoittaa 060:llä TÄSMÄLLEEN samaa kuin 040:llä (IC+DC päällä). Käyttämättä ovat branch
    cache (IC60_EBC 0x00800000, tyhjennys IC60_CABC 0x00400000) ja store buffer
    (DC60_ESB 0x20000000). ÄLÄ muuta mitään tässä sessiossa — lue ja kirjaa.
 7. Dhrystone molemmilta CPU:ilta kunnolla talteen, kernelin build id merkittynä.

Mitä EI saa päätellä: vihreä patteristo tarkoittaa että ne testit menivät läpi, ei että 060-tuki on
kunnossa. Aiempi puhdas 060-linja oli käskyvalinnan onnea eikä kattavuutta — se lause on
KNOWN-ISSUESissa syystä. Amiberry ei ole todiste FSLW.MA:sta, välimuistikäytöksestä eikä
toteuttamattomien käskyjen trappaamisesta.

Jos ajat jäävät aikaa: seuraava yksikkö on 060:n vikapolun laskurit (x60_fmt4_n, x60_ma_n,
x60_compat_n, x60_rw_read_n, x60_rw_write_n, x60_far_fail_n, x60_last_fa, x60_last_fslw) wb040.s:ään
wb_dfc_*:n muotoon. Ilman niitä Codexin XPAGE-hyväksyntää EI voi ottaa: tällä hetkellä mikään ei
laske fmt-4-kehyksiä, joten boottaava kone todistaa että polut selvittiin, ei että ne ajettiin.

Rauta: A3000 + Mercury 68060 osoitteessa 10.0.10.10 (root/(see local/secrets.env)), ajuri real.py durable-tools-
hakemistossa. Emulaattori: emu-reset-boot.sh [040|060] loki.txt IMAGE. NAS: amix/hwtest-260802b/.
Älä käytä Agent-työkalua. Vastaa suomeksi.

Seitsemän sääntöä jotka ovat jo maksaneet aikaa:
 1. Vaihto on yksisuuntainen tämän session ajan: 040-regressiota EI ole olemassa niin kauan kuin
    060 on koneessa. Siksi jokainen 060-muutos pysyy cputype-portitettuna niin että 040-polku on
    tavuidenttinen, ja molemmat emu-CPU-konfiguraatiot boottaavat ennen jokaista rautabootia.
 2. Laske laskuriosoitteet uudelleen joka imagelle (base 0xe4868 vs RTG 0xed894). Lue magic-sana
    ENSIN äläkä usko lukuja jos se ei täsmää.
 3. "Kone boottasi" ei ole todiste siitä että polku ajettiin — laskurin pitää näyttää se.
 4. Älä niputa mount+kopiot+käännös yhteen real.py-komentoon. AMIX_CMD_TIMEOUT=900 käännöksille, ja
    pitkät ajot irrotettuna SULKEIDEN kanssa: (nohup sh /tmp/x.sh > /tmp/x.log 2>&1 &) — ajuri
    lisää perään "; echo TAG", ja paljas & tekee siitä hiljaisen no-opin.
 5. /tmp tyhjenee joka bootissa. /kpeek ja /pgc ovat juuressa ja säilyvät; lähteet NAS:issa,
    mount -F nfs nasu:Public /mnt/nasu ei säily bootin yli.
 6. Konsoli kertoo asioita joita laskurit eivät voi (ISSUE-39 ratkesi yhdeltä konsoliriviltä).
    Pyydä kuva kun ruudulle tulee jotain.
 7. Kirjaa kumotut hypoteesit. Suunnitelmassa on kaksi nimettyä ennustetta — natiivi cc on
    060-turvallinen (§2) ja ISSUE-34b on vektori 11 eikä syscall-polku (§6) — ja kumpikin on
    tarkoitettu mitattavaksi, ei uskottavaksi.
