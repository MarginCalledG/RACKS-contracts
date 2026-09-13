# RACKS — Testnet Deploy & Test, Schritt fuer Schritt (aktueller Stand)

Erster Bring-up auf Robinhood-Testnet mit MOCK-Infrastruktur (Mock-USDG/SPY/VRF/Pool),
damit das ganze System live laeuft, bevor echte Bausteine reinkommen.

Netzwerk:
- RPC:      https://rpc.testnet.chain.robinhood.com/rpc
- Chain ID: 46630
- Explorer: https://explorer.testnet.chain.robinhood.com
- Faucet:   https://faucet.testnet.chain.robinhood.com

WICHTIG: Was mit Mocks testbar ist:
  JA  -> Melt/Decay, Locks (Cayman), IRS-Agents (mint/reveal/feed), Sell-Tax, enableTrading, renounceMint
  NEIN-> echte Kaeufe & Max-Wallet (braucht einen echten Uniswap-Pool; kommt in Phase 7)

===========================================================================
## PHASE 0 - Lokales Setup
===========================================================================
1) Foundry:
   curl -L https://foundry.paradigm.xyz | bash
   foundryup

2) Repo klonen:
   git clone https://github.com/DEIN_USER/DEIN_REPO.git
   cd DEIN_REPO

3) Dependencies:
   forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts --no-git

4) Bauen + testen (muss 70 gruen zeigen):
   forge build
   forge test

===========================================================================
## PHASE 1 - Wallet & Test-ETH
===========================================================================
5) Frische Testnet-Wallet:
   cast wallet new
   -> Adresse + Private Key notieren. NUR fuer Testnet.

6) Test-ETH holen: Adresse auf https://faucet.testnet.chain.robinhood.com einwerfen.
   Pruefen:
   cast balance DEINE_ADRESSE --rpc-url https://rpc.testnet.chain.robinhood.com/rpc

===========================================================================
## PHASE 2 - Konfigurieren
===========================================================================
7) .env anlegen (Repo-Root; wird durch .gitignore NICHT committet):
   echo 'PRIVATE_KEY=0xDEIN_TESTNET_KEY' > .env
   (Fuer den Testnet-Bring-up reicht der PRIVATE_KEY - die Mocks deployt das Skript selbst.)

===========================================================================
## PHASE 3 - Deployen
===========================================================================
8) Ganzes System deployen (ein Befehl):
   forge script script/DeployTestnet.s.sol:DeployTestnet \
     --rpc-url https://rpc.testnet.chain.robinhood.com/rpc \
     --broadcast

   Am Ende werden ALLE Adressen geloggt (RACKS, Cayman, IRSAgent, USDG, VRF, PAIR ...).
   ALLE notieren. Die 69,42 Mrd. Start-Supply liegen danach bei deiner Deployer-Wallet.
   (Scheitert es am tx-Format: --legacy anhaengen.)

9) Auf dem Explorer pruefen:
   RACKS-Adresse auf https://explorer.testnet.chain.robinhood.com eingeben.

===========================================================================
## PHASE 4 - Variablen setzen (fuer die naechsten Befehle)
===========================================================================
   export RPC=https://rpc.testnet.chain.robinhood.com/rpc
   export PK=0xDEIN_KEY
   export ME=DEINE_ADRESSE
   export RACKS=0x...     # aus Schritt 8
   export CAYMAN=0x...
   export AGENTS=0x...
   export USDG=0x...
   export VRF=0x...
   export PAIR=0x...      # die Mock-Pool-Adresse (als isDex markiert)
   export MAX=$(cast max-uint)

===========================================================================
## PHASE 5 - Zustand lesen & Kern testen
===========================================================================
10) Lesen:
   cast call $RACKS "balanceOf(address)(uint256)" $ME --rpc-url $RPC     # ~69.42e27
   cast call $RACKS "ratePerDayBps()(uint256)" --rpc-url $RPC            # 420..690 (=4.2..6.9%/Tag)
   cast call $RACKS "epochNow()(uint256)" --rpc-url $RPC
   cast call $RACKS "mintRenounced()(bool)" --rpc-url $RPC               # false (noch nicht renounced)

11) Offshore locken (Cayman, 1-Tage-Stufe = tier 0):
   cast send $RACKS  "approve(address,uint256)" $CAYMAN $MAX --rpc-url $RPC --private-key $PK
   cast send $USDG   "approve(address,uint256)" $CAYMAN $MAX --rpc-url $RPC --private-key $PK
   cast send $CAYMAN "lock(uint8,uint256)" 0 100000000000000000000000 --rpc-url $RPC --private-key $PK
   cast call $CAYMAN "claimOf(address,uint8)(uint256)" $ME 0 --rpc-url $RPC   # ~100000e18 geschuetzt

12) IRS-Agent minten + Rang aufdecken:
   cast send $USDG   "approve(address,uint256)" $AGENTS $MAX --rpc-url $RPC --private-key $PK
   cast send $AGENTS "mint()" --rpc-url $RPC --private-key $PK
   cast call $VRF    "lastId()(uint256)" --rpc-url $RPC                   # VRF-Request-ID X
   cast send $VRF    "fulfill(uint256,uint256)" X 97 --rpc-url $RPC --private-key $PK   # 97 -> Special-Rang
   cast call $AGENTS "agents(uint256)(uint8,uint40,uint32,bool,bool)" 1 --rpc-url $RPC  # (tier,lastFed,..,revealed,dead)
   cast call $AGENTS "agentsOf(address)(uint256[])" $ME --rpc-url $RPC    # Roster der Wallet

13) Melt beobachten (zeitbasiert - echtes Warten):
   # Fuer schnelleres Testen die Epoche auf den 15-Min-Boden stellen:
   cast send $RACKS "setEpochLength(uint256)" 900 --rpc-url $RPC --private-key $PK
   # balanceOf lesen, 15+ Min warten, nochmal lesen -> kleiner. Innerhalb einer Epoche konstant.

===========================================================================
## PHASE 6 - Launch-Mechanik testen (Tax + Sell)
===========================================================================
14) Trading aktivieren (startet die 1h-Launch-Phase: 8/8% Tax, Max-Wallet):
   cast send $RACKS "enableTrading()" --rpc-url $RPC --private-key $PK
   cast call $RACKS "inLaunchWindow()(bool)" --rpc-url $RPC              # true (erste Stunde)

15) Sell testen (Transfer an die Pool-Adresse = Verkauf -> 8% Launch-Tax an den Swapper):
   cast send $RACKS "transfer(address,uint256)" $PAIR 10000000000000000000000 --rpc-url $RPC --private-key $PK
   # Tax landet im TaxSwapper (= Tax-Wallet). Swapper-Adresse aus Schritt 8:
   # cast call $RACKS "balanceOf(address)(uint256)" $SWAPPER --rpc-url $RPC   -> ~800e18 (8% von 10000)

   Hinweis: Echte Kaeufe (Pool -> Wallet) und die Max-Wallet-Grenze lassen sich mit dem
   Mock-Pool nicht ausloesen - dafuer braucht es einen echten Uniswap-Pool (Phase 7).
   Die Kauf-/Max-Wallet-Logik ist in den Foundry-Tests (Launch.t.sol) voll belegt.

===========================================================================
## PHASE 7 - Echte Infrastruktur reintauschen (spaeter, mit Deploy.s.sol)
===========================================================================
Wenn der Mock-Durchlauf sitzt, Stueck fuer Stueck echt (Adressen in .env fuer Deploy.s.sol):
  1. Echtes Testnet-USDG (Adresse vom Testnet-Explorer) statt Mock-USDG.
  2. Echten S&P-500-Token statt Mock-SPY.
  3. Echten Uniswap-V2-Pool RACKS/SPY anlegen + Liquiditaet -> als PAIR / isDex / TwapOracle.
  4. Echtes VRF (Chainlink/Randomizer) statt MockVRF.
Nach jedem Tausch neu smoke-testen. Erst dann sind echte Kaeufe + Max-Wallet testbar.

===========================================================================
## PHASE 8 - Renounce (OPTIONAL, erst wenn alles laeuft)
===========================================================================
Supply permanent fixieren (kein Nachdrucken mehr moeglich):
   cast send $RACKS "renounceMint()" --rpc-url $RPC --private-key $PK
   cast call $RACKS "mintRenounced()(bool)" --rpc-url $RPC              # true

REIHENFOLGE AM LAUNCH-TAG (nicht vertauschen!):
   1. Deploy + mint (Supply erzeugen)
   2. Pool + Liquiditaet
   3. enableTrading()   <-- SONST ist der Token nach Renounce tot
   4. finale Parameter (setEpochLength, alle setDex fuer existierende Pools)
   5. renounceMint()    <-- ganz zuletzt
