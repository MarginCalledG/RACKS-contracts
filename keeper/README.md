# Keeper

The keeper reveals one pre-committed value per epoch — at the epoch's START, so it is public while
attacks are placed and decides nothing on its own (reveal-then-play). The seed is that value combined
with a block hash captured after the epoch closed, which no player controls. The keeper therefore never
knows a result before attacks are closed, cannot choose values (the chain is fixed at commit time), and
gains nothing by withholding: a missed reveal fails the epoch for everyone, keeper included, and slashes
max(floor, current pot) from its bond into the pot. Attacks are refused while the bond is below cover.

**chain.json is a pot-sized secret.** Anyone holding it can act as keeper; treat it like the keeper key.

Post-close entropy is captured in TWO steps: the first transaction after an epoch's end fixes a
FUTURE block number (its hash does not exist yet, so nobody gains by choosing when to touch); a later
transaction freezes that block's hash (it can only be recorded, not chosen). The freeze must happen
within 256 blocks (~64 s on RH), so the bot ticks every 15 s. If the window lapses the epoch FAILS and the keeper is slashed — freezing in time is the keeper's
job, and re-rolling would hand a candidate choice to whoever already saw the mined hash.

Reveal is only accepted BEFORE the epoch ends: the keeper can never see the post-close hash first.

Residual trust (documented, not solved): the post-close block hash is produced by Robinhood's
sequencer, which has no stake in the game. Removing even that is the CCIP upgrade path (proposeVrf).

## One-time setup
1. `npm i ethers ethereum-cryptography`
2. `node generate-chain.mjs 100000 > chain.json` — **keep chain.json secret, back it up offline**.
   The command prints the chain END; that is the only value that goes on-chain.
3. Multisig: `HashChainSeed.setKeeper(<bot address>)`.
4. Keeper: `HashChainSeed.commit(<chain end>, 100000)`, then `depositBond(<RACKS>)`
   (bond must stay ≥ one `slashPerMiss`; fund the bot address with gas).
5. Multisig: `IRSAgent.setPaused(false)` — only now, and only after this contract has been audited.

## Run
`RPC=... KEY=... SEED=... AGENT=... RACKS=... node keeper.mjs`
Run two instances on two machines with the same chain.json and a shared state file if you want
redundancy: the second one just sees "resolved" and skips. Monitor `Failed` events on the seed
contract — each one is a missed reveal and a slashed bond.

## What it does every tick
reveal the current epoch at its start; for closed epochs capture → tally → settle; then
`vault.advance(tier)` for all three tiers plus `burnExpired()`, and `meltPool()` / `swapTax()`.

**Why advance() matters:** a lock changes regime (tier bleed → unlocked melt, pot → burn) exactly when
`advance()` processes its expiry bucket. Running it every epoch makes that split exact. If it lags,
expired positions keep bleeding at the tier rate — in the locker's favour and at the pot's expense,
bounded by the lag. Set `VAULT=0x…` in the environment.
Unrevealed agents: after an outage, `advanceScan(id)` persists how far the dead-epoch scan already
got. It is permissionless, changes no outcome (the tier always comes from the first epoch that is
not dead) and turns a 159k-gas lookup into 5.7k. Worth running once per affected agent after any
outage; the protocol works without it, just more expensively.

Bond: must stay >= `requiredBond()` (the current pot, floor `slashPerMiss`); below that, attacks are
refused protocol-wide. A single miss takes at most a quarter of the bond, so an outage cannot compound
it away — but repeated misses still add up. The bot warns when the bond is short.
The bond belongs to the keeper slot: if the multisig replaces the keeper, the posted bond goes to the
pot, not to the successor. Post a fresh bond after a keeper change.
Lost chain.json: the owner can replace the chain via `proposeChainReset` + 3 days + `executeChainReset`.
If the chain and the on-chain head ever disagree, it stops (exit 2) rather than burning gas.
