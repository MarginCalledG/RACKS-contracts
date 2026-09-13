# RACKS — Interner Security-Audit (Adversarial Review)

Vorgehen: alle Contracts vollstaendig gelesen; jede Angriffsklasse durchgegangen (Reentrancy, Access
Control, Arithmetik/Rundung, Oracle-Manipulation, First-Depositor, Flash-Loan, Griefing/DoS, oekonomische
Exploits); fuer echte Funde ein Proof-of-Concept-Test (test/Audit.t.sol) — erst Exploit bewiesen, dann
gefixt, dann Regressionstest der beweist dass er blockiert ist.

## KRITISCH (gefixt)
**W1 — First-Depositor / Share-Inflation im wRACKS-Wrapper.**
PoC: Angreifer wrappt 1 wei (1 Share), spendet 1M RACKS direkt an den Wrapper, Opfer wrappt 500k RACKS
und erhaelt 0 Shares; Angreifer wickelt seinen 1 Share aus und geht mit 2.5M statt 2.0M RACKS —
die kompletten 500k des Opfers gestohlen. Relevanz: jeder, der VOR dem Seed-Wrap 1 wei wrappt.
Fix: Uniswap-V2-Muster — beim ersten Wrap werden 1000 tote Shares an DEAD_SHARES geprägt
(MINIMUM_LIQUIDITY), `require(shares > 0)`. Regressionstest: Angriff verliert jetzt Geld, Opfer
behaelt ~100% seiner Einlage.

## MITTEL (gefixt)
- **R2 — Racks._move klemmte Transfers ueber dem Guthaben still auf das Guthaben** statt zu reverten.
  Verletzt ERC20-Semantik; jeder Integrator (Lending, DEX), der `transferFrom(X)` aufruft und X oder
  Revert erwartet, wird ueberrascht. Fix: `require(amount <= bal)`; die Klemme deckt nur noch die
  Exakt-Guthaben-Rundung. Nebeneffekt: hat einen echten Rundungs-Footgun in unserem eigenen Zap
  aufgedeckt (uebertrug nominal statt Ist-Bestand) -> Zap bewegt jetzt Ist-Bestaende.
- **W5 — Ein revertierendes/boesartiges Tax-Orakel bricked wrap/unwrap dauerhaft** (Owner-Rug-Vektor:
  Orakel auf revert setzen -> Funds im Wrapper gefangen). Fix: try/catch, Fallback auf flache Rate.
- **A5 — Nicht abgeholte Preise sperren den Pot fuer immer** (allocatedPot wird nie freigegeben).
  Fix: per-Epoche-Tracking + permissionless `sweepStale(e)` nach CLAIM_WINDOW (90 Epochen ~30d).
- **Zap/V4Swap — Rueckerstattung ging an `to` statt an den Zahler.** Wer fuer eine andere Adresse
  kauft, verlor die Rueckerstattung an sie. Fix: Refund an msg.sender / payer.

## NIEDRIG (gefixt)
- **R5** — `enableTrading()` bei Supply 0 setzte maxWallet=0 -> 1h lang jeder Kauf blockiert. Fix: require.
- **A2** — Unbekannte/wiederholte VRF-Request-ID lief in den Attack-Zweig fuer Agent 0 und korrumpierte
  Epoche-0-Shares (Pot dauerhaft an unclaimbaren Agent 0 alloziert). Fix: `require(q.kind != 0)`.
- **R7/W8** — Kein Reentrancy-Guard auf Racks.transfer/transferFrom (externer Orakel-Call in `_move`)
  und WRacks.wrap/unwrap. Fix: nonReentrant.
- **W10** — Kein Ownership-Transfer -> Admin-Rechte konnten nie an ein Multisig uebergeben werden.
  Fix: 2-step transferOwnership/acceptOwnership in Racks und WRacks.
- **Dead-Share-Senke** — `address(0xdead)` kollidierte mit Adressen aus Tests (0xDEAD == 0xdead).
  Jetzt dedizierte Konstante DEAD_SHARES. (Der Cap-Exempt der Senke ist harmlos: Burn-Adresse.)

## DESIGN-BEOBACHTUNGEN (bewusst NICHT gefixt — Entscheidung des Owners)
- **C1 — (ERLEDIGT durch Vault-Umbau)** Strafe entfaellt; abgelaufene Positionen melten normal.
- **C10 — (ERLEDIGT)** lockedSupply = Vault-Balance minus Pot; nur Nutzer-Locks zaehlen.
- **Pot-Abhaengigkeit** — der Pot lebt nur von kontinuierlichem 1d/3d-Bleed. Ohne stetige Kurz-Locker
  ist das Casino leer (2-Wochen-Sim: Pot ab Tag ~10 trocken).
- **A9 — MAX_PER_WALLET ist per Wallet-Wechsel umgehbar** (Sybil); nur CAP=10.000 bindet hart.
- **Launch-Cap-Sybil** — 1%/Wallet, 50 Wallets = 50%. Kein Wallet-Cap loest das.
- **Lock erneuert unlockAt fuer die GANZE Position** — wer zu einer Position dazulockt, verlaengert alles.
- **Owner-Macht (Vertrauensannahme)**: setExempt (koennte Pool melt-exempt machen), setLockedSupply
  (Melt-Rate in der 4.2–6.9%-Band verschieben), setCapExempt (Sniper waehrend Launch freischalten),
  setTaxOracle (Rate bis 8%-Cap). Tax-Hoehe selbst ist immutable gedeckelt. -> Admin an Multisig.
- **Infrastruktur-Abhaengigkeiten**: VRF-Ausfall verliert Angriffs-Cooldowns (attack setzt Cooldown
  vor Fulfill); VRF-Subscription muss finanziert sein.
- **TaxSwapper ist v2-only** (Uniswap-V2-Router). Im v4-Modell sammelt sich die Tax als RACKS in der
  Tax-Wallet und wird NICHT automatisch in SPY gewandelt -> v4-Swapper fehlt noch (funktionale Luecke).

## Runde 2 — nach dem Vault-Umbau (test/AuditVault.t.sol, test/v4/Stress10M.t.sol)
Gezielt angegriffen: permissionless `harvest` (Griefing/Doppel-Melt), `_settle`-Solvenz ueber 200
zufaellige Ops (lock/unlock/relock/harvest/drawPot/poke), Burn-Buchhaltung, Relock nach Ablauf,
Hinzufuegen zu Position. Ergebnis: keine Exploits.
- **Harvest-Spam** (72 Harvests/3 Tage) aendert das Ergebnis des Owners um ~0.12% — KEIN Diebstahl,
  sondern legitimer Feedback: Pot zaehlt nicht als lockedSupply -> Free Float minimal hoeher -> globale
  Melt-Rate rueckt Richtung 6.9%. Gedeckelt durch Band + 24h-Glaettung. Beobachtung, kein Bug.
- Abgelaufene Positionen fuettern den Pot nie (30 Tage getestet); Melt wird exakt gebrannt
  (Supply-Delta == Melt); Relock nach Ablauf wendet Melt zuerst an (kein Dodge).
- Solvenz-Identitaet `vault == sum(claims) + pot` haelt ueber 200 Zufalls-Ops.
- **$18.16M Volumen-Stress** (Fork): 40 Launch-Stunden-Kaeufe gegen den Cap ohne Revert, 400er
  Churn, $2M-Einzeltrade, $1.5M Einweg-Druck je Richtung: Tax stets in [400, 800] bps, Pool danach
  funktional, nichts in Zap/Swapper gestrandet, SPY im System erhalten.
- Bekannte OPERATIVE Abhaengigkeit (kein Bug): der Pot waechst nur bei Abrechnung. Vor `settle(e)`
  der Agenten sollte ein Keeper aktive Kurz-Positionen harvesten, sonst ist der Epochen-Preis 0.

## Runde 3 — Exploit-Muster aus der Praxis (test/ExploitsFromTheWild.t.sol)
Recherchierte Angriffsklassen (Balancer Nov-2025 Rundungs-Exploit im exact-out-Pfad; Lotterie-
Settlement-Timing und Rollback-/Prediction-Angriffe aus den arXiv-Taxonomien; ERC4626-Rest-
Inflation) gegen unsere Contracts angewandt. ZWEI ECHTE LUECKEN gefunden, per PoC bewiesen, gefixt:

**E1 — KRITISCH: Phantom-Share-Diebstahl ueber verspaetete VRF-Antwort.** Angreifer greift in der
letzten Sekunde der Epoche an, settlet sofort nach Epochenende (vor seiner VRF-Antwort); die
verspaetete Antwort schrieb 144 Shares in die bereits abgeschlossene Epoche -> Angreifer kassierte
den GESAMTEN allozierten Pot beider Epochen (66.892 RACKS), ehrlicher Gewinner bekam 0.
Fix: (a) `pendingAttacks[e]` — settle ist erst moeglich, wenn alle VRF-Ergebnisse der Epoche da sind
ODER `SETTLE_GRACE` (10 min) verstrichen ist (haengende VRF kann settle nicht ewig blockieren);
(b) ein Ergebnis, das NACH dem Settle landet, praegt keine Shares mehr.
**E2 — Sofort-Settle-Griefing:** jeder konnte eine Epoche im Moment ihres Endes settlen -> Preis 0.
Fix: derselbe Pending-/Grace-Gate.
**E4 — Harvest-Aushungerung:** 30 Dust-Locks (1 wei, je $3) belegten die 25 Auto-Harvest-Plaetze
-> echter Bleed nie gebucht -> Epochen-Preis 0. Fix: rotierender `harvestCursor` (jede Position
wird ueber aufeinanderfolgende Settles gebucht) + `MIN_LOCK` = 1 RACKS.
**E3 — Balancer-Klasse (Rundungs-Extraktion):** 300 krumm dosierte Wrap/Unwrap-Round-Trips im
duennen Wrapper -> Angreifer endet nie reicher. Nicht verwundbar (Ist-Delta-Messung + floor).
**E6 — ERC4626-Rest-Inflation nach toten Shares:** MINIMUM_LIQUIDITY von 1e3 auf 1e6 erhoeht ->
eine 1M-RACKS-Spende blockiert nur noch Wraps < 1 RACKS (vorher < 1000), Opfer verlieren nie
(Revert statt 0 Shares), Angreifer verbrennt ~seine ganze Spende. Unwirtschaftlich.
Rollback-/Prediction-Angriffe auf den Zufall: strukturell ausgeschlossen (Ergebnis kommt in einer
separaten VRF-Fulfill-TX, im Angriff-TX ist es unbekannt -> nichts zum Zurueckrollen).

## Runde 4 — Antwort auf das EXTERNE Audit (test/ExternalAudit.t.sol)
Jeder Diebstahl-Fund per PoC VERIFIZIERT (nicht geglaubt), dann gefixt, dann Regressionstest.

**F1 (kritisch) — Settle in falscher Reihenfolge stahl den Pot der Vorepoche.** PoC: Alice (einzige
Gewinnerin e0) bekam 0, Bob (e1) nahm 66.890 RACKS. BESTAETIGT. Fix: strikt sequenzielles Settle;
leere Vorgaenger-Epochen (keine Shares, nichts pendend) settlen automatisch mit, Epochen mit
Gewinnern muessen zuerst explizit gesettlet werden (`settledThrough`).
**F2 (kritisch) — Claim nach sweepStale war ein Double-Spend** (mein eigener A5-Fix hatte die Luecke
geoeffnet). PoC: Alice claimte 33.558 aus einer geswepten Epoche, Bob bekam 66.442 statt 100.000.
BESTAETIGT. Fix: Auszahlung wird auf `epochUnclaimed[e]` gedeckelt (nach Sweep 0) + require > 0.
**F3 (hoch) — Launch-Cap war ein Balance-Snapshot.** PoC: kaufen -> unwrappen -> kaufen: 500.000 RACKS
in EINEM Wallet bei 110.000 Cap (4.5x). BESTAETIGT. Fix: kumulatives `launchReceived`-Ledger in RACKS
(steigt nie), gespeist von Router->Wallet-Lieferungen (Zap) UND Pool->Wallet-Lieferungen (der Wrapper
meldet sie per `recordLaunchReceipt`). Peer-Transfers bleiben bewusst uncapped (Owner-Entscheidung);
Token wegzuschieben senkt den Erwerbs-Zaehler nie -> Schleife geschlossen. Fork-Test: zweiter Kauf
desselben Wallets liefert nur noch den 0.5%-Haircut-Rest.
  DEPLOY-PFLICHT: `racks.setWrapper(wRACKS)` und `racks.setCapExempt(zap)` — ohne setWrapper
  reverten Launch-Transfers an Nutzer mit "!wrapper" (fail-closed), ohne capExempt(zap) zaehlt
  der Zap-Kauf nicht und der Cap ist wirkungslos. Beides steht in STATUS.md.
**F6** — Orakel ohne Code brickte wrap/unwrap (try/catch faengt den extcodesize-Check nicht).
Fix: `require(o.code.length > 0)` im Setter + Codesize-Guard bei Nutzung.
**F7** — `_active`-Liste vergiftbar. Fix: abgelaufene Positionen unter MIN_LOCK werden beim Settle
automatisch entfernt (Dust an den Owner zurueck), MIN_LOCK 1.000 RACKS, `potLiveRange(from,count)`
zum Pagen; `harvestBatch` ist removal-sicher (swap-and-pop waehrend Iteration).
**F8** — MAX_PER_WALLET galt nur beim Mint. Fix: Cap in `_update` auf den Empfaenger.
**F9** — Unrevealter Agent war ein Zombie (nicht fuetter-/reapbar, zaehlte aber). Fix: reap nach
LIFE auch fuer unrevealte.
**Zap/V4Swap** — gestrandete Teil-Fill-Refunds. Fix: nach jedem Aufruf werden Restbestaende von
USDG/SPY/wRACKS an msg.sender gesweept; Return-Werte der Refund-Transfers werden geprueft.
**Owner-Macht** — `renounceExemptControl()` in RACKS: setExempt (der Rug-Vektor) laesst sich nach
dem Launch permanent abschalten.

**F4/F5 — GELOEST: Tax lebt jetzt AM POOL (src/v4/TaxHook.sol).** Owner-Entscheidung: "wir brauchen
unbedingt tax". v4-afterSwap-Hook nach dem Standard-"Taking-Fee"-Muster: nimmt bei JEDEM Swap die Tax
direkt aus dem Output des Swappers (hookDelta) und schickt sie per `take` an die Tax-Wallet.
Unumgehbar fuer Direkt-Trader, Bots, Router. Kauf-Tax faellt in wRACKS an, Verkaufs-Tax in SPY
(landet ohne Swapper reserve-fertig). Der Hook ruft bei jedem Swap `oracle.update()` -> das TWAP ist
nicht mehr stale (loest die Orakel-Beobachtung). Fork-Tests (test/v4/TaxHook.t.sol): Direktkauf/-
verkauf besteuert (Basis 4% + Impact), Launch 8%, nach Dump 799 bps Sell / 102 bps Buy,
**Stueckelung spart nur noch 2.3%** (vorher ~50%), revertierendes Orakel -> Fallback statt Brick.
Die Wrapper-Tax wurde ENTFERNT (ein einziges Tax-Modell; Zap-Nutzer zahlen nicht doppelt): wrap/
unwrap ist eine reine Formaenderung. Hook-Adresse muss per CREATE2 gemint werden (low 14 bits ==
AFTER_SWAP|AFTER_SWAP_RETURNS_DELTA = 0x44); der wRACKS/SPY-Pool MUSS mit dem Hook im PoolKey
erstellt werden (ein hookloser Pool haette keine Tax). Direkt-Round-Trip kostet nun ~13%.
Offen: Umwandlung der wRACKS-Tax in SPY (Tax-Wallet swappt mit `exemptSender`, damit sie sich nicht
selbst besteuert) — einfacher Keeper-Schritt, kein Contract noetig.
**OFFEN — Infrastruktur:** Deploy.s.sol ist v2-Stand (deployt weder Zap noch V4Swap noch
TwapOracleV4, kein setCapExempt/setWrapper/setTaxOracle); VRF-Interface ist fiktiv (Chainlink-v2.5-
Adapter noetig, Verfuegbarkeit auf RH ungeklaert); TwapOracleV4 sampelt nur bei wrap/unwrap.
**Frontend-Drift (nicht dieses Repo):** EXPIRED_BLEED 2%/d -> real: normaler Melt, gebrannt;
Special-Hitrate 80 -> 75; Tax-Caps 7/5 -> 8/8; useTradeTax muss wRACKS-Mengen quoten.

## Runde 5 — Komplett-Check nach dem Hook-Umbau (test/v4/HookAdversarial.t.sol + alles)
(A) Gezielte Angriffe auf den neuesten Code: exact-OUTPUT-Swaps werden auf der Input-Seite besteuert
(kein Umweg ueber den anderen Swap-Modus); Liquiditaets-Ops unbesteuert; nur der Owner kann Sender
exempten / die Tax-Wallet setzen; fremder Pool mit unserem Hook ist harmlos.
**DEPLOY-FALLE gefunden und abgesichert:** Der Hook liefert Tax-wRACKS an die Tax-Wallet; waehrend
der Launch-Stunde laeuft das durch das kumulative Cap-Ledger. Ist die Tax-Wallet NICHT exempt, hat
sie nach ~1% Tax den Cap erreicht und **jeder weitere Swap revertet — der Pool ist fuer den Rest
der Launch-Stunde tot** (Fork-Test: nach 25 Swaps). Fix/Guard: `TaxHook.wiringOk()` prueft, dass die
Tax-Wallet in RACKS exempt UND in wRACKS capExempt ist; das Deploy-Skript muss `require(wiringOk())`.
(B) Invarianten-Fuzz 1.000 Laeufe x 60 Tiefe = 60.000 Calls je Suite: keine Inflation, Index
gebunden, Rate im Band, Vault solvent, Allokation <= Pot — alles haelt.
(C) 99 normale + 40 Fork-Tests gruen.
(D) 2-Wochen-Sim und $17.9M-Stress unter dem Hook-Modell: Raritaet/Trefferquoten/Pot-Oekonomie
unveraendert; Tax faellt am Pool an (wRACKS bei Kaeufen, SPY bei Verkaeufen -> reserve-fertig);
Tax-Band stets in [400, 800]; Launch-Stunde ohne Revert.
Tax-Groessenordnung (gemessen): kleiner Trade 4.03%/4.01% -> ~8.4% Round-Trip; 1% des Pools
5.6%/4.7%; 3.3% des Pools 8.0%/6.4% -> ~14%. Der Impact-Term greift bei Whales, nicht bei
Kleinanlegern. Bei einem $5k-Launch-Pool ist JEDER mittlere Trade ein grosser Pool-Anteil -> nahe 8%.

## Runde 6 — Architekturwechsel auf v2 (atomarer Pool-Melt)
Angegriffen: Bounty-Farming (100 Wiederholungscalls zahlen 0), Doppelzaehlung des Pool-Melts
(folgt exakt dem Index-Verhaeltnis), LP-Ausstieg nach 5 Tagen Melt (funktioniert, keine Insolvenz),
Sandwich um den Melt herum (Round-Trip verliert Geld), setPair ohne Exempt (revertet),
Supply-Wirkung (Pool-Melt verkleinert die Supply wirklich). Keine Exploits.
Korrektur (Runde 9): meltPool ist fuer externe Caller NICHT epochen-gegatet — es meltet zeitbasiert
ab der ersten Sekunde. Unschaedlich (Melt+Sync atomar, Gesamtmelt aufrufunabhaengig), aber die frueher
behauptete Eigenschaft "Balance innerhalb einer Epoche konstant" gilt nur fuer den Self-Call.
Bewusste Abwaegung: meltPool traegt KEIN nonReentrant, weil der externe Self-Call aus _preOp genau
dann komplett zurueckrollen soll, wenn das Pair gelockt ist. Sicher, weil meltPool nur Pair-State
anfasst und sync() nicht in Racks zurueckruft.
Restrisiko (bekannt, klein): zwischen Epochenwechsel und erstem meltPool ist der Pool-Preis 0,09-0,15%
zu niedrig — dieselbe Arb-Klasse wie AMPL-Syncs; die Bounty haelt das Fenster praktisch geschlossen.

## Runde 7 — Antwort auf das externe Audit (N-Serie) — test/AuditN.t.sol
Alle vier per PoC BESTAETIGT, gefixt, Regressionstest.
**N1 (kritisch) — `renounceExemptControl()` war ein Flag, das niemand liest.** setExempt prueft es
nicht; nach dem Renounce konnte der Owner das Pair de-exempten — genau der Rug-Vektor, den AUDIT.md
als "permanent abgeschaltet" beschrieb. Mein Fix aus Runde 4 hatte die Datei nie erreicht und ich
hatte ihn nie getestet. Fix: `require(!exemptControlRenounced)` in setExempt + Test.
**N2 (hoch) — kein Trading-Gate.** PoC: zwischen addLiquidity und enableTrading nahm ein Sniper 20%
der Supply, launchReceived blieb 0. Fix: solange `tradingStart == 0` reverten alle Pool<->Wallet-
Transfers ("not started"); tax-exempte Adressen (Deployer) duerfen weiter seeden.
**N11 (hoch) — kumulativer Cap brickte custodial Bot-Router.** PoC: drei Nutzer a 0.3% durch
denselben Fee-Router, der vierte revertet, obwohl jedes Nutzer-Ledger 0 ist. Fix: bei
`to.code.length > 0` bucht das Ledger auf `tx.origin` statt auf den Router.
**N3 (mittel) — sequenzielles Settle unbegrenzt.** Gemessen: 81 Mio. Gas nach 3.000 leeren Epochen
(schlimmer als gemeldet). Fix: O(1) — `settled(e)` ist eine View (`e < settledThrough || _map[e]`),
und nur Epochen mit Angriffen landen in `activeEpochs` mit Cursor. Jetzt 79.556 Gas, unabhaengig vom Alter.
Niedrig: relock nach Auto-Prune kassierte die USDG-Fee fuer eine geloeschte Position (Fix: erst
settlen, dann pruefen, dann Fee); externes meltPool schreibt jetzt die Glaettung fort wie poke.
Repo: Deploy.s.sol komplett neu auf v2 (siehe unten); V2EndToEnd.t.sol und RacksOnRealV2.t.sol
entfernt (testeten das alte Modell; V2AtomicMelt deckt das echte ab) — der vom Auditor gefundene
Prank-Bug darin ist damit gegenstandslos. Der gemeldete Compile-Fehler (WRacksTax.t.sol) kam aus
einem aelteren Zip; die Datei war hier bereits geloescht.

**OFFEN — Entscheidungen des Owners (N4/N5):**
- N4: LP-Operationen werden wie Trades besteuert (Pair->LP = Buy, LP->Pair = Sell). Dritte werden
  so keine Liquiditaet stellen. Gleichzeitig ist genau das die Bremse gegen den LP-Melt-Dodge
  (Liquiditaet im Fenster rausnehmen, un-gemeltet, danach zurueck). Entweder nur eigene LP fahren,
  oder LP-Exemption plus Bedingung `pairIndex == index()` fuer Pair->Wallet-Transfers.
- N5: Bounty 0.25% des Epochen-Melts ist bei kleinem Pool nur Cent-Betraege. Wenn Bots den Job
  wirklich uebernehmen sollen, braucht es einen absoluten Mindestbetrag (bewusst als LP-Kosten).
  Aktuell traegt die Self-Heal-Logik in _preOp den Loewenanteil.

## Runde 8 — Deploy-Audit (P-Serie) — test/v4/DeployWindow.t.sol
**P1 (hoch, BESTAETIGT) — offenes Fenster zwischen addLiquidity und setPair.** Mit --broadcast ist
jeder Call eine eigene TX in einem eigenen Block. Mit vm.roll nachgestellt: in dem Fenster ist das
Pair nicht isDex -> Gate blind, Tax 0, Cap-Ledger aus. PoC: Sniper nahm **13.38% der Supply, null
Tax, launchReceived 0**. Mein alter Fork-Test konnte das nicht sehen, weil er das Skript in EINER
Test-TX ausfuehrte. Fix: `setPair` (und Orakel) VOR `addLiquidity`; der Deployer ist tax-exempt und
passiert das Gate, pairIndex wird auf leerem Pool gesetzt (erster Melt rechnet korrekt). Beide
Ordnungen sind als Tests hinterlegt (P1 = alte Reihenfolge bricht, P1b = neue haelt).
**VRF-Platzhalter (BESTAETIGT als reales Risiko).** IRSAgent startet jetzt `paused = true`;
`setPaused(false)` verlangt `vrf.code.length > 0`, ein codeloser Platzhalter laesst sich also gar
nicht scharfschalten. Ein permissionless Mock bliebe gefaehrlich — deshalb Deploy-Selbstcheck
`require(agents.paused())`.
**LP-Handling (BESTAETIGT).** LP lag beim dauerhaft tax-exempten Deployer: Scanner melden "creator
can pull liquidity", und der Melt-Dodge waere fuer ihn gratis. Skript sendet die LP jetzt an
`LP_DESTINATION` (0x...dEaD = burn), setzt `setTaxExempt(deployer, false)` und startet die
Ownership-Uebergabe an die Multisig. Selbstchecks: Deployer haelt keine LP, ist nicht mehr
tax-exempt, pendingOwner == Multisig.
**Repo-Drift (BEHOBEN).** Tote v4-Schicht entfernt: src/v4/*, src/WRacks.sol und alle zugehoerigen
Tests (inkl. der vom Auditor genannten WRacksTax/V2EndToEnd/RacksOnRealV2/RacksDirectInPool),
DeployTestnet.s.sol. Wrapper-spezifische Regressionen (W1, E3, E6, F3-Wrapper, F6-Hook) sind mit dem
Wrapper gegenstandslos und entfernt; die Token-Ebene-Regressionen bleiben. Clean-Clone-Build
verifiziert: 94 Tests gruen, 14 Fork-Tests gruen, keine Altlasten.
Niedrig, dokumentiert statt gefixt: tx.origin-Ledger teilt sich bei AA-Bundlern ein Cap (auf RH
heute nicht relevant); `renounceExemptControl` ist irreversibel und blockiert auch kuenftig noetige
Exemptions; `activeEpochs` waechst ~1.100 Eintraege/Jahr (Cursor-basiert, unkritisch).
**OFFEN (Owner):** Pot-Seed. Das Skript schickt 100% der Supply in den Pool -> Casino startet mit
Pot 0. Wenn am Launch geraidet werden soll, braucht es Supply-Reserve fuer `fundPot` oder frueh
Kurz-Locker. Widerspricht der bisherigen Doku und ist bewusst zu entscheiden.

## Runde 9 — Praezision und Doku
- **Zwei Quellen fuer dieselbe Rate** (F_FF0/F_FF1 vs. _factorEnds(0)) wichen um ~4e10 Wei auf 1e27 ab;
  ratePerDayBps() und ratePerDayBpsFor(0) konnten im letzten Bps-Digit auseinanderlaufen. Vereinheitlicht:
  die Faktortabelle ist jetzt die einzige Quelle, F_FF0/F_FF1 entfernt. Test: testSingleRateSource.
- **Abgelaufene Locks drueckten den Free Float** fuer alle, bis sie unter MIN_LOCK geprunt wurden (bei
  einer grossen vergessenen Position ueber Monate). `expiredPrincipal` wird jetzt mitgefuehrt und aus
  lockedSupply herausgerechnet. Gemessen: Rate springt nach Ablauf von 623 auf 690 bps/d zurueck.
- Doppelte Bedingung in _preOp entfernt; README auf die aktuelle Architektur umgeschrieben (beschrieb
  noch WRacks als Fallback); STATUS-Verweis auf den geloeschten RacksDirectInPool-Test korrigiert.
- Pot-Formel klargestellt: Pot_in = 0,3*r_w*V1d + 0,2*r_w*V3d + 0,1*r_w*V14d, kein W-Term.

## Runde 10 — Owner-Modell der Nachbar-Contracts (S-Serie)
**S1 — BESTAETIGT (hoch) und gefixt.** Auf dem veroeffentlichten Stand war `setAgent` owner-only
ohne jede Einschraenkung, und Vault, Agent und Orakel hatten keine Ownership-Uebergabe — das
Deploy-Skript uebertrug nur Racks. Der Deployer-Key konnte den gesamten Pot mit einem Call
umleiten, unabhaengig davon, wie gut der Token gehaertet war. Gefixt in derselben Runde: einmaliges
`setAgent`, 2-Step-Ownership in allen drei Contracts, Deploy-Skript uebergibt alle vier und prueft
alle vier im Self-Check. (Eine fruehere Fassung dieses Eintrags behauptete, der Befund beziehe
sich auf einen aelteren Stand — das war falsch und ist hier korrigiert.)
**S2 — bestaetigt und gefixt.** PoC: nach `setEpochLength(30min -> 2h)` war epochNow()=8 gegen
pairEpoch=24, der Self-Heal-Melt haette nie wieder gefeuert. `setEpochLength` re-ankert pairEpoch
jetzt auf die neue Zaehlung; Regressionstest prueft, dass der Pool danach wieder meltet.
**S3 — bestaetigt und entfernt.** `wrapper`, `setWrapper` und `recordLaunchReceipt` waren toter Code
aus der Wrapper-Aera, mit dem ein gesetzter `wrapper` fremden Wallets das Launch-Cap-Ledger haette
vollschreiben koennen. Ersatzlos geloescht.
Operativ uebernommen: USDG (Paxos) hat eine Freeze-Liste — `reserve` darf keine einfrierbare Adresse
sein, sonst reverten lock/mint/feed; `setReserve` ist der Ausweg. Steht in STATUS.md.

## Runde 11 — Migrationspfad (M1)
**M1 bestaetigt und gefixt.** PoC: Alice gewinnt 34.740 RACKS und claimt nicht; der Owner migriert
ueber den 48h-Timelock; danach revertet ihr Claim (der alte Agent darf kein drawPot mehr), und der
neue Agent startet mit allocatedPot == 0 und verteilt DASSELBE Geld erneut.
Fix: `executeAgent` verlangt, dass der alte Agent nichts mehr schuldet (`allocatedPot() == 0`), also
alle Gewinne abgeholt oder via sweepStale freigegeben sind — das passt zum Timelock-Gedanken.
Fail-closed: ein Agent, dessen Buecher nicht lesbar sind, gilt als schuldend. Der Code-Check muss
EXPLIZIT sein, weil ein `try` auf eine codelose Adresse schon an Soliditys extcodesize-Pruefung
revertet, bevor der catch greift (derselbe Fallstrick wie bei W5).
Dabei ein Folgeproblem gefunden, das der strikte Check erst sichtbar machte: pari-mutuel-Rundung
liess **1 Wei** pro Epoche in allocatedPot stehen — die Migration waere dauerhaft an Staub blockiert
gewesen. `claim` schliesst einen Epochen-Topf jetzt sauber, sobald der Rest unter DUST (1e9 wei)
faellt; der Rest bleibt unalloziert im Pot.
Ergaenzt: `forceExecuteAgent` als Notausgang nach FORCE_DELAY (30 Tage ab Vorschlag), damit ein
gebrickter Agent das Protokoll nicht fuer immer festhaelt — offene Preise gehen auf diesem Pfad
verloren, deshalb der lange Vorlauf und ein Event. `AgentChanged(old,new,forced)` und
`AgentCancelled` werden jetzt emittiert.
Kommentar korrigiert: der Timelock gibt NICHT Lockern Zeit zum Aussteigen (drawPot bewegt nur `pot`,
nie Principal) — er schuetzt Praemienberechtigte, deren Anspruch in den Buechern des alten Agenten steht.

## Runde 12 — Agent-Zeiger eingefroren (Owner-Entscheidung)
Statt M1 nur abzusichern, wurde die Faehigkeit ganz entfernt: `setAgent` ist einmalig, es gibt kein
proposeAgent/executeAgent/forceExecuteAgent mehr. Damit ist M1 gegenstandslos (keine Migration =
keine gestrandeten Preise), und der Vault hat keinen Schluessel mehr, der den Pot umleiten kann —
die staerkste Form von S1.
Voraussetzung dafuer: `vrf` in IRSAgent war `immutable`, der Agententausch war also der einzige Weg,
je eine echte Zufallsquelle anzuschliessen. Das wandert jetzt in den Agenten: `proposeVrf` mit 7-Tage-
Timelock, `executeVrf`, `renounceVrfControl` als Einbahnstrasse. Verbleibende Owner-Macht ist damit
strikt kleiner: eine manipulierte Zufallsquelle beeinflusst nur, wer gewinnt (epochenweise, gedeckelt,
sichtbar), waehrend ein Agententausch den ganzen Pot in einem Call bewegt haette.
Der M1-Dust-Fix (Epochen-Toepfe schliessen unter DUST) bleibt drin: er verhinderte, dass 1 Wei
Rundung Buchhaltung dauerhaft offen haelt.

## Runde 13 — Automatische Tax-Umwandlung, TaxSwapper entfernt
Die Tax wird jetzt IM TOKEN bei jedem Verkauf automatisch in SPY getauscht (an `reserve`).
Ein Kauf kann das nicht: `pair.swap()` haelt den Reentrancy-Lock, ein Rueck-Swap darin revertet
zwingend — Kauf-Tax wandert beim naechsten Verkauf mit. Fork-getestet gegen den echten RH-Router.
Sicherheitsrelevante Punkte dieser Aenderung (Audit-Schwerpunkt):
- Eigener Reentrancy-Guard: der Router MUSS waehrend der Umwandlung transferFrom auf uns aufrufen,
  deshalb ist genau dieser Pfad ueber `inSwap` erlaubt, jeder andere bleibt blockiert.
- `try/catch` um den Swap: eine fehlschlagende Umwandlung darf einen Nutzer-Verkauf nie kippen
  (Test erzwingt den Fall mit 0 bps Slippage-Toleranz).
- `maxSwapBps` = 0.5% der Pair-Reserve pro Umwandlung deckelt den Preis-Impact; der Rueckstand ist
  dadurch begrenzt, nicht unbegrenzt.
- Die wartende Tax ist melt- und tax-exempt (schrumpft nicht, besteuert sich nicht selbst).
`TaxSwapper.sol` und sein Test sind ersatzlos entfernt (Contract, Tests, Deploy-Wiring, Doku).
Clean-Clone-Build gruen: 100 normale + 18 Fork-Tests.

## Runde 14 — Auto-Swap-Nebenwirkungen (X-Serie)
Alle sechs Befunde uebernommen, in der vorgeschlagenen Reihenfolge.
**X2 (die schwerwiegendste) — der Verkaeufer wurde auf die Dislokation besteuert, die das Protokoll
gerade selbst erzeugt hatte.** `_swapTax` stand vor `_taxBps`, das Orakel sampelte den Post-Dump-Spot.
Fix: `bps` wird jetzt VOR jeder protokollseitigen Umwandlung berechnet.
**X1 — das Protokoll verkaufte vor seinen eigenen Verkaeufern.** Zwei Massnahmen: `maxSwapBps` von
50 auf 10 (0.1% der Reserve, unter jedem Bot-Default), und ein permissionless `swapTax()` mit
0.25%-Bounty analog `meltPool` — die Umwandlung passiert damit in EIGENEN Transaktionen, der
In-Transfer-Pfad ist nur noch Fallback, wenn niemand nachgekommen ist.
**X3 — minOut lag am Live-Quote**, gegen den sich ein Sandwich vorpositionieren kann. Jetzt gilt das
Minimum aus Live-Quote und TWAP-Bewertung als Basis; der TWAP ist in einem Block nicht bewegbar.
**X4 — `guarded` hob den Reentrancy-Schutz global auf, solange `inSwap` stand.** Jetzt ist die
Ausnahme auf `msg.sender == swapRouter` verengt; `burn` nutzt denselben Guard statt des alten.
**X5 — `enableAutoSwap` setzte `isExempt[this]` an `setExempt` vorbei** und konnte `reserve_`
jederzeit umbiegen. Jetzt an `exemptControlRenounced` gebunden, und das Ziel ist nach der ersten
Konfiguration fixiert ("reserve is fixed").
**X6 — nach `executeVrf` konnte die alte Quelle offene Requests nicht mehr erfuellen**; laufende
Mints verfielen mit den $99. Neu: `reclaimStuckMint(reqId)` nach STUCK_AFTER (3 Tage) — der
unrevealte Agent wird stillgelegt und die Mint-Gebuehr an den Zahler erstattet.
  BETRIEBSHINWEIS: `reserve` muss dem Agenten eine USDG-Allowance geben, sonst schlaegt die
  Erstattung fehl.

## Runde 15 — Folgefunde in den frischen Fixes (Y-Serie)
Beide neuen Punkte stammen aus meinen eigenen Aenderungen der Vorrunde.
**Y1 — `reap()` konnte die Erstattung zerstoeren.** LIFE und STUCK_AFTER sind beide 3 Tage, `reap`
ist permissionless und setzte `dead`, `reclaimStuckMint` verlangte `!dead`: wer zuerst reapte, machte
aus einem erstattbaren Mint fuer Gaskosten einen verlorenen $99. Fix: `dead` sperrt die Erstattung
nicht mehr; das Loeschen des Requests ist der Einmal-Schutz. Der Reap wird nachgeholt, falls noch offen.
**Y2 — die TWAP-Basis nahm die falsche Seite.** `min(Live-Quote, TWAP)` akzeptiert genau den
gedrueckten Spot, vor dem der Kommentar zu schuetzen behauptete. Jetzt `max(...)`. Bewusste Folge:
bei einem echten scharfen Kursrutsch pausiert die Umwandlung, bis der TWAP nachzieht — Verkaeufe
laufen weiter (try/catch). Deterministisch belegt in test/TwapFloor.t.sol: fairer Kurs wandelt,
gedrueckter wird verweigert, besserer wandelt, nach TWAP-Angleich laeuft es wieder.
**Y3 — `router_` und `spy_` waren weiter aenderbar.** Ein fremdes `swapSpy` mit luegendem balanceOf
haette die `out >= minOut`-Pruefung ausgehebelt. Beide sind jetzt wie die Reserve nach der ersten
Konfiguration fixiert.
**Y4 — Erstattungen ziehen per transferFrom von der Reserve.** Neu: `refundsReady()` als View, damit
die Multisig Allowance und Deckung pruefen kann, bevor jemand eine Erstattung braucht; steht im
Deploy-Log und in STATUS.md.

## Runde 16 — Z-Serie
**Z1 (hoch, mein Fehler aus X1) — Bounty wurde VOR dem `try` gezahlt.** Jeder Fehlschlag (TWAP-Floor
nach einem Dump, Router-Ausfall, SPY pausiert) wurde zur Bounty-Farm: rufen, scheitern, Bounty
behalten, wiederholen. Fix: Bounty nur im Erfolgszweig. Test: 200 Aufrufe am gedrueckten Spot
farmen exakt 0, ein erfolgreicher Aufruf zahlt genau einmal.
Dazu, wie empfohlen: die In-Transfer-Fallback-Konvertierung in `_move` ist ENTFERNT. Sie stellte
bei jedem Sell einen Protokoll-Verkauf vor die Order des Nutzers und kostete ~140k Gas pro Trade.
Konvertierung laeuft ausschliesslich ueber das permissionless `swapTax()` (Bots/Cron).
**Z3** — `setSwapParams` erlaubt jetzt hoechstens 0.5% der Reserve (vorher 5%) als Multisig-Hebel.
**setPair** ist einmalig ("pair is final").
**Z2** — effektive Slippage: die TWAP-Bewertung `amt*twap` ist ein Mid-Preis ohne 0.3% Pool-Fee
und ohne Impact, die Live-Quote enthaelt beides; die `max`-Basis ist damit praktisch immer der TWAP.
Bei 300 bps Toleranz lag die effektive Toleranz bei ~2.6%. Default auf 350 bps gesetzt, damit die
Konvertierung nicht schon bei kleinen Bewegungen pausiert.
Bot-Kompatibilitaet nach Z1: Worst-Case-Sell ohne Fallback-Konvertierung deutlich unter 400k Gas.

## Runde 17 — Abschluss
Externer Abschlussbericht (13 Runden, 07.–10.09.2026): **keine offenen Code-Findings.** Z1 verifiziert
(200 Fehlversuche farmen 0; Fork: Tax-Pot unveraendert), In-Transfer-Fallback entfernt, Worst-Case-Sell
362k Gas (vorher 536k). Verbleibend: Design-Entscheidungen (W-Term, Pot-Seed, Zufallsquelle) und die
Multisig-Vertrauensliste — beides Text, kein Code.

## Runde 18 — Zufallsquelle gebaut: HashChainSeed + Epochen-Seed im Agenten
Owner-Entscheidung: Pot wird jede Epoche geleert (Rule 1+2 verworfen); Zufall = vorab festgelegte
Hash-Kette, ein Seed pro Epoche, mit den zwei Keeper-Regeln (Withhold = alle verlieren; Kaution).
Sicherheitswirkung des Umbaus: die gesamte Klasse der VRF-Timing-Exploits (E1 Phantom-Shares,
E2 Sofort-Settle, X6/Y1 Stuck-Mint) ist STRUKTURELL weg — es gibt keine Requests mehr. Der Agent ist
mit 315 Zeilen kleiner als vorher (322) trotz neuem Tally.
Getestet (test/HashChainSeed.t.sol, test/IRSAgent.t.sol): Reveal muss zur Kette passen, kein Replay,
kein Reveal einer offenen Epoche; voller Ablauf Mint -> Reveal -> Attack -> Reveal -> Settle -> Claim
mit der echten Quelle; Zurueckhalten -> permissionless Slash -> Kaution in den Pot -> jeder verliert;
Mint in einer failed Epoche wird vom naechsten guten Seed enthuellt; nur der Keeper deckt auf, Kaution
darf nicht unter eine Strafe fallen; Tally seitenweise; Settle ohne Seed unmoeglich.
Invarianten-Handler ist jetzt selbst die Seed-Quelle und haelt zufaellig Epochen zurueck — Solvenz
und Allokation halten weiter. Deploy-Skript deployt die Quelle mit (KEEPER-Env), fuenf Ownerships.
NEU ZU AUDITIEREN (das eine ungeschriebene Kapitel, jetzt geschrieben): src/HashChainSeed.sol und die
Tally-/Reveal-Logik in IRSAgent.

## Runde 19 — K-Serie: das Zufallskapitel hielt nicht
**K1 (kritisch, mein Analysefehler).** Der `attackDigest` im Seed war kein Schutz, sondern ein
Grinding-Eingang: der Keeper kennt jedes Urbild und konnte den Digest mit eigenen Angriffen so lange
verlaengern, bis der Seed seine Agenten gewinnen liess (10 Agenten = 1.023 Kandidaten/Epoche, ~85% des
Pots, ohne je einen Reveal zu verpassen). Mein Satz "niemand kennt das Ergebnis vor Schluss" war fuer
den Keeper exakt falsch herum. Fix nach Auditor-Vorschlag: reveal-then-play — Urbild am Epochenanfang
enthuellen (oeffentlich, entscheidet allein nichts), Unvorhersagbarkeit aus einem Post-Close-Blockhash,
den kein Spieler steuert; Angreifer-Input aus dem Seed entfernt. Test testK1: der Keeper greift mit
eigenen Agenten an, der Seed haengt nur von Urbild + Close-Hash ab.
**K2 (hoch).** Slash von 1M RACKS war bei 69B Supply ~7 Cent — Zurueckhalten kostete nichts. Fix:
Slash = max(Floor, aktueller Pot), Kaution muss das decken, `attack()` verweigert bei Unterdeckung.
**K3.** Keeper 2h offline: Epoche faellt, alle verfehlen (gewollt). Keeper gibt auf: Mints blieben
unrevealed, $99 verloren. Fix: `reclaimUnrevealed` nach 7 Tagen mit Erstattung aus der Reserve.
Restvertrauen, explizit: der Close-Blockhash stammt vom RH-Sequencer (kein Stake). Entfernbar nur
ueber CCIP (proposeVrf-Pfad). chain.json ist als pot-wertiges Geheimnis im Runbook markiert.

## Runde 20 — C-Serie: dieselbe Luecke im zweiten Baustein
**C1 (kritisch, mein Fehler von gestern).** `captureClose` nahm den Hash des VORBLOCKS der ersten
Transaktion nach Epochenende — permissionless und lazy. Mit oeffentlichem Urbild rechnet ein Spieler
fuer jeden neuen Block den Kandidaten-Seed aus und fasst die Epoche erst an, wenn ihm das Ergebnis
gefaellt (PoC: 185 Bloecke warten, 100% des Pots). "no single party picks the block" war falsch — die
erste Partei tat genau das. Fix nach Auditor-Vorschlag, zwei Schritte: der erste Toucher fixiert nur
eine ZUKUENFTIGE Blocknummer (Hash unbekannt), eine spaetere Transaktion innerhalb von 256 Bloecken
friert den Hash ein (nur festhalten, nicht waehlen); bei Verfall neue Zukunftsnummer. Tests testC1_*.
Keeper-Bot tickt 15 s statt 5 min, damit das Einfrieren innerhalb der ~64 s auf RH sicher passiert.
**C5 (mittel, das Y1-Muster erneut).** `reap` (3 Tage) sperrte `reclaimUnrevealed` (7 Tage) ueber
`!dead`. Fix: eigenes `refunded`-Flag als Einmal-Schutz, `dead` sperrt nicht. Test testC5.
**C6.** Reveal war bis 2h nach Schluss erlaubt — dann kannte der Keeper den Seed vor dem Reveal.
Jetzt nur bis Epochenende ("epoch over"); Slash ab Epochenende.
**C7.** `fundPot` kann den Pot ueber die Kaution heben und Angriffe sperren — Griefing auf eigene
Kosten, dokumentiert in STATUS.

## Runde 21 — R7-Serie (Zufallsbaustein + Launch-Pfad)
**R7-1 (hoch) — Slash-Drain durch Dritte.** Kein Untergrenze ab commit(): jeder konnte alle Epochen
aus der Pausenzeit slashen (PoC: 32M von 50M Bond, danach bondOk false, niemand kann angreifen);
zudem potenzierte sich der Slash, weil er in den Pot floss und damit den naechsten erhoehte.
Fix: `firstEpoch` beim commit, `slash` nur ab da UND nur fuer Epochen mit Angreifern; Trennung von
`requiredBond()` (Gate, ungedeckelt) und `slashAmount()` (Abzug, max. ein Viertel der Kaution).
Beim Bauen gefunden: die Deckelung allein haette `bondOk()` bedeutungslos gemacht (Kaution deckt
immer ein Viertel von sich selbst) — daher die Trennung.
**R7-1b (mittel) — Bond-Buchhaltung auf Nominalwerten.** Ein Wei Rundung haette einen vollen Slash
reverten lassen und damit `settle` fuer alle Folgeepochen blockiert. Fix: Ist-Delta messen
(deposit/withdraw), plus `syncBond()`.
**R7-2 (mittel) — Re-Roll war C1 durch die Hintertuer.** Wer den geminten Hash sah, konnte das
Fenster verfallen lassen, bis ein Kandidat passte. Fix: Fensterverfall = Epoche failed + Slash.
**R7-3 (mittel) — Quellentausch verlor Historie.** Fix: Tier wird beim ersten Reveal gecacht
(automatisch beim ersten Angriff), `executeVrf` nur bei vollstaendig gesettleten Angriffs-Epochen.
**R7-4 (mittel) — verlorene chain.json brickte die Quelle.** Fix: `proposeChainReset` + 3 Tage.
Zusaetzlich: die Kaution haengt am Keeper-Slot (Nachfolger erbt sie nicht, sie geht in den Pot).
**R7-5 (mittel) — `swapTax()` verbrannte das Launch-Kontingent des Aufrufers.** Lieferungen INS Pair
wurden auf tx.origin gebucht. Fix: `if (isDex[to]) return;` in `_recordLaunch`.
Zusatz: `reap` verlangt jetzt `revealed` — ein noch erstattbarer Agent kann nicht weggeraeumt werden.
Die uebrigen Beobachtungen (minIndex-Ende der Demurrage, LP-Ops als Trades, sekundaere Pairs,
AA-Bundler, Settle-Timing, SPY-uiMultiplier, setEpochLength ohne Obergrenze) stehen als bekannte
Eigenschaften bzw. Vertrauensannahmen in STATUS.md.

## Runde 22 — R8/R9: Wurzelfix statt Symptomfix
**R8-1 (die wichtigste) — eine Regel, drei Implementierungen.** `index()` klemmte bei minIndex,
`meltPool` und `_split` riefen rpow direkt: nach ~190 Tagen war Halten strikt besser als Locken und
der Pool meltete gegen einen konstanten SPY-Bestand leer. Fix: EINE Funktion `Racks.decayIndex(idx,
pos, dt)` mit dem Floor, benutzt von Token, Pool und Vault; der Vault fuehrt dafuer einen eigenen
kumulativen Index pro Position. Belegt nicht nur punktuell, sondern als EIGENSCHAFT
(test/MeltLawProperty.t.sol, 4 Fuzz + 2 Integrationsproben): nie unter den Floor, Floor absorbierend,
Zerlegung des Intervalls aendert nichts, die Fuenf-Positionen-Leiter haelt zu JEDEM Zeitpunkt, und
Vault wie Pool folgen messbar derselben Kurve. Ein kuenftiger privater Decay-Pfad faellt hier auf.
**R9-1** — `payout > 0` liess vollstaendig gemeltete Positionen fuer immer in der aktiven Liste
(passiert jeder Position durch Zeitablauf). Fix: Prune auch bei 0.
**R9-2** — `settle` rief `tally(e, max)`; bei 10k Agenten ~219M Gas und damit eine Blockade aller
Folgeepochen. Fix: gedeckelter Auto-Tally (TALLY_STEP), sonst "tally first".
**R9-3** — `_revealSeed` lief linear ueber alle failed Epochen (483k Gas nach 120) und steckte in
jedem attack(). Fix: Scan auf REVEAL_SCAN begrenzt, `revealed()` O(1) sobald der Tier gecacht ist.
**R8-3** — `setEpochLength` ohne Obergrenze konnte den Melt einfrieren. Fix: MAX_EPOCH = 1 Tag.
**R8-5** — Kaution pro Keeper: bereits in Runde 21 gefixt (Bericht lief auf aelterem Stand).
**R8-6 / R9-4 / R8-7 / R8-8** — Doku korrigiert bzw. als bekannte Eigenschaften aufgenommen.
**R9-5** — Launch-Cap = ~$51 pro Adresse; Tabelle und Stellschrauben in STATUS.md, Owner-Entscheidung.
**OFFEN, bewusst nicht in dieser Runde:** R8-2 (Settle-Timing bepreist den ganzen Bleed mit dem
Faktor des Settle-Moments) und R8-4 (Rotationsfenster vs. Dust-Flood) haben dieselbe Wurzel: die
Pot-Buchhaltung laeuft pro Position statt ueber einen kumulativen Tier-Index. Der richtige Fix ist
derselbe wie bei R8-1 — Aggregat statt Iteration — und macht `harvestBatch` fuer die Pot-Buchung
ueberfluessig. Das ist ein Vault-Umbau, kein Patch; er gehoert in eine eigene Runde mit eigenen
Eigenschaftstests, nicht schnell hinterher.

## Runde 23 — eigener Durchgang nach Fehlerklassen (statt nach Einzelfaellen)
Gesucht wurde nach den drei Klassen, die die letzten Runden erzeugt haben: doppelt implementierte
Logik, unbegrenzte Schleifen, Timing-Abhaengigkeit.

**Gefunden in MEINEM R8-1-Fix (gravierend):** der Halter-Pfad INTEGRIERT die Rate (`index()` wird an
jeder Epochengrenze mit der damals gueltigen Rate fortgerollt), waehrend `decayIndex` die gesamte
verstrichene Zeit mit der Rate im Lesemoment bewertete. Mein Fix hatte diese Semantik auf den Pool
ausgeweitet. Das ist R8-2, und es betraf damit zwei statt einer Stelle.
Fix: kumulative Indizes pro Positionstyp (`posIndex(p)`), die im selben `_preOp`-Schritt wie der
Halter-Index fortgerollt werden. Vault und Pool lesen jetzt Verhaeltnisse dieser Indizes statt selbst
zu decayen. Ergebnis, gemessen: Pool nach einem Melt und nach 40 Melts **auf das Wei identisch**;
Vault einmal vs. zwoelfmal abgerechnet 0,006 % auseinander (vorher +598 bps fuer den Nutzer,
-5.327 bps fuer den Pot). Tests testR82_SettleTimingDoesNotChangeOutcomes und
testR82_PoolMeltFrequencyInvariant.
Restliche Ungenauigkeit, bewusst und dokumentiert: der EINE Uebergangsschritt bei Ablauf einer
Position (der Tier-Index zum exakten Ablaufzeitpunkt ist nicht historisiert) wird weiterhin mit dem
aktuellen Faktor genaehert. Einmalig pro Position, begrenzt durch die Zeit bis zur ersten Abrechnung
nach Ablauf.
Nebenbefund: `posIndex` konnte nach `setEpochLength` unterlaufen (dieselbe Klasse wie S2) — jetzt
unterlauf-sicher und im Setter re-verankert.
Genauigkeitsgewinn: der Live-Pot trifft jetzt den analytisch korrekten Wert (10.404 statt 8.364 fuer
12 h auf der 1d-Stufe) — die frueher erwartete Zahl stammte aus der ungenauen Per-Position-Rechnung.

Unbegrenzte Schleifen, geprueft: `agentsOf` ist eine reine Off-Chain-View (kommentiert); `potLive`
hat mit `potLiveRange` eine Paging-Variante; `harvestAll` ist dokumentiert; `tally` und `_revealSeed`
sind seit Runde 22 gedeckelt. Kein neuer On-Chain-Pfad mit unbegrenzter Iteration.

## Runde 24 — Wurzelfix der Pot-Buchhaltung (R8-2-Rest und R8-4)
Beide Restpunkte hatten dieselbe Ursache: der Vault buchte den Pot PRO POSITION durch Iteration.
Daraus folgte das Rotationsfenster (man kann nicht alle Positionen anfassen) UND die Naeherung beim
Ablauf (der Regimewechsel haing am Besuch der Einzelposition).
Umbau: der Pot wird ABGELEITET statt gebucht. Die gebluteten RACKS verlassen den Vault nie, also ist
  pot = Bestand − totalOwed() − pendingBurn(),
alles in O(1) aus kumulativen Indizes. Positionen halten `scaled`, ihr Wert ist `scaled * I`.
Ablauf laeuft ueber Buckets je Ablauf-Epoche: `advance(tier, maxEpochs)` stellt ganze Buckets um und
haelt in `expiryRatio` das Umrechnungsverhaeltnis fest — Aggregat und Einzelposition benutzen damit
exakt dieselbe Zahl (verifiziert: Summe der Positionen == totalOwed() auf 1 Wei ueber 6 Zeitschritte).
Entfallen: aktive Positionsliste, harvestBatch-Rotation, Prune-Logik, `pot`-Zaehler. Shims fuer
`pot()/harvest()/harvestAll()/activeCount()` bleiben, damit Aufrufer nicht brechen.
Beim Bauen gefunden und gefixt (haette sonst die naechste Runde ergeben): `scaled` mit dem
Unlocked-Index zu lesen, bevor die Umrechnung stattfand (falscher Wert); `burnExpired()` NACH dem
Bucket-Move (haette echte Token fuer nie angefallenen Melt verbrannt); `advance` liess die laufende
Epoche aus (Regimewechsel eine Epoche zu spaet); `e + maxEpochs` lief in uint32 ueber.
Verbleibende Betriebsabhaengigkeit, bewusst: die Umstellung nutzt die Indizes im Moment des
`advance()`-Aufrufs. Zeitnah (Keeper jede Epoche) ist sie exakt; mit Rueckstand bleeden abgelaufene
Positionen laenger zur Tier-Rate. Der Keeper-Bot ruft `advance()` fuer alle drei Stufen plus
`burnExpired()` in jedem Tick.

## Runde 25 — detaillierter Durchgang durch den neuen Vault
Acht gezielte Proben (test/VaultDetail.t.sol) auf den frisch umgebauten Code. Zwei echte Funde:

**D1 — `_bucketOf` nahm 1800 Sekunden als Epochenlaenge an**, obwohl der Owner sie zwischen 15 min und
1 Tag setzen kann. Mit abweichender Laenge landeten Positionen in unerreichbaren Buckets (Unterlauf).
**D6 — und die Wurzel darunter: Buckets waren nach EPOCHENNUMMERN indiziert.** `setEpochLength`
nummeriert Epochen neu, also strandeten laufende Positionen in Buckets, die nie verarbeitet werden.
Fix: Buckets haengen jetzt an einem FESTEN Wanduhr-Fenster (`BUCKET = 30 min`, `ts / BUCKET`) und
nicht mehr an der Epochennummerierung. Nur vollstaendig verstrichene Buckets werden gerollt, damit
eine Position nie VOR ihrem Ablauf umgestellt wird — schlimmstenfalls bleibt sie 30 min laenger auf
der Tier-Rate. D6 prueft jetzt eine Laengenaenderung mitten im Betrieb: beide Positionen bleiben
erreichbar und lassen sich ausloesen.
Dazu: stille `if (bucket >= scaled)`-Skips durch `require(..., "bucket drift")` ersetzt — eine
Abweichung zwischen Aggregat und Einzelposition schlaegt jetzt laut fehl statt still zu driften;
toter Code (`_epochOf`) entfernt.

Bestanden und damit belegt: Aggregat == Summe der Positionen ueber 40 zufaellige Operationen
(D2, Toleranz 1e-6 RACKS); der Regimewechsel erhaelt den Wert **auf 1 Wei** (D3); Relock aus dem
abgelaufenen Zustand erhaelt den Wert und laesst keinen Rest zurueck (D4); abgelaufener Melt wird
gebrannt und erreicht den Pot nicht (D5); `burnExpired` kann den Vault nicht bricken, der Locker
kommt immer raus (D7); kein verdeckter Fehlbetrag hinter der 0-Klemme von `potBalance` (D8).

Bestaetigte Betriebsabhaengigkeit (kein Bug, aber messbar): die Umstellung nutzt die Indizes im
Moment des `advance()`-Aufrufs. Mit Keeper-Kadenz (alle 30 min) ist sie praktisch exakt; die aelteren
Tests, die tagelang sprangen und einmal rollten, zeigten bis zu 6 % Abweichung im Pot — sie bilden
jetzt die Keeper-Kadenz nach. Das ist genau die Groessenordnung, um die der Pot zu kurz kommt, wenn
der Bot laenger ausfaellt.

## Runde 26 — Ursache der Epochen-Klasse beseitigt
D1 und D6 waren wieder nur die betroffene Stelle. Die URSACHE war die Epochennummerierung selbst:
`epochNow()` wurde als `(now - startTime) / epochLength` GERECHNET, also nummerierte jede
Laengenaenderung die gesamte Vergangenheit neu — Nummern konnten sogar rueckwaerts springen.
Daraus sind drei Bugs entstanden, jeder einzeln geflickt: S2 (`pairEpoch` gestrandet, Self-Heal-Melt
feuerte nie wieder), der `posIndex`-Unterlauf, und die unerreichbaren Ablauf-Buckets (D1/D6).
Fix: der Zaehler ist jetzt KUMULATIV (`epochBase` + verstrichene Epochen seit `epochAnchor`).
`setEpochLength` rechnet alle Indizes unter der alten Laenge durch, traegt den Zaehler weiter und
laesst die neue Laenge ab jetzt zaehlen. Nummern bewegen sich nur noch vorwaerts; die lokalen
Re-Anchor-Hacks in `setEpochLength` sind ersatzlos entfallen.
Als EIGENSCHAFT gepinnt (test/MeltLawProperty.t.sol, je 256 Laeufe):
- P7 `epochNow()` faellt nie — weder ueber Zeit noch bei sechs zufaelligen Laengenaenderungen.
- P8 kein Index springt bei einer Laengenaenderung (Halter und alle fuenf Positionstypen).
- P9 eine gesperrte Position bleibt ueber beliebige Laengenaenderungen erreichbar, Aggregat und
  Position stimmen weiter ueberein, und der Ausstieg revertet nicht.
Damit kann diese Fehlerklasse nicht mehr entstehen, statt an der naechsten Stelle erneut aufzutauchen.

## Runde 26 — Schnittstellen, Oekonomie, Gas
Neue Winkel: die Naehte zwischen Token, Vault, Agent und Zufallsquelle; die Kautions-Oekonomie;
das Gasprofil der neuen Vault-Pfade (test/InterfaceAudit.t.sol, test/GasProfile.t.sol).

**Gefunden (Gas, gravierend genug fuer einen Nutzer):** `advance` schrieb fuer JEDEN durchlaufenen
Bucket ein Umrechnungsverhaeltnis — auch fuer leere. 64 Buckets x ~20k = 1,28 Mio. Gas, und ein
`unlock` nach einer Woche ohne Keeper kostete **2.006.078 Gas**. Fix: das Verhaeltnis wird nur fuer
Buckets geschrieben, die tatsaechlich Positionen hielten (nur dort wird es je gelesen). Danach:
**562.298**. Zweite Optimierung: ein `advance` ohne zu rollende Buckets und ohne ausstehenden Burn
kehrt jetzt zurueck, ohne Storage anzufassen (107.958 -> 42.931) — der Keeper ruft es dreimal pro Tick.
Beim Optimieren selbst einen Fehler eingebaut und gefunden: `burnExpired` fruehzeitig zu verlassen
liess `burnIdx` stehen und erzeugte damit wieder einen Phantom-Burn fuer spaeter ablaufende
Positionen (15 Tests rot, darunter die Solvenz-Invariante). `burnIdx` wird jetzt immer nachgezogen,
nur der Burn-Aufruf selbst entfaellt bei 0.

Gasprofil danach (Keeper laeuft): lock 385k (erste Position) bzw. 315k, unlock 177k, advance mit
einem Bucket 268k, Leerlauf 43k, claimOf 25k, potBalance 61k.

Geprueft und in Ordnung:
- **I1/I5 — die Epochen-Klasse**: Agent und Zufallsquelle haben eine EIGENE Uhr (8-h-Konstante,
  unabhaengig von `epochLength`). `setEpochLength` verschiebt weder `currentEpoch`, noch
  Epochengrenzen, noch den Slashing-Bereich der Quelle. Die Klasse, die dreimal zuschlug, greift hier
  nicht — jetzt belegt statt vermutet.
- **I2 — Keeper-Ausfall blockiert die Settle-Kette nicht.** Eine verpasste Epoche kann NIE mehr
  enthuellt werden (Reveal nur vor Epochenende); Epochen mit Angreifern werden per `slash` aufgeloest,
  Epochen ohne Angreifer stehen nicht in `activeEpochs` und blockieren daher nichts. Nach dem Ausfall
  laeuft die Kette weiter.
- **I3** Direktspende an den Vault hebt nur den Pot, senkt nie die Schuld.
- **I4** Der Agent kann den Pot nicht ueberziehen; danach sind die Locker weiterhin gedeckt.
- **I6 (Oekonomie)** `requiredBond` = aktueller Pot. Da `settle` den Pot jede Epoche leert, bleibt er
  klein gegenueber dem TVL: gemessen deckte eine Kaution von 20 Mio. einen Pot von 302k muehelos.
  Die Anforderung greift erst, wenn der Pot die Kaution uebersteigt — dann sind Angriffe gesperrt,
  bis der Keeper nachlegt. Betriebspunkt fuer das Runbook, keine Bremse.

## Runde 27 — externer Vollaudit (Commit 1192e6e) gegengeprueft
Der Bericht lief auf einem Stand VOR den Runden 21-26. Gegen den aktuellen Code geprueft:
F-02, F-03, F-06, F-07, F-08, F-09, F-10, F-11, F-12, F-13, F-14, F-15, F-16, F-17, F-18, F-19 sind
bereits behoben (jeweils mit Regressionstest). TaxSwapper ist entfernt. F-04 (Launch-Cap ~50 USD)
und F-21 (LP-Ops besteuert) sind Owner-Entscheidungen und bleiben so gewollt — 5.000 USD Seed.

**F-01 (KRITISCH, neu und real): die Contracts waren nicht deploybar.** Ohne Optimizer lagen
`Racks` (31.056) und `IRSAgent` (31.446) ueber dem EIP-170-Limit von 24.576 Bytes; `foundry.toml`
setzte keinen. Warum das 26 Runden lang unsichtbar blieb: Foundry erzwingt die Groessengrenze in
Tests NICHT — auch der Fork-Test, der das echte Deploy-Skript ausfuehrt, lief durch. Fix: Optimizer
(runs = 200) aktiviert; Groessen jetzt Racks 16.508 / IRSAgent 17.395. Damit das nie wieder
unbemerkt passiert, ist die Grenze als Test verankert (test/DeployabilityAudit.t.sol), der jeden
Contract deployt und `code.length < 24576` prueft.

**F-05 (hoch, real): `setExempt(pair,false)` konnte den Pool toeten.** Der Bericht empfiehlt,
`renounceExemptControl()` frueh zu rufen — das ist eine Umgehung, keine Behebung: es bleibt ein
Zeitfenster und eine Bedienhandlung. URSACHE gefixt: `setExempt` kann das registrierte Pair gar
nicht mehr de-exemptieren ("pair must stay exempt"). Andere Adressen bleiben schaltbar.

**F-25 enthielt versteckt einen Fund der Klasse, die uns dreimal getroffen hat:** `ratePerDayBps()`
war eine ZWEITE, hartkodierte Formel (420 + 270*FF), nicht aus der Faktortabelle abgeleitet. Heute
stimmten beide zufaellig ueberein; jede kuenftige Aenderung an den Faktoren haette sie still
auseinanderlaufen lassen. Jetzt abgeleitet, mit Test.
Rest aus F-25 umgesetzt: Events auf allen beobachtbaren Settern (setEpochLength, setLockedSupply,
setSwapParams, enableAutoSwap, setDex/Exempt/TaxExempt/CapExempt, setTaxWallet, setTaxOracle,
setVault, setPair, Ownership, drawPot, withdrawBond, setSlash, setAutoHarvest, setReserve);
Zero-Checks auf allen Adress-Settern und transferOwnership; `approve`-Rueckgabe geprueft;
`minCum` explizit initialisiert; Shadowing in `position()` aufgeloest; DynamicTax-Header (7/5 ->
8/8) korrigiert.

Offen und bewusst so: F-20 (sweepStale), F-22 (nicht registrierte Pairs), F-23 (Doku), F-24
(meltPool-MEV) — dokumentierte Eigenschaften.

## Runde 28 — Regressionen aus den eigenen Fixes (N-Serie)
Alle fuenf an der URSACHE behoben, jede mit Regressionstest.

**N-01 (hoch) — `lock()` in eine abgelaufene Position revertete IMMER.** Der Expired-Zweig faltet
die Position zurueck, fiel danach aber in die generische Bucket-Subtraktion, obwohl `advance()` den
Bucket laengst geleert hatte -> `require(expiringAt >= scaled)` schlug zwangslaeufig fehl. `relock`
machte es richtig — der Unterschied lag im Codepfad, nicht im Zustand. Fix: der gefaltete Fall
ueberspringt die Subtraktion (`wasFolded`). Test: Aufstocken einer abgelaufenen Position fuegt exakt
den neuen Betrag hinzu, Aggregat stimmt weiter.
**N-02 (hoch) — eine leere, verpasste Epoche war unaufloesbar und toetete ihre Mints.** URSACHE:
`failed` trug ZWEI Bedeutungen — Strafe fuer den Keeper UND Signal "diese Epoche ist tot". Da
`slash()` nur bei Angreifern feuert, blieb eine leere Epoche ewig unmarkiert. Die zweite Bedeutung
ist jetzt ABGELEITET statt gespeichert: `unrevealable(e)` = kein Preimage und Epoche vorbei;
`failed(e) = _failed[e] || unrevealable(e)`. Slash schreibt weiter den Strafflag und bestraft
weiterhin. Test: ein in der verpassten Epoche geminteter Agent wird vom naechsten guten Seed
enthuellt und kann spielen.
**N-03 (mittel) — `meltPool()` schob `checkpointEpoch` vor, ohne die Positionsindizes zu rollen.**
Dieselbe Klasse wie F-02/R8-2: ein Schritt, drei Implementierungen, eine davon unvollstaendig — und
weil der Keeper `meltPool()` alle 15 s ruft, war sie meist die erste Transaktion der Epoche. Fix:
ein einziges `_rollEpoch()`, benutzt von `_preOp`, `meltPool` und `setEpochLength`. Test: nach 300
Epochen sind die Indizes in der meltPool-Welt und der poke-Welt **auf das Wei identisch** (vorher
12 bps auseinander).
**N-04 (mittel) — das Reveal-Fenster war an `mintEpoch` verankert und wanderte nie.** REVEAL_SCAN
von 16 auf 24 Epochen (8 Tage) erhoeht, damit es die Erstattungsfrist (`UNREVEALED_AFTER` = 7 Tage)
ueberdeckt: ein Agent ist damit immer entweder enthuellt ODER erstattbar, nie beides nicht.
**N-10 (Chain-Annahme) — auf RH GEMESSEN statt angenommen**: alle 32 letzten Blockhashes sind
nicht-null (test/v4/BlockhashProbe.t.sol, Fork). Die Annahme haelt. Zusaetzlich wie empfohlen
abgesichert: der Lapse-Zweig slasht nur noch den FLOOR statt `slashAmount()` — ein
Infrastrukturausfall darf die Kaution nicht in Vierteln aufzehren.

**N-05 — bewusst NICHT als "behoben" verkauft.** Der Regimewechsel liest die Indizes im Moment des
`advance()`-Aufrufs. Zeitexakt waere er nur mit einer Index-Historie pro Epoche on-chain (~100k Gas
JEDE Epoche, dauerhaft). Statt das zu bezahlen oder das Problem wegzureden, ist es jetzt gemessen
und begrenzt: mit Keeper-Kadenz liegt der Wechsel innerhalb eines 30-Minuten-Buckets; ein ganzer Tag
Rueckstand schenkt dem Locker **115 bps** (Test testN05_RegimeChangeDependencyIsBounded, Schranke
400 bps). Die Richtung ist immer zugunsten des Lockers, nie zulasten.

## Runde 29 — Folgebefunde aus dem N-02-Fix (N-06 bis N-13)
**N-12/N-13 (hoch) — der Lapse-Zweig umging die `nothing at stake`-Sperre.** `slash()` hatte sie,
`captureClose()` nicht: zwei Transaktionen pro LEERER Epoche (Zukunftsnummer fixieren, 256 Bloecke
warten, ausloesen) schoben die Kaution in den Pot — wiederholbar, bis `bondOk()` faellt und
`attack()` protokollweit verweigert. Kein reines Griefing: wer selbst Agenten haelt, verwandelt die
Kaution in eigenes Preisgeld. Mein N-02-Fix hatte es sogar erleichtert, weil `resolved(e)` fuer eine
verpasste Epoche jetzt sofort true ist und der Keeper-Bot sie ueberspringt — das Fenster stand offen.
Fix: derselbe `attackersOf(e) > 0`-Vorbehalt im Lapse-Zweig; die Epoche wird weiterhin als tot
markiert (blockiert also nichts), kostet aber nichts. Test: 9 leere Lapse-Versuche lassen die
Kaution bei exakt 100M; eine GESPIELTE Epoche bestraft weiterhin, gedeckelt auf den Floor (N-10).
Beim Schreiben dieses Fixes ist mir aufgefallen, dass zwei fruehere Edits (N-10-Floor, N-12-Sperre)
den Block nie erreicht hatten — der Test hat genau das aufgedeckt, bevor es ins Paket ging.
**N-11 (Regression aus N-02) — `failed()` rief `agent.epochEnd()` in einer 24er-Schleife zurueck**:
`revealed()` kostete wieder 175k statt 14k. Die Uhr des Agenten ist unveraenderlich, also wird sie
in `setAgent` einmal gecacht (`agentStart`, `agentEpochLen`) und `unrevealable` rechnet lokal.
Gemessen: **16.787 Gas** bei komplett totem Scan-Fenster.
**N-06** — vier Events waren deklariert und wurden nie emittiert (EpochLengthSet, LockedSupplySet,
TaxExemptSet, TaxOracleSet). Nachgezogen. **Dabei einen eigenen Fehler gefunden:** beim
Event-Einbau war die `no code`-Pruefung in `setTaxOracle` (F-06) verloren gegangen — wiederhergestellt.
**N-08** — `feed()` ruft jetzt `cacheTier(id)`, damit Fuettern nicht jedes Mal den Scan bezahlt.

## Runde 30 — N-18 (korrigierte Diagnose) und N-09
**N-18 — die Ursache war NICHT der externe Rueckruf.** Der Auditor hat seine eigene Diagnose aus der
Vorrunde korrigiert, und die Messung gibt ihm recht: das Entfernen des Rueckrufs brachte nur
175.295 -> 157.539, weil jede gescannte Epoche ~5.9k Gas kostet (zwei kalte Reads in getrennten
Mappings plus externer Aufruf). Solange jeder Aufruf den Scan von vorn beginnt, ist das durch kein
Caching auf der Quellenseite wegzubekommen.
URSACHE behoben: ein CURSOR pro Agent (`scanFrom`) statt einer Wiederholung, permissionless
vorschiebbar (`advanceScan`). Voraussetzung selbst nachgeprueft statt uebernommen: `failed()` ist
monoton — `_failed` wird nie geloescht, und `unrevealable` haengt an `preimage == 0`, das nach
Epochenende nicht mehr gesetzt werden kann. Damit kann der Cursor nur vorwaerts und veraendert kein
Ergebnis: der Tier kommt immer aus der ERSTEN nicht-toten Epoche, niemand kann einen Seed aussuchen
(im Test verifiziert: `tier` bleibt nach erneutem Vorschieben identisch).
Gemessen bei komplett totem 24-Epochen-Fenster: **159.380 -> 5.679 Gas**. Das loest zugleich N-04
struktureller als die Erhoehung auf REVEAL_SCAN = 24: der Cursor laeuft ueber beliebig lange
Ausfaelle hinweg, statt an einem festen Fenster zu enden.
**N-09 — toter Code gefunden und entfernt:** `autoHarvest` und `setAutoHarvest` im IRSAgent stammten
aus der Rotations-Ernte, die mit der Aggregat-Buchhaltung des Vaults weggefallen ist.
Keeper-Runbook um `advanceScan` ergaenzt (optional, reine Gas-Optimierung).

## Runde 31 — N-19 bis N-22
**N-19 (hoch, bestaetigt) — `advanceScan` konnte fremde Erstattungsansprueche vernichten.**
`reclaimUnrevealed` haing an `!revealed(id)`, und `revealed` leitet sich aus dem permissionless
verschiebbaren Cursor ab. Genau der Keeper-Bot, der nach einem Ausfall `advanceScan` ruft, haette
reihenweise Ansprueche von Agenten geloescht, die waehrend desselben Ausfalls verhungert sind.
**Den vorgeschlagenen Fix habe ich NICHT uebernommen.** `!tierCached` allein oeffnet ein schwereres
Loch: ein Agent, der enthuellt wurde, aber nie eingesetzt wird, waere nach 7 Tagen erstattbar — Mint,
schlechten Tier sehen, verfallen lassen, Geld zurueck. Eine kostenlose Option auf den Tier.
Stattdessen: die Erstattung verlangt, dass seit dem Mint KEINE lebende Epoche existiert — der Scan
wird bis zur Gegenwart vorgeschoben und danach geurteilt (`scanFrom >= currentEpoch`). Diese
Bedingung kann niemand bewegen: existiert eine lebende Epoche, ist der Agent enthuellt UND spielbar,
und es steht keine Erstattung zu. Beide Richtungen als Test.
**N-20 (die Ursache darunter) — ein unenthuellter Agent verhungerte.** `feed` verlangt `alive()`,
`alive()` verlangt `revealed()`: waehrend eines Ausfalls konnte der Agent weder gefuettert noch
gerettet werden und starb nach 3 Tagen. Die Lebensuhr startet jetzt mit der Enthuellung
(`cacheTier` setzt `lastFed`), nicht mit dem Mint. Damit verschwindet die ganze Klasse: kein
Verhungern waehrend eines Ausfalls, kein Wettlauf um die Erstattung. Der Cursor bleibt eine reine
Gas-Optimierung — das ist jetzt richtig, statt der einzige Rettungsweg zu sein.
**N-21** `advanceScan` verlangt eine existierende Token-Id (kein Storage fuer Phantom-Ids).
**N-22** `mintEpoch` war seit dem Umbau write-only und ist entfernt; `scanFrom` traegt dieselbe
Information und wird tatsaechlich gelesen.

## Runde 32 — N-23, N-24 und die Reap-Oekonomie
**N-23 (mittel, Regression aus meinem N-20-Fix) — `cacheTier` war ein Wiederbelebungsknopf.**
`r.lastFed = block.timestamp` galt nicht nur im Ausfallfall, sondern fuer jeden Agenten, der noch nie
gefuettert hatte: regulaer enthuellt, zehn Tage nicht gefuettert, verhungert — und ein einziger
Aufruf von irgendwem machte ihn wieder spielbar. Damit war die Fuettergebuehr fuer den ersten Zyklus
optional, und LIFE (der einzige Mechanismus, der Agenten gegen die 10.000er-CAP abbaut) wirkungslos.
URSACHE: die Uhr hing am Aufrufzeitpunkt statt an einer Tatsache. Sie startet jetzt bei
`epochEnd(firstLiveEpoch)` — dem Moment, in dem der Agent tatsaechlich spielbar wurde. Deterministisch,
fuer jeden Aufrufer identisch, zu jeder Zeit. Dazu `if (r.dead) return;`. Beide Richtungen als Test:
ein verhungerter Agent bleibt tot, ein Agent nach 5 Tagen Ausfall lebt und spielt.
**N-24 (niedrig) — die Fehlermeldung log.** `reclaimUnrevealed` meldete "live epoch exists", obwohl
der Scan nur nicht durch war (60 tote Epochen, Fenster 24). Jetzt unterscheidet die Pruefung die
beiden Faelle: "live epoch exists" nur, wenn tatsaechlich eine lebende Epoche gefunden wurde, sonst
"advance scan first".
**Reap-Oekonomie — an der Ursache, nicht mit einer Praemie.** `reap` ist permissionless und zahlt
nichts, also laeuft es niemand, und `livingCount` — woran die CAP haengt — driftet nach oben. Eine
Praemie aus dem Pot haette den Gewinnern Geld weggenommen. Stattdessen ist die Bereinigung auf die
Operation amortisiert, die den Platz tatsaechlich braucht: `mint()` reapt bis zu drei abgelaufene
Agenten (O(1) je Schritt, keine externen Aufrufe), BEVOR die CAP geprueft wird. Test: sechs
verhungerte Agenten, niemand reapt, zwei Mints raeumen sie weg.

## Runde 33 — N-27, N-28 und eine Selbstpruefung auf die eigenen Fehlermuster
**N-27 (mittel) — verlassene Agenten waren fuer die Bereinigung unsichtbar.** Ich hatte `r.tierCached`
als O(1)-Ersatz fuer "revealed" genommen. Gesetzt wird es aber nur durch `attack`, `feed` oder einen
expliziten Aufruf — also genau NICHT bei der Gruppe, um die es geht: gemintet, enthuellt, liegen
gelassen. Zehn solcher Agenten blieben nach 60 Reap-Schritten unangetastet und hielten das Wallet-Cap
ihrer Besitzerin dauerhaft belegt. Fix: die Bedingung haengt jetzt allein an der Zeit —
`lastFed + LIFE + UNREVEALED_AFTER`. Nach Fuetterungsfrist PLUS Erstattungsfenster ist kein legitimer
lebender Zustand mehr moeglich, und der Puffer garantiert, dass kein offener Erstattungsanspruch
weggeraeumt wird (eine Erstattung funktioniert auch auf einem toten Agenten). Test: 10 -> 0, und ein
gefuetterter Agent ueberlebt fuenf Bereinigungsrunden.
**N-28 (niedrig, aber der aergerlichste Fund) — ich hatte die Tier-Formel selbst dupliziert**, eine
Runde nachdem ich dieselbe Klasse bei `ratePerDayBps` behoben und dokumentiert hatte. Jetzt eine
gemeinsame `_tierOf(sd, id)`; der Seed wird einmal statt dreimal gelesen. cacheTier: 52.476 -> 45.608
Gas. Fuzz-Test: gecachter und berechneter Tier stimmen fuer zufaellige Seeds ueberein.

**Selbstpruefung auf die beiden Muster, die diese Runden verursacht haben** (statt zu warten, bis sie
gefunden werden):
- Doppelte Formeln/Konstanten: Tier-Schwellen nur noch in `_tierOf`, HITRATE und WEIGHT je ein Array,
  Melt-Faktoren nur in `_factorEnds`, Tagesrate nur aus der Faktortabelle. Keine zweite Kopie mehr.
- Geld-Bedingungen an veraenderbarem Zustand: `reclaimUnrevealed` filtert zwar ueber `revealed`/
  `tierCached`, entscheidet aber ueber die unbewegliche Tatsachenpruefung (`_firstLive`). Ein Dritter
  kann `cacheTier` nur dann setzen, wenn der Agent WIRKLICH enthuellt ist — und dann steht ohnehin
  keine Erstattung zu. `reap` und die amortisierte Bereinigung haengen nur an Zeit und `dead`.

## Runde 34 — N-32: zwei eigene Fixes widersprachen sich
**N-32 (bestaetigt).** N-20/N-23 sagt "die Fuetterungsuhr darf nicht laufen, solange ein Agent nicht
enthuellt werden kann"; N-27 sagt "raeume nach `lastFed + 10 Tagen` ab, unabhaengig davon". Bei einem
Ausfall ueber zehn Tage gewann der zweite: der Sweep markierte den Agenten tot, `cacheTier` kehrt bei
`dead` sofort zurueck, und sobald der Ausfall endete, machte `advanceScan` (Runbook!) `revealed` true
und sperrte damit auch die Erstattung. 99 USDG — weder spielbar noch erstattbar. Genau der Zustand,
den N-19 geschlossen hatte, ueber einen anderen Weg hinein.
Fix: der Sweep braucht ein O(1)-Signal fuer "war je enthuellt". `everRevealed` wird dort geschrieben,
wo ein lebender Seed ohnehin gelesen wird — in `cacheTier` und in `advanceScan` — und nie geraten.
Der Sweep fasst nur noch Agenten an, bei denen `tierCached || everRevealed` gilt. Damit:
- verlassene, aber enthuellte Agenten werden weiter eingesammelt (N-27 bleibt zu),
- ein Agent, der nie enthuellt werden konnte, ueberlebt den Sweep und ist nach dem Ausfall spielbar,
- und solange kein lebender Seed existiert, funktioniert die Erstattung weiter, auch nach einem Sweep.
Beide Richtungen als Test.
Sichtbar gemachte Abhaengigkeit: `everRevealed` entsteht erst, wenn jemand `advanceScan` oder
`cacheTier` ruft. Der Keeper tut das laut Runbook; ohne ihn bleibt ein verlassener Agent stehen, bis
sein Besitzer ihn selbst reapt (wofuer er einen Anreiz hat — es ist sein eigener Wallet-Slot). Der
N-27-Test bildet diesen Ablauf jetzt explizit ab, statt ihn stillschweigend vorauszusetzen.

**Prozess:** der gemeldete rote Test stammt von einem aelteren Commit; im ausgelieferten Paket steht
dort `15 days` und er ist gruen. Die Beobachtung zur strikten Ungleichung (`>` schlaegt bei
Gleichheit nicht an) ist trotzdem richtig und der Grund fuer den Puffer. Ab sofort ist der
Clean-Clone-Lauf ein fester Schritt vor jeder Abgabe, nicht nur bei groesseren Aenderungen.

## Runde 35 — die Frage einmal richtig beantwortet (N-36, N-37)
Drei Runden kreisten um dieselbe Frage: **woran erkennt der Contract, ob ein Agent je eine Chance
hatte zu spielen?** Meine Antworten waren alle vom selben Typ — ein MERKMAL, das jemand setzen muss:
`tierCached` (nur beim Spielen gesetzt -> verlassene Agenten unsichtbar, N-27), reine Zeit (weiss
nichts von Ausfaellen -> toetet unverschuldet, N-32), `everRevealed` (muss vom Keeper gesetzt werden
-> N-36). Jede Antwort verschob das Problem dorthin, wo das Merkmal NICHT gesetzt wurde.
Der zweite, tiefere Fehler: ich behandelte `dead` als endgueltig. Dadurch wurde jeder Weg, auf dem
ein Agent unverschuldet stirbt, zum Totalverlust — und ich musste immer neue Bedingungen bauen, um
das Sterben zu verhindern, statt den Tod reparierbar zu machen.

**Die Antwort ist herleitbar, ohne dass jemand etwas setzt:** endet die erste lebende Epoche SPAETER,
als der Agent verhungert waere (`epochEnd(firstLive) > lastFed + LIFE`), dann konnte er nie spielen.
Beide Groessen liegen bereits im Storage.
Daraus folgt alles andere:
- `cacheTier` nimmt genau diesen einen Tod zurueck — und nur diesen. Wer spielen konnte und nicht
  gefuettert hat, bleibt tot ("starved"). Beide Grenzen als Test, inklusive korrekt
  wiederhergestellter Zaehler.
- Weil Einsammeln damit folgenlos ist, laeuft der Sweep wieder rein zeitbasiert — ohne Flag, ohne
  Keeper-Abhaengigkeit. N-27 und N-36 sind damit beide zu, ohne sich zu widersprechen.
- `everRevealed` faellt ersatzlos weg, der Struct schrumpft.
**N-37** (Fenster zwischen `advanceScan` und `cacheTier`) entfaellt mit: `advanceScan` ruft
`cacheTier`, sobald ein lebender Seed erreichbar ist — Flag und Uhr im selben Aufruf. Der irrefuehrende
Kommentar ("purely an optimisation") ist korrigiert: der Aufruf entscheidet nicht, WELCHEN Tier ein
Agent bekommt, aber sehr wohl, wann seine Uhr startet.

## Runde 36 — die Wiederbelebung als eigene Operation (N-41, N-42, N-43)
Runde 35 machte den Tod reparierbar. Dabei entstand eine neue Operation — die Wiederbelebung — die
einen Wallet-Slot und einen Platz unter `CAP` neu belegt. Sie wurde aber wie ein Buchhaltungsdetail
im Inneren von `cacheTier` abgelegt, statt wie das behandelt zu werden, was sie ist: ein zweiter
Weg, lebendig zu werden. Ein Mint prueft zwei Grenzen; dieser zweite Weg prueft keine.

**N-42 — Wiederbelebung umgeht `MAX_PER_WALLET` und `CAP`.**
Ablauf: zehn Agenten im Ausfall minten, elf Tage warten bis der Sweep sie einsammelt (`ownedLiving`
faellt auf 0), zehn neue minten, dann Cursor vorschieben — die ersten zehn kommen zurueck.
`ownedLiving[alice] = 20` bei `MAX_PER_WALLET = 10`, alle zwanzig voll spielbar. Keine
Buchhaltungsfrage: `MAX_PER_WALLET` ist die Anti-Sybil-Grenze in einem Pari-mutuel-Spiel, in dem der
Anteil an der Ausschuettung an der Zahl der Agenten haengt. Wer den Ausfall abwartet, verdoppelt
seine Position.
Ursache: `livingCount++` und `ownedLiving++` im Wiederbelebungszweig ohne die Pruefungen, die
`mint()` eine Zeile weiter oben durchfuehrt. Muster 2 der Projektliste — dieselbe Geldbedingung an
zwei Stellen, nur an einer geprueft.
Fix: der Zweig prueft beide Caps. Er **revertet nicht**, sondern kehrt zurueck und laesst `lastFed`
unberuehrt — die Wiederbelebung bleibt damit geschuldet und gelingt beim naechsten Aufruf, sobald
ein Slot frei ist. Ein Revert haette N-41 wieder aufgemacht, ein blosses Ueberspringen haette den
Agenten dauerhaft verfallen lassen (siehe naechster Absatz).
Tests: `testN42_RevivalCannotBreachTheWalletCap`, `testN42_DeniedRevivalIsNotForfeited`.

**N-41 — `cacheTier` revertete, wo es zurueckkehren sollte.**
`cacheTier` wird best-effort aus `advanceScan`, `attack` und `feed` gerufen, hatte aber zwei Reverts
und keinen Weg zu sagen "hier ist nichts zu tun". Fuer eingesammelte, verlassene Agenten — genau die
Population, die der Sweep laufend erzeugt — schlug jeder `advanceScan`-Aufruf mit `"starved"` fehl.
Ein solcher Agent in einer Batch-Schleife stoppt den ganzen Lauf.
Fix: jeder Zweig, der "nicht jetzt" entscheidet, kehrt zurueck statt zu reverten (unrevealed,
starved, refunded, kein Slot). Zusaetzlich: der Schnellpfad ist jetzt `tierCached && !dead` statt
`tierCached` allein — ein toter Agent traegt noch eine offene Frage (ist dieser Tod geschuldet?),
also darf er nicht am Eingang abgewiesen werden. Ohne das waere die erste abgelehnte Wiederbelebung
still endgueltig geworden, weil `tierCached` bereits gesetzt war.
Test: `testN41_AdvanceScanSurvivesStarvedAgents`. Der alte
`testDerivedRule_StarvedAgentStaysDead` pruefte den Revert-Text; er prueft jetzt das Ergebnis (tot,
nicht spielbar, kein Slot) — die Regel ist unveraendert, nur der Mechanismus.

**N-43 — ein erstatteter Mint kam zurueck.** Beim Pruefen der neuen Bedingungen gegen alle bereits
gesetzten Bedingungen desselben Objekts (Muster 3) gefunden, nicht gemeldet.
`reclaimUnrevealed` zahlt die 99 USDG zurueck und setzt `dead`. Kehrt der Keeper spaeter zurueck und
entsteht endlich eine lebende Epoche, ist `epochEnd(firstLive) > lastFed + LIFE` erfuellt — der
Agent wird wiederbelebt. Der Besitzer haette sein Geld **und** einen spielbaren Agenten, womit der
Mint genau die kostenlose Option auf den Rang waere, die N-19 verhindern sollte. Reichweite: exakt
das Ausfall-Szenario, fuer das die Erstattung existiert.
Fix: `refunded[id]` blockiert die Wiederbelebung.
Test: `testN43_RefundedAgentCannotComeBack`.

**Beobachtung zu den Invarianten (uebernommen).** Die randomisierte Agent-Maschine faengt N-42 nicht
— die noetige Folge (Cap fuellen, Sweep abwarten, neu fuellen, Cursor schieben) ist zu spezifisch,
als dass sie zufaellig entsteht. Invarianten sichern die Buchhaltung; ein Szenario, das niemand
beschreibt, findet auch der Fuzzer nicht.

**Offen, kein Code-Befund:** der Audit-Text nimmt an, der Keeper-Bot rufe `advanceScan` in einer
Schleife. Er tut es nicht — `advanceScan` steht in `keeper/keeper.mjs` nur im ABI, der Tick ruft es
nirgends. Die Batch-Unterbrechung trifft damit heute Dritte (UI, Skripte), nicht den ausgelieferten
Bot. Ob der Bot die Roster-Schleife bekommen soll, ist eine Betriebsentscheidung.

## Runde 37 — systematischer Durchgang ausserhalb des Agenten (test/Adversarial.t.sol)
Alle bisherigen Runden hingen am Agenten-Lebenszyklus. Dieser Durchgang formuliert 26 Eigenschaften
fuer die Bereiche, die bisher am wenigsten Szenarioabdeckung hatten: der abgeleitete Pot, das
Vault-Aggregat, die Launch-Schranken, der Tax-Pfad und das Melt-Gesetz. Keine neuen
Sicherheitsbefunde.

**Methodisch wichtig:** der erste Entwurf enthielt eine Solvenz-Pruefung der Form
`owed + pendingBurn + pot <= balance`. Die kann nicht fehlschlagen, weil `potBalance()` genau als
`balance - owed - pendingBurn` definiert ist — eine Tautologie, die aussieht wie ein Test. Die
Pruefung lautet jetzt `owed + pendingBurn <= balance`: ob das Vault den Lockern mehr verspricht als
es haelt. Wer diese Suite erweitert, sollte auf dieselbe Falle achten.

Geprueft und gehalten:
- **Pot** — Solvenz unter randomisierter Op-Mischung; vollstaendiger Exit aller Locker in zufaelliger
  Reihenfolge, nachdem der Agent den Pot geleert hat; Dust-Flut aus 30 MIN_LOCK-Positionen gegen
  einen Wal; Spende per Direkttransfer landet im Pot und in keinem Anspruch.
- **Vault** — Lock/Unlock-Zyklus erzeugt nie Wert; zehn Relocks entkommen dem Melt nicht;
  `advance(b,1)` dreihundertmal landet exakt dort, wo ein einziger voller Aufruf landet
  (Settlement-Frequenz aendert kein Ergebnis); zwei Positionen im selben Bucket, eine vor und eine
  nach dem Roll angefasst, konvertieren identisch; zwanzig `burnExpired()` in Folge brennen nichts
  doppelt; zwei `setEpochLength`-Wechsel mit lebender 14d-Position stranden sie nicht;
  `lockedSupply` enthaelt den Pot nicht.
- **Launch** — das Cap-Ledger ist kumulativ ueber kaufen/wegschieben/kaufen; frische
  Empfaenger-Contracts setzen es nicht zurueck (Buchung auf `tx.origin`, N11); nach dem Fenster faellt
  das Cap ersatzlos; in der Launch-Stunde 8 % flach, auch wenn das Orakel 0,01 % sagen will.
- **Tax** — ein Orakel, das 90 % verlangt, wird auf 8 % gedeckelt; ein revertierendes Orakel bricht
  keinen Handel und bedeutet nie 0 %, sondern faellt auf die Basisrate; Wallet-zu-Wallet bleibt frei.
- **Melt** — Reihenfolge 14d < 3d < 1d < LP < unlocked haelt ueber 200 Tage; Supply waechst unter
  keiner Poke-Folge; nach 4000 Tagen liegt keine Position unter `minIndex`; `setEpochLength` bewegt
  keinen Index sprunghaft.

**Beobachtung, kein Befund: `transfer(balanceOf(x))` kann 1 wei stehen lassen.** `balanceOf` rundet
scaled->nominal ab, `_debit` rundet nominal->scaled erneut ab; die Differenz bleibt als
Scaled-Rest liegen. Gemessen ueber 0/1/3/30/180/900 Tage: hoechstens 1 wei, meist 0. Es entsteht kein
Wert und es geht keiner verloren, aber ein Integrator, der von einem Voll-Transfer eine geleerte
Adresse erwartet, wird ueberrascht. Der Transfer-Pfad wurde bewusst NICHT geaendert — ein Aufrunden
wuerde den Empfaenger 1 wei mehr bekommen lassen, als `amount` sagt, und damit eine schaerfere
Zusage brechen als die, die hier verletzt wird. Stattdessen ist die Schranke als Test verankert
(`testToken_FullBalanceTransferResidueIsAtMostOneWei`) und gehoert in den Launch-Text.

**Was dieser Durchgang NICHT ist:** kein Ersatz fuer das externe Audit. Er prueft Eigenschaften, die
ich selbst formuliert habe — und der Auditor der Runde 36 hat recht damit, dass ein Szenario, das
niemand beschreibt, auch hier nicht auftaucht.

## Runde 38 — HashChainSeed adversarisch (N-44)
11 Eigenschaften fuer die Zufallsquelle, den Teil, den der Projektkontext als den empfindlichsten
fuehrt. Ein Befund.

**N-44 — der Constructor bindet den Agenten, ohne seine Uhr zu cachen.**
`setAgent` speichert `agentStart` und `agentEpochLen`, weil `unrevealable()` bis zu REVEAL_SCAN mal
pro Agenten-Lookup gelesen wird (N-11: sonst 175k statt 14k Gas). Der Constructor nimmt ebenfalls
eine Agenten-Adresse entgegen, weist `agent` zu — und cacht **nicht**. Danach verweigert `setAgent`
den Dienst (`"agent is final"`), also bleiben beide Werte dauerhaft 0.
Folge: `_epochEnd(e) = 0 + (e+1)*0 = 0`, also ist `block.timestamp >= _epochEnd(e)` immer wahr und
`unrevealable(e)` meldet **jede** noch nicht aufgedeckte Epoche als tot — die laufende und sogar
zukuenftige. `failed()` leitet daraus ab, `_firstLive` im Agenten ueberspringt entsprechend alles,
und kein Agent wird je enthuellt. Die Quelle ist ab Deployment unbrauchbar, ohne dass irgendetwas
revertet.
Reichweite: `script/Deploy.s.sol` uebergibt `address(0)` und ruft danach `setAgent` — der
ausgelieferte Pfad ist also gesund. Der Befund trifft jede abweichende Deploy-Reihenfolge, ein
Testnetz-Skript oder eine spaetere Neuverdrahtung. Kein Angriff, sondern eine still scheiternde
Initialisierung — Muster 1 der Projektliste: dieselbe Regel (Agent binden heisst Uhr cachen) an zwei
Stellen implementiert, an einer unvollstaendig.
Fix: beide Pfade laufen durch `_bindAgent(address)`. Eine Stelle, an der Zeiger und Uhr geschrieben
werden.
Test: `testSeed_ConstructorWithAgentMustNotBrickTheClock` — prueft zuerst die Auswirkung (eine
lebende Epoche darf sich nicht als tot lesen), dann die Ursache.

Geprueft und gehalten:
- **Reveal-Fenster** — nicht vor Epochenbeginn, nie nach Epochenende (der Keeper darf die
  Post-Close-Entropie nie zuerst sehen); nur Urbilder der committeten Kette werden angenommen.
- **Close-Erfassung** — der erste Toucher fixiert eine Blocknummer in der Zukunft, deren Hash noch
  nicht existiert; ein zweiter Toucher kann sie nicht mehr verschieben (kein Re-Roll, R7-2).
- **Seed-Unkenntnis** — ein aufgedecktes Urbild allein ergibt `seed == 0`; auch nach Schritt eins
  noch; erst nach dem Einfrieren des Close-Hashes existiert der Seed.
- **Kaution** — ein Slash nimmt nie mehr als vorhanden und derselbe Epochen-Slash ist nicht
  wiederholbar; `withdrawBond` laesst sich exakt bis zur Deckungslinie fuehren, ein wei darueber
  nicht; ein Keeper-Wechsel verfaellt die Kaution in den Pot und der Nachfolger startet ungedeckt.
- **Melt** — die exempte Quelle haelt ihren Nominalwert ueber 120 Tage; faellt der `setExempt`-Schritt
  im Deploy weg, laeuft die Zaehlung der Balance davon und `syncBond()` repariert genau das.

## Runde 39 — swapTax gegen boesartige Router
11 Eigenschaften fuer den permissionless Tax-Pfad, getrieben von vier Angreifer-Routern: ein
ehrlicher, einer der die RACKS behaelt und nichts liefert, einer der aus dem Swap heraus
zurueckruft, und einer der einen Kurs quotiert, den niemand erfuellen kann. Kein Befund.

Geprueft und gehalten:
- **Bounty nur bei Erfolg (Z1)** — fuenf Versuche gegen einen Router, der nichts liefert, zahlen
  null; die Tax bleibt unberuehrt, weil `executeTaxSwap` extern ist und der Fehlschlag nur den Swap
  zurueckrollt.
- **Ein unerfuellbarer Kurs pausiert**, bricht nichts und zahlt nichts.
- **Ein kaputter Router bricht keinen Verkauf** — der Verkaeufer kommt durch.
- **`swapTax` ist nicht wiedereintrittsfaehig** (`inSwap`).
- **Die Freigabe begrenzt den Router** — ein zweiter `transferFrom` im selben Call sprengt die
  Allowance und rollt alles zurueck.
- **Impact-Deckel** — eine Konvertierung nimmt nie mehr als `maxSwapBps` der Pair-Reserve.
- **Router, SPY und Reserve sind nach der Erstkonfiguration fix** (alle drei Reverts einzeln
  geprueft).
- **Die wartende Tax meltet nicht** und besteuert sich nicht selbst (60 Tage).
- **Unter dem Threshold** passiert nichts und niemand wird fuer den Aufruf bezahlt.

**Beobachtung, kein Befund: die X4-Ausnahme im `guarded`-Modifier wird nie erreicht.**
`guarded` erlaubt Wiedereintritt, wenn `inSwap` gilt und der Aufrufer der Router ist. Der einzige
Weg zu `_swapTax` ist aber `swapTax()`, und das traegt **kein** `guarded`. Waehrend der gesamten
Konvertierung ist `_entered` daher 0 und jeder geschuetzte Einstiegspunkt steht ohnehin allen offen —
dem Router wie jedem Dritten. Das ist derzeit unbedenklich: waehrend einer Konvertierung ist kein
Nutzer-Transfer halb fertig, und `swapTax()` selbst ist ueber `inSwap` gesichert.
Festgehalten wird es, weil die Ausnahme ein aufgeweiteter Schutz fuer einen Pfad ist, den es nicht
mehr gibt (die In-Transfer-Konvertierung, die X1 entfernt hat). Wird eine In-Transfer-Konvertierung je
wieder eingebaut, oeffnet sich diese Ausnahme von selbst und nichts schlaegt laut fehl. Der Modifier
wurde bewusst NICHT geaendert — er ist korrekt, falls der Pfad zurueckkehrt, und harmlos, solange
nicht. Der Test `testSwap_GuardStateDuringAConversion` haelt den Ist-Zustand fest statt eine
Eigenschaft zu behaupten, die der Code nicht hat.

**Methodisch, zum Mitschreiben:** der erste Entwurf dieses Tests nutzte `meltPool()` als Sonde fuer
den Guard. `meltPool()` ist absichtlich **nicht** guarded (externer Self-Call aus `_preOp`), taugt
also nicht als Probe. Wer hier weiterprueft, muss einen geschuetzten Einstiegspunkt nehmen.

## Runde 40 — DynamicTax und TwapOracle
12 Eigenschaften fuer die Preisbildung selbst, nicht nur fuer ihre Deckelung. Kein Sicherheitsbefund,
aber drei Eigenschaften, die im Launch-Text stehen muessen, weil sie von dem abweichen, was der Code
ueber sich selbst behauptet.

Die Kurve (reine Bibliothek, deshalb gefuzzt):
- Ueber den gesamten Eingaberaum bleibt die Rate in [100, 800]. Das ist die Eigenschaft, auf die
  sich der Token verlaesst, wenn er das Orakel deckelt.
- Monoton in der Dislokation: ein schlechterer Preis ist nie billiger zu verkaufen.
- Monoton im Trade-Impact auf der eigenen Seite: ein groesserer Trade zahlt nie weniger.
- Unter Kaufdruck haelt die Verkaufsrate bei 400, wie weit der Preis auch laeuft.
- `twap == 0` revertet (`"twap"`), der Token faengt es und faellt auf die Basisrate.
- Slicing: die Impact-Komponente ist per Trade, also ist eine Scheibe billiger als das Ganze — so
  gewollt. Was traegt, ist der State-Term: sobald die Scheiben den Preis 10 % bewegt haben, steht die
  Verkaufsrate bei 800, unabhaengig von der Scheibengroesse.

**Beobachtung 1: `WINDOW = 15 minutes` wird nirgends gelesen.** Der Contract heisst sich selbst
15-Minuten-TWAP, aber nichts referenziert die Konstante. Die tatsaechliche Mittelungsspanne ist
"zurueck bis zur aeltesten von 8 Ringproben, die mindestens `PERIOD` auseinanderliegen", also
**mindestens 7 x 3 = 21 Minuten** bei aktivem Markt. Gemessen: ein Preissprung ist nach 1.260
Sekunden vollstaendig aufgenommen. Wer 15 Minuten in den Launch-Text schreibt, schreibt eine Zahl
hin, die der Code nicht benutzt.

**Beobachtung 2: Leerlauf altert den Durchschnitt nicht, er friert ihn ein.** `twap()`
extrapoliert `lastSpot` — den beim letzten `update()` erfassten Preis — ueber die gesamte Luecke.
Nach sieben Tagen Stille meldet das Orakel weiterhin den Preis von vor der Stille, egal wie weit der
Pool gelaufen ist. `update()` ist permissionless, also kann jeder es auffrischen; nur zwingt niemanden
etwas dazu. Der Keeper-Tick tut es heute nicht.

**Beobachtung 3: das Orakel wird nur von BESTEUERTEN Trades vorgerueckt.** `_taxBps` kehrt vor dem
`update()`-Aufruf zurueck, sowohl fuer tax-exempte Parteien als auch fuer die **gesamte
Launch-Stunde**. Wenn die Launch-Stunde endet und die Rate von 8 % auf die Basis faellt, ist der Ring
also noch leer und `twap() == spot` — der Dislokations-Term ist blind, bis die ersten Proben landen.
In dieser Luecke traegt allein der Impact-Term: ein Trade mit 5 % Impact erreicht weiterhin 800, eine
Folge kleiner Trades zahlt bis zur ersten Probe nur die Basis. Empfehlung fuer den Betrieb: den
Keeper `oracle.update()` mit ticken lassen, dann ist der Ring vor dem Ende der Launch-Stunde warm.
Kein Code geaendert — das ist eine Betriebs-, keine Contract-Entscheidung.

Weiter geprueft und gehalten:
- Zweihundert `update()` im selben Block bewegen den TWAP um null; zwei Minuten Spam im
  Sekundentakt koennen einen 10x-Spike nicht zum Durchschnitt machen. Die Ringabstaende lassen sich
  nicht unter `PERIOD` druecken.
- Der TWAP liegt stets zwischen dem niedrigsten und hoechsten in seiner Spanne beobachteten Spot.
- Ein leergezogener Pool friert den Spot ein, statt durch null zu teilen; `update()` revertet nicht.

**Zur Vertrauensliste (Abschnitt 9):** `TwapOracle.setPair` ist eine Owner-Vollmacht, die dort nicht
aufgefuehrt ist. Das Deploy-Skript uebergibt die Orakel-Ownership an die Multisig (Zeile 114), der
Punkt gehoert also in dieselbe Liste wie `setTaxOracle`.

## Runde 41 — die Deploy-Sequenz Fenster fuer Fenster
Unter `--broadcast` ist jede Zeile von `Deploy.s.sol` eine eigene Transaktion in einem eigenen Block.
Jeder Zwischenzustand ist also mindestens einen Block lang oeffentlich und angreifbar — genau daraus
entstand P1 (Sniper mit 13,38 % der Supply, null Tax). 9 Eigenschaften, ein Angreifer in jedem
Spalt. Kein Sicherheitsbefund.

Geprueft und gehalten:
- **Pair exempt, noch nicht `isDex`** — ein Aussenstehender hat keine RACKS, um den Pool zu seeden,
  und das Gate laesst ihn ohnehin nicht an das Pair.
- **Registriert, Handel noch zu** — das Gate weist Nicht-Exempte in BEIDE Richtungen ab: weder
  hinein noch heraus.
- **Liquiditaet drin, Gate zu** — haelt ueber einen vollen Blockwechsel, nicht nur innerhalb einer
  Transaktion.
- **`enableTrading` mit der gesamten Supply im exempten Pair** liefert trotzdem ein nutzbares Cap
  (R5: ein Null-Cap haette jeden Kauf blockiert).
- **Der erste Kaeufer nach `enableTrading`** zahlt ab dem ersten Block 8 % und faellt unter das Cap —
  auch in den Bloecken, bevor der Deployer seine eigene Exemption ablegt.
- **Der Deployer endet sauber**: keine RACKS, keine Tax-Exemption, keine Melt-Exemption.
- **Zwei-Schritt-Ownership**: der Pending Owner hat vor `acceptOwnership` keinerlei Macht.
- **Das registrierte Pair laesst sich nicht de-exemptieren** (hart im Contract).

**Beobachtung 1: die Exemption des alten TAX_WALLET ueberlebt seine Rolle.**
Schritt 1 setzt `taxWallet = TAX_WALLET` und macht die Adresse melt- und tax-exempt (Zeilen 66-68).
Schritt 3b ruft `enableAutoSwap`, und das zeigt `taxWallet` auf den Token selbst um (Zeile 524 in
Racks). Ab da hat die konfigurierte TAX_WALLET-Adresse **keine Rolle mehr**, behaelt aber beide
Exemptions — RACKS, die dort geparkt werden, melten nie und handeln steuerfrei. Der Selbstcheck des
Skripts prueft in Zeile 124 weiterhin genau diese Exemption, was so liest, als waere die Adresse
aktiv. Nach `renounceExemptControl()` ist sie nicht mehr zurueckzunehmen. Kein Angriff, aber eine
dauerhaft privilegierte Adresse ohne Aufgabe. Empfehlung: entweder die Exemption vor der Uebergabe
zuruecknehmen, oder in Abschnitt 9 als Vertrauensannahme auffuehren.
Test: `testDeploy_TaxWalletExemptionOutlivesItsRole`.

**Beobachtung 2: das Launch-Cap ist netto, nicht brutto.** `_recordLaunch` bucht, was ANKOMMT, also
nach Abzug der 8 % Launch-Tax. Eine Wallet kann daher brutto `cap / 0,92` erwerben, bevor sie
blockiert wird — rund **1,087 % der Supply statt 1,00 %**. Bei der Seed-Liquiditaet sind das etwa
55 statt 51 USD. Die Groessenordnung aus Abschnitt 10 stimmt, die Zahl im Launch-Text sollte die
richtige sein.
Test: die Assertion in `testWindow_FirstBuyerIsTaxedAndCappedImmediately`.

**Nicht geschlossen, weil es kein Contract-Problem ist:** zwischen `enableTrading()` und dem
`acceptOwnership()` der Multisig haelt der Deployer-EOA weiterhin jede Vollmacht ueber alle fuenf
Contracts. Das Skript sagt es in der Konsolenausgabe, das Runbook nennt "innerhalb von Minuten". Der
Test haelt fest, dass die Zwei-Schritt-Uebergabe wirkt; die Dauer des Fensters ist eine Frage des
Betriebs.

## Runde 42 — externer Bericht, nachgeprueft (N-45, N-46)
Ein externer Durchgang meldete sechs Punkte. Alle nachgeprueft, alle bestaetigt. Zwei davon sind
Code-/Test-Befunde, vier sind Doku-Drift. Nichts davon ist ausnutzbar; N-46 kann das Casino
allerdings dauerhaft sperren.

**N-45 — `block.number` ist die Nummer der ELTERNKETTE, nicht die L2-Hoehe.**
Gegen RH-Mainnet gemessen, dreifach:
- `NUMBER`-Opcode via `eth_call`: `0x18c49ba` = 25.971.130
- Header-Feld `l1BlockNumber`: `0x18c49ba` — identisch
- Header-Feld `number` (L2): `0x3b61d97` = 62.266.775
`blockhash()` ist auf diese Nummerierung gekeyt und verhaelt sich korrekt: `number-255` liefert
einen Hash, `number-300` und `number` liefern null. Der Mechanismus TRAEGT also — falsch war das
abgeleitete Zeitmodell.
Folgen: 256 Bloecke sind rund **51 Minuten**, nicht die dokumentierten ~64 s. Der 15-s-Takt des
Keepers ist dadurch grosszuegiger als angenommen, nicht knapper. Und rund 48 L2-Bloecke teilen sich
eine `block.number`, die Entropie ist also ein Zug pro ~12 s Kettenzeit statt pro L2-Block.
Der eigentliche Fehler lag im Test: `BlockhashProbe` schrieb "block.number is the chain's own
height" in den Kommentar und assertierte davon **nichts** — er prueft nur Non-Zero ueber 32 Bloecke
und ging gruen durch, waehrend die Annahme, fuer die er geschrieben wurde, verletzt war. Der Probe
misst und assertiert jetzt beide Nummern gegeneinander sowie die Raender des 256-Fensters.

**N-45b — `SLASH_DIVISOR`-Kommentar widerspricht dem Code.**
Der Kommentar sagte "one miss can never cost more than a quarter of the bond". `slashAmount()` hebt
den Deckel danach aber auf den Floor: `if (cap < slashPerMiss) cap = slashPerMiss`. Sobald
Kaution/4 unter `slashPerMiss` faellt, nimmt ein einzelner Miss mehr als ein Viertel — im Grenzfall
alles. Genau in dem Regime, in dem die Kaution klein ist, gilt die Zusage also nicht.
Der Code bleibt: der Floor ist eine bewusste Entscheidung (N-10), und eine Kaution, die den Floor
nicht deckt, ist keine schuetzenswerte Kaution. Korrigiert wurde der Kommentar, und die tatsaechliche
Regel ist als Test verankert: `testSeed_FloorOverridesTheQuarterCap`.

**N-46 — die beiden Renounce-Schalter kollidieren.**
`setExempt` haengt an `exemptControlRenounced`. Das Deploy macht die Seed-Quelle melt-exempt, weil
die Kaution nicht schmelzen darf. Die Seed-Quelle ist aber das EINE Bauteil, das bewusst
austauschbar gehalten wurde (`proposeVrf`/`executeVrf`, 7 Tage Timelock). Wird
`renounceExemptControl()` vor `renounceVrfControl()` gezogen, laesst sich eine Ersatzquelle zwar
installieren, aber nie melt-exempt machen. Ihre Kaution schmilzt dann mit 4,2-6,9 %/Tag, waehrend
`requiredBond() = max(Pot, slashPerMiss)` stehenbleibt.
Gemessen: 20 Mio RACKS Kaution stehen nach 30 Tagen bei 2,34 Mio und nach 60 Tagen unter der
Deckungslinie. `bondOk()` kippt von allein, `attack()` verweigert, das Casino sperrt sich selbst —
ohne dass jemand etwas tut.
Kein Code geaendert. Eine Ausnahme fuer die Seed-Quellen-Rolle waere eine Owner-Vollmacht, die einen
Renounce ueberlebt, und das widerspricht dem Zweck des Renounce. Stattdessen als harte
Reihenfolgeregel in STATUS und Runbook: **`renounceExemptControl()` erst nach
`renounceVrfControl()`** — oder gar nicht. Wenn der Owner die Ausnahme lieber im Contract haette,
ist das seine Entscheidung, nicht meine.
Test: `testSeed_RenouncingExemptControlTrapsAReplacementSource`.

**Das Zwei-Parteien-Bild der Zufallsquelle hielt nicht.** STATUS sagte "zwei Parteien, keine steuert
allein". Gegen den Keeper stimmt das. Gegen den Sequencer nicht: Enthuellen ist nur bis Epochenende
erlaubt, das Preimage ist also oeffentlich, BEVOR der Close-Hash existiert — wer den Close-Block
produziert, kennt beide Komponenten und kann den Seed waehlen. Das Preimage verhindert
Keeper-Grinding, es fuegt gegen einen Sequencer-Angreifer keine Entropie hinzu. Das Restvertrauen war
weiter unten bereits dokumentiert, aber das Zwei-von-Zwei-Bild darueber widersprach ihm. Fuer ein
Auszahlungsspiel ist das kein Detail; die Formulierung ist raus, STATUS und keeper/README nennen die
Annahme jetzt beim Namen.

**Doku-Drift, verifiziert und korrigiert:**
- `_preOp()` — STATUS behauptete im Pool-Melt-Abschnitt "immer wenn der Pool nachhinkt
  (selbstheilend, nicht nur bei Epochenwechsel)". Der Code ist
  `if (p != address(0) && epochNow() > pairEpoch)` — reiner Epochenwechsel. Der Melt-Faktoren-Abschnitt
  derselben Datei sagte es korrekt; zwei Abschnitte, ein Widerspruch.
- Melt im Preis — STATUS nannte 995.015 -> 603.222 RACKS pro SPY nach 7 Tagen. Selbst gegen
  RH-Mainnet nachgemessen: **777.070**. Die alte Zahl stammt aus dem Modell vor der 0,5x-Stufe fuers
  Pair.
- R9-5 stand als "ENTSCHEIDUNG VOR DEM DEPLOY … muss VOR dem Deploy fallen", obwohl entschieden —
  ein externer Auditor liest das als offen. Jetzt als entschieden markiert, mit der Netto-Korrektur
  aus Runde 41 (brutto ~1,087 %, ~$55).
- Bounty-Oekonomie — "MEV-Bots erledigen den Job von selbst" stimmt bei dieser Groesse nicht:
  0,25 % des Pool-Melts in einem Token, dessen gesamter Markt der Seed-Pool ist, sind einstellige
  Dollarbetraege. Der Cron ist der Primaerpfad, nicht der Fallback. Bei `meltPool` folgenlos
  (selbstheilend), bei `swapTax` und `vault.advance()` haengt der Betrieb real am Keeper.

**Offen, bewusst nicht angefasst:** die strukturell gedeckelte Markttiefe. Der Pool startet mit
100 % der Supply gegen 6,45 SPY, die LP geht an 0x…dEaD, Hinzufuegen ist auf Token-Ebene ein
besteuerter Sell und Entfernen ein besteuerter Buy (auf v2 nicht unterscheidbar), und die LP-Seite
bleedet mit 0,5x. Niemand kann rational nachlegen, die Tiefe ist damit praktisch auf den Initial-Seed
festgenagelt. Das folgt aus bereits getroffenen Entscheidungen (Abschnitt 3 und 10), stand aber
nirgends als eine Aussage. Gehoert in den Launch-Text — als Produkteigenschaft, nicht als Bug.

## Nicht gefunden (geprueft)
- Flash-Loan-Manipulation des TWAP: Spot -75% in einem Block bewegt TWAP 0 bps (Stresstest).
- Cayman-Inflation: Index-basiert, keine Share-Ratio -> kein First-Depositor-Vektor.
- Rundungs-Inflation ueber viele Wraps: Ist-Delta-Messung schliesst Dust-Muenzung aus.
- Pool-Melt-Drift: Pool haelt wRACKS (fix), kein Rebasing-Leck (7d-Melt-Test).
