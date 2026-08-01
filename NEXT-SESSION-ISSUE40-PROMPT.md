# Prompt for the next session — ISSUE-40 fix

Copy everything between the lines into the new session.

---

Lue ENSIN kernelsupport/RESUME-HERE-260801.md äläkä johda mitään sen ulkopuolelta. Sen jälkeen
ISSUE40-AVAILRMEM-DECLINE-260801.md ja Codexin analyysi
amix-kernel-analysis/vm-map/AVAILRMEM-ACCOUNTING-AUDIT.md (commit d27a303).

Tilanne yhdellä rivillä: 040-portti on kokonaan rautahyväksytty (patteristo 9/9, burst 96/96,
mprotect-julkaisu-ABI, Model-B-headerit ja X11R5 Piccololla), ja auki on yksi aito vika —
jokainen exec menettää pysyvästi yhden 4 KiB sivun, mikä rappeuttaa koneen tunneissa.

TÄMÄN SESSION TYÖ: ISSUE-40:n korjaus, yhtenä yksikkönä.

Vika, mitattuna eikä pääteltynä: dynaaminen exec varaa libc:lle 17 yksikön legacy-SDT:n ketjussa
segvn_create -> hat_map -> hat_growsdt -> hat_sdtalloc. SDT-sivulla on 32 yksikköä, joten kaksi
17:n varausta ei mahdu samalle sivulle -> jokainen exec-AS saa oman 4 KiB sivunsa. Portin OMA
hat_free040 (@0x000d82bc) purkaa vain 040:n A/B/C-puun eikä koskaan kutsu hat_growsdt(...,0) tai
hat_sdtfree -> sivua ei palauteta. Debit on säilytetyssä stock-koodissa, puuttuva elinkaarikaari
meidän overridessamme.

⚠ ÄLÄ korjaa tätä pelkällä availrmem++:lla. Rautamittaus osoitti että availrmem + pages_pp_kernel
säilyy jokaisessa vaiheessa, eli sivu on AIDOSTI varattuna. Pelkkä hyvitys saisi laskurit
tarjoamaan sivua jota ei ole, ja tekisi tilanteesta vaarallisemman kuin se nyt on.

Hyväksyntäkriteeri on kirjattu ETUKÄTEEN, joten korjaus on kumottavissa:
  1. `/tmp/leaktest 300 1` jättää availrmem, availsmem ja pages_pp_kernel tasaisiksi
     taustakohinan rajoissa (nyt: -300 / -300 / +300).
  2. `availrmem + pages_pp_kernel` säilyy edelleen.
  3. `/tmp/leaktest 300 0` (fork) käyttäytyy kuten ennenkin.
  4. Patteristo 9/9 + burst 96/96 eivät regressoi, ja hat_pfnmiss_n liikkuu tarkalleen +2
     per devmaptest eikä muusta.
  5. Pitkä ajo: availrmem ei enää valu ~21 sivua/min kuorman alla.

Jos Codexilta on tullut vastaus kysymyksiin (ISSUE40-CODEX-FOLLOWUP-QUESTIONS.md), lue se ennen
toteutusta — kysymykset koskevat juuri sitä mitä toteutus tarvitsee: mihin kohtaan purkujärjestystä
kaari kuuluu, mitkä sectionit vapautetaan, ja onko hat_growsdt(...,0) ylipäätään kutsuttavissa
portin tilassa vai onko turvallisempi kutsua hat_sdtfree suoraan.

Rauta: A3000+Mercury 040 osoitteessa 10.0.10.10 (root/REDACTED-see-local-secrets-env), ajuri real.py
durable-tools-hakemistossa. Emulaattori: emu-reset-boot.sh [040|060|a3640] loki.txt IMAGE.
NAS: amix/hwtest-260801/ (imaget, SHA256SUMS, testilähteet, lokit, konsolikuvat).
Älä käytä Agent-työkalua. Vastaa suomeksi.

Kahdeksan sääntöä jotka ovat jo maksaneet aikaa:
 1. Laske laskuriosoitteet UUDELLEEN joka relinkin jälkeen JA erikseen jokaiselle imagelle —
    RTG-kernelin osoitteet eivät ole basen osoitteita (textsize 0xed5b4 vs 0xe4588). Lue
    hat_cm_ram-ankkuri (base 0x080FC888, RTG 0x081058B4) ENSIN; sen pitää olla 0x20.
 2. COMMON-symboleilla (freemem, availrmem, availsmem, deficit, physmem, maxmem, nscan) EI ole
    laskettavaa osoitetta — loader sijoittaa ne. Seuraa i39-osoitinpöytää (issue39_040.s);
    pages_pp_kernel sen sijaan on .data ja lasketaan normaalisti.
 3. "Kone boottasi" ei ole todiste siitä että korjaus laukesi — laskurin pitää näyttää se.
 4. Älä niputa mount+kopiot+käännös yhteen real.py-komentoon (natiivi cc ylittää aikarajan ja
    ajuri lähettää ^C:n kesken). AMIX_CMD_TIMEOUT=900 käännöksille, ja aja KAIKKI pitkät ajot
    irrotettuna: nohup sh /tmp/skripti.sh > /tmp/loki 2>&1 &
 5. /tmp TYHJENEE joka bootissa — kaikki binäärit on käännettävä uudelleen. /kpeek ja /pgc ovat
    juuressa ja säilyvät. Lähteet ovat NAS:issa; mount -F nfs nasu:Public /mnt/nasu ei säily.
 6. Testi joka epäonnistuu puuttuvan hakemiston tai rikkinäisen mittarin takia EI ole kernelin
    tulos. bmaptest tarvitsee /pgc:n; va2000probe:n versiolukema on roskaa vaikka kortti toimii.
 7. Konsoli kertoo asioita joita laskurit eivät voi. ISSUE-39 ratkesi konsoliriviltä joka kertoi
    pyydetyn koon, kutsujan ja syscallin — laskurit eivät olisi koskaan kertoneet niitä. Pyydä
    kuva kun ruudulle tulee jotain.
 8. Kirjaa kumotut hypoteesit. Tässä asiassa meni kolme ennustetta väärin yhden päivän aikana, ja
    jokainen kumoutui mittaukseen; se on halvempaa kuin sama harha huomenna uudestaan.
