# RACKS

Satirical DeFi + GameFi protocol on **Robinhood Chain** (Arbitrum Orbit L2, chain id 4663).
A demurrage token whose supply melts continuously, an offshore-themed lock vault, and an NFT casino
that raids what the vault bleeds.

> Status: pre-audit. Token, vault and pool are feature-complete and fork-tested against RH mainnet.
> The agent casino is **paused on deploy** and stays paused until a real randomness source exists on
> this chain (see STATUS.md). Nothing here has been externally audited.

## Contracts (`src/`)

| Contract | Role |
|---|---|
| `Racks.sol` | ERC20 demurrage token: ray-index melt, trading tax, launch cap, atomic pool melt |
| `CaymanIslands.sol` | 3-tier lock vault; what locks melt feeds the agent pot |
| `IRSAgent.sol` | ERC721 "IRS Agent" casino: pari-mutuel raids on the pot, epoch-based |
| `TwapOracle.sol` | TWAP + dislocation/impact read off the real v2 pair |
| `DynamicTax.sol` | Maps TWAP dislocation and trade impact to a tax rate (1%–8%) |

## Market structure: Uniswap v2, no wrapper

RACKS trades **directly** as RACKS in a Uniswap v2 pair against SPY. There is no wrapper token and no
v4 hook. v3/v4 derive reserves from liquidity and price and have no `sync()`, so a melting token goes
insolvent in them — verified on-chain, see AUDIT.md. v2 reconciles, so it works.

The pair is **melt-exempt** and holds a nominal balance. Its melt is applied explicitly and atomically
together with `pair.sync()` in `Racks.meltPool()`, so reserves and balance never drift apart and a swap
can never hit `UniswapV2: K`. `meltPool()` is permissionless (0.25% bounty) and is also self-called
from `_preOp` on epoch change, so it keeps itself in step without a keeper.

## Melt factors

Every position melts at `r_w * factor`. `r_w` is the free-float-coupled, 24h-smoothed base rate
(4.2%/d at FF=0 … 6.9%/d at FF=1).

| Position | Factor | @4.2% | @6.9% | Melt goes to |
|---|---|---|---|---|
| Unlocked | 1.0 | 4.20 %/d | 6.90 %/d | burned |
| LP (pair) | 0.5 | 2.10 %/d | 3.45 %/d | burned |
| Lock 1d | 0.3 | 1.26 %/d | 2.07 %/d | agent pot |
| Lock 3d | 0.2 | 0.84 %/d | 1.38 %/d | agent pot |
| Lock 14d | 0.1 | 0.42 %/d | 0.69 %/d | agent pot |

Read them on-chain with `ratePerDayBpsFor(pos)` / `perSecFactorFor(pos)`
(`P_UNLOCKED=0, P_LP=1, P_LOCK_1D=2, P_LOCK_3D=3, P_LOCK_14D=4`).

An **expired** lock is an ordinary token again: it melts at factor 1.0, that melt is **burned** (not
paid to the pot), and it stops counting as locked supply.

## Tax

Tax lives in the token (`isDex`), not in a hook: buys and sells are taxed, wallet-to-wallet is free.
4%/4% base, 1%–8% dynamic via `TwapOracle` + `DynamicTax`, flat 8% during the launch hour. With no
oracle wired the base rate applies — a missing oracle must never switch the tax off.

## Launch protection

`enableTrading()` arms the launch. Before that, every pool↔wallet transfer reverts (`not started`), so
there is no window in which the pool is live but ungated. For the first hour a cumulative 1% per-wallet
cap applies; the ledger counts what a wallet *acquires* and never decreases, so unwrapping, selling or
moving tokens away cannot reset it. Deliveries to contracts are booked on `tx.origin`, so shared
custodial bot routers do not brick for later users.

## Build and test

```bash
forge build
forge test                                                     # unit + invariants
forge test --fork-url https://rpc.mainnet.chain.robinhood.com  # against real v2/SPY on RH
```

Fork tests cover the atomic pool melt across epoch boundaries, adversarial melt/bounty scenarios,
and the real deploy script end to end.

## Deploy

`script/Deploy.s.sol`. The ordering is load-bearing and enforced by `require`s — read the deploy
section of STATUS.md before running it. Env: `PRIVATE_KEY`, `VRF_COORDINATOR`, `RESERVE`,
`TAX_WALLET`, `MULTISIG`, `LP_DESTINATION`.

## Docs

- `STATUS.md` — current architecture, deploy order, open decisions
- `AUDIT.md` — every finding across eight review rounds, with the tests that prove each fix
