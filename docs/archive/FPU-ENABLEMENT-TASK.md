# Codex-toimeksianto: 68040/68060 FPU-käyttöönoton census + speksi (Tier 1 + FPSP-plan)

**Määritelty 2026-07-24, Xsvga-FPU-esteen jälkeen.** Xsvga-KERNELAJURI saatiin
linkitettyä 040-kerneliin ja se toimii (svgaprobe: Piccolo tunnistuu), mutta
Xsvga X-SERVERI kaatuu **F-line-käskyyn 0xf200** (68881/68882-transkendentti,
jota 68040:n FPU ei toteuta raudassa) → SIGSYS. Sama este koskee KAIKKIA
FP-transkendentteja käyttäviä 040-userland-ohjelmia. Tämä toimeksianto kartoittaa
FPU-käyttöönoton ja tuottaa toteutusspeksit. **EI kernel-muutoksia — puhdas
analyysi + patch-speksit asserteilla; Fable toteuttaa.**

## Kohde ja pinnaus

- Kernelrepo commit: `51f3d71`
- `build/unix-040` SHA-256:
  `5bd37386d9c5a0f89be451b187fa5dfe9e4f05bcf2f1c37accdc22177a225b38`
- `build/unix-040-dbg` SHA-256:
  `a35a4b596f3c1387d4b890f2108fb0c3b8470a4da3292f83873a23fee0f6f952`
- Vanilla-referenssi: `vanilla/stand/unix` + MI/MD-lähteet. Source-first-sääntö.

**Nykyiset FPU-symbolit (build/unix-040 .text/.data):**

| symboli | osoite | rooli |
|---|---|---|
| `chk_fpu` | `0xc0` | FPU-probe (frestore/fsave + bus-error-temppu) |
| `fpu_save` | `0x132` | fsave@112 + fmovemx fp0-fp7 + fmoveml fpiar/fpsr/fpcr |
| `fpu_restore` | `0x158` | vastinpari |
| `no_fpu1` | `0x156` | fpu_save/restore no-FPU-exit |
| `fpu_setup` | `0x19b50` | (3 call-sitea) |
| `fpuinit` | `0x19bac` | (0 call-sitea — kutsutaanko?) |
| `fpu_wrt_ok` | `0x19bf0` | FP-kirjoitusluvan tarkistus |
| `fpu_present` | `.data 0x4fdc` | **= 0 nyt** (FPU merkitty poissaolevaksi) |
| `fpu_ptr` | `.data 0x4fe0` | nykyisen FP-omistajan proc-osoitin? |

**Nykytila (todettu 2026-07-24):** stock-kernelissä ON FP-context-koneisto (ei
tyhjä), mutta `fpu_present=0` estää sen. `resume` (natiivi 040-ctx-switch,
`src/runtime040.s`, 0xd9c34) **EI kutsu fpu_save/fpu_restorea** — override
pudotti FP-context-vaihdon. Call-site-laskenta: chk_fpu ×1, fpu_setup ×3,
fpu_save ×5, fpu_restore ×3; `fpu_present` 17 kuluttajaa (060-prestudy).

**Valmiit lähteet koneella (`netbsd/syssrc.tgz`):**
- `sys/arch/m68k/fpsp/FPSP.sa` = Motorolan **68040 FPSP** (emuloi VAIN 040:n
  toteuttamattomat käskyt: transkendentit + denormaalit).
- `sys/arch/m68k/060sp/` (51 tied.) = Motorolan **68060 SP**.
- `sys/arch/m68k/fpe/` (23 C-tied.) = NetBSD:n **portaabeli C-FP-emulaattori**
  (emuloi kaiken; kääntyy meidän cross-cc:llä).
- AMIX vanilla EI kanna FPSP:tä.

**Pohjadokumentit:** `docs/68060-prestudy.md` §3.6 (korkean tason FPU-kartoitus:
fpu_present 17 kuluttajaa, FSAVE/FRESTORE-työ, ifpsp040/060 ratkaisu, "largest,
deferred"). Tämä toimeksianto vie sen disassembly-tasolle.

## Miksi (kaksitasoinen, de-riskattu)

- **Tier 1 (perus-HW-FPU):** 68040:n on-chip-FPU toteuttaa perus-FP:n (add/sub/
  mul/div/sqrt/abs/neg/cmp/fmove + useimmat muunnokset) RAUDASSA. Se tarvitsee
  vain: detektointi+enable, FP-context-save/restore ctx-switchissä, oikean
  FSAVE-kehyskoon, FP-poikkeusvektorit. Kattaa valtaosan FP-ohjelmista, emu-
  testattava.
- **Tier 2 (toteuttamattomat käskyt):** transkendentit (fsin/fcos/ftan/fetox/
  flogn/fatan/…) + denormaali-datatyypit trapaavat 040:llä "FP unimplemented
  instruction"-vektoriin → vaativat FPSP:n. Xsvga:n este on juuri tämä. Ei
  kirjoiteta tyhjästä — Motorola 040 FPSP TAI netbsd fpe on valmis.

## Tuotos 1: `FPU-STATE-CENSUS.md` — nykytilan disassembly-census

1. **FP-koneiston disassembly + luokittelu:** chk_fpu, fpu_setup, fpuinit,
   fpu_save, fpu_restore, fpu_wrt_ok, no_fpu1. Kullekin: mitä tekee, onko
   040-yhteensopiva vai **68882-kehysspesifi** (fsave/frestore-kehysformaatti
   eroaa: 68882 NULL/IDLE/BUSY = 4/0x38/0xb4 tavua, 68040 = 4/0x30/0x60). Onko
   `fsave@112`-slotti + save-area riittävän iso 040-kehykselle? Ratkaiseva
   kysymys: **miksi `fpu_present=0` juuri 040:llä** — kutsutaanko chk_fpu:ta
   bootissa, ja miksi sen probe päättelee "ei FPU:ta" (bus-erroraako fsave koska
   FP-vektori osoittaa väärin, vai eri syy)? Todista.
2. **Kutsupolku-census (5+3+3+17 sitea):** jokainen fpu_save/fpu_restore/
   fpu_setup-call-site + fpu_present-kuluttaja luokiteltuna — mikä on ctx-switch
   / signal (sendsig 0x59022) / exec (exece 0x56444) / fork (0x410b0) / kmem-
   FP-avator. **Ristiin 040-override-ketju:** säilyttääkö vai pudottaako se
   kunkin? Erityisesti VAHVISTA että resume (0xd9c34, runtime040.s) pudotti
   fpu_save/restoren, ja LISTAA muut mahdollisesti pudotetut (swtch 0xb902c,
   setuctxt 0x41918, sendsig).
3. **FP-poikkeusvektorit:** mihin osoittavat nyt meidän kernelissä — FP
   Unimplemented Instruction, FP Disabled, FP Unimplemented Data Type, BSUN,
   FP-signaalit (INEX/DZ/UNFL/OVFL/OPERR/SNAN)? Onko vektoritaulu (VBR) meidän
   hallinnassa (pstart040?) vai peritty? Tämä ratkaisee sekä probe-epäonnistumisen
   että Tier-2-hookkauksen.
4. **FSAVE-kehysformaatti + save-area-koko** 68040:llä (ja 68060:llä erikseen —
   eri formaatti) vs. mitä stock-koodi olettaa.

## Tuotos 2: `FPU-TIER1-ENABLE-SPEC.md` — perus-HW-FPU:n käyttöönotto

Toteutusspeksi (patch/override-tasolla, old-byte-assertein / .s-override-
suosituksin):
1. **Detektointi+enable:** miten `fpu_present` asetetaan oikein 040:llä (chk_fpu-
   korjaus vai bring-up-poke pstart040:ssa), FP-poikkeusvektorien asetus jos
   puuttuu.
2. **Context-switch-kytkentä:** fpu_save/fpu_restore takaisin resume040:een
   (runtime040.s) — tarkka paikka Lrt_rest-tienoilla, ABI (a0=proc/u-area FP-
   save-area), lazy-vs-eager-FP-vaihto (kannattaako lazy: aseta FP-disabled per
   proc, tallenna vasta kun toinen proc koskee FP:tä). Huomioi että meidän
   resume on jo natiivi 040-override.
3. **Save-area-koko + p_addr/u-area-layout:** riittääkö olemassa oleva slotti
   040-kehykselle; jos ei, mihin laajennus.
4. **Tier-1-hyväksyntä:** emu-040 + emu-060, ohjelma joka käyttää VAIN
   toteutettuja FP-käskyjä (perus-liukuluku add/mul/div/sqrt) → oikea tulos +
   context-switch säilyttää FP-tilan (fork+FP-laskenta rinnakkain). Testiohjelma
   speksataan (K&R C, cc).

## Tuotos 3: `FPSP-INTEGRATION-PLAN.md` — Tier 2 (transkendentit)

1. **Pakettivalinta meidän link-malliin:** vertaa (a) Motorola 040 FPSP
   (`fpsp/FPSP.sa` — assembly, nopein, HW-FPU hoitaa perus-FP:n) vs (b) netbsd
   `fpe/` (23 C-tied., portaabeli, kääntyy cross-cc:llä, hitain, ei tarvitse
   HW-FPU:ta). Arvioi kumpi istuu meidän `ld -r`/objcopy-relink-mekanismiin
   (Motorola .sa vaatii kokoamisen + entry-taulun; fpe = tavallinen C-käännös).
   Anna SUOSITUS perusteineen.
2. **Integraatiopinta:** miten valittu paketti kytketään — FP Unimplemented
   Instruction -vektori → paketin dispatch, entry/exit-ABI (rekisterien
   säilytys, fsave-kehyksen välitys), miten paketti lukee/kirjoittaa faulttaavan
   FP-käskyn operandit (fpe:n calcea vs Motorolan konventio). Mihin symboleihin
   se linkittyy meidän kernelissä.
3. **060-yhteensopivuus:** sama vaihe kattaa 060:n (060sp) — kirjaa erot
   (060:n FSAVE-kehys + eri vektorit), jotta yksi FPU-vaihe hoitaa molemmat.
4. **Tier-2-hyväksyntä:** Xsvga käynnistyy graafiselle Piccolo-näytölle (kuva-
   kaappaus) + transkendentti-testiohjelma (fsin/fcos/… tunnettu tulos).

## Sulkeumavaatimukset

Vähintään kolme riippumatonta hakua ristiin: (1) FPU-symbolien reloc/call-site-
census, (2) mekaaninen FP-opcode-census (fsave/frestore/fmovem/F-line 0xF000-
0xFFFF) + vektoritaulun luku, (3) source-first: stock FP-käsittelyn kontrakti
(mistä MD-lähteestä?) + netbsd fpsp/fpe/060sp -referenssi. Kaikki osoitteet
pinnatusta imagesta (SHA:t yllä).

## Rajaukset (non-goals)

- EI kernel-muutoksia — speksit + assertit; Fable toteuttaa.
- FPSP-matematiikkaa EI kirjoiteta tyhjästä (valmis paketti portataan/kytketään).
- B2-copyback / DTT0-kavennus / real-060-DC = eri langat.
- Xsvga-ajuri-integraatio on jo valmis (`relink-040-xsvga.sh`) — tämä poistaa
  vain sen FP-esteen, ei kosketa ajuria.

## Hyväksyntäkriteerit

1. Census selittää yksiselitteisesti miksi `fpu_present=0` 040:llä ja mitkä
   FP-koneiston osat ovat 040-yhteensopivia vs. 68882-spesifisiä.
2. Kutsupolku-census kattaa 5+3+3+17 sitea + todistaa resume040:n (ja muiden)
   pudotukset.
3. Tier-1-speksi on toteutettavissa (detektointi+enable+ctx-switch-kytkentä+
   save-area) old-byte-asserttein / override-suosituksin + testiohjelma.
4. FPSP-plan antaa pakettivalinnan perusteineen + konkreettisen integraatiopinnan
   (vektori→dispatch, ABI) + 040/060-yhteensopivuuden.
5. Kaikki osoitteet verifioitu pinnattua imagea vasten.
