// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {TwapOracle} from "../src/TwapOracle.sol";
import {HashChainSeed} from "../src/HashChainSeed.sol";

interface IV2Factory { function createPair(address,address) external returns (address); function getPair(address,address) external view returns (address); }
interface IV2Router { function addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256) external returns (uint256,uint256,uint256); }
interface IERC20d { function approve(address,uint256) external returns (bool); function balanceOf(address) external view returns (uint256); function transfer(address,uint256) external returns (bool); }

/// RACKS mainnet deploy — Uniswap v2 on Robinhood Chain. No wrapper, no hook.
/// Ordering matters and is enforced by the checks below:
///   1. deploy token + vault + agents, wire them
///   2. create the pair, make it MELT-EXEMPT, seed liquidity  (trading gate still closed)
///   3. setPair (registers isDex + capExempt + pairIndex) and the tax oracle
///   4. enableTrading LAST -> launch hour (8% flat, 1% cumulative cap) starts here
contract DeployScript is Script {
    address public deployedRacks;   // for fork tests / verification tooling
    address constant FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
    address constant ROUTER  = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;
    address constant SPY     = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant USDG    = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    uint256 constant SUPPLY   = 69_420_000_000 ether;
    uint256 constant SPY_SEED = 6.45 ether;          // ~$5k seed
    uint256 constant RAY      = 1e27;
    uint256 constant SWAP_THRESHOLD = 1_000_000 ether;   // min accrued tax before a conversion fires
    uint256 constant SLASH_PER_MISS = 1_000_000 ether;   // keeper bond slashed per withheld epoch

    struct Cfg { address me; address vrf; address reserve; address taxWallet; address multisig; address lpDestination; address keeper; }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        Cfg memory c = Cfg({
            me: vm.addr(pk),
            vrf: address(0),                            // replaced by HashChainSeed below
            reserve: vm.envAddress("RESERVE"),
            taxWallet: vm.envAddress("TAX_WALLET"),
            multisig: vm.envAddress("MULTISIG"),
            lpDestination: vm.envAddress("LP_DESTINATION"),  // 0x...dEaD burns the LP
            keeper: vm.envAddress("KEEPER")                   // hot-wallet of the reveal bot
        });

        vm.startBroadcast(pk);

        // ---- 1. core ----
        Racks racks = new Racks(RAY / 1e6);
        CaymanIslands vault = new CaymanIslands(address(racks), USDG, c.reserve);
        // Randomness: one pre-committed hash-chain value per epoch (see keeper/README.md).
        // The source needs the agent and the agent needs the source: deploy the source with agent=0,
        // then the agent, then set the agent on the source (one-shot).
        HashChainSeed seedSrc = new HashChainSeed(address(racks), address(vault), address(0), SLASH_PER_MISS);
        IRSAgent agents = new IRSAgent(USDG, address(vault), address(seedSrc), c.reserve);
        seedSrc.setAgent(address(agents));
        seedSrc.setKeeper(c.keeper);
        racks.setExempt(address(seedSrc), true);       // the bond must not melt
        vault.setAgent(address(agents));   // FINAL: the pot pointer can never be changed again
        racks.setVault(address(vault));
        racks.setExempt(address(vault), true);      // locked RACKS must not lazy-melt
        racks.setTaxExempt(address(vault), true);
        racks.setTaxExempt(address(agents), true);
        racks.setTaxWallet(c.taxWallet);
        racks.setExempt(c.taxWallet, true);           // accrued tax must not melt away
        racks.setTaxExempt(c.taxWallet, true);
        racks.setTaxExempt(c.me, true);               // deployer seeds LP untaxed (and passes the gate)

        racks.mint(c.me, SUPPLY);
        racks.renounceMint();                       // supply is final

        // ---- 2. pair, REGISTERED BEFORE any liquidity ----
        // P1: with --broadcast every call is its own transaction in its own block. If liquidity
        // existed while the pair was not yet isDex, the N2 gate would not see it, tax would be 0 and
        // the cap ledger off — exactly the PairCreated+Mint window sniper bots listen for.
        // Registering first means every intermediate block is gate-protected.
        address pair = IV2Factory(FACTORY).getPair(address(racks), SPY);
        if (pair == address(0)) pair = IV2Factory(FACTORY).createPair(address(racks), SPY);
        racks.setExempt(pair, true);                // REQUIRED before setPair: pair holds a NOMINAL balance
        racks.setPair(pair);                        // isDex + capExempt + pairIndex (pool still empty: melt = 0)
        TwapOracle oracle = new TwapOracle(pair, address(racks));
        racks.setTaxOracle(address(oracle));

        // ---- 3. seed liquidity (gate is closed; only the tax-exempt deployer gets through) ----
        IERC20d(address(racks)).approve(ROUTER, type(uint256).max);
        IERC20d(SPY).approve(ROUTER, type(uint256).max);
        require(IERC20d(SPY).balanceOf(c.me) >= SPY_SEED, "fund the deployer with SPY first");
        IV2Router(ROUTER).addLiquidity(address(racks), SPY, SUPPLY, SPY_SEED, 0, 0, c.me, block.timestamp + 600);

        // ---- 3b. automatic tax conversion: every sell converts accrued tax RACKS -> SPY -> reserve
        // (a buy cannot: the pair is locked inside pair.swap(); buy-side tax converts on the next sell)
        racks.enableAutoSwap(ROUTER, SPY, c.reserve, SWAP_THRESHOLD);

        // ---- 4. arm the launch ----
        racks.enableTrading();

        // ---- 5. drop the deployer's powers ----
        // LP tokens must not stay on a tax-exempt EOA: scanners flag "creator can pull liquidity",
        // and a tax-exempt LP holder could run the melt-dodge for free. Send them to LP_DESTINATION
        // (0x...dEaD to burn, or a locker/multisig).
        uint256 lp = IERC20d(pair).balanceOf(c.me);
        require(lp > 0, "no LP minted");
        require(IERC20d(pair).transfer(c.lpDestination, lp), "lp move failed");
        racks.setTaxExempt(c.me, false);              // deployer is now an ordinary trader

        // S1: hand over EVERY contract, not just the token. The vault holds the lockers' funds and
        // the pot; leaving it on the deployer EOA would keep a single key able to swap the agent
        // (after the timelock) and drain the pot. All four use 2-step ownership.
        racks.transferOwnership(c.multisig);
        vault.transferOwnership(c.multisig);
        agents.transferOwnership(c.multisig);
        oracle.transferOwnership(c.multisig);
        seedSrc.transferOwnership(c.multisig);

        vm.stopBroadcast();

        // ---- deploy self-checks: fail loudly rather than launch broken ----
        require(racks.isExempt(pair), "pair must be melt-exempt");
        require(racks.pair() == pair && racks.pairIndex() != 0, "setPair missing");
        require(racks.isDex(pair), "pair not marked as dex");
        require(racks.capExempt(pair), "pair must be cap-exempt (it is the distributor)");
        require(racks.isExempt(c.taxWallet), "tax wallet must be melt-exempt");
        require(racks.taxOracle() == address(oracle), "oracle not wired");
        require(racks.mintRenounced(), "mint not renounced");
        require(racks.tradingStart() != 0, "trading not enabled");
        require(racks.maxWallet() > 0, "launch cap not set");
        require(racks.autoSwap() && racks.taxWallet() == address(racks), "auto tax swap not wired");
        require(IERC20d(pair).balanceOf(c.me) == 0, "deployer still holds LP");
        require(!racks.isTaxExempt(c.me), "deployer still tax-exempt");
        require(racks.pendingOwner() == c.multisig, "racks handover not started");
        require(vault.pendingOwner() == c.multisig, "vault handover not started");
        require(agents.pendingAdmin() == c.multisig, "agents handover not started");
        require(oracle.pendingOwner() == c.multisig, "oracle handover not started");
        require(seedSrc.pendingOwner() == c.multisig, "seed source handover not started");
        require(address(seedSrc.agent()) == address(agents) && seedSrc.keeper() == c.keeper, "seed source not wired");
        require(agents.paused(), "agents must stay paused until the keeper has committed a chain");
        require(vault.agent() == address(agents), "agent not set");

        deployedRacks = address(racks);
        console.log("RACKS   ", address(racks));
        console.log("Vault   ", address(vault));
        console.log("Agents  ", address(agents));
        console.log("Pair    ", pair);
        console.log("Oracle  ", address(oracle));
        console.log("maxWallet (1%)", racks.maxWallet());
        console.log("LP sent to  ", c.lpDestination);
        console.log("NEXT: multisig calls acceptOwnership() on ALL FIVE:");
        console.log("       racks, vault, agents, oracle, seedSrc - until then the deployer still controls them");
        console.log("SeedSrc ", address(seedSrc));
        console.log("NEXT (keeper): generate chain, commit(chainEnd, N), depositBond -> see keeper/README.md");
        console.log("NEXT (multisig): acceptOwnership on ALL FIVE, then agents.setPaused(false) after audit");
        console.log("LATER: agents.renounceVrfControl() once the source is settled");
        console.log("RUNBOOK: reserve MUST approve the agent for USDG, else refunds revert.");
        console.log("         verify with agents.refundsReady() before the casino is unpaused.");
        console.log("LATER: racks.renounceExemptControl() - IRREVERSIBLE, blocks all future exemptions");
    }
}
