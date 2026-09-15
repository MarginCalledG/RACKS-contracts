# RACKS — Status

## MELT-FAKTOREN (ein Ratengesetz, fuenf Positionstypen)
Jede Position schmilzt mit `r_w * Faktor`. r_w ist die freefloat-gekoppelte, 24h-geglaettete Basisrate
(4,2 %/d bei FF=0 ... 6,9 %/d bei FF=1). Die Faktoren sind als exakte Per-Sekunden-Konstanten fuer
BEIDE Bandenden hinterlegt und mit demselben FF-Signal interpoliert — jeder Typ folgt r_w also
proportional, an jedem Punkt des Bandes.

| Position   | Faktor | bei 4,2 % | bei 6,9 % | Ziel des Melts        | Bindung          |
|------------|--------|-----------|-----------|-----------------------|------------------|
| Unlocked   | 1,0    | 4,20 %/d  | 6,90 %/d  | Burn (Supply sinkt)   | keine            |
| LP (Pair)  | 0,5    | 2,10 %/d  | 3,45 %/d  | Burn, via meltPool    | Tax rein/raus+IL |
| Lock 1d    | 0,3    | 1,26 %/d  | 2,07 %/d  | **Agent-Pot**         | 1 Tag, $3        |
| Lock 3d    | 0,2    | 0,84 %/d  | 1,38 %/d  | **Agent-Pot**         | 3 Tage, $5       |
| Lock 14d   | 0,1    | 0,42 %/d  | 0,69 %/d  | **Agent-Pot**         | 14 Tage, $10     |

API: `perSecFactorFor(pos)` und `ratePerDayBpsFor(pos)` mit
P_UNLOCKED=0, P_LP=1, P_LOCK_1D=2, P_LOCK_3D=3, P_LOCK_14D=4.
Aenderungen ggue. dem alten Modell:
- Die Lock-Bleeds sind nicht mehr fix (2,0 / 1,5 / 0 %/d), sondern an r_w gekoppelt.
- **Die 14d-Stufe ist nicht mehr melt-frei** (0,1x statt 0) — und speist damit erstmals auch den Pot.
  Damit haengt das Casino nicht mehr allein an Kurz-Lockern (loest die Pot-Starvation aus der 2-Wochen-Sim).
- **Das Pair schmilzt mit 0,5x** statt voll; `meltPool` rechnet zeitbasiert ab pairLastMelt.
  Der SELF-Call aus _preOp feuert nur beim Epochenwechsel (Gaskosten); extern ist meltPool
  permissionless und meltet ab der ersten Sekunde. Die Balance ist innerhalb einer Epoche also NICHT
  konstant — das ist unschaedlich, weil Melt und Sync atomar sind (kein K-Revert moeglich). Die
  Atomaritaet ist die tragende Eigenschaft, nicht die Epochen-Diskretisierung.
- **Der Gesamtmelt ist NICHT unabhaengig von der Aufrufhaeufigkeit (N-47).** Dieser Satz stand hier
  frueher und ist falsch. Er gilt nur bei KONSTANTER Rate — und die Rate ist konstruktionsbedingt nie
  konstant, weil sie am Freifloat haengt. Der Index-Roll bepreist die gesamte verstrichene Spanne mit
  dem geglaetteten Freifloat, der beim Roll gilt, statt ueber den Pfad zu integrieren.
  Gemessen (zwei identische Welten, einziger Unterschied ist der Tick):

  | Luecke ohne Aufruf | Abweichung |
  |---|---:|
  | 1 Tag  | 0 bps |
  | 7 Tage | 639 bps |
  | 30 Tage | 3.633 bps |
  | 90 Tage | 8.630 bps |

  Richtung: **Stille schmilzt MEHR**, weil die veraltete Rate die schnellere ist. Betrifft alle drei
  Indizes. Auf einem laufenden System liegt der Effekt bei null — deshalb ist es kein
  Sicherheitsbefund, sondern eine Spezifikationsabweichung. Konsequenz fuer den Betrieb: **der
  Keeper-Takt ist eine VORAUSSETZUNG der dokumentierten Oekonomie, keine Bequemlichkeit.** Der saubere
  Fix waere ein kumulativer Ratenindex — ein Eingriff in den Kern fuer einen Effekt, den der Keeper
  ohnehin auf null drueckt, und vor dem Launch nicht zu empfehlen.
  Test: `test/MeltCadence.t.sol`.
- Abgelaufene Locks schmelzen unveraendert mit Faktor 1,0 und werden GEBRANNT (nicht in den Pot).
Reihenfolge bleibt garantiert: 14d < 3d < 1d < LP < unlocked (Test testLockingBeatsHolding).

## AUTOMATISCHE TAX-UMWANDLUNG (RACKS -> SPY -> Reserve)
Die Tax faellt auf dem Token selbst an und wird ueber `swapTax()` in SPY getauscht und an `reserve`
geschickt. Permissionless mit Bounty; ein Cron als Fallback ist Teil des Runbooks.

EINZIGER PFAD: `swapTax()` ist permissionless und zahlt 0.25% Bounty — NUR bei Erfolg. Bots (oder
ein Cron als Fallback) wandeln damit in eigenen Transaktionen um; nichts landet je vor der Order
eines Verkaeufers. Es gibt keine In-Transfer-Konvertierung mehr (kostete ~140k Gas pro Sell und
stellte das Protokoll vor seine eigenen Verkaeufer).
Schutzmechanismen:
- `maxSwapBps` (0.1% der Pair-Reserve pro Umwandlung, Obergrenze 0.5%) deckelt den Preis-Impact.
- Die Tax-Rate wird VOR jeder Umwandlung bestimmt — kein Verkaeufer zahlt auf unsere eigene Dislokation.
- `minOut` = MAXIMUM aus Live-Quote und TWAP-Bewertung. Die schuetzende Seite ist die hoehere:
  ein gedrueckter Spot wird nicht bedient. Folge: bei einem echten scharfen Rutsch pausiert die
  Umwandlung, bis der TWAP nachzieht; Verkaeufe laufen unbeeintraechtigt weiter.
- `router`, `spy` und `reserve` sind nach der ersten Konfiguration unveraenderlich.
- `swapSlippageBps` (3%) gegen getAmountsOut; scheitert der Swap, faengt try/catch ihn ab —
  **ein Nutzer-Verkauf darf daran nie scheitern** (Fork-Test deckt das ab).
- Eigener Reentrancy-Guard: waehrend der Umwandlung darf ausschliesslich `swapRouter` zurueckrufen
  (`inSwap && msg.sender == swapRouter`), jeder andere Pfad bleibt blockiert.
- Die wartende Tax ist melt-exempt und tax-exempt (sie schrumpft nicht und besteuert sich nicht selbst).
Konfiguration: `enableAutoSwap(router, spy, reserve, threshold)`, `setSwapParams(threshold, maxBps, slipBps)`,
`setAutoSwap(bool)`. Der frühere TaxSwapper-Contract ist ersatzlos entfernt.

## ARCHITEKTUR-ENTSCHEIDUNG: Uniswap v2 (kein Wrapper, kein Hook)
Auf RH-Mainnet gegen die ECHTE Uniswap v2 verifiziert (Factory 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f,
Router02 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba).

Warum nicht v3/v4: beide leiten Reserven aus L und Preis ab und haben kein sync(). Fork-Beweis (in Runde 6 gefahren, Test seither
mit der v4-Schicht entfernt; Ergebnis in AUDIT.md dokumentiert): nach 7 Tagen Melt haelt der PoolManager 1.818 statt 3.000 RACKS,
der Pool rechnet weiter mit 3.000 -> Melt kommt NICHT im Preis an und removeLiquidity revertet
(insolvent). v3 zusaetzlich ohne Fee-on-Transfer-Router und ohne Hooks.

### Pool-Melt: atomar (src/Racks.sol)
Das Pair ist melt-EXEMPT (nominale Balance, kein lazy Melt). Sein Melt wird explizit angewendet und
im selben Call mit pair.sync() verheiratet -> Reserven und Balance laufen NIE auseinander, ein Swap
kann kein "UniswapV2: K" sehen.
- `setPair(p)` — verlangt, dass p bereits melt-exempt ist; setzt isDex + capExempt + pairIndex.
- `meltPool()` — permissionless, wendet Melt an und synct atomar. Bounty MELT_BOUNTY_BPS = 25 (0.25%
  des Pool-Melts) an externe Caller. **Nicht** darauf verlassen, dass MEV-Bots das von selbst
  erledigen: 0,25 % des Pool-Melts, denominiert in einem Token, dessen gesamter Markt der Seed-Pool
  ist, sind einstellige Dollarbetraege. Der Cron ist der Primaerpfad, nicht der Fallback. Bei
  `meltPool` ist das folgenlos (selbstheilend), bei `swapTax` und `vault.advance()` haengt der
  Betrieb real am Keeper.
- `_preOp()` ruft `try this.meltPool() catch {}` **nur beim Epochenwechsel**
  (`epochNow() > pairEpoch`) — aus Gaskosten. Selbstheilend ist der Pfad trotzdem, aber ueber den
  permissionless externen `meltPool()`, nicht ueber `_preOp`. Innerhalb einer Epoche ist die
  Pair-Balance also NICHT konstant; unschaedlich, weil Melt und Sync atomar sind. (Dieser Absatz
  behauptete frueher "immer wenn der Pool nachhinkt" und widersprach damit dem
  Melt-Faktoren-Abschnitt weiter oben, der es korrekt beschreibt.)
  BEWUSST kein nonReentrant auf meltPool: der externe Self-Call rollt bei gelocktem Pair (mitten im
  Swap) alles zurueck, statt Melt ohne Sync stehenzulassen.
- Reihenfolge ist kritisch: _preOp laeuft VOR jedem _credit in _move. Beim Sell schiebt der Router
  RACKS ins Pair und ruft dann swap; der Sync sieht die eingehenden Token also noch nicht —
  sonst rechnete der Router amountIn == 0.

Fork-Beweise (test/v4/V2AtomicMelt.t.sol, test/v4/V2MeltAdversarial.t.sol):
- 12 Epochenwechsel OHNE Keeper/Cron: jeder Buy und jeder Sell geht durch, kein einziger Revert.
- Sell als erste TX nach einem Epochenwechsel: funktioniert.
- Reserven == Pair-Balance nach jeder Epoche.
- Melt im Preis: 995.015 -> 777.070 RACKS pro SPY nach 7 Tagen (gemessen gegen RH-Mainnet.
  Die frueher hier stehenden 603.222 stammten aus dem Modell VOR der 0,5x-Stufe fuer das Pair.)
- Bounty nicht farmbar (100 Wiederholungen zahlen 0), Pool-Melt folgt exakt dem Index,
  LP kommt immer raus, Round-Trip um den Melt herum verliert Geld, Pool-Melt verkleinert die Supply.

### Was dadurch entfaellt
WRacks (Wrapper), TaxHook (v4), Zap, V4Swap, V4Pool, TwapOracleV4, Hook-Mining, wiringOk —
und mit ihnen die Angriffsflaechen Share-Inflation, Wrapper-Cap-Meldung und Hook-Deploy-Falle.
Tax laeuft im Token (isDex): Kauf und Verkauf besteuert, Wallet-zu-Wallet frei, dynamisch
ueber TwapOracle (jetzt auf dem echten v2-Pair-Interface: getReserves/token0).
Ohne Orakel greift BASE_TAX_BPS = 400 statt 0 (eine fehlende Quelle darf die Tax nie abschalten).
USDG-Weg existiert auf v2: USDG->SPY->RACKS in einer TX ueber den Standard-Router, kein Zap noetig.

### Deploy (script/Deploy.s.sol — v2, gegen RH-Fork getestet)
Reihenfolge ist zwingend und wird per require geprueft. Jeder Schritt ist unter --broadcast eine
eigene TX in einem eigenen Block — deshalb muss JEDES Zwischenfenster gate-geschuetzt sein:
1. Token/Vault/Agents + Wiring, mint, renounceMint
2. Pair anlegen, `setExempt(pair)`, dann SOFORT `setPair(pair)` + TwapOracle — VOR jeder Liquiditaet
   (sonst existiert ein Block, in dem der Pool handelbar, aber ungegatet und steuerfrei ist)
3. Liquiditaet seeden (Gate zu; nur der tax-exempte Deployer kommt durch)
4. `enableTrading()` -> Launch-Stunde startet
5. LP an LP_DESTINATION (0x...dEaD = burn), `setTaxExempt(deployer,false)`, dann Ownership-Uebergabe
   ALLER VIER Contracts an die Multisig: racks, vault, agents, oracle (2-Step, per require geprueft).
   **Die Multisig muss auf allen vieren `acceptOwnership()` rufen** — bis dahin kontrolliert sie der
   Deployer. Der Vault haelt die Einlagen der Locker und den Pot; ihn beim Deployer zu lassen waere
   ein Single-Key-Risiko, unabhaengig davon wie gut der Token gehaertet ist.
   **Der Agent-Zeiger im Vault ist FINAL.** `setAgent` geht genau einmal (beim Deploy), danach nie
   wieder — es gibt keinen proposeAgent/executeAgent mehr. Damit existiert KEIN Schluessel, der den
   Pot umleiten koennte, und unbeanspruchte Gewinne koennen nicht durch eine Migration verfallen.
   Kein Upgrade-Pfad, bewusst.
   Austauschbar ist nur die ZUFALLSQUELLE, und zwar im Agenten selbst: `proposeVrf` -> 7 Tage ->
   `executeVrf`, danach `renounceVrfControl()` als Einbahnstrasse. Machtvergleich: ein Agententausch
   haette den Pot in einem Call bewegt; eine manipulierte Zufallsquelle kann nur beeinflussen, WER
   gewinnt — Epoche fuer Epoche, durch die pari-mutuel-Aufteilung gedeckelt und on-chain sichtbar.
Env: PRIVATE_KEY, VRF_COORDINATOR, RESERVE, TAX_WALLET, MULTISIG, LP_DESTINATION
Selbstchecks am Ende: Pair melt-exempt, setPair gesetzt, isDex, capExempt, Tax-Wallet melt-exempt,
Orakel verdrahtet, Mint renounced, Trading an, maxWallet > 0.
Fork-Test test/v4/DeployScript.t.sol fuehrt das echte Skript aus und handelt danach: Kauf in der
Launch-Stunde OK, zweiter Kauf ueber dem Cap revertet, Kauf+Verkauf ueber einen Melt-Epochenwechsel
ohne Keeper OK.
NACH dem Launch: `transferOwnership(multisig)` + `acceptOwnership()`, dann `renounceExemptControl()`.

## ZUFALLSQUELLE (src/HashChainSeed.sol + keeper/) — reveal-then-play
Ein Seed pro Epoche aus ZWEI Komponenten. **Gegen den Keeper** steuert keine Partei allein; gegen
den Sequencer sehr wohl — siehe "Restvertrauen" am Ende dieses Abschnitts. Das Preimage verhindert
Keeper-Grinding, es fuegt gegen einen Sequencer-Angreifer KEINE Entropie hinzu.
- Der vorab committete Kettenwert des Keepers, enthuellt am EPOCHENANFANG. Ab dann oeffentlich —
  fuer niemanden ein Vorteil, denn er entscheidet allein nichts.
- Ein Blockhash NACH Epochenschluss, in ZWEI Schritten erfasst (C1): die erste Transaktion nach dem
  Ende fixiert eine ZUKUENFTIGE Blocknummer (Hash existiert noch nicht — wer wann anfasst, gewinnt
  nichts); eine spaetere Transaktion innerhalb von 256 Bloecken friert diesen Hash ein (kann ihn nur
  festhalten, nicht waehlen). Verfaellt das Fenster, wird erneut eine Zukunftsnummer gesetzt.
  **Zum Fenster (N-45):** `block.number` ist auf dieser Orbit-Chain die Nummer der ELTERNKETTE, nicht
  die L2-Hoehe — auf dem Mainnet gemessen: block.number 25.971.156 gegen arbBlockNumber 62.269.858.
  256 Bloecke sind damit rund **51 Minuten**, nicht die frueher hier stehenden ~64 s. Der 15-s-Takt
  des Bots ist dadurch grosszuegiger als gedacht, nicht knapper. Zweite Folge: rund 48 L2-Bloecke
  teilen sich eine `block.number`, die Entropie ist also grobkoerniger als ein Zug pro L2-Block —
  einer pro ~12 s Kettenzeit. `test/v4/BlockhashProbe.t.sol` assertiert beides jetzt, statt es
  nur zu behaupten.
  Verfaellt das Fenster, FAELLT die Epoche und der Keeper wird geslasht (R7-2) — kein Re-Roll, sonst
  koennte wer den geminten Hash schon gesehen hat auf einen besseren Kandidaten warten.
seed(e) = keccak(preimage_e, closeHash_e). Der Keeper kennt ein Ergebnis NIE vor Epochenschluss.
Es gibt keinen Angreifer-Input im Seed mehr (der fruehere attackDigest war ein Grinding-Eingang fuer
den Keeper — K1, kritisch, behoben).
Enthuellen ist NUR bis zum Epochenende erlaubt (C6) — der Keeper sieht den Post-Close-Hash nie zuerst.
Verbleibende Keeper-Macht: innerhalb der Epoche spaet enthuellen oder gar nicht. Preis:
1. Keine Enthuellung bis Epochenende = Epoche FAILED, jeder verliert, auch der Keeper.
2. `requiredBond()` = max(slashPerMiss, Pot) ist die SOLL-Kaution; `attack()` verweigert, solange die
   Kaution darunter liegt (bondOk). Ein einzelner Slash ist auf max(Kaution/SLASH_DIVISOR,
   slashPerMiss) gedeckelt, damit ein Keeper-Ausfall sie nicht potenziert — jeder Slash landet im Pot
   und wuerde sonst den naechsten erhoehen (R7-1). **Das Viertel ist ein Deckel UEBER dem Floor, keine
   Zusage:** sobald Kaution/4 unter `slashPerMiss` faellt, gewinnt der Floor und ein einzelner Miss
   nimmt mehr als ein Viertel — im Grenzfall die ganze Kaution (N-45, Test
   `testSeed_FloorOverridesTheQuarterCap`).
   Der Keeper haftet erst ab `firstEpoch` (Zeitpunkt seines commit) — Epochen aus der Pausenzeit
   sind nicht slashbar, ebenso wenig Epochen ohne Angreifer.
   Die Kaution haengt am Keeper-Slot: bei Keeper-Wechsel geht sie in den Pot, nicht an den Nachfolger.
3. Mints, deren Epoche nie einen Seed bekommt (Keeper weg): `reclaimUnrevealed` nach 7 Tagen
   erstattet die 99 USDG aus der Reserve (Allowance noetig, `refundsReady()`). `reap` verlangt
   `revealed` — ein noch erstattbarer Agent kann nicht weggeraeumt werden (C5/R7).
4. Verlorene chain.json: `proposeChainReset` + 3 Tage + `executeChainReset` durch die Multisig (R7-4).
5. Quellentausch (`executeVrf`) nur, wenn alle Epochen mit Angreifern gesettlet sind; Tiers werden
   beim ersten Reveal gecacht (`cacheTier`, automatisch beim ersten Angriff) und ueberleben den
   Wechsel (R7-3).
Restvertrauen, dokumentiert — **der Sequencer ist die eine Partei, die den Seed allein bestimmen
kann.** Enthuellen ist nur bis zum Epochenende erlaubt, das Preimage ist also oeffentlich, BEVOR der
Close-Hash existiert. Wer den Close-Block produziert, kennt damit beide Komponenten und kann den
Seed waehlen. Das schuetzt gegen den Keeper (er sieht das Ergebnis nie zuerst), nicht gegen den
RH-Sequencer, der hier als nicht am Spiel beteiligt angenommen wird. Fuer ein Auszahlungsspiel ist
das eine echte Vertrauensannahme und gehoert in den Launch-Text. Wer sie nicht will: CCIP-Relay
ueber proposeVrf (7 Tage Timelock).
**Achtung bei der Reihenfolge der Renounces (N-46):** `setExempt` haengt an
`exemptControlRenounced`, und die Seed-Quelle ist melt-exempt, damit die Kaution nicht schmilzt.
Wird `renounceExemptControl()` VOR `renounceVrfControl()` gezogen, kann eine ueber `executeVrf`
installierte ERSATZ-Quelle nie melt-exempt gemacht werden: ihre Kaution schmilzt mit 4,2-6,9 %/Tag,
waehrend `requiredBond()` stehenbleibt. Gemessen: 20 Mio RACKS Kaution sind nach 30 Tagen bei 2,34
Mio und nach 60 Tagen unter der Deckungslinie — `bondOk()` kippt von allein und das Casino sperrt
sich selbst, bis der Keeper dauerhaft nachschiesst.
**Regel: `renounceExemptControl()` erst, nachdem `renounceVrfControl()` gezogen wurde** (oder gar
nicht). Test: `testSeed_RenouncingExemptControlTrapsAReplacementSource`. chain.json ist ein
**Verfuegbarkeits-Asset, kein Geheimnis** (N-50). Ein Leak erlaubt keine Vorhersage: jedes Urbild wird
zu Beginn seiner Epoche ohnehin oeffentlich, und der Seed braucht zusaetzlich einen Close-Hash, den es
vor Epochenende nicht gibt. Und wer die Datei hat, ist NICHT faktisch der Keeper — `reveal` ist
`onlyKeeper`, ohne `setKeeper` ist die Datei wirkungslos. Das Risiko ist der VERLUST: dann geht es nur
ueber `proposeChainReset` mit 3 Tagen Timelock. Also sichern, mehrfach und offline.
Griefing, dokumentiert (C7): jeder kann per `fundPot` den Pot ueber die Kaution heben und damit
Angriffe sperren, bis der Keeper nachschiesst — auf eigene Kosten, das Geld bleibt im Pot.
Rollen: Multisig setzt/ersetzt den Keeper; Keeper committed, hinterlegt Kaution, enthuellt am Start;
jeder darf captureClose, tally, settle, slash.

## VERTRAUENSANNAHMEN GEGENUEBER DER MULTISIG (gehoert woertlich in den Launch-Text)
Auch nach renounceExemptControl und Ownership-Uebergabe verbleiben beim Owner:
- `setTaxExempt` — steuerfreies Trading fuer Einzeladressen
- `setDex(pair, false)` — Tax global aus
- `setLockedSupply` — Rate innerhalb des Bands verschieben (Vault ueberschreibt bei naechster Operation)
- HINWEIS: `renounceExemptControl` bindet `setExempt` und `enableAutoSwap`, NICHT `setDex`,
  `setTaxExempt`, `setCapExempt`, `setFloatExcluded`, `setLockedSupply`, `setEpochLength`.
  Das registrierte Pair ist seit F-05 dauerhaft melt-exempt und kann nicht mehr abgeschaltet werden.
- `setEpochLength` (15 min .. 1 Tag, gedeckelt). Die Epochennummerierung ist kumulativ, eine
  Aenderung nummeriert die Vergangenheit NICHT neu und kann keine Position stranden lassen (P7-P9).
- `setKeeper` — Keeper-Wechsel; die alte Kaution geht dabei in den Pot
- `proposeChainReset` (3 Tage) — Ersatz der Zufallskette
- `setSwapParams` — Konvertierungs-Deckel (max. 0.5% der Reserve) und Slippage
- `setPaused(false)` auf IRSAgent — mit jeder Adresse, die Code hat (ein permissionless Mock waere
  katastrophal; Multisig-Disziplin)
- `proposeVrf` (7 Tage) bis `renounceVrfControl`
- `enableAutoSwap` bis zum Renounce (Ziele danach fix)
- Tax-Wallet ist melt-exempt und Owner-kontrolliert

## DEPLOYBARKEIT (F-01)
Der Optimizer ist in foundry.toml PFLICHT (runs = 200): ohne ihn liegen Racks und IRSAgent ueber
dem EIP-170-Limit und lassen sich nicht deployen. Foundry erzwingt die Grenze in Tests nicht,
deshalb prueft test/DeployabilityAudit.t.sol sie explizit. Aktuell: Racks 16.508, IRSAgent 17.395,
CaymanIslands 11.811, HashChainSeed 8.732 Bytes.

## GASPROFIL (Vault, Keeper laeuft)
lock 385k (erste Position) / 315k · unlock 177k · advance mit einem Bucket 268k · advance im Leerlauf
43k · claimOf 25k · potBalance 61k. Ohne Keeper-Lauf steigt ein `unlock` mit dem Rueckstand
(eine Woche: 562k) — ein weiterer Grund, `advance()` im Tick zu halten.
Keeper-Gaskosten: 3x advance + burnExpired + meltPool + swapTax pro Tick.

## AGENTEN-LEBENSZYKLUS (nach N-19/N-20)
- Die Fuetterungsuhr (LIFE = 3 Tage) startet mit der ENTHUELLUNG, nicht mit dem Mint. Ein Agent, der
  wegen eines Keeper-Ausfalls noch keinen Seed hat, verhungert also nicht.
- `cacheTier(id)` ist permissionless und startet diese Uhr — auf `epochEnd` der ersten lebenden
  Epoche, NICHT auf den Aufrufzeitpunkt. Damit kann niemand einen verhungerten Agenten wiederbeleben.
- `mint()` reapt bis zu drei abgelaufene Agenten, bevor die 10.000er-CAP geprueft wird. Angefasst
  werden nur Agenten, die je enthuellt waren (`tierCached || everRevealed`) — ein Agent, der wegen
  eines Keeper-Ausfalls nie enthuellt werden konnte, wird NIE eingesammelt, sonst waere er weder
  spielbar noch erstattbar (N-32). `everRevealed` entsteht in `cacheTier`/`advanceScan`, also im
  Keeper-Tick. Damit haengt
  der Abbau nicht daran, dass jemand freiwillig `reap` bezahlt. Die Frist dafuer ist
  `LIFE + UNREVEALED_AFTER` (10 Tage) — spaeter als das explizite `reap` (3 Tage), damit die
  Bereinigung niemals einen offenen Erstattungsanspruch wegraeumt.
- Erstattung (`reclaimUnrevealed`, 99 USDG nach 7 Tagen) gibt es nur, wenn seit dem Mint KEINE
  lebende Epoche existierte. Sobald eine existiert, ist der Agent enthuellt und spielbar — dann gibt
  es kein Geld zurueck (sonst waere der Mint eine kostenlose Option auf den Tier).
- `reserve` muss dem Agenten dafuer eine USDG-Allowance geben (`refundsReady()`).

## PRE-LAUNCH-CHECKLISTE
- [x] Alle Code-Findings der 17 Audit-Runden gefixt und verifiziert (Abschlussbericht 10.09.2026)
- [ ] Push auf GitHub mit `git rm` fuer geloeschte Dateien; Clean-Clone-Build als Pflicht vor jedem Push
- [ ] W-Term und Pot-Seed schriftlich entscheiden; Seed-Betrag ins Deploy-Skript
- [ ] Multisig-Runbook: `acceptOwnership()` x5 innerhalb von Minuten nach dem Skript;
      `renounceExemptControl()` erst nach Abwaegung (irreversibel)
- [ ] Cron fuer `meltPool()` (alle 30 min) und `swapTax()` als Fallback — Self-Heal und Bounty tragen,
      aber nachts handelt niemand
- [ ] `forge test --fork-url <RH-RPC>` einmal echt fahren: test/v4/BlockhashProbe.t.sol ist ohne
      RPC nur Dokumentation. Ohne diesen Lauf ist die blockhash-Annahme der Zufallsquelle ungeprueft.
- [ ] Keeper: Kette generieren, committen, Kaution hinterlegen; HashChainSeed separat auditieren;
      erst dann IRSAgent.setPaused(false)
- [ ] Bot-Kompatibilitaet live auf Testnet gegen GoPlus / honeypot.is: Sell-Simulation muss zu jeder
      Sekunde gruen sein
- [ ] Externes Audit mit AUDIT.md als Startpunkt; Scope src/ + script/

## BEKANNTE EIGENSCHAFTEN (kein Bug, gehoert in den Launch-Text)
- `minIndex = RAY/1e6`: der Melt endet fuer JEDE Position beim selben relativen Floor (1e-6 des
  Ausgangswerts) — Holder, Pool und alle Lock-Stufen (R8-1 gefixt: eine Funktion `decayIndex`,
  drei Aufrufer, Eigenschaftstests in test/MeltLawProperty.t.sol). Zeitpunkt: ca. 190 Tage bei
  6,9 %/d, ca. 320 Tage bei 4,2 %/d fuer Unlocked; Lock-Stufen entsprechend spaeter (Faktor).
  ENTSCHEIDUNG: bewusst kommunizieren ("der Melt endet nach X Monaten") oder minIndex tiefer setzen.
- Liquiditaet hinzufuegen ist auf Token-Ebene ein besteuerter Sell, Entfernen ein besteuerter Buy
  (4–8 %). Auf v2 nicht unterscheidbar.
- Sekundaere Pairs (jeder kann RACKS/USDG anlegen) sind nicht `isDex`: dort faellt keine Tax an und
  die Reserven melten un-gesynct (Swaps scheitern an "K", bis jemand `sync()` ruft). Multisig muss
  `setDex` nachziehen oder es bewusst lassen.
- ERC-4337-Bundler: in der Launch-Stunde landen alle Kaeufe eines Bundlers auf dessen `tx.origin`-
  Ledger; nach 1 % ist er fuer alle dicht.
- **Pot-Buchhaltung ist abgeleitet, nicht gebucht** (Wurzelfix fuer R8-2 und R8-4): die gebluteten
  RACKS verlassen den Vault nie, also ist der Pot = Bestand − Schuld − ausstehender Burn, alles in
  O(1) aus kumulativen Indizes. Es gibt kein Rotationsfenster, keine aktive Positionsliste und
  keinen Harvest-Schritt mehr; Dust-Fluten koennen nichts aushungern.
- Positionen reiten Indizes (`scaled * I`), daher aendern Abrechnungszeitpunkt und -haeufigkeit kein
  Ergebnis. Ablauf wird ueber Buckets je Ablauf-Epoche verarbeitet: `advance(tier, maxEpochs)` stellt
  ganze Buckets auf einmal um und haelt das Umrechnungsverhaeltnis fest, damit Aggregat und
  Einzelposition exakt dieselbe Zahl benutzen.
- Ablauf-Buckets haengen an einem FESTEN 30-Minuten-Fenster (`BUCKET`), nicht an der Epochennummer —
  `setEpochLength` kann Positionen damit nicht mehr stranden lassen. Nur vollstaendig verstrichene
  Buckets werden gerollt: eine Position wird nie VOR ihrem Ablauf umgestellt, hoechstens 30 min danach.
- N-05 (gemessen, bewusste Abwaegung): der Regimewechsel liest die Indizes beim `advance()`-Aufruf.
  Zeitexakt nur mit Index-Historie pro Epoche on-chain (~100k Gas je Epoche, dauerhaft) — nicht
  bezahlt. Kosten stattdessen: ein Tag Keeper-Rueckstand schenkt dem Locker 115 bps, immer zu seinen
  Gunsten, nie zulasten. Mit Keeper-Kadenz praktisch null.
- BETRIEB: `advance()` gehoert in jeden Keeper-Tick. Die Umstellung ist exakt, wenn sie zeitnah
  laeuft; hinkt sie hinterher, bleeden abgelaufene Positionen laenger zur Tier-Rate — zugunsten des
  Lockers, zulasten des Pots. Gemessen: ein Rueckstand von einem Tag kostet den Pot ca. 6 % der
  betroffenen Position, ein Rueckstand von 30 min praktisch nichts.
- Eine Epoche OHNE Treffer zahlt nichts aus und der Pot rollt weiter. Die fruehere Formulierung
  "der Pot wird jede Epoche geleert" gilt nur fuer Epochen MIT Treffern (R8-6, Doku korrigiert).
- `sweepStale` vernichtet einen nicht abgeholten Gewinnanspruch nach 90 Epochen; danach revertet
  `claim` mit "empty". So gewollt — den Verlust traegt der Gewinner (R9-4).
- SPY `uiMultiplier` (ERC-8056): falls ein Split die On-Chain-Balance rebased, waere der v2-Pool per
  `skim()` abgreifbar. Vor Mainnet mit RH klaeren.

## ENTSCHIEDEN: Launch-Cap bleibt bei 1 % (R9-5)
Vom Owner so entschieden; hier nur noch als Rechnung dokumentiert, nicht als offene Frage.
Hinweis zur Zahl: das Ledger bucht NETTO (nach 8 % Launch-Tax), eine Wallet erwirbt brutto also
`cap / 0,92` ~ 1,087 % der Supply, rund $55 statt $51.
Der Cap ist 1 % der Supply, und der Pool startet mit 100 % der Supply gegen 6,45 SPY (~$5.000).
1 % der Supply ist damit ~1 % der Reserve — exakt gerechnet (v2 exact-out, 0,3 % Fee):

| Cap | RACKS | Kosten | in USD |
|-----|-------|--------|--------|
| 1 % (heute) | 0,69 Mrd | 0,0653 SPY | **~$51** |
| 3 % | 2,08 Mrd | 0,2001 SPY | ~$155 |
| 5 % | 3,47 Mrd | 0,3405 SPY | ~$264 |
| 10 % | 6,94 Mrd | 0,7188 SPY | ~$557 |

Heisst: eine Adresse darf in der Launch-Stunde fuer ~$51 kaufen (plus 8 % Tax). Echte Kaeufer sind
damit praktisch ausgeschlossen, Sybil ist der einzig rationale Weg — 50 Wallets x $50 = $2.500 fuer
50 % der Supply. Der Cap bevorzugt Sniper gegenueber normalen Kaeufern.
Stellschrauben: MAX_WALLET_BPS erhoehen, oder mehr SPY-Seed (tiefere Reserve = mehr USD pro Prozent),
oder beides. Muss VOR dem Deploy fallen.

## OFFEN
1. Repo: v4-Schicht ist ENTFERNT (Clean-Clone-Build gruen). Auf GitHub per git rm nachziehen —
   'Add files via upload' loescht nichts.
3. ZUFALL: GELOEST durch src/HashChainSeed.sol (ein Seed pro Epoche aus einer vorab festgelegten
   Hash-Kette) — siehe Abschnitt ZUFALLSQUELLE. Das Casino bleibt pausiert, bis der Keeper eine Kette
   committed und die Kaution hinterlegt hat und die Quelle separat auditiert ist.
6. Pot-Seed ist NOETIG, nicht optional, wenn am ersten Tag geraidet werden soll. Der Pot speist sich
   ausschliesslich aus den drei Lock-Bleeds: Pot_in = 0,3*r_w*V1d + 0,2*r_w*V3d + 0,1*r_w*V14d.
   Unlocked-Melt und Pool-Melt werden GEBRANNT und tragen nichts bei (kein W-Term). Ohne Locker ist
   der Pot null. Optionen: (a) Supply-Reserve zurueckhalten und `fundPot` am Launch, (b) den W-Term
   nachruesten (ein Teil des Unlocked-Melts in den Pot statt in den Burn) — Owner-Entscheidung.
7. USDG (Paxos) hat eine Freeze-Liste: `reserve` darf keine einfrierbare Adresse sein, sonst reverten
   lock, mint und feed. `setReserve` ist der Ausweg — Adresse bewusst waehlen.
8. renounceExemptControl ist IRREVERSIBEL — danach sind auch noetige Exemptions (neue Vault-Version,
   neue Tax-Wallet) unmoeglich. Bewusst erst nach dem Launch und nach Abwaegung aufrufen.
4. Externes Audit vor Mainnet.
5. Frontend-Konstanten an die Contracts angleichen (siehe AUDIT.md).
